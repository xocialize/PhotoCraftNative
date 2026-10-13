// Port of photocraft-engine (crates/engine/src/commands.rs `Registry`, `build`, `find`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The registry is built from command modules, one registration function per photocraft
// `*_cmds.rs` module, so later packages plug in the same way: a module registers its commands (or
// replaces registered `unavailable` stubs by id) without touching the engine.
// photocraft's dispatch also calls into a few modules on every command (the Channels-panel target,
// the floating selection, Fade, hidden-layer refusals); those are hooks a module installs.

import PCDocument

/// A group of commands ported from one photocraft module.
public protocol CommandModule {
    /// The photocraft module (`layer_menu_cmds`), for coverage reports.
    static var name: String { get }
    /// Adds the module's commands (and hooks) to `registry`.
    static func register(into registry: inout CommandRegistry)
}

/// Engine-wide hooks the dispatch runs for every command (photocraft calls these modules directly).
public struct DispatchHooks: Sendable {
    /// Rewrites the params a command runs with (photocraft `channel_cmds::inject_target`).
    public var prepareParams: [@Sendable (Session, String, JSONValue) -> JSONValue] = []
    /// Runs before the command; a non-nil result ends the dispatch with it (photocraft
    /// `float_cmds::before_command`).
    public var before: [@Sendable (Session, String, JSONValue) throws -> JSONValue?] = []
    /// Refuses a command with a message (photocraft `hidden_target::refusal`).
    public var refusal: [@Sendable (Session, String, JSONValue) -> String?] = []
    /// Overrides a command's precondition for a call (photocraft `channel_cmds::mask_target_enabled`):
    /// `.some(reason)` decides (nil reason = enabled), `.none` leaves it to the command.
    public var enabledOverride: [@Sendable (Session, String, JSONValue) -> Precondition?] = []
    /// After a successful command (photocraft `after_command`: Fade source, mask view, presets).
    public var after: [@Sendable (Session, String, JSONValue) -> Void] = []
    /// After every edit, on the edited document state, with the document before the edit
    /// (photocraft `channel_cmds::fix_view` / `restrict_to_color`).
    public var afterEdit: [@Sendable (Session, inout DocState, Document) -> Void] = []
    /// Commands that never edit the active document, allowed while a job runs on it.
    public var documentIndependent: [@Sendable (String) -> Bool] = []
    /// After every committed step: the session, the document index and the document before.
    public var afterCommit: [@Sendable (Session, Int, Document) -> Void] = []
    /// Keeps view state consistent with the document after any change (photocraft `fix_view`,
    /// `mask_view_cmds::fix`).
    public var viewFixups: [@Sendable (Session, inout DocState) -> Void] = []
    /// Whether the edit target is a layer mask (the Channels panel's target).
    public var maskTargeted: (@Sendable (Session) -> Bool)?
    /// Before a document closes (its index).
    public var onClose: [@Sendable (Session, Int) -> Void] = []
    /// The colour channel a command may change (photocraft `channel_cmds::color_restriction`).
    public var colorRestriction: (@Sendable (Session, String, JSONValue) -> Int?)?
    /// Adds module sections to `document.inspect` (channels, mask view, symmetry…).
    public var documentInspectors: [@Sendable (DocState, inout [String: JSONValue]) -> Void] = []
    /// Folds a journal entry into the previous one (a brush-settings gesture); true = handled.
    public var coalesceJournal: (@Sendable (Session, String, JSONValue) -> Bool)?

    public init() {}
}

/// The command catalogue: menus, palette, shortcuts, the CLI and MCP all read it.
public struct CommandRegistry: Sendable {
    public private(set) var specs: [CommandSpec] = []
    private var index: [String: Int] = [:]
    public var hooks = DispatchHooks()
    /// Modules installed, in order.
    public private(set) var modules: [String] = []

    public init() {}

    /// Adds `spec`. A spec with an id already registered replaces it in place (a package that
    /// lands later replaces the `unavailable` stub of its command).
    public mutating func add(_ spec: CommandSpec) {
        if let i = index[spec.id] {
            specs[i] = spec
        } else {
            index[spec.id] = specs.count
            specs.append(spec)
        }
    }

    public mutating func add(_ specs: [CommandSpec]) { for s in specs { add(s) } }

    /// Adds `spec` only when its id isn't registered yet (stubs never replace implementations).
    public mutating func addIfMissing(_ spec: CommandSpec) {
        if index[spec.id] == nil { add(spec) }
    }

    public mutating func install(_ module: any CommandModule.Type) {
        module.register(into: &self)
        modules.append(module.name)
    }

    public func spec(_ id: String) -> CommandSpec? { index[id].map { specs[$0] } }
    public func contains(_ id: String) -> Bool { index[id] != nil }
    public var count: Int { specs.count }
    public var ids: [String] { specs.map(\.id) }

    /// The engine's own modules (everything the finished packages can serve, plus registered
    /// stubs for what nothing implements yet: the plug-in host).
    nonisolated(unsafe) public static let builtinModules: [any CommandModule.Type] = EngineModules.all

    /// A registry with every built-in module installed. Built once (≈ 900 specs and their schemas)
    /// and copied: a registry is a value, so a session that adds or replaces commands changes only
    /// its own copy.
    public static func standard() -> CommandRegistry { standardRegistry }

    static let standardRegistry: CommandRegistry = {
        var r = CommandRegistry()
        for m in builtinModules { r.install(m) }
        return r
    }()
}
