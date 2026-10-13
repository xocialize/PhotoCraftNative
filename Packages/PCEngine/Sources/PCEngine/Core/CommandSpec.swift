// Port of photocraft-engine (crates/engine/src/commands.rs `CommandSpec`, `list_entry`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// One command: id, label, menu path, shortcut, params (photocraft's human/agent-readable notation
// plus a JSON Schema generated from it for UI generation and MCP), the `enabled` precondition, the
// implementation, the journal flag, and — from architecture §4.2 — its kind (instant, dialog,
// interactive) and preview mode. A command whose implementation waits on an unfinished package is
// registered as `unavailable(reason)` so menus, schemas and scripts see it.

import PCDocument

/// How a frontend presents a command (architecture §4.2 `kind`).
public enum CommandKind: String, Sendable, Codable, CaseIterable {
    /// Runs at once (Invert, Deselect).
    case instant
    /// Opens a dialog when invoked from a menu without params (labels ending in "…").
    case dialog
    /// Hands control to a tool or an on-canvas session (Free Transform, Liquify, Puppet Warp).
    case interactive
}

/// Whether a dialog can preview the command on the canvas (architecture §4.2 `preview`).
public enum PreviewMode: String, Sendable, Codable, CaseIterable {
    case none
    /// Re-run on the document copy as parameters change (adjustments, filters).
    case live
    /// Re-run on a reduced proxy (expensive filters).
    case proxy
}

/// Whether the command can run in this build.
public enum Availability: Hashable, Sendable {
    case available
    /// Registered for menus, schemas and scripts, but its implementation waits on something
    /// (`reason` names it, e.g. "needs PCAlgo's resampler").
    case unavailable(String)

    public var reason: String? {
        if case .unavailable(let r) = self { return r }
        return nil
    }
}

/// photocraft `Run`: the command body.
public typealias CommandRun = @Sendable (Session, JSONValue) throws -> JSONValue
/// photocraft `Enabled`: nil when the command can run, else why not. The params are the call's
/// (with the Channels-panel target filled in), so a target can enable a command.
public typealias CommandEnabled = @Sendable (Session, JSONValue) -> Precondition

/// Metadata and implementation of one command.
public struct CommandSpec: Sendable {
    public var id: String
    public var label: String
    /// Menu placement (`["Layer", "New"]`); empty = not in the menus.
    public var menu: [String]
    /// Default shortcut in photocraft's notation (`Cmd+Shift+N`), mapped per platform by the UI.
    public var shortcut: String?
    /// photocraft's params notation, verbatim (`{"radius":0.1..1000=1}`). Setting it regenerates
    /// `schema`.
    public var params: String { didSet { schema = ParamSchema.schema(params) } }
    /// JSON Schema of the params, generated from the notation (`ParamSchema`).
    public var schema: JSONValue
    public var enabled: CommandEnabled
    public var run: CommandRun
    /// Recorded in the session journal (false for queries).
    public var journal: Bool
    public var kind: CommandKind
    public var preview: PreviewMode
    public var availability: Availability
    /// The photocraft module this command comes from (`layer_menu_cmds`), for coverage reports.
    public var module: String

    public init(_ id: String, _ label: String, menu: [String] = [], shortcut: String? = nil, params: String = "{}",
                module: String, journal: Bool = true, kind: CommandKind? = nil, preview: PreviewMode? = nil,
                enabled: @escaping CommandEnabled = Pre.always, run: @escaping CommandRun) {
        self.id = id
        self.label = label
        self.menu = menu
        self.shortcut = shortcut
        self.params = params
        self.schema = ParamSchema.schema(params)
        self.enabled = enabled
        self.run = run
        self.journal = journal
        self.kind = kind ?? CommandSpec.defaultKind(id: id, label: label)
        self.preview = preview ?? CommandSpec.defaultPreview(id: id)
        self.availability = .available
        self.module = module
    }

    /// A registered command that can't run in this build: menus, schemas, `command.list` and
    /// scripts see it, `enabled` reports `reason`, and running it fails with
    /// `EngineError.unavailable`.
    public static func unavailable(_ id: String, _ label: String, menu: [String] = [], shortcut: String? = nil, params: String = "{}",
                                   module: String, journal: Bool = true, reason: String) -> CommandSpec {
        var s = CommandSpec(id, label, menu: menu, shortcut: shortcut, params: params, module: module, journal: journal,
                            enabled: { _, _ in reason }, run: { _, _ in throw EngineError.unavailable(id, reason) })
        s.availability = .unavailable(reason)
        return s
    }

    public var isAvailable: Bool { availability == .available }

    static let interactiveIds: Set<String> = [
        "edit.transform", "filter.liquify", "edit.puppetWarp", "layer.smartObjects.puppetWarp", "edit.perspectiveWarp",
        "layer.smartObjects.perspectiveWarp", "edit.transform.warp", "layer.smartObjects.warp", "filter.vanishingPoint",
        "select.transformSelection", "type.edit", "paint.stroke", "paint.pencil", "paint.mixerBrush", "paint.colorReplacement",
    ]

    static func defaultKind(id: String, label: String) -> CommandKind {
        if interactiveIds.contains(id) { return .interactive }
        return label.hasSuffix("…") ? .dialog : .instant
    }

    static func defaultPreview(id: String) -> PreviewMode {
        if id.hasPrefix("image.adjustments.") || id.hasPrefix("layer.newAdjustmentLayer.") || id == "layer.setAdjustment" { return .live }
        if id.hasPrefix("filter.blurGallery.") || id == "filter.blur.lensBlur" || id.hasPrefix("filter.gallery.") { return .proxy }
        if id.hasPrefix("filter.") { return .live }
        return .none
    }
}

/// A recorded or scripted call: what actions, droplets and batch files store.
public struct CommandInvocation: Hashable, Sendable, Codable {
    public var id: String
    public var params: JSONValue
    public init(_ id: String, _ params: JSONValue = .object([:])) { self.id = id; self.params = params }
}

/// photocraft's precondition helpers (`always`, `has_doc`, `has_layer`, …), for `enabled`.
public enum Pre {
    public static let always: CommandEnabled = { _, _ in nil }
    public static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document open" : nil }
    public static let hasLayer: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        guard let id = d.activeLayer, d.doc.layer(id) != nil else { return "no active layer" }
        return nil
    }
    public static let hasPixelLayer: CommandEnabled = { s, _ in
        switch s.activeLayer() {
        case .failure(let why): return why.description
        case .success(let l):
            if case .raster = l.content { return nil }
            return "active layer is \(l.content.article) \(l.content.kindName) layer, not a pixel layer"
        }
    }
    public static let hasSelection: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.selection == nil ? "no selection" : nil
    }
    public static let canUndo: CommandEnabled = { s, _ in s.active?.history.canUndo == true ? nil : "nothing to undo" }
    public static let canRedo: CommandEnabled = { s, _ in s.active?.history.canRedo == true ? nil : "nothing to redo" }

    /// All of `checks`, the first failing one's reason.
    public static func all(_ checks: CommandEnabled...) -> CommandEnabled {
        { s, p in
            for c in checks { if let why = c(s, p) { return why } }
            return nil
        }
    }
}
