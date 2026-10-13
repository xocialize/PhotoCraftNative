// Port of photocraft-engine (crates/engine/src/document_preset_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft reloads presets through its preferences JSON (`load_prefs_json`); here a reload goes
// through `DocumentPresetCommands.value` / `restore`, the same `presets` collections. Unrelated
// preferences in `old_preferences_and_malformed_presets_keep_unrelated_settings` aren't part of
// this module and are left out. `invalid_explicit_background_colour_does_not_create_a_document`
// checks `validateNewParams` directly (the core's `file.new` still uses `CoreCommands.validateNew`).

import Foundation
import PCDocument
@testable import PCEngine
import PCFormat
import PCFoundation
import Testing

@Suite struct DocumentPresetTests {
    typealias D = DocumentPresetCommands

    func settings() -> JSONValue {
        ["width": 16, "height": 24, "resolution": 254.5, "mode": "lab", "depth": 16, "background": "backgroundColor",
         "backgroundColor": [0.125, 0.375, 0.625], "unit": "mm", "resolutionUnit": "cm"]
    }

    @discardableResult
    func saved(_ s: Session, _ name: String, _ settings: JSONValue) throws -> JSONValue {
        try #require(try s.execute("document.presets.save", ["name": .string(name), "settings": settings])["preset"])
    }

    func reload(_ s: Session) -> Session {
        let next = Session()
        D.restore(next, from: D.value(s))
        return next
    }

    func rev(_ s: Session) -> UInt64 { s.state[D.Key.self].revision }

    @Test func everyFieldSurvivesSaveReloadAndFileNew() throws {
        for mode in ["rgb", "gray", "cmyk", "lab"] {
            for depth in [8, 16, 32] {
                let s = Session()
                let config = settings().setting("mode", .string(mode)).setting("depth", .int(depth))
                let preset = try saved(s, "  Product square  ", config)
                #expect(preset["name"] == "Product square")
                #expect(preset["settings"] == config)
                let next = reload(s)
                #expect(next.state[D.Key.self].documents == s.state[D.Key.self].documents)
                let r = rev(next)
                let selected = try next.execute("document.presets.get", ["name": "product SQUARE"])
                #expect(selected["preset"] == preset)
                #expect(next.documents.isEmpty, "save/get do not create a document")
                #expect(rev(next) == r, "queries do not dirty preferences")
                let params = try #require(selected["params"])
                #expect(params["name"] == nil)
                try next.execute("file.new", params.setting("name", "Actual document"))
                let doc = next.active!.doc
                #expect(doc.size == PixelSize(width: 16, height: 24) && doc.resolutionDpi == 254.5)
                #expect(doc.name == "Actual document")
                #expect(doc.mode == D.colorMode(mode))
                #expect(doc.depth == CoreCommands.sampleType(depth))
            }
        }
    }

    @Test func backgroundChoiceAndCapturedColourAreIndependentOfTheToolbox() throws {
        let cases: [(String, [Double])] = [
            ("white", [1, 1, 1, 1]), ("black", [0, 0, 0, 1]), ("transparent", [0, 0, 0, 0]), ("#ff0000", [1, 0, 0, 1]),
            ("backgroundColor", [0.125, 0.375, 0.625, 1]),
        ]
        for (background, expected) in cases {
            let s0 = Session()
            s0.tools.background = SIMD4(0.125, 0.375, 0.625, 1)
            try saved(s0, "Background", ["width": 4, "height": 4, "background": .string(background), "depth": 32])
            let s = reload(s0)
            s.tools.background = SIMD4(1, 0, 1, 1)
            let p = try s.execute("document.presets.get", ["name": "Background"])
            #expect(p["preset"]?["settings"]?["background"] == .string(background))
            try s.execute("file.new", try #require(p["params"]))
            let pixel = try #require(try s.execute("document.pixel", ["x": 0, "y": 0]).arrayValue)
            for (actual, e) in zip(pixel, expected) {
                #expect(abs((actual.doubleValue ?? -1) - e) < 0.001, "\(background): \(pixel)")
            }
        }
    }

    @Test func deletionMarksPreferencesDirtyAndSurvivesReload() throws {
        let s0 = Session()
        try saved(s0, "Delete me", settings())
        try saved(s0, "Keep me", settings())
        let s1 = reload(s0)
        let r = rev(s1)
        try s1.execute("document.presets.delete", ["name": " delete ME "])
        #expect(rev(s1) > r)
        let s = reload(s1)
        #expect(try s.execute("document.presets.list", .object([:]))["presets"]?.arrayValue?.count == 1)
        #expect(s.state[D.Key.self].documents.first?.name == "Keep me")
        #expect(throws: EngineError.self) { try s.execute("document.presets.get", ["name": "Delete me"]) }
        #expect(throws: EngineError.self) { try s.execute("document.presets.delete", ["name": "Delete me"]) }
    }

    @Test func malformedPresetsAreDroppedEntryByEntry() throws {
        let original = Session()
        let valid = try saved(original, "Keep me", settings())
        for invalid: JSONValue in ["bad collection", [false, [:], ["name": "broken", "settings": [:]]]] {
            let s = Session()
            D.restore(s, from: D.value(original).setting("documents", invalid))
            #expect(s.state[D.Key.self].documents.isEmpty)
        }
        let bad = valid.setting("settings", (valid["settings"] ?? .null).setting("width", 0))
        let s = Session()
        D.restore(s, from: D.value(original).setting("documents", [bad, valid, valid]))
        #expect(s.state[D.Key.self].documents.count == 1, "keep valid entries, discard bad/duplicate entries")
        #expect(s.state[D.Key.self].documents.first?.name == "Keep me")
        let old = Session()
        D.restore(old, from: D.value(original).removing("documents"))
        #expect(old.state[D.Key.self].documents.isEmpty)
    }

    @Test func badInputAndDuplicateNamesNeverReplaceOrMutateASnapshot() throws {
        let s = Session()
        try saved(s, "Keep me", settings())
        let config = settings().setting("width", 99)
        #expect(s.state[D.Key.self].documents[0].settings.width == 16)
        let before = D.value(s)
        let r = rev(s)
        for name in ["", " \t\n ", "Keep me", " keep ME ", String(repeating: "x", count: 256)] {
            #expect(throws: EngineError.self) { try s.execute("document.presets.save", ["name": .string(name), "settings": config]) }
        }
        let bads: [(String, JSONValue)] = [
            ("width", 0), ("height", -1), ("width", 300_001), ("width", "wrong"), ("resolution", 0), ("resolution", 30_001),
            ("resolution", .null), ("mode", "indexed"), ("depth", 64), ("depth", "16"), ("background", "invalid"),
            ("backgroundColor", [1, 0]), ("backgroundColor", [2, 0, 0]), ("unit", "yards"), ("resolutionUnit", "px"),
        ]
        for (key, bad) in bads {
            #expect(throws: EngineError.self, "\(key)") {
                try s.execute("document.presets.save", ["name": "Bad", "settings": settings().setting(key, bad)])
            }
        }
        for p: JSONValue in [[:], .null, ["name": 12], ["name": "Bad", "settings": []]] {
            #expect(throws: EngineError.self) { try s.execute("document.presets.save", p) }
        }
        #expect(D.value(s) == before)
        #expect(rev(s) == r)
    }

