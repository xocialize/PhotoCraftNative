// Port of photocraft-engine (crates/engine/src/layer_mask_props_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Non-destructive pixel-mask properties (the Properties panel's Density and Feather sliders):
// density and feather leave the mask pixels intact.

import PCDocument

enum LayerMaskPropsCommands: CommandModule {
    static let name = "layer_mask_props_cmds"
    static let edit = "layer.layerMask.edit"

    static func bad(_ msg: String) -> EngineError { .bad(edit, msg) }

    /// A finite number within `0...max`, nil when absent.
    static func number(_ p: JSONValue, _ key: String, _ max: Double) throws -> Float? {
        guard let v = p[key] else { return nil }
        guard let n = v.doubleValue, n.isFinite, n >= 0, n <= max else {
            throw bad("`\(key)` must be a finite number within 0..\(Int(max))")
        }
        return Float(n)
    }

    static func run(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard p.objectValue != nil else { throw bad("params must be an object") }
        let density = try number(p, "density", 100).map { $0 / 100 }
        let feather = try number(p, "feather", 1000)
        if density == nil && feather == nil { throw bad("density or feather is required") }
        guard let st = s.active else { throw EngineError.noDocument }
        if let document = p["document"], document.uint64Value != st.doc.id.rawValue {
            throw bad("the target document is no longer active")
        }
        let id: LayerId
        if let v = p["layer"] {
            guard let n = v.uint64Value else { throw bad("`layer` must be an unsigned layer id") }
            id = LayerId(n)
        } else {
            guard let a = st.activeLayer else { throw bad("no layer given and no active layer") }
            id = a
        }
        guard let layer = st.doc.layer(id) else { throw EngineError.noLayer(id) }
        guard let mask = layer.mask else { throw bad("the target layer has no pixel mask") }
        let d = density ?? mask.density, f = feather ?? mask.feather
        if d != mask.density || f != mask.feather {
            try s.edit("Edit Layer Mask") { doc, _ in
                var missing = true
                guard doc.updateLayer(id, { (l: inout Layer) -> Void in
                    guard var m = l.mask else { return }
                    m.density = d
                    m.feather = f
                    l.mask = m
                    missing = false
                }) != nil else { throw EngineError.noLayer(id) }
                if missing { throw bad("the target layer has no pixel mask") }
            }
        }
        return ["layer": .id(id), "density": .float(d * 100), "feather": .float(f)]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec(edit, "Edit Layer Mask",
                          params: ##"{"layer":id? (default active),"document":id? (reject a stale dialog),"density":0..100?,"feather":0..1000? (pixels)} → {layer,density,feather}; at least one property required; mask pixels are preserved"##,
                          module: name, enabled: Pre.hasDoc, run: run))
    }
}
