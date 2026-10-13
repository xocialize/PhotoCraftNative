// Port of photocraft-engine (crates/engine/src/type_styles_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Character Styles and Paragraph Styles (Window › Character Styles / Paragraph Styles):
// `type.characterStyle.*` and `type.paragraphStyle.*` — new, duplicate, delete, rename, set (Style
// Options), apply, redefine (from the selected text), clear override and list. The style model is
// PCDocument's `TextStyles`; text runs keep fully resolved attributes plus a style reference, so
// whatever differs from the referenced styles is a local override ("+").
//
// Text targets: `layer` (one type layer) or `layers` (several), default the selected type layers;
// `range: [startChar, endChar]` restricts a single layer to part of its text. Changing a style's
// definition re-renders every type layer that uses it, keeping overrides.

import Foundation
import PCDocument
import PCFoundation

enum TypeStylesCommands: CommandModule {
    static let name = "type_styles_cmds"
    static let m = name
    typealias T = TypeCommands

    static var family: String { T.defaultFamily }

    static func exhaustedId(_ paragraph: Bool) -> EngineError {
        .other("\(paragraph ? "paragraph" : "character") style id space exhausted")
    }

    /// Type layers a style command acts on: `layer`, `layers`, else the selected type layers.
    static func targets(_ s: Session, _ p: JSONValue) -> [LayerId] {
        guard let st = s.active else { return [] }
        let ids: [LayerId]
        if let id = p["layer"]?.uint64Value {
            ids = [LayerId(id)]
        } else if let a = p["layers"]?.arrayValue {
            ids = a.compactMap { $0.uint64Value.map { LayerId($0) } }
        } else {
            ids = st.selectedLayers
        }
        return ids.filter { T.textOf(st.doc, $0) != nil }
    }

    static let hasTarget: CommandEnabled = { s, _ in
        if s.active == nil { return "no document open" }
        return targets(s, .null).isEmpty ? "select a type layer" : nil
    }

    /// `range` in characters → bytes (whole text when absent).
    static func rangeOf(_ text: String, _ p: JSONValue) -> (Int, Int) { T.rangeParam(text, p) }

    // MARK: Attribute parameters

    /// A character style with every field changed from the default, to see which fields a set of
    /// Character-panel keys touches.
    static func perturbedChar() -> CharStyle {
        var c = CharStyle()
        c.fontFamily = "\u{1}"
        c.fontStyle = "\u{1}"
        c.postscriptName = "\u{1}"
        c.weight = 1
        c.italic = true
        c.sizePt = -1
        c.color = PCColor.rgb(0.123, 0.456, 0.789, 0.5)
        c.tracking = -12345
        c.leadingPt = -1
        c.baselineShiftPt = -1
        c.horizontalScale = -1
        c.verticalScale = -1
        c.underline = true
        c.strikethrough = true
        c.fauxBold = true
        c.fauxItalic = true
        c.kerning = .off
        c.kern = -12345
        c.caps = .allCaps
        c.ligatures = false
        c.discretionaryLigatures = true
        c.features = [FontFeature(tag: "\u{1}", value: 9)]
        c.variations = [FontVariation(axis: "\u{1}", value: -1)]
        c.language = "\u{1}"
        c.styleSheet = nil
        return c
    }

    static func perturbedPara() -> ParagraphStyle {
        var p = ParagraphStyle()
        p.align = .justifyAll
        p.firstLineIndentPt = -1
        p.startIndentPt = -1
        p.endIndentPt = -1
        p.spaceBeforePt = -1
        p.spaceAfterPt = -1
        p.autoLeading = -1
        p.direction = .rtl
        p.hyphenate = true
        p.styleSheet = nil
        return p
    }

    /// Fields set by Character/Paragraph-panel keys: the fields whose value is the same whatever
    /// they were before.
    static func touched<S: Codable>(_ base: S, _ perturbed: S, _ apply: (inout S) -> Void) -> StyleAttrs {
        var a = base, b = perturbed
        apply(&a)
        apply(&b)
        func obj(_ x: S) -> [String: JSONValue] { ((try? JSONValue(encoding: x))?.objectValue) ?? [:] }
        let allB = obj(b)
        return obj(a).filter { k, v in k != "style_sheet" && allB[k] == v }
    }

