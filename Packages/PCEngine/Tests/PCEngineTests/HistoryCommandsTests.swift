// Port of photocraft-engine (crates/engine/src/history_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

/// photocraft's `edit.fill` on the active layer (Edit › Fill isn't in this build's core): one
/// "Fill" step.
private func fill(_ s: Session, _ hex: String) throws {
    let c = try #require(Params.parseHex(hex))
    try s.edit("Fill") { doc, active in
        guard let id = active else { throw EngineError.other("no active layer") }
        let b = doc.bounds
        doc.withRaster(of: id) { $0.fill(b, with: $0.format.components(fromRGBA: c)) }
    }
}

/// A document with three steps after Open: entries Open, New Layer, Fill, Fill.
private func session() throws -> Session {
    let s = Session()
    try s.execute("file.new", ["width": 20, "height": 10])
    try s.execute("layer.new.layer")
    try fill(s, "#ff0000")
    try fill(s, "#00ff00")
    return s
}

private func entries(_ s: Session) -> [String] { s.active?.history.entries ?? [] }

/// The top layer's pixel at (1, 1).
private func topPixel(_ s: Session) -> SIMD4<Float>? { s.active?.doc.layers.last?.surface?.rgba(x: 1, y: 1) }

private func snapshots(_ s: Session) -> JSONValue {
    guard let d = s.active else { return .null }
    return Inspect.document(d)["snapshots"] ?? .null
}

@Suite struct HistoryCommandsTests {
    @Test func historyUndoAndRedoAliasEditUndoAndRedo() throws {
        let s = try session()
        let n = try #require(s.active).history.pastCount
        #expect(try s.execute("history.undo") == true)
        #expect(s.active?.history.pastCount == n - 1, "history.undo steps back like edit.undo")
        #expect(try s.execute("history.redo") == true)
        #expect(s.active?.history.pastCount == n, "history.redo steps forward like edit.redo")
        #expect(!Session().isEnabled("history.undo"))
    }

    @Test func deleteCurrentStateStepsBackAndDropsIt() throws {
        let s = try session()
        let before = entries(s)
        #expect(before == ["Open", "New Layer", "Fill", "Fill"])
        let prev = try #require(s.active?.history.state(before.count - 2))
        let r = try s.execute("history.deleteState")
        #expect(r["states"] == .int(before.count - 1))
        #expect(r["current"] == "Fill")
        #expect(entries(s) == Array(before.dropLast()))
        #expect(s.active?.doc == prev, "the document is the state before")
        #expect(s.active?.history.canRedo == false, "the deleted state can't be redone")
        #expect(throws: EngineError.self) { try s.execute("edit.redo") }
    }

    @Test func deleteAnEarlierStateDropsItAndEveryLaterOne() throws {
        var s = try session()
        let first = try #require(s.active?.history.state(0))
        try s.execute("history.deleteState", ["state": 1])
        #expect(entries(s) == ["Open"])
        #expect(s.active?.doc == first)
        #expect(s.active?.history.canRedo == false)
        // Redo states after an undo go too.
        s = try session()
        try s.execute("edit.undo")
        try s.execute("history.deleteState")
        #expect(entries(s).count == 2)
        #expect(s.active?.history.canRedo == false)
    }

    @Test func deleteStateRefusesTheOldestStateAndBadParams() throws {
        var s = Session()
        #expect(throws: EngineError.self, "no document") { try s.execute("history.deleteState") }
        try s.execute("file.new", ["width": 8, "height": 8])
        #expect(!s.isEnabled("history.deleteState"), "only the opening state")
        #expect(throws: EngineError.self) { try s.execute("history.deleteState") }
        s = try session()
        let before = entries(s)
        let bads: [JSONValue] = [["state": 0], ["state": -1], ["state": 99], ["state": "x"], ["state": .number(.greatestFiniteMagnitude)], ["state": [1]]]
        for p in bads {
            #expect(throws: EngineError.self, "\(p)") { try s.execute("history.deleteState", p) }
            #expect(entries(s) == before, "\(p) changed nothing")
        }
    }

    @Test func newDocumentFromAStateCopiesItIntoAFreshDocument() throws {
        let s = try session()
        let src = try #require(s.active).doc
        let label = try #require(entries(s).last)
        let r = try s.execute("history.newDocument")
        #expect(s.documents.count == 2)
        #expect(r["document"] == 1)
        #expect(r["name"] == .string(label), "named after the state")
        let new = try #require(s.active)
        #expect(new.doc.size == src.size)
        #expect(new.doc.layers.count == src.layers.count)
        #expect(new.doc.id != src.id)
        #expect(Set(new.doc.allLayerIds).isDisjoint(with: src.allLayerIds), "the copy's layers have their own ids")
        #expect(new.history.entries.count == 1, "a fresh history")
        // An earlier state, with a chosen name; the source document is untouched.
        _ = s.setActive(0)
        let before = entries(s)
        let open = try #require(s.active?.history.state(0))
        try s.execute("history.newDocument", ["state": 0, "name": "Start"])
        let start = try #require(s.active)
        #expect(start.doc.name == "Start")
        #expect(start.doc.layers.count == open.layers.count)
        _ = s.setActive(0)
        #expect(entries(s) == before)
    }

