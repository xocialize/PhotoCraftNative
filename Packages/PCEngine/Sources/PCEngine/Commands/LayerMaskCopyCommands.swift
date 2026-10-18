// PhotoCraftNative's own command (AB-T-0324): photocraft has no counterpart. MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.
//
// Photoshop's Layers panel moves a layer mask by dragging its thumbnail onto another layer, and copies it with an
// Option-drag; either replaces any mask the target had. There is no menu item, so the command has no menu path.
// The mask keeps everything: its pixels where they sit on the document (masks are document-space surfaces), the
// value outside its content (a Hide All mask's black), density, feather, enabled and linked. Vector masks are out
// of scope.

import PCDocument

enum LayerMaskCopyCommands: CommandModule {
    static let name = "layer_mask_copy_cmds"
    static let copy = "layer.layerMask.copy"

    static func bad(_ msg: String) -> EngineError { .bad(copy, msg) }

    /// The source (`"from"`, else the active layer) and target (`"to"`) layers, or why they can't be used.
    static func layers(_ s: Session, _ p: JSONValue) -> Result<(from: LayerId, to: LayerId), EngineError> {
        guard let st = s.active else { return .failure(.noDocument) }
        if p["from"] != nil && Params.layerId(p, "from") == nil { return .failure(bad("`from` must be a layer id")) }
        guard let from = Params.layerId(p, "from") ?? st.activeLayer else { return .failure(bad("no `from` layer and no active layer")) }
        guard let to = Params.layerId(p, "to") else { return .failure(bad("`to` (a layer id) is required")) }
        guard let source = st.doc.layer(from) else { return .failure(.noLayer(from)) }
        guard st.doc.layer(to) != nil else { return .failure(.noLayer(to)) }
        if source.mask == nil { return .failure(bad("the `from` layer has no layer mask")) }
        if from == to { return .failure(bad("`from` and `to` are the same layer")) }
        return .success((from, to))
    }

    static let enabled: CommandEnabled = { s, p in
        switch layers(s, p) {
        case .failure(let e): e.description
        case .success: nil
        }
    }

    static func run(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let (from, to) = try layers(s, p).get()
        if p["move"] != nil && p["move"]?.boolValue == nil { throw bad("`move` must be a bool") }
        let move = Params.bool(p, "move", false)
        let replaced = s.active?.doc.layer(to)?.mask != nil
        // Photoshop's mask copy (`make` a mask channel `using` another layer's mask, the Option-drag's event)
        // names its step "Add Layer Mask" (measured, AB-T-0308). It refuses a target that has a mask, and no
        // scripted event moves one, so "Replace Layer Mask" and "Move Layer Mask" stay unmeasured names.
        let label = replaced ? "Replace Layer Mask" : move ? "Move Layer Mask" : "Add Layer Mask"
        try s.edit(label) { doc, active in
            guard let mask = doc.layer(from)?.mask else { throw bad("the `from` layer has no layer mask") }
            // A Background taking a mask becomes an ordinary layer, as Add Layer Mask makes it.
            LayerOps.backgroundToLayer(&doc, to)
            let copy = LayerOps.maskAtDepth(mask, doc.depth)
            guard doc.updateLayer(to, { $0.mask = copy }) != nil else { throw EngineError.noLayer(to) }
            if move { doc.updateLayer(from) { $0.mask = nil } }
            active = to
        }
        LayerMulti.reselect(s, [to], active: to)
        return ["layer": .id(to), "replaced": .bool(replaced), "moved": .bool(move)]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec(copy, "Copy Layer Mask",
                          params: #"{"from":id? (default active),"to":id,"move":bool=false} → {layer,replaced,moved} (the layers panel's drag of a mask thumbnail onto another layer, ⌥-drag copies; the mask replaces any the target had and keeps its pixels where they sit, its outside value, density, feather, enabled and linked; move deletes the source's mask in the same step; the target becomes the active layer)"#,
                          module: name, enabled: enabled, run: run))
    }
}
