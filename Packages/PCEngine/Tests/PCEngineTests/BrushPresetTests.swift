// Port of photocraft-engine (crates/engine/src/brush_preset_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCDocument
@testable import PCEngine
import PCPaint
import Testing

@Suite struct BrushPresetTests {
    typealias B = BrushPresetCommands

    func names(_ s: Session, _ g: String) -> [String] { s.tools.presets.filter { $0.group == g }.map(\.name) }

    func add(_ s: Session, _ name: String, _ group: String, _ folder: [String] = []) {
        s.tools.presets.append(BrushPreset(name: name, brush: BrushSettings(), builtin: false, group: group, folder: folder))
    }

    func withGroups() -> Session {
        let s = Session()
        for (n, g) in [("A1", "Alpha"), ("A2", "Alpha"), ("A3", "Alpha"), ("B1", "Beta"), ("B2", "Beta")] { add(s, n, g) }
        return s
    }

    @Test func moveWithinAndBetweenGroups() throws {
        let s = withGroups()
        let r = try s.execute("brush.presets.move", ["name": "A3", "before": "A1"])
        #expect(r == ["name": "A3", "group": "Alpha", "folder": [], "index": 0])
        #expect(names(s, "Alpha") == ["A3", "A1", "A2"])
        try s.execute("brush.presets.move", ["name": "A3", "index": 99])
        #expect(names(s, "Alpha") == ["A1", "A2", "A3"])
        try s.execute("brush.presets.move", ["name": "A1", "index": 1])
        #expect(names(s, "Alpha") == ["A2", "A1", "A3"])
        // Into another group, before a member (the group comes from `before`).
        try s.execute("brush.presets.move", ["name": "A1", "before": "B2"])
        #expect(names(s, "Alpha") == ["A2", "A3"] && names(s, "Beta") == ["B1", "A1", "B2"])
        // Into a group by name (appended), and into a new group.
        try s.execute("brush.presets.move", ["name": "A2", "group": "Beta"])
        #expect(names(s, "Beta") == ["B1", "A1", "B2", "A2"])
        try s.execute("brush.presets.move", ["name": "A3", "group": "Gamma"])
        #expect(B.groupOrder(s.tools.presets).last == "Gamma")
        #expect(names(s, "Alpha").isEmpty)
        // A built-in moved to another group becomes the user's.
        let b = try #require(s.tools.presets.first { $0.builtin }).name
        try s.execute("brush.presets.move", ["name": .string(b), "group": "Beta", "index": 0])
        let moved = try #require(BrushPresets.find(s.tools.presets, b))
        #expect(!moved.builtin && moved.group == "Beta")
        #expect(names(s, "Beta").first == b)
    }

    @Test func groupsMoveRenameAndDelete() throws {
        let s = withGroups()
        let order = B.groupOrder(s.tools.presets)
        #expect(Array(order.suffix(2)) == ["Alpha", "Beta"])
        let r = try s.execute("brush.presets.moveGroup", ["group": "Beta", "index": 0])
        #expect(r["index"] == 0)
        #expect(B.groupOrder(s.tools.presets).first == "Beta")
        #expect(names(s, "Beta") == ["B1", "B2"], "a group moves as a block, in order")
        try s.execute("brush.presets.moveGroup", ["group": "Alpha", "before": "Beta"])
        #expect(Array(B.groupOrder(s.tools.presets).prefix(2)) == ["Alpha", "Beta"])
        try s.execute("brush.presets.moveGroup", ["group": "Alpha"])
        #expect(B.groupOrder(s.tools.presets).last == "Alpha")
        try s.execute("brush.presets.renameGroup", ["group": "Alpha", "newName": "First"])
        #expect(names(s, "First") == ["A1", "A2", "A3"])
        #expect(throws: EngineError.self) { try s.execute("brush.presets.renameGroup", ["group": "First", "newName": "Beta"]) }
        let d = try s.execute("brush.presets.deleteGroup", ["group": "First"])
        #expect(d["deleted"] == 3)
        #expect(names(s, "First").isEmpty)
    }

    @Test func renameChecksNames() throws {
        let s = withGroups()
        try s.execute("brush.presets.rename", ["name": "a1", "newName": "Alpha One"])
        #expect(BrushPresets.find(s.tools.presets, "Alpha One") != nil)
        #expect(throws: EngineError.self) { try s.execute("brush.presets.rename", ["name": "A2", "newName": "alpha one"]) }
        // Case-only renames of itself are fine.
        try s.execute("brush.presets.rename", ["name": "Alpha One", "newName": "ALPHA ONE"])
        let b = try #require(s.tools.presets.first { $0.builtin }).name
        try s.execute("brush.presets.rename", ["name": .string(b), "newName": "My Round"])
        #expect(BrushPresets.find(s.tools.presets, "My Round")?.builtin == false)
    }

