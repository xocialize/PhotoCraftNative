// Port of photocraft-engine (crates/engine/src/migrate_cmds.rs, `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft's preferences revision (`prefs.rev()`) has no Swift counterpart: a migration that
// changes the library bumps the presets revision and emits `.preferencesChanged` (what the shell
// persists on); the tests check the revision and that the persisted JSON (`prefsValue`) changes
// only when something was added, and survives a reload.

import Foundation
import PCDocument
@testable import PCEngine
import Testing

fileprivate func writeJSON(_ v: JSONValue, _ dir: URL, _ name: String) throws -> String {
    let url = dir.appendingPathComponent(name)
    try Data(v.serialized().utf8).write(to: url)
    return url.path
}

@Suite struct MigrateCommandsTests {
    @Test func mergesNewGroupsOnly() throws {
        let dir = try ioDir("migrate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = Session()
        let before = PresetCommands.state(s).gradients.count
        let existing = try #require(PresetCommands.state(s).gradients.first?.name)
        // A presets file with one new gradient group and one that already exists.
        let file = try writeJSON(["presets": ["gradients": [["name": "My Imported Set", "items": .array([])], ["name": .string(existing), "items": .array([])]]]],
                                 dir, "presets.json")
        let rev = PresetCommands.state(s).rev
        let r = try s.execute("edit.presets.migratePresets", ["path": .string(file)])
        #expect(r["added"]?["gradients"] == 1, "only the new group is added")
        #expect(PresetCommands.state(s).gradients.count == before + 1)
        #expect(PresetCommands.state(s).gradients.contains { $0.name == "My Imported Set" })
        #expect(PresetCommands.state(s).rev == rev + 1, "migration marks the presets changed")
        // Idempotent: migrating again adds nothing.
        let rev2 = PresetCommands.state(s).rev
        let saved = s.prefsValue()
        let r2 = try s.execute("edit.presets.migratePresets", ["path": .string(file)])
        #expect(r2["migrated"] == 0)
        #expect(PresetCommands.state(s).rev == rev2, "duplicate groups change nothing")
        #expect(s.prefsValue() == saved)
    }

    @Test func eachMigratedPresetKindMarksPreferencesDirtyAndSurvivesReload() throws {
        let dir = try ioDir("migrate-persist")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kinds: [(String, JSONValue)] = [
            ("gradients", [["name": "Imported gradients", "items": .array([])]]),
            ("styles", [["name": "Imported styles", "items": .array([])]]),
            ("shapes", [["name": "Imported shapes", "items": .array([])]]),
            ("pattern_groups", [["name": "Imported patterns", "items": ["Bricks"]]]),
            ("tool_presets", [["name": "Imported tool", "tool": "brush", "options": ["size": 17.0]]]),
        ]
        for (key, incoming) in kinds {
            for wrapped in [false, true] {
                let s = Session()
                var data: JSONValue = .object([key: incoming])
                if wrapped { data = ["presets": data] }
                let file = try writeJSON(data, dir, "\(key)-\(wrapped).json")
                let rev = PresetCommands.state(s).rev
                let r = try s.execute("edit.presets.migratePresets", ["path": .string(file)])
                #expect(r["migrated"] == 1, "\(key), wrapped=\(wrapped)")
                #expect(PresetCommands.state(s).rev == rev + 1, "\(key), wrapped=\(wrapped): preferences must be saved")
                let saved = s.prefsValue()
                let restored = Session()
                restored.loadPrefs(saved)
                let imported = try #require(incoming.arrayValue?.first)
                #expect(restored.prefsValue()["presets"]?[key]?.arrayValue?.contains(imported) == true, "\(key), wrapped=\(wrapped)")
            }
        }
    }

    @Test func badPathIsAnError() {
        let s = Session()
        #expect(throws: (any Error).self) { try s.execute("edit.presets.migratePresets", ["path": "/no/such/file.json"]) }
        #expect(throws: (any Error).self) { try s.execute("edit.presets.migratePresets") }
    }
}
