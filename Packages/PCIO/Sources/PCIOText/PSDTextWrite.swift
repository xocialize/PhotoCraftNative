// PSD type layers, writing: `TextLayer` → EngineData, the `TySh` block and the document's
// `Txt2` block.
// Port of photocraft-text (crates/text/src/psd.rs: `kern_units`, `pair_runs`, `postscript_for`,
// `style_sheet_data`, `paragraph_properties`, `font_entry`, `txt2_mode_runs`, `needs_txt2`,
// `build_txt2`, `with_modes`, `build_engine_data`, `build_tysh`), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.
//
// Writing starts from the layer's original `TySh` (when present) and patches only the text, runs,
// paragraphs, fonts, shape and transform, so Photoshop-only settings survive an edit. EngineData
// and `Txt2` are written in Photoshop's own byte layout (PCPSD's writer), not photocraft's (see
// `EngineDataLayout`), for Photoshop acceptance.

import Foundation
import PCDocument
import PCFoundation
import PCPSD

extension PSDText {
    @inline(__always) static func real(_ v: Float) -> E { .real(Double(v)) }

    /// Manual kerning as Photoshop stores it: a whole number of 1/1000 em (its UI range is ±1000;
    /// anything non-finite writes 0).
    public static func kernUnits(_ v: Float) -> Int64 {
        v.isFinite ? sat(min(max(v.rounded(), -10_000), 10_000)) : 0
    }

    static func manual(_ s: CharStyle) -> Bool { s.kerning == .off || kernUnits(s.kern) != 0 }

    /// EngineData style runs for `edText` (the layer text with `\r` breaks and the trailing `\r`):
    /// (model run index, `(AutoKerning, Kerning)`, UTF-16 length), split where those change.
    static func pairRuns(_ edText: String, _ runs: [TextRun]) -> [(Int, (Bool, Int64), Int)] {
        // Model run of each character (the trailing `\r` takes the last run).
        var owner: [(Int, Int)] = []
        var ri = 0
        var runEnd = runs.first?.len ?? 0
        var b = 0
        for ch in edText.unicodeScalars {
            while b >= runEnd && ri + 1 < runs.count {
                ri += 1
                runEnd = satAdd(runEnd, runs[safe: ri]?.len ?? 0)
            }
            owner.append((ri, utf16Len(ch)))
            b += utf8Len(ch)
        }
        func style(_ i: Int) -> CharStyle? { owner[safe: i].flatMap { runs[safe: $0.0] }?.style }
        var out: [(Int, (Bool, Int64), Int)] = []
        for (j, (ri, n)) in owner.enumerated() {
            let k: Int64 = j >= 1 ? (style(j - 1).map { kernUnits($0.kern) } ?? 0) : 0
            // `false` marks character j - 2 manual: written when it is and its own kern (on j - 1)
            // doesn't say so already; harmless (and Photoshop's own form) next to a kern on j.
            let off: Bool = j >= 2 ? (style(j - 2).map { manual($0) && (kernUnits($0.kern) == 0 || k != 0) } ?? false) : k != 0
            let fields = (!off, k)
            if let last = out.last, last.0 == ri, last.1 == fields {
                out[out.count - 1].2 += n
            } else {
                out.append((ri, fields, n))
            }
        }
        return out
    }

    /// PostScript name for a style (the PSD `FontSet` stores these).
    public static func postscriptFor(_ s: CharStyle) -> String {
        if let ps = s.postscriptName { return ps }
        let fam = s.fontFamily.isEmpty ? defaultFamily : s.fontFamily
        let w: String = switch s.weight {
        case 0 ... 150: "Thin"
        case 151 ... 250: "ExtraLight"
        case 251 ... 350: "Light"
        case 351 ... 450: "Regular"
        case 451 ... 550: "Medium"
        case 551 ... 650: "SemiBold"
        case 651 ... 750: "Bold"
        case 751 ... 850: "ExtraBold"
        default: "Black"
        }
        let style = w == "Regular" && s.italic ? "Italic" : s.italic ? w + "Italic" : w
        var v = String.UnicodeScalarView()
        for c in fam.unicodeScalars where c != " " { v.append(c) }
        return String(v) + "-" + style
    }

