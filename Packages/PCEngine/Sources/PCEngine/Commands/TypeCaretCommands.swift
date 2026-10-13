// Port of photocraft-engine (crates/engine/src/type_caret_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Headless caret geometry for type layers: `type.hitTest`, `type.caret`, `type.navigate`.
//
// Queries (`journal: false`, no history step). Positions are document pixels, so an agent never
// touches text space; offsets are character indices, the same unit as `type.edit` and
// `type.setStyle`. The geometry is `TypeCommands.Layout` (photocraft-text's caret, hit-test, word
// and line helpers over PCPlatform's CoreText layout).

import Foundation
import PCDocument
import PCFoundation

enum TypeCaretCommands: CommandModule {
    static let name = "type_caret_cmds"
    static let m = name
    typealias T = TypeCommands

    static func reqF64(_ p: JSONValue, _ key: String, _ cmd: String) throws -> Double {
        guard let v = p[key] else { throw EngineError.bad(cmd, "missing `\(key)`") }
        guard let n = v.doubleValue, n.isFinite else { throw EngineError.bad(cmd, "`\(key)` must be a finite number") }
        return n
    }

    /// `x` when present. Absent is fine; a present non-number is not.
    static func optF64(_ p: JSONValue, _ key: String, _ cmd: String) throws -> Double? {
        switch p[key] {
        case nil, .null?: return nil
        default: return try reqF64(p, key, cmd)
        }
    }

    static func reqIndex(_ p: JSONValue, _ key: String, _ cmd: String) throws -> Int {
        guard let v = p[key] else { throw EngineError.bad(cmd, "missing `\(key)`") }
        guard let n = v.uint64Value else { throw EngineError.bad(cmd, "`\(key)` must be a character index") }
        guard let i = Int(exactly: n) else { throw EngineError.bad(cmd, "`\(key)` is out of range") }
        return i
    }

    static func checkIndex(_ text: String, _ index: Int, _ cmd: String) throws {
        let n = T.charCount(text)
        if index > n { throw EngineError.bad(cmd, "index \(index) is past the end of the text (\(n) characters)") }
    }

