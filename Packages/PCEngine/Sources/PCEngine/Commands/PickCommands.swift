// Port of photocraft-engine (crates/engine/src/pick_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Move tool Auto-Select: pick the topmost visible, not fully locked layer with pixels at a canvas
// point (Photoshop's options bar "Auto-Select: Layer | Group", ⌘-click with the Move tool, and the
// canvas right-click layer list), and the Move tool's marquee that selects the layers it touches.
// Like Photoshop, Auto-Select hits a type layer anywhere inside its text's bounds, so a click
// between letters picks the type rather than the layer under it (#2370).

import PCDocument
import PCFoundation
import PCRender

public enum PickCommands: CommandModule {
    public static let name = "pick_cmds"
    static let m = "pick_cmds"

    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document" : nil }

    static func visible(_ doc: Document, _ path: LayerPath) -> Bool {
        guard !path.isEmpty else { return false }
        return (1...path.count).allSatisfy { doc.layer(at: Array(path.prefix($0)))?.visible ?? false }
    }

    static func board(_ doc: Document, _ path: LayerPath) -> Artboard? {
        guard let i = path.first, i >= 0, i < doc.layers.count else { return nil }
        return doc.layers[i].artboard
    }

    /// Layers with visible pixels at (x, y), topmost first (hidden layers and hidden groups
    /// skipped).
    public static func layersAt(_ doc: Document, _ x: Int32, _ y: Int32) -> [LayerId] { layersHit(doc, x, y, typeBounds: false) }

    /// `layersAt`, but with `typeBounds` a type layer is hit anywhere inside the bounds of its
    /// rendered text (the gaps between glyphs included), as Photoshop's Auto-Select does.
    static func layersHit(_ doc: Document, _ x: Int32, _ y: Int32, typeBounds: Bool) -> [LayerId] {
        // A 1×1 read at Int32.max would be an empty rect (huge `x` params saturate there).
        if x == .max || y == .max { return [] }
        let px = PixelRect(x0: x, y0: y, x1: x + 1, y1: y + 1)
        var out: [LayerId] = []
        for e in doc.walk().reversed() {
            let l = e.layer
            // The layer and every enclosing group must be visible.
            if !visible(doc, e.path) { continue }
            // An artboard clips its layers to the board (#1531); the board itself is hit anywhere
            // on it, below its layers (the walk lists them first).
            if let b = board(doc, e.path), !b.rect.contains(x: x, y: y) { continue }
            if l.artboard != nil {
                out.append(l.id)
                continue
            }
            switch l.content {
            case .group, .adjustment: continue
            default: break
            }
            let alpha: Float
            switch l.content {
            // Fill layers cover the canvas (their mask limits them).
            case .fill: alpha = 1
            // The text's pixel bounds (in document space, so they follow the layer's transform).
            case .text(let t) where typeBounds && (t.cache?.contentBounds.contains(x: x, y: y) ?? false): alpha = 1
            default: alpha = l.surface?.readRGBA(px).first?.w ?? 0
            }
            var mask: Float = 1
            if let mk = l.mask, mk.enabled { mask = mk.surface.pixel(x: x, y: y).first ?? 0 }
            if alpha * mask > 0 { out.append(l.id) }
        }
        return out
    }

    /// The outermost group containing `id` (the layer itself when it isn't in a group). An
    /// artboard is not a group here: Group mode stops at the outermost group on the board.
    static func topGroup(_ doc: Document, _ id: LayerId) -> LayerId {
        guard let path = doc.path(of: id) else { return id }
        let depth = board(doc, path) != nil ? 2 : 1
        guard path.count >= depth, let l = doc.layer(at: Array(path.prefix(depth))) else { return id }
        return l.id
    }

    /// The layer an Auto-Select click at (x, y) picks (with `group`, its outermost group): the
    /// topmost hit, a type layer by its text bounds. Like Photoshop, it clicks through a fully
    /// locked layer to the layer under it (#1641); the right-click list still shows it.
    public static func autoSelectTarget(_ doc: Document, _ x: Int32, _ y: Int32, group: Bool) -> LayerId? {
        guard let hit = layersHit(doc, x, y, typeBounds: true).first(where: { !doc.effectiveLocks($0).all }) else { return nil }
        return group ? topGroup(doc, hit) : hit
    }