    /// An EngineData `StyleSheetData` dictionary for `s`, naming font `font` of the `FontSet`,
    /// with sizes divided by `k` (72 / dpi).
    public static func styleSheetData(_ s: CharStyle, _ font: Int, _ k: Float) -> PSDEngineData {
        let c = s.color
        let values: [E]
        switch c.mode {
        case .cmyk: values = [real(c.alpha), real(c.c[0]), real(c.c[1]), real(c.c[2]), real(c.c[3])]
        case .grayscale: values = [real(c.alpha), real(c.c[0])]
        default:
            let rgb = c.rgb
            values = [real(c.alpha), real(rgb.x), real(rgb.y), real(rgb.z)]
        }
        let colorType: Int64 = switch c.mode {
        case .cmyk: 2
        case .grayscale: 0
        default: 1
        }
        let opentype: [(String, E)] = opentypeKeys
            .filter { entry in s.features.contains { same($0.tag, entry.tag) && $0.value > 0 } }
            .map { ($0.key, .bool(true)) }
        let caps: Int64 = switch s.caps {
        case .normal: 0
        case .smallCaps: 1
        case .allCaps: 2
        }
        return .d([
            ("Font", .int(Int64(font))),
            ("FontSize", real(s.sizePt / k)),
            ("FauxBold", .bool(s.fauxBold)),
            ("FauxItalic", .bool(s.fauxItalic)),
            ("AutoLeading", .bool(s.leadingPt == nil)),
            ("Leading", real((s.leadingPt ?? 0) / k)),
            ("HorizontalScale", real(s.horizontalScale)),
            ("VerticalScale", real(s.verticalScale)),
            ("Tracking", .int(sat(s.tracking.rounded()))),
            ("AutoKerning", .bool(s.kerning != .off)),
            ("Kerning", .int(kernUnits(s.kern))),
            ("BaselineShift", real(s.baselineShiftPt / k)),
            ("FontCaps", .int(caps)),
            ("Underline", .bool(s.underline)),
            ("Strikethrough", .bool(s.strikethrough)),
            ("Ligatures", .bool(s.ligatures)),
            ("DLigatures", .bool(s.discretionaryLigatures)),
            // Photopea lays out edited text without painting it unless its fill is enabled.
            ("FillFlag", .bool(true)),
            ("FillColor", .d([("Type", .int(colorType)), ("Values", .array(values))])),
        ] + opentype)
    }

    /// An EngineData paragraph `Properties` dictionary for `p`, with lengths divided by `k`.
    public static func paragraphProperties(_ p: ParagraphStyle, _ k: Float) -> PSDEngineData {
        let j: Int64 = switch p.align {
        case .left: 0
        case .right: 1
        case .center: 2
        case .justifyLeft: 3
        case .justifyRight: 4
        case .justifyCenter: 5
        case .justifyAll: 6
        }
        return .d([
            ("Justification", .int(j)),
            ("FirstLineIndent", real(p.firstLineIndentPt / k)),
            ("StartIndent", real(p.startIndentPt / k)),
            ("EndIndent", real(p.endIndentPt / k)),
            ("SpaceBefore", real(p.spaceBeforePt / k)),
            ("SpaceAfter", real(p.spaceAfterPt / k)),
            ("AutoHyphenate", .bool(p.hyphenate)),
            ("AutoLeading", real(p.autoLeading)),
            ("LeadingType", .int(0)),
        ])
    }

    /// A `FontSet` entry for PostScript name `name`.
    public static func fontEntry(_ name: String) -> PSDEngineData {
        .d([("Name", .string(name)), ("Script", .int(0)), ("FontType", .int(1)), ("Synthetic", .int(0))])
    }

    // MARK: - Txt2

    /// The `Txt2` auto-kern mode of a style: 0 manual, 1 metrics, 2 optical — the values
    /// `applyTxt2` maps back to `Kerning`. EngineData's `AutoKerning` can't say Metrics from
    /// Optical, so the mode only lives in `Txt2`.
    static func txt2Mode(_ s: CharStyle) -> Int64 {
        manual(s) ? 0 : s.kerning == .optical ? 2 : 1
    }

