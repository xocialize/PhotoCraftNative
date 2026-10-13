// Port of photocraft-engine (crates/engine/src/type_spell_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The dictionary is macOS's (NSSpellChecker, "en"); photocraft's expectations hold with it
// ("Teh" → "The" first, "Photocraft" unknown). The user dictionary lives in the preferences.

import Foundation
@testable import PCEngine
import PCDocument
import Testing

@Suite struct TypeSpellTests {
    func session(_ text: String) throws -> (Session, UInt64) {
        let s = Session()
        try s.execute("file.new", ["width": 300, "height": 100, "background": "white"])
        let r = try s.execute("type.create", ["x": 10, "y": 50, "text": .string(text), "size": 12])
        return (s, try #require(r["layer"]?.uint64Value))
    }

    func textOf(_ s: Session, _ id: UInt64) -> String? { s.active.flatMap { TypeCommands.textOf($0.doc, LayerId(id))?.text } }

    @Test func listsChangesAndLearnsWords() throws {
        let (s, id) = try session("Teh quick brwon fox, teh end. Photocraft")
        let lid: JSONValue = .number(Double(id))
        var r = try s.execute("edit.checkSpelling", [:])
        let words = r["misspellings"]?.arrayValue?.compactMap { $0["word"]?.stringValue }
        #expect(words == ["Teh", "brwon", "teh", "Photocraft"])
        let first = r["misspellings"]?[0]
        #expect(first?["start"] == 0 && first?["end"] == 3)
        #expect(first?["suggestions"]?[0] == "The")
        // Change one occurrence (verified), then all of another.
        try s.execute("edit.checkSpelling", ["action": "change", "layer": lid, "start": 0, "end": 3, "word": "Teh", "replace": "The"])
        #expect(throws: EngineError.self) {
            try s.execute("edit.checkSpelling", ["action": "change", "layer": lid, "start": 0, "end": 3, "word": "Teh", "replace": "X"])
        }
        r = try s.execute("edit.checkSpelling", ["action": "changeAll", "word": "brwon", "replace": "brown"])
        #expect(r["changed"] == 1)
        #expect(textOf(s, id) == "The quick brown fox, teh end. Photocraft")
        // One undo step per change.
        try s.execute("edit.undo", [:])
        #expect(textOf(s, id)?.contains("brwon") == true)
        try s.execute("edit.redo", [:])
        // Ignore All and Add to Dictionary.
        r = try s.execute("edit.checkSpelling", ["ignore": ["teh"]])
        #expect(r["count"] == 1)
        try s.execute("edit.checkSpelling", ["action": "addToDictionary", "word": "Photocraft"])
        #expect(TypeSpellCommands.userDictionary(s) == ["Photocraft"])
        r = try s.execute("edit.checkSpelling", [:])
        #expect(r["count"] == 1)
        try s.execute("edit.checkSpelling", ["action": "removeFromDictionary", "word": "photocraft"])
        #expect(TypeSpellCommands.userDictionary(s).isEmpty)
        #expect(throws: EngineError.self) { try s.execute("edit.checkSpelling", ["action": "bogus"]) }
        r = try s.execute("edit.checkSpelling", ["action": "suggest", "word": "recieve"])
        #expect(r["correct"] == false)
    }

    @Test func disabledWithoutType() throws {
        let s = Session()
        #expect(!s.isEnabled("edit.checkSpelling"))
        try s.execute("file.new", ["width": 10, "height": 10])
        #expect(!s.isEnabled("edit.checkSpelling"))
        #expect(!s.isEnabled("type.insertText"))
    }

    @Test func insertGlyphAtCaretAndOverRange() throws {
        let (s, id) = try session("ab")
        let lid: JSONValue = .number(Double(id))
        try s.execute("type.insertText", ["layer": lid, "text": "→", "at": 1])
        #expect(textOf(s, id) == "a→b")
        let r = try s.execute("type.insertText", ["layer": lid, "text": "€", "range": [0, 2]])
        #expect(textOf(s, id) == "€b" && r["caret"] == 1)
        try s.execute("type.insertText", ["text": "!"])
        #expect(textOf(s, id) == "€b!")
        #expect(throws: EngineError.self) { try s.execute("type.insertText", ["text": ""]) }
    }

    @Test func insertCRLFReportsCaretInNormalizedText() throws {
        let (s, id) = try session("")
        let lid: JSONValue = .number(Double(id))
        let inserted = try s.execute("type.insertText", ["layer": lid, "text": "x\r\ny"])
        #expect(inserted["caret"] == 3)
        #expect(try s.execute("type.info", ["layer": lid])["text"] == "x\ny")
        #expect(try s.execute("type.caret", ["layer": lid, "index": inserted["caret"] ?? .null])["index"] == inserted["caret"])
    }

    @Test func wordsSplitLikePhotocraft() {
        let t = "don't stop-me 3rd ’tis"
        let w = TypeSpellCommands.words(t).map { TypeCommands.slice(t, $0.0, $0.1) }
        #expect(w == ["don't", "stop", "me", "3rd", "tis"])
    }
}
