// PSD type layers, reading: the `TySh` block (transform + text descriptor with `EngineData` +
// warp) and the document's `Txt2` block → the typed `TextLayer` model.
// Port of photocraft-text (crates/text/src/psd.rs: `text_layer_from_tysh`, `apply_engine_data`,
// `char_style`, `para_style`, `kerning_from_pairs`, `apply_txt2`, `apply_txt2_frame`, …),
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Units: EngineData sizes are in text-space units, which the `TySh` transform maps to document
// pixels; Photoshop shows them as points at the document resolution, so
// `size_pt = FontSize × 72 / dpi` (and likewise leading, tracking-independent lengths, indents).
// Box bounds stay in text-space pixels.

import Foundation
import PCDocument
import PCFoundation
import PCPSD

/// PSD type layers ⇄ `TextLayer` (photocraft `photocraft_text::psd`).
public enum PSDText {
    /// The highest text-object number honoured here (`TextIndex`, and the slot array `buildTxt2`
    /// sizes). PSD text objects are numbered densely from 0; a crafted file can name object
    /// `Int32.max`, and sizing the array by it would make every save allocate gigabytes.
    public static let maxTextIndex: Int32 = 0xFFFF

    /// OpenType settings of a `Txt2` style that are on/off flags, by style key, as Photoshop
    /// writes them: `/20` Contextual Alternates, `/23` Fractions, `/24` Ordinals, `/25` Swash,
    /// `/26` Titling Alternates, `/28` Stylistic Alternates, `/29` Ornaments. (`/18` and `/19` are
    /// the standard and discretionary ligatures, which EngineData carries too; `/27` is Arabic
    /// connection forms.)
    public static let txt2Features: [(key: String, tag: String)] = [
        ("20", "calt"), ("23", "frac"), ("24", "ordn"), ("25", "swsh"), ("26", "titl"), ("28", "salt"), ("29", "ornm"),
    ]

    /// The `Txt2` style key holding the Stylistic Sets as a bit mask: bit n is set n + 1
    /// (`ss01`…`ss20`).
    public static let txt2StylisticSets = "85"

    /// EngineData style keys for the Type › OpenType toggles and the OpenType feature each one
    /// turns on (the standard and discretionary ligature keys map to dedicated `CharStyle` fields).
    public static let opentypeKeys: [(key: String, tag: String)] = [
        ("ContextualLigatures", "calt"),
        ("Swash", "swsh"),
        ("OldStyle", "onum"),
        ("StylisticAlternates", "salt"),
        ("Titling", "titl"),
        ("Ornaments", "ornm"),
        ("Ordinals", "ordn"),
        ("Fractions", "frac"),
    ]

    // MARK: - TySh → TextLayer

