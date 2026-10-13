// Port of photocraft-engine (crates/engine/src/type_spell_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Edit › Check Spelling… and glyph insertion (Window › Glyphs).
//
// `edit.checkSpelling` checks type layers against an English dictionary plus the user dictionary
// in the preferences (`userDictionary`). Headless, it lists misspellings with suggestions and
// changes, changes all, or adds words to the dictionary; the UI's dialog drives the same actions.
// Offsets are character indices. photocraft bundles SCOWL size 50 and its own suggester; here the
// dictionary is macOS's (`NSSpellChecker`, language "en", used headlessly and serialised), with
// photocraft's tokeniser and pre-checks (digits skipped, possessive 's, typographic apostrophes).
// The user dictionary is kept here, never taught to the system (`learnWord` is not called), so
// words the user taught macOS elsewhere also count as correct.
//
// `type.insertText` inserts a string (a glyph) into a type layer at a character position or over
// a range.

#if canImport(AppKit)
import AppKit
#endif
import Foundation
import PCDocument

enum TypeSpellCommands: CommandModule {
    static let name = "type_spell_cmds"
    static let m = name
    typealias T = TypeCommands

    // MARK: Dictionary

    /// macOS's spelling dictionary (photocraft-text `spell::Dictionary`).
    enum Dictionary {
        static let lock = NSLock()

        static var isAvailable: Bool {
            #if canImport(AppKit)
            return true
            #else
            return false
            #endif
        }

        /// Typographic apostrophes → `'`.
        static func normalize(_ w: String) -> String {
            w.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{02BC}", with: "'")
        }

        /// Whether `word` is spelled correctly (also accepting `user` words, compared without case).
        static func check(_ word: String, _ user: Set<String>) -> Bool {
            var w = normalize(word)
            if w.hasSuffix("'s") && w.count > 2 { w.removeLast(2) }
            w = w.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if w.isEmpty || w.unicodeScalars.contains(where: { $0.properties.numericType != nil }) || !w.unicodeScalars.contains(where: \.properties.isAlphabetic) {
                return true
            }
            if user.contains(w.lowercased()) { return true }
            #if canImport(AppKit)
            return lock.withLock {
                NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
            }
            #else
            return true
            #endif
        }

