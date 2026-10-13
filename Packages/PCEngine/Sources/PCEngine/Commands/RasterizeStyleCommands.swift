// Port of photocraft-engine (crates/engine/src/rasterize_style_cmds.rs, with the content rasterization of extra_cmds.rs `kind_of`/`rasterize_content`/`content_pixels`/`step_key` it runs first), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Layer › Rasterize › Layer Style (#2245): bake a layer's effects into its pixels. The layer is
// rendered alone by the compositor (the same path as the canvas) at 100 % opacity in Normal mode,
// so its effects, fill opacity and masks end up in the pixels; its own opacity, blend mode,
// knockout and Blend If stay layer properties and apply to the baked pixels. For a Normal layer
// whose effects blend Normal the document looks the same before and after. An effect in another
// mode is evaluated against the transparent backdrop of the isolated layer, so it can look
// different afterwards; no single layer of pixels can blend one part Multiply and another Screen.

import PCDocument
import PCFoundation
import PCRender

enum RasterizeStyleCommands: CommandModule {
    static let name = "rasterize_style_cmds"
    static let id = "layer.rasterize.layerStyle"

    /// Whether Rasterize › Layer Style applies to `l`: visible effects on a layer whose content
    /// can become pixels (not a group or an adjustment layer).
    static func canBake(_ l: Layer) -> Bool {
        switch l.content {
        case .group, .adjustment: false
        default: LayerGeometry.hasEffects(l)
        }
    }