    /// Splits `attrs` into character and paragraph attribute sets. Keys may be model field names
    /// (`size_pt`, `align`: values as in `type.info`) or the Character/Paragraph panel keys of
    /// `type.setStyle` (`size`, `font`, `align`, …).
    static func parseAttrs(_ cmd: String, _ v: JSONValue) throws -> (StyleAttrs, StyleAttrs) {
        guard case .object(let obj) = v else {
            if v == .null { return ([:], [:]) }
            throw EngineError.bad(cmd, "`attrs` must be an object")
        }
        let charKeys = Set(charAttrs(CharStyle()).keys)
        let paraKeys = Set(paraAttrs(ParagraphStyle()).keys)
        var c: StyleAttrs = [:], pa: StyleAttrs = [:], friendly: StyleAttrs = [:]
        for (k, x) in obj {
            // Names shared by the model and the panels (`color`, `align`, `caps`, …) are read as
            // model values when they parse as such, else as panel values ("#ff0000", "center").
            let one: StyleAttrs = [k: x]
            if charKeys.contains(k) && (try? validateAttrs(one, for: CharStyle.self)) != nil {
                c[k] = x
            } else if paraKeys.contains(k) && (try? validateAttrs(one, for: ParagraphStyle.self)) != nil {
                pa[k] = x
            } else {
                friendly[k] = x
            }
        }
        if !friendly.isEmpty {
            let f = JSONValue.object(friendly)
            let fc = T.fonts { touched(CharStyle(), perturbedChar()) { T.applyCharProps(&$0, f) } }
            let fp = touched(ParagraphStyle(), perturbedPara()) { T.applyParaProps(&$0, f) }
            if fc.isEmpty && fp.isEmpty {
                throw EngineError.bad(cmd, "unknown style attributes: \(friendly.keys.sorted().joined(separator: ", "))")
            }
            c.merge(fc) { _, b in b }
            pa.merge(fp) { _, b in b }
        }
        do { try validateAttrs(c, for: CharStyle.self) } catch { throw EngineError.bad(cmd, error.message) }
        do { try validateAttrs(pa, for: ParagraphStyle.self) } catch { throw EngineError.bad(cmd, error.message) }
        return (c, pa)
    }

    // MARK: Restyling

    /// What to do to the targeted text while re-resolving against new styles.
    struct Op {
        /// Set the character style of the range (`.some(nil)` = "None").
        var setChar: UInt32??
        /// Set the paragraph style of paragraphs touching the range (`.some(nil)` = Basic).
        var setPara: UInt32??
        /// Drop character overrides in the range.
        var clearChar = false
        /// Drop paragraph overrides of paragraphs touching the range.
        var clearPara = false
    }