    static func resolveLayer(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> LayerId {
        if let v = p["layer"], v != .null {
            guard let id = v.uint64Value else { throw EngineError.bad(cmd, "`layer` must be a layer id") }
            return LayerId(id)
        }
        guard let id = s.active?.activeLayer else { throw EngineError.other("no active layer") }
        return id
    }

    /// A type layer laid out once, plus the bits of it the queries need.
    struct Frame {
        var id: LayerId
        var text: String
        var transform: PCAffine
        /// Rendered ink in document pixels (empty text has none).
        var ink: PixelRect?
        var layout: T.Layout

        /// Same hit as the Type tool, without its zoom slop: the laid-out line boxes or the rendered ink.
        func contains(_ x: Double, _ y: Double) -> Bool {
            let (tx, ty) = TypeCaretCommands.toText(transform, x, y)
            if layout.contains(tx, ty, slop: 0) { return true }
            guard let r = ink else { return false }
            return x >= Double(r.x0) && x <= Double(r.x1) && y >= Double(r.y0) && y <= Double(r.y1)
        }
    }

    static func frame(_ doc: Document, _ id: LayerId, _ cmd: String) throws -> Frame {
        guard let layer = doc.layer(id) else { throw EngineError.noLayer(id) }
        guard case .text(let t) = layer.content else {
            throw EngineError.bad(cmd, "layer \(id.rawValue) is \(layer.content.article) \(layer.content.kindName) layer, not a type layer")
        }
        let ink = t.cache.map(\.contentBounds).flatMap { $0.isEmpty ? nil : $0 }
        return Frame(id: id, text: t.text, transform: t.transform, ink: ink, layout: T.Layout(t, dpi: Double(doc.resolutionDpi)))
    }

    static func toText(_ aff: PCAffine, _ x: Double, _ y: Double) -> (Double, Double) {
        let p = (aff.inverse ?? .identity).apply(PCPoint(x, y))
        return (p.x, p.y)
    }

    static func docPoint(_ aff: PCAffine, _ x: Double, _ y: Double, _ cmd: String) throws -> JSONValue {
        let p = aff.apply(PCPoint(x, y))
        guard p.x.isFinite && p.y.isFinite else { throw EngineError.bad(cmd, "the caret is not a finite point") }
        return [.number(p.x), .number(p.y)]
    }

    /// Topmost visible type layer under the point (`walk` is bottom-up; the Type tool hits the top first).
    static func topmost(_ doc: Document, _ x: Double, _ y: Double) -> Frame? {
        let ids = doc.walk().filter { e in
            T.isText(e.layer) && e.path.indices.allSatisfy { n in doc.layer(at: Array(e.path.prefix(n + 1)))?.visible ?? false }
        }.map(\.layer.id)
        for id in ids.reversed() {
            if let f = try? frame(doc, id, "type.hitTest"), f.contains(x, y) { return f }
        }
        return nil
    }

    /// Line-space column for a document x. Translate and scale keep that x as the same column on
    /// every line; when a rotation makes document x independent of the column, the caret's own
    /// column is kept.
    static func column(_ layout: T.Layout, _ aff: PCAffine, _ text: String, _ index: Int, _ docX: Double?) -> Double {
        let (x, top, bottom) = layout.caret(T.byteAt(text, index))
        guard let docX else { return x }
        let y = (top + bottom) * 0.5
        // Horizontal: text = (line_x, line_y). Vertical: text = (-line_y, line_x).
        let (coef, along) = layout.vertical ? (aff.c, docX - aff.e + aff.a * y) : (aff.a, docX - aff.e - aff.c * y)
        if abs(coef) < 1e-8 { return x }
        let solved = along / coef
        return solved.isFinite ? solved : x
    }

    /// Nearest caret to a text-space point: character index and the line it sits on.
    static func hitChar(_ layout: T.Layout, _ text: String, _ x: Double, _ y: Double) -> (Int, Int) {
        let byte = layout.hitTest(x, y)
        // At a soft-wrap boundary either visual line can share this byte offset; the pointer's
        // line is authoritative.
        let (_, lineY) = layout.toLine(x, y)
        let line = layout.closestLine(lineY) ?? layout.lineIndex(byte)
        return (T.charAt(text, byte), line)
    }

    /// Character index of the word boundary before (`forward` false) or after `idx`; a word is a
    /// run of alphanumeric characters.
    static func wordBoundary(_ text: String, _ idx: Int, forward: Bool) -> Int {
        let chars = Array(text.unicodeScalars)
        func alnum(_ c: Unicode.Scalar) -> Bool { c.properties.isAlphabetic || c.properties.numericType != nil }
        var i = min(idx, chars.count)
        if forward {
            while i < chars.count && !alnum(chars[i]) { i += 1 }
            while i < chars.count && alnum(chars[i]) { i += 1 }
        } else {
            while i > 0 && !alnum(chars[i - 1]) { i -= 1 }
            while i > 0 && alnum(chars[i - 1]) { i -= 1 }
        }
        return i
    }

    /// Caret on the neighbouring line keeping line-space `x`; past the first or last line the caret
    /// goes to the start or end of the text.
    static func lineStep(_ layout: T.Layout, _ text: String, _ idx: Int, _ x: Double, _ dir: Int) -> Int {
        let n = T.charCount(text)
        let idx = min(idx, n)
        if layout.lines.isEmpty { return idx }
        let current = layout.lineIndex(T.byteAt(text, idx))
        let target: Int
        if dir < 0 {
            guard current > 0 else { return 0 }
            target = current - 1
        } else {
            guard current + 1 < layout.lines.count else { return n }
            target = current + 1
        }
        return T.charAt(text, layout.hitTestXOnLine(target, x))
    }

    /// Line start (`end` false) or end for the line containing `idx`, as a character index.
    static func lineEdge(_ layout: T.Layout, _ text: String, _ idx: Int, end: Bool) -> Int {
        let n = T.charCount(text)
        let idx = min(idx, n)
        let li = layout.lineIndex(T.byteAt(text, idx))
        guard li < layout.lines.count else { return idx }
        let ln = layout.lines[li]
        return T.charAt(text, end ? ln.range.upperBound : ln.range.lowerBound)
    }

    // MARK: Commands

    @Sendable static func hitTest(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "type.hitTest"
        let x = try reqF64(p, "x", cmd), y = try reqF64(p, "y", cmd)
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        let f: Frame
        if let v = p["layer"], v != .null {
            guard let id = v.uint64Value else { throw EngineError.bad(cmd, "`layer` must be a layer id") }
            f = try frame(doc, LayerId(id), cmd)
        } else {
            guard let hit = topmost(doc, x, y) else { throw EngineError.bad(cmd, "no type layer under the point") }
            f = hit
        }
        let (tx, ty) = toText(f.transform, x, y)
        let (index, line) = hitChar(f.layout, f.text, tx, ty)
        return ["layer": .id(f.id), "index": .int(index), "line": .int(line), "inside": .bool(f.contains(x, y))]
    }

    @Sendable static func caret(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "type.caret"
        let index = try reqIndex(p, "index", cmd)
        let id = try resolveLayer(s, p, cmd)
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        let f = try frame(doc, id, cmd)
        try checkIndex(f.text, index, cmd)
        let byte = T.byteAt(f.text, index)
        let seg = f.layout.caretSegment(byte)
        let p0 = try docPoint(f.transform, seg[0].0, seg[0].1, cmd)
        let p1 = try docPoint(f.transform, seg[1].0, seg[1].1, cmd)
        return ["index": .int(index), "line": .int(f.layout.lineIndex(byte)), "segment": [p0, p1]]
    }

    @Sendable static func navigate(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "type.navigate"
        let index = try reqIndex(p, "index", cmd)
        guard let mov = p["move"]?.stringValue else { throw EngineError.bad(cmd, "missing `move`") }
        let docX = try optF64(p, "x", cmd)
        let id = try resolveLayer(s, p, cmd)
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        let f = try frame(doc, id, cmd)
        try checkIndex(f.text, index, cmd)
        let next: Int
        switch mov {
        case "wordPrev": next = wordBoundary(f.text, index, forward: false)
        case "wordNext": next = wordBoundary(f.text, index, forward: true)
        case "linePrev", "lineNext":
            let x = column(f.layout, f.transform, f.text, index, docX)
            next = lineStep(f.layout, f.text, index, x, mov == "linePrev" ? -1 : 1)
        case "lineStart": next = lineEdge(f.layout, f.text, index, end: false)
        case "lineEnd": next = lineEdge(f.layout, f.text, index, end: true)
        case "start": next = 0
        case "end": next = T.charCount(f.text)
        default:
            throw EngineError.bad(cmd, "move \(TypeSpellCommands.debugQuoted(mov)) must be wordPrev, wordNext, linePrev, lineNext, lineStart, lineEnd, start or end")
        }
        return ["index": .int(next)]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("type.hitTest", "Hit-Test Type",
                          params: ##"{"layer":id?, "x":px, "y":px} → {"layer","index":char,"line","inside":bool}. No layer: the topmost visible type layer whose laid-out text or rendered pixels contain the point (same order as the Type tool); a miss is an error. With a layer, index is the nearest caret even when inside is false"##,
                          module: m, journal: false, enabled: T.hasDoc, run: hitTest))
        r.add(CommandSpec("type.caret", "Type Caret",
                          params: ##"{"layer":id?, "index":char (0..=length; empty text is 0)} → {"index","line","segment":[[x,y],[x,y]]} caret segment in document pixels, for rotated and vertical type too"##,
                          module: m, journal: false, enabled: T.hasDoc, run: caret))
        r.add(CommandSpec("type.navigate", "Navigate Type",
                          params: ##"{"layer":id?, "index":char, "move":"wordPrev|wordNext|linePrev|lineNext|lineStart|lineEnd|start|end", "x":px?} → {"index"}. Words are alphanumeric runs. x is the document x to keep across linePrev/lineNext (a caret segment's x); omitted uses the caret's own column. Empty text returns index 0"##,
                          module: m, journal: false, enabled: T.hasDoc, run: navigate))
    }
}
