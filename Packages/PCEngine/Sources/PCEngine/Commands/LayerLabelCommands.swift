// Port of photocraft-engine (crates/engine/src/layer_label_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Undoable layer colour labels. A group applies the label to its existing descendants, without
// changing pixels, visibility, locks or the layer selection.

import PCDocument

enum LayerLabelCommands: CommandModule {
    static let name = "layer_label_cmds"
    static let id = "layer.setLabelColor"

    static func bad(_ message: String) -> EngineError { .bad(id, message) }

    static let enabled: CommandEnabled = { s, _ in
        guard let st = s.active else { return "no document open" }
        return st.selectedLayers.isEmpty ? "no layer selected" : nil
    }

    static func setLabel(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard p.objectValue != nil else { throw bad("expected an object") }
        guard let color = p["color"]?.stringValue.flatMap({ LabelColor(id: $0) }) else {
            throw bad("`color` must be a layer colour id (none, red, orange, yellow, green, seafoam, blue, indigo, magenta, fuchsia, violet, gray)")
        }
        guard let st = s.active else { throw EngineError.noDocument }
        let roots: [LayerId]
        if let v = p["layer"] {
            guard let n = v.uint64Value else { throw bad("`layer` must be an unsigned integer") }
            roots = [LayerId(n)]
        } else {
            roots = st.selectedLayers
        }
        if roots.isEmpty { throw bad("no layer selected") }
        let walk = st.doc.walk()
        var paths: [LayerPath] = []
        for id in roots {
            guard let e = walk.first(where: { $0.layer.id == id }) else { throw EngineError.noLayer(id) }
            paths.append(e.path)
        }
        // A single walk also deduplicates a selected child whose parent is selected.
        var changed = false
        var targets: [(LayerPath, LayerId)] = []
        for e in walk where paths.contains(where: { e.path.starts(with: $0) }) {
            if e.layer.label != color { changed = true }
            targets.append((e.path, e.layer.id))
        }
        if changed {
            try s.edit("Layer Color") { doc, _ in
                for (path, id) in targets {
                    guard doc.updateLayer(at: path, { $0.label = color }) != nil else { throw EngineError.noLayer(id) }
                }
            }
            // This is saved document metadata; no canvas pixels need recompositing.
            s.noteDamage(.empty)
        }
        return ["color": .string(color.id), "layers": .ids(targets.map(\.1)), "changed": .bool(changed)]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec(id, "Layer Color",
                          params: #"{"color":"none|red|orange|yellow|green|seafoam|blue|indigo|magenta|fuchsia|violet|gray","layer":id?} (no layer: selected layers; groups include descendants)"#,
                          module: name, enabled: enabled, run: setLabel))
    }
}
