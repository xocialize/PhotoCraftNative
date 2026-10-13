// Port of photocraft-engine (crates/engine/src/type_styles_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// `isolated_options_preview…` compares the composite through the CPU compositor and drops
// the `psd_raw` equality (always nil here).

import Foundation
@testable import PCEngine
import PCDocument
import PCFormat
import PCFoundation
import PCPlatform
import Testing

@Suite struct TypeStylesTests {
    func session(_ text: String) throws -> (Session, UInt64) {
        let s = Session()
        try s.execute("file.new", ["width": 400, "height": 200, "background": "transparent"])
        let r = try s.execute("type.create", ["x": 10, "y": 50, "text": .string(text), "size": 12])
        return (s, try #require(r["layer"]?.uint64Value))
    }

    func layer(_ s: Session, _ id: UInt64) throws -> TextLayer { try #require(s.active.flatMap { TypeCommands.textOf($0.doc, LayerId(id)) }) }

    func runAt(_ t: TextLayer, _ ci: Int) -> CharStyle {
        let b = TypeCommands.byteAt(t.text, ci)
        var at = 0
        for r in t.charRuns() {
            if b < at + r.len { return r.style }
            at += r.len
        }
        return t.charRuns().last?.style ?? CharStyle()
    }

    func lid(_ id: UInt64) -> JSONValue { .number(Double(id)) }

    @Test func characterStyleLifecycle() throws {
        let (s, id) = try session("Hello world")
        let r = try s.execute("type.characterStyle.new", ["attrs": ["size": 30, "underline": true], "fromSelection": false])
        let cs = try #require(r["id"]?.uint64Value)
        #expect(r["name"] == "Character Style 1")
        let l = try s.execute("type.characterStyle.list", [:])
        #expect(l["styles"]?[0]?["name"] == "None")
        #expect(l["styles"]?[1]?["attrs"] == ["size_pt": 30.0, "underline": true])

        // Apply to "world": its runs take the style; "Hello " keeps None.
        try s.execute("type.characterStyle.apply", ["id": .int(cs), "layer": lid(id), "range": [6, 11]])
        var t = try layer(s, id)
        let w = runAt(t, 7)
        #expect(w.sizePt == 30 && w.underline && w.styleSheet == UInt32(cs))
        #expect(runAt(t, 0).styleSheet == nil)
        var cur = try s.execute("type.characterStyle.list", ["layer": lid(id), "range": [6, 11]])["current"]
        #expect(cur?["character"] == .int(cs) && cur?["characterOverride"] == false)

        // A local change is an override ("+"); redefining the style changes other text too.
        try s.execute("type.setStyle", ["layer": lid(id), "range": [6, 8], "italic": true])
        cur = try s.execute("type.characterStyle.list", ["layer": lid(id), "range": [6, 8]])["current"]
        #expect(cur?["characterOverride"] == true)
        try s.execute("type.characterStyle.set", ["id": .int(cs), "attrs": ["size_pt": 40.0]])
        t = try layer(s, id)
        #expect(runAt(t, 6).sizePt == 40 && runAt(t, 6).italic)
        #expect(runAt(t, 9).sizePt == 40 && !runAt(t, 9).italic)
        #expect(runAt(t, 0).sizePt == 12)

        // Clear Override drops the italic but keeps the style.
        try s.execute("type.characterStyle.clearOverride", ["layer": lid(id), "range": [6, 11]])
        t = try layer(s, id)
        #expect(!runAt(t, 6).italic)
        #expect(runAt(t, 6).styleSheet == UInt32(cs))

        // Rename, duplicate, delete (text keeps its look).
        try s.execute("type.characterStyle.rename", ["id": .int(cs), "name": "Emphasis"])
        let d = try s.execute("type.characterStyle.duplicate", ["id": .int(cs)])
        #expect(d["name"] == "Emphasis copy")
        try s.execute("type.characterStyle.delete", ["id": .int(cs)])
        t = try layer(s, id)
        #expect(runAt(t, 7).sizePt == 40 && runAt(t, 7).styleSheet == nil)
        #expect(try s.execute("type.characterStyle.list", [:])["styles"]?.arrayValue?.count == 2)

        // Each command is one undo step.
        try s.execute("edit.undo", [:])
        #expect(runAt(try layer(s, id), 7).styleSheet == UInt32(cs))
    }

    @Test func newStyleFromSelectionAndRedefine() throws {
        let (s, id) = try session("Title")
        try s.execute("type.setStyle", ["layer": lid(id), "size": 48, "color": "#ff0000"])
        let r = try s.execute("type.characterStyle.new", ["layer": lid(id), "apply": true])
        let cs = UInt32(try #require(r["id"]?.uint64Value))
        let st = try #require(s.active?.doc.textStyles.charStyle(cs))
        #expect(st.attrs["size_pt"] == 48.0)
        #expect(runAt(try layer(s, id), 0).styleSheet == cs)
        // Change the text, then redefine the style from it: no override remains.
        try s.execute("type.setStyle", ["layer": lid(id), "size": 60])
        try s.execute("type.characterStyle.redefine", ["layer": lid(id)])
        let cur = try s.execute("type.characterStyle.list", ["layer": lid(id)])["current"]
        #expect(cur?["character"] == .int(cs) && cur?["characterOverride"] == false)
        #expect(s.active?.doc.textStyles.charStyle(cs)?.attrs["size_pt"] == 60.0)
    }

    @Test func paragraphStylesAndBasicParagraph() throws {
        let (s, id) = try session("One\nTwo")
        // A fresh layer is Basic Paragraph with no paragraph override.
        let cur = try s.execute("type.paragraphStyle.list", ["layer": lid(id)])["current"]
        #expect(cur?["paragraph"] == 0 && cur?["paragraphOverride"] == false)
        let r = try s.execute("type.paragraphStyle.new", ["name": "Head", "fromSelection": false, "attrs": ["align": "center", "size": 24, "weight": 700]])
        let ps = UInt32(try #require(r["id"]?.uint64Value))
        try s.execute("type.paragraphStyle.apply", ["id": .int(ps), "layer": lid(id), "range": [0, 1]])
        var t = try layer(s, id)
        var p = t.paragraphRuns()
        #expect(p[0].style.styleSheet == ps)
        #expect(p[0].style.align == .center)
        #expect(p.last?.style.styleSheet == nil)
        // The first paragraph's characters are on the style's basis.
        #expect(runAt(t, 0).sizePt == 24 && runAt(t, 0).weight == 700)
        #expect(runAt(t, 5).sizePt == 12)
        // Redefining Basic Paragraph moves the second paragraph only.
        try s.execute("type.paragraphStyle.set", ["id": 0, "attrs": ["spaceBefore": 6]])
        t = try layer(s, id)
        p = t.paragraphRuns()
        #expect(p.last?.style.spaceBeforePt == 6)
        #expect(p[0].style.spaceBeforePt == 6, "Head inherits Basic Paragraph for unset attributes")
        // Basic Paragraph can't be deleted or renamed; bad ids and attributes are rejected.
        #expect(throws: EngineError.self) { try s.execute("type.paragraphStyle.delete", ["id": 0]) }
        #expect(throws: EngineError.self) { try s.execute("type.paragraphStyle.rename", ["id": 0, "name": "x"]) }
        #expect(throws: EngineError.self) { try s.execute("type.characterStyle.apply", ["id": 99]) }
        #expect(throws: EngineError.self) { try s.execute("type.characterStyle.new", ["attrs": ["bogus": 1]]) }
        #expect(throws: EngineError.self) { try s.execute("type.characterStyle.new", ["attrs": ["size_pt": "big"]]) }
        // Delete keeps the look.
        try s.execute("type.paragraphStyle.delete", ["id": .int(ps)])
        t = try layer(s, id)
        #expect(t.paragraphRuns()[0].style.align == .center)
        #expect(t.paragraphRuns()[0].style.styleSheet == nil)
    }

    @Test func stylesSurviveTypingAndSave() throws {
        let (s, id) = try session("ab")
        let r = try s.execute("type.characterStyle.new", ["attrs": ["size": 20], "fromSelection": false])
        let cs = UInt32(try #require(r["id"]?.uint64Value))
        try s.execute("type.characterStyle.apply", ["id": .int(cs), "layer": lid(id)])
        // Typed text inherits the run (and its style reference).
        try s.execute("type.edit", ["layer": lid(id), "replace": ["start": 2, "end": 2, "text": "cd"]])
        #expect(runAt(try layer(s, id), 3).styleSheet == cs)
        // .pcraft round trip keeps the styles and references.
        let doc = try #require(s.active?.doc)
        let back = try PcraftFormat.load(try PcraftFormat.save(doc))
        #expect(back.textStyles == doc.textStyles)
        let text = back.walk().lazy.compactMap { e -> TextLayer? in if case .text(let t) = e.layer.content { t } else { nil } }.first
        #expect(runAt(try #require(text), 0).styleSheet == cs)
    }

    @Test func disabledStates() throws {
        let s = Session()
        #expect(!s.isEnabled("type.characterStyle.new"))
        try s.execute("file.new", ["width": 10, "height": 10])
        #expect(s.isEnabled("type.characterStyle.new"))
        #expect(!s.isEnabled("type.characterStyle.apply"))
        #expect(try s.execute("type.characterStyle.list", [:])["current"] == .null)
    }

    @Test func sharedAttributeNamesAcceptBothSpellings() throws {
        let (s, _) = try session("x")
        let r = try s.execute("type.characterStyle.new", ["fromSelection": false, "attrs": ["color": "#ff0000", "caps": "all", "kerning": "Off"]])
        let id = UInt32(try #require(r["id"]?.uint64Value))
        let st = try #require(s.active).doc.textStyles.resolveChar(para: nil, chr: id, defaultFamily: FontCatalog.defaultFamily)
        #expect(st.color.rgb == SIMD3(1, 0, 0))
        #expect(st.caps == .allCaps)
        #expect(st.kerning == .off)
        let r2 = try s.execute("type.paragraphStyle.new", ["fromSelection": false, "attrs": ["align": "Center", "direction": "rtl"]])
        let p = try #require(s.active).doc.textStyles.resolvePara(UInt32(try #require(r2["id"]?.uint64Value)))
        #expect(p.align == .center && p.direction == .rtl)
    }

    @Test func exhaustedStyleIdsReturnErrorsWithoutHistoryChanges() throws {
        let (s, _) = try session("x")
        try s.updateActive { st in
            st.doc.textStyles.character.append(CharacterStyleDef(id: .max, name: "Max"))
            st.doc.textStyles.paragraph.append(ParagraphStyleDef(id: .max, name: "Max"))
        }
        let past = try #require(s.active).history.pastCount
        let revision = try #require(s.active).revision
        func message(_ id: String, _ p: JSONValue) -> String {
            do { try s.execute(id, p); return "" } catch { return "\(error)" }
        }
        #expect(message("type.characterStyle.new", ["fromSelection": false]).contains("character style id space exhausted"))
        #expect(message("type.characterStyle.duplicate", ["id": .int(UInt32.max)]).contains("character style id space exhausted"))
        #expect(message("type.paragraphStyle.new", ["fromSelection": false]).contains("paragraph style id space exhausted"))
        #expect(message("type.paragraphStyle.duplicate", ["id": .int(UInt32.max)]).contains("paragraph style id space exhausted"))
        #expect(s.active?.history.pastCount == past)
        #expect(s.active?.revision == revision)
        #expect(s.active?.doc.textStyles.nextCharId == nil)
        #expect(s.active?.doc.textStyles.nextParaId == nil)
    }

    @Test(arguments: [(false, 8), (false, 16), (false, 32), (true, 8), (true, 16), (true, 32)])
    func isolatedOptionsPreviewMatchesCommit(_ paragraph: Bool, _ depth: Int) throws {
        let s = Session()
        try s.execute("file.new", ["width": 400, "height": 200, "depth": .int(depth), "background": "transparent"])
        let a = try #require(try s.execute("type.create", ["x": 10, "y": 50, "text": "Hello world", "size": 24])["layer"]?.uint64Value)
        let b = try #require(try s.execute("type.create", ["x": 10, "y": 100, "text": "Second layer", "size": 24])["layer"]?.uint64Value)
        let prefix = paragraph ? "type.paragraphStyle" : "type.characterStyle"
        let id = try #require(try s.execute("\(prefix).new", ["fromSelection": false, "attrs": ["color": "#ff0000"]])["id"]?.uint64Value)
        for l in [a, b] { try s.execute("\(prefix).apply", ["id": .int(id), "layer": lid(l)]) }
        try s.execute("type.setStyle", ["layer": lid(a), "range": [6, 11], "color": "#0000ff"])
        let doc = try #require(s.active).doc
        let revision = try #require(s.active).revision
        let p: JSONValue = ["id": .int(id), "attrs": ["color": "#00ff00"]]
        let shown = try TypeStylesCommands.previewOptions(doc, p, paragraph: paragraph)
        #expect(s.active?.doc == doc)
        #expect(s.active?.revision == revision)
        #expect(TypeCommands.textOf(shown, LayerId(a))?.charRuns().last?.style.color.rgb == SIMD3(0, 0, 1))
        #expect(TypeCommands.textOf(shown, LayerId(b))?.color.rgb == SIMD3(0, 1, 0))
        try s.execute("\(prefix).set", p)
        let committed = try #require(s.active).doc
        #expect(shown.textStyles == committed.textStyles)
        for l in [a, b] {
            let expected = TypeCommands.textOf(shown, LayerId(l)), actual = TypeCommands.textOf(committed, LayerId(l))
            #expect(expected?.runs == actual?.runs)
            #expect(expected?.paragraphs == actual?.paragraphs)
        }
        let px = PixelRect(x0: 20, y0: 40, x1: 21, y1: 41)
        #expect(try s.services.renderer.renderCPU(shown, region: px).px == s.services.renderer.renderCPU(committed, region: px).px)
    }

    @Test func previewOptionsValidatesWithoutMutatingSource() throws {
        let (s, _) = try session("Text")
        let doc = try #require(s.active).doc
        for paragraph in [false, true] {
            for p: JSONValue in [[:], ["id": "bad"], ["id": .number(1.8e19)], ["id": 999], ["id": 0, "attrs": 3]] {
                #expect(throws: EngineError.self) { try TypeStylesCommands.previewOptions(doc, p, paragraph: paragraph) }
            }
        }
        let before = doc.textStyles
        let p: JSONValue = ["id": 0, "attrs": ["color": "#112233"]]
        #expect(throws: EngineError.self) { try TypeStylesCommands.previewOptions(doc, p, paragraph: false) }
        let shown = try TypeStylesCommands.previewOptions(doc, p, paragraph: true)
        #expect(shown.textStyles != before)
        #expect(doc.textStyles == before)
    }
}
