// Port of photocraft-engine (crates/engine/src/actions_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
@testable import PCEngine
import Testing

@Suite struct ActionsTests {
    typealias Action = ActionsCommands.Action
    typealias Key = ActionsCommands.ActionStateKey

    func actions(_ s: Session) -> ActionsCommands.ActionState { ActionsCommands.state(s) }

    func step(_ name: String) -> CommandInvocation { CommandInvocation("layer.new.layer", ["name": .string(name)]) }

    /// Names of the layers above the Background.
    func names(_ s: Session) -> [String] { s.active?.doc.layers.dropFirst().map(\.name) ?? [] }

    @Test func uncheckedStepsAreSkippedAndFollowMoveAndDelete() throws {
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 8])
        s.state[Key.self].list.append(Action("Three", [step("A"), step("B"), step("C")]))

        #expect(try s.execute("actions.toggle", ["action": "Three", "step": 1])["disabled"] == [1])
        let played = try s.execute("actions.play", ["action": 0])
        #expect(played["ran"] == 2)
        #expect(names(s) == ["A", "C"], "the unchecked step is skipped")
        #expect(try s.execute("actions.get", ["action": 0])["disabled"] == [1])

        // Moving step 3 to the top keeps B (now step 2) unchecked; deleting the moved step shifts it to 1.
        try s.execute("actions.move", ["action": 0, "step": 2, "to": 0])
        #expect(actions(s).list[0].steps.map { $0.params["name"]?.stringValue ?? "" } == ["C", "A", "B"])
        #expect(actions(s).list[0].disabled == [2])
        try s.execute("actions.delete", ["action": 0, "step": 0])
        #expect(actions(s).list[0].steps == [step("A"), step("B")], "deleting removes only that step")
        #expect(actions(s).list[0].disabled == [1])

        // The action's own check: all on unless all already are.
        try s.execute("actions.toggle", ["action": 0])
        #expect(actions(s).list[0].disabled.isEmpty)
        try s.execute("actions.toggle", ["action": 0])
        #expect(actions(s).list[0].disabled.count == 2)
        try s.execute("actions.toggle", ["action": 0, "step": 0, "enabled": true])
        #expect(actions(s).list[0].disabled == [1])

        let bad: [JSONValue] = [
            ["action": 0, "step": 2], ["action": 0, "step": -1], ["action": 0, "step": "x"],
            ["action": 0, "step": 0, "enabled": "yes"], ["action": 7, "step": 0], [:],
        ]
        for p in bad { #expect(throws: (any Error).self, "\(p)") { try s.execute("actions.toggle", p) } }
        #expect(actions(s).list[0].disabled == [1], "rejected toggles change nothing")
    }

    @Test func renameKeepsCallsAndFunctionKeyAndRejectsBadNames() throws {
        let s = Session()
        s.state[Key.self].list.append(Action("Action 1", [CommandInvocation("layer.new.layer")]))
        s.state[Key.self].list.append(Action("Caller", [CommandInvocation("actions.play", ["action": "Action 1"])]))
        s.preferences = Preferences(values: s.preferences.values.setting("shortcuts", ["actions.play:Action 1": "F2"]))
        #expect(try s.execute("actions.rename", ["action": 0, "name": "Sepia"])["action"] == "Sepia")
        #expect(try s.execute("actions.list")["actions"]?[0]?["name"] == "Sepia")
        #expect(actions(s).list[1].steps[0].params["action"] == "Sepia")
        #expect(s.preferences["shortcuts"]?["actions.play:Sepia"] == "F2")
        #expect(s.preferences["shortcuts"]?["actions.play:Action 1"] == nil)
        let bad: [JSONValue] = [
            ["action": 0, "name": ""], ["action": 0, "name": "  "], ["action": 0, "name": "Caller"],
            ["action": 0, "name": 7], ["action": 9, "name": "X"], ["action": 0],
        ]
        for p in bad { #expect(throws: (any Error).self, "\(p)") { try s.execute("actions.rename", p) } }
        #expect(actions(s).list[0].name == "Sepia")
    }

    /// photocraft's `record_red`, with a selection-masked Solid Color layer for Edit › Fill (not
    /// ported yet): the recording keeps the edits, not the queries.
    func recordRed(_ s: Session, depth: Int) throws {
        try s.execute("file.new", ["width": 40, "height": 40, "depth": .int(depth)])
        try s.execute("actions.record", ["name": "Red"])
        try s.execute("layer.new.layer")
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 10, "height": 10])
        try s.execute("layer.newFillLayer.solidColor", ["color": "#ff0000"])
        _ = try? s.execute("document.pixel", ["x": 1, "y": 1])
        _ = try? s.execute("actions.list")
        try s.execute("actions.stop")
    }

    @Test func recordKeepsOnlyReplayableSteps() throws {
        let s = Session()
        try recordRed(s, depth: 8)
        let got = try s.execute("actions.get", ["action": "Red"])
        #expect(got["steps"]?.arrayValue?.compactMap { $0[0]?.stringValue } == ["layer.new.layer", "select.rect", "layer.newFillLayer.solidColor"])
        #expect(s.journal.allSatisfy { !$0.id.hasPrefix("actions.") })
        let listed = try s.execute("actions.list")
        #expect(listed["actions"]?[0]?["steps"] == 3)
        #expect(listed["recording"] == .null)
    }

    @Test(arguments: [8, 16, 32]) func playOnAnotherDocumentMatchesPixelsAtEachDepth(depth: Int) throws {
        let s = Session()
        try recordRed(s, depth: depth)
        try s.execute("file.new", ["width": 40, "height": 40, "depth": .int(depth)])
        let before = try #require(s.active).history.pastCount
        let r = try s.execute("actions.play", ["action": 0])
        #expect(r["failed"] == nil, "depth \(depth): \(r)")
        #expect(r["ran"] == 3)
        #expect(s.active?.doc.layers.count == 3)
        #expect(s.active?.history.pastCount == before + 3, "one history step per played step")
        let px = try #require(try s.execute("document.pixel", ["x": 5, "y": 5]).arrayValue?.compactMap(\.doubleValue))
        #expect(px.count == 4 && zip(px, [1.0, 0, 0, 1]).allSatisfy { abs($0 - $1) < 1e-5 }, "depth \(depth): \(px)")
        #expect(actions(s).playing == 0)
    }

    @Test func playStopsAtTheFailingStepAndReportsIt() throws {
        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 16])
        try s.execute("actions.record")
        try s.execute("layer.new.layer", ["name": "One"])
        try s.execute("actions.stop")
        s.state[Key.self].list[0].steps.append(CommandInvocation("not.a.command"))
        try s.execute("file.new", ["width": 16, "height": 16])
        let r = try s.execute("actions.play", ["action": "Action 1"])
        #expect(r["ran"] == 1)
        #expect(r["failed"]?["step"] == 1)
        #expect(r["failed"]?["id"] == "not.a.command")
        #expect(r["failed"]?["error"]?.stringValue?.contains("unknown command") == true)
        #expect(s.active?.doc.layers.count == 2, "the step before the failure is kept")
        #expect(actions(s).playing == 0)
        // A later play still runs.
        #expect(try s.execute("actions.play", ["action": 0, "from": 1])["ran"] == 0)
    }

    @Test func playRefusesRecursion() throws {
        let s = Session()
        s.state[Key.self].list.append(Action("Loop", [CommandInvocation("actions.play", ["action": "Loop"])]))
        let r = try s.execute("actions.play", ["action": "Loop"])
        #expect(r["ran"] == 0)
        #expect(r["failed"]?["id"] == "actions.play")
        #expect(r["failed"]?["error"]?.stringValue?.contains("recursive action") == true, "\(r)")
        #expect(actions(s).playing == 0)
    }

    @Test func playChecksEachStepWithTheAuthorizeHook() throws {
        let s = Session()
        s.authorize = { id, _ in
            if id.hasPrefix("file.") { throw EngineError.other("automation command `\(id)` is disabled") }
        }
        s.state[Key.self].list.append(Action("Open", [CommandInvocation("file.open", ["path": "/etc/passwd"]), CommandInvocation("layer.new.layer")]))
        let r = try s.execute("actions.play", ["action": "Open"])
        #expect(r["ran"] == 0)
        #expect(r["failed"]?["step"] == 0)
        #expect(r["failed"]?["id"] == "file.open")
        #expect(r["failed"]?["error"]?.stringValue?.contains("disabled") == true, "\(r)")
        #expect(s.documents.isEmpty, "the refused step does not open a document")
    }

    @Test func appendDeleteAndFromStep() throws {
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 8, "background": "white"])
        #expect(try s.execute("actions.record", ["name": "Grow"])["index"] == 0)
        try s.execute("layer.new.layer", ["name": "One"])
        #expect(throws: (any Error).self, "already recording") { try s.execute("actions.record") }
        #expect(throws: (any Error).self, "delete while recording") { try s.execute("actions.delete", ["action": 0]) }
        #expect(try s.execute("actions.stop")["steps"] == 1)
        try s.execute("actions.record", ["action": "Grow"])
        try s.execute("layer.new.layer", ["name": "Two"])
        #expect(try s.execute("actions.stop")["steps"] == 2)
        #expect(throws: (any Error).self, "not recording") { try s.execute("actions.stop") }
        let before = try #require(s.active).doc.layers.count
        #expect(try s.execute("actions.play", ["action": "Grow", "from": 1])["ran"] == 1)
        #expect(s.active?.doc.layers.count == before + 1)
        #expect(try s.execute("actions.delete", ["action": "Grow"])["deleted"] == "Grow")
        #expect(actions(s).list.isEmpty)
        #expect(throws: (any Error).self) { try s.execute("actions.get", ["action": "Grow"]) }
    }

    @Test func deleteOneStepWhileRecordingKeepsJournalAndRemainingSteps() throws {
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 8])
        try s.execute("actions.record", ["name": "Edit"])
        try s.execute("layer.new.layer", ["name": "Kept"])
        try s.execute("layer.new.layer", ["name": "Removed"])
        let journal = s.journal
        let before = actions(s)
        for step: JSONValue in [-1, 2, 0.5, .null, "0", .number(1.8446744073709552e19)] {
            #expect(throws: (any Error).self) { try s.execute("actions.delete", ["action": 0, "step": step]) }
            #expect(actions(s) == before, "invalid deletion is atomic")
        }
        #expect(ActionsCommands.pendingSteps(s, 0).count == 2)
        #expect(try s.execute("actions.delete", ["action": 0, "step": 1])["steps"] == 1)
        #expect(s.journal == journal, "deleting a recording does not erase executed commands")
        #expect(s.active?.doc.layers.count == 3, "it does not undo document edits")
        #expect(actions(s).recording != nil)
        #expect(actions(s).rev > before.rev)
        try s.execute("layer.new.layer", ["name": "After"])
        try s.execute("actions.stop")
        #expect(actions(s).list[0].steps.map { $0.params["name"]?.stringValue ?? "" } == ["Kept", "After"])
        try s.execute("actions.delete", ["action": "Edit", "step": 0])
        #expect(actions(s).list[0].steps[0].params["name"] == "After")
        let saved = try JSONEncoder().encode(actions(s).list)
        s.state[Key.self].list = try JSONDecoder().decode([Action].self, from: saved)
        try s.execute("file.new", ["width": 8, "height": 8])
        #expect(try s.execute("actions.play", ["action": 0])["ran"] == 1)
        #expect(s.active?.doc.layers[1].name == "After")
        try s.execute("actions.delete", ["action": 0, "step": 0])
        #expect(actions(s).list.count == 1, "an empty action still exists")
        #expect(actions(s).list[0].steps.isEmpty)
    }

    @Test func nestedCallRecordsOneNamedStepAndTracksChildEdits() throws {
        let s = Session()
        try s.execute("file.new", ["width": 4, "height": 4])
        s.state[Key.self].list.append(Action("Child", [step("Child layer")]))
        try s.execute("actions.record", ["name": "Parent"])
        try s.execute("layer.new.layer", ["name": "Before"])
        try s.execute("actions.play", ["action": 0])
        #expect(ActionsCommands.pendingSteps(s, 1) == [CommandInvocation("actions.play", ["action": "Child"])])
        try s.execute("layer.new.layer", ["name": "After"])
        try s.execute("actions.stop")
        #expect(actions(s).list[1].steps.map(\.id) == ["layer.new.layer", "actions.play", "layer.new.layer"])
        s.state[Key.self].list[0].steps.append(step("Added later"))
        try s.execute("actions.move", ["action": "Child", "to": 1])
        let saved = try JSONEncoder().encode(actions(s).list)
        s.state[Key.self].list = try JSONDecoder().decode([Action].self, from: saved)
        try s.execute("file.new", ["width": 4, "height": 4])
        let result = try s.execute("actions.play", ["action": "Parent"])
        #expect(result["failed"] == nil, "\(result)")
        #expect(names(s) == ["Before", "Child layer", "Added later", "After"])
        #expect(actions(s).playbackStack.isEmpty)
    }

    @Test func nestedFailureCyclesDepthAndAuthorizationStopParent() throws {
        let s = Session()
        s.state[Key.self].list.append(Action("A", [CommandInvocation("actions.play", ["action": "B"]), CommandInvocation("file.new", ["width": 2, "height": 2])]))
        s.state[Key.self].list.append(Action("B", [CommandInvocation("actions.play", ["action": "A"])]))
        var r = try s.execute("actions.play", ["action": "A"])
        #expect(r["failed"]?["error"]?.stringValue?.contains("recursive") == true)
        #expect(s.documents.isEmpty)
        s.state[Key.self].list[1].steps = [CommandInvocation("file.new", ["width": 2, "height": 2])]
        s.authorize = { id, _ in if id == "file.new" { throw EngineError.other("denied nested file") } }
        r = try s.execute("actions.play", ["action": "A"])
        #expect(r["failed"]?["error"]?.stringValue?.contains("denied nested file") == true)
        #expect(s.documents.isEmpty)
        s.authorize = nil
        s.state[Key.self].list = (0..<17).map { i in
            Action("N\(i)", i < 16 ? [CommandInvocation("actions.play", ["action": .string("N\(i + 1)")])] : [])
        }
        r = try s.execute("actions.play", ["action": "N0"])
        #expect(r["failed"]?["error"]?.stringValue?.contains("16 levels") == true, "\(r)")
        #expect(actions(s).playing == 0)
        #expect(actions(s).playbackStack.isEmpty)
        s.state[Key.self].list[15].steps.removeAll()
        #expect(try s.execute("actions.play", ["action": "N0"])["failed"] == nil)
    }

    @Test func movePendingStepsIsAtomicPersistsAndChangesPlaybackOrder() throws {
        let s = Session()
        try s.execute("file.new", ["width": 4, "height": 4])
        try s.execute("actions.record", ["name": "Order"])
        for name in ["One", "Two", "Three"] { try s.execute("layer.new.layer", ["name": .string(name)]) }
        let before = actions(s)
        let bad: [JSONValue] = [
            ["action": 0, "step": 0, "to": 3], ["action": 0, "step": 99, "to": 0], ["action": 0, "step": 0.5, "to": 0],
            ["action": 0, "to": -1], ["action": 0, "to": .null],
        ]
        for p in bad {
            #expect(throws: (any Error).self, "\(p)") { try s.execute("actions.move", p) }
            #expect(actions(s) == before)
        }
        let journal = s.journal
        try s.execute("actions.move", ["action": 0, "step": 0, "to": 2])
        try s.execute("actions.move", ["action": 0, "step": 1, "to": 0])
        #expect(s.journal == journal)
        try s.execute("layer.new.layer", ["name": "Four"])
        try s.execute("actions.stop")
        #expect(actions(s).list[0].steps.map { $0.params["name"]?.stringValue ?? "" } == ["Three", "Two", "One", "Four"])
        try s.execute("file.new", ["width": 4, "height": 4])
        try s.execute("actions.play", ["action": 0])
        #expect(names(s) == ["Three", "Two", "One", "Four"])
    }

    @Test func newNamesDoNotCollideWithNamedCalls() throws {
        let s = Session()
        s.state[Key.self].list.append(Action("Action 2"))
        #expect(try s.execute("actions.record")["action"] == "Action 3")
        try s.execute("actions.stop")
        #expect(throws: (any Error).self) { try s.execute("actions.record", ["name": "Action 2"]) }
        #expect(actions(s).recording == nil)
    }

    @Test func movingActionKeepsRecordingAttachedToIt() throws {
        let s = Session()
        try s.execute("file.new", ["width": 4, "height": 4])
        for name in ["A", "B", "C"] { s.state[Key.self].list.append(Action(name)) }
        try s.execute("actions.record", ["action": "B"])
        try s.execute("layer.new.layer", ["name": "before"])
        try s.execute("actions.move", ["action": "B", "to": 2])
        try s.execute("actions.move", ["action": "A", "to": 2])
        try s.execute("layer.new.layer", ["name": "after"])
        try s.execute("actions.stop")
        #expect(actions(s).list[1].name == "B")
        #expect(actions(s).list[1].steps.count == 2)
    }

    @Test func badParamsDoNotTrap() throws {
        let s = Session()
        let junk: [JSONValue] = [
            .null, [], "x", 1, ["action": true], ["action": -1], ["action": 99], ["action": ""], ["name": 1], ["name": ""],
            ["from": "start"], ["from": -3], ["action": "missing", "from": 4],
        ]
        for id in ["actions.list", "actions.get", "actions.record", "actions.stop", "actions.play", "actions.delete", "actions.move"] {
            for p in junk { _ = try? s.execute(id, p) }
        }
        #expect(actions(s).playing == 0)
        let spec = try #require(s.registry.spec("actions.play"))
        #expect(!spec.journal && spec.menu.isEmpty)
    }

    // MARK: Beyond photocraft's tests (its `file.scripts.browse` and Straighten cases need
    // modules not ported yet): the same rules through commands registered here.

    /// A registry with two test commands: a replayable command that runs others on its own behalf
    /// (like Straighten), and one that also plays an action and then fails.
    func scriptSession() -> Session {
        var r = CommandRegistry.standard()
        r.add(CommandSpec("test.twoLayers", "Two Layers", module: "test") { s, _ in
            try s.execute("layer.new.layer", ["name": "One"])
            try s.execute("actions.play", ["action": "Child"])
            return .null
        })
        r.add(CommandSpec("test.failing", "Failing", module: "test") { s, _ in
            try s.execute("actions.play", ["action": "Child"])
            throw EngineError.other("refused")
        })
        return Session(registry: r)
    }

    @Test func recordCommandThatRunsCommandsReplaysItOnce() throws {
        let s = scriptSession()
        try s.execute("file.new", ["width": 8, "height": 8])
        s.state[Key.self].list.append(Action("Child", [step("Two")]))
        try s.execute("actions.record", ["name": "Outer"])
        try s.execute("test.twoLayers")
        #expect(try s.execute("actions.stop")["steps"] == 1)
        #expect(actions(s).list[1].steps.map(\.id) == ["test.twoLayers"], "the nested steps and the nested play are not recorded")
        try s.execute("file.new", ["width": 8, "height": 8])
        let r = try s.execute("actions.play", ["action": "Outer"])
        #expect(r["failed"] == nil && r["ran"] == 1, "\(r)")
        #expect(names(s) == ["One", "Two"], "played once, not its steps as well")
    }

    @Test func recordingResumesAfterAReplayableCommandFails() throws {
        let s = scriptSession()
        try s.execute("file.new", ["width": 8, "height": 8])
        s.state[Key.self].list.append(Action("Child", [step("Two")]))
        try s.execute("actions.record", ["name": "Outer"])
        try s.execute("layer.new.layer", ["name": "First"])
        #expect(throws: (any Error).self) { try s.execute("test.failing") }
        #expect(actions(s).recording?.index == 1, "the paused recording is back")
        try s.execute("layer.new.layer", ["name": "Last"])
        try s.execute("actions.stop")
        let recorded = actions(s).list[1].steps.map(\.id)
        #expect(recorded.first == "layer.new.layer" && recorded.last == "layer.new.layer", "\(recorded)")
        #expect(!recorded.contains("test.failing"))
        #expect(!recorded.contains("actions.play"), "the action played inside the failed command didn't flush or record itself")
    }
}