    /// Re-resolves every run and paragraph of `t` against `new` (keeping overrides made against
    /// `old`), applying `op` to bytes `a..<b`. Returns whether anything changed.
    static func restyle(_ t: inout TextLayer, old: TextStyles, new: TextStyles, range: (Int, Int)?, op: Op) -> Bool {
        let before = (t.runs, t.paragraphs)
        let text = t.text
        let n = text.utf8.count
        let (a, b) = range ?? (0, n)
        let whole = range == nil
        // Paragraphs.
        let oldParas = t.paragraphRuns()
        var starts: [Int] = []
        var acc = 0
        for r in oldParas { starts.append(acc); acc += r.len }
        func paraAt(_ off: Int) -> ParagraphStyle {
            let i = starts.lastIndex { $0 <= off } ?? 0
            return i < oldParas.count ? oldParas[i].style : ParagraphStyle()
        }
        var paras: [(Range<Int>, ParagraphStyle, UInt32?)] = []  // range, new style, old ref
        for pr in T.splitParagraphs(text) {
            let oldP = paraAt(pr.lowerBound)
            let touches = whole || (pr.lowerBound < b && pr.upperBound > a) || (a == b && a >= pr.lowerBound && (a < pr.upperBound || pr.upperBound == n))
            let newRef: UInt32? = touches ? (op.setPara ?? oldP.styleSheet) : oldP.styleSheet
            let np = op.clearPara && touches ? new.resolvePara(newRef) : new.restylePara(old: old, oldP, newPara: newRef)
            paras.append((pr, np, oldP.styleSheet))
        }
        // Character runs, split at paragraph boundaries and the range edges.
        var cuts = paras.map(\.0.lowerBound)
        cuts += [a, b, n]
        var runs: [(Int, CharStyle)] = []
        var at = 0
        for r in t.charRuns() {
            let (rs, re) = (at, at + r.len)
            at = re
            let edges = Array(Set(cuts.filter { $0 > rs && $0 < re })).sorted()
            var s0 = rs
            for e in edges + [re] {
                if e <= s0 && rs != re { continue }
                let pi = paras.lastIndex { $0.0.lowerBound <= s0 } ?? 0
                let (oldPref, newPref) = pi < paras.count ? (paras[pi].2, paras[pi].1.styleSheet) : (nil, nil)
                let inside = whole || (s0 >= a && e <= b && a < b)
                let chr: UInt32? = inside ? (op.setChar ?? r.style.styleSheet) : r.style.styleSheet
                let st = op.clearChar && inside
                    ? new.resolveChar(para: newPref, chr: chr, defaultFamily: family)
                    : new.restyleChar(old: old, run: r.style, oldPara: oldPref, newPara: newPref, newChr: chr, family: family)
                if let last = runs.last, last.1 == st {
                    runs[runs.count - 1].0 += e - s0
                } else {
                    runs.append((e - s0, st))
                }
                s0 = e
            }
        }
        var pruns: [(Int, ParagraphStyle)] = []
        for (r, st, _) in paras {
            if let last = pruns.last, last.1 == st { pruns[pruns.count - 1].0 += r.count } else { pruns.append((r.count, st)) }
        }
        if runs.isEmpty {
            let first = t.charRuns().first?.style ?? CharStyle()
            runs.append((0, new.restyleChar(old: old, run: first, oldPara: nil, newPara: pruns.first?.1.styleSheet,
                                            newChr: op.setChar ?? first.styleSheet, family: family)))
        }
        t.runs = runs.map { TextRun(len: $0.0, style: $0.1) }
        t.paragraphs = pruns.map { ParagraphRun(len: $0.0, style: $0.1) }
        t.syncSummary()
        return t.runs != before.0 || t.paragraphs != before.1
    }

    /// A type layer and an optional byte range in it.
    typealias Target = (LayerId, (Int, Int)?)

    /// Replaces the document's styles with `new` and re-resolves every type layer (as one history
    /// step), applying `op` to `target`.
    @discardableResult
    static func commit(_ s: Session, _ label: String, _ new: TextStyles, _ target: [Target], _ op: Op) throws -> Int {
        try s.edit(label) { doc, _ in applyStyles(&doc, new, target, op) }
    }

    /// Shared by history-backed commands and isolated preview documents.
    @discardableResult
    static func applyStyles(_ doc: inout Document, _ new: TextStyles, _ target: [Target], _ op: Op) -> Int {
        let old = doc.textStyles
        doc.textStyles = new
        let snapshot = doc
        var changed = 0
        for id in T.textLayerIds(doc) {
            let tgt = target.first { $0.0 == id }
            T.withText(&doc, id) { t in
                let did = tgt.map { restyle(&t, old: old, new: new, range: $0.1, op: op) }
                    ?? restyle(&t, old: old, new: new, range: (0, 0), op: Op())
                if did {
                    T.refresh(snapshot, &t)
                    changed += 1
                }
            }
        }
        return changed
    }

