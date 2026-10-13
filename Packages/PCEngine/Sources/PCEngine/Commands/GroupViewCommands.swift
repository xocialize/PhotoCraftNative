// Port of photocraft-engine (crates/engine/src/group_view_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Layers panel disclosure state: expanding and collapsing layer groups (#126). A group's
// open/closed state is document data (`LayerGroup.expanded`, the PSD section divider's open/closed
// folder type, saved in `.pcraft` too) but, as in Photoshop, toggling it is a view change: no
// history step, and a clean document stays clean.

import PCDocument

enum GroupViewCommands: CommandModule {
    static let name = "group_view_cmds"
    static let id = "layer.setExpanded"

    static func bad(_ msg: String) -> EngineError { .bad(id, msg) }

    static let hasGroup: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.walk().contains(where: { $0.layer.isGroup }) ? nil : "the document has no layer groups"
    }

    static func optBool(_ p: JSONValue, _ key: String) throws -> Bool? {
        switch p[key] {
        case nil, .some(.null): return nil
        case let v?:
            guard let b = v.boolValue else { throw bad("`\(key)` must be true or false") }
            return b
        }
    }

    /// `{"layer":id?,"expanded":bool?,"all":bool?}`: open or close a group (no `expanded`:
    /// toggle). With `all`, every group in the document takes the new state (Photoshop's ⌥-click
    /// on a disclosure triangle); without a layer, `all` toggles from "any group open".
    static func setExpanded(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let want = try optBool(p, "expanded")
        let all = try optBool(p, "all") ?? false
        guard let st = s.active else { throw EngineError.noDocument }
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
        let current: Bool
        if let id = layer {
            guard let l = st.doc.layer(id) else { throw EngineError.noLayer(id) }
            guard let g = l.group else { throw bad("layer \(id.rawValue) is not a group") }
            current = g.expanded
        } else {
            current = st.doc.walk().contains { $0.layer.group?.expanded == true }
        }
        let expanded = want ?? !current
        // Not an edit: the document changes in place, outside history (photocraft mutates the
        // active document's copy-on-write `Arc` directly).
        let changed = try s.updateActive { st -> Int in
            if all {
                var n = 0
                st.doc.forEachLayerMut { l in
                    if l.withGroup({ $0.expanded = expanded }) != nil { n += 1 }
                }
                return n
            }
            guard let id = layer else { throw bad("no layer") }
            guard st.doc.updateLayer(id, { $0.withGroup { $0.expanded = expanded } }) ?? nil != nil else {
                throw EngineError.noLayer(id)
            }
            return 1
        }
        return ["expanded": .bool(expanded), "groups": .int(changed)]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec(id, "Expand/Collapse Group",
                          params: ##"{"layer":id?,"expanded":bool?,"all":bool?} (no expanded: toggle; all: every group; not an undo step)"##,
                          module: name, journal: false, enabled: hasGroup, run: setExpanded))
    }
}
