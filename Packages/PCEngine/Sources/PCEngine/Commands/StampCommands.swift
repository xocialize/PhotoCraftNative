// Port of photocraft-engine (crates/engine/src/stamp_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Stamping (#217): merge layers into a layer while keeping the originals.
// - Stamp Visible (⌘⌥⇧E, or ⌥ + Layer › Merge Visible): every visible layer composited into a
//   new layer above the active one.
// - Stamp Down (⌘⌥E, or ⌥ + Layer › Merge Down): a copy of the active layer merged into the pixel
//   layer below it; with several layers selected, a copy of them merged into a new layer above
//   the top one.
// Photoshop has no menu items for these (they are the ⌥ variants of the merge commands), so they
// are commands with default shortcuts. The composite is rendered in bands by the engine renderer
// (`compositeToSurface`), and tiles left fully transparent are pruned.

import PCDocument
import PCFoundation

enum StampCommands: CommandModule {
    static let name = "stamp_cmds"

    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document" : nil }
    static let hasLayer: CommandEnabled = { s, _ in
        guard let st = s.active else { return "no document" }
        guard let id = st.activeLayer, st.doc.layer(id) != nil else { return "no active layer" }
        return nil
    }

    /// The document's pixel format with an alpha channel (a stamp has transparency).
    static func withAlpha(_ doc: Document) -> PixelFormat {
        let f = doc.pixelFormat
        return PixelFormat(mode: f.mode, sample: f.sample, alpha: true)
    }

    /// A new pixel layer holding the composite of `doc`'s visible layers, rendered in bands.
    static func stampLayer(_ doc: Document, _ name: String, _ renderer: EngineRenderer) throws -> Layer {
        let fmt = withAlpha(doc)
        return Layer.raster(name, surface: try renderer.compositeToSurface(doc, rect: nil, format: fmt, background: nil))
    }

    /// Make `id` the only selected layer and the active one.
    static func selectOnly(_ s: Session, _ id: LayerId) {
        try? s.updateActive { st in
            st.selectedLayerIds = [id]
            st.activeLayer = id
            st.layerAnchor = id
            st.fixSelection()
        }
    }

    /// The ⌥ variant of a Layer menu merge command (⌥ + Merge Down / Merge Visible / Merge Layers).
    static func altVariant(_ id: String) -> String? {
        switch id {
        case "layer.mergeVisible": "layer.stampVisible"
        case "layer.mergeDown", "layer.mergeLayers": "layer.stampDown"
        default: nil
        }
    }

    static func stampVisible(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let renderer = s.services.renderer
        let id = try s.edit("Stamp Visible") { doc, active -> LayerId in
            let snapshot = doc
            let anyVisible = snapshot.walk().contains { e in
                !e.layer.isGroup && (1...max(e.path.count, 1)).allSatisfy { n in snapshot.layer(at: Array(e.path.prefix(n)))?.visible == true }
            }
            if !anyVisible { throw EngineError.other("there are no visible layers to stamp") }
            let layer = try stampLayer(snapshot, snapshot.nextLayerName("Layer"), renderer)
            let id = doc.insertAbove(active, layer)
            active = id
            return id
        }
        selectOnly(s, id)
        return ["layer": .id(id)]
    }

    static func stampDown(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let sel = LayerMulti.selected(s)
        if sel.count >= 2 { return try stampSelected(s, sel) }
        guard let st = s.active else { throw EngineError.noDocument }
        guard let id = st.activeLayer else { throw EngineError.other("no active layer") }
        let renderer = s.services.renderer
        try s.edit("Stamp Down") { doc, _ in
            guard let path = doc.path(of: id), let idx = path.last else { throw EngineError.noLayer(id) }
            guard idx >= 1 else { throw EngineError.other("there is no layer below to stamp into") }
            let below = Array(path.dropLast()) + [idx - 1]
            guard let lower = doc.layer(at: below), let upper = doc.layer(id) else { throw EngineError.noLayer(id) }
            guard case .raster = lower.content else { throw EngineError.other("the layer below is not a pixel layer") }
            let locks = doc.effectiveLocks(lower.id)
            if locks.all || locks.pixels { throw EngineError.other("the layer below is locked") }
            if !upper.visible { throw EngineError.other("the layer is hidden") }
            // The two layers on their own, composited in bands; the lower one keeps its id, name
            // and blend mode, as Merge Down does.
            var tmp = doc
            var base = lower
            base.visible = true
            tmp.layers = [base, upper]
            let f = doc.pixelFormat
            let fmt = lower.locks.transparency ? f : PixelFormat(mode: f.mode, sample: f.sample, alpha: true)
            let surf = try renderer.compositeToSurface(tmp, rect: nil, format: fmt, background: nil)
            var merged = Layer(name: lower.name, content: .raster(surf))
            merged.id = lower.id
            merged.blend = lower.blend
            merged.visible = lower.visible
            merged.locks = lower.locks
            merged.opacity = 1
            guard doc.updateLayer(at: below, { $0 = merged }) != nil else { throw EngineError.noLayer(lower.id) }
        }
        return ["layer": .id(id)]
    }

    /// Several layers selected: a copy of them merged into a new layer above the top one.
    static func stampSelected(_ s: Session, _ sel: [LayerId]) throws -> JSONValue {
        let renderer = s.services.renderer
        let id = try s.edit("Stamp Layers") { doc, active -> LayerId in
            let ids = LayerOps.topLevel(doc, sel)
            guard let top = ids.last else { throw EngineError.other("no layers selected") }
            var solo = doc
            solo.layers = ids.compactMap { doc.layer($0) }.filter(\.visible)
            if solo.layers.isEmpty { throw EngineError.other("the selected layers are all hidden") }
            let name = "\(doc.layer(top)?.name ?? "Layer") (merged)"
            let layer = try stampLayer(solo, name, renderer)
            let id = doc.insertAbove(top, layer)
            active = id
            return id
        }
        selectOnly(s, id)
        return ["layer": .id(id)]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("layer.stampVisible", "Stamp Visible", shortcut: "Cmd+Alt+Shift+E",
                          params: ##"{} → {layer} (every visible layer merged into a new layer above the active one; the originals stay)"##,
                          module: name, enabled: hasDoc, run: stampVisible))
        r.add(CommandSpec("layer.stampDown", "Stamp Down", shortcut: "Cmd+Alt+E",
                          params: ##"{} → {layer} (a copy of the active layer merged into the pixel layer below; several selected: into a new layer above them)"##,
                          module: name, enabled: hasLayer, run: stampDown))
    }
}
