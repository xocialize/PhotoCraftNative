// Port of photocraft-engine (crates/engine/src/artboard_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Artboards: Layer › New › Artboard (from scratch, a group or the selected layers), artboard
// properties (board rect, background, preset), View › Clear Selected Artboard Guides, and
// File › Export › Artboards to Files / to PDF.
//
// An artboard is a top-level group with `Artboard` set; the compositor clips its children to the
// board and paints its background. Moving the group (Move tool, `layer.translate`) moves the board
// with its contents. The canvas grows to fit every board, in every direction, like Photoshop's
// auto-expanding artboard canvas (`fitCanvas`).

import Foundation
import PCDocument
import PCFoundation
import PCPlatform

enum ArtboardCommands: CommandModule {
    static let name = "artboard_cmds"
    static let m = "artboard_cmds"

    /// Artboard size presets (name, width, height) in pixels, Photoshop's common devices and pages.
    static let presets: [(String, Int64, Int64)] = [
        ("iPhone 14", 390, 844),
        ("iPhone 14 Pro Max", 430, 932),
        ("Android 1080p", 360, 640),
        ("iPad Pro 12.9", 1024, 1366),
        ("Web 1280", 1280, 800),
        ("Web 1366", 1366, 768),
        ("Web 1920", 1920, 1080),
        ("Instagram Post", 1080, 1080),
        ("Letter", 612, 792),
        ("A4", 595, 842),
    ]

    /// Gap Photoshop leaves between a new artboard and the rightmost existing one.
    static let gap: Int64 = 100

    // MARK: Preconditions

    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document open" : nil }