    /// Target list with byte ranges (`range` applies only to a single layer).
    static func targetRanges(_ s: Session, _ p: JSONValue) throws -> [Target] {
        guard let st = s.active else { throw EngineError.noDocument }
        let ids = targets(s, p)
        if ids.isEmpty { throw EngineError.other("no type layer to apply the style to") }
        let ranged = p["range"] != nil && p["layers"] == nil
        return ids.map { id in (id, ranged ? T.textOf(st.doc, id).map { rangeOf($0.text, p) } : nil) }
    }

    /// The run and paragraph at the start of the target (for new/redefine), with the layer and the
    /// run's byte range.
    static func sample(_ s: Session, _ p: JSONValue) -> (CharStyle, ParagraphStyle, LayerId, (Int, Int))? {
        guard let st = s.active, let id = targets(s, p).first, let t = T.textOf(st.doc, id) else { return nil }
        let n = t.text.utf8.count
        let (a, _) = rangeOf(t.text, p)
        var at = 0
        var run: (CharStyle, (Int, Int))?
        for r in t.charRuns() {
            let (s0, e0) = (at, at + r.len)
            at = e0
            if a < e0 || e0 == n {
                run = (r.style, (s0, e0))
                break
            }
        }
        guard let (style, span) = run else { return nil }
        at = 0
        var para: ParagraphStyle?
        for r in t.paragraphRuns() {
            let hit = a < at + r.len || at + r.len == n
            at += r.len
            if hit { para = r.style; break }
        }
        guard let para else { return nil }
        return (style, para, id, span)
    }

    /// Character / paragraph style state of the target over the whole target (mixed ids → null).
    static func current(_ s: Session, _ p: JSONValue) -> JSONValue? {
        guard let st = s.active, let tr = try? targetRanges(s, p) else { return nil }
        let styles = st.doc.textStyles
        var chars: [UInt32] = [], paras: [UInt32] = []
        var cOver = false, pOver = false
        for (id, r) in tr {
            guard let t = T.textOf(st.doc, id) else { return nil }
            let n = t.text.utf8.count
            let (a, b) = r ?? (0, n)
            var at = 0
            var paraSpans: [(Int, Int, UInt32?)] = []
            for x in t.paragraphRuns() {
                let (s0, e0) = (at, at + x.len)
                at = e0
                if (s0 < b && e0 > a) || (a == b && a >= s0 && (a < e0 || e0 == n)) || t.text.isEmpty {
                    paras.append(x.style.styleSheet ?? 0)
                    pOver = pOver || !styles.paraOverrides(x.style).isEmpty
                }
                paraSpans.append((s0, e0, x.style.styleSheet))
            }
            at = 0
            for x in t.charRuns() {
                let (s0, e0) = (at, at + x.len)
                at = e0
                if (s0 < b && e0 > a) || (a == b && a >= s0 && a <= e0) || t.text.isEmpty {
                    let pref = paraSpans.last { $0.0 <= s0 }?.2
                    chars.append(x.style.styleSheet ?? 0)
                    cOver = cOver || !styles.charOverrides(x.style, para: pref, defaultFamily: family).isEmpty
                }
            }
        }
        func one(_ v: [UInt32]) -> JSONValue {
            guard let f = v.first, v.allSatisfy({ $0 == f }) else { return .null }
            return .int(f)
        }
        return ["character": one(chars), "characterOverride": .bool(cOver), "paragraph": one(paras), "paragraphOverride": .bool(pOver)]
    }

    // MARK: Commands

    static func styles(_ s: Session) throws -> TextStyles {
        guard let d = s.active else { throw EngineError.noDocument }
        return d.doc.textStyles
    }

    static func charJSON(_ d: CharacterStyleDef, _ styles: TextStyles) -> JSONValue {
        ["id": .int(d.id), "name": .string(d.name), "attrs": .object(d.attrs), "resolved": .encoded(styles.resolveChar(para: nil, chr: d.id, defaultFamily: family))]
    }

    static func paraJSON(_ d: ParagraphStyleDef, _ styles: TextStyles) -> JSONValue {
        ["id": .int(d.id), "name": .string(d.name), "paragraphAttrs": .object(d.paraAttrs), "characterAttrs": .object(d.charAttrs),
         "resolved": ["paragraph": .encoded(styles.resolvePara(d.id)), "character": .encoded(styles.resolveChar(para: d.id, chr: nil, defaultFamily: family))]]
    }

