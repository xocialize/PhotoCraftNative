// Port of photocraft-engine (crates/engine/src/notes_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// `import_notes_from_pcraft_and_psd` is ported for `.pcraft` and for a PSD written by PCIO (the
// photocraft corpus sample is not available); `importedNotesArePulledInsideTheCanvas` (not a
// photocraft test) checks the placement with an in-memory source document.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct NotesTests {
    func session() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 100, "height": 80])
        return s
    }

    @Test func addEditMoveDeleteWithUndo() throws {
        let s = try session()
        #expect(!s.isEnabled("notes.delete"))
        let r = try s.execute("notes.add", ["x": 10, "y": 12, "text": "fix this", "author": "QA", "color": "#ff0000"])
        #expect(r["index"] == 0)
        #expect(r["note"]?["color"] == [1.0, 0.0, 0.0])
        try s.execute("notes.add", ["x": 50, "y": 40])
        try s.execute("notes.set", ["index": 0, "text": "fixed", "x": 20])
        let d = s.active!.doc
        #expect(d.notes[0].text == "fixed")
        #expect(d.notes[0].position == SIMD2(20, 12))
        #expect(d.notes[0].popup.x == 40)
        #expect(d.notes[0].modified.hasPrefix("D:") && d.notes[0].modified.count == 17)
        // Unchanged edits don't add history.
        let before = s.active!.history.pastCount
        #expect(try s.execute("notes.set", ["index": 0, "text": "fixed"])["changed"] == false)
        #expect(s.active!.history.pastCount == before)
        try s.execute("notes.delete", ["index": 1])
        #expect(try s.execute("notes.list", .object([:]))["notes"]?.arrayValue?.count == 1)
        #expect(s.undo())
        #expect(s.active!.doc.notes.count == 2)
        try s.execute("notes.delete", ["all": true])
        #expect(s.active!.doc.notes.isEmpty)
        #expect(throws: EngineError.self) { try s.execute("notes.set", ["index": 0]) }
    }

    @Test func badParams() throws {
        let s = try session()
        #expect(throws: EngineError.self) { try s.execute("notes.add", ["x": 1]) }
        try s.execute("notes.add", ["x": 1, "y": 1])
        #expect(throws: EngineError.self) { try s.execute("notes.set", ["index": 5, "text": "x"]) }
        #expect(throws: EngineError.self) { try s.execute("notes.set", .object([:])) }
        #expect(throws: EngineError.self) { try s.execute("file.import.notes", .object([:])) }
        #expect(throws: EngineError.self) { try s.execute("file.import.notes", ["path": "/nonexistent/x.psd"]) }
    }

    @Test func importedNotesArePulledInsideTheCanvas() throws {
        let s = try session()
        var src = Document(name: "src", size: PixelSize(width: 400, height: 400), mode: .rgb, depth: .u8)
        src.notes.append(Note(text: "from pcraft", position: SIMD2(300, 300)))
        let r = try NotesCommands.importNotes(s, name: "a.pcraft", from: src)
        #expect(r["imported"] == 1)
        // Pulled inside the 100×80 canvas.
        let n = s.active!.doc.notes[0]
        #expect(n.text == "from pcraft")
        #expect(n.position.x <= 84 && n.position.y <= 60)
        // A document without notes is an error.
        src.notes.removeAll()
        #expect(throws: EngineError.self) { try NotesCommands.importNotes(s, name: "b.pcraft", from: src) }
    }
    @Test func importNotesFromPcraftAndPsd() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = Session()
        try src.execute("file.new", ["width": 400, "height": 400])
        try src.execute("notes.add", ["x": 300, "y": 300, "text": "from pcraft"])
        let pc = dir.appendingPathComponent("a.pcraft").path
        try src.saveDocument(to: pc)
        let s = try session()
        let r = try s.execute("file.import.notes", ["path": .string(pc)])
        #expect(r["imported"] == 1)
        // Pulled inside the 100×80 canvas.
        let n = try #require(s.active?.doc.notes.first)
        #expect(n.text == "from pcraft")
        #expect(n.position.x <= 84 && n.position.y <= 60)
        // A PSD with notes (the PSD `Anno` block) appends more.
        try src.execute("notes.add", ["x": 10, "y": 10, "text": "second"])
        let psd = dir.appendingPathComponent("b.psd")
        try src.saveDocument(to: psd.path)
        dropForOracle(psd, as: "notes-import.psd")
        try s.execute("file.import.notes", ["path": .string(psd.path)])
        #expect(s.active?.doc.notes.count == 3)
        // A file without notes is an error.
        try src.execute("notes.delete", ["all": true])
        let empty = dir.appendingPathComponent("c.pcraft").path
        try src.saveDocument(to: empty)
        #expect(throws: (any Error).self) { try s.execute("file.import.notes", ["path": .string(empty)]) }
    }
}