    static let hasArtboards: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.hasArtboards ? nil : "the document has no artboards"
    }

    /// The active layer's artboard (the layer itself or its top-level ancestor).
    static func activeArtboard(_ s: Session) -> LayerId? {
        guard let d = s.active, let a = d.activeLayer else { return nil }
        return d.doc.artboard(of: a)
    }

    static let hasActiveArtboard: CommandEnabled = { s, _ in
        activeArtboard(s) == nil ? "select an artboard (or a layer inside one)" : nil
    }

    static let hasPlainGroup: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        guard let id = d.activeLayer else { return "no active layer" }
        guard let l = d.doc.layer(id) else { return "no active layer" }
        if !l.isGroup || l.artboard != nil { return "select a layer group" }
        if !d.doc.layers.contains(where: { $0.id == id }) { return "artboards must be top-level: select a group that is not nested" }
        return nil
    }

    static let hasFreeLayers: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        let sel = d.selectedLayers
        if sel.isEmpty { return "select one or more layers" }
        if sel.contains(where: { d.doc.artboard(of: $0) != nil }) { return "the selection is already in an artboard" }
        return nil
    }

    // MARK: Params

    /// photocraft `commands::int`: a whole number (floats rounded, saturating), nil otherwise.
    static func int(_ v: JSONValue?) -> Int64? {
        guard let d = v?.doubleValue, d.isFinite else { return nil }
        let r = d.rounded()
        if r >= 9.223372036854775807e18 { return .max }
        if r <= -9.223372036854775808e18 { return .min }
        return Int64(r)
    }

    /// photocraft `int_i32`: nil when absent, a bad-params error when it doesn't fit 32 bits.
    static func intI32(_ cmd: String, _ p: JSONValue, _ key: String) throws -> Int64? {
        guard let v = int(p[key]) else { return nil }
        guard Int32(exactly: v) != nil else { throw EngineError.bad(cmd, "`\(key)` = \(v) is outside the 32-bit coordinate range") }
        return v
    }

    /// ASCII-only lowercase (Rust `eq_ignore_ascii_case`).
    static func asciiLower(_ s: String) -> String {
        String(decoding: s.utf8.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }, as: UTF8.self)
    }

    static func presetSize(_ name: String) -> (Int64, Int64)? {
        let want = asciiLower(name)
        return presets.first { asciiLower($0.0) == want }.map { ($0.1, $0.2) }
    }

    static func backgroundParam(_ p: JSONValue, _ cmd: String) throws -> ArtboardBackground? {
        let custom: ArtboardBackground? = p["color"] == nil ? nil : {
            let c = Params.color(p, "color", SIMD4(1, 1, 1, 1))
            return .custom(.rgb(c.x, c.y, c.z, c.w))
        }()
        switch p["background"]?.stringValue {
        case nil: return custom
        case "white": return .white
        case "black": return .black
        case "transparent": return .transparent
        case "custom", "other": return custom ?? .white
        case let o?: throw EngineError.bad(cmd, "unknown background `\(o)` (white|black|transparent|custom)")
        }
    }

    /// A board rect from `x, y, width, height`, or a bad-params error naming them when an edge
    /// falls outside the 32-bit coordinate range (#931).
    static func boardRect(_ cmd: String, _ v: [Int64]) throws -> PixelRect {
        let (x, y, w, h) = (v[0], v[1], v[2], v[3])
        if w <= 0 || h <= 0 { throw EngineError.bad(cmd, "the artboard size must be positive (width = \(w), height = \(h))") }
        func span(_ a: Int64, _ len: Int64) -> (Int32, Int32)? {
            guard let a0 = Int32(exactly: a) else { return nil }
            let (e, o) = a.addingReportingOverflow(len)
            guard !o, let a1 = Int32(exactly: e) else { return nil }
            return (a0, a1)
        }
        guard let (x0, x1) = span(x, w), let (y0, y1) = span(y, h) else {
            throw EngineError.bad(cmd, "the artboard [x, y, width, height] = [\(x), \(y), \(w), \(h)] reaches outside the 32-bit coordinate range (\(Int32.min)..=\(Int32.max))")
        }
        return PixelRect(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    /// `rect` as `[x, y, w, h]` or `x`/`y`/`width`/`height` keys over `base`.
    static func rectParam(_ p: JSONValue, _ base: [Int64], _ cmd: String) throws -> PixelRect {
        if case .array(let a)? = p["rect"] {
            let v = a.compactMap { int($0) }
            guard v.count == 4 else { throw EngineError.bad(cmd, #""rect" must be [x, y, width, height] with a positive size"#) }
            return try boardRect(cmd, v)
        }
        let x = try intI32(cmd, p, "x") ?? base[0]
        let y = try intI32(cmd, p, "y") ?? base[1]
        let w = int(p["width"]) ?? base[2]
        let h = int(p["height"]) ?? base[3]
        return try boardRect(cmd, [x, y, w, h])
    }

    static func xywh(_ r: PixelRect) -> [Int64] { [Int64(r.x0), Int64(r.y0), Int64(r.width), Int64(r.height)] }

    // MARK: Canvas

    /// Every surface a document translation moves (photocraft `image_cmds::for_each_surface`).
    static func forEachSurface(_ layers: [Layer], _ body: (Surface) -> Void) {
        for l in layers {
            if let m = l.mask { body(m.surface) }
            if let fc = l.fillCache { body(fc.surface) }
            switch l.content {
            case .raster(let s): body(s)
            case .text(let t): if let c = t.cache { body(c) }
            case .shape(let sh): if let c = sh.cache { body(c) }
            case .smart(let sm):
                if let c = sm.cache { body(c) }
                if let m = sm.filterMask { body(m.surface) }
            case .group(let g): forEachSurface(g.children, body)
            case .adjustment, .fill: break
            }
        }
    }

    /// photocraft `image_cmds::translate_doc`: moves everything by (dx, dy), refusing (before
    /// anything moves) a move that would push pixels outside the 32-bit range.
    static func translateDoc(_ doc: inout Document, _ cmd: String, _ dx: Int32, _ dy: Int32) throws {
        try ImageCommands.translateDocument(&doc, cmd, dx, dy)
    }

    /// Grow the canvas so every artboard fits (photocraft `fit_canvas`). A board left of or above
    /// the origin shifts the whole document right/down by its overhang, then the canvas grows to
    /// show it. An axis whose boards span more than the largest canvas, or a shift that would push
    /// pixels past the 32-bit range, stays unshifted.
    static func fitCanvas(_ doc: inout Document) {
        let maxDim = Int64(CoreCommands.maxDimension)
        let boards = doc.artboards.map(\.artboard.rect)
        var (x0, x1) = (Int64(0), Int64(doc.size.width))
        var (y0, y1) = (Int64(0), Int64(doc.size.height))
        for b in boards {
            x0 = min(x0, Int64(b.x0)); x1 = max(x1, Int64(b.x1))
            y0 = min(y0, Int64(b.y0)); y1 = max(y1, Int64(b.y1))
        }
        func shift(_ lo: Int64, _ hi: Int64) -> Int32 { hi - lo <= maxDim ? (Int32(exactly: -lo) ?? 0) : 0 }
        var (sx, sy) = (shift(x0, x1), shift(y0, y1))
        if sx != 0 || sy != 0 {
            do { try translateDoc(&doc, "artboard", sx, sy) } catch { (sx, sy) = (0, 0) }
        }
        let size = PixelSize(width: Int(min(max(x1 + Int64(sx), 1), maxDim)), height: Int(min(max(y1 + Int64(sy), 1), maxDim)))
        if size != doc.size {
            doc.size = size
            // Shape pixels are cut at the canvas: re-render them against the grown canvas (#2389).
            CanvasGeometry.refresh(&doc, .shapes)
        }
    }

    static func nextArtboardName(_ doc: Document) -> String {
        let names = doc.artboards.map(\.name)
        return (1...(names.count + 1)).map { "Artboard \($0)" }.first { !names.contains($0) } ?? "Artboard"
    }

    static func setArtboard(_ l: inout Layer, _ a: Artboard) {
        l.withGroup { g in
            g.artboard = a
            g.expanded = true
        }
        // Artboards composite like pass-through groups.
        l.clipped = false
    }

    static func result(_ id: LayerId, _ r: PixelRect) -> JSONValue { ["layer": .id(id), "rect": .rect(r)] }

    // MARK: Commands

    static func newArtboard(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layer.new.artboard"
        guard let d = s.active else { throw EngineError.noDocument }
        let preset = p["preset"]?.stringValue ?? ""
        let (pw, ph): (Int64, Int64)
        if preset.isEmpty {
            (pw, ph) = (Int64(d.doc.size.width), Int64(d.doc.size.height))
        } else {
            guard let sz = presetSize(preset) else { throw EngineError.bad(cmd, "unknown preset `\(preset)`") }
            (pw, ph) = sz
        }
        // Default placement: right of the rightmost artboard, else the canvas origin.
        let boards = d.doc.artboards
        let right = boards.map(\.artboard.rect.x1).max()
        let top = boards.map(\.artboard.rect.y0).min() ?? 0
        let base: [Int64] = right.map { [Int64($0) + gap, Int64(top), pw, ph] } ?? [0, 0, pw, ph]
        // With no room right of the rightmost board, ask for a position; an explicit `x` (or
        // `rect`) still works.
        let explicitX = p["rect"] != nil || p.has("x")
        if let edge = right, !explicitX, base[0] > Int64(Int32.max) {
            throw EngineError.bad(cmd, "no room for a new artboard right of the rightmost one (its right edge is x = \(edge)); pass \"x\" to place it")
        }
        // A preset decides the size (dialogs send the canvas size alongside it).
        let rect = preset.isEmpty || p["rect"] != nil
            ? try rectParam(p, base, cmd)
            : try rectParam(["x": p["x"] ?? .null, "y": p["y"] ?? .null], base, cmd)
        let background = try backgroundParam(p, cmd) ?? .white
        let name = p["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let id = try s.edit("New Artboard") { doc, active -> LayerId in
            var g = Layer.group(name ?? nextArtboardName(doc), [])
            setArtboard(&g, Artboard(rect: rect, background: background, preset: preset))
            let id = doc.insertAbove(nil, g)
            fitCanvas(&doc)
            active = id
            return id
        }
        try LayerMulti.setSelection(s, [id], active: id, anchor: id)
        return result(id, rect)
    }

    static func artboardFromGroup(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        guard let id = Params.layerId(p) ?? d.activeLayer else { throw EngineError.other("no active layer") }
        let canvas = d.doc.bounds
        let background = try backgroundParam(p, "layer.new.artboardFromGroup") ?? .white
        let rect = try s.edit("Artboard from Group") { doc, active -> PixelRect in
            guard doc.layers.contains(where: { $0.id == id && $0.isGroup && $0.artboard == nil }) else {
                throw EngineError.other("artboards are made from a top-level layer group")
            }
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            let rect = LayerOps.layerBounds(l) ?? canvas
            doc.updateLayer(id) { setArtboard(&$0, Artboard(rect: rect, background: background, preset: "")) }
            fitCanvas(&doc)
            active = id
            return rect
        }
        return result(id, rect)
    }

    static func artboardFromLayers(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let sel = LayerMulti.selected(s)
        guard let d = s.active else { throw EngineError.noDocument }
        let canvas = d.doc.bounds
        let name = p["name"]?.stringValue
        let background = try backgroundParam(p, "layer.new.artboardFromLayers") ?? .white
        let (gid, rect) = try s.edit("Artboard from Layers") { doc, active -> (LayerId, PixelRect) in
            let ids = LayerOps.topLevel(doc, sel)
            if ids.isEmpty || ids.contains(where: { doc.artboard(of: $0) != nil }) {
                throw EngineError.other("select layers that are not in an artboard")
            }
            var children: [Layer] = []
            children.reserveCapacity(ids.count)
            for id in ids {
                guard let l = doc.remove(id) else { throw EngineError.noLayer(id) }
                children.append(l)
            }
            let rect = children.compactMap(LayerOps.layerBounds).reduce(nil as PixelRect?) { a, b in a.map { $0.union(b) } ?? b } ?? canvas
            var g = Layer.group(name ?? nextArtboardName(doc), children)
            setArtboard(&g, Artboard(rect: rect, background: background, preset: ""))
            let gid = doc.insertAbove(nil, g)
            try LayerOps.checkGroupDepth(doc, "Artboard from Layers")
            fitCanvas(&doc)
            active = gid
            return (gid, rect)
        }
        try LayerMulti.setSelection(s, [gid], active: gid, anchor: gid)
        return result(gid, rect)
    }

    /// Properties panel / Artboard tool: board position and size, background, preset, name.
    /// Changing X/Y moves the board with its contents; changing W/H resizes it from the top left.
    static func setProps(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layer.artboard.set"
        guard let d = s.active else { throw EngineError.noDocument }
        let id: LayerId
        if let v = p["layer"]?.uint64Value {
            id = LayerId(v)
        } else {
            guard let a = activeArtboard(s) else { throw EngineError.bad(cmd, "no artboard selected") }
            id = a
        }
        guard let old = d.doc.layer(id)?.artboard else { throw EngineError.bad(cmd, "the layer is not an artboard") }
        let preset = p["preset"]?.stringValue
        var base = xywh(old.rect)
        if let name = preset, !name.isEmpty {
            guard let (w, h) = presetSize(name) else { throw EngineError.bad(cmd, "unknown preset `\(name)`") }
            (base[2], base[3]) = (w, h)
        }
        let rect = try rectParam(p, base, cmd)
        let background = try backgroundParam(p, cmd)
        let name = p["name"]?.stringValue
        let moveContents = p["moveContents"]?.boolValue ?? true
        // The offset between two in-range edges can need 33 bits (#931); layers move by Int32 only.
        let (dx64, dy64) = (Int64(rect.x0) - Int64(old.rect.x0), Int64(rect.y0) - Int64(old.rect.y0))
        let dx: Int32, dy: Int32
        if let x = Int32(exactly: dx64), let y = Int32(exactly: dy64) {
            (dx, dy) = (x, y)
        } else if !moveContents {
            (dx, dy) = (0, 0)
        } else {
            throw EngineError.bad(cmd, "moving the artboard with its contents by (\(dx64), \(dy64)) is outside the 32-bit range; move it in smaller steps or pass \"moveContents\": false")
        }
        try s.edit("Edit Artboard") { doc, _ in
            if moveContents && (dx != 0 || dy != 0) {
                guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
                let snapshot = doc
                doc.updateLayer(id) { LayerOps.translateLayer(snapshot, &$0, dx, dy) }
            }
            guard doc.layer(id)?.artboard != nil else { throw EngineError.noLayer(id) }
            doc.updateLayer(id) { l in
                if let name { l.name = name }
                guard var a = l.artboard else { return }
                a.rect = rect
                if let background { a.background = background }
                if let preset {
                    a.preset = preset
                } else if rect.width != old.rect.width || rect.height != old.rect.height {
                    // A hand-edited size no longer matches the preset.
                    a.preset = ""
                }
                l.artboard = a
            }
            fitCanvas(&doc)
        }
        return result(id, rect)
    }

    /// The Artboard tool's "+" buttons: a board the size of board `layer` on one of its sides, a
    /// gap away (further out past any board in the way), empty or (`duplicate`) a copy with its
    /// contents. A board left of or above the canvas origin shifts the whole document right/down
    /// so the canvas can grow to show it. One undo step.
    static func addBeside(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layer.artboard.addBeside"
        guard let d = s.active else { throw EngineError.noDocument }
        let id: LayerId
        if let v = p["layer"]?.uint64Value {
            id = LayerId(v)
        } else {
            guard let a = activeArtboard(s) else { throw EngineError.bad(cmd, "no artboard selected") }
            id = a
        }
        guard let src = d.doc.layer(id)?.artboard else { throw EngineError.bad(cmd, "the layer is not an artboard") }
        let side = p["side"]?.stringValue ?? "right"
        let duplicate = p["duplicate"]?.boolValue ?? false
        let b0 = xywh(src.rect)
        let (x0, y0, w, h) = (b0[0], b0[1], b0[2], b0[3])
        var x: Int64, y: Int64
        switch side {
        case "right": (x, y) = (x0 + w + gap, y0)
        case "left": (x, y) = (x0 - gap - w, y0)
        case "bottom": (x, y) = (x0, y0 + h + gap)
        case "top": (x, y) = (x0, y0 - gap - h)
        default: throw EngineError.bad(cmd, "unknown side `\(side)` (left|right|top|bottom)")
        }
        let boards = d.doc.artboards.map(\.artboard.rect)
        // Each round clears every board in the way, so one round per board settles it.
        for _ in 0...boards.count {
            let blocked = boards.filter { Int64($0.x0) < x + w && Int64($0.x1) > x && Int64($0.y0) < y + h && Int64($0.y1) > y }
            if blocked.isEmpty { break }
            switch side {
            case "right": x = (blocked.map { Int64($0.x1) }.max() ?? x) + gap
            case "left": x = (blocked.map { Int64($0.x0) }.min() ?? x) - gap - w
            case "bottom": y = (blocked.map { Int64($0.y1) }.max() ?? y) + gap
            default: y = (blocked.map { Int64($0.y0) }.min() ?? y) - gap - h
            }
        }
        let rect = try boardRect(cmd, [x, y, w, h])
        // The canvas starts at (0, 0): a board past it moves everything right/down instead.
        let (nx, ox) = Int32(0).subtractingReportingOverflow(min(rect.x0, 0))
        let (ny, oy) = Int32(0).subtractingReportingOverflow(min(rect.y0, 0))
        if ox || oy {
            throw EngineError.bad(cmd, "no room for an artboard \(side) of \"\(d.doc.layer(id)?.name ?? "")\"")
        }
        let (sx, sy) = (nx, ny)
        func grown(_ len: Int, _ by: Int32) -> Int { Int(min(max(Int64(len) + Int64(by), 1), 300_000)) }
        let label = duplicate ? "Duplicate Artboard" : "New Artboard"
        let (nid, placed) = try s.edit(label) { doc, active -> (LayerId, PixelRect) in
            if sx != 0 || sy != 0 {
                try translateDoc(&doc, cmd, sx, sy)
                doc.size = PixelSize(width: grown(doc.size.width, sx), height: grown(doc.size.height, sy))
                CanvasGeometry.refresh(&doc, .shapes)
            }
            let (ax0, o1) = rect.x0.addingReportingOverflow(sx), (ay0, o2) = rect.y0.addingReportingOverflow(sy)
            let (ax1, o3) = rect.x1.addingReportingOverflow(sx), (ay1, o4) = rect.y1.addingReportingOverflow(sy)
            if o1 || o2 || o3 || o4 { throw EngineError.bad(cmd, "the new artboard is outside the 32-bit coordinate range") }
            let r = PixelRect(x0: ax0, y0: ay0, x1: ax1, y1: ay1)
            let nid: LayerId
            if duplicate {
                guard let srcRect = doc.layer(id)?.artboard?.rect else { throw EngineError.noLayer(id) }
                let dx = Int32(clamping: Int64(r.x0) - Int64(srcRect.x0)), dy = Int32(clamping: Int64(r.y0) - Int64(srcRect.y0))
                let copy = try LayerOps.layerCopy(doc, id)
                nid = doc.insertAbove(id, copy)
                // Grow the canvas first, so shapes on the board re-render uncut where they land.
                func fit(_ len: Int, _ edge: Int32) -> Int { Int(min(max(max(Int64(len), Int64(edge)), 1), 300_000)) }
                doc.size = PixelSize(width: fit(doc.size.width, r.x1), height: fit(doc.size.height, r.y1))
                let snapshot = doc
                doc.updateLayer(nid) { LayerOps.translateLayer(snapshot, &$0, dx, dy) }
            } else {
                var g = Layer.group(nextArtboardName(doc), [])
                setArtboard(&g, Artboard(rect: r, background: src.background, preset: src.preset))
                nid = doc.insertAbove(id, g)
            }
            fitCanvas(&doc)
            active = nid
            return (nid, r)
        }
        try LayerMulti.setSelection(s, [nid], active: nid, anchor: nid)
        return result(nid, placed)
    }

    static func clearArtboardGuides(_ s: Session) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        guard let id = activeArtboard(s) else { throw EngineError.other("no artboard selected") }
        guard let r = d.doc.layer(id)?.artboard?.rect else { throw EngineError.noLayer(id) }
        let insideX = { (x: Double) in x > Double(r.x0) && x < Double(r.x1) }
        let insideY = { (y: Double) in y > Double(r.y0) && y < Double(r.y1) }
        let n = d.doc.guides.vertical.filter(insideX).count + d.doc.guides.horizontal.filter(insideY).count
        if n == 0 { return ["cleared": 0] }
        try s.edit("Clear Selected Artboard Guides") { doc, _ in
            doc.guides.vertical.removeAll(where: insideX)
            doc.guides.horizontal.removeAll(where: insideY)
            doc.guides.pruneColors()
        }
        return ["cleared": .int(n)]
    }

    // MARK: Export

    /// One artboard as its own document: the board's size, its group moved to the origin. nil
    /// when `id` is not an artboard; an error when the board is too far from the origin to move.
    static func artboardDocument(_ doc: Document, _ id: LayerId) throws -> Document? {
        guard let l = doc.layer(id), let r = l.artboard?.rect else { return nil }
        // A board starting at Int32.min needs an offset of 2^31 to reach the origin (#931).
        guard r.x0 != .min, r.y0 != .min else {
            throw EngineError.other("artboard `\(l.name)` at (\(r.x0), \(r.y0)) is too far from the origin to export")
        }
        var group = l
        group.visible = true
        LayerOps.translateLayer(doc, &group, -r.x0, -r.y0)
        var one = doc
        one.name = l.name
        one.size = PixelSize(width: r.width, height: r.height)
        one.layers = [group]
        one.channels.removeAll()
        one.selection = nil
        one.quickMask = nil
        one.layerComps.removeAll()
        one.lastAppliedComp = nil
        one.lastDocumentState = nil
        func shift(_ v: [Double], _ o: Int32, _ len: Int) -> [Double] { v.map { $0 - Double(o) }.filter { $0 > 0 && $0 < Double(len) } }
        one.guides.vertical = shift(doc.guides.vertical, r.x0, r.width)
        one.guides.horizontal = shift(doc.guides.horizontal, r.y0, r.height)
        return one
    }

    /// The artboards an export covers: `"artboards": [ids]`, else all, top of the Layers panel first.
    static func chosenArtboards(_ doc: Document, _ p: JSONValue) -> [LayerId] {
        let all = doc.artboards.reversed().map(\.id)
        if case .array(let a)? = p["artboards"] {
            let want = Set(a.compactMap(\.uint64Value))
            return all.filter { want.contains($0.rawValue) }
        }
        return all
    }

    /// `artboardDocument` for each chosen board, all built before any file is written so a board
    /// that can't be exported fails the export without leaving a partial set behind.
    static func chosenDocuments(_ doc: Document, _ p: JSONValue) throws -> [Document] {
        try chosenArtboards(doc, p).compactMap { try artboardDocument(doc, $0) }
    }

    /// A minimal PDF with one page per JPEG image: (width px, height px, dpi, JPEG bytes). Pages
    /// are sized so the image prints at its resolution.
    static func rasterPdf(_ pages: [(Int, Int, Float, Data)]) -> Data {
        var out = Data("%PDF-1.4\n".utf8)
        out.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int] = []
        func obj(_ body: Data) {
            offsets.append(out.count)
            out.append(Data("\(offsets.count) 0 obj\n".utf8))
            out.append(body)
            out.append(Data("\nendobj\n".utf8))
        }
        func f3(_ v: Double) -> String { String(format: "%.3f", v) }
        // Objects: 1 catalog, 2 page tree, then per page: page, contents, image.
        let kids = pages.indices.map { "\(3 + $0 * 3) 0 R" }
        obj(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        obj(Data("<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(pages.count) >>".utf8))
        for (i, page) in pages.enumerated() {
            let (w, h, dpi, jpeg) = page
            let k = 72.0 / Double(max(dpi, 1))
            let (pw, ph) = (Double(w) * k, Double(h) * k)
            let (contents, image) = (4 + i * 3, 5 + i * 3)
            obj(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(f3(pw)) \(f3(ph))] /Resources << /XObject << /Im0 \(image) 0 R >> >> /Contents \(contents) 0 R >>".utf8))
            let stream = "q \(f3(pw)) 0 0 \(f3(ph)) 0 0 cm /Im0 Do Q"
            obj(Data("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream".utf8))
            var img = Data("<< /Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length \(jpeg.count) >>\nstream\n".utf8)
            img.append(jpeg)
            img.append(Data("\nendstream".utf8))
            obj(img)
        }
        let xref = out.count
        out.append(Data("xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n".utf8))
        for o in offsets { out.append(Data((String(format: "%010ld", o) + " 00000 n \n").utf8)) }
        out.append(Data("trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return out
    }

    /// file_cmds `str_param`: a non-empty string.
    static func strParam(_ p: JSONValue, _ key: String, _ cmd: String) throws -> String {
        guard let v = p[key]?.stringValue, !v.isEmpty else { throw EngineError.bad(cmd, "missing \"\(key)\"") }
        return v
    }

    /// File › Export › Artboards to Files: each board saved alone (moved to the origin) through
    /// PCIO's exporters, named `<prefix>_<board name>.<format>` (photocraft `artboards_to_files`).
    static func artboardsToFiles(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.export.artboardsToFiles"
        let dir: String
        do { dir = try strParam(p, "dir", cmd) } catch { dir = try strParam(p, "output", cmd) }
        var format = Substring(p["format"]?.stringValue ?? "png")
        while format.hasPrefix(".") { format = format.dropFirst() }
        let ext = format.lowercased()
        let save = try FileCommands.SaveOpts.from(s, p, cmd)
        guard let d = s.active else { throw EngineError.noDocument }
        let prefix = p["prefix"]?.stringValue ?? FileCommands.stem(d.doc.name)
        let doc = d.doc
        var files: [JSONValue] = []
        for one in try chosenDocuments(doc, p) {
            let name = prefix.isEmpty ? FileCommands.sanitize(one.name) : "\(FileCommands.sanitize(prefix))_\(FileCommands.sanitize(one.name))"
            let path = FileCommands.join(dir, "\(name).\(ext)")
            try FileCommands.saveDoc(s, one, path, save)
            files.append(.string(path))
        }
        if files.isEmpty { throw EngineError.bad(cmd, "no matching artboards") }
        return ["files": .array(files)]
    }

    /// File › Export › Artboards to PDF: one page per board (flattened over white, JPEG-encoded).
    static func artboardsToPdf(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.export.artboardsToPdf"
        let path = try strParam(p, "path", cmd)
        guard let d = s.active else { throw EngineError.noDocument }
        let doc = d.doc
        let quality = p["quality"]?.doubleValue.flatMap { $0.isFinite ? $0 : nil } ?? 10
        var opts = EncodeOptions()
        // photocraft `file_cmds::encode`: Photoshop's 0…12 onto the IJG 1…100 scale.
        opts.jpegQuality = Int((min(max(quality, 0), 12) / 12 * 99 + 1).rounded())
        let rgb8 = PixelFormat(mode: .rgb, sample: .u8, alpha: false)
        var pages: [(Int, Int, Float, Data)] = []
        for one in try chosenDocuments(doc, p) {
            let flat = try s.services.renderer.compositeToSurface(one, rect: one.bounds, format: rgb8, background: SIMD3(1, 1, 1))
            let jpeg: Data
            do { jpeg = try ImageCodecs.encode(RasterBuffer(surface: flat, rect: one.bounds), as: .jpeg, options: opts) } catch {
                throw EngineError.other("page.jpg: \(error)")
            }
            pages.append((one.size.width, one.size.height, doc.resolutionDpi, jpeg))
        }
        if pages.isEmpty { throw EngineError.bad(cmd, "no matching artboards") }
        try s.services.fileSystem.write(path, rasterPdf(pages))
        return ["path": .string(path), "pages": .int(pages.count)]
    }

    // MARK: Registration

    static func register(into r: inout CommandRegistry) {
        let exportArtboards = Pre.all(hasDoc, hasArtboards)
        r.add([
            CommandSpec("layer.new.artboard", "Artboard…", menu: ["Layer", "New"],
                        params: ##"{"rect":[x,y,w,h]? | "x","y","width","height"? (default: canvas size, right of the last board),"preset":"iPhone 14|Web 1920|A4|…"?,"name":str?,"background":"white|black|transparent|custom"="white","color":[r,g,b]|"#rrggbb"? (custom)} → {layer, rect}"##,
                        module: m, enabled: hasDoc) { s, p in try newArtboard(s, p) },
            CommandSpec("layer.new.artboardFromGroup", "Artboard from Group…", menu: ["Layer", "New"],
                        params: #"{"layer":id? (a top-level group; default active),"background":…?} → {layer, rect}"#,
                        module: m, enabled: hasPlainGroup) { s, p in try artboardFromGroup(s, p) },
            CommandSpec("layer.new.artboardFromLayers", "Artboard from Layers…", menu: ["Layer", "New"],
                        params: #"{"name":str?,"background":…?} (the selected layers) → {layer, rect}"#,
                        module: m, enabled: hasFreeLayers) { s, p in try artboardFromLayers(s, p) },
            CommandSpec("layer.artboard.set", "Edit Artboard",
                        params: #"{"layer":id? (default: the active artboard),"x","y","width","height"?|"rect":[x,y,w,h]?,"preset":str?,"background":"white|black|transparent|custom"?,"color":…?,"name":str?,"moveContents":bool=true} → {layer, rect}"#,
                        module: m, enabled: hasActiveArtboard) { s, p in try setProps(s, p) },
            CommandSpec("view.clearSelectedArtboardGuides", "Clear Selected Artboard Guides", menu: ["View"],
                        params: "{} (guides inside the active artboard)",
                        module: m, enabled: hasActiveArtboard) { s, _ in try clearArtboardGuides(s) },
            CommandSpec("layer.artboard.addBeside", "Add Artboard Beside",
                        params: #"{"layer":id? (default: the active artboard),"side":"left|right|top|bottom"="right","duplicate":bool=false (copy the board with its contents instead of an empty one)} → {layer, rect} (the Artboard tool's "+" buttons: same size, a 100 px gap away, past any board in the way)"#,
                        module: m, enabled: hasActiveArtboard) { s, p in try addBeside(s, p) },
            CommandSpec("file.export.artboardsToFiles", "Artboards to Files…", menu: ["File", "Export"],
                        params: #"{"dir":folder,"format":"png|jpg|psd|tiff|…"="png","prefix":str=document name ("" = none),"artboards":[id]? (default all),"quality":0..12?} → {files}"#,
                        module: m, enabled: exportArtboards) { s, p in try artboardsToFiles(s, p) },
            CommandSpec("file.export.artboardsToPdf", "Artboards to PDF…", menu: ["File", "Export"],
                        params: #"{"path":str (.pdf),"artboards":[id]?,"quality":0..12=10} → {path, pages} (one raster page per board)"#,
                        module: m, enabled: exportArtboards) { s, p in try artboardsToPdf(s, p) },
        ])
    }
}
