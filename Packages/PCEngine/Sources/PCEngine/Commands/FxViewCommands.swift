// Port of photocraft-engine (crates/engine/src/fx_view_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Layers panel: showing or hiding a layer's effects list under its row (the triangle beside the
// fx badge, #144). View state (photocraft `DocState::fx_collapsed`, here `FxCollapsedKey` in the
// document's view store): no history step, and a clean document stays clean.

import PCDocument

/// The layers whose effects list is collapsed in the Layers panel (photocraft
/// `DocState::fx_collapsed`): `st.view[FxCollapsedKey.self]`. Missing ids are open.
public enum FxCollapsedKey: StateKey {
    public static let defaultValue: [LayerId] = []
}

enum FxViewCommands: CommandModule {
    static let name = "fx_view_cmds"
    static let id = "layer.setEffectsExpanded"

    static func bad(_ msg: String) -> EngineError { .bad(id, msg) }

    static let hasEffects: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.walk().contains(where: { !$0.layer.effects.items.isEmpty }) ? nil : "no layer has effects"
    }

    static func optBool(_ p: JSONValue, _ key: String) throws -> Bool? {
        switch p[key] {
        case nil, .some(.null): return nil
        case let v?:
            guard let b = v.boolValue else { throw bad("`\(key)` must be true or false") }
            return b
        }
    }

    /// `{"layer":id?,"expanded":bool?,"all":bool?}`: show or hide a layer's effects list (no
    /// `expanded`: toggle). With `all`, every layer with effects takes the new state (⌥-click).
    static func setExpanded(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let want = try optBool(p, "expanded")
        let all = try optBool(p, "all") ?? false
        return try s.updateActive { st -> JSONValue in
            let layer: LayerId?
            switch p["layer"] {
            case nil, .some(.null):
                if all {
                    layer = nil
                } else {
                    guard let a = st.activeLayer else { throw bad("no layer given and no active layer") }
                    layer = a
                }
            case let v?:
                guard let n = v.uint64Value else { throw bad("`layer` must be a layer id") }
                layer = LayerId(n)
            }
            let collapsed = st.view[FxCollapsedKey.self]
            let withFx = st.doc.walk().filter { !$0.layer.effects.items.isEmpty }.map(\.layer.id)
            let current: Bool
            if let id = layer {
                guard let l = st.doc.layer(id) else { throw EngineError.noLayer(id) }
                if l.effects.items.isEmpty { throw bad("layer \(id.rawValue) has no effects") }
                current = !collapsed.contains(id)
            } else {
                current = withFx.contains { !collapsed.contains($0) }
            }
            let expanded = want ?? !current
            let targets = all ? withFx : (layer.map { [$0] } ?? [])
            // Forget ids no longer in the document so the list can't grow without bound.
            let doc = st.doc
            var next = collapsed.filter { doc.layer($0) != nil && !targets.contains($0) }
            if !expanded { next += targets }
            st.view[FxCollapsedKey.self] = next
            return ["expanded": .bool(expanded), "layers": .int(targets.count)]
        }
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec(id, "Expand/Collapse Effects",
                          params: ##"{"layer":id?,"expanded":bool?,"all":bool?} (no expanded: toggle; all: every layer with effects; view state, not an undo step)"##,
                          module: name, journal: false, enabled: hasEffects, run: setExpanded))
    }
}