    /// `Txt2` style runs for `layer`: `(mode, UTF-16 length)` over the engine text (`\r` breaks
    /// and the trailing `\r`, which takes the last run's mode), split where the auto-kern mode
    /// changes.
    static func txt2ModeRuns(_ layer: TextLayer) -> [(Int64, Int)] {
        let runs = layer.charRuns()
        let edText = toEngineBreaks(layer.text) + "\r"
        var out: [(Int64, Int)] = []
        var ri = 0
        var runEnd = runs.first?.len ?? 0
        var b = 0
        for ch in edText.unicodeScalars {
            while b >= runEnd && ri + 1 < runs.count {
                ri += 1
                runEnd = satAdd(runEnd, runs[safe: ri]?.len ?? 0)
            }
            let mode = runs[safe: ri].map { txt2Mode($0.style) } ?? 1
            if let last = out.last, last.0 == mode {
                out[out.count - 1].1 += utf16Len(ch)
            } else {
                out.append((mode, utf16Len(ch)))
            }
            b += utf8Len(ch)
        }
        return out
    }

    /// Whether the document `Txt2` block is needed for `objects`: only a non-Metrics auto-kern
    /// mode (`Optical`) is exclusive to `Txt2` — EngineData's `AutoKerning` cannot distinguish
    /// Metrics from Optical — so a fresh document of ordinary Metrics text has nothing to put in
    /// the block. Writing Photoshop's empty `<< /0 << >> >>` stub anyway makes some readers
    /// (Photopea) fail (#3514); the export omits the block for such a document.
    public static func needsTxt2(_ objects: [(index: Int32, layer: TextLayer)]) -> Bool {
        objects.contains { $0.layer.charRuns().contains { $0.style.kerning == .optical } }
    }

    /// The document's `Txt2` block for `objects`: `(TextIndex, layer)` pairs, one text object
    /// each at the slot its `TextIndex` names (see `setTextIndex` and `textIndex`; unused slots
    /// are empty dictionaries), carrying the automatic kerning mode of every pair (`/11`:
    /// 0 manual, 1 metrics, 2 optical) — the one thing EngineData can't say (`AutoKerning true`
    /// covers Metrics and Optical alike). PSD export writes this block for the type layers it
    /// writes `TySh` data for; `applyTxt2` reads it back. Numbers outside `0...maxTextIndex` are
    /// skipped: the slot array is sized by real text objects, never by a file's numbers.
    ///
    /// `previous` is the block this replaces (the file's own). A kept object — one whose text is
    /// unchanged — keeps everything the file held beyond the two regenerated keys (its model's
    /// text and style runs): Photoshop stores glyph pen positions under `/21 /1` there, and a
    /// save with no text edit must not drop them. Its own style runs keep every style key too:
    /// only their auto-kern mode is set (split where a mode changes inside a run). A changed text
    /// invalidates those extras along with the old runs, so they are dropped rather than left
    /// stale. Everything else the file's block held — the other keys beside the text objects,
    /// objects no layer names — is kept, and a block whose content comes out unchanged is
    /// returned byte for byte (#2374: Photoshop refused files whose `Txt2` an unedited save had
    /// stripped).
    public static func buildTxt2(_ objects: [(index: Int32, layer: TextLayer)], previous: [UInt8]?) -> [UInt8] {
        let prev = previous.flatMap(parseTxt2)
        let prevObjects: [E] = prev?.at("1", "1")?.arr ?? []
        var slots = prevObjects
        for (index, layer) in objects {
            guard (0 ... maxTextIndex).contains(index) else { continue }
            let text = toEngineBreaks(layer.text) + "\r"
            let modes = txt2ModeRuns(layer)
            let at = Int(index)
            let kept = prevObjects[safe: at].flatMap { o in same(o.get("0")?.get("0")?.str, text) ? o : nil }
            var object = kept ?? .emptyDict
            var model = object.get("0").flatMap { $0.isDict ? $0 : nil } ?? .emptyDict
            // An empty layer has no character an auto-kern mode could apply to: its file runs stay.
            let fileRuns = kept == nil ? nil : model.at("6", "0")?.arr.flatMap { layer.text.isEmpty ? $0 : withModes($0, modes) }
            let runs = fileRuns ?? modes.map { mode, len in
                // `<< /0 << /0 << /0 () /6 << /0 0 /11 mode >> >> >> /1 len >>`.
                let style = E.d([("0", .int(0)), ("11", .int(mode))])
                let data = E.d([("0", .string("")), ("6", style)])
                return E.d([("0", .d([("0", data)])), ("1", .int(Int64(len)))])
            }
            model.put("0", .string(text))
            if model.get("6")?.isDict == true {
                model.update("6") { $0.put("0", .array(runs)) }
            } else {
                model.put("6", .d([("0", .array(runs))]))
            }
            object.put("0", model)
            if slots.count <= at { slots.append(contentsOf: repeatElement(E.emptyDict, count: at + 1 - slots.count)) }
            slots[at] = object
        }
        // The outer dictionary keeps whatever the block held (`/98` version, block extras, …),
        // and `/1` whatever it holds beside the text objects.
        var outer = prev ?? .d([("98", .d([("0", .int(14))])), ("0", .emptyDict)])
        if outer.get("1")?.isDict == true {
            outer.update("1") { $0.put("1", .array(slots)) }
        } else {
            outer.put("1", .d([("1", .array(slots))]))
        }
        // Nothing changed: the file's own bytes (writing them back would re-encode strings and
        // numbers).
        if let previous, let p = prev, p.sameValue(outer) { return previous }
        return engineDataBareBytes(outer.entries ?? [])
    }