    /// Builds a `TextLayer` (model, text and transform; no cache, no `psdRaw`) from `TySh` data.
    public static func textLayer(fromTySh data: [UInt8], dpi: Float) -> TextLayer? {
        guard let t = parseTySh(data) else { return nil }
        var layer = TextLayer()
        layer.transform = t.transform
        var txt: String?
        if case let .text(s)? = t.text["Txt "] {
            var v = s.string.unicodeScalars
            while v.last == "\0" { v.removeLast() }
            txt = String(v)
        }
        layer.orientation = enumValue(t.text, "Ornt") == "Vrtc" ? .vertical : .horizontal
        switch enumValue(t.text, "AntA") {
        case "Anno"?, "antiAliasNone"?: layer.antialias = .none
        case "antiAliasSharp"?, "AnSh"?: layer.antialias = .sharp
        case "AnCr"?, "antiAliasCrisp"?: layer.antialias = .crisp
        case "AnSt"?, "antiAliasStrong"?: layer.antialias = .strong
        case "antiAliasPlatformGray"?: layer.antialias = .windows
        case "antiAliasPlatformLCD"?: layer.antialias = .windowsLcd
        case .some: layer.antialias = .smooth
        // No `AntA`: the engine data's mode says it.
        case nil:
            layer.antialias = engineData(t.text)?.at("EngineDict", "AntiAlias")?.f64.flatMap(engineAntialias) ?? .smooth
        }
        if let w = t.warp {
            let style = enumValue(w, "warpStyle") ?? "warpNone"
            if style != "warpNone" {
                layer.warp = TextWarp(
                    style: style,
                    value: Float(dnum(w["warpValue"]) ?? 0),
                    horizontalDistortion: Float(dnum(w["warpPerspective"]) ?? 0),
                    verticalDistortion: Float(dnum(w["warpPerspectiveOther"]) ?? 0),
                    horizontal: enumValue(w, "warpRotate") != "Vrtc"
                )
            }
        }
        let k: Float = 72 / (dpi > 0 ? dpi : 72)
        if let e = engineData(t.text) {
            // Without an `Ornt` key, the engine data's writing direction says it (2 = vertical).
            if enumValue(t.text, "Ornt") == nil, e.at("EngineDict", "Rendered", "Shapes", "WritingDirection")?.f64 == 2 {
                layer.orientation = .vertical
            }
            applyEngineData(&layer, e, txt, k)
        } else {
            layer.text = toModelBreaks(txt ?? "")
        }
        // Some legacy PSDs store point text at a large local origin even though PointBase is zero.
        // Their transform maps that origin onto the canvas, but maps our zero-based layout far
        // away. Move the imported layout to the descriptor's ink origin so editing, engine
        // commands, and writing the TySh all agree on the visible position (#1469).
        if let (x, y) = legacyPointOrigin(t) {
            let m = layer.transform
            layer.transform = PCAffine(a: m.a, b: m.b, c: m.c, d: m.d, e: m.a * x + m.c * y + m.e, f: m.b * x + m.d * y + m.f)
        }
        layer.syncSummary()
        return layer
    }

    /// The local origin to fold into a legacy point-text transform, if present.
    ///
    /// Photoshop normally keeps point text close to its PointBase. The affected legacy files
    /// instead use a zero PointBase plus a very large `boundingBox` origin, with an equally remote
    /// transform translation that cancels it out. Do not apply this to ordinary point text: its
    /// transform origin is already the layout origin, and shifting it by the ink bounds would
    /// move the layer.
    static func legacyPointOrigin(_ t: TySh) -> (Double, Double)? {
        guard let e = engineData(t.text),
              let pointBase = e.at("EngineDict", "Rendered", "Shapes", "Children")?.arr?.first?.at("Cookie", "Photoshop", "PointBase")?.arr,
              pointBase.count == 2 else { return nil }
        if pointBase[0].f64 != 0 || pointBase[1].f64 != 0 { return nil }
        guard let bounds = descriptorRect(t.text, "boundingBox") else { return nil }
        let m = t.transform
        let values = [m.a, m.b, m.c, m.d, m.e, m.f, bounds[0], bounds[1]]
        guard values.allSatisfy(\.isFinite) else { return nil }
        let shifted = (m.a * bounds[0] + m.c * bounds[1] + m.e, m.b * bounds[0] + m.d * bounds[1] + m.f)
        let originDistance = max(abs(m.e), abs(m.f))
        let shiftedDistance = max(abs(shifted.0), abs(shifted.1))
        // A local bounding-box origin in the thousands and a transform origin beyond a normal
        // canvas are the signature of this old writer. Requiring that the bounding-box origin is
        // closer to the document prevents applying the correction again after export/import.
        guard max(abs(bounds[0]), abs(bounds[1])) > 1024, originDistance > 4096, shiftedDistance < originDistance else { return nil }
        return (bounds[0], bounds[1])
    }

