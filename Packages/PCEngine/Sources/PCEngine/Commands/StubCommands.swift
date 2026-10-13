// Port of photocraft-engine's registry completeness (crates/engine/src/commands.rs `build`): every photocraft command id is registered, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Installed last: every command of `PhotocraftCatalog` that no module implemented is registered as
// `unavailable(reason)` with photocraft's label, menu path, shortcut and params, so menus, the
// palette, `command.list`, scripts and MCP see the whole catalogue. The reason names what the
// command waits on (only the plug-in host's `plugin.*` ids are left). A package that lands later
// replaces these by id.

import PCDocument

enum StubCommands: CommandModule {
    static let name = "stubs"

    /// Why a module's commands can't run in this build.
    static func reason(module: String, id: String) -> String {
        switch module {
        case "plugin_cmds":
            return "the WebAssembly plug-in host (photocraft-plugins) is not ported"
        default:
            return "not ported yet (photocraft \(module).rs)"
        }
    }

    static func register(into r: inout CommandRegistry) {
        for c in PhotocraftCatalog.commands where !r.contains(c.id) {
            r.add(.unavailable(c.id, c.label, menu: c.menu, shortcut: c.shortcut, params: c.params, module: c.module,
                               reason: reason(module: c.module, id: c.id)))
        }
    }
}

/// Command coverage against photocraft's catalogue, per module.
public struct CoverageReport: Sendable {
    public struct Row: Sendable {
        public var module: String
        public var total: Int
        public var implemented: Int
        public var stubbed: Int
        /// In photocraft's catalogue but not registered at all.
        public var missing: Int
    }

    public var rows: [Row]
    /// Registered commands that photocraft doesn't have (new ids, e.g. the AI tier's).
    public var extra: [String]

    public init(registry: CommandRegistry) {
        var by: [String: Row] = [:]
        for c in PhotocraftCatalog.commands {
            var row = by[c.module] ?? Row(module: c.module, total: 0, implemented: 0, stubbed: 0, missing: 0)
            row.total += 1
            switch registry.spec(c.id)?.availability {
            case .available?: row.implemented += 1
            case .unavailable?: row.stubbed += 1
            case nil: row.missing += 1
            }
            by[c.module] = row
        }
        rows = by.values.sorted { $0.module < $1.module }
        extra = registry.ids.filter { PhotocraftCatalog.byId[$0] == nil }
    }

    public var total: Int { rows.reduce(0) { $0 + $1.total } }
    public var implemented: Int { rows.reduce(0) { $0 + $1.implemented } }
    public var stubbed: Int { rows.reduce(0) { $0 + $1.stubbed } }
    public var missing: Int { rows.reduce(0) { $0 + $1.missing } }

    /// A Markdown table (PORT-NOTES).
    public var markdown: String {
        var s = "| photocraft module | commands | implemented | stubbed (`unavailable`) | not registered |\n|---|---:|---:|---:|---:|\n"
        for r in rows { s += "| `\(r.module)` | \(r.total) | \(r.implemented) | \(r.stubbed) | \(r.missing) |\n" }
        s += "| **total** | **\(total)** | **\(implemented)** | **\(stubbed)** | **\(missing)** |\n"
        return s
    }

    public var json: JSONValue {
        [
            "total": .int(total), "implemented": .int(implemented), "stubbed": .int(stubbed), "missing": .int(missing),
            "extra": .strings(extra),
            "modules": .array(rows.map { ["module": .string($0.module), "total": .int($0.total), "implemented": .int($0.implemented),
                                         "stubbed": .int($0.stubbed), "missing": .int($0.missing)] }),
        ]
    }
}
