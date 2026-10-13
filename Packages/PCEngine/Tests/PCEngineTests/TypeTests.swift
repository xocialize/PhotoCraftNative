// Port of photocraft-engine (crates/engine/src/type_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft's tests use its bundled Inter; macOS has no Inter, so the face-name tests use
// Avenir Next (Regular / Demi Bold, weights 400 / 600) and the default family is PCPlatform's.
// The TySh checks of `create_renders_and_is_undoable` and `trailing_empty_paragraph_styles…` parse
// the TySh back through a PSD round trip (the engine does not keep a generated TySh on the layer;
// PCIO writes it on export). Skipped: `kern_pair_cost` (#[ignore] timing).

import Foundation
@testable import PCEngine
import PCDocument
import PCFoundation
import PCPlatform
import Testing

@Suite struct TypeTests {
    func session() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 200, "height": 100, "background": "transparent"])
        return s
    }

    func textLayer(_ s: Session, _ id: UInt64) throws -> TextLayer {
        try #require(s.active.flatMap { TypeCommands.textOf($0.doc, LayerId(id)) })
    }

    /// Text layer `id` read back from the TySh PCIO writes for it in a PSD.
    func throughTySh(_ s: Session, _ id: UInt64) throws -> TextLayer {
        let doc = try #require(s.active?.doc)
        let bytes = try EngineIO.export(doc, as: "t.psd", services: s.services).bytes
        let back = try EngineIO.importFile(name: "t.psd", bytes: bytes, services: s.services).document
        let index = try #require(doc.walk().firstIndex { $0.layer.id == LayerId(id) })
        let layer = back.walk()[index].layer
        guard case .text(let t) = layer.content else { throw EngineError.other("layer \(id) came back as \(layer.content)") }
        return t
    }

    func create(_ s: Session, _ p: JSONValue) throws -> UInt64 {
        try #require(try s.execute("type.create", p)["layer"]?.uint64Value)
    }

    func layerName(_ s: Session, _ id: UInt64) -> String? { s.active?.doc.layer(LayerId(id))?.name }

    func isBadParams(_ cmd: String, _ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch let EngineError.badParams(c, _) { return c == cmd } catch { return false }
    }

    @Test func namedFaceMetadataReplacesOldPostscriptIdentity() {
        var style = CharStyle()
        style.fontFamily = "Avenir Next"
        style.postscriptName = "AvenirNext-Regular"
        TypeCommands.applyCharProps(&style, ["fontStyle": "Demi Bold"])
        #expect(style.weight == 600)
        #expect(style.postscriptName == "AvenirNext-DemiBold")
        TypeCommands.applyCharProps(&style, ["weight": 400])
        // #3556: a style change re-resolves to the installed face instead of leaving it nameless.
        #expect(style.postscriptName == "AvenirNext-Regular")
        #expect(style.fontStyle.isEmpty)
        TypeCommands.applyCharProps(&style, ["fontStyle": "unknown-style"])
        #expect(style.postscriptName == "AvenirNext-Regular")
        TypeCommands.applyCharProps(&style, ["fontStyle": "Regular", "postscriptName": "ExplicitFace"])
        #expect(style.postscriptName == "ExplicitFace")
    }

    @Test func aFamilyFontGetsTheInstalledPostscriptName() {
        var style = CharStyle()
        style.fontFamily = "Avenir Next"
        TypeCommands.applyCharProps(&style, ["font": "Avenir Next"])
        #expect(style.fontFamily == "Avenir Next")
        #expect(style.postscriptName == "AvenirNext-Regular")
        TypeCommands.applyCharProps(&style, ["font": "Avenir Next", "weight": 600])
        #expect(style.postscriptName == "AvenirNext-DemiBold")
        // A weight no face has names no face.
        TypeCommands.applyCharProps(&style, ["weight": 650])
        #expect(style.postscriptName == nil)
        var absent = CharStyle()
        absent.fontFamily = "No Such Family 123"
        TypeCommands.applyCharProps(&absent, ["font": "No Such Family 123"])
        #expect(absent.postscriptName == nil)
    }

    @Test func aStyleOrWeightResetsTheWeightAxis() {
        var style = CharStyle()
        func axes(_ s: CharStyle) -> [String] { s.variations.map { "\($0.axis)=\($0.value)" } }
        TypeCommands.applyCharProps(&style, ["variations": ["wght": 650, "wdth": 80]])
        TypeCommands.applyCharProps(&style, ["fontStyle": "Bold"])
        #expect(axes(style) == ["wdth=80.0"])
        TypeCommands.applyCharProps(&style, ["variations": ["wght": 650]])
        TypeCommands.applyCharProps(&style, ["weight": 300])
        #expect(axes(style) == ["wdth=80.0"])
        TypeCommands.applyCharProps(&style, ["fontStyle": "Light", "variations": ["wght": 350]])
        #expect(axes(style) == ["wdth=80.0", "wght=350.0"], "same-call values apply after the style")
    }

    @Test func absurdTypeSizeAndTrackingAreRejectedAsBadParams() throws {
        let s = try session()
        #expect(isBadParams("type.create") { try s.execute("type.create", ["text": "abc", "size": 1e30]) })
        let id = try create(s, ["text": "abc", "size": 12])
        let before = try textLayer(s, id)
        for p: JSONValue in [["layer": .number(Double(id)), "tracking": 1e30],
                             ["layer": .number(Double(id)), "runs": [["start": 0, "end": 3, "tracking": 1e30]]]] {
            #expect(isBadParams("type.edit") { try s.execute("type.edit", p) })
            #expect(try textLayer(s, id).runs == before.runs)
        }
        #expect(isBadParams("type.setStyle") { try s.execute("type.setStyle", ["layer": .number(Double(id)), "tracking": 1e30]) })
        #expect(try textLayer(s, id).runs == before.runs)
    }

    /// A font that arrives after the layer was drawn re-renders it with no history step.
    @Test func refreshingTypeLayersTakesNoHistoryStep() throws {
        let s = try session()
        let id = LayerId(try create(s, ["text": "Hello", "size": 24]))
        let docId = try #require(s.active?.id)
        try s.updateActive { st in
            TypeCommands.withText(&st.doc, id) { $0.cache = nil }
            st.savedRevision = st.revision
        }
        let rev = try #require(s.active?.revision)
        let busy = TypeCommands.refreshTypeLayers(s, [(docId, id), (docId, LayerId(9999)), (DocId.fresh(), id)])
        #expect(busy.isEmpty)
        #expect(try textLayer(s, id.rawValue).cache != nil)
        let st = try #require(s.active)
        #expect(st.revision > rev)
        #expect(st.savedRevision == st.revision, "still clean")
        #expect(s.undo())
        #expect(s.active?.doc.layer(id) == nil)
    }

    @Test func createRendersAndIsUndoable() throws {
        let s = try session()
        let r = try s.execute("type.create", ["x": 10, "y": 50, "text": "Hello", "size": 24, "color": "#ff0000"])
        let id = try #require(r["layer"]?.uint64Value)
        let b = try #require(r["bounds"]?.arrayValue).compactMap(\.intValue)
        #expect(b.count == 4 && b[0] >= 9 && b[3] <= 56, "\(b)")
        let t = try textLayer(s, id)
        #expect(t.text == "Hello")
        #expect(t.runs[0].style.sizePt == 24)
        #expect(layerName(s, id) == "Hello")
        let c = try #require(t.cache)
        let px = c.readRGBA(c.contentBounds)
        #expect(px.contains { $0.w > 0.9 && $0.x > 0.9 && $0.y < 0.1 }, "red pixels exist")
        // The TySh we generate parses back to the same model.
        let back = try throughTySh(s, id)
        #expect(back.text == "Hello")
        func strip(_ r: [TextRun]) -> [TextRun] { r.map { var x = $0; x.style.postscriptName = nil; return x } }
        #expect(strip(back.charRuns()) == strip(t.charRuns()))
        #expect(back.charRuns().first?.style.postscriptName != nil, "the face is named")
        #expect(s.undo())
        #expect(s.active?.doc.layer(LayerId(id)) == nil)
    }

    @Test func autoNameFollowsTheText() throws {
        // The Type tool's flow (#483): a placeholder, selected, then replaced by typing.
        let s = try session()
        let id = try create(s, ["x": 0, "y": 40, "text": "Lorem Ipsum", "coalesce": "k"])
        #expect(layerName(s, id) == "Lorem Ipsum")
        let lid: JSONValue = .number(Double(id))
        try s.execute("type.edit", ["layer": lid, "replace": ["start": 0, "end": 11, "text": "H"], "coalesce": "k"])
        try s.execute("type.edit", ["layer": lid, "replace": ["start": 1, "end": 1, "text": "eading\nsecond line"], "coalesce": "k"])
        #expect(layerName(s, id) == "Heading")
        try s.execute("type.edit", ["layer": lid, "text": ""])
        #expect(layerName(s, id) == "Type Layer")
        try s.execute("type.edit", ["layer": lid, "text": "Title"])
        #expect(layerName(s, id) == "Title")
        #expect(s.undo())
        #expect(layerName(s, id) == "Type Layer")
    }

    @Test func sizeKeysStepEachRunAndRespectLayerScale() throws {
        let s = try session()
        let id = try create(s, ["x": 0, "y": 40, "text": "Hello world", "size": 12])
        try s.execute("type.setStyle", ["layer": .number(Double(id)), "range": [6, 11], "size": 20])
        try s.execute("type.increaseSize", [:])
        func sizes() throws -> [Float] { try textLayer(s, id).charRuns().map(\.style.sizePt) }
        #expect(try sizes() == [14, 22], "every run grows by 2 pt")
        try s.execute("type.decreaseSizeMore", ["range": [0, 5]])
        #expect(try sizes()[0] == 4, "only the range, by 10 pt")
        for _ in 0..<2 { try s.execute("type.decreaseSize", ["range": [0, 5]]) }
        #expect(try sizes()[0] == Float(TypeCommands.sizeMinPt), "never below the smallest size")
        try s.execute("edit.undo", [:])
        #expect(try sizes()[0] == 2, "one undo step per press")

        let scaled = try create(s, ["x": 0, "y": 80, "text": "Big", "size": 12])
        try s.execute("type.edit", ["layer": .number(Double(scaled)), "transform": [2.0, 0.0, 0.0, 2.0, 0.0, 80.0]])
        try s.execute("type.increaseSize", ["layer": .number(Double(scaled))])
        #expect(try textLayer(s, scaled).charRuns()[0].style.sizePt == 13, "a 200% layer shows 24 pt and steps to 26 pt")
    }

    @Test func sizeKeysNeedATypeLayer() throws {
        let s = try session()
        #expect(throws: EngineError.self) { try s.execute("type.increaseSize", [:]) }
        let id = try create(s, ["x": 0, "y": 40, "text": "Hi", "size": 12])
        try s.execute("type.increaseSize", ["by": "big"])
        try s.execute("type.increaseSize", ["by": -3])
        try s.execute("type.decreaseSize", ["by": 1e30, "range": [9, 0]])
        #expect(try textLayer(s, id).charRuns()[0].style.sizePt == Float(TypeCommands.sizeMinPt), "bad steps fall back or clamp, never panic")
        #expect(s.registry.spec("type.increaseSize")?.shortcut == "Cmd+Shift+.")
        #expect(s.registry.spec("type.decreaseSize")?.shortcut == "Cmd+Shift+,")
    }

    @Test func autoNameSkipsLeadingBlankLines() throws {
        let s = try session()
        let id = try create(s, ["x": 0, "y": 40, "text": "\n  \nHello\nworld"])
        #expect(layerName(s, id) == "Hello")
        try s.execute("type.edit", ["layer": .number(Double(id)), "replace": ["start": 0, "end": 0, "text": "\n"]])
        try s.execute("type.edit", ["layer": .number(Double(id)), "text": "\n\nGoodbye"])
        #expect(layerName(s, id) == "Goodbye")
    }

    @Test func customNameSurvivesTextEdits() throws {
        let s = try session()
        var id = try create(s, ["x": 0, "y": 40, "text": "Hello", "name": "Logo"])
        try s.execute("type.edit", ["layer": .number(Double(id)), "text": "Goodbye"])
        #expect(layerName(s, id) == "Logo")
        id = try create(s, ["x": 0, "y": 80, "text": "Hello"])
        try s.execute("layer.renameLayer", ["layer": .number(Double(id)), "name": "Caption"])
        try s.execute("type.edit", ["layer": .number(Double(id)), "text": "Goodbye"])
        #expect(layerName(s, id) == "Caption")
        try s.execute("type.edit", ["layer": .number(Double(id)), "text": "Again", "name": "Footer"])
        #expect(layerName(s, id) == "Footer")
    }

    @Test func editWithNameIsOneUndoStepForTextNameAndBounds() throws {
        let s = try session()
        let id = try create(s, ["x": 10, "y": 50, "text": "Before", "size": 20, "name": "Original"])
        let beforeBounds = try #require(try textLayer(s, id).cache).contentBounds
        #expect(layerName(s, id) == "Original")
        let steps = try #require(s.active).history.entries.count
        try s.execute("type.edit", ["layer": .number(Double(id)), "text": "A much longer edited title that wraps", "box": [10, 10, 50, 60], "name": "Renamed"])
        #expect(layerName(s, id) == "Renamed")
        #expect(try textLayer(s, id).text == "A much longer edited title that wraps")
        #expect(try #require(try textLayer(s, id).cache).contentBounds != beforeBounds)
        #expect(s.active?.history.entries.count == steps + 1)
        #expect(s.undo())
        #expect(layerName(s, id) == "Original")
        #expect(try textLayer(s, id).text == "Before")
        #expect(try #require(try textLayer(s, id).cache).contentBounds == beforeBounds)
    }

    @Test func editReplaceKeepsStyles() throws {
        let s = try session()
        let id = try create(s, ["x": 0, "y": 40, "text": "Hello world"])
        let lid: JSONValue = .number(Double(id))
        try s.execute("type.setStyle", ["layer": lid, "range": [6, 11], "fauxBold": true, "color": [0, 0, 1]])
        var t = try textLayer(s, id)
        #expect(t.runs.count == 2)
        #expect(t.runs[0].len == 6)
        #expect(t.runs[1].style.fauxBold)
        // Insert inside the bold word: inherits bold.
        try s.execute("type.edit", ["layer": lid, "replace": ["start": 8, "end": 8, "text": "XX"]])
        t = try textLayer(s, id)
        #expect(t.text == "Hello woXXrld")
        #expect(t.runs[1].len == 7)
        // Delete across the style boundary.
        try s.execute("type.edit", ["layer": lid, "replace": ["start": 3, "end": 8, "text": ""]])
        t = try textLayer(s, id)
        #expect(t.text == "HelXXrld")
        #expect(t.runs.map(\.len) == [3, 5])
        // Whole-text replace with a multi-byte string.
        let info = try s.execute("type.edit", ["layer": lid, "text": "Größe ✓\nzwei"])
        #expect(info["lines"]?.arrayValue?.count == 2)
        t = try textLayer(s, id)
        #expect(t.runs.map(\.len).reduce(0, +) == t.text.utf8.count)
    }

    @Test func allLockedTypeEditRejectsTextReplacementWithoutHistory() throws {
        let s = try session()
        let id = try create(s, ["x": 20, "y": 20, "text": "a", "size": 12])
        let lid: JSONValue = .number(Double(id))
        try s.execute("layer.setProps", ["layer": lid, "locked": true])
        var history = try #require(s.active).history.pastCount
        do {
            try s.execute("type.edit", ["layer": lid, "text": "b"])
            Issue.record("a locked layer was edited")
        } catch let EngineError.other(message) {
            #expect(message.contains("locked"))
        }
        #expect(try textLayer(s, id).text == "a")
        #expect(s.active?.history.pastCount == history)
        try s.execute("layer.setProps", ["layer": lid, "locked": false])
        history = try #require(s.active).history.pastCount
        try s.execute("type.edit", ["layer": lid, "text": "b"])
        #expect(try textLayer(s, id).text == "b")
        #expect(s.active?.history.pastCount == history + 1)
        try s.execute("edit.undo", [:])
        #expect(try textLayer(s, id).text == "a")
        #expect(s.active?.history.pastCount == history)
    }

    @Test func trailingEmptyParagraphStylesWithoutChangingPreviousLines() throws {
        let s = try session()
        let id = try create(s, ["text": "a\nb\n", "x": 20, "y": 20, "size": 12, "align": "left"])
        let lid: JSONValue = .number(Double(id))
        let before = try s.execute("type.info", ["layer": lid])
        let previousLine = before["lines"]?[1]
        #expect(previousLine != nil)
        let styled = try s.execute("type.setStyle", ["layer": lid, "range": [4, 4], "align": "right"])
        let paras = try #require(styled["paragraphs"]?.arrayValue)
        #expect(paras.count == 2)
        #expect(paras[0]["start"] == 0 && paras[0]["end"] == 4)
        #expect(paras[0]["style"]?["align"] == "Left")
        #expect(paras[1]["start"] == 4 && paras[1]["end"] == 4)
        #expect(paras[1]["style"]?["align"] == "Right")
        #expect(styled["lines"]?[1] == previousLine, "the preceding paragraph must not move")
        #expect(try throughTySh(s, id).paragraphRuns().last?.style.align == .right)
        // Typing directly into the previously empty final paragraph retains its style.
        let edited = try s.execute("type.edit", ["layer": lid, "replace": ["start": 4, "end": 4, "text": "c"]])
        #expect(edited["text"] == "a\nb\nc")
        #expect(edited["paragraphs"]?[0]?["end"] == 4)
        #expect(edited["paragraphs"]?[0]?["style"]?["align"] == "Left")
        #expect(edited["paragraphs"]?[1]?["start"] == 4)
        #expect(edited["paragraphs"]?[1]?["end"] == 5)
        #expect(edited["paragraphs"]?[1]?["style"]?["align"] == "Right")
        #expect(edited["lines"]?[1] == previousLine, "typing in the final paragraph does not move b")
    }

    @Test func setStyleParagraphAndBox() throws {
        let s = try session()
        let id = try create(s, ["box": [10, 10, 80, 80], "text": "one two three four five six seven", "size": 12])
        let lid: JSONValue = .number(Double(id))
        let info = try s.execute("type.setStyle", ["layer": lid, "align": "center", "leading": 20])
        let lines = try #require(info["lines"]?.arrayValue)
        #expect(lines.count >= 3)
        let b0 = try #require(lines[0]["baseline"]?.doubleValue), b1 = try #require(lines[1]["baseline"]?.doubleValue)
        #expect(abs(b1 - b0 - 20) < 1e-3, "explicit leading \(b0) \(b1)")
        #expect(info["paragraphs"]?[0]?["style"]?["align"] == "Center")
        var t = try textLayer(s, id)
        #expect(t.shape == .box(.init(x: 0, y: 0, width: 80, height: 80)))
        // Pixels stay inside the box horizontally.
        let r = try #require(t.cache).contentBounds
        #expect(r.x0 >= 9 && r.x1 <= 91, "\(r)")
        // Convert to point text and move.
        try s.execute("type.edit", ["layer": lid, "point": [5, 30]])
        try s.execute("type.edit", ["layer": lid, "move": [10, 0]])
        t = try textLayer(s, id)
        #expect(t.shape == .point)
        #expect(t.transform.e == 15)
    }

    @Test func rasterizeAndFonts() throws {
        let s = try session()
        let id = try create(s, ["x": 5, "y": 30, "text": "Raster"])
        try s.execute("type.rasterize", ["layer": .number(Double(id))])
        let l = try #require(s.active?.doc.layer(LayerId(id)))
        #expect(l.rasterSurface != nil)
        #expect((l.surface?.contentBounds.width ?? 0) > 10)
        #expect(throws: EngineError.self) { try s.execute("type.edit", ["layer": .number(Double(id)), "text": "x"]) }
        let fonts = try s.execute("type.fonts", [:])
        #expect(fonts["families"]?.arrayValue?.contains(.string(FontCatalog.defaultFamily)) == true)
        let faces = try s.execute("type.fonts", ["family": .string(FontCatalog.defaultFamily)])
        #expect(faces["faces"]?.arrayValue?.isEmpty == false)
    }

    /// #124: a type edit damages only the layer's old and new pixels, and a drag's coalesced steps
    /// are one history step.
    @Test func typeEditsDamageOnlyTheLayerAndCoalesce() throws {
        let s = Session()
        try s.execute("file.new", ["width": 3000, "height": 2000])
        let id = try create(s, ["x": 100, "y": 100, "text": "Hi", "size": 20])
        let steps = try #require(s.active).history.entries.count
        for k in 0..<5 {
            try s.execute("type.setStyle", ["layer": .number(Double(id)), "size": .number(Double(30 + k * 10)), "coalesce": "drag"])
            let d = try #require(s.active?.lastDamage)
            let r = try #require(try textLayer(s, id).cache).contentBounds
            #expect(d.intersect(r) == r && d.width <= 512 && d.height <= 512, "\(d) \(r)")
        }
        #expect(s.active?.history.entries.count == steps + 1)
        #expect(s.undo())
        #expect(try textLayer(s, id).runs[0].style.sizePt == 20)
    }

    @Test func editRejectsAReversedRunsRange() throws {
        let s = try session()
        let id = try create(s, ["x": 0, "y": 40, "text": "Hello world", "size": 20])
        let lid: JSONValue = .number(Double(id))
        let before = try textLayer(s, id).charRuns()
        let steps = try #require(s.active).history.entries.count
        for runs: JSONValue in [[["start": 5, "end": 2, "fauxBold": true]],
                                [["start": 0, "end": 3, "fauxBold": true], ["start": 8, "end": 7]],
                                [["end": 0, "start": 1]]] {
            do {
                try s.execute("type.edit", ["layer": lid, "runs": runs])
                Issue.record("accepted \(runs)")
            } catch let e as EngineError {
                guard case .badParams = e else { Issue.record("\(e)"); continue }
                #expect(e.description.contains("is before `start`"))
            }
        }
        #expect(try textLayer(s, id).charRuns() == before)
        #expect(s.active?.history.entries.count == steps)
        try s.execute("type.edit", ["layer": lid, "runs": [["start": 2, "end": 5, "fauxBold": true]]])
        let runs = try textLayer(s, id).charRuns()
        #expect(runs.map(\.len) == [2, 3, 6])
        #expect(runs.map(\.style.fauxBold) == [false, true, false])
    }

    @Test func styleRangeReversedIsANoOp() {
        var t = TextLayer()
        TypeCommands.replaceText(&t, 0, 0, "Hello world")
        let before = t.charRuns()
        TypeCommands.styleRange(&t, 5, 2) { $0.sizePt = 40 }
        #expect(t.charRuns() == before)
        #expect(t.runs.map(\.len).reduce(0, +) == t.text.utf8.count)
    }

    @Test func styleRangeOnEmptyText() {
        var t = TextLayer()
        TypeCommands.styleRange(&t, 0, 0) { $0.sizePt = 40 }
        #expect(t.runs[0].style.sizePt == 40)
        TypeCommands.replaceText(&t, 0, 0, "abc")
        #expect(t.runs.count == 1)
        #expect(t.runs[0].len == 3)
        #expect(t.runs[0].style.sizePt == 40)
    }

    func kerningOf(_ s: Session, _ id: UInt64) throws -> [String] {
        let t = try textLayer(s, id)
        var out: [String] = []
        var at = 0
        for r in t.charRuns() {
            let n = TypeCommands.charCount(TypeCommands.slice(t.text, at, at + r.len))
            out += Array(repeating: "\(r.style.kerning.rawValue) \(r.style.kern)", count: n)
            at += r.len
        }
        return out
    }

    /// #206: `type.edit {"kerning"}` over a range takes a number (manual, 1/1000 em) or a mode.
    @Test func editSetsKerningOverARange() throws {
        let s = try session()
        let id = try create(s, ["x": 5, "y": 50, "text": "AVAT", "size": 30])
        let lid: JSONValue = .number(Double(id))
        try s.execute("type.edit", ["layer": lid, "range": [0, 1], "kerning": 100])
        try s.execute("type.edit", ["layer": lid, "range": [2, 4], "kerning": "optical"])
        #expect(try kerningOf(s, id) == ["Off 100.0", "Metrics 0.0", "Optical 0.0", "Optical 0.0"])
        try s.execute("type.edit", ["layer": lid, "kerning": "metrics"])
        #expect(try kerningOf(s, id).allSatisfy { $0 == "Metrics 0.0" })
        try s.execute("type.edit", ["layer": lid, "runs": [["start": 1, "end": 2, "kerning": -50]]])
        try s.execute("type.setStyle", ["layer": lid, "range": [3, 4], "kerning": "off"])
        #expect(try kerningOf(s, id)[1] == "Off -50.0")
        #expect(try kerningOf(s, id)[3] == "Off 0.0")
        let info = try s.execute("type.info", ["layer": lid])
        #expect(info["runs"]?[1]?["style"]?["kern"] == -50.0)
    }

    /// Bad kerning params are errors, never crashes, and leave the layer alone.
    @Test func kerningParamsFailGracefully() throws {
        let s = try session()
        let id = try create(s, ["x": 5, "y": 50, "text": "AV\nT", "size": 30])
        let before = try textLayer(s, id)
        let cases: [JSONValue] = [
            ["kerning": "tight"], ["kerning": 1e9], ["kerning": -5000], ["kerning": true], ["kerning": [1]],
            ["runs": [["start": 0, "end": 1, "kerning": "x"]]], ["kernPair": 3], ["kernPair": ["by": 20]], ["kernPair": ["at": 1]],
            ["kernPair": ["at": 1, "by": "20"]], ["kernPair": ["at": 1, "by": 1e12]], ["kernPair": ["at": 0, "by": 20]],
            ["kernPair": ["at": 4, "by": 20]], ["kernPair": ["at": 99, "by": 20]], ["kernPair": ["at": 2, "by": 20]],
            ["kernPair": ["at": 3, "by": 20]], ["kernPair": ["at": -1, "by": 20]],
        ]
        for p in cases {
            let q = p.setting("layer", .number(Double(id)))
            #expect(throws: EngineError.self, "\(q)") { try s.execute("type.edit", q) }
        }
        #expect(throws: EngineError.self) { try s.execute("type.setStyle", ["layer": .number(Double(id)), "kerning": "tight"]) }
        #expect(try textLayer(s, id).runs == before.runs)
        // type.create rejects the same values and creates no layer (#994).
        let layers = s.active?.doc.layerCount
        for k: JSONValue in ["tight", 1e9, -5000, true, [1]] {
            #expect(throws: EngineError.self) { try s.execute("type.create", ["x": 0, "y": 10, "text": "AV", "kerning": k]) }
        }
        #expect(s.active?.doc.layerCount == layers)
        var nid = try create(s, ["x": 0, "y": 10, "text": "AV", "kerning": "optical"])
        #expect(try kerningOf(s, nid).allSatisfy { $0 == "Optical 0.0" })
        nid = try create(s, ["x": 0, "y": 10, "text": "AV", "kerning": -50])
        #expect(try kerningOf(s, nid).allSatisfy { $0 == "Off -50.0" })
    }

    /// Photoshop's Alt+←/→: the pair before the caret becomes manual, starting from the kerning it
    /// shows (the font's pair kerning for "AV"), ±20 per press, one history step each.
    @Test func kernPairStepsFromTheShownKerning() throws {
        let s = try session()
        let id = try create(s, ["x": 5, "y": 50, "text": "AVA", "size": 40, "font": "Avenir Next"])
        let lid: JSONValue = .number(Double(id))
        let metric = try #require(TypeCommands.pairKerning(try textLayer(s, id), dpi: 72, at: 0))
        #expect(metric < -10, "Avenir Next kerns AV: \(metric)")
        let steps = try #require(s.active).history.entries.count
        try s.execute("type.edit", ["layer": lid, "kernPair": ["at": 1, "by": 20]])
        #expect(try kerningOf(s, id)[0] == "Off \(metric.rounded() + 20)")
        try s.execute("type.edit", ["layer": lid, "kernPair": ["at": 1, "by": 100]])
        #expect(try kerningOf(s, id)[0] == "Off \(metric.rounded() + 120)")
        try s.execute("type.edit", ["layer": lid, "kernPair": ["at": 1, "by": -20]])
        #expect(try kerningOf(s, id)[0] == "Off \(metric.rounded() + 100)")
        #expect(Array(try kerningOf(s, id)[1...]) == ["Metrics 0.0", "Metrics 0.0"])
        #expect(s.active?.history.entries.count == steps + 3)
        #expect(s.undo())
        #expect(try kerningOf(s, id)[0] == "Off \(metric.rounded() + 120)")
        #expect(s.undo() && s.undo())
        #expect(try kerningOf(s, id)[0] == "Metrics 0.0")
    }

    @Test func createVerticalTypeIsAtomicAndInvalidOrientationIsRejected() throws {
        for boxed in [false, true] {
            let s = try session()
            let before = try #require(s.active).history.entries.count
            for o: JSONValue in ["diagonal", .null, true] {
                #expect(throws: EngineError.self) { try s.execute("type.create", ["text": "test", "orientation": o]) }
                #expect(s.active?.history.entries.count == before)
            }
            var p: JSONValue = ["text": "test", "orientation": "vertical", "x": 20, "y": 20]
            if boxed { p = p.setting("box", [20, 20, 80, 60]) }
            let id = try create(s, p)
            let t = try textLayer(s, id)
            #expect(t.orientation == .vertical)
            if case .box = t.shape { #expect(boxed) } else { #expect(!boxed) }
            try s.execute("edit.undo", [:])
            #expect(s.active?.doc.layer(LayerId(id)) == nil)
        }
    }

    @Test func missingFontEmitsWarningInCreateSetStyleAndEdit() throws {
        let s = try session()
        let r = try s.execute("type.create", ["x": 10, "y": 20, "text": "Hello", "font": "NoSuchFamily123"])
        #expect(r["warnings"] == ["font 'NoSuchFamily123' is not installed; text may render using a fallback face"])
        let id = try #require(r["layer"]?.uint64Value)
        let styled = try s.execute("type.setStyle", ["layer": .number(Double(id)), "font": "StillNoSuchFamily456"])
        #expect(styled["warnings"] == ["font 'StillNoSuchFamily456' is not installed; text may render using a fallback face"])
        let edited = try s.execute("type.edit", ["layer": .number(Double(id)), "runs": [["start": 0, "end": 2, "font": "AnotherMissingFont789"]]])
        #expect(edited["warnings"] == [
            "font 'AnotherMissingFont789' is not installed; text may render using a fallback face",
            "font 'StillNoSuchFamily456' is not installed; text may render using a fallback face",
        ])
    }
}
