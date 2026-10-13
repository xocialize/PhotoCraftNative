// Port of photocraft-engine (crates/engine/src/fill_key_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Photoshop's fill keys (#249): ⌥⌫ fills the selection (or the whole layer) with the foreground
// colour, ⌘⌫ with the background colour, and with ⇧ added they preserve transparency. ⌘⌥⌫ fills
// from history: the History Brush's source state (the oldest state still held). Photoshop has no
// menu item for them; here they are ordinary commands with default shortcuts, so they can be
// rebound, recorded and driven by agents. Each one is `edit.fill` with the colour and Preserve
// Transparency fixed: one "Fill" history step, the Channels panel target honoured, locked layers
// refused.

import PCDocument

enum FillKeyCommands: CommandModule {
    static let name = "fill_key_cmds"

    /// The fill-key command ids (routed to the Channels panel target like `edit.fill`).
    static let ids = ["edit.fillForeground", "edit.fillBackground", "edit.fillForegroundPreserve", "edit.fillBackgroundPreserve", "edit.fillHistory"]

    static let params = #"{"layer":id?,"target":"pixels"|"mask"|"quickMask"|{"channel":i}?}"#

    /// `edit.fill`'s precondition.
    static let enabled: CommandEnabled = { s, p in
        guard let fill = s.registry.spec("edit.fill") else { return "Fill is unavailable" }
        if let r = fill.availability.reason { return r }
        return fill.enabled(s, p)
    }

    static func runFill(_ s: Session, _ q: JSONValue) throws -> JSONValue {
        guard let fill = s.registry.spec("edit.fill") else { throw EngineError.other("Fill is unavailable") }
        return try fill.run(s, q)
    }

    /// Runs `edit.fill` with the foreground or background colour and Preserve Transparency.
    static func fill(_ s: Session, _ p: JSONValue, _ cmd: String, background: Bool, preserve: Bool) throws -> JSONValue {
        guard var q = p == .null ? [:] : p.objectValue else { throw EngineError.bad(cmd, "expected an object") }
        // The colour and transparency handling are what the key means; don't let params override them.
        for k in ["color", "contents", "pattern", "preserveTransparency", "opacity"] { q[k] = nil }
        let c = background ? s.tools.background : s.tools.foreground
        q["color"] = [.float(c.x), .float(c.y), .float(c.z), 1]
        q["preserveTransparency"] = .bool(preserve)
        return try runFill(s, .object(q))
    }

    /// ⌘⌥⌫: `edit.fill` from history, the History Brush's source unless `state` names another.
    static func fillHistory(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard var q = p == .null ? [:] : p.objectValue else { throw EngineError.bad("edit.fillHistory", "expected an object") }
        for k in ["color", "contents", "pattern"] { q[k] = nil }
        q["contents"] = "history"
        return try runFill(s, .object(q))
    }

    static func register(into r: inout CommandRegistry) {
        let m = name
        let keys: [(String, String, String, Bool, Bool)] = [
            ("edit.fillForeground", "Fill with Foreground Color", "Alt+Backspace", false, false),
            ("edit.fillBackground", "Fill with Background Color", "Cmd+Backspace", true, false),
            ("edit.fillForegroundPreserve", "Fill with Foreground Color, Preserve Transparency", "Alt+Shift+Backspace", false, true),
            ("edit.fillBackgroundPreserve", "Fill with Background Color, Preserve Transparency", "Cmd+Shift+Backspace", true, true),
        ]
        for (id, label, shortcut, background, preserve) in keys {
            r.add(CommandSpec(id, label, shortcut: shortcut, params: params, module: m, enabled: enabled) { s, p in
                try fill(s, p, id, background: background, preserve: preserve)
            })
        }
        r.add(CommandSpec("edit.fillHistory", "Fill from History", shortcut: "Cmd+Alt+Backspace",
                          params: #"{"state":n? (default: the History Brush's source, the oldest state still held),"layer":id?,"target":"pixels"|"mask"|"quickMask"|{"channel":i}?,"preserveTransparency":bool?}"#,
                          module: m, enabled: enabled) { s, p in try fillHistory(s, p) })
    }
}
