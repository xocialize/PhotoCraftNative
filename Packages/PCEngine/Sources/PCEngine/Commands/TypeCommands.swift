// Port of photocraft-engine (crates/engine/src/type_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// `type.*` commands: create and edit type (text) layers, plus the helpers the other type modules
// share (character/paragraph keys, run splitting, text replacement, re-rendering, targets).
//
// Text offsets in parameters and results are **character** indices (Unicode scalar values), so
// JSON clients never split a UTF-8 sequence. Sizes, leading, indents and spacing are in points
// (converted with the document resolution); tracking is in 1/1000 em; positions and boxes are
// document pixels. Every edit re-renders the layer with PCPlatform's CoreText `TextEngine`
// (photocraft-text in photocraft). photocraft also regenerates the PSD `TySh` data on every edit;
// PSD text serialisation belongs to PCPSD/PCIO, so `refresh` drops the stale `psdRaw` instead.
//
// `TypeCommands.Layout` is photocraft-text's `TextLayout` geometry (line space, clusters, carets,
// hit testing) computed from PCPlatform's CoreText layout, for type.info, the caret queries and
// the point ⇄ paragraph conversions.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import PCPlatform

enum TypeCommands: CommandModule {
    static let name = "type_cmds"
    static let m = name

    // MARK: Limits

    /// Photoshop's manual kerning range (1/1000 em).
    static let kernMin = -1000.0
    static let kernMax = 10_000.0
    static let sizeMinPt = 0.1
    static let sizeMaxPt = 1296.0
    static let trackingMin = -1000.0
    static let trackingMax = 10_000.0

    /// photocraft-text's `DEFAULT_FAMILY` (Inter there; PCPlatform's default face here).
    static var defaultFamily: String { FontCatalog.defaultFamily }

    /// Runs a font or text-engine call. No lock: PCPlatform's `FontCatalog` caches what it reads
    /// from CoreText's font registry and sends the registry one query at a time itself, so
    /// concurrent text work is safe (this used to serialise every call, when the catalog asked the
    /// font daemon on every character lookup and parallel callers stalled its XPC replies).
    @discardableResult
    static func fonts<R>(_ body: () throws -> R) rethrows -> R { try body() }

    // MARK: Module state

    /// Type › Save Default Type Styles (photocraft `Session::type_defaults`).
    struct Defaults: Sendable, Equatable {
        var char: CharStyle
        var para: ParagraphStyle
    }

    enum DefaultsKey: StateKey {
        static let defaultValue: Defaults? = nil
    }

    // MARK: Small helpers

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document open" : nil }

    /// photocraft `layer_id`: the `"layer"` param, else the active layer.
    static func layerId(_ s: Session, _ p: JSONValue) throws -> LayerId {
        if let id = p["layer"]?.uint64Value { return LayerId(id) }
        guard let id = s.active?.activeLayer else { throw EngineError.other("no active layer") }
        return id
    }

    static func f32p(_ p: JSONValue, _ k: String) -> Float? { p[k]?.doubleValue.map { Float($0) } }

    /// The type layer `id` of `doc`.
    static func textOf(_ doc: Document, _ id: LayerId) -> TextLayer? {
        if case .text(let t)? = doc.layer(id)?.content { return t }
        return nil
    }

    static func isText(_ l: Layer) -> Bool {
        if case .text = l.content { return true }
        return false
    }

    /// Mutates the type layer `id` in place; nil when it isn't one.
    @discardableResult
    static func withText<R>(_ doc: inout Document, _ id: LayerId, _ body: (inout TextLayer) throws -> R) rethrows -> R? {
        let r: R?? = try doc.updateLayer(id) { l in try l.withText(body) }
        return r ?? nil
    }

    /// Every type layer of `doc`, in walk order (bottom to top).
    static func textLayerIds(_ doc: Document) -> [LayerId] {
        doc.walk().filter { isText($0.layer) }.map(\.layer.id)
    }

    /// `"layer N is a Pixel layer, not a type layer"`.
    static func notTypeLayer(_ id: LayerId, _ c: LayerContent) -> EngineError {
        .other("layer \(id.rawValue) is \(c.article) \(c.kindName) layer, not a type layer")
    }