        /// Up to `max` suggestions for a misspelled word, nearest first.
        static func suggest(_ word: String, _ max: Int) -> [String] {
            let w = normalize(word)
            guard max > 0, !w.isEmpty else { return [] }
            #if canImport(AppKit)
            let guesses = lock.withLock {
                NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: (w as NSString).length), in: w, language: "en",
                                              inSpellDocumentWithTag: 0) ?? []
            }
            var out: [String] = []
            for g in guesses where g != w && !out.contains(g) { out.append(g) }
            return Array(out.prefix(max))
            #else
            return []
            #endif
        }

        /// Misspelled words of `text` in order (byte ranges).
        static func misspellings(_ text: String, _ user: Set<String>) -> [(Int, Int, String)] {
            words(text).compactMap { a, b in
                let w = T.slice(text, a, b)
                return check(w, user) ? nil : (a, b, w)
            }
        }
    }

    /// Byte ranges of the words in `text`: letters/digits with inner apostrophes (hyphens split)
    /// (photocraft-text `spell::words`).
    static func words(_ text: String) -> [(Int, Int)] {
        func isApos(_ c: Unicode.Scalar) -> Bool { c == "'" || c == "\u{2019}" || c == "\u{02BC}" }
        func alnum(_ c: Unicode.Scalar) -> Bool { c.properties.isAlphabetic || c.properties.numericType != nil }
        var out: [(Int, Int)] = []
        var start: Int?
        let chars = Array(text.unicodeScalars)
        var b = 0
        for (i, c) in chars.enumerated() {
            let innerApos = isApos(c) && start != nil && i + 1 < chars.count && chars[i + 1].properties.isAlphabetic
            if alnum(c) || innerApos {
                if start == nil { start = b }
            } else if let s = start {
                out.append((s, b))
                start = nil
            }
            b += UTF8.width(c)
        }
        if let s = start { out.append((s, b)) }
        return out
    }

    // MARK: Helpers

    /// Type layers top to bottom (Layers panel order), skipping fully locked ones.
    static func typeLayers(_ doc: Document) -> [LayerId] {
        doc.walk().reversed().filter { T.isText($0.layer) && !doc.locks(at: $0.path).all }.map(\.layer.id)
    }

    static let hasType: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return typeLayers(d.doc).isEmpty ? "the document has no type layers" : nil
    }

    static let hasTextLayer: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        if let id = d.activeLayer, T.textOf(d.doc, id) != nil { return nil }
        return "the active layer is not a type layer"
    }

    static func text(_ doc: Document, _ id: LayerId) -> String? { T.textOf(doc, id)?.text }

    /// The user dictionary (preferences `userDictionary`, photocraft `Preferences::user_dictionary`).
    static func userDictionary(_ s: Session) -> [String] {
        s.preferences["userDictionary"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// Edits the user dictionary (photocraft `Session::edit_prefs`); returns `f`'s result.
    static func editUserDictionary(_ s: Session, _ f: (inout [String]) -> Bool) -> Bool {
        var words = userDictionary(s)
        let r = f(&words)
        s.preferences = Preferences(values: s.preferences.values.setting("userDictionary", .strings(words)))
        return r
    }

    /// The user dictionary plus `ignore` words, lowercased.
    static func accepted(_ s: Session, _ p: JSONValue) -> Set<String> {
        var set = Set(userDictionary(s).map { $0.lowercased() })
        for w in p["ignore"]?.arrayValue?.compactMap(\.stringValue) ?? [] { set.insert(w.lowercased()) }
        return set
    }

    static func layersParam(_ s: Session, _ p: JSONValue) -> [LayerId] {
        guard let st = s.active else { return [] }
        let all = typeLayers(st.doc)
        if p["allLayers"]?.boolValue == false || p["layer"] != nil {
            let active = try? s.layerParam(p)
            return all.filter { $0 == active }
        }
        return all
    }

    /// Rust's `{:?}` of a string.
    static func debugQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    // MARK: Check Spelling

    static func list(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let st = s.active else { throw EngineError.noDocument }
        let ok = accepted(s, p)
        let max = T.index(p["suggestions"]) ?? 5
        var out: [JSONValue] = []
        for id in layersParam(s, p) {
            guard let t = text(st.doc, id) else { continue }
            for (a, b, w) in Dictionary.misspellings(t, ok) {
                out.append(["layer": .id(id), "start": .int(T.charAt(t, a)), "end": .int(T.charAt(t, b)), "word": .string(w),
                            "suggestions": .strings(Dictionary.suggest(w, max))])
            }
        }
        return ["misspellings": .array(out), "count": .int(out.count)]
    }

    /// Replaces one occurrence (verified to still be `word` when given).
    static func change(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "edit.checkSpelling"
        guard let lid = p["layer"]?.uint64Value else { throw EngineError.bad(cmd, "`change` needs `layer`") }
        let id = LayerId(lid)
        guard let start = T.index(p["start"]) else { throw EngineError.bad(cmd, "`change` needs `start`") }
        guard let end = T.index(p["end"]) else { throw EngineError.bad(cmd, "`change` needs `end`") }
        guard let to = p["replace"]?.stringValue else { throw EngineError.bad(cmd, "`change` needs `replace`") }
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        guard let t = text(doc, id) else { throw EngineError.bad(cmd, "layer \(id.rawValue) is not a type layer") }
        let (a, b) = (T.byteAt(t, start), T.byteAt(t, max(end, start)))
        if let w = p["word"]?.stringValue, T.slice(t, a, b) != w {
            throw EngineError.bad(cmd, "the text at \(start)..\(end) is \(debugQuoted(T.slice(t, a, b))), not \(debugQuoted(w))")
        }
        try s.edit("Check Spelling") { doc, _ in
            let snapshot = doc
            T.withText(&doc, id) { t in
                T.replaceText(&t, a, b, to)
                T.refresh(snapshot, &t)
            }
        }
        return ["changed": 1, "layer": .id(id), "start": .int(start), "end": .int(start + T.charCount(to))]
    }

    /// Replaces every whole-word, case-sensitive occurrence of `word` in the checked layers.
    static func changeAll(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "edit.checkSpelling"
        guard let word = p["word"]?.stringValue, !word.isEmpty else { throw EngineError.bad(cmd, "`changeAll` needs `word`") }
        guard let to = p["replace"]?.stringValue else { throw EngineError.bad(cmd, "`changeAll` needs `replace`") }
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        let plan: [(LayerId, [(Int, Int)])] = layersParam(s, p).compactMap { id in
            guard let t = text(doc, id) else { return nil }
            let hits = words(t).filter { T.slice(t, $0.0, $0.1) == word }
            return hits.isEmpty ? nil : (id, hits)
        }
        let count = plan.reduce(0) { $0 + $1.1.count }
        if count > 0 {
            try s.edit("Check Spelling") { doc, _ in
                let snapshot = doc
                for (id, hits) in plan {
                    T.withText(&doc, id) { t in
                        for (a, b) in hits.reversed() { T.replaceText(&t, a, b, to) }
                        T.refresh(snapshot, &t)
                    }
                }
            }
        }
        return ["changed": .int(count), "layers": .int(plan.count)]
    }

    static func addWord(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let word = p["word"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !word.isEmpty,
              !word.unicodeScalars.contains(where: \.properties.isWhitespace) else {
            throw EngineError.bad("edit.checkSpelling", "`add` needs a single `word`")
        }
        let added = editUserDictionary(s) { dict in
            if dict.contains(where: { asciiCaseInsensitiveEqual($0, word) }) { return false }
            dict.append(word)
            dict = dict.enumerated().sorted { ($0.element.lowercased(), $0.offset) < ($1.element.lowercased(), $1.offset) }.map(\.element)
            return true
        }
        return ["added": .bool(added), "word": .string(word), "userDictionary": .strings(userDictionary(s))]
    }

    static func removeWord(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let word = p["word"]?.stringValue ?? ""
        let removed = editUserDictionary(s) { dict in
            let n = dict.count
            dict.removeAll { asciiCaseInsensitiveEqual($0, word) }
            return n != dict.count
        }
        return ["removed": .bool(removed), "userDictionary": .strings(userDictionary(s))]
    }

    /// Rust `eq_ignore_ascii_case`.
    static func asciiCaseInsensitiveEqual(_ a: String, _ b: String) -> Bool {
        func low(_ u: UInt8) -> UInt8 { (65...90).contains(u) ? u + 32 : u }
        return a.utf8.count == b.utf8.count && zip(a.utf8, b.utf8).allSatisfy { low($0) == low($1) }
    }

    @Sendable static func checkSpelling(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        switch p["action"]?.stringValue ?? "list" {
        case "list", "check": return try list(s, p)
        case "change": return try change(s, p)
        case "changeAll": return try changeAll(s, p)
        case "add", "addToDictionary": return try addWord(s, p)
        case "removeFromDictionary": return try removeWord(s, p)
        case "suggest":
            let w = p["word"]?.stringValue ?? ""
            let ok = accepted(s, p)
            return ["word": .string(w), "correct": .bool(Dictionary.check(w, ok)), "suggestions": .strings(Dictionary.suggest(w, T.index(p["suggestions"]) ?? 5))]
        case let other:
            throw EngineError.bad("edit.checkSpelling", "unknown action \(debugQuoted(other))")
        }
    }

    // MARK: Insert Glyph

    @Sendable static func insertText(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "type.insertText"
        let id = try s.layerParam(p)
        guard let raw = p["text"]?.stringValue, !raw.isEmpty else { throw EngineError.bad(cmd, "missing `text`") }
        let new = T.normText(raw)
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        guard let t = text(doc, id) else { throw EngineError.bad(cmd, "layer \(id.rawValue) is not a type layer") }
        let n = T.charCount(t)
        var (a, b): (Int, Int)
        if let r = p["range"]?.arrayValue, r.count == 2 {
            let x = T.index(r[0]) ?? 0
            let y = T.index(r[1]) ?? x
            (a, b) = (min(min(x, y), n), min(max(x, y), n))
        } else if let at = T.index(p["at"]) {
            (a, b) = (at, at)
        } else {
            (a, b) = (n, n)
        }
        (a, b) = (min(a, n), min(b, n))
        let (ba, bb) = (T.byteAt(t, a), T.byteAt(t, b))
        let label = p["label"]?.stringValue ?? "Insert Glyph"
        try s.edit(label) { doc, _ in
            let snapshot = doc
            T.withText(&doc, id) { t in
                T.replaceText(&t, ba, bb, new)
                T.refresh(snapshot, &t)
            }
        }
        return ["layer": .id(id), "caret": .int(a + T.charCount(new))]
    }

    static func register(into r: inout CommandRegistry) {
        let spellParams = #"{"action":"list|change|changeAll|addToDictionary|removeFromDictionary|suggest"="list","allLayers":bool=true,"layer":id? (check one layer),"ignore":[word]? (Ignore All for this check),"suggestions":n=5; change: "layer","start","end" (chars),"word"? (verified),"replace"; changeAll: "word","replace"; addToDictionary/removeFromDictionary/suggest: "word"} → list: {"misspellings":[{"layer","start","end","word","suggestions"}],"count"}"#
        if Dictionary.isAvailable {
            r.add(CommandSpec("edit.checkSpelling", "Check Spelling…", menu: ["Edit"], params: spellParams, module: m, enabled: hasType, run: checkSpelling))
        } else {
            r.add(.unavailable("edit.checkSpelling", "Check Spelling…", menu: ["Edit"], params: spellParams, module: m,
                               reason: "needs a spelling dictionary (NSSpellChecker is macOS-only)"))
        }
        r.add(CommandSpec("type.insertText", "Insert Glyph",
                          params: #"{"layer":id?,"text":str,"at":char? (default: end of text),"range":[startChar,endChar]? (replaced),"label":str?} → {"layer","caret"}"#,
                          module: m, enabled: hasTextLayer, run: insertText))
    }
}