    /// The file's own `Txt2` style runs `runs` with the auto-kern modes `modes` (`(mode, UTF-16
    /// length)`, see `txt2ModeRuns`) set at `/0 /0 /6 /11`, keeping every other style key. A run
    /// a mode change falls inside is split there. nil when the runs don't cover the text or lack
    /// a style dictionary: the caller writes its own runs instead.
    static func withModes(_ runs: [E], _ modes: [(Int64, Int)]) -> [E]? {
        var lens: [Int] = []
        for r in runs {
            guard let l = r.get("1")?.i64, l >= 0 else { return nil }
            lens.append(Int(l))
        }
        var total = 0
        for m in modes {
            guard let s = checkedAdd(total, m.1) else { return nil }
            total = s
        }
        var sum = 0
        for l in lens {
            guard let s = checkedAdd(sum, l) else { return nil }
            sum = s
        }
        guard sum == total, let first = modes.first else { return nil }
        var out: [E] = []
        out.reserveCapacity(runs.count)
        var mi = 0
        var modeEnd = first.1
        var at = 0
        for (run, len) in zip(runs, lens) {
            if len == 0 {
                out.append(run)
                continue
            }
            let end = at + len
            while at < end {
                while at >= modeEnd && mi + 1 < modes.count {
                    mi += 1
                    guard let m = modes[safe: mi] else { return nil }
                    modeEnd = satAdd(modeEnd, m.1)
                }
                let pieceEnd = min(end, modeEnd)
                if pieceEnd <= at { return nil }
                var piece = run
                if pieceEnd - at != len { piece.put("1", .int(Int64(pieceEnd - at))) }
                guard var l0 = piece.get("0"), l0.isDict, var l1 = l0.get("0"), l1.isDict,
                      var style = l1.get("6"), style.isDict else { return nil }
                guard let mode = modes[safe: mi]?.0 else { return nil }
                // Keep the file's value (and its number type) when the mode is the same. Photoshop
                // leaves `/11` out of a style whose mode is its default, Metrics (1): a missing key
                // is 1, and stays missing (photocraft added `/11 1`, so an unedited save of such a
                // file rewrote its `Txt2`, the #2374 failure).
                let current: Int64? = if let v = style.get("11") { v.i64 } else { 1 }
                if current != mode {
                    style.put("11", .int(mode))
                    l1.put("6", style)
                    l0.put("0", l1)
                    piece.put("0", l0)
                }
                out.append(piece)
                at = pieceEnd
            }
        }
        return out
    }