    /// photocraft's `color`: `[r,g,b(,a)]` or `"#rrggbb(aa)"`.
    static func color(_ v: JSONValue) -> PCColor? {
        switch v {
        case .array(let a) where a.count >= 3:
            let c = a.map { Float($0.doubleValue ?? 0) }
            return PCColor.rgb(c[0], c[1], c[2], c.count > 3 ? c[3] : 1)
        case .string(let s):
            var h = Substring(s)
            while h.hasPrefix("#") { h = h.dropFirst() }
            let b = Array(h.utf8)
            func byte(_ i: Int) -> Float? {
                guard i + 2 <= b.count, let v = UInt8(String(decoding: b[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
                return Float(v) / 255
            }
            switch b.count {
            case 6:
                guard let r = byte(0), let g = byte(2), let bl = byte(4) else { return nil }
                return PCColor.rgb(r, g, bl, 1)
            case 8:
                guard let r = byte(0), let g = byte(2), let bl = byte(4), let a = byte(6) else { return nil }
                return PCColor.rgb(r, g, bl, a)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    // MARK: Text offsets (UTF-8 bytes ⇄ characters)

    /// Normalises line breaks to `\n`.
    static func normText(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Byte offset of character `ci` (the text length past the end).
    static func byteAt(_ text: String, _ ci: Int) -> Int {
        var b = 0, i = 0
        for u in text.unicodeScalars {
            if i == ci { return b }
            b += UTF8.width(u)
            i += 1
        }
        return b
    }

    /// Character index of byte `bi`, floored to a character boundary.
    static func charAt(_ text: String, _ bi: Int) -> Int {
        var b = 0, i = 0
        for u in text.unicodeScalars {
            let w = UTF8.width(u)
            if b + w > bi { return i }
            b += w
            i += 1
        }
        return i
    }

    static func charCount(_ text: String) -> Int { text.unicodeScalars.count }

    static func endsWithBreak(_ text: String) -> Bool { text.utf8.last == 0x0A || text.utf8.last == 0x0D }

    /// A non-negative index param as `Int` (photocraft `as_u64() as usize`).
    static func index(_ v: JSONValue?) -> Int? { v?.uint64Value.map { Int(clamping: $0) } }

    /// `range: [start, end]` in characters → byte range (whole text when absent).
    static func rangeParam(_ text: String, _ p: JSONValue) -> (Int, Int) {
        guard let r = p["range"]?.arrayValue, r.count == 2 else { return (0, text.utf8.count) }
        let a = index(r[0]) ?? 0
        let b = index(r[1]) ?? a
        return (byteAt(text, min(a, b)), byteAt(text, max(a, b)))
    }

    /// Replaces UTF-8 bytes `a..<b` of `s`.
    static func replaceBytes(_ s: inout String, _ a: Int, _ b: Int, _ new: String) {
        var bytes = Array(s.utf8)
        let a = min(max(a, 0), bytes.count), b = min(max(b, a), bytes.count)
        bytes.replaceSubrange(a..<b, with: Array(new.utf8))
        s = String(decoding: bytes, as: UTF8.self)
    }

    /// The UTF-8 bytes `a..<b` of `s` as a string.
    static func slice(_ s: String, _ a: Int, _ b: Int) -> String {
        let bytes = Array(s.utf8)
        let a = min(max(a, 0), bytes.count), b = min(max(b, a), bytes.count)
        return String(decoding: bytes[a..<b], as: UTF8.self)
    }

    /// Byte ranges of paragraphs, each including its `\r`, `\n` or `\r\n` terminator; text ending
    /// with a break yields a final empty paragraph (photocraft-text `split_paragraphs`).
    static func splitParagraphs(_ text: String) -> [Range<Int>] {
        let b = Array(text.utf8)
        var v: [Range<Int>] = []
        var start = 0, i = 0
        while i < b.count {
            switch b[i] {
            case 0x0D:
                let end = i + 1 < b.count && b[i + 1] == 0x0A ? i + 2 : i + 1
                v.append(start..<end)
                start = end
                i = end
            case 0x0A:
                v.append(start..<(i + 1))
                start = i + 1
                i += 1
            default:
                i += 1
            }
        }
        v.append(start..<b.count)
        return v
    }

    // MARK: Validation

    /// Validates the `kerning` key of character params: a number in kernMin…kernMax or
    /// `"metrics"`, `"optical"`, `"off"` (`"none"`, `"0"`).
    static func checkKerning(_ p: JSONValue) -> String? {
        switch p["kerning"] {
        case nil:
            return nil
        case .number(let k)?:
            if (kernMin...kernMax).contains(k) { return nil }
            return "kerning must be between \(fmt(kernMin)) and \(fmt(kernMax)) (1/1000 em)"
        case .string(let v)? where ["metrics", "optical", "off", "none", "0"].contains(v.lowercased()):
            return nil
        default:
            return "kerning must be a number (1/1000 em) or \"metrics\", \"optical\" or \"off\""
        }
    }

    /// Validates text metrics that can otherwise exceed the rasterizer's supported range.
    static func checkSizeTracking(_ p: JSONValue) -> String? {
        if let v = p["size"] {
            guard let size = v.doubleValue, size.isFinite, (sizeMinPt...sizeMaxPt).contains(size) else {
                return "size must be between \(fmt(sizeMinPt)) and \(fmt(sizeMaxPt)) pt"
            }
        }
        if let v = p["tracking"] {
            guard let tr = v.doubleValue, tr.isFinite, (trackingMin...trackingMax).contains(tr) else {
                return "tracking must be between \(fmt(trackingMin)) and \(fmt(trackingMax)) (1/1000 em)"
            }
        }
        return nil
    }

    /// Rust's `{}` of an f64 (`-1000`, `0.1`).
    static func fmt(_ v: Double) -> String { v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v) }

    // MARK: Character and paragraph keys

    /// The PostScript name of the installed face of `family` at exactly `weight`/`italic` (#3556).
    static func installedPostscript(_ family: String, _ weight: UInt16, _ italic: Bool) -> String? {
        fonts { FontCatalog.faces(family: family) }.first { $0.italic == italic && $0.weight == Int(weight) }?.postScriptName
    }

    /// Applies character-style keys from JSON. Returns true if any key was present.
    @discardableResult
    static func applyCharProps(_ s: inout CharStyle, _ p: JSONValue) -> Bool {
        var any = false
        let fontKey = ["font", "family", "fontStyle", "weight", "italic"].contains { p[$0] != nil }
        if let v = (p["font"] ?? p["family"])?.stringValue {
            s.fontFamily = v
            s.postscriptName = nil
            any = true
        }
        if let v = p["fontStyle"]?.stringValue {
            s.fontStyle = v
            s.postscriptName = nil
            // The style sets the weight, so a weight slider value set earlier stops overriding it.
            s.variations.removeAll { $0.axis == "wght" }
            let l = v.lowercased()
            s.italic = l.contains("italic") || l.contains("oblique")
            let g = FontCatalog.guess(postScriptName: "X-" + v.replacingOccurrences(of: " ", with: ""))
            s.weight = UInt16(clamping: g.weight)
            if let face = fonts({ FontCatalog.named(family: s.fontFamily, style: v) }) {
                s.weight = UInt16(clamping: face.weight)
                s.italic = face.italic
                s.postscriptName = face.postScriptName
            }
            any = true
        }
        if let v = p["weight"]?.doubleValue {
            let weight = UInt16(min(max(v, 1), 1000))
            if s.weight != weight {
                s.postscriptName = nil
                s.fontStyle = ""
            }
            s.variations.removeAll { $0.axis == "wght" }
            s.weight = weight
            any = true
        }
        if let v = p["italic"]?.boolValue {
            if s.italic != v {
                s.postscriptName = nil
                s.fontStyle = ""
            }
            s.italic = v
            any = true
        }
        if let v = p["postscriptName"]?.stringValue {
            s.postscriptName = v
            any = true
        }
        // A font named by family has no PostScript name yet: fill in the installed face's (#3556).
        if fontKey && s.postscriptName == nil {
            s.postscriptName = installedPostscript(s.fontFamily, s.weight, s.italic)
        }
        if let v = f32p(p, "size") {
            s.sizePt = max(v, 0.01)
            any = true
        }
        if let c = p["color"].flatMap(color) {
            s.color = c
            any = true
        }
        if let v = f32p(p, "tracking") {
            s.tracking = v
            any = true
        }
        switch p["leading"] {
        case .null?:
            s.leadingPt = nil
            any = true
        case .string("auto")?:
            s.leadingPt = nil
            any = true
        case .number(let x)?:
            s.leadingPt = Float(x)
            any = true
        default:
            break
        }
        if let v = f32p(p, "baselineShift") { s.baselineShiftPt = v; any = true }
        if let v = f32p(p, "horizontalScale") { s.horizontalScale = max(v / 100, 0.01); any = true }
        if let v = f32p(p, "verticalScale") { s.verticalScale = max(v / 100, 0.01); any = true }
        let flags: [(String, WritableKeyPath<CharStyle, Bool>)] = [
            ("underline", \.underline), ("strikethrough", \.strikethrough), ("fauxBold", \.fauxBold), ("fauxItalic", \.fauxItalic),
            ("ligatures", \.ligatures), ("discretionaryLigatures", \.discretionaryLigatures),
        ]
        for (k, kp) in flags {
            if let v = p[k]?.boolValue { s[keyPath: kp] = v; any = true }
        }
        switch p["kerning"] {
        // A number is Photoshop's manual kerning: no automatic pair kerning plus the value.
        case .number(let k)?:
            if k.isFinite {
                s.kerning = .off
                s.kern = Float(min(max(k, kernMin), kernMax))
                any = true
            }
        case .string(let v)?:
            switch v.lowercased() {
            case "optical": s.kerning = .optical
            case "none", "off", "0": s.kerning = .off
            default: s.kerning = .metrics
            }
            s.kern = 0
            any = true
        default:
            break
        }
        if let v = p["caps"]?.stringValue {
            switch v {
            case "small", "smallCaps": s.caps = .smallCaps
            case "all", "allCaps": s.caps = .allCaps
            default: s.caps = .normal
            }
            any = true
        }
        if case .object(let m)? = p["features"] {
            for tag in m.keys.sorted() {
                guard let v = m[tag] else { continue }
                let value = v.uint64Value.map { UInt16(truncatingIfNeeded: $0) } ?? v.boolValue.map { $0 ? 1 : 0 } ?? 1
                s.features.removeAll { $0.tag == tag }
                s.features.append(FontFeature(tag: tag, value: value))
            }
            any = true
        }
        if case .object(let m)? = p["variations"] {
            for axis in m.keys.sorted() {
                s.variations.removeAll { $0.axis == axis }
                if let x = m[axis]?.doubleValue { s.variations.append(FontVariation(axis: axis, value: Float(x))) }
            }
            any = true
        }
        if let v = p["language"] {
            s.language = v.stringValue
            any = true
        }
        return any
    }

    /// Applies paragraph-style keys from JSON. Returns true if any key was present.
    @discardableResult
    static func applyParaProps(_ s: inout ParagraphStyle, _ p: JSONValue) -> Bool {
        var any = false
        if let v = p["align"]?.stringValue {
            switch v {
            case "center": s.align = .center
            case "right": s.align = .right
            case "justify", "justifyLeft": s.align = .justifyLeft
            case "justifyCenter": s.align = .justifyCenter
            case "justifyRight": s.align = .justifyRight
            case "justifyAll": s.align = .justifyAll
            default: s.align = .left
            }
            any = true
        }
        let fields: [(String, WritableKeyPath<ParagraphStyle, Float>)] = [
            ("firstLineIndent", \.firstLineIndentPt), ("startIndent", \.startIndentPt), ("endIndent", \.endIndentPt),
            ("spaceBefore", \.spaceBeforePt), ("spaceAfter", \.spaceAfterPt), ("autoLeading", \.autoLeading),
        ]
        for (k, kp) in fields {
            if let v = f32p(p, k) {
                s[keyPath: kp] = k == "autoLeading" ? v / 100 : v
                any = true
            }
        }
        if let v = p["direction"]?.stringValue {
            switch v {
            case "ltr": s.direction = .ltr
            case "rtl": s.direction = .rtl
            default: s.direction = .auto
            }
            any = true
        }
        if let v = p["hyphenate"]?.boolValue {
            s.hyphenate = v
            any = true
        }
        return any
    }

    // MARK: Runs

    static func pushMerge<S: Equatable>(_ out: inout [(Int, S)], _ len: Int, _ st: S) {
        if len == 0 { return }
        if let last = out.last, last.1 == st {
            out[out.count - 1].0 += len
        } else {
            out.append((len, st))
        }
    }

    /// Applies `f` to the character style of bytes `a..<b` (splitting runs at the edges).
    static func styleRange(_ t: inout TextLayer, _ a: Int, _ b: Int, _ f: (inout CharStyle) -> Void) {
        // A reversed range styles nothing (#714).
        let b = max(b, a)
        let runs = t.charRuns()
        if t.text.isEmpty {
            var st = runs.first?.style ?? CharStyle()
            f(&st)
            t.runs = [TextRun(len: 0, style: st)]
            t.syncSummary()
            return
        }
        var out: [(Int, CharStyle)] = []
        var at = 0
        for r in runs {
            let (rs, re) = (at, at + r.len)
            at = re
            let ca = min(max(a, rs), re), cb = min(max(b, rs), re)
            pushMerge(&out, ca - rs, r.style)
            var st = r.style
            f(&st)
            pushMerge(&out, cb - ca, st)
            pushMerge(&out, re - cb, r.style)
        }
        t.runs = out.map { TextRun(len: $0.0, style: $0.1) }
        t.syncSummary()
    }

    /// Applies `f` to every paragraph touching bytes `a..<b` (paragraph runs follow paragraphs).
    static func styleParagraphs(_ t: inout TextLayer, _ a: Int, _ b: Int, _ f: (inout ParagraphStyle) -> Void) {
        let old = t.paragraphRuns()
        var starts: [Int] = []
        var acc = 0
        for r in old { starts.append(acc); acc += r.len }
        func styleAt(_ off: Int) -> ParagraphStyle {
            let i = starts.lastIndex { $0 <= off } ?? 0
            return i < old.count ? old[i].style : ParagraphStyle()
        }
        var out: [(Int, ParagraphStyle)] = []
        let n = t.text.utf8.count
        let trailingBreak = endsWithBreak(t.text)
        for pr in splitParagraphs(t.text) {
            var st = styleAt(pr.lowerBound)
            let terminalEmpty = pr.isEmpty
            let touches = (pr.lowerBound < b && pr.upperBound > a)
                || (a == b && a >= pr.lowerBound && (a < pr.upperBound || terminalEmpty || (pr.upperBound == n && !trailingBreak)))
            if touches { f(&st) }
            if terminalEmpty && trailingBreak {
                // This paragraph has no bytes but keeps its own style for the next typed
                // character and for the PSD's final paragraph marker.
                out.append((0, st))
            } else {
                pushMerge(&out, pr.count, st)
                if out.isEmpty { out.append((0, st)) }
            }
        }
        t.paragraphs = out.map { ParagraphRun(len: $0.0, style: $0.1) }
    }

    /// Replaces bytes `a..<b` with `new`, keeping styles: inserted text takes the style of the
    /// character before it (or after it at the start).
    static func replaceText(_ t: inout TextLayer, _ a: Int, _ b: Int, _ new: String) {
        func adjust<S: Equatable>(_ runs: [(Int, S)], _ a: Int, _ b: Int, _ ins: Int, _ trailingParagraph: Bool) -> [(Int, S)] {
            var out: [(Int, S)] = []
            let total = runs.reduce(0) { $0 + $1.0 }
            let host: Int
            if trailingParagraph && a == b && (runs.last.map { $0.0 == 0 } ?? false) && a == total {
                // Inserted text belongs to a styled final empty paragraph, not to the preceding
                // paragraph whose break ends at this byte offset.
                host = runs.count - 1
            } else {
                var s = 0
                var found: Int?
                for (i, r) in runs.enumerated() {
                    let e = s + r.0
                    if a == 0 ? (e > 0 || s == 0) : (a > s && a <= e) { found = i; break }
                    s = e
                }
                host = found ?? 0
            }
            var at = 0
            for (i, (len, st)) in runs.enumerated() {
                let (rs, re) = (at, at + len)
                at = re
                let keep = (min(max(a, rs), re) - rs) + (re - min(max(b, rs), re))
                pushMerge(&out, keep + (i == host ? ins : 0), st)
            }
            return out
        }
        let n = t.text.utf8.count
        let a0 = min(a, n)
        let (a, b) = (a0, max(min(b, n), a0))
        let new = normText(new)
        let cr = t.charRuns().map { ($0.len, $0.style) }
        let pr = t.paragraphRuns().map { ($0.len, $0.style) }
        let firstC = cr.first?.1 ?? CharStyle()
        let firstP = pr.first?.1 ?? ParagraphStyle()
        let trailingStyle = endsWithBreak(t.text) ? pr.last.flatMap { $0.0 == 0 ? $0.1 : nil } : nil
        var c2 = adjust(cr, a, b, new.utf8.count, false)
        var p2 = adjust(pr, a, b, new.utf8.count, true)
        replaceBytes(&t.text, a, b, new)
        if endsWithBreak(t.text), let style = trailingStyle { p2.append((0, style)) }
        if c2.isEmpty { c2.append((t.text.utf8.count, firstC)) }
        if p2.isEmpty { p2.append((t.text.utf8.count, firstP)) }
        t.runs = c2.map { TextRun(len: $0.0, style: $0.1) }
        t.paragraphs = p2.map { ParagraphRun(len: $0.0, style: $0.1) }
        t.syncSummary()
    }

    // MARK: Rendering

    /// Re-renders the layer's pixels (photocraft `refresh`). The PSD `TySh` data photocraft
    /// regenerates here is PCPSD's; the stale copy is dropped so an export rebuilds it from the model.
    static func refresh(_ doc: Document, _ t: inout TextLayer) {
        fonts { TextEngine.renderLayer(&t, dpi: Double(doc.resolutionDpi), format: doc.pixelFormat) }
        t.psdRaw = nil
    }

    /// Runs `f` on a type layer as one undo step. `f` may set an explicit layer name (`type.edit`'s
    /// `name`), applied in the same step; otherwise an auto-named layer follows its text.
    static func withTextLayer<R>(_ s: Session, _ p: JSONValue, _ label: String,
                                 _ f: (inout TextLayer, Document, inout String?) throws -> R) throws -> R {
        let id = try layerId(s, p)
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        guard let layer = doc.layer(id) else { throw EngineError.noLayer(id) }
        if doc.effectiveLocks(id).all {
            throw EngineError.other("Could not complete your request because the layer \"\(layer.name)\" is locked")
        }
        var damage: PixelRect?
        let r = try s.edit(label) { doc, _ -> R in
            let snapshot = doc
            let out: R? = try doc.updateLayer(id) { l -> R in
                let autoNamed = isAutoNamed(l)
                guard isText(l) else { throw notTypeLayer(id, l.content) }
                var name: String?
                let r: R? = try l.withText { t -> R in
                    let before = t.cache?.tileBounds
                    var rename: String?
                    let r = try f(&t, snapshot, &rename)
                    refresh(snapshot, &t)
                    // Only this layer's pixels changed: the canvas recomposites their old and new area (#124).
                    if let a = before, let b = t.cache?.tileBounds { damage = a.union(b) } else { damage = nil }
                    name = rename ?? (autoNamed ? layerName(t.text) : nil)
                    return r
                }
                guard let r else { throw notTypeLayer(id, l.content) }
                if let name { l.name = name }
                return r
            }
            guard let out else { throw EngineError.noLayer(id) }
            return out
        }
        s.noteDamage(damage)
        return r
    }

    /// Direct formatting follows the selected Type layers, while an explicit layer or character
    /// range keeps its single-layer scope. Selected groups are not expanded.
    static func formatTargets(_ s: Session, _ p: JSONValue) throws -> [LayerId] {
        guard let st = s.active else { throw EngineError.noDocument }
        let single = p["layer"] != nil || (p["range"] != nil && p["layers"] == nil)
        let ids: [LayerId]
        if single {
            ids = [try layerId(s, p)]
        } else if let value = p["layers"] {
            guard let a = value.arrayValue else { throw EngineError.other("layers must be an array of layer IDs") }
            ids = try a.map { v in
                guard let n = v.uint64Value else { throw EngineError.other("layers must contain layer IDs") }
                return LayerId(n)
            }
        } else {
            ids = st.selectedLayers
        }
        var targets: [LayerId] = []
        for id in ids {
            guard let l = st.doc.layer(id) else { throw EngineError.noLayer(id) }
            if isText(l) {
                if !targets.contains(id) { targets.append(id) }
            } else if single {
                throw notTypeLayer(id, l.content)
            }
        }
        if targets.isEmpty { throw EngineError.other("select a type layer") }
        return targets
    }

    static let hasFormatTarget: CommandEnabled = { s, _ in
        do { _ = try formatTargets(s, .null); return nil } catch { return EngineError.wrap(error).description }
    }

    /// One history step for a formatting batch.
    @discardableResult
    static func withTextTargets(_ s: Session, _ p: JSONValue, _ label: String,
                                _ f: (inout TextLayer, (Int, Int)) throws -> Void) throws -> [LayerId] {
        let ids = try formatTargets(s, p)
        let perLayerRange = p["layers"] == nil || p["layer"] != nil
        let damage: PixelRect? = try s.edit(label) { doc, _ in
            let snapshot = doc
            var damage: PixelRect? = .empty
            for id in ids {
                let done: Bool? = try withText(&doc, id) { t in
                    let before = t.cache?.tileBounds
                    let range = perLayerRange ? rangeParam(t.text, p) : (0, t.text.utf8.count)
                    try f(&t, range)
                    refresh(snapshot, &t)
                    // An unknown old/new cache keeps the edit's full-refresh fallback.
                    if let all = damage, let a = before, let b = t.cache?.tileBounds { damage = all.union(a).union(b) } else { damage = nil }
                    return true
                }
                if done == nil { throw EngineError.noLayer(id) }
            }
            return damage
        }
        s.noteDamage(damage)
        return ids
    }

    /// UI size/leading are measured after the layer transform; command callers otherwise use points.
    static func shownStyleParams(_ t: TextLayer, _ p: JSONValue) throws -> JSONValue {
        guard p["metricsAsShown"]?.boolValue == true else { return p }
        let m = t.transform
        let sc = Float(abs(m.a * m.d - m.b * m.c).squareRoot())
        let scale = sc.isFinite && sc > 1e-3 ? Double(sc) : 1
        var params = p
        for key in ["size", "leading"] {
            if let value = p[key]?.doubleValue {
                let v = value / scale
                if !v.isFinite || abs(v) > Double(Float.greatestFiniteMagnitude) {
                    throw bad("type.setStyle", "shown size and leading must convert to finite point values")
                }
                params = params.setting(key, .number(v))
            }
        }
        return params
    }

    /// Whether a type layer still has the name it got from its text (#483).
    static func isAutoNamed(_ l: Layer) -> Bool {
        if case .text(let t) = l.content { return l.name == layerName(t.text) }
        return false
    }

    /// The name a type layer gets from its text: its first non-empty line, at most 40 characters.
    static func layerName(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var s = String(line)
            if s.hasSuffix("\r") { s.removeLast() }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let first = lines.first { !$0.isEmpty } ?? ""
        let name = String(String.UnicodeScalarView(first.unicodeScalars.prefix(40)))
        return name.isEmpty ? "Type Layer" : name
    }

    // MARK: Missing fonts (photocraft type_extra_cmds, used by info/create here)

    static func installedFamilies() -> Set<String> { Set(fonts { FontCatalog.families() }.map { $0.lowercased() }) }

    /// Font families used by a type layer that the font catalogue cannot supply.
    static func missingFontsInLayer(_ t: TextLayer, have: Set<String>? = nil) -> [String] {
        let have = have ?? installedFamilies()
        var out: [String] = []
        for r in t.charRuns() {
            let f = r.style.fontFamily
            if !f.isEmpty && !have.contains(f.lowercased()) && !out.contains(f) { out.append(f) }
        }
        return out
    }

    /// Font families used by type layers that the font catalogue cannot supply.
    static func missingFonts(_ doc: Document) -> [String] {
        let have = installedFamilies()
        var out: [String] = []
        for e in doc.walk() {
            guard case .text(let t) = e.layer.content else { continue }
            for f in missingFontsInLayer(t, have: have) where !out.contains(f) { out.append(f) }
        }
        return out
    }

    static func fontsToWarnings(_ fonts: [String]) -> [String] {
        fonts.map { "font '\($0)' is not installed; text may render using a fallback face" }
    }

    static func missingFontWarningsForLayer(_ t: TextLayer) -> [String] { fontsToWarnings(missingFontsInLayer(t)) }

    // MARK: Queries

    static func info(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try layerId(s, p)
        guard let d = s.active else { throw EngineError.noDocument }
        guard let l = d.doc.layer(id) else { throw EngineError.noLayer(id) }
        guard case .text(let t) = l.content else { throw EngineError.other("layer \(id.rawValue) is not a type layer") }
        let text = t.text
        var at = 0
        let runs: [JSONValue] = t.charRuns().map { r in
            defer { at += r.len }
            return ["start": .int(charAt(text, at)), "end": .int(charAt(text, at + r.len)), "style": .encoded(r.style)]
        }
        at = 0
        let paragraphs: [JSONValue] = t.paragraphRuns().map { r in
            defer { at += r.len }
            return ["start": .int(charAt(text, at)), "end": .int(charAt(text, at + r.len)), "style": .encoded(r.style)]
        }
        let layout = Layout(t, dpi: Double(d.doc.resolutionDpi))
        let lines: [JSONValue] = layout.lines.map { ln in
            ["start": .int(charAt(text, ln.range.lowerBound)), "end": .int(charAt(text, ln.range.upperBound)), "baseline": .number(ln.baseline),
             "x0": .number(ln.x0), "x1": .number(ln.x1), "ascent": .number(ln.ascent), "descent": .number(ln.descent)]
        }
        let bounds: JSONValue = t.cache.map { c in
            let r = c.contentBounds
            return [.int(r.x0), .int(r.y0), .int(r.x1), .int(r.y1)]
        } ?? .null
        let warnings = missingFontWarningsForLayer(t)
        var out: JSONValue = [
            "layer": .id(id), "text": .string(text), "shape": .encoded(t.shape), "transform": .doubles(t.transform.m),
            "antialias": .encoded(t.antialias), "orientation": .encoded(t.orientation), "warp": t.warp.map { .encoded($0) } ?? .null,
            "runs": .array(runs), "paragraphs": .array(paragraphs), "lines": .array(lines), "bounds": bounds,
            "pxPerPt": .number(layout.pxPerPt),
        ]
        if !warnings.isEmpty { out = out.setting("warnings", .strings(warnings)) }
        return out
    }

    /// A type layer (not yet rendered or added) from `type.create`'s params, starting from the
    /// default type styles in the foreground colour. Shared with `type.createSelection`.
    static func newTextLayer(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> TextLayer {
        let orientation: TextOrientation
        switch p["orientation"] {
        case nil: orientation = .horizontal
        case .string("horizontal")?: orientation = .horizontal
        case .string("vertical")?: orientation = .vertical
        default: throw bad(cmd, "orientation must be horizontal or vertical")
        }
        if let m = checkKerning(p) { throw bad(cmd, m) }
        if let m = checkSizeTracking(p) { throw bad(cmd, m) }
        let text = normText(p["text"]?.stringValue ?? "")
        // Type › Save Default Type Styles sets the starting styles; the colour is always the
        // foreground colour, as in Photoshop.
        var style: CharStyle, para: ParagraphStyle
        if let d = s.state[DefaultsKey.self] {
            style = d.char
            para = d.para
        } else {
            style = CharStyle()
            style.fontFamily = defaultFamily
            para = ParagraphStyle()
        }
        let fg = s.tools.foreground
        style.color = PCColor.rgb(fg.x, fg.y, fg.z, fg.w)
        applyCharProps(&style, p)
        applyParaProps(&para, p)
        let shape: TextShape
        let transform: PCAffine
        if let b = p["box"]?.arrayValue, b.count == 4 {
            let v = b.map { Float($0.doubleValue ?? 0) }
            if v[2] <= 0 || v[3] <= 0 { throw bad(cmd, "box width and height must be positive") }
            shape = .box(.init(x: 0, y: 0, width: v[2], height: v[3]))
            transform = .translate(Double(v[0]), Double(v[1]))
        } else {
            shape = .point
            transform = .translate(Double(f32p(p, "x") ?? 0), Double(f32p(p, "y") ?? 0))
        }
        var t = TextLayer()
        t.runs = [TextRun(len: text.utf8.count, style: style)]
        t.paragraphs = [ParagraphRun(len: text.utf8.count, style: para)]
        t.text = text
        t.shape = shape
        t.transform = transform
        t.orientation = orientation
        t.syncSummary()
        return t
    }

    /// Kerning (1/1000 em) between the character starting at byte `at` and the next one, as laid
    /// out: the manual kern, or the automatic kerning of the pair (photocraft-text `pair_kerning`).
    /// nil when there is no such pair on one line.
    static func pairKerning(_ layer: TextLayer, dpi: Double, at: Int) -> Float? {
        let bytes = Array(layer.text.utf8)
        guard at >= 0, at < bytes.count else { return nil }
        let rest = slice(layer.text, at, bytes.count)
        guard let ch = rest.unicodeScalars.first else { return nil }
        let next = at + UTF8.width(ch)
        let after = slice(layer.text, next, bytes.count).unicodeScalars.first
        if ch == "\n" || ch == "\r" || after == nil || after == "\n" || after == "\r" { return nil }
        func gap(_ l: Layout) -> Double? {
            guard let a = l.clusters.first(where: { $0.range.lowerBound == at }),
                  let b = l.clusters.first(where: { $0.range.lowerBound == next }), a.line == b.line, !a.rtl else { return nil }
            return b.x - a.x
        }
        guard let with = gap(Layout(layer, dpi: dpi)) else { return nil }
        let runs = layer.charRuns()
        var acc = 0
        guard let styleRun = runs.first(where: { acc += $0.len; return at < acc }) else { return nil }
        let em = Double(styleRun.style.sizePt) * (dpi > 0 ? dpi / 72 : 1)
        if em.isNaN || em <= 0 { return nil }
        // A manually kerned pair shows its manual value. photocraft measures it like automatic
        // kerning; PCPlatform's CoreText adds `kCTKern` to the font's pair kerning instead of
        // replacing it, so the model value is the one Photoshop shows.
        if styleRun.style.kerning == .off { return styleRun.style.kern }
        // The same layer with the pair's first character unkerned.
        var plain = layer
        plain.runs = []
        var start = 0
        for r in runs {
            let end = start + r.len
            func push(_ s0: Int, _ e0: Int, _ unkern: Bool) {
                guard e0 > s0 else { return }
                var style = r.style
                if unkern { style.kerning = .off; style.kern = 0 }
                plain.runs.append(TextRun(len: e0 - s0, style: style))
            }
            push(start, min(max(at, start), end), false)
            push(min(max(at, start), end), min(max(next, start), end), true)
            push(min(max(next, start), end), end, false)
            start = end
        }
        guard let without = gap(Layout(plain, dpi: dpi)) else { return nil }
        let k = Float((with - without) / em * 1000)
        return k.isFinite ? k : nil
    }

    // MARK: Commands

    static let charParams = ##""font":str,"fontStyle":str,"weight":100..900,"italic":bool,"size":0.1..=1296 pt,"color":"#rrggbb"|[r,g,b,a],"tracking":-1000..=10000 (1/1000 em),"leading":pt|"auto","baselineShift":pt,"horizontalScale":%,"verticalScale":%,"underline":bool,"strikethrough":bool,"fauxBold":bool,"fauxItalic":bool,"kerning":1/1000em (manual, after each character)|"metrics"|"optical"|"off","caps":"normal|small|all","ligatures":bool,"discretionaryLigatures":bool,"features":{"ss01":1},"variations":{"wght":650},"language":str"##

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("type.create", "New Type Layer", menu: ["Layer", "New"],
                          params: ##"{"x":px,"y":px (baseline anchor of point text),"text":str,"box":[x,y,w,h]? (paragraph text),"name":str?,"align":"left|center|right|justify…"?,"orientation":"horizontal|vertical"="horizontal", …character keys: "font","size":pt=12,"color",…}"##,
                          module: m, enabled: hasDoc, run: create))
        r.add(CommandSpec("type.edit", "Edit Type",
                          params: ##"{"layer":id?,"text":str? (replace all, styles kept),"replace":{"start":char,"end":char,"text":str}?,"runs":[{"start":char,"end":char,…character keys}]?,"box":[x,y,w,h]? (to paragraph text),"point":[x,y]? (to point text),"move":[dx,dy]?,"transform":[a,b,c,d,e,f]?,"antialias":"none|sharp|crisp|strong|smooth"?,"name":str?,"kerning":1/1000em|"metrics"|"optical"|"off"? (with "range":[startChar,endChar]?, default all),"kernPair":{"at":caretChar,"by":1/1000em}? (Alt+←/→: the pair before the caret becomes manual, its current kerning + by)}"##,
                          module: m, enabled: hasDoc, run: edit))
        r.add(CommandSpec("type.setStyle", "Set Type Style",
                          params: ##"{"layer":id? or "layers":[id,…]? (default selected Type layers),"range":[startChar,endChar]? (single layer; default all),"metricsAsShown":bool=false (size/leading include each layer's transform scale), "## + charParams + ##", paragraph keys: "align":"left|center|right|justify|justifyCenter|justifyRight|justifyAll","firstLineIndent":pt,"startIndent":pt,"endIndent":pt,"spaceBefore":pt,"spaceAfter":pt,"autoLeading":%,"direction":"auto|ltr|rtl","hyphenate":bool}"##,
                          module: m, enabled: hasDoc, run: setStyle))
        r.add(CommandSpec("type.rasterize", "Rasterize Type", menu: ["Layer", "Rasterize"], params: ##"{"layer":id?}"##, module: m, enabled: hasDoc, run: rasterize))
        r.add(CommandSpec("type.info", "Type Layer Info",
                          params: ##"{"layer":id?} → text, runs/paragraphs (char offsets + styles), shape, transform, laid-out lines (text space px), bounds"##,
                          module: m, journal: false, enabled: hasDoc) { s, p in try info(s, p) })
        r.add(CommandSpec("type.fonts", "List Fonts", params: ##"{"family":str? (faces of one family)}"##, module: m, journal: false) { _, p in
            if let f = p["family"]?.stringValue {
                let faces: [JSONValue] = fonts({ FontCatalog.faces(family: f) }).map { x in
                    let axes: [JSONValue] = fonts({ FontCatalog.variationAxes(postScriptName: x.postScriptName) }).map {
                        [.string($0.tag), .number($0.minimum), .number($0.defaultValue), .number($0.maximum)]
                    }
                    return ["family": .string(x.family), "style": .string(x.style), "postscriptName": .string(x.postScriptName),
                            "weight": .int(x.weight), "italic": .bool(x.italic), "axes": .array(axes)]
                }
                return ["faces": .array(faces)]
            }
            return ["families": .strings(fonts { FontCatalog.families() })]
        })
        for (id, label, shortcut, up, by) in [("type.increaseSize", "Increase Type Size", "Cmd+Shift+.", true, Float(2)),
                                              ("type.decreaseSize", "Decrease Type Size", "Cmd+Shift+,", false, 2),
                                              ("type.increaseSizeMore", "Increase Type Size by 10", "Cmd+Alt+Shift+.", true, 10),
                                              ("type.decreaseSizeMore", "Decrease Type Size by 10", "Cmd+Alt+Shift+,", false, 10)] {
            r.add(CommandSpec(id, label, shortcut: shortcut, params: ##"{"layer":id?,"range":[startChar,endChar]? (default all),"by":pt? (as the layer appears)}"##,
                              module: m, enabled: hasTypeLayer) { s, p in try stepSize(s, p, up, by) })
        }
    }

    static let hasTypeLayer: CommandEnabled = { s, _ in
        guard let st = s.active else { return "no document open" }
        if let id = st.activeLayer, let l = st.doc.layer(id), isText(l) { return nil }
        return "the active layer is not a type layer"
    }

    @Sendable static func create(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        var t = try newTextLayer(s, p, "type.create")
        let name = p["name"]?.stringValue ?? layerName(t.text)
        let id = try s.edit("New Type Layer") { doc, active -> LayerId in
            refresh(doc, &t)
            let id = doc.insertAbove(active, Layer(name: name, content: .text(t)))
            active = id
            return id
        }
        let bounds = s.active?.doc.layer(id)?.surface.map(\.contentBounds)
        var out: JSONValue = ["layer": .id(id), "bounds": bounds.map { [.int($0.x0), .int($0.y0), .int($0.x1), .int($0.y1)] } ?? .null]
        if let tl = s.active.flatMap({ textOf($0.doc, id) }) {
            let warnings = missingFontWarningsForLayer(tl)
            if !warnings.isEmpty { out = out.setting("warnings", .strings(warnings)) }
        }
        return out
    }

    @Sendable static func edit(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "type.edit"
        let id = try layerId(s, p)
        let name = p["name"]?.stringValue
        if let m = checkKerning(p) { throw bad(cmd, m) }
        if let m = checkSizeTracking(p) { throw bad(cmd, m) }
        if case .array(let runs)? = p["runs"] {
            for (i, r) in runs.enumerated() {
                if let m = checkKerning(r) { throw bad(cmd, m) }
                // Checked before anything changes, so a bad run leaves the layer untouched (#714).
                let start = r["start"]?.uint64Value ?? 0
                if let end = r["end"]?.uint64Value, end < start {
                    throw bad(cmd, "runs[\(i)]: `end` (\(end)) is before `start` (\(start))")
                }
                if let m = checkSizeTracking(r) { throw bad(cmd, m) }
            }
        }
        var kernPair: (Int, Double)?
        if let k = p["kernPair"] {
            guard let at = k["at"]?.uint64Value else { throw bad(cmd, "kernPair.at must be a caret position (character index)") }
            guard let by = k["by"]?.doubleValue, by.isFinite, abs(by) <= kernMax else { throw bad(cmd, "kernPair.by must be a number of 1/1000 em") }
            kernPair = (Int(clamping: at), by)
        }
        let label = kernPair != nil ? "Kerning" : "Edit Type"
        try withTextLayer(s, p, label) { t, doc, rename in
            if let (at, by) = kernPair {
                // Photoshop's Alt+←/→: the pair before the caret becomes manually kerned, starting
                // from what it shows now (its metrics/optical or manual value).
                let n = charCount(t.text)
                if at == 0 || at >= n { throw bad(cmd, "kernPair needs a caret between two characters") }
                let a = byteAt(t.text, at - 1), b = byteAt(t.text, at)
                guard let now = pairKerning(t, dpi: Double(doc.resolutionDpi), at: a) else {
                    throw bad(cmd, "no kerning pair at the caret (line break or line end)")
                }
                let value = Float(min(max(Double(now.rounded()) + by, kernMin), kernMax))
                styleRange(&t, a, b) { st in
                    st.kerning = .off
                    st.kern = value
                }
            }
            if let k = p["kerning"] {
                let (a, b) = rangeParam(t.text, p)
                let kp: JSONValue = ["kerning": k]
                styleRange(&t, a, b) { st in applyCharProps(&st, kp) }
            }
            if let v = p["text"]?.stringValue {
                replaceText(&t, 0, t.text.utf8.count, v)
            }
            if let r = p["replace"] {
                let a = byteAt(t.text, index(r["start"]) ?? 0)
                let b = byteAt(t.text, index(r["end"]) ?? Int.max)
                replaceText(&t, a, max(b, a), r["text"]?.stringValue ?? "")
            }
            if case .array(let runs)? = p["runs"] {
                for r in runs {
                    let a = byteAt(t.text, index(r["start"]) ?? 0)
                    let b = byteAt(t.text, index(r["end"]) ?? Int.max)
                    styleRange(&t, a, b) { st in applyCharProps(&st, r) }
                }
            }
            let lin = t.transform
            if let b = p["box"]?.arrayValue, b.count == 4 {
                let v = b.map { $0.doubleValue ?? 0 }
                t.shape = .box(.init(x: 0, y: 0, width: Float(max(v[2], 1)), height: Float(max(v[3], 1))))
                t.transform = PCAffine(a: lin.a, b: lin.b, c: lin.c, d: lin.d, e: v[0], f: v[1])
            }
            if let pt = p["point"]?.arrayValue, pt.count == 2 {
                t.shape = .point
                t.transform = PCAffine(a: lin.a, b: lin.b, c: lin.c, d: lin.d, e: pt[0].doubleValue ?? 0, f: pt[1].doubleValue ?? 0)
            }
            if let d = p["move"]?.arrayValue, d.count == 2 {
                t.transform.e += d[0].doubleValue ?? 0
                t.transform.f += d[1].doubleValue ?? 0
            }
            if let mm = p["transform"]?.arrayValue, mm.count == 6 {
                var v = t.transform.m
                for (i, x) in mm.enumerated() { v[i] = x.doubleValue ?? v[i] }
                t.transform = PCAffine(m: v)
            }
            if let a = p["antialias"]?.stringValue {
                switch a {
                case "none": t.antialias = .none
                case "sharp": t.antialias = .sharp
                case "crisp": t.antialias = .crisp
                case "strong": t.antialias = .strong
                default: t.antialias = .smooth
                }
            }
            // The rename lands in the same undo step as the edit (#497).
            rename = name
        }
        return try info(s, ["layer": .id(id)])
    }

    @Sendable static func setStyle(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        if let m = checkKerning(p) { throw bad("type.setStyle", m) }
        let ids = try withTextTargets(s, p, "Set Type Style") { t, range in
            let (a, b) = range
            let props = try shownStyleParams(t, p)
            if let m = checkSizeTracking(props) { throw bad("type.setStyle", m) }
            var probe = CharStyle()
            if applyCharProps(&probe, props) {
                styleRange(&t, a, b) { st in applyCharProps(&st, props) }
            }
            var pprobe = ParagraphStyle()
            if applyParaProps(&pprobe, p) {
                styleParagraphs(&t, a, b) { st in applyParaProps(&st, p) }
            }
        }
        guard let id = ids.first else { throw EngineError.other("select a type layer") }
        return try info(s, ["layer": .id(id)])
    }

    @Sendable static func rasterize(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try layerId(s, p)
        try s.edit("Rasterize Type") { doc, _ in
            let snapshot = doc
            let done: Bool? = try doc.updateLayer(id) { l in
                guard case .text(var t) = l.content else { throw EngineError.other("layer \(id.rawValue) is not a type layer") }
                if t.cache == nil { refresh(snapshot, &t) }
                let surface = t.cache ?? Surface(format: snapshot.pixelFormat)
                l.content = .raster(surface.format == snapshot.pixelFormat ? surface : surface.converted(to: snapshot.pixelFormat))
                l.psdBlocks.removeAll { $0.key == PSDKey("TySh") }
                return true
            }
            if done == nil { throw EngineError.noLayer(id) }
        }
        return ["layer": .id(id)]
    }

    /// Re-renders the pixels of type layers whose font arrived after they were drawn (photocraft
    /// `Session::refresh_type_layers`, lib.rs). The model is unchanged, so this is no history step
    /// and leaves a clean document clean. Unknown documents and layers are skipped; the layers of a
    /// document a background job is computing from are returned, to try again later.
    @discardableResult
    static func refreshTypeLayers(_ s: Session, _ layers: [(DocId, LayerId)]) -> [(DocId, LayerId)] {
        var busy: [(DocId, LayerId)] = []
        var docs: [DocId] = []
        for (d, _) in layers where !docs.contains(d) { docs.append(d) }
        let jobDocs = Set(s.runningJobs.compactMap(\.document))
        for docId in docs {
            let mine = layers.filter { $0.0 == docId }
            if jobDocs.contains(docId) {
                busy.append(contentsOf: mine)
                continue
            }
            guard let i = s.index(of: docId) else { continue }
            let changed: Bool = (try? s.updateDocument(at: i) { st in
                let snapshot = st.doc
                var doc = snapshot
                var changed = false
                for (_, id) in mine where withText(&doc, id, { t in refresh(snapshot, &t) }) != nil { changed = true }
                guard changed else { return false }
                st.doc = doc
                Session.noEditRevision(&st)
                st.lastDamage = nil
                return true
            }) ?? false
            if changed, let st = s.documents.indices.contains(i) ? s.documents[i] : nil {
                s.emit(.documentChanged(st.id, revision: st.revision, damage: nil))
            }
        }
        s.publish()
        return busy
    }

    /// Grows or shrinks every character in the range by `by` points as the layer appears, so mixed
    /// sizes keep their differences and a scaled layer steps in the points its size field shows.
    static func stepSize(_ s: Session, _ p: JSONValue, _ up: Bool, _ defaultBy: Float) throws -> JSONValue {
        let id = try layerId(s, p)
        let by = min(abs(f32p(p, "by").flatMap { $0.isFinite ? $0 : nil } ?? defaultBy), Float(sizeMaxPt))
        try withTextLayer(s, p, "Change Type Size") { t, _, _ in
            let m = t.transform
            let sc = Float(abs(m.a * m.d - m.b * m.c).squareRoot())
            let scale = sc.isFinite && sc > 1e-3 ? sc : 1
            let delta = (up ? by : -by) / scale
            let (a, b) = rangeParam(t.text, p)
            styleRange(&t, a, b) { st in st.sizePt = min(max(st.sizePt + delta, Float(sizeMinPt)), Float(sizeMaxPt)) }
        }
        return try info(s, ["layer": .id(id)])
    }
}

// MARK: - Layout geometry

extension TypeCommands {
    /// photocraft-text's `TextLayout` geometry over PCPlatform's CoreText layout. Lines are in
    /// *line space*: `x` runs along the line and `baseline` is the cross-line position (for
    /// vertical type line space is turned 90° clockwise into text space, `toText`). Offsets are
    /// UTF-8 bytes of the layer text.
    struct Layout {
        struct Line: Equatable {
            /// Byte range in the layer text (without the paragraph break).
            var range: Range<Int>
            var baseline: Double
            /// Visual extent along the baseline.
            var x0: Double
            var x1: Double
            var ascent: Double
            var descent: Double
            var paragraph: Int
        }

        /// A caret stop (a character, or a ligature's characters) in line space.
        struct Cluster: Equatable {
            var range: Range<Int>
            var x: Double
            var advance: Double
            var line: Int
            var rtl: Bool
        }

        var lines: [Line] = []
        var clusters: [Cluster] = []
        var vertical: Bool
        var pxPerPt: Double

        init(_ t: TextLayer, dpi: Double) {
            let tl = TypeCommands.fonts { TextEngine.layout(t, dpi: dpi) }
            vertical = t.orientation == .vertical
            pxPerPt = dpi > 0 ? dpi / 72 : 1
            let paraStarts = TypeCommands.splitParagraphs(t.text).map(\.lowerBound)
            // Character sizes, for the half widths of vertical columns.
            var runEnds: [(Int, Float)] = []
            var acc = 0
            for r in t.charRuns() { acc += r.len; runEnds.append((acc, r.style.sizePt)) }
            func maxSizePx(_ r: Range<Int>) -> Double {
                var m: Float = 0
                var s0 = 0
                for (e, size) in runEnds {
                    if (s0 < r.upperBound && e > r.lowerBound) || (r.isEmpty && r.lowerBound >= s0 && r.lowerBound <= e) { m = max(m, size) }
                    s0 = e
                }
                return Double(m) * pxPerPt
            }
            for l in tl.lines {
                let pi = paraStarts.lastIndex { $0 <= l.range.lowerBound } ?? 0
                if vertical {
                    // PCPlatform turns each line into a column turned 90° clockwise: `x` is the
                    // column's centre in text space and `baseline` its along-column start. Glyphs
                    // are centred on the column, so its half widths are half an em.
                    let half = maxSizePx(l.range) / 2
                    lines.append(Line(range: l.range, baseline: -Double(l.x), x0: Double(l.baseline), x1: Double(l.baseline) + Double(l.width),
                                      ascent: half, descent: half, paragraph: pi))
                } else {
                    lines.append(Line(range: l.range, baseline: Double(l.baseline), x0: Double(l.x), x1: Double(l.x) + Double(l.width),
                                      ascent: Double(l.ascent), descent: Double(l.descent), paragraph: pi))
                }
            }
            // Glyph clusters → one caret stop per source offset; each ends where the next begins.
            var perLine: [[Int: (x0: Double, x1: Double, rtl: Bool)]] = Array(repeating: [:], count: lines.count)
            for c in tl.clusters where c.line >= 0 && c.line < lines.count {
                let lr = lines[c.line].range
                let s0 = c.range.lowerBound
                guard !lr.isEmpty, s0 >= lr.lowerBound, s0 < lr.upperBound else { continue }
                let x = Double(c.x), w = Double(c.width)
                if let e = perLine[c.line][s0] {
                    perLine[c.line][s0] = vertical ? (e.x0, e.x1 + w, false) : (min(e.x0, x), max(e.x1, x + w), e.rtl || c.rtl)
                } else {
                    perLine[c.line][s0] = vertical ? (0, w, false) : (x, x + w, c.rtl)
                }
            }
            for (li, m) in perLine.enumerated() {
                let starts = m.keys.sorted()
                // Vertical forms: CoreText reports each glyph's vertical advance as its width and
                // no usable position, so the stops follow each other down the column.
                var along = lines[li].x0
                for (k, s0) in starts.enumerated() {
                    guard let e = m[s0] else { continue }
                    let end = k + 1 < starts.count ? starts[k + 1] : max(lines[li].range.upperBound, s0 + 1)
                    let x = vertical ? along : e.x0
                    clusters.append(Cluster(range: s0..<end, x: x, advance: e.x1 - e.x0, line: li, rtl: e.rtl))
                    along += e.x1 - e.x0
                }
                // The logical line box covers its trailing spaces (photocraft's line advance).
                if let last = clusters.last, last.line == li { lines[li].x1 = max(lines[li].x1, last.x + last.advance) }
            }
        }

        /// Line space → text space (identity for horizontal type; vertical: lines run down,
        /// the next line is to the left).
        func toText(_ x: Double, _ y: Double) -> (Double, Double) { vertical ? (-y, x) : (x, y) }

        /// Text space → line space.
        func toLine(_ x: Double, _ y: Double) -> (Double, Double) { vertical ? (y, -x) : (x, y) }

        /// Logical bounds of all lines in line space `[x0, y0, x1, y1]`.
        func lineBounds() -> [Double]? {
            var acc: [Double]?
            for l in lines {
                let r = [l.x0, l.baseline - l.ascent, l.x1, l.baseline + l.descent]
                if let a = acc { acc = [min(a[0], r[0]), min(a[1], r[1]), max(a[2], r[2]), max(a[3], r[3])] } else { acc = r }
            }
            return acc
        }

        /// Logical bounds of all lines, text space.
        func bounds() -> [Double]? {
            guard let b = lineBounds() else { return nil }
            return vertical ? [-b[3], b[0], -b[1], b[2]] : b
        }

        /// The visual line nearest to a line-space ordinate, including its ascent and descent.
        func closestLine(_ y: Double) -> Int? {
            func d(_ l: Line) -> Double {
                if y < l.baseline - l.ascent { return l.baseline - l.ascent - y }
                if y > l.baseline + l.descent { return y - l.baseline - l.descent }
                return 0
            }
            return lines.indices.min { d(lines[$0]) < d(lines[$1]) }
        }

        /// Byte offset of the caret nearest to a text-space point.
        func hitTest(_ x: Double, _ y: Double) -> Int {
            let (lx, ly) = toLine(x, y)
            guard let li = closestLine(ly) else { return 0 }
            return hitTestXOnLine(li, lx)
        }

        func hitTestXOnLine(_ lineIndex: Int, _ x: Double) -> Int {
            guard lineIndex >= 0, lineIndex < lines.count else { return 0 }
            var best = (Double.greatestFiniteMagnitude, lines[lineIndex].range.upperBound)
            for c in clusters where c.line == lineIndex {
                let mid = c.x + c.advance / 2
                let (before, after) = c.rtl ? (c.range.upperBound, c.range.lowerBound) : (c.range.lowerBound, c.range.upperBound)
                let (dist, off) = x < mid ? (abs(x - c.x), before) : (abs(x - c.x - c.advance), after)
                if dist < best.0 { best = (dist, off) }
            }
            return best.1
        }

        /// Caret geometry for a byte offset: (x, top, bottom) in line space.
        func caret(_ offset: Int) -> (Double, Double, Double) {
            for c in clusters where c.range.lowerBound == offset && c.line < lines.count {
                let l = lines[c.line]
                return (c.rtl ? c.x + c.advance : c.x, l.baseline - l.ascent, l.baseline + l.descent)
            }
            // End of a line (or empty line): after the last cluster of the line containing it.
            let li = lines.firstIndex { offset >= $0.range.lowerBound && offset <= $0.range.upperBound } ?? max(lines.count - 1, 0)
            guard li < lines.count else { return (0, 0, 0) }
            let l = lines[li]
            let x = clusters.first { $0.line == li && $0.range.upperBound == offset }.map { $0.rtl ? $0.x : $0.x + $0.advance } ?? l.x1
            return (x, l.baseline - l.ascent, l.baseline + l.descent)
        }

        /// The caret for a byte offset as a text-space segment.
        func caretSegment(_ offset: Int) -> [(Double, Double)] {
            let (x, top, bottom) = caret(offset)
            return [toText(x, top), toText(x, bottom)]
        }

        /// Line containing a byte offset; a shared wrap boundary belongs to the following line.
        func lineIndex(_ byte: Int) -> Int {
            lines.lastIndex { byte >= $0.range.lowerBound && byte <= $0.range.upperBound } ?? max(lines.count - 1, 0)
        }

        /// Text-space point inside the laid-out line boxes, expanded by `slop` px on every side.
        func contains(_ x: Double, _ y: Double, slop: Double = 0) -> Bool {
            let slop = slop.isFinite ? max(slop, 0) : 0
            guard let b = bounds() else { return false }
            return x >= b[0] - slop && x <= b[2] + slop && y >= b[1] - slop && y <= b[3] + slop
        }
    }
}
