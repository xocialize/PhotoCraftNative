// Port of photocraft-engine (crates/engine/src/migrate_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Edit › Presets › Migrate Presets. Photoshop imports presets from a previous version; we merge a
// presets file (another install's preferences, or an exported preset library) into the current
// library, appending groups the library doesn't already have (by name). Headless and scriptable.
// The library is PresetCommands' (gradients, styles, shapes, pattern folders, tool presets); a
// change marks the preferences dirty so the shell persists it.

import Foundation
import PCDocument

enum MigrateCommands: CommandModule {
    static let name = "migrate_cmds"

    /// Appends incoming groups whose name the library doesn't already have; returns how many were
    /// added.
    static func mergeGroups<T>(_ cur: inout [PresetCommands.Group<T>], _ incoming: [PresetCommands.Group<T>]) -> Int {
        var added = 0
        for g in incoming where !cur.contains(where: { $0.name == g.name }) {
            cur.append(g)
            added += 1
        }
        return added
    }

    /// `v[key]` as groups, empty when absent or malformed.
    static func groups<T: Codable & Sendable>(_ v: JSONValue, _ key: String, _ type: T.Type) -> [PresetCommands.Group<T>] {
        guard let g = v[key], let decoded = try? g.decode(as: [PresetCommands.CodableGroup<T>].self) else { return [] }
        return decoded.map(\.group)
    }

    static func migrate(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let path = p["path"]?.stringValue else {
            throw EngineError.bad("edit.presets.migratePresets", "need `path` to a presets or preferences file")
        }
        let data: Data
        do { data = try s.services.fileSystem.read(path) } catch { throw EngineError.other("read `\(path)`: \(EngineError.wrap(error))") }
        guard let text = String(data: data, encoding: .utf8) else { throw EngineError.other("read `\(path)`: stream did not contain valid UTF-8") }
        let root: JSONValue
        do { root = try JSONValue.parse(text) } catch { throw EngineError.other("`\(path)` is not JSON: \(error)") }
        // Accept a full preferences file (has a `presets` section) or a bare presets object.
        let v = root["presets"] ?? root

        var ps = PresetCommands.state(s)
        let g = mergeGroups(&ps.gradients, groups(v, "gradients", PresetCommands.GradientPreset.self))
        let st = mergeGroups(&ps.styles, groups(v, "styles", PresetCommands.StylePreset.self))
        let sh = mergeGroups(&ps.shapes, groups(v, "shapes", PresetCommands.ShapePreset.self))
        let pt = mergeGroups(&ps.patternGroups, groups(v, "pattern_groups", PresetCommands.PatternRef.self))
        // Tool presets are a flat list, matched by name.
        var tp = 0
        if let arr = v["tool_presets"], let incoming = try? arr.decode(as: [PresetCommands.ToolPreset].self) {
            for t in incoming where !ps.toolPresets.contains(where: { $0.name == t.name }) {
                ps.toolPresets.append(t)
                tp += 1
            }
        }
        let total = g + st + sh + pt + tp
        if total > 0 {
            s.state[PresetCommands.Key.self] = ps
            PresetCommands.presetsChanged(s)
        }
        return [
            "migrated": .int(total),
            "added": ["gradients": .int(g), "styles": .int(st), "shapes": .int(sh), "patternGroups": .int(pt), "toolPresets": .int(tp)],
        ]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("edit.presets.migratePresets", "Migrate Presets", menu: ["Edit", "Presets"],
                          params: #"{path} → {migrated, added:{gradients,styles,shapes,patternGroups,toolPresets}}: merge a presets/preferences file into the library (appends groups by name)"#,
                          module: name, journal: false, run: migrate))
    }
}