    // MARK: - EngineData and TySh

    /// Updates (or creates) an EngineData tree for `layer`. `template` is the layer's current
    /// EngineData (from its `TySh`), whose Photoshop-only settings are kept.
    public static func buildEngineData(_ layer: TextLayer, template: PSDEngineData?, dpi: Float) -> PSDEngineData {
        let k: Float = 72 / (dpi > 0 ? dpi : 72)
        let fresh = E.d([("EngineDict", .emptyDict), ("ResourceDict", .emptyDict)])
        // The template comes from the PSD: it may not be a dictionary or may lack `EngineDict`.
        var e: E = if let template, template.isDict { template } else { fresh }
        if e.get("EngineDict")?.isDict != true { e.put("EngineDict", .emptyDict) }
        let runs = layer.charRuns()
        let paras = layer.paragraphRuns()
        let text = toEngineBreaks(layer.text)
        let edText = text + "\r"

        // Fonts: keep the template's font list and append new PostScript names.
        var fonts: [String] = e.at("ResourceDict", "FontSet")?.arr?.map { $0.get("Name")?.str ?? "" } ?? []
        func fontIndex(_ ps: String) -> Int {
            if let i = fonts.firstIndex(where: { same($0, ps) }) { return i }
            fonts.append(ps)
            return fonts.count - 1
        }
        var sruns: [E] = []
        var slens: [E] = []
        for (ri, pair, n) in pairRuns(edText, runs) {
            guard let r = runs[safe: ri] else { continue }
            let fi = fontIndex(postscriptFor(r.style))
            var data = styleSheetData(r.style, fi, k)
            data.put("AutoKerning", .bool(pair.0))
            data.put("Kerning", .int(pair.1))
            sruns.append(.d([("StyleSheet", .d([("StyleSheetData", data)]))]))
            slens.append(.int(Int64(n)))
        }
        var pruns: [E] = []
        var plens: [E] = []
        let textBytes = Array(text.utf8)
        var at = 0
        for (i, p) in paras.enumerated() {
            let lo = min(at, textBytes.count), hi = min(max(lo, at + p.len), textBytes.count)
            at += p.len
            var n = Int64(String(decoding: textBytes[lo ..< hi], as: UTF8.self).utf16.count)
            if i + 1 == paras.count { n += 1 }
            pruns.append(.d([("ParagraphSheet", .d([("DefaultStyleSheet", .int(0)), ("Properties", paragraphProperties(p.style, k))]))]))
            plens.append(.int(n))
        }
        let fontset = E.array(fonts.map(fontEntry))

        guard var dict = e.get("EngineDict") else { return fresh }
        var editor = dict.get("Editor") ?? .emptyDict
        editor.put("Text", .string(edText))
        dict.put("Editor", editor)
        var pr = dict.get("ParagraphRun") ?? .emptyDict
        pr.put("RunArray", .array(pruns))
        pr.put("RunLengthArray", .array(plens))
        if pr.get("IsJoinable") == nil { pr.put("IsJoinable", .int(1)) }
        dict.put("ParagraphRun", pr)
        var sr = dict.get("StyleRun") ?? .emptyDict
        sr.put("RunArray", .array(sruns))
        sr.put("RunLengthArray", .array(slens))
        if sr.get("IsJoinable") == nil { sr.put("IsJoinable", .int(2)) }
        dict.put("StyleRun", sr)
        let antialias: Int64 = switch layer.antialias {
        case .none: 0
        case .crisp: 1
        case .strong: 2
        case .smooth: 3
        case .sharp: 4
        // No Photoshop file confirms the platform modes' numbers here; the `AntA` descriptor
        // carries the exact mode, and Smooth is the closest.
        case .windows, .windowsLcd: 3
        }
        dict.put("AntiAlias", .int(antialias))
        if dict.get("UseFractionalGlyphWidths") == nil { dict.put("UseFractionalGlyphWidths", .bool(true)) }
        let shapeType: Int64
        let boxBounds: [Float]?
        // Type on a path is written as point text and area type as a box of the area's bounds: PSD's
        // path-text records are not generated here.
        if let b = layer.shape.layoutBox {
            (shapeType, boxBounds) = (1, [b.x, b.y, b.x + b.width, b.y + b.height])
        } else {
            (shapeType, boxBounds) = (0, nil)
        }
        var photoshop = E.d([("ShapeType", .int(shapeType))])
        if let boxBounds {
            photoshop.put("BoxBounds", .array(boxBounds.map(real)))
        } else {
            photoshop.put("PointBase", .array([real(0), real(0)]))
        }
        photoshop.put("Base", .d([
            ("ShapeType", .int(shapeType)),
            ("TransformPoint0", .array([real(1), real(0)])),
            ("TransformPoint1", .array([real(0), real(1)])),
            ("TransformPoint2", .array([real(0), real(0)])),
        ]))
        // EngineData writing direction and procession, as Photoshop writes vertical type: 2 and 1
        // (horizontal: 0 and 0). The descriptor's `Ornt` agrees.
        let writing: Int64 = layer.orientation == .vertical ? 2 : 0
        let child = E.d([
            ("ShapeType", .int(shapeType)),
            ("Procession", .int(writing == 2 ? 1 : 0)),
            ("Lines", .d([("WritingDirection", .int(writing)), ("Children", .array([]))])),
            ("Cookie", .d([("Photoshop", photoshop)])),
        ])
        dict.put("Rendered", .d([
            ("Version", .int(1)),
            ("Shapes", .d([("WritingDirection", .int(writing)), ("Children", .array([child]))])),
        ]))
        e.put("EngineDict", dict)

        for key in ["ResourceDict", "DocumentResources"] {
            if key == "DocumentResources" && e.get(key) == nil {
                e.put(key, e.get("ResourceDict") ?? .emptyDict)
                continue
            }
            guard var rd = e.get(key) else { continue }
            rd.put("FontSet", fontset)
            if rd.get("StyleSheetSet") == nil {
                let base = runs.first?.style ?? CharStyle()
                rd.put("StyleSheetSet", .array([.d([("Name", .string("Normal RGB")), ("StyleSheetData", styleSheetData(base, 0, k))])]))
            }
            if rd.get("ParagraphSheetSet") == nil {
                rd.put("ParagraphSheetSet", .array([.d([
                    ("Name", .string("Normal RGB")),
                    ("DefaultStyleSheet", .int(0)),
                    ("Properties", paragraphProperties(ParagraphStyle(), k)),
                ])]))
            }
            for k2 in ["TheNormalStyleSheet", "TheNormalParagraphSheet"] where rd.get(k2) == nil {
                rd.put(k2, .int(0))
            }
            e.put(key, rd)
        }
        return e
    }