    static func list(_ s: Session, _ p: JSONValue, _ paragraph: Bool) throws -> JSONValue {
        let st = try styles(s)
        let cur = current(s, p) ?? .null
        if paragraph {
            return ["styles": .array([paraJSON(st.basic, st)] + st.paragraph.map { paraJSON($0, st) }), "current": cur]
        }
        let none: JSONValue = ["id": 0, "name": .string(noCharacterStyleName), "attrs": .object([:])]
        return ["styles": .array([none] + st.character.map { charJSON($0, st) }), "current": cur]
    }

    static func newStyle(_ s: Session, _ p: JSONValue, _ paragraph: Bool) throws -> JSONValue {
        let cmd = paragraph ? "type.paragraphStyle.new" : "type.characterStyle.new"
        var st = try styles(s)
        var (ca, pa) = try parseAttrs(cmd, p["attrs"] ?? .null)
        // With a type layer targeted, the style starts from the text's formatting (as Photoshop).
        let fromText = p["fromSelection"]?.boolValue ?? true
        if fromText, let (run, para, _, _) = sample(s, p) {
            if paragraph {
                let baseC = st.resolveChar(para: nil, chr: nil, defaultFamily: family)
                var plain = run
                plain.styleSheet = nil
                ca = diffAttrs(plain, baseC).merging(ca) { _, b in b }
                pa = diffAttrs(para, st.resolvePara(nil)).merging(pa) { _, b in b }
            } else {
                let baseC = st.resolveChar(para: para.styleSheet, chr: nil, defaultFamily: family)
                ca = diffAttrs(run, baseC).merging(ca) { _, b in b }
            }
        }
        let name = p["name"]?.stringValue ?? st.uniqueName(paragraph: paragraph, base: paragraph ? "Paragraph Style" : "Character Style")
        let id: UInt32
        if paragraph {
            guard let nid = st.nextParaId else { throw exhaustedId(true) }
            id = nid
            st.paragraph.append(ParagraphStyleDef(id: id, name: name, paraAttrs: pa, charAttrs: ca))
        } else {
            guard let nid = st.nextCharId else { throw exhaustedId(false) }
            id = nid
            st.character.append(CharacterStyleDef(id: id, name: name, attrs: ca))
        }
        var target: [Target] = []
        var op = Op()
        if p["apply"]?.boolValue ?? false {
            target = try targetRanges(s, p)
            if paragraph { op.setPara = .some(id) } else { op.setChar = .some(id) }
        }
        try commit(s, paragraph ? "New Paragraph Style" : "New Character Style", st, target, op)
        return ["id": .int(id), "name": .string(name)]
    }

    static func lookupId(_ cmd: String, _ st: TextStyles, _ p: JSONValue, _ paragraph: Bool, allowDefault: Bool) throws -> UInt32 {
        guard let id = try Params.u32Id(cmd, p, "id") else { throw EngineError.bad(cmd, "missing `id`") }
        let ok = paragraph ? st.paraStyle(id) != nil : st.charStyle(id) != nil
        if !(ok || (allowDefault && id == 0)) { throw EngineError.bad(cmd, "no style with id \(id)") }
        if id == 0 && !allowDefault {
            throw EngineError.bad(cmd, paragraph ? "Basic Paragraph can't be changed this way" : "\"None\" is not a style")
        }
        return id
    }