    @Test func badParamsFailWithoutChanges() throws {
        let s = withGroups()
        let before = s.tools.presets
        let long = JSONValue.string(String(repeating: "x", count: B.maxName + 1))
        let cases: [(String, JSONValue)] = [
            ("brush.presets.move", [:]),
            ("brush.presets.move", ["name": "Nope"]),
            ("brush.presets.move", ["name": "A1", "before": "A1"]),
            ("brush.presets.move", ["name": "A1", "before": "Nope"]),
            ("brush.presets.move", ["name": "A1", "group": "Alpha", "before": "B1"]),
            ("brush.presets.move", ["name": "A1", "index": -1]),
            ("brush.presets.move", ["name": "A1", "index": "first"]),
            ("brush.presets.move", ["name": "A1", "group": 7]),
            ("brush.presets.move", ["name": "A1", "group": long]),
            ("brush.presets.rename", ["name": "A1"]),
            ("brush.presets.rename", ["name": "A1", "newName": "  "]),
            ("brush.presets.rename", ["name": "A1", "newName": long]),
            ("brush.presets.moveGroup", ["group": "Nope"]),
            ("brush.presets.moveGroup", ["group": "Alpha", "before": "Alpha"]),
            ("brush.presets.moveGroup", ["group": "Alpha", "index": 1.5]),
            ("brush.presets.renameGroup", ["group": "Alpha"]),
            ("brush.presets.deleteGroup", ["group": nil]),
            ("brush.presets.deleteGroup", ["group": "Nope"]),
        ]
        for (id, p) in cases {
            #expect(throws: EngineError.self, "\(id) \(p)") { try s.execute(id, p) }
        }
        #expect(s.tools.presets == before)
        // Huge indices clamp to the end.
        try s.execute("brush.presets.move", ["name": "A1", "index": .number(Double(UInt64.max))])
        try s.execute("brush.presets.moveGroup", ["group": "Alpha", "index": .number(Double(UInt64.max))])
    }

    /// Group "Set": S0 at its top level, folders Ink (I1, I2; subfolder Fine: F1) and Dry (D1).
    func withFolders() -> Session {
        let s = Session()
        for (n, f) in [("S0", [String]()), ("I1", ["Ink"]), ("F1", ["Ink", "Fine"]), ("I2", ["Ink"]), ("D1", ["Dry"])] { add(s, n, "Set", f) }
        return s
    }

    func folderOf(_ s: Session, _ n: String) -> [String] { BrushPresets.find(s.tools.presets, n)?.folder ?? ["<missing>"] }

    @Test func presetsMoveBetweenFolders() throws {
        let s = withFolders()
        // `before` brings its folder.
        let r = try s.execute("brush.presets.move", ["name": "D1", "before": "I2"])
        #expect(r["folder"] == ["Ink"])
        #expect(folderOf(s, "D1") == ["Ink"])
        // An explicit folder, appended at the end of it.
        try s.execute("brush.presets.move", ["name": "S0", "folder": ["Ink", "Fine"]])
        #expect(folderOf(s, "S0") == ["Ink", "Fine"])
        func pos(_ n: String) -> Int { s.tools.presets.firstIndex { $0.name == n } ?? -1 }
        #expect(pos("S0") == pos("F1") + 1)
        // Within its group without a folder keeps its folder; to another group without one lands
        // at that group's top level; `folder: []` is the group's top level.
        try s.execute("brush.presets.move", ["name": "S0", "index": 0])
        #expect(folderOf(s, "S0") == ["Ink", "Fine"])
        try s.execute("brush.presets.move", ["name": "S0", "group": "Other"])
        #expect(folderOf(s, "S0").isEmpty)
        try s.execute("brush.presets.move", ["name": "I1", "folder": []])
        #expect(folderOf(s, "I1").isEmpty)
        // `before` in another folder than the one named.
        #expect(throws: EngineError.self) { try s.execute("brush.presets.move", ["name": "I1", "folder": ["Dry"], "before": "I2"]) }
        #expect(B.subfolderOrder(s.tools.presets, "Set", []) == ["Ink"])
    }

