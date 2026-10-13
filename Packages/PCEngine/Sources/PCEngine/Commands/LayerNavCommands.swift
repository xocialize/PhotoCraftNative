// Port of photocraft-engine (crates/engine/src/layer_nav_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Keyboard layer navigation, the shortcuts that have no menu item (#352): ⌥] / ⌥[ select the
// layer above / below, ⌥. / ⌥, the top / bottom layer, and ⇧⌥] / ⇧⌥[ add the layer above /
// below to the selection. They follow the Layers panel's rows, top to bottom: a group's row comes
// before its children, and the children of a collapsed group are skipped.

import PCDocument

enum LayerNavCommands: CommandModule {
    static let name = "layer_nav_cmds"

    static let hasLayers: CommandEnabled = { s, _ in
        guard let st = s.active else { return "no document open" }
        return st.doc.layers.isEmpty ? "the document has no layers" : nil
    }

    /// The Layers panel's rows, top to bottom: each group before its children, collapsed groups
    /// without them (photocraft `panel_rows`).
    static func panelRows(_ doc: Document) -> [LayerId] {
        var out: [LayerId] = []
        func rec(_ layers: [Layer]) {
            for l in layers.reversed() {
                out.append(l.id)
                if let g = l.group, g.expanded { rec(g.children) }
            }
        }
        rec(doc.layers)
        return out
    }

    /// Where `id` is in `rows`; a layer inside a collapsed group counts as that group's row (the
    /// nearest enclosing one that has a row).
    static func rowOf(_ doc: Document, _ rows: [LayerId], _ id: LayerId) -> Int? {
        guard let path = doc.path(of: id), !path.isEmpty else { return nil }
        for n in stride(from: path.count, through: 1, by: -1) {
            if let l = doc.layer(at: Array(path[..<n])), let i = rows.firstIndex(of: l.id) { return i }
        }
        return nil
    }

    enum Step { case above, below, top, bottom }

    /// Selects (or with `add`, adds to the selection) the row `step` away from the active layer.
    /// At the top or bottom row the selection stays as it is.
    static func navigate(_ s: Session, _ step: Step, add: Bool) throws -> JSONValue {
        guard let st = s.active else { throw EngineError.noDocument }
        let rows = panelRows(st.doc)
        guard !rows.isEmpty else { throw EngineError.other("the document has no layers") }
        let last = rows.count - 1
        let current = st.activeLayer.flatMap { rowOf(st.doc, rows, $0) }
        let target: Int
        switch (step, current) {
        case (.top, _), (.above, nil): target = 0
        case (.bottom, _), (.below, nil): target = last
        case (.above, let i?): target = max(i - 1, 0)
        case (.below, let i?): target = min(i + 1, last)
        }
        guard target >= 0, target < rows.count else { throw EngineError.other("no layer there") }
        let id = rows[target]
        if add {
            var sel = st.selectedLayers
            if !sel.contains(id) { sel.append(id) }
            try LayerMulti.setSelection(s, sel, active: id, anchor: st.layerAnchor)
        } else {
            try s.selectLayer(id)
        }
        guard let after = s.active else { throw EngineError.noDocument }
        return ["layer": .id(id), "selected": .ids(after.selectedLayers)]
    }

    static func register(into r: inout CommandRegistry) {
        let params = "{} (follows the Layers panel's rows; collapsed groups are one row)"
        let items: [(String, String, String, Step, Bool)] = [
            ("layer.selectAbove", "Select Layer Above", "Alt+]", .above, false),
            ("layer.selectBelow", "Select Layer Below", "Alt+[", .below, false),
            ("layer.selectTop", "Select Top Layer", "Alt+.", .top, false),
            ("layer.selectBottom", "Select Bottom Layer", "Alt+,", .bottom, false),
            ("layer.addAboveToSelection", "Add Layer Above to Selection", "Alt+Shift+]", .above, true),
            ("layer.addBelowToSelection", "Add Layer Below to Selection", "Alt+Shift+[", .below, true),
        ]
        for (id, label, shortcut, step, add) in items {
            r.add(CommandSpec(id, label, shortcut: shortcut, params: params, module: name, enabled: hasLayers) { s, _ in
                try navigate(s, step, add: add)
            })
        }
    }
}