    static func duplicate(_ s: Session, _ p: JSONValue, _ paragraph: Bool) throws -> JSONValue {
        let cmd = paragraph ? "type.paragraphStyle.duplicate" : "type.characterStyle.duplicate"
        var st = try styles(s)
        let id = try lookupId(cmd, st, p, paragraph, allowDefault: paragraph)
        let newId: UInt32, name: String
        if paragraph {
            var src = st.paraStyle(id) ?? ParagraphStyleDef()
            name = "\(src.name) copy"
            guard let nid = st.nextParaId else { throw exhaustedId(true) }
            let pos = st.paragraph.firstIndex { $0.id == id }.map { $0 + 1 } ?? 0
            src.id = nid
            src.name = name
            st.paragraph.insert(src, at: pos)
            newId = nid
        } else {
            var src = st.charStyle(id) ?? CharacterStyleDef()
            name = "\(src.name) copy"
            guard let nid = st.nextCharId else { throw exhaustedId(false) }
            let pos = st.character.firstIndex { $0.id == id }.map { $0 + 1 } ?? 0
            src.id = nid
            src.name = name
            st.character.insert(src, at: pos)
            newId = nid
        }
        try commit(s, "Duplicate Style", st, [], Op())
        return ["id": .int(newId), "name": .string(name)]
    }

    static func delete(_ s: Session, _ p: JSONValue, _ paragraph: Bool) throws -> JSONValue {
        let cmd = paragraph ? "type.paragraphStyle.delete" : "type.characterStyle.delete"
        let st = try styles(s)
        let id = try lookupId(cmd, st, p, paragraph, allowDefault: false)
        // Text keeps its look: references are dropped and the attributes become overrides.
        let n = try s.edit("Delete Style") { doc, _ -> Int in
            if paragraph { doc.textStyles.paragraph.removeAll { $0.id == id } } else { doc.textStyles.character.removeAll { $0.id == id } }
            let snapshot = doc
            var n = 0
            for lid in T.textLayerIds(doc) {
                T.withText(&doc, lid) { t in
                    var hit = false
                    if paragraph {
                        for i in t.paragraphs.indices where t.paragraphs[i].style.styleSheet == id {
                            t.paragraphs[i].style.styleSheet = nil
                            hit = true
                        }
                    } else {
                        for i in t.runs.indices where t.runs[i].style.styleSheet == id {
                            t.runs[i].style.styleSheet = nil
                            hit = true
                        }
                    }
                    if hit {
                        T.refresh(snapshot, &t)
                        n += 1
                    }
                }
            }
            return n
        }
        return ["deleted": .int(id), "layers": .int(n)]
    }

    static func rename(_ s: Session, _ p: JSONValue, _ paragraph: Bool) throws -> JSONValue {
        let cmd = paragraph ? "type.paragraphStyle.rename" : "type.characterStyle.rename"
        var st = try styles(s)
        let id = try lookupId(cmd, st, p, paragraph, allowDefault: false)
        guard let name = p["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw EngineError.bad(cmd, "missing `name`")
        }
        if paragraph {
            if var d = st[paraStyle: id] { d.name = name; st[paraStyle: id] = d }
        } else if var d = st[charStyle: id] {
            d.name = name
            st[charStyle: id] = d
        }
        try commit(s, "Rename Style", st, [], Op())
        return ["id": .int(id), "name": .string(name)]
    }