    static func pick(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let xf = p["x"]?.doubleValue else { throw EngineError.bad("layer.pickAt", "missing `x`") }
        guard let yf = p["y"]?.doubleValue else { throw EngineError.bad("layer.pickAt", "missing `y`") }
        let (x, y) = (BrushCommands.i32(xf.rounded(.down)), BrushCommands.i32(yf.rounded(.down)))
        guard let st = s.active else { throw EngineError.noDocument }
        let doc = st.doc
        // The right-click list names the layers with pixels under the pointer.
        if p["list"]?.boolValue ?? false {
            let names: [JSONValue] = layersHit(doc, x, y, typeBounds: false).compactMap { id in
                doc.layer(id).map { ["layer": .id($0.id), "name": .string($0.name)] }
            }
            return ["layers": .array(names)]
        }
        let group = p["target"]?.stringValue == "group"
        guard let target = autoSelectTarget(doc, x, y, group: group) else { return ["layer": .null] }
        if p["select"]?.boolValue ?? true {
            let mode = p["mode"]?.stringValue ?? "replace"
            // Like Photoshop, a plain click on one of several selected layers keeps them all
            // selected, so the drag that follows moves the whole selection.
            let keeps = mode == "replace" && st.isLayerSelected(target) && st.selectedLayers.count > 1
            if !keeps { try s.execute("layer.select", ["layer": .id(target), "mode": .string(mode)]) }
        }
        return ["layer": .id(target)]
    }

    /// Layers whose content touches document rect `r`, top to bottom: visible, not fully locked,
    /// not the locked Background (as Select › All Layers). A layer on an artboard counts only where
    /// the board shows it. With `group`, each counts as its outermost group (deduplicated).
    public static func layersInRect(_ doc: Document, _ r: PixelRect, group: Bool) -> [LayerId] {
        var out: [LayerId] = []
        if r.isEmpty { return out }
        let canvas = doc.bounds
        for e in doc.walk().reversed() {
            let l = e.layer
            switch l.content {
            case .group, .adjustment: continue
            default: break
            }
            if doc.isBackground(l.id) || doc.effectiveLocks(l.id).all || !visible(doc, e.path) { continue }
            var b = LayerGeometry.layerBounds(l, canvas: canvas)
            if let board = board(doc, e.path) { b = b.intersect(board.rect) }
            if b.isEmpty || b.intersect(r).isEmpty { continue }
            let id = group ? topGroup(doc, l.id) : l.id
            if !out.contains(id) { out.append(id) }
        }
        return out
    }

    /// `layer.selectInRect`: the Move tool's marquee with Auto-Select, dragged from an empty spot.
    static func selectInRect(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        func num(_ k: String) throws -> Double {
            guard let v = p[k]?.doubleValue, v.isFinite else { throw EngineError.bad("layer.selectInRect", "missing or invalid `\(k)`") }
            return v
        }
        let (x, y, w, h) = (try num("x"), try num("y"), try num("width"), try num("height"))
        func px(_ v: Double) -> Int32 { Int32(min(max(v, Double(Int32.min / 2)), Double(Int32.max / 2))) }
        // A rect dragged up or left has a negative size.
        let r = PixelRect(x0: px(min(x, x + w).rounded(.down)), y0: px(min(y, y + h).rounded(.down)),
                          x1: px(max(x, x + w).rounded(.up)), y1: px(max(y, y + h).rounded(.up)))
        guard let st = s.active else { throw EngineError.noDocument }
        let group = p["target"]?.stringValue == "group"
        let hits = layersInRect(st.doc, r, group: group)
        let add: Bool
        switch p["mode"]?.stringValue ?? "replace" {
        case "replace": add = false
        case "add": add = true
        case let other: throw EngineError.bad("layer.selectInRect", "unknown mode `\(other)`")
        }
        // Nothing touched leaves the layer selection as it is.
        if !hits.isEmpty {
            var ids = add ? st.selectedLayers : []
            ids += hits.filter { !ids.contains($0) }
            try LayerMulti.setSelection(s, ids, active: hits.first, anchor: hits.first)
        }
        return ["layers": .ids(hits)]
    }

    public static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("layer.selectInRect", "Select Layers in Marquee",
                        params: #"{"x":px,"y":px,"width":px,"height":px,"target":"layer|group"="layer","mode":"replace|add"="replace"} → {layers} (the layers whose content touches the rect, topmost first; none leaves the selection as it is)"#,
                        module: m, enabled: hasDoc, run: selectInRect),
            CommandSpec("layer.pickAt", "Auto-Select Layer",
                        params: #"{"x":px,"y":px,"target":"layer|group"="layer","select":bool=true,"mode":"replace|toggle|add"="replace","list":bool=false (return every layer with pixels there, topmost first)} → {layer} | {layers}"#,
                        module: m, journal: false, enabled: hasDoc, run: pick),
        ])
    }
}
