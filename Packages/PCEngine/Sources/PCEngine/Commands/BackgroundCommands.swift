// Port of photocraft-engine (crates/engine/src/background_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Layer › New › Background from Layer. Photoshop's Background is the locked, opaque layer at the
// bottom of the stack; this command turns the selected layer into it: transparent pixels take the
// background colour and the layer drops to the bottom. The rule that keeps the Background at the
// bottom (`background_id` / `keep_background_at_bottom`) lives in `LayerOps` (the arrange and
// move commands share it); Layer from Background turns it back into a normal layer.

import PCDocument
import PCFoundation

enum BackgroundCommands: CommandModule {
    static let name = "background_cmds"
    static let cmd = "layer.new.backgroundFromLayer"

    /// Can `l` become the Background? Groups and adjustment layers have no pixels of their own.
    static func convertible(_ l: Layer) -> String? {
        switch l.content {
        case .group, .adjustment: "\(l.content.article) \(l.content.kindName) layer can't become the Background"
        default: nil
        }
    }

    static let canConvert: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        if LayerOps.backgroundId(d.doc) != nil { return "the document already has a Background layer" }
        guard let id = d.activeLayer, let l = d.doc.layer(id) else { return "no active layer" }
        return convertible(l)
    }

    static func backgroundFromLayer(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id: LayerId
        switch p["layer"] {
        case nil, .some(.null):
            id = try s.layerParam(p)
        case let v?:
            guard let n = v.uint64Value else { throw EngineError.bad(cmd, "`layer` must be a layer id") }
            id = LayerId(n)
        }
        let bg = s.tools.background
        let renderer = s.services.renderer
        try s.edit("Background From Layer") { doc, active in
            if LayerOps.backgroundId(doc) != nil { throw EngineError.other("the document already has a Background layer") }
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            if let why = convertible(l) { throw EngineError.other(why) }
            // Render the layer alone, as it looks (mask, opacity and effects applied), over the
            // background colour: the Background is opaque and plain.
            var only = l
            only.visible = true
            only.clipped = false
            let fmt = doc.pixelFormat
            var solo = doc
            solo.layers = [only]
            let pixels = try renderer.compositeToSurface(solo, rect: nil, format: fmt, background: SIMD3(bg.x, bg.y, bg.z))
            var out = Layer.raster("Background", surface: pixels)
            out.id = id
            out.visible = l.visible
            out.locks.transparency = true
            out.locks.position = true
            guard doc.remove(id) != nil else { throw EngineError.noLayer(id) }
            doc.layers.insert(out, at: 0)
            active = id
        }
        // The Background is the one targeted layer now.
        try s.selectLayer(id)
        return ["layer": .id(id)]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec(cmd, "Background From Layer", menu: ["Layer", "New"],
                          params: ##"{"layer":id?} (the active layer by default; transparent pixels take the background colour and the layer drops to the bottom as the locked Background)"##,
                          module: name, enabled: canConvert, run: backgroundFromLayer))
    }
}