    @Test func foldersMoveRenameAndDelete() throws {
        let s = withFolders()
        #expect(B.subfolderOrder(s.tools.presets, "Set", []) == ["Ink", "Dry"])
        // Move Dry before Ink: the whole folder moves as a block.
        let r = try s.execute("brush.presets.moveGroup", ["group": "Set", "folder": ["Dry"], "before": "Ink"])
        #expect(r == ["group": "Set", "folder": ["Dry"], "index": 0])
        #expect(B.subfolderOrder(s.tools.presets, "Set", []) == ["Dry", "Ink"])
        try s.execute("brush.presets.moveGroup", ["group": "Set", "folder": ["Dry"]])
        #expect(B.subfolderOrder(s.tools.presets, "Set", []) == ["Ink", "Dry"])
        try s.execute("brush.presets.moveGroup", ["group": "Set", "folder": ["Dry"], "index": 0])
        #expect(B.subfolderOrder(s.tools.presets, "Set", []) == ["Dry", "Ink"])
        let ink = s.tools.presets.filter { $0.folder.first == "Ink" }.map(\.name)
        #expect(ink == ["I1", "F1", "I2"], "presets keep their order inside a moved folder")
        // Rename a nested folder: every preset below it follows.
        let rr = try s.execute("brush.presets.renameGroup", ["group": "Set", "folder": ["Ink"], "newName": "Inks"])
        #expect(rr["folder"] == ["Inks"])
        #expect(folderOf(s, "F1") == ["Inks", "Fine"])
        #expect(throws: EngineError.self) { try s.execute("brush.presets.renameGroup", ["group": "Set", "folder": ["Inks"], "newName": "Dry"]) }
        // Renaming the group keeps the folders.
        try s.execute("brush.presets.renameGroup", ["group": "Set", "newName": "Kit"])
        #expect(folderOf(s, "F1") == ["Inks", "Fine"])
        // Delete a nested folder: only the presets in it (and below) go.
        let d = try s.execute("brush.presets.deleteGroup", ["group": "Kit", "folder": ["Inks"]])
        #expect(d["deleted"] == 3)
        #expect(BrushPresets.find(s.tools.presets, "S0") != nil)
        #expect(BrushPresets.find(s.tools.presets, "D1") != nil)
    }

    @Test func badFolderParamsFailWithoutChanges() throws {
        let s = withFolders()
        let before = s.tools.presets
        let long = JSONValue.string(String(repeating: "x", count: B.maxName + 1))
        let deep = JSONValue.strings(Array(repeating: "a", count: B.maxFolderDepth + 1))
        let cases: [(String, JSONValue)] = [
            ("brush.presets.move", ["name": "S0", "folder": "Ink"]),
            ("brush.presets.move", ["name": "S0", "folder": [""]]),
            ("brush.presets.move", ["name": "S0", "folder": [7]]),
            ("brush.presets.move", ["name": "S0", "folder": [long]]),
            ("brush.presets.move", ["name": "S0", "folder": deep]),
            ("brush.presets.moveGroup", ["group": "Set", "folder": ["Nope"]]),
            ("brush.presets.moveGroup", ["group": "Set", "folder": ["Ink"], "before": "Ink"]),
            ("brush.presets.moveGroup", ["group": "Set", "folder": ["Ink"], "before": "Nope"]),
            ("brush.presets.moveGroup", ["group": "Set", "folder": ["Ink"], "before": 3]),
            ("brush.presets.moveGroup", ["group": "Set", "folder": ["Ink"], "index": -2]),
            ("brush.presets.renameGroup", ["group": "Set", "folder": ["Ink"], "newName": ""]),
            ("brush.presets.renameGroup", ["group": "Set", "folder": ["Ink", "Nope"], "newName": "x"]),
            ("brush.presets.deleteGroup", ["group": "Set", "folder": ["Dry", "Nope"]]),
            ("brush.presets.deleteGroup", ["group": "Nope", "folder": ["Dry"]]),
        ]
        for (id, p) in cases {
            #expect(throws: EngineError.self, "\(id) \(p)") { try s.execute(id, p) }
        }
        #expect(s.tools.presets == before)
        try s.execute("brush.presets.moveGroup", ["group": "Set", "folder": ["Ink", "Fine"], "index": .number(Double(UInt64.max))])
    }

    func paths(_ s: Session) -> [String] {
        s.tools.presets.filter { !$0.builtin }.map { "\($0.group):\($0.folder.joined(separator: "/")):\($0.name)" }
    }

    /// `withFolders` plus group "Other" holding O1, and folder Box (B1) in it.
    func withTwoGroups() -> Session {
        let s = withFolders()
        add(s, "O1", "Other")
        add(s, "B1", "Other", ["Box"])
        return s
    }

