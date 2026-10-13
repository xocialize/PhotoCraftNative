// Port of photocraft-engine (crates/engine/src/guide_layout.rs, and the guide commands of crates/engine/src/file_cmds.rs: view.newGuideLayout, view.newGuidesFromShape, view.clearCanvasGuides), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// View › New Guide Layout (the pure layout calculation is shared by the command and the dialog's
// non-destructive preview: `calculate`), View › New Guides From Shape and View › Clear Canvas
// Guides. The three commands live in photocraft's file_cmds.rs and are registered under that
// module name.

import Foundation
import PCDocument
import PCFoundation

enum GuideLayoutCommands: CommandModule {
    static let name = "guide_layout"
    /// The photocraft module the commands are registered under.
    static let m = "file_cmds"

    static let command = "view.newGuideLayout"
    static let maxCount: UInt64 = 1000
    static let maxEdges: UInt64 = 16_000

    static func bad(_ message: String) -> EngineError { .bad(command, message) }

    static func number(_ p: JSONValue, _ key: String, _ fallback: Double) throws -> Double {
        guard let v = p[key], v != .null else { return fallback }
        guard let n = v.doubleValue, n.isFinite, n >= 0 else { throw bad("\(key) must be a finite non-negative number") }
        return n
    }

    static func count(_ p: JSONValue, _ key: String) throws -> UInt64 {
        var n: UInt64 = 0
        if let v = p[key] {
            guard let c = v.uint64Value else { throw bad("\(key) must be a whole number") }
            n = c
        }
        // Each column/row costs a loop iteration plus a duplicate scan: an absurd count would block
        // the app for minutes (#704). Photoshop's dialog caps at 32; 1000 still finishes instantly.
        if n > maxCount { throw bad("\(key) must be \(maxCount) or fewer (got \(n))") }
        return n
    }

    static func flag(_ p: JSONValue, _ key: String) throws -> Bool {
        guard let v = p[key] else { return false }
        guard let b = v.boolValue else { throw bad("\(key) must be a boolean") }
        return b
    }

    /// Document coordinates of every selected artboard, including boards containing selected layers.
    static func selectedArtboards(_ s: Session) -> [PixelRect] {
        guard let st = s.active else { return [] }
        let ids = Set(st.selectedLayers.compactMap { st.doc.artboard(of: $0) })
        return st.doc.artboards.filter { ids.contains($0.id) }.map(\.artboard.rect)
    }

    static func targets(_ s: Session, _ p: JSONValue) throws -> [PixelRect] {
        guard let st = s.active else { throw EngineError.noDocument }
        var target = "document"
        if let v = p["target"] {
            guard let t = v.stringValue else { throw bad("target must be a string") }
            target = t
        }
        switch target {
        case "document": return [st.doc.bounds]
        case "selectedArtboards":
            let boards = selectedArtboards(s)
            if boards.isEmpty { throw bad("select an artboard or a layer inside one") }
            return boards
        default: throw bad("target must be document or selectedArtboards")
        }
    }

    static func pushUnique(_ out: inout [Double], _ value: Double) throws {
        if !value.isFinite { throw bad("guide coordinates exceed the supported range") }
        if !out.contains(where: { abs($0 - value) < 0.01 }) { out.append(value) }
    }

    /// Guide positions for `count` columns (or rows) across `[start, end]`, Photoshop-style: both
    /// edges of every column; a fixed `width` packs columns from `start` (or centres them).
    static func axis(_ start: Double, _ end: Double, _ count: UInt64, _ fixed: Double, _ gap: Double, _ center: Bool, _ out: inout [Double]) throws {
        if count == 0 { return }
        let available = end - start
        let n = Double(count)
        let width = fixed > 0 ? fixed : (available - (n - 1) * gap) / n
        let total = n * width + (n - 1) * gap
        if width <= 0 || !total.isFinite || total > available + 0.001 {
            throw bad("count, size and gutter must fit inside the target margins")
        }
        let origin = center && fixed > 0 ? start + (available - total) / 2 : start
        for i in 0..<count {
            let a = origin + Double(i) * (width + gap)
            try pushUnique(&out, a)
            try pushUnique(&out, a + width)
        }
    }

    /// New lines and the exact guide set that OK will commit.
    struct Layout: Sendable {
        var added: Guides
        var guides: Guides
    }

