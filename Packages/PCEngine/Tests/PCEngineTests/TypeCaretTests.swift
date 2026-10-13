// Port of photocraft-engine (crates/engine/src/type_caret_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft's "Inter" is PCPlatform's default family here.

import Foundation
@testable import PCEngine
import PCDocument
import Testing

@Suite struct TypeCaretTests {
    func session() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 400, "height": 300, "background": "white"])
        return s
    }

    func create(_ s: Session, _ p: JSONValue) throws -> UInt64 { try #require(try s.execute("type.create", p)["layer"]?.uint64Value) }

    func u(_ v: JSONValue, _ k: String) throws -> UInt64 { try #require(v[k]?.uint64Value, "missing \(k) in \(v)") }

    func mid(_ c: JSONValue) throws -> (Double, Double) {
        let seg = try #require(c["segment"]?.arrayValue)
        let x0 = try #require(seg[0][0]?.doubleValue), y0 = try #require(seg[0][1]?.doubleValue)
        let x1 = try #require(seg[1][0]?.doubleValue), y1 = try #require(seg[1][1]?.doubleValue)
        return ((x0 + x1) / 2, (y0 + y1) / 2)
    }

    /// Caret midpoint hit-tests back to the same character.
    func roundTrip(_ s: Session, _ id: UInt64, checkInside: Bool) throws {
        let lid: JSONValue = .number(Double(id))
        let info = try s.execute("type.info", ["layer": lid])
        let text = try #require(info["text"]?.stringValue)
        let lines = try #require(info["lines"]?.arrayValue)
        let n = TypeCommands.charCount(text)
        for i in 0...n {
            let c = try s.execute("type.caret", ["layer": lid, "index": .int(i)])
            #expect(try u(c, "index") == UInt64(i), "\(text) caret \(i): \(c)")
            let (x, y) = try mid(c)
            #expect(x.isFinite && y.isFinite, "\(c)")
            let h = try s.execute("type.hitTest", ["layer": lid, "x": .number(x), "y": .number(y)])
            #expect(try u(h, "index") == UInt64(i), "\(text) index \(i) at (\(x), \(y)) -> \(h)")
            #expect(h["line"] == c["line"], "\(text) index \(i)")
            #expect(try u(h, "layer") == id)
            // A shared soft-wrap boundary belongs to the following line, where the caret is drawn (#3068).
            let onLine = lines.lastIndex { ln in
                let a = ln["start"]?.intValue ?? 0, b = ln["end"]?.intValue ?? 0
                return i >= a && i <= b
            }
            #expect(try u(c, "line") == UInt64(onLine ?? max(lines.count - 1, 0)), "\(text) index \(i) lines \(lines)")
            if checkInside { #expect(h["inside"] == true, "\(text) index \(i) at (\(x), \(y))") }
        }
    }

    @Test func commandsAreRegisteredQueries() {
        let r = CommandRegistry.standard()
        for id in ["type.hitTest", "type.caret", "type.navigate"] {
            let spec = r.spec(id)
            #expect(spec != nil && spec?.journal == false && spec?.menu.isEmpty == true, "\(id)")
        }
    }

    @Test func caretMidpointRoundTripsForPointParagraphTransformedAndVertical() throws {
        let s = try session()
        let point = try create(s, ["x": 40, "y": 70, "text": "AäB", "size": 28])
        try roundTrip(s, point, checkInside: true)

        let para = try create(s, ["box": [15, 20, 64, 180], "text": "one two three four six seven eight nine", "size": 16])
        let nlines = try s.execute("type.info", ["layer": .number(Double(para))])["lines"]?.arrayValue?.count ?? 0
        #expect(nlines >= 2, "paragraph should wrap, got \(nlines) lines")
        try roundTrip(s, para, checkInside: true)

        let turned = try create(s, ["x": 30, "y": 40, "text": "Rotate me", "size": 22])
        let (ang, scale) = (0.55, 1.35)
        let (sn, cs) = (sin(ang), cos(ang))
        try s.execute("type.edit", ["layer": .number(Double(turned)), "transform": .doubles([cs * scale, sn * scale, -sn * scale, cs * scale, 130, 80])])
        try roundTrip(s, turned, checkInside: false)

        let vert = try create(s, ["x": 200, "y": 30, "text": "Abc\nDef", "size": 20])
        try s.execute("type.orientation.vertical", ["layer": .number(Double(vert))])
        try roundTrip(s, vert, checkInside: false)
    }

    func go(_ s: Session, _ id: UInt64, _ index: Int, _ mov: String, _ x: Double? = nil) throws -> UInt64 {
        var p: JSONValue = ["layer": .number(Double(id)), "index": .int(index), "move": .string(mov)]
        if let x { p = p.setting("x", .number(x)) }
        return try u(try s.execute("type.navigate", p), "index")
    }

    @Test func navigateWordsLinesEdgesAndKeepsAColumn() throws {
        let s = try session()
        var id = try create(s, ["x": 20, "y": 60, "text": "hello big world", "size": 18])
        #expect(try go(s, id, 0, "wordNext") == 5)
        #expect(try go(s, id, 5, "wordNext") == 9)
        #expect(try go(s, id, 9, "wordNext") == 15)
        #expect(try go(s, id, 15, "wordNext") == 15)
        #expect(try go(s, id, 15, "wordPrev") == 10)
        #expect(try go(s, id, 7, "wordPrev") == 6)
        #expect(try go(s, id, 6, "wordPrev") == 0)
        #expect(try go(s, id, 0, "wordPrev") == 0)
        #expect(try go(s, id, 4, "start") == 0)
        #expect(try go(s, id, 4, "end") == 15)
        #expect(try go(s, id, 4, "lineStart") == 0)
        #expect(try go(s, id, 4, "lineEnd") == 15)

        // A newline is not part of either word; line edges agree with type.info.
        id = try create(s, ["x": 20, "y": 120, "text": "hello\nworld", "size": 18])
        #expect(try go(s, id, 0, "wordNext") == 5)
        #expect(try go(s, id, 5, "wordNext") == 11)
        #expect(try go(s, id, 6, "wordPrev") == 0)
        var lines = try #require(try s.execute("type.info", ["layer": .number(Double(id))])["lines"]?.arrayValue)
        #expect(lines.count == 2, "\(lines)")
        let (l0s, l0e) = (try u(lines[0], "start"), try u(lines[0], "end"))
        let (l1s, l1e) = (try u(lines[1], "start"), try u(lines[1], "end"))
        #expect(try go(s, id, 2, "lineEnd") == l0e)
        #expect(try go(s, id, 2, "lineStart") == l0s)
        #expect(try go(s, id, Int(l1s) + 1, "lineStart") == l1s)
        #expect(try go(s, id, Int(l1s), "lineEnd") == l1e)
        let next = try go(s, id, 1, "lineNext")
        #expect((l1s...l1e).contains(next), "lineNext \(next) not on \(l1s)...\(l1e)")
        #expect(try go(s, id, 0, "linePrev") == 0)
        #expect(try go(s, id, Int(l1e), "lineNext") == 11)

        // Repeated line moves keep the document x of the original column.
        id = try create(s, ["x": 24, "y": 200, "text": "WWWWWW\nI", "size": 28])
        lines = try #require(try s.execute("type.info", ["layer": .number(Double(id))])["lines"]?.arrayValue)
        let end0 = try u(lines[0], "end")
        let (start1, end1) = (try u(lines[1], "start"), try u(lines[1], "end"))
        #expect(end1 > start1, "\(lines)")
        let caret0 = try s.execute("type.caret", ["layer": .number(Double(id)), "index": 0])
        let x = try #require(caret0["segment"]?[0]?[0]?.doubleValue)
        #expect(try go(s, id, Int(end0), "lineNext", x) == start1)
        #expect(try go(s, id, Int(end0), "lineNext") == end1)
        #expect(try go(s, id, Int(start1), "linePrev", x) == (try u(lines[0], "start")))

        // Queries do not record history or a journal entry.
        let steps = try #require(s.active).history.entries.count
        let rev = try #require(s.active).revision
        let journal = s.journal.count
        try s.execute("type.hitTest", ["layer": .number(Double(id)), "x": .number(x), "y": caret0["segment"]?[0]?[1] ?? 0])
        try s.execute("type.caret", ["layer": .number(Double(id)), "index": 1])
        try s.execute("type.navigate", ["layer": .number(Double(id)), "index": 0, "move": "end"])
        #expect(s.active?.history.entries.count == steps)
        #expect(s.active?.revision == rev)
        #expect(s.journal.count == journal)
    }

    @Test func wrappedCaretQueriesUseTheLineThatContainsTheCaret() throws {
        let s = try session()
        let id = try create(s, ["text": "ab cd", "box": [20, 20, 20, 70], "size": 12])
        let lines = try #require(try s.execute("type.info", ["layer": .number(Double(id))])["lines"]?.arrayValue)
        #expect(lines.count >= 2, "\(lines)")
        let index = Int(try u(lines[1], "start"))
        #expect(UInt64(index) == (try u(lines[0], "end")), "shared wrap boundary")
        #expect(try s.execute("type.caret", ["layer": .number(Double(id)), "index": .int(index)])["line"] == 1)
        #expect(try go(s, id, index, "lineStart") == UInt64(index))
        #expect(try go(s, id, index, "lineEnd") == (try u(lines[1], "end")))

        let hard = try create(s, ["text": "ab\ncd", "x": 30, "y": 100, "size": 12])
        #expect(try s.execute("type.caret", ["layer": .number(Double(hard)), "index": 3])["line"] == 1)
        #expect(try go(s, hard, 3, "lineStart") == 3)
        #expect(try go(s, hard, 3, "lineEnd") == 5)
    }

    @Test func hitTestPicksTheTopmostVisibleTypeLayerAndEmptyTextIsIndexZero() throws {
        let s = try session()
        let lower = try create(s, ["x": 50, "y": 80, "text": "AAAA", "size": 36])
        let upper = try create(s, ["x": 50, "y": 80, "text": "BBBB", "size": 36])
        let (x, y) = try mid(try s.execute("type.caret", ["layer": .number(Double(upper)), "index": 1]))
        var hit = try s.execute("type.hitTest", ["x": .number(x), "y": .number(y)])
        #expect(try u(hit, "layer") == upper)
        #expect(hit["inside"] == true)
        try s.execute("layer.setProps", ["layer": .number(Double(upper)), "visible": false])
        hit = try s.execute("type.hitTest", ["x": .number(x), "y": .number(y)])
        #expect(try u(hit, "layer") == lower)
        // A named hidden layer is still queried.
        hit = try s.execute("type.hitTest", ["layer": .number(Double(upper)), "x": .number(x), "y": .number(y)])
        #expect(try u(hit, "layer") == upper)
        #expect(throws: EngineError.self) { try s.execute("type.hitTest", ["x": -40.0, "y": -40.0]) }

        let empty = try create(s, ["x": 10, "y": 40, "text": "", "size": 18])
        let c = try s.execute("type.caret", ["layer": .number(Double(empty)), "index": 0])
        #expect(try u(c, "index") == 0)
        let ex = try #require(c["segment"]?[0]?[0]?.doubleValue)
        let (_, ey) = try mid(c)
        hit = try s.execute("type.hitTest", ["layer": .number(Double(empty)), "x": .number(ex), "y": .number(ey)])
        #expect(try u(hit, "index") == 0)
        for mov in ["wordNext", "wordPrev", "lineNext", "linePrev", "lineStart", "lineEnd", "start", "end"] {
            #expect(try go(s, empty, 0, mov) == 0, "\(mov)")
        }
    }

    @Test func automaticHitTestSkipsHiddenParentGroups() throws {
        let s = try session()
        let text = try create(s, ["x": 50, "y": 80, "text": "AB", "size": 36])
        let (x, y) = try mid(try s.execute("type.caret", ["layer": .number(Double(text)), "index": 1]))
        #expect(try u(try s.execute("type.hitTest", ["x": .number(x), "y": .number(y)]), "layer") == text)
        try s.execute("layer.new.groupFromLayers", ["name": "Inner"])
        try s.execute("layer.new.groupFromLayers", ["name": "Outer"])
        try s.execute("layer.setProps", ["visible": false])
        #expect(throws: EngineError.self, "hidden ancestor must suppress automatic targeting") {
            try s.execute("type.hitTest", ["x": .number(x), "y": .number(y)])
        }
        #expect(try u(try s.execute("type.hitTest", ["layer": .number(Double(text)), "x": .number(x), "y": .number(y)]), "layer") == text)
        try s.execute("layer.setProps", ["visible": true])
        #expect(try u(try s.execute("type.hitTest", ["x": .number(x), "y": .number(y)]), "layer") == text)
    }

    @Test func badParamsAreErrors() throws {
        let bare = Session()
        for (id, p) in [("type.hitTest", ["x": 0, "y": 0] as JSONValue), ("type.caret", ["index": 0]), ("type.navigate", ["index": 0, "move": "end"])] {
            do { try bare.execute(id, p); Issue.record("\(id) ran without a document") } catch EngineError.disabled {} catch { Issue.record("\(id): \(error)") }
        }
        let s = try session()
        let id = try create(s, ["x": 10, "y": 40, "text": "Hi", "size": 20])
        let pixel = try #require(try s.execute("layer.new.layer", [:])["layer"]?.uint64Value)
        let lid: JSONValue = .number(Double(id)), pid: JSONValue = .number(Double(pixel))
        let cases: [(String, JSONValue)] = [
            ("type.hitTest", [:]), ("type.hitTest", ["x": "1", "y": 2]), ("type.hitTest", ["layer": lid, "x": 1]),
            ("type.hitTest", ["layer": "nope", "x": 1, "y": 2]), ("type.hitTest", ["layer": pid, "x": 1, "y": 2]),
            ("type.caret", ["layer": lid]), ("type.caret", ["layer": lid, "index": -1]), ("type.caret", ["layer": lid, "index": 1.5]),
            ("type.caret", ["layer": lid, "index": 99]), ("type.caret", ["layer": pid, "index": 0]),
            ("type.navigate", ["layer": lid, "index": 0]), ("type.navigate", ["layer": lid, "index": 0, "move": "left"]),
            ("type.navigate", ["layer": lid, "index": 9, "move": "end"]), ("type.navigate", ["layer": lid, "index": 0, "move": "lineNext", "x": "no"]),
            ("type.navigate", ["layer": pid, "index": 0, "move": "start"]),
        ]
        for (cmd, p) in cases {
            do { try s.execute(cmd, p); Issue.record("\(cmd) \(p) succeeded") } catch EngineError.badParams {} catch { Issue.record("\(cmd) \(p): \(error)") }
        }
        do {
            try s.execute("type.caret", ["layer": 9_999_999, "index": 0])
            Issue.record("unknown layer accepted")
        } catch EngineError.noLayer {} catch { Issue.record("\(error)") }
        // A point on the named layer but outside its text still returns a caret, marked outside.
        let far = try s.execute("type.hitTest", ["layer": lid, "x": 390, "y": 290])
        #expect(far["inside"] == false)
        #expect(try u(far, "index") <= 2)
    }
}
