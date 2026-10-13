// Port of photocraft-engine (crates/engine/src/fx_visibility_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Layers panel: the eyes on a layer's effects rows (#1622). The eye on the "Effects" row shows or
// hides every effect of that layer; the eye on one effect's row shows or hides that effect. The
// effects keep their settings either way, and each toggle is one history step.

import PCDocument

enum FxVisibilityCommands: CommandModule {
    static let name = "fx_visibility_cmds"
    static let id = "layer.setEffectsVisible"

    static func bad(_ msg: String) -> EngineError { .bad(id, msg) }

    static let hasEffects: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.walk().contains(where: { !$0.layer.effects.items.isEmpty }) ? nil : "no layer has effects"
    }

    /// `{"layer":id?,"index":n?,"visible":bool?}`: show or hide a layer's effects (no `visible`:
    /// toggle). Without `index` it is the whole list (the "Effects" row); with it, the effect at
    /// that position in the layer's list.
    static func setVisible(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let want: Bool?
        switch p["visible"] {
        case nil, .some(.null): want = nil
        case let v?:
            guard let b = v.boolValue else { throw bad("`visible` must be true or false") }
            want = b
        }
        let index: Int?
        switch p["index"] {
        case nil, .some(.null): index = nil
        case let v?:
            guard let i = v.uint64Value.flatMap({ Int(exactly: $0) }) else { throw bad("`index` must be an effect position (0, 1, …)") }
            index = i
        }
        guard let st = s.active else { throw EngineError.noDocument }
        let id: LayerId
        switch p["layer"] {
        case nil, .some(.null):
            guard let a = st.activeLayer else { throw bad("no layer given and no active layer") }
            id = a
        case let v?:
            guard let n = v.uint64Value else { throw bad("`layer` must be a layer id") }
            id = LayerId(n)
        }
        guard let l = st.doc.layer(id) else { throw EngineError.noLayer(id) }
        if l.effects.items.isEmpty { throw bad("layer \(id.rawValue) has no effects") }
        let current: Bool
        let label: String
        if let i = index {
            guard i < l.effects.items.count else { throw bad("layer \(id.rawValue) has no effect at index \(i)") }
            current = l.effects.items[i].isEnabled
            label = l.effects.items[i].label
        } else {
            current = l.effects.enabled
            label = "Layer Effects"
        }
        let visible = want ?? !current
        if visible != current {
            try s.edit("\(visible ? "Show" : "Hide") \(label)") { doc, _ in
                var failure: EngineError?
                guard doc.updateLayer(id, { (l: inout Layer) -> Void in
                    if let i = index {
                        guard i < l.effects.items.count else {
                            failure = bad("layer \(id.rawValue) has no effect at index \(i)")
                            return
                        }
                        l.effects.items[i].setEnabled(visible)
                    } else {
                        l.effects.enabled = visible
                    }
                }) != nil else { throw EngineError.noLayer(id) }
                if let failure { throw failure }
            }
        }
        return ["layer": .id(id), "index": index.map { .int($0) } ?? .null, "visible": .bool(visible)]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec(id, "Show/Hide Effects",
                          params: ##"{"layer":id?,"index":n?,"visible":bool?} (no index: all of the layer's effects, the "Effects" row; index: the effect at that position in the layer's list; no visible: toggle)"##,
                          module: name, enabled: hasEffects, run: setVisible))
    }
}