    /// Builds the `TySh` block for `layer`, patching its current `psdRaw` when present. `ink` is
    /// the layer's rendered bounds in text space (left, top, right, bottom; for
    /// `bounds`/`boundingBox`).
    public static func buildTySh(_ layer: TextLayer, dpi: Float, ink: SIMD4<Float>?) -> [UInt8] {
        let old = layer.psdRaw.flatMap(parseTySh)
        // Photoshop-complete EngineData (PCPSD `missingPhotoshopStructures()` empty) is the
        // template, so everything Photoshop wrote beyond the model survives; anything less
        // (hand-built or third-party EngineData, which crashes Photoshop 27.11 on open or makes it
        // refuse the file) is rebuilt from the model.
        let template = old.flatMap { engineData($0.text) }.flatMap { $0.missingPhotoshopStructures().isEmpty ? $0 : nil }
        let e = buildEngineData(layer, template: template, dpi: dpi)
        var text = old?.text ?? PSDDescriptor(classID: "TxLr")
        text.set("Txt ", .text(.nulTerminated(toEngineBreaks(layer.text))))
        if text["textGridding"] == nil { text.set("textGridding", enumv("textGridding", "None")) }
        text.set("Ornt", enumv("Ornt", layer.orientation == .vertical ? "Vrtc" : "Hrzn"))
        let annt = switch layer.antialias {
        case .none: "Anno"
        case .sharp: "antiAliasSharp"
        case .crisp: "AnCr"
        case .strong: "AnSt"
        case .smooth: "AnSm"
        case .windows: "antiAliasPlatformGray"
        case .windowsLcd: "antiAliasPlatformLCD"
        }
        text.set("AntA", enumv("Annt", annt))
        let r: SIMD4<Float> = switch (layer.shape, ink) {
        case let (.box(b), _): SIMD4(b.x, b.y, b.x + b.width, b.y + b.height)
        case let (_, i?): i
        default: .zero
        }
        func rect(_ cls: String) -> PSDDescriptor.Value {
            .descriptor(PSDDescriptor(classID: PSDDescriptor.ID(cls))
                .with("Left", .unitFloat(unit: "#Pnt", value: Double(r[0])))
                .with("Top ", .unitFloat(unit: "#Pnt", value: Double(r[1])))
                .with("Rght", .unitFloat(unit: "#Pnt", value: Double(r[2])))
                .with("Btom", .unitFloat(unit: "#Pnt", value: Double(r[3]))))
        }
        text.set("bounds", rect("bounds"))
        text.set("boundingBox", rect("boundingBox"))
        if text["TextIndex"] == nil { text.set("TextIndex", .integer(0)) }
        text.set("EngineData", .rawData(Data(engineDataBytes(e))))
        let warp: PSDDescriptor?
        if let w = layer.warp {
            warp = PSDDescriptor(classID: "warp")
                .with("warpStyle", enumv("warpStyle", w.style))
                .with("warpValue", .double(Double(w.value)))
                .with("warpPerspective", .double(Double(w.horizontalDistortion)))
                .with("warpPerspectiveOther", .double(Double(w.verticalDistortion)))
                .with("warpRotate", enumv("Ornt", w.horizontal ? "Hrzn" : "Vrtc"))
        } else if let o = old?.warp, enumValue(o, "warpStyle") == "warpNone" {
            warp = o
        } else {
            warp = nil
        }
        // Photoshop's trailing bounds: zeros for unwarped type, the text-space bounds when warped.
        let warped = warp.flatMap { enumValue($0, "warpStyle") }.map { $0 != "warpNone" } ?? false
        return writeTySh(TySh(transform: layer.transform, text: text, warp: warp, bounds: warped ? r : .zero))
    }