    /// The layout `p` describes over the active document. Never edits the session (the dialog's
    /// preview calls it on every change).
    static func calculate(_ s: Session, _ p: JSONValue) throws -> Layout {
        guard let st = s.active else { throw EngineError.noDocument }
        let cols = try count(p, "columns")
        let rows = try count(p, "rows")
        let width = try number(p, "width", 0)
        let height = try number(p, "height", 0)
        let gap = try number(p, "gutter", 0)
        let rowGap = try number(p, "rowGutter", gap)
        let center = try flag(p, "centerColumns")
        let clear = try flag(p, "clearExisting")
        let margins: [Double]
        if case .array(let a)? = p["margin"] {
            if a.count != 4 { throw bad("margin must contain top, left, bottom and right") }
            margins = try a.map { v in
                guard let x = v.doubleValue, x.isFinite, x >= 0 else { throw bad("margins must be finite non-negative numbers") }
                return x
            }
        } else {
            margins = Array(repeating: try number(p, "margin", 0), count: 4)
        }
        let (top, left, bottom, right) = (margins[0], margins[1], margins[2], margins[3])
        let bounds = try targets(s, p)
        // Bound the aggregate work as well as each count, including multi-artboard requests.
        // (Counts are at most `maxCount`, so the products can't overflow.)
        if (cols + rows + 4) * 2 * UInt64(bounds.count) > maxEdges { throw bad("the selected targets would create too many guide lines") }
        var added = Guides()
        for rect in bounds {
            let (x0, y0, x1, y1) = (Double(rect.x0) + left, Double(rect.y0) + top, Double(rect.x1) - right, Double(rect.y1) - bottom)
            if x0 >= x1 || y0 >= y1 { throw bad("margins must leave space inside the target") }
            if margins.contains(where: { $0 != 0 }) {
                try pushUnique(&added.vertical, x0)
                try pushUnique(&added.vertical, x1)
                try pushUnique(&added.horizontal, y0)
                try pushUnique(&added.horizontal, y1)
            }
            try axis(x0, x1, cols, width, gap, center, &added.vertical)
            try axis(y0, y1, rows, height, rowGap, center, &added.horizontal)
        }
        if added.vertical.isEmpty && added.horizontal.isEmpty { throw bad(#"give "columns", "rows" or a "margin""#) }
        var guides = st.doc.guides
        if clear {
            if p["target"]?.stringValue == "selectedArtboards" {
                // Guides are stored as document-wide axes, matching Clear Selected Artboard Guides.
                guides.vertical.removeAll { v in bounds.contains { v >= Double($0.x0) && v <= Double($0.x1) } }
                guides.horizontal.removeAll { v in bounds.contains { v >= Double($0.y0) && v <= Double($0.y1) } }
            } else {
                guides = Guides()
            }
            // Cleared guides take their colours along, so a new guide at the same place doesn't
            // inherit one.
            guides.pruneColors()
        }
        for x in added.vertical { try pushUnique(&guides.vertical, x) }
        for y in added.horizontal { try pushUnique(&guides.horizontal, y) }
        return Layout(added: added, guides: guides)
    }

    static func apply(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let layout = try calculate(s, p)
        let result: JSONValue = ["vertical": .int(layout.added.vertical.count), "horizontal": .int(layout.added.horizontal.count)]
        try s.edit("New Guide Layout") { doc, _ in doc.guides = layout.guides }
        return result
    }

    // MARK: file_cmds guides

    /// file_cmds `push_unique` (no range check).
    static func pushUniquePlain(_ v: inout [Double], _ x: Double) {
        if !v.contains(where: { abs($0 - x) < 0.01 }) { v.append(x) }
    }

    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document open" : nil }

    static let hasShape: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        if let id = d.activeLayer, let l = d.doc.layer(id), case .shape = l.content { return nil }
        return "the active layer is not a shape layer"
    }

    static func guidesFromShape(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        guard let d = s.active else { throw EngineError.noDocument }
        guard let l = d.doc.layer(id) else { throw EngineError.noLayer(id) }
        guard case .shape(let sh) = l.content else { throw EngineError.other("the layer is not a shape layer") }
        guard let b = sh.path.controlBounds else { throw EngineError.other("the shape has no path") }
        let (x0, y0, x1, y1) = (b.x, b.y, b.z, b.w)
        try s.edit("New Guides From Shape") { doc, _ in
            for x in [x0, (x0 + x1) / 2, x1] { pushUniquePlain(&doc.guides.vertical, x) }
            for y in [y0, (y0 + y1) / 2, y1] { pushUniquePlain(&doc.guides.horizontal, y) }
        }
        return ["bounds": .doubles([x0, y0, x1, y1])]
    }

    static func clearCanvasGuides(_ s: Session) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        // Guides inside an artboard belong to it (View › Clear Selected Artboard Guides); the rest
        // are canvas guides. Without artboards every guide is a canvas guide.
        let boards = d.doc.artboards.map(\.artboard.rect)
        let inX = { (x: Double) in boards.contains { x > Double($0.x0) && x < Double($0.x1) } }
        let inY = { (y: Double) in boards.contains { y > Double($0.y0) && y < Double($0.y1) } }
        let n = d.doc.guides.vertical.filter { !inX($0) }.count + d.doc.guides.horizontal.filter { !inY($0) }.count
        if n == 0 { return ["cleared": 0] }
        try s.edit("Clear Canvas Guides") { doc, _ in
            doc.guides.vertical.removeAll { !inX($0) }
            doc.guides.horizontal.removeAll { !inY($0) }
            doc.guides.pruneColors()
        }
        return ["cleared": .int(n)]
    }

    static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("view.newGuideLayout", "New Guide Layout…", menu: ["View"],
                        params: #"{"columns":n=0,"width":px?,"gutter":px=0,"rows":n=0,"height":px?,"rowGutter":px=gutter,"margin":px|[top,left,bottom,right]=0,"centerColumns":bool=false,"clearExisting":bool=false,"target":"document|selectedArtboards"="document"}"#,
                        module: m, enabled: hasDoc) { s, p in try apply(s, p) },
            CommandSpec("view.newGuidesFromShape", "New Guides From Shape", menu: ["View"], params: #"{"layer":id?}"#,
                        module: m, enabled: hasShape) { s, p in try guidesFromShape(s, p) },
            CommandSpec("view.clearCanvasGuides", "Clear Canvas Guides", menu: ["View"], params: "{}",
                        module: m, enabled: hasDoc) { s, _ in try clearCanvasGuides(s) },
        ])
    }
}