    /// Some selected layer (or the active one) has effects to bake.
    static let enabled: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        let ids = d.selectedLayers + (d.activeLayer.map { [$0] } ?? [])
        return ids.compactMap { d.doc.layer($0) }.contains(where: canBake) ? nil : "no selected layer has layer effects to rasterize"
    }

    /// photocraft `extra_cmds::step_key`: a coalescing key unique to this document revision.
    static func stepKey(_ s: Session, _ what: String) -> String { "\(what)#\(s.active?.revision ?? 0)" }

    /// photocraft `extra_cmds::kind_of`.
    static func kindOf(_ s: Session, _ id: LayerId) -> String? {
        switch s.active?.doc.layer(id)?.content {
        case .text?: "type"
        case .shape?: "shape"
        case .fill?: "fill"
        case .smart?: "smart"
        default: nil
        }
    }

    /// photocraft `extra_cmds::content_pixels`: the layer's content alone (no masks, effects,
    /// opacity or blending) over the canvas, in the document's format.
    static func contentPixels(_ doc: Document, _ l: Layer, _ renderer: EngineRenderer) throws -> Surface {
        var tmp = l
        tmp.mask = nil
        tmp.vectorMask = nil
        tmp.effects.items.removeAll()
        tmp.opacity = 1
        tmp.fillOpacity = 1
        tmp.blend = .normal
        tmp.clipped = false
        tmp.visible = true
        let canvas = doc.bounds
        let fmt = doc.pixelFormat
        var solo = doc
        solo.layers = [tmp]
        var s = Surface(format: fmt)
        if canvas.isEmpty { return s }
        let buf = try renderer.render(solo, region: canvas)
        s.writeRegion(canvas, PixelCodec.fromRGBA(fmt, rgba: buf.px))
        s.prune()
        return s
    }

    static let typeBlocks: [PSDKey] = ["TySh"]
    static let shapeBlocks: [PSDKey] = ["vmsk", "vsms", "vogk", "vstk", "vscg", "SoCo", "GdFl", "PtFl"]
    static let smartBlocks: [PSDKey] = ["SoLd", "SoLE", "PlLd"]
    static let fillBlocks: [PSDKey] = ["SoCo", "GdFl", "PtFl", "SoLd", "PlLd", "SoLE"]

    /// photocraft `extra_cmds::rasterize_content` for one kind (Rasterize › Type / Shape / Smart
    /// Object / Fill Content), sharing the history step `key`: type and shape layers become their
    /// rendered cache, smart objects their cached placement, fill layers their rendered fill.
    static func rasterizeContent(_ s: Session, _ id: LayerId, kind: String, key: String) throws {
        let renderer = s.services.renderer
        let (label, blocks): (String, [PSDKey]) = switch kind {
        case "type": ("Rasterize Type", typeBlocks)
        case "shape": ("Rasterize Shape", shapeBlocks)
        case "smart": ("Rasterize Smart Object", smartBlocks)
        default: ("Rasterize Fill Content", fillBlocks)
        }
        let saved = s.coalesceRequest
        s.coalesceRequest = key
        defer { s.coalesceRequest = saved }
        try s.edit(label) { doc, _ in
            guard let snap = doc.layer(id) else { throw EngineError.noLayer(id) }
            let fmt = doc.pixelFormat
            var surface: Surface
            switch (kind, snap.content) {
            case ("type", .text(let t)):
                surface = t.cache ?? renderer.rasterizer.rasterize(snap, in: doc) ?? Surface(format: fmt)
            case ("type", _):
                throw EngineError.other("layer \(id.rawValue) is not a type layer")
            case ("shape", .shape(let sh)):
                surface = sh.cache ?? renderer.rasterizer.rasterize(snap, in: doc) ?? Surface(format: fmt)
            case ("shape", _):
                throw EngineError.other("layer \(id.rawValue) is not a shape layer")
            case ("smart", .smart(let sm)):
                surface = try sm.cache ?? renderer.rasterizer.rasterize(snap, in: doc) ?? contentPixels(doc, snap, renderer)
            case ("smart", _):
                throw EngineError.other("layer \(id.rawValue) is not a smart object")
            default:
                surface = try contentPixels(doc, snap, renderer)
            }
            if surface.format != fmt { surface = surface.convertedAny(to: fmt) }
            let px = surface
            guard doc.updateLayer(id, { (l: inout Layer) -> Void in
                l.content = .raster(px)
                if kind == "fill" { l.fillCache = nil }
                l.psdBlocks.removeAll { blocks.contains($0.key) }
            }) != nil else { throw EngineError.noLayer(id) }
        }
    }

    /// Bake one layer (type, shape, fill and Smart Object content is rasterized first, in the same
    /// history step). Returns false when the layer has nothing to bake.
    static func bakeOne(_ s: Session, _ id: LayerId, key: String) throws -> Bool {
        guard let d = s.active else { throw EngineError.noDocument }
        guard let l = d.doc.layer(id), canBake(l) else { return false }
        if let kind = kindOf(s, id) { try rasterizeContent(s, id, kind: kind, key: key) }
        let renderer = s.services.renderer
        let saved = s.coalesceRequest
        s.coalesceRequest = key
        defer { s.coalesceRequest = saved }
        try s.edit("Rasterize Layer Style") { doc, _ in
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            guard case .raster = l.content else { throw EngineError.other("the layer could not be rasterized") }
            let canvas = doc.bounds
            let fmt = doc.pixelFormat
            // The pixels (also those past the canvas) and everything the effects reach from them.
            let own = LayerGeometry.layerBounds(l, canvas: canvas)
            let area = own.isEmpty ? own : own.outset(by: max(LayerGeometry.margin(l), 0))
            var alone = l
            alone.visible = true
            alone.opacity = 1
            alone.blend = .normal
            alone.clipped = false
            // These depend on the layers beneath and stay on the layer, applied to the baked pixels.
            alone.advanced.knockout = .none
            alone.blendIf = BlendIf()
            alone.excludedChannels = 0
            var px = Surface(format: fmt)
            if !area.isEmpty {
                // Render the layer on its own with the document's settings (mode, depth, global
                // light, patterns).
                var solo = doc
                solo.layers = [alone]
                let buf = try renderer.render(solo, region: area)
                px.writeRegion(area, PixelCodec.fromRGBA(fmt, rgba: buf.px))
            }
            px.prune()
            let baked = px
            guard doc.updateLayer(id, { (l: inout Layer) -> Void in
                l.content = .raster(baked)
                l.fillCache = nil
                // Fill opacity, the masks and the effects are in the pixels now.
                l.fillOpacity = 1
                l.mask = nil
                l.vectorMask = nil
                l.effects.items.removeAll()
                l.effects.psdRaw = nil
                l.effects.reference = nil
                l.effects.enabled = true
                l.advanced.blendInterior = false
                l.advanced.layerMaskHidesEffects = false
                l.advanced.vectorMaskHidesEffects = false
            }) != nil else { throw EngineError.noLayer(id) }
        }
        return true
    }

    /// `{"layer":id?}`: with a layer, just that one; otherwise every selected layer with effects,
    /// in one history step.
    static func rasterizeLayerStyle(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let ids = try LayerMulti.targets(s, p)
        let many = ids.count > 1
        let key = stepKey(s, "rasterizeLayerStyle")
        var done: [LayerId] = []
        for id in ids {
            if try bakeOne(s, id, key: key) { done.append(id) }
        }
        guard let first = done.first else {
            throw EngineError.other(many ? "none of the selected layers has layer effects" : "the layer has no layer effects")
        }
        let active = s.active?.activeLayer.flatMap { done.contains($0) ? $0 : nil }
        return ["layer": .id(active ?? first), "layers": .ids(done)]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec(id, "Layer Style", menu: ["Layer", "Rasterize"],
                          params: ##"{"layer":id?} (no layer: every selected layer with effects; bakes the effects, fill opacity and masks into the pixels)"##,
                          module: name, enabled: enabled, run: rasterizeLayerStyle))
    }
}