    @Test func foldersMoveIntoFoldersAndGroups() throws {
        let s = withTwoGroups()
        // A nested folder into a sibling folder: its subtree follows, order kept.
        let r = try s.execute("brush.presets.moveGroup", ["group": "Set", "folder": ["Dry"], "into": ["group": "Set", "folder": ["Ink", "Fine"]]])
        #expect(r == ["group": "Set", "folder": ["Ink", "Fine", "Dry"], "index": 0])
        #expect(folderOf(s, "D1") == ["Ink", "Fine", "Dry"])
        // Into another group, before one of its folders.
        let r2 = try s.execute("brush.presets.moveGroup", ["group": "Set", "folder": ["Ink"], "into": ["group": "Other"], "before": "Box"])
        #expect(r2["folder"] == ["Ink"])
        #expect(paths(s) == ["Set::S0", "Other::O1", "Other:Ink:I1", "Other:Ink/Fine:F1", "Other:Ink/Fine/Dry:D1", "Other:Ink:I2", "Other:Box:B1"])
        // Out to the top level: the folder becomes a group of its own.
        let r3 = try s.execute("brush.presets.moveGroup", ["group": "Other", "folder": ["Ink", "Fine"], "into": [:]])
        #expect(r3["group"] == "Fine")
        #expect(folderOf(s, "D1") == ["Dry"])
        #expect(BrushPresets.find(s.tools.presets, "F1")?.group == "Fine")
        // A whole group into another group's folder.
        try s.execute("brush.presets.moveGroup", ["group": "Fine", "into": ["group": "Set"]])
        #expect(names(s, "Fine").isEmpty)
        #expect(folderOf(s, "D1") == ["Fine", "Dry"])
        #expect(B.subfolderOrder(s.tools.presets, "Set", []) == ["Fine"])
    }

    @Test func badMovesIntoFoldersFailWithoutChanges() throws {
        let s = withTwoGroups()
        // A chain 31 deep under Set/Deep.
        let deep = ["Deep"] + (0..<30).map { "d\($0)" }
        add(s, "Z", "Set", deep)
        add(s, "Y", "Other", ["Dry"])
        let before = s.tools.presets
        let cases: [JSONValue] = [
            // Into itself or its own descendant.
            ["group": "Set", "folder": ["Ink"], "into": ["group": "Set", "folder": ["Ink"]]],
            ["group": "Set", "folder": ["Ink"], "into": ["group": "Set", "folder": ["Ink", "Fine"]]],
            ["group": "Set", "into": ["group": "Set", "folder": ["Dry"]]],
            ["group": "Set", "into": ["group": "Set"]],
            // A group already at the top level.
            ["group": "Set", "into": [:]],
            // A name clash at the destination.
            ["group": "Set", "folder": ["Dry"], "into": ["group": "Other"]],
            ["group": "Other", "folder": ["Box"], "into": ["group": "Set", "folder": ["Ink"]], "before": "Nope"],
            ["group": "Set", "folder": ["Dry"], "into": ["group": "Set", "folder": ["Ink"]], "index": 0],
            // Missing destinations and bad shapes.
            ["group": "Set", "folder": ["Dry"], "into": ["group": "Nope"]],
            ["group": "Set", "folder": ["Dry"], "into": ["group": "Other", "folder": ["Nope"]]],
            ["group": "Set", "folder": ["Dry"], "into": ["folder": ["Box"]]],
            ["group": "Set", "folder": ["Dry"], "into": "Other"],
            ["group": "Set", "folder": ["Dry"], "into": ["group": 5]],
            ["group": "Set", "folder": ["Dry"], "into": ["group": "Other"], "before": 3],
            // Deeper than maxFolderDepth once moved (Ink/Fine is 2 deep: 2 + 31 > 32).
            ["group": "Set", "folder": ["Deep"], "into": ["group": "Set", "folder": ["Ink", "Fine"]]],
            ["group": "Set", "folder": ["Ink"], "into": ["group": "Set", "folder": .strings(deep)]],
        ]
        for p in cases {
            #expect(throws: EngineError.self, "\(p)") { try s.execute("brush.presets.moveGroup", p) }
        }
        #expect(s.tools.presets == before)
        // Ink/Fine into Set itself: a clash with nothing, so it moves up a level.
        try s.execute("brush.presets.moveGroup", ["group": "Set", "folder": ["Ink", "Fine"], "into": ["group": "Set"]])
        #expect(folderOf(s, "F1") == ["Fine"])
        // An ungrouped preset's group can't move.
        add(s, "U", "")
        #expect(throws: EngineError.self) { try s.execute("brush.presets.moveGroup", ["group": "", "into": ["group": "Set"]]) }
    }
}