    @Test func recentListsCreatedSettingsNewestFirstCappedAndSurvivesReload() throws {
        let s0 = Session()
        func add(_ s: Session, _ w: Int, _ unit: String) throws {
            try s.execute("document.recent.add", ["settings": ["width": .int(w), "height": 10, "unit": .string(unit)]])
        }
        for w in 1...(D.maxRecent + 5) { try add(s0, w, "px") }
        // The same document again (shown in other units) moves to the front instead of repeating.
        try add(s0, 10, "mm")
        let s = reload(s0)
        let recent = try #require(try s.execute("document.recent.list", .object([:]))["recent"]?.arrayValue)
        let widths = recent.compactMap { $0["width"]?.uint64Value }
        #expect(widths.count == D.maxRecent)
        #expect(Array(widths.prefix(3)) == [10, 25, 24])
        #expect(widths.filter { $0 == 10 }.count == 1)
        #expect(recent[0]["unit"] == "mm")
        // Bad settings change nothing; damaged stored entries are dropped, the rest kept.
        let r = rev(s)
        for bad: JSONValue in [[:], ["settings": ["width": 0, "height": 1]], ["settings": "x"], .null] {
            #expect(throws: EngineError.self) { try s.execute("document.recent.add", bad) }
        }
        #expect(rev(s) == r)
        let next = Session()
        D.restore(next, from: D.value(s).setting("recent_documents", [["width": -1], recent[1], "junk", recent[1], recent[2]]))
        #expect(next.state[D.Key.self].recent.map(\.width) == [25, 24])
        #expect(next.documents.isEmpty, "recording never creates a document")
    }

    @Test func invalidExplicitBackgroundColourIsRefusedByValidateNewParams() throws {
        let s = Session()
        for color: JSONValue in [.null, [1, 2], [1, -1, 0], "red"] {
            #expect(throws: EngineError.self) {
                try D.validateNewParams(s, ["background": "backgroundColor", "backgroundColor": color])
            }
        }
        #expect(throws: EngineError.self) { try D.validateNewParams(s, ["bogus": 1]) }
        try D.validateNewParams(s, ["width": 16, "height": 24, "resolution": 254.5, "mode": "lab", "depth": 16, "background": "#ff0000", "name": "x"])
        try D.validateNewParams(s, .null)
    }

    /// What `file.new` can create, `.pcraft` can reopen: the loader's default canvas budget
    /// covers the largest new document (#2935), and such a document round-trips.
    @Test func theLargestNewDocumentReopensFromPcraft() throws {
        let s = Session()
        let m = CoreCommands.maxDimension
        try s.execute("file.new", ["width": .int(m), "height": .int(m), "background": "transparent"])
        let doc = try #require(s.active?.doc)
        let back = try PcraftFormat.load(try PcraftFormat.save(doc))
        #expect(back.size == PixelSize(width: m, height: m))
    }
}