    /// Converts UTF-16 run lengths over `text` into UTF-8 byte lengths.
    public static func utf16ToByteLengths(_ text: String, _ lens: [Double]) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(lens.count)
        var chars = text.unicodeScalars.makeIterator()
        for l in lens {
            var units: Int = sat(max(l, 0))
            var bytes = 0
            while units > 0 {
                guard let c = chars.next() else { break }
                units = units > utf16Len(c) ? units - utf16Len(c) : 0
                bytes += utf8Len(c)
            }
            out.append(bytes)
        }
        return out
    }

    /// The anti-aliasing mode for EngineData's `AntiAlias` number, as Photoshop writes it: 0 None,
    /// 1 Crisp, 2 Strong, 3 Smooth, 4 Sharp. Other numbers (platform modes) are left to `AntA`.
    static func engineAntialias(_ n: Double) -> AntiAlias? {
        switch sat(n) as Int64 {
        case 0: AntiAlias.none
        case 1: .crisp
        case 2: .strong
        case 3: .smooth
        case 4: .sharp
        default: nil
        }
    }

    static func applyEngineData(_ layer: inout TextLayer, _ e: E, _ txt: String?, _ k: Float) {
        let edText = e.at("EngineDict", "Editor", "Text")?.str ?? ""
        // Photoshop always ends the engine text with a paragraph break; the descriptor text doesn't.
        layer.text = toModelBreaks(txt ?? strippingCR(edText))
        let res = e.get("ResourceDict") ?? e.get("DocumentResources")
        let fonts: [String] = res?.get("FontSet")?.arr?.map { $0.get("Name")?.str ?? "" } ?? []
        // Style resolution (#3795). A run's own `StyleSheetData` / `Properties` hold only what it
        // overrides; the rest comes from its sheets, as in Photoshop:
        // - a paragraph run: its `Properties` → the `ParagraphSheetSet` entry its `Name` names (a
        //   paragraph style; or its `Parent` index) → `TheNormalParagraphSheet`;
        // - a character run: its `StyleSheetData` → the `StyleSheetSet` entry its `Parent` or
        //   `Name` names (a character style) → the default character style of its paragraph (the
        //   paragraph run's `DefaultStyleSheet`, else its paragraph style's) → `TheNormalStyleSheet`.
        // Missing or out-of-range indices fall through to the next level, then to the defaults.
        let styleSet: [E] = res?.get("StyleSheetSet")?.arr ?? []
        let paraSet: [E] = res?.get("ParagraphSheetSet")?.arr ?? []
        func index(_ key: String) -> Int? { res?.get(key)?.i64.flatMap { $0 >= 0 ? Int($0) : nil } }
        let normalStyle = index("TheNormalStyleSheet").flatMap { styleSet[safe: $0] } ?? styleSet.first
        let normalPara = index("TheNormalParagraphSheet").flatMap { paraSet[safe: $0] } ?? paraSet.first
        // A run names its sheet by a `Parent` index or by `Name` (see `PSDStyles`).
        func named(_ set: [E], _ sheet: E) -> Int? {
            if let i = sheet.get("Parent")?.i64, i >= 0, i < set.count { return Int(i) }
            guard let name = sheet.get("Name")?.str else { return nil }
            return set.firstIndex { same($0.get("Name")?.str, name) }
        }

        // Paragraph runs first: a character run's defaults depend on its paragraph.
        let prun = e.at("EngineDict", "ParagraphRun")
        let psheets: [E] = prun?.get("RunArray")?.arr?.compactMap { $0.get("ParagraphSheet") } ?? []
        let plens16 = arrF(prun?.get("RunLengthArray"))
        let plens = utf16ToByteLengths(edText, plens16)
        let empty = E.emptyDict
        // Per paragraph run: its merged base properties and its default character style.
        let paraBases: [(E, E?)] = psheets.map { sheet in
            let style = named(paraSet, sheet).flatMap { paraSet[safe: $0] }
            let base = merged([style?.get("Properties"), normalPara?.get("Properties")])
            let charDefault = [sheet, style].lazy.compactMap { $0 }.compactMap { s -> E? in
                guard let i = s.get("DefaultStyleSheet")?.i64, i >= 0 else { return nil }
                return styleSet[safe: Int(i)]
            }.first
            return (base, charDefault)
        }
        layer.paragraphs = zip(zip(psheets, paraBases), plens).map { pair, len in
            ParagraphRun(len: len, style: paraStyle(pair.1.0, pair.0.get("Properties") ?? empty, k))
        }

        // Character runs.
        let srun = e.at("EngineDict", "StyleRun")
        let ssheets: [E] = srun?.get("RunArray")?.arr?.compactMap { $0.get("StyleSheet") } ?? []
        let slens16 = arrF(srun?.get("RunLengthArray"))
        let slens = utf16ToByteLengths(edText, slens16)
        // The paragraph run each character run starts in (UTF-16 offsets).
        func paraOf(_ at: Double) -> Int? {
            var end = 0.0
            for (i, n) in plens16.enumerated() {
                end += n
                if at < end { return i }
            }
            return plens16.isEmpty ? nil : plens16.count - 1
        }
        var at16 = 0.0
        var bases: [E] = []
        bases.reserveCapacity(ssheets.count)
        for (i, sheet) in ssheets.enumerated() {
            let own = named(styleSet, sheet).flatMap { styleSet[safe: $0] }
            let paraDefault = paraOf(at16).flatMap { paraBases[safe: $0] }?.1
            at16 += slens16[safe: i] ?? 0
            bases.append(merged([own, paraDefault, normalStyle].map { $0?.get("StyleSheetData") }))
        }
        let sdata: [E] = ssheets.map { $0.get("StyleSheetData") ?? empty }
        let incoming: [(Int, Bool, Float)] = zip(zip(sdata, bases), slens).map { pair, len in
            let (d, base) = pair
            let auto = lookup(d, base, "AutoKerning")?.flag != false
            let kern = lookup(d, base, "Kerning")?.f64.flatMap { $0.isFinite ? $0 : nil } ?? 0
            return (len, auto, Float(kern))
        }
        layer.runs = zip(zip(sdata, bases), slens).map { pair, len in
            TextRun(len: len, style: charStyle(pair.1, pair.0, fonts, k))
        }
        layer.runs = kerningFromPairs(layer.text, layer.charRuns(), incoming)

        // Shape.
        if let sh = e.at("EngineDict", "Rendered", "Shapes", "Children")?.arr?.first, sh.get("ShapeType")?.i64 == 1 {
            let b = arrF(sh.at("Cookie", "Photoshop", "BoxBounds"))
            if b.count == 4 {
                layer.shape = .box(TextShape.TextBox(x: Float(b[0]), y: Float(b[1]), width: Float(b[2] - b[0]), height: Float(b[3] - b[1])))
            }
        }
    }

    /// The dictionaries in `levels` as one: a key comes from the first level that has it.
    static func merged(_ levels: [E?]) -> E {
        var out: [E.Entry] = []
        for case let .dict(kv)? in levels {
            for entry in kv where !out.contains(where: { same($0.key, entry.key) }) {
                out.append(entry)
            }
        }
        return .dict(out)
    }

    static func lookup(_ run: E, _ base: E?, _ key: String) -> E? {
        run.get(key) ?? base?.get(key)
    }

    /// A character style from an EngineData `StyleSheetData` dictionary `d` over `base` (the
    /// resolved sheets), with sizes scaled by `k` (72 / dpi).
    public static func charStyle(_ base: PSDEngineData?, _ d: PSDEngineData, _ fonts: [String], _ k: Float) -> CharStyle {
        func g(_ key: String) -> E? { lookup(d, base, key) }
        func num(_ key: String) -> Double? { g(key)?.f64 }
        func flag(_ key: String) -> Bool? { g(key)?.flag }
        var s = CharStyle()
        if let i = g("Font")?.i64, let ps = fonts[safe: usizeIndex(i)] {
            let r = guessFromPostscript(ps)
            s.fontFamily = r.family
            s.weight = r.weight
            s.italic = r.italic
            s.postscriptName = ps
        }
        if let v = num("FontSize") { s.sizePt = Float(v) * k }
        if flag("AutoLeading") == false, let v = num("Leading") { s.leadingPt = Float(v) * k }
        s.tracking = Float(num("Tracking") ?? 0)
        s.baselineShiftPt = Float(num("BaselineShift") ?? 0) * k
        s.horizontalScale = Float(num("HorizontalScale") ?? 1)
        s.verticalScale = Float(num("VerticalScale") ?? 1)
        s.fauxBold = flag("FauxBold") ?? false
        s.fauxItalic = flag("FauxItalic") ?? false
        s.underline = flag("Underline") ?? false
        s.strikethrough = flag("Strikethrough") ?? false
        s.ligatures = flag("Ligatures") ?? true
        s.discretionaryLigatures = flag("DLigatures") ?? false
        for (key, tag) in opentypeKeys where flag(key) == true {
            s.features.append(FontFeature(tag: tag, value: 1))
        }
        s.kerning = flag("AutoKerning") == false ? .off : .metrics
        s.kern = Float(num("Kerning").flatMap { $0.isFinite ? $0 : nil } ?? 0)
        s.caps = switch g("FontCaps")?.i64 {
        case 1?: .smallCaps
        case 2?: .allCaps
        default: .normal
        }
        if let c = g("FillColor") {
            let v = arrF(c.get("Values"))
            let a = Float(v.first ?? 1)
            s.color = switch v.count {
            case 5: PCColor(mode: .cmyk, c: SIMD4(Float(v[1]), Float(v[2]), Float(v[3]), Float(v[4])), alpha: a)
            case 2: PCColor(mode: .grayscale, c: SIMD4(Float(v[1]), 0, 0, 0), alpha: a)
            case 4: PCColor.rgb(Float(v[1]), Float(v[2]), Float(v[3]), a)
            default: .black
            }
        }
        return s
    }

    /// A paragraph style from an EngineData paragraph `Properties` dictionary `d` over `base`.
    public static func paraStyle(_ base: PSDEngineData?, _ d: PSDEngineData, _ k: Float) -> ParagraphStyle {
        func num(_ key: String) -> Double? { lookup(d, base, key)?.f64 }
        var p = ParagraphStyle()
        p.align = switch num("Justification").map({ sat($0) as Int64 }) {
        case 1?: .right
        case 2?: .center
        case 3?: .justifyLeft
        case 4?: .justifyRight
        case 5?: .justifyCenter
        case 6?: .justifyAll
        default: .left
        }
        p.firstLineIndentPt = Float(num("FirstLineIndent") ?? 0) * k
        p.startIndentPt = Float(num("StartIndent") ?? 0) * k
        p.endIndentPt = Float(num("EndIndent") ?? 0) * k
        p.spaceBeforePt = Float(num("SpaceBefore") ?? 0) * k
        p.spaceAfterPt = Float(num("SpaceAfter") ?? 0) * k
        p.autoLeading = Float(num("AutoLeading") ?? 1.2)
        p.hyphenate = lookup(d, base, "AutoHyphenate")?.flag ?? false
        return p
    }

    // Kerning in EngineData, as observed in Photoshop 2026 (writing, and reading files without
    // `Txt2`): a manual kern k (1/1000 em) after character c is written on character c + 1 as
    // `AutoKerning false` + `Kerning k`; everything else is `true` + 0. Photoshop's reader takes
    // `Kerning k` on character j as the kern after j - 1 (making j - 1 manual), and
    // `AutoKerning false` on j as "character j - 2 is manually kerned" (no automatic kerning).
    // The automatic mode itself (Metrics or Optical) isn't in EngineData: Photoshop keeps it in
    // the document's `Txt2` (see `applyTxt2`). We write and read the same way, so Photoshop reads
    // our kerning as we do and Photoshop's own fields round-trip unchanged. (The mode of the last
    // character has no slot and reads back as Metrics.)

    /// Reads EngineData's kerning fields back into the model (see the notes above). `incoming` is
    /// per EngineData style run: (UTF-8 length in the engine text, `AutoKerning`, `Kerning`).
    static func kerningFromPairs(_ text: String, _ runs: [TextRun], _ incoming: [(Int, Bool, Float)]) -> [TextRun] {
        if runs.isEmpty { return runs }
        // An empty text has no character to carry a manual kern or "no automatic kerning": its
        // style run reads as Metrics, the only thing EngineData can say for it.
        if text.isEmpty {
            return runs.map { r in
                var r = r
                if r.style.kerning == .off { r.style.kerning = .metrics }
                return r
            }
        }
        // Byte offset of every character, plus the trailing break.
        var starts: [Int] = []
        var b = 0
        for c in text.unicodeScalars {
            starts.append(b)
            b += utf8Len(c)
        }
        starts.append(b)
        let n = starts.count - 1
        var kern = [Float](repeating: 0, count: n)
        var off = [Bool](repeating: false, count: n)
        var si = 0
        var segEnd = incoming.first?.0 ?? 0
        for (j, b) in starts.enumerated() {
            while b >= segEnd && si < incoming.count {
                si += 1
                segEnd = satAdd(segEnd, incoming[safe: si]?.0 ?? 0)
            }
            guard let (_, auto, k) = incoming[safe: si] else { break }
            if k != 0, j >= 1, j - 1 < n {
                kern[j - 1] = k
                off[j - 1] = true
            }
            if !auto, j >= 2, j - 2 < n { off[j - 2] = true }
        }
        var ri = 0
        var runEnd = runs.first?.len ?? 0
        var out: [TextRun] = []
        for c in 0 ..< n {
            let (b, len) = (starts[c], starts[c + 1] - starts[c])
            while b >= runEnd && ri + 1 < runs.count {
                ri += 1
                runEnd = satAdd(runEnd, runs[safe: ri]?.len ?? 0)
            }
            guard let r = runs[safe: ri] else { break }
            let k = kern[safe: c] ?? 0
            let kerning: Kerning = (off[safe: c] ?? false) ? .off : .metrics
            if let last = out.last, last.style.kern == k, last.style.kerning == kerning, sameButKerning(last.style, r.style) {
                out[out.count - 1].len += len
            } else {
                var style = r.style
                style.kerning = kerning
                style.kern = k
                out.append(TextRun(len: len, style: style))
            }
        }
        return out
    }

    /// Whether two styles differ at most in their kerning.
    static func sameButKerning(_ a: CharStyle, _ b: CharStyle) -> Bool {
        var x = a
        x.kerning = b.kerning
        x.kern = b.kern
        return x == b
    }

    // MARK: - Txt2

    /// Applies what Photoshop keeps only in `Txt2` to `layer`, read from `tysh`: the automatic
    /// kerning modes (EngineData writes Optical and "0" alike as `AutoKerning true`) and the
    /// OpenType settings besides (discretionary) ligatures: stylistic sets, contextual
    /// alternates, swashes and the rest (`txt2Features`), which Photoshop leaves out of
    /// EngineData. Only when the layer's `TextIndex` entry still holds the layer's text (an edit
    /// elsewhere leaves `Txt2` stale).
    ///
    /// Observed layout: `Txt2 /1` is the list of text objects; an object's `/0` is its text model
    /// with `/0` the text (`\r` breaks, trailing `\r`) and `/6 /0` its style runs, each
    /// `<< /0 << /0 << … /6 <<style>> >> >> /1 utf16-length >>`; style key `/11` is the auto-kern
    /// mode of the pair after each character: 0 manual, 1 metrics, 2 optical.
    public static func applyTxt2(_ layer: inout TextLayer, tysh: [UInt8], txt2: PSDEngineData) {
        guard let index = parseTySh(tysh).flatMap({ rawTextIndex($0.text) }),
              let model = txt2.at("1", "1")?.arr?[safe: index]?.get("0"),
              let text = model.get("0")?.str,
              same(toModelBreaks(strippingCR(text)), layer.text),
              let styleRuns = model.at("6", "0")?.arr else { return }
        let styles: [(Double, E?)] = styleRuns.map { ($0.get("1")?.f64 ?? 0, $0.at("0", "0", "6")) }
        let lens = utf16ToByteLengths(text, styles.map(\.0))
        // Txt2 style per byte segment, then split the model runs at segment boundaries.
        let segs: [(Int, E?)] = zip(lens, styles.map(\.1)).filter { $0.0 > 0 }
        let runs = layer.charRuns()
        var out: [TextRun] = []
        var si = 0
        var segEnd = segs.first?.0 ?? Int.max
        var at = 0
        for r in runs {
            let end = at + r.len
            while at < end {
                while at >= segEnd && si + 1 < segs.count {
                    si += 1
                    segEnd = satAdd(segEnd, segs[safe: si]?.0 ?? 0)
                }
                let pieceEnd = at < segEnd ? min(end, segEnd) : end
                var style = r.style
                let txt2Style: E? = at < segEnd ? (segs[safe: si]?.1 ?? nil) : nil
                // Txt2 has the exact mode (EngineData's reading also marks neighbours of manual
                // kerns manual, like Photoshop's legacy reader).
                switch txt2Style?.get("11")?.i64 {
                case 0?: style.kerning = .off
                case 1?: style.kerning = .metrics
                case 2?: style.kerning = .optical
                default: break
                }
                if let st = txt2Style { addTxt2Features(&style, st) }
                let len = pieceEnd - at
                if let last = out.last, last.style == style {
                    out[out.count - 1].len += len
                } else {
                    out.append(TextRun(len: len, style: style))
                }
                at = pieceEnd
            }
        }
        // An empty type layer has one zero-length run holding its font and size: there is nothing
        // to split, and replacing the runs with none would lose them (photocraft drops it).
        if out.isEmpty { return }
        layer.runs = out
        layer.syncSummary()
    }

    /// Sets in `style` the OpenType features a `Txt2` style dictionary turns on (`txt2Features`
    /// and the Stylistic Sets mask). A feature the style already sets keeps its value. A flag
    /// that is off changes nothing, except Contextual Alternates: shapers apply `calt` by
    /// default, Photoshop only when it is on (its default is off), so off is written as `calt` 0.
    static func addTxt2Features(_ style: inout CharStyle, _ txt2Style: E) {
        func set(_ tag: String, _ value: UInt16) {
            if !style.features.contains(where: { same($0.tag, tag) }) {
                style.features.append(FontFeature(tag: tag, value: value))
            }
        }
        for (key, tag) in txt2Features {
            switch txt2Style.get(key)?.flag {
            case true?: set(tag, 1)
            case false? where tag == "calt": set(tag, 0)
            default: break
            }
        }
        // A mask beyond the 20 sets is not Photoshop's: ignore it.
        let sets = txt2Style.get(txt2StylisticSets)?.i64.flatMap { (0 ..< (1 << 20)).contains($0) ? $0 : nil } ?? 0
        for n in 0 ..< 20 where sets & (1 << Int64(n)) != 0 {
            set("ss" + (n + 1 < 10 ? "0" : "") + String(n + 1), 1)
        }
    }

    /// The frame (`Txt2 /0 /8 /0` entry) of text object `index`: its rendered frame's `/10`
    /// names it.
    static func txt2Frame(_ txt2: E, _ index: Int) -> E? {
        guard let object = txt2.at("1", "1")?.arr?[safe: index],
              let frames = object.at("1", "2")?.arr?.first?.get("6")?.arr,
              let frame = frames.lazy.compactMap({ $0.get("10")?.i64 }).first,
              frame >= 0 else { return nil }
        return txt2.at("0", "8", "0")?.arr?[safe: usizeIndex(frame)]?.get("0")
    }

    /// Places `layer` where Photoshop draws it when the text object's frame in `Txt2` is moved
    /// (#1317). Recent Photoshop keeps a type layer's position partly in its `Txt2` frame: a
    /// matrix (`/2 /2`) from the frame's space to the `TySh` text space and, for point text, the
    /// anchor (`/0`), while EngineData's `PointBase` stays at the origin and `BoxBounds` stays in
    /// the frame's space. Ignoring them put the text far from Photoshop's pixels (off the canvas,
    /// so it "disappeared" as soon as an edit started), and point text a line too high and off
    /// its alignment anchor. Only when the layer's `TextIndex` entry still holds the layer's
    /// text, as for `applyTxt2`, and the frame agrees with the `TySh` `bounds`.
    public static func applyTxt2Frame(_ layer: inout TextLayer, tysh: [UInt8], txt2: PSDEngineData) {
        guard let t = parseTySh(tysh), let index = rawTextIndex(t.text) else { return }
        guard let text = txt2.at("1", "1")?.arr?[safe: index]?.at("0", "0")?.str,
              same(toModelBreaks(strippingCR(text)), layer.text),
              let frame = txt2Frame(txt2, index) else { return }
        let m = arrF(frame.at("2", "2"))
        let matrix = m.count == 6 && m.allSatisfy(\.isFinite) ? PCAffine(m: m) : .identity
        let at: PCAffine
        switch layer.shape {
        case .point:
            let p = arrF(frame.get("0"))
            at = p.count == 2 && p.allSatisfy(\.isFinite) ? .translate(p[0], p[1]) : .identity
        case .box:
            at = .identity
        }
        let toText = matrix.mul(at)
        if toText == .identity || abs(toText.determinant) <= 1e-9 { return }
        // The frame's origin (point text: the anchor; box text: the box's top left) must land in
        // the text-space `bounds` Photoshop wrote beside it, and not already be there without it.
        // A `TySh` PhotoCraft rewrote (an edited or moved layer whose text is unchanged keeps its
        // old `Txt2` object and frame) already has the frame folded into its transform and its
        // `bounds` near the origin: applying the frame again would move it twice.
        let origin: PCPoint
        switch layer.shape {
        case .point:
            origin = PCPoint(0, 0)
        case .box:
            let b = engineData(t.text).map { e in
                arrF(e.at("EngineDict", "Rendered", "Shapes", "Children")?.arr?.first?.at("Cookie", "Photoshop", "BoxBounds"))
            } ?? []
            guard b.count >= 2 else { return }
            origin = PCPoint(b[0], b[1])
        }
        guard let r = descriptorRect(t.text, "bounds") else { return }
        let (l, top, right, bottom) = (r[0], r[1], r[2], r[3])
        func inside(_ p: PCPoint) -> Bool { p.x >= l - 1 && p.x <= right + 1 && p.y >= top - 1 && p.y <= bottom + 1 }
        if inside(origin) || !inside(toText.apply(origin)) { return }
        // From the file's own transform: the frame's anchor is exact, so it replaces the ink-box
        // estimate `legacyPointOrigin` made for such point text (#1469), which put the baseline
        // at the ink's top and the anchor at the ink's left whatever the alignment.
        layer.transform = t.transform.mul(toText)
    }

    /// The layer's text-object number in the document's `Txt2` block, when its `TySh` names one
    /// within `0...maxTextIndex`. PSD export keeps a preserved number — its regenerated `Txt2`
    /// object sits at that slot, and `applyTxt2` looks the slot up — and numbers layers without
    /// one (or with a file-controlled out-of-range one) afresh.
    public static func textIndex(_ tysh: [UInt8]) -> Int32? {
        guard let t = parseTySh(tysh), case let .integer(i)? = t.text["TextIndex"], (0 ... maxTextIndex).contains(i) else { return nil }
        return i
    }

    /// Rewrites a `TySh`'s `TextIndex`: the layer's text-object number in the document's `Txt2`
    /// block (`buildTxt2` writes them in this order). nil when `tysh` doesn't parse.
    ///
    /// Only the index changes: a block that already names `index` comes back as it is, and
    /// otherwise the rest of the block keeps its bytes (versions, warp and the bytes after it,
    /// through PCPSD's lossless `PSDTypeTool`). photocraft rewrites the whole block in its
    /// normalised form, which drops the padding Photoshop leaves after the bounds.
    public static func setTextIndex(_ tysh: [UInt8], _ index: Int32) -> [UInt8]? {
        guard var t = parseTySh(tysh) else { return nil }
        if case let .integer(i)? = t.text["TextIndex"], i == index { return tysh }
        if var lossless = try? PSDTypeTool(bytes: Data(tysh)) {
            lossless.text.descriptor.set("TextIndex", .integer(index))
            return [UInt8](lossless.serialized())
        }
        t.text.set("TextIndex", .integer(index))
        return writeTySh(t)
    }
}