    @Test func newSnapshotKeepsTheDocumentAndIsNotAHistoryState() throws {
        let s = try session()
        let before = entries(s)
        #expect(try s.execute("history.newSnapshot") == ["snapshot": 1, "name": "Snapshot 1"])
        #expect(entries(s) == before, "taking a snapshot is not a step")
        #expect(try s.execute("history.newSnapshot", ["name": "Before green"]) == ["snapshot": 2, "name": "Before green"])
        #expect(snapshots(s) == [["id": 1, "name": "Snapshot 1"], ["id": 2, "name": "Before green"]])
    }

    @Test func selectSnapshotReturnsToItAsOneUndoableState() throws {
        let s = try session()
        try s.execute("history.newSnapshot")
        let green = topPixel(s)
        let id = try #require(s.active).doc.id
        try fill(s, "#0000ff")
        let blue = topPixel(s)
        let before = entries(s)
        try s.execute("history.selectSnapshot", ["snapshot": 1])
        #expect(topPixel(s) == green)
        #expect(entries(s).count == before.count + 1, "one new state")
        #expect(entries(s).last == "Snapshot 1")
        #expect(s.active?.doc.id == id, "the same document")
        #expect(s.active?.activeLayer != nil)
        try s.execute("edit.undo")
        #expect(topPixel(s) == blue, "undo leaves the snapshot")
        #expect(snapshots(s).arrayValue?.count == 1, "snapshots are not history")
    }

    @Test func snapshotsFromMergedLayersOrTheCurrentLayer() throws {
        let s = try session()
        #expect(s.active?.doc.layers.count == 2)
        try s.execute("history.newSnapshot", ["from": "mergedLayers"])
        try s.execute("history.newSnapshot", ["from": "currentLayer"])
        try s.execute("history.newSnapshot", ["from": "fullDocument"])
        try s.execute("history.selectSnapshot", ["snapshot": 1])
        let doc = try #require(s.active).doc
        #expect(doc.layers.count == 1, "merged into one layer")
        #expect(doc.layers.first?.surface?.rgba(x: 1, y: 1) == SIMD4(0, 1, 0, 1), "the visible result")
        try s.execute("history.selectSnapshot", ["snapshot": 2])
        #expect(s.active?.doc.layers.count == 1, "only the active layer")
        try s.execute("history.selectSnapshot", ["snapshot": 3])
        #expect(s.active?.doc.layers.count == 2)
    }

    @Test func renameAndDeleteSnapshotsKeepTheOtherIds() throws {
        let s = try session()
        for _ in 0..<3 { try s.execute("history.newSnapshot") }
        try s.execute("history.renameSnapshot", ["snapshot": 2, "name": "Lesson start"])
        #expect(try s.execute("history.deleteSnapshot", ["snapshot": 1]) == ["snapshot": 1, "snapshots": 2])
        #expect(snapshots(s) == [["id": 2, "name": "Lesson start"], ["id": 3, "name": "Snapshot 3"]])
        #expect(try s.execute("history.newSnapshot")["snapshot"] == 4, "ids are never reused")
    }

    @Test func snapshotCommandsRefuseBadParams() throws {
        var s = Session()
        let noDoc: [(String, JSONValue)] = [
            ("history.newSnapshot", .object([:])), ("history.selectSnapshot", ["snapshot": 1]),
            ("history.renameSnapshot", ["snapshot": 1, "name": "x"]), ("history.deleteSnapshot", ["snapshot": 1]),
        ]
        for (cmd, p) in noDoc { #expect(throws: EngineError.self, "\(cmd): no document") { try s.execute(cmd, p) } }
        s = try session()
        try s.execute("history.newSnapshot")
        let (before, snaps) = (entries(s), snapshots(s))
        let bads: [(String, JSONValue)] = [
            ("history.newSnapshot", ["from": "everything"]), ("history.newSnapshot", ["from": 3]), ("history.newSnapshot", ["name": 7]),
            ("history.selectSnapshot", .object([:])), ("history.selectSnapshot", ["snapshot": 99]), ("history.selectSnapshot", ["snapshot": -1]),
            ("history.selectSnapshot", ["snapshot": "1"]), ("history.selectSnapshot", ["snapshot": .number(.greatestFiniteMagnitude)]),
            ("history.renameSnapshot", ["snapshot": 1]), ("history.renameSnapshot", ["snapshot": 1, "name": "  "]),
            ("history.renameSnapshot", ["snapshot": 99, "name": "x"]), ("history.deleteSnapshot", ["snapshot": 99]),
            ("history.deleteSnapshot", ["snapshot": [1]]),
        ]
        for (cmd, p) in bads {
            #expect(throws: EngineError.self, "\(cmd) \(p)") { try s.execute(cmd, p) }
            #expect(entries(s) == before && snapshots(s) == snaps, "\(cmd) \(p) changed nothing")
        }
        // Current Layer needs an active layer.
        try s.execute("select.deselectLayers")
        #expect(throws: EngineError.self) { try s.execute("history.newSnapshot", ["from": "currentLayer"]) }
    }

    @Test func newDocumentRefusesBadParams() throws {
        var s = Session()
        #expect(throws: EngineError.self, "no document") { try s.execute("history.newDocument") }
        s = try session()
        for p: JSONValue in [["state": -1], ["state": 99], ["state": "x"], ["state": "NaN"]] {
            #expect(throws: EngineError.self, "\(p)") { try s.execute("history.newDocument", p) }
        }
        #expect(s.documents.count == 1)
    }
}