    /// The byte layout EngineData is written in.
    public enum EngineDataLayout: Sendable {
        /// Photoshop's own layout (PCPSD's writer; the default): `TySh` EngineData tab-indented
        /// with arrays on their key's line and no final newline (`PSDEngineData.serialized()`),
        /// and the document `Txt2` block on one line (`serializedCompactBare()`). It reproduces
        /// every EngineData and `Txt2` block of the Photoshop corpus byte for byte.
        case photoshop
        /// photocraft's `engine_data::write` / `write_bare`: an array holding containers opens on
        /// the line after its key, the document ends with a newline, and `Txt2` is written
        /// tab-indented over several lines. Kept for byte comparisons with photocraft.
        case photocraft
    }

    /// EngineData `v` as bytes in `layout` (Photoshop's by default).
    public static func engineDataBytes(_ v: PSDEngineData, layout: EngineDataLayout = .photoshop) -> [UInt8] {
        switch layout {
        case .photoshop: [UInt8](v.serialized())
        case .photocraft: EngineWriter.write(v)
        }
    }

    /// `/key value` pairs without an enclosing dictionary (the document `Txt2` layout) in
    /// `layout` (Photoshop's by default).
    public static func engineDataBareBytes(_ items: [PSDEngineData.Entry], layout: EngineDataLayout = .photoshop) -> [UInt8] {
        switch layout {
        case .photoshop: [UInt8](PSDEngineData.dict(items).serializedCompactBare())
        case .photocraft: EngineWriter.writeBare(items)
        }
    }
}