    static func prepareOptions(_ st: TextStyles, _ p: JSONValue, _ paragraph: Bool) throws -> (TextStyles, UInt32) {
        var st = st
        let cmd = paragraph ? "type.paragraphStyle.set" : "type.characterStyle.set"
        let id = try lookupId(cmd, st, p, paragraph, allowDefault: paragraph)
        let (ca, pa) = try parseAttrs(cmd, p["attrs"] ?? .null)
        let replace = p["replace"]?.boolValue ?? false
        let clear = p["clear"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let name = p["name"]?.stringValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        func merge(_ dst: inout StyleAttrs, _ src: StyleAttrs) {
            if replace { dst.removeAll() }
            dst.merge(src) { _, b in b }
            for k in clear { dst[k] = nil }
        }
        if paragraph {
            guard var d = st[paraStyle: id] else { throw EngineError.bad(cmd, "no such style") }
            merge(&d.charAttrs, ca)
            if replace { d.paraAttrs.removeAll() }
            d.paraAttrs.merge(pa) { _, b in b }
            for k in clear { d.paraAttrs[k] = nil }
            if let name, id != 0 { d.name = name }
            st[paraStyle: id] = d
        } else {
            if !pa.isEmpty { throw EngineError.bad(cmd, "character styles have no paragraph attributes") }
            guard var d = st[charStyle: id] else { throw EngineError.bad(cmd, "no such style") }
            merge(&d.attrs, ca)
            if let name { d.name = name }
            st[charStyle: id] = d
        }
        return (st, id)
    }

    /// Apply Style Options to an isolated document, using exactly the command's resolution and
    /// rendering logic. The source document and the caller's session/history remain untouched.
    static func previewOptions(_ doc: Document, _ p: JSONValue, paragraph: Bool) throws -> Document {
        let (new, _) = try prepareOptions(doc.textStyles, p, paragraph)
        var shown = doc
        applyStyles(&shown, new, [], Op())
        return shown
    }

    static func setOptions(_ s: Session, _ p: JSONValue, _ paragraph: Bool) throws -> JSONValue {
        let (st, id) = try prepareOptions(try styles(s), p, paragraph)
        let layers = try commit(s, "Style Options", st, [], Op())
        return try list(s, [:], paragraph).setting("layers", .int(layers)).setting("id", .int(id))
    }

    static func apply(_ s: Session, _ p: JSONValue, _ paragraph: Bool) throws -> JSONValue {
        let cmd = paragraph ? "type.paragraphStyle.apply" : "type.characterStyle.apply"
        let st = try styles(s)
        let id: UInt32
        switch p["id"] {
        case nil, .null?: id = 0
        default: id = try lookupId(cmd, st, p, paragraph, allowDefault: true)
        }
        let target = try targetRanges(s, p)
        let clear = p["clearOverrides"]?.boolValue ?? false
        let r: UInt32? = id != 0 ? id : nil
        var op = Op()
        if paragraph {
            op.setPara = .some(r)
            op.clearPara = clear
            op.clearChar = clear
        } else {
            op.setChar = .some(r)
            op.clearChar = clear
        }
        let n = try commit(s, paragraph ? "Apply Paragraph Style" : "Apply Character Style", st, target, op)
        return ["id": .int(id), "layers": .int(n), "current": current(s, p) ?? .null]
    }

    static func clearOverride(_ s: Session, _ p: JSONValue, _ paragraph: Bool) throws -> JSONValue {
        let st = try styles(s)
        let target = try targetRanges(s, p)
        var op = Op()
        op.clearChar = true
        op.clearPara = paragraph
        let n = try commit(s, "Clear Override", st, target, op)
        return ["layers": .int(n), "current": current(s, p) ?? .null]
    }

    static func redefine(_ s: Session, _ p: JSONValue, _ paragraph: Bool) throws -> JSONValue {
        let cmd = paragraph ? "type.paragraphStyle.redefine" : "type.characterStyle.redefine"
        var st = try styles(s)
        guard let (run, para, layer, span) = sample(s, p) else { throw EngineError.bad(cmd, "select type to redefine the style from") }
        let id: UInt32
        if try Params.u32Id(cmd, p, "id") != nil {
            id = try lookupId(cmd, st, p, paragraph, allowDefault: paragraph)
        } else if paragraph {
            id = para.styleSheet ?? 0
        } else {
            guard let c = run.styleSheet else { throw EngineError.bad(cmd, "the selected text has no character style") }
            id = c
        }
        if paragraph {
            let charKeys = Set(run.styleSheet.flatMap { st.charStyle($0) }.map { Array($0.attrs.keys) } ?? [])
            let cOver = st.charOverrides(run, para: id != 0 ? id : nil, defaultFamily: family).filter { !charKeys.contains($0.key) }
            let pOver = diffAttrs(para, st.resolvePara(id))
            guard var d = st[paraStyle: id] else { throw EngineError.bad(cmd, "no such style") }
            d.charAttrs.merge(cOver) { _, b in b }
            d.paraAttrs.merge(pOver) { _, b in b }
            st[paraStyle: id] = d
        } else {
            var styled = run
            styled.styleSheet = id
            let over = st.charOverrides(styled, para: para.styleSheet, defaultFamily: family)
            guard var d = st[charStyle: id] else { throw EngineError.bad(cmd, "no such style") }
            d.attrs.merge(over) { _, b in b }
            st[charStyle: id] = d
        }
        // The sampled run gets the style (its overrides are now part of it); others follow.
        var op = Op()
        if paragraph { op.setPara = .some(id != 0 ? id : nil) } else { op.setChar = .some(id) }
        let n = try commit(s, paragraph ? "Redefine Paragraph Style" : "Redefine Character Style", st, [(layer, span)], op)
        return ["id": .int(id), "layers": .int(n), "current": current(s, p) ?? .null]
    }

    // MARK: Registry

    static let targetDoc = #""layer":id? | "layers":[id]? (default: the selected type layers),"range":[startChar,endChar]? (one layer; default all text)"#
    static let attrsDoc = ##""attrs":{model fields as in type.info ("size_pt":36,"font_family":"Inter","align":"Center",…) or Character/Paragraph panel keys as in type.setStyle ("size":36,"font":"Inter","color":"#rrggbb","align":"center",…)}"##

    static func specs(paragraph: Bool, prefix: String, noun: String) -> [CommandSpec] {
        [
            CommandSpec("\(prefix).new", "New \(noun) Style",
                        params: #"{"name":str?,"# + attrsDoc + #"?,"fromSelection":bool=true (start from the targeted text's formatting),"apply":bool=false,"# + targetDoc + #"} → {"id","name"}"#,
                        module: m, enabled: T.hasDoc) { s, p in try newStyle(s, p, paragraph) },
            CommandSpec("\(prefix).duplicate", "Duplicate Style", params: #"{"id":u32}"#, module: m, enabled: T.hasDoc) { s, p in try duplicate(s, p, paragraph) },
            CommandSpec("\(prefix).delete", "Delete Style", params: #"{"id":u32} (text keeps its formatting as overrides)"#, module: m, enabled: T.hasDoc) { s, p in
                try delete(s, p, paragraph)
            },
            CommandSpec("\(prefix).rename", "Rename Style", params: #"{"id":u32,"name":str}"#, module: m, enabled: T.hasDoc) { s, p in try rename(s, p, paragraph) },
            CommandSpec("\(prefix).set", "\(noun) Style Options",
                        params: #"{"id":u32 (paragraph: 0 = Basic Paragraph),"name":str?,"# + attrsDoc + #","replace":bool=false (drop attributes not given),"clear":[field]?} (text using the style updates, overrides kept)"#,
                        module: m, enabled: T.hasDoc) { s, p in try setOptions(s, p, paragraph) },
            CommandSpec("\(prefix).apply", "Apply \(noun) Style",
                        params: #"{"id":u32|0|null (0/null: None / Basic Paragraph),"clearOverrides":bool=false (Alt-click),"# + targetDoc + "}",
                        module: m, enabled: hasTarget) { s, p in try apply(s, p, paragraph) },
            CommandSpec("\(prefix).redefine", "Redefine \(noun) Style",
                        params: #"{"id":u32? (default: the targeted text's style),"# + targetDoc + "} (the style takes the formatting of the start of the targeted text)",
                        module: m, enabled: hasTarget) { s, p in try redefine(s, p, paragraph) },
            CommandSpec("\(prefix).clearOverride", "Clear Override", params: "{" + targetDoc + "}", module: m, enabled: hasTarget) { s, p in
                try clearOverride(s, p, paragraph)
            },
            CommandSpec("\(prefix).list", "List \(noun) Styles",
                        params: "{" + targetDoc + #"} → {"styles":[{"id","name",attributes,"resolved"}],"current":{"character":id|null (mixed),"characterOverride":bool,"paragraph":id|null,"paragraphOverride":bool}}"#,
                        module: m, journal: false, enabled: T.hasDoc) { s, p in try list(s, p, paragraph) },
        ]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(specs(paragraph: false, prefix: "type.characterStyle", noun: "Character"))
        r.add(specs(paragraph: true, prefix: "type.paragraphStyle", noun: "Paragraph"))
    }
}
