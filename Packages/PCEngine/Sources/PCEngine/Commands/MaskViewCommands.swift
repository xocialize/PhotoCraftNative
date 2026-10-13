// Port of photocraft-engine (crates/engine/src/mask_view_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// View › layer mask (#196): ⌥-click a layer-mask thumbnail shows the mask as a grayscale image
// instead of the composite; ⇧⌥-click (or the eye on the Channels panel's temporary mask row, or
// `\`) shows it as a rubylith overlay over the composite. This is view state on
// `ChannelView.layerMask` (Core/ChannelTargets.swift, which also keeps it valid and reports it in
// `document.inspect`): no history step, a clean document stays clean, and it never changes a
// pixel. While a mask is shown, pixel commands without an explicit `target` edit that mask.

import PCDocument

enum MaskViewCommands: CommandModule {
    static let name = "mask_view_cmds"
    static let id = "view.layerMask"
    /// `\` (#1765): show or hide the active layer's mask as a rubylith.
    static let overlayId = "layer.toggleMaskOverlay"

    static func bad(_ msg: String) -> EngineError { .bad(id, msg) }

    static func modeName(_ v: LayerMaskView?) -> String {
        switch v?.mode {
        case nil: "off"
        case .gray?: "gray"
        case .overlay?: "overlay"
        }
    }

    /// The view as JSON (`{"layer","mode"}`, or null when off) (photocraft `view_json`).
    static func viewJSON(_ st: DocState) -> JSONValue {
        guard let v = st.currentMaskView else { return .null }
        return ["layer": .id(v.layer), "mode": .string(modeName(v))]
    }

    /// `{"layer":id?,"mode":"off"|"gray"|"overlay"|"toggleGray"|"toggleOverlay"="toggleGray"}`.
    static func setView(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let mode: String
        switch p["mode"] {
        case nil, .some(.null): mode = "toggleGray"
        case let v?:
            guard let m = v.stringValue else { throw bad("`mode` must be a string") }
            mode = m
        }
        guard let st = s.active else { throw EngineError.noDocument }
        let layer: LayerId
        switch p["layer"] {
        case nil, .some(.null):
            guard let a = st.activeLayer else { throw bad("no layer given and no active layer") }
            layer = a
        case let v?:
            guard let n = v.uint64Value else { throw bad("`layer` must be a layer id") }
            layer = LayerId(n)
        }
        guard let l = st.doc.layer(layer) else { throw EngineError.noLayer(layer) }
        let hasMask = l.mask != nil
        let shown = st.currentMaskView.flatMap { $0.layer == layer ? $0.mode : nil }
        let want: MaskViewMode?
        switch mode {
        case "off": want = nil
        case "gray": want = .gray
        case "overlay": want = .overlay
        case "toggleGray": want = shown != .gray ? .gray : nil
        case "toggleOverlay": want = shown != .overlay ? .overlay : nil
        default: throw bad("unknown mode `\(mode)` (off|gray|overlay|toggleGray|toggleOverlay)")
        }
        if want != nil && !hasMask { throw bad("layer \"\(l.name)\" has no layer mask") }
        // ⌥-clicking another layer's mask selects that layer, as in Photoshop.
        if want != nil && s.active?.activeLayer != layer { try s.selectLayer(layer) }
        let next = want.map { LayerMaskView(layer: layer, mode: $0) }
        let current = try s.updateActive { st -> LayerMaskView? in
            // "off" for a layer whose mask isn't the one shown leaves the other view alone.
            let applies = next != nil || st.channelView.layerMask?.layer == layer
            if applies && st.channelView.layerMask != next {
                st.channelView.layerMask = next
                // Hiding the mask while every colour channel is off would leave a blank canvas.
                st.fixChannelView()
                // A view change: redraw without recompositing, and keep a clean document clean.
                Session.noEditRevision(&st)
            }
            return st.currentMaskView
        }
        return ["layer": .id(layer), "mode": .string(modeName(current.flatMap { $0.layer == layer ? $0 : nil }))]
    }

    /// `\` needs a layer mask on the active layer; without one Photoshop's key does nothing.
    static let activeHasMask: CommandEnabled = { s, _ in
        guard let st = s.active else { return "no document open" }
        guard let id = st.activeLayer, let l = st.doc.layer(id) else { return "no active layer" }
        return l.mask != nil ? nil : "layer \"\(l.name)\" has no layer mask"
    }

    /// `{"layer":id?}`: `view.layerMask` with mode `toggleOverlay` (a `mode` param is ignored).
    static func toggleOverlay(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard p.objectValue != nil || p == .null else { throw EngineError.bad(overlayId, "expected an object") }
        let layer = p["layer"] ?? .null
        return try setView(s, ["layer": layer, "mode": "toggleOverlay"])
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec(id, "View Layer Mask",
                          params: ##"{"layer":id?,"mode":"off"|"gray"|"overlay"|"toggleGray"|"toggleOverlay"="toggleGray"} (gray: the mask alone, ⌥-click its thumbnail; overlay: red rubylith over the composite, ⇧⌥-click or `\`; view state, not an undo step; painting while shown paints the mask)"##,
                          module: name, journal: false, enabled: Pre.hasDoc, run: setView))
        r.add(CommandSpec(overlayId, "Toggle Layer Mask Overlay", shortcut: #"\"#,
                          params: ##"{"layer":id?} (shows or hides the active layer's mask as a 50% red rubylith over the composite, the `\` key; view state, not an undo step; painting while shown paints the mask)"##,
                          module: name, journal: false, enabled: activeHasMask, run: toggleOverlay))
    }
}
