// Port of photocraft-engine (crates/engine/src/variables_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// `csv_multiline_values_apply_persist_and_export_as_two_data_sets` is split: the CSV half is
// `csvMultilineValuesApply`, the `.pcraft` reopen and export half `multilineDataSetsPersistAndExport`.
// Type layers are built in the model rather than with `type.create`'s font matching. Exported PSDs
// also go to the Photoshop oracle.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCPlatform
import Testing

@Suite struct VariablesTests {
    /// A document with a raster layer "photo", a togglable raster "badge" and a text layer "title".
    func session() throws -> (Session, LayerId, LayerId, LayerId) {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 48])
        let ids = try s.edit("setup") { doc, _ -> (LayerId, LayerId, LayerId) in
            let fmt = doc.pixelFormat
            var photo = Layer.raster("photo", format: fmt)
            photo.withRaster { $0.fill(PixelRect(x: 0, y: 0, width: 64, height: 48), with: PixelCodec.fromRGBA(fmt, SIMD4(0.5, 0.5, 0.5, 1))) }
            var badge = Layer.raster("badge", format: fmt)
            badge.withRaster { $0.fill(PixelRect(x: 0, y: 0, width: 10, height: 10), with: PixelCodec.fromRGBA(fmt, SIMD4(1, 0, 0, 1))) }
            let title = Layer(name: "title", content: .text(TextLayer(text: "Old")))
            doc.layers.append(contentsOf: [photo, badge, title])
            return (photo.id, badge.id, title.id)
        }
        return (s, ids.0, ids.1, ids.2)
    }

    func doc(_ s: Session) -> Document { s.active!.doc }

    func textOf(_ s: Session, _ id: LayerId) -> String? {
        guard case .text(let t)? = doc(s).layer(id)?.content else { return nil }
        return t.text
    }

    func tmp(_ name: String) throws -> String {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pc-vars-\(ProcessInfo.processInfo.processIdentifier)-\(name)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.path
    }

    func defineBadgeAndHeadline(_ s: Session, _ badge: LayerId, _ title: LayerId) throws {
        try s.execute("image.variables.define", ["defs": [
            ["name": "showBadge", "layer": .id(badge), "type": "visibility"],
            ["name": "headline", "layer": .id(title), "type": "textReplacement"],
        ]])
    }

    @Test func defineApplyVisibilityAndText() throws {
        let (s, _, badge, title) = try session()
        try defineBadgeAndHeadline(s, badge, title)
        try s.execute("image.variables.dataSets", ["dataSets": [
            ["name": "A", "values": [
                ["variable": "showBadge", "kind": "visibility", "value": false],
                ["variable": "headline", "kind": "text", "value": "Hello"],
            ]],
        ]])
        #expect(doc(s).layer(badge)?.visible == true)
        #expect(textOf(s, title) == "Old")

        // document.inspect surfaces the variables for agents.
        let insp = try s.execute("document.inspect")
        #expect(insp["variables"]?["defs"]?.arrayValue?.count == 2)
        #expect(insp["variables"]?["dataSets"]?[0] == "A")

        let r = try s.execute("image.applyDataSet", ["name": "A"])
        #expect(r["applied"] == "A")
        #expect(doc(s).layer(badge)?.visible == false, "visibility applied")
        #expect(textOf(s, title) == "Hello", "text applied")
        #expect(doc(s).variables.active == 0)

        // One history step, undoable back to the original.
        #expect(s.active?.history.entries.last == "Apply Data Set \"A\"")
        #expect(s.undo())
        #expect(doc(s).layer(badge)?.visible == true)
        #expect(textOf(s, title) == "Old")
    }

    @Test(arguments: ["fit", "fill", "asIs", "conform"]) func listedPixelMethodsCanBeUsedToRedefineVariables(method: String) throws {
        let (s, photo, _, _) = try session()
        let defined = try s.execute("image.variables.define", ["defs": [
            ["name": "photo", "layer": .id(photo), "type": "pixelReplacement", "method": .string(method), "align": "bottomRight", "clip": true],
        ]])
        let expected = doc(s).variables.defs
        let listed = try s.execute("variables.list")
        try s.execute("image.variables.define", ["defs": listed["defs"] ?? .null])
        #expect(doc(s).variables.defs == expected)
        #expect(defined["defs"]?[0]?["method"] == .string(method))
        #expect(listed["defs"]?[0]?["method"] == .string(method))
        #expect(listed["defs"]?[0]?["align"] == "bottomRight")
    }

    @Test func badParamsAreErrors() throws {
        let (s, _, badge, _) = try session()
        #expect(throws: (any Error).self) { try s.execute("image.variables.define", ["defs": [["name": "x", "layer": 999999, "type": "visibility"]]]) }
        #expect(throws: (any Error).self) { try s.execute("image.variables.define", ["defs": [["name": "x", "layer": .id(badge), "type": "nope"]]]) }
        #expect(throws: (any Error).self) { try s.execute("image.applyDataSet", ["name": "missing"]) }
    }

    @Test func csvImportAndApply() throws {
        let (s, _, badge, title) = try session()
        try defineBadgeAndHeadline(s, badge, title)
        let csv = try tmp("csv") + "/sets.csv"
        try Data("DataSet,showBadge,headline\nrow-on,true,On Sale\nrow-off,false,Sold Out\n".utf8).write(to: URL(fileURLWithPath: csv))
        #expect(try s.execute("file.import.variableDataSets", ["path": .string(csv)])["imported"] == 2)

        try s.execute("image.applyDataSet", ["name": "row-off"])
        #expect(doc(s).layer(badge)?.visible == false)
        #expect(textOf(s, title) == "Sold Out")

        try s.execute("image.applyDataSet", ["name": "row-on"])
        #expect(doc(s).layer(badge)?.visible == true)
        #expect(textOf(s, title) == "On Sale")
    }

    @Test func csvFieldsPreserveUnicodeAndQuoting() {
        let cases: [(String, Unicode.Scalar, [String])] = [
            ("Café,Привет,日本語,👩‍🎨,e\u{301}", ",", ["Café", "Привет", "日本語", "👩‍🎨", "e\u{301}"]),
            ("\"Café, Привет\",\"日本語 \"\"quoted\"\" 👩‍🎨\",", ",", ["Café, Привет", "日本語 \"quoted\" 👩‍🎨", ""]),
            ("Café;\"Привет;日本語\";👩‍🎨", ";", ["Café", "Привет;日本語", "👩‍🎨"]),
            ("Café\t\"Привет\t日本語\"\t👩‍🎨", "\t", ["Café", "Привет\t日本語", "👩‍🎨"]),
            ("plain,\"with, comma\",\"a\"\"b\",,", ",", ["plain", "with, comma", "a\"b", "", ""]),
            ("", ",", [""]),
        ]
        for (line, delimiter, expected) in cases {
            #expect(VariablesCommands.splitCSV(line, delimiter) == expected, "\(line)")
        }
    }

    @Test(arguments: [",", ";", "\t"]) func csvImportPreservesUnicodeHeadersNamesAndText(delimiter: String) throws {
        let csv = try tmp("unicode-text-\(delimiter.unicodeScalars.first!.value)") + "/sets.csv"
        let (s, _, badge, title) = try session()
        try s.execute("image.variables.define", ["defs": [
            ["name": "показать", "layer": .id(badge), "type": "visibility"],
            ["name": "заголовок café", "layer": .id(title), "type": "textReplacement"],
        ]])
        let text = "Café, Привет; 日本語\t👩‍🎨 e\u{301} \"quoted\""
        let d = delimiter
        let body = "DataSet\(d)показать\(d)заголовок café\r\nНабор 日本語\(d)true\(d)Café\r\n\"Строка \"\"été\"\"\"\(d)false\(d)\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"\r\n"
        try Data(body.utf8).write(to: URL(fileURLWithPath: csv))
        #expect(try s.execute("file.import.variableDataSets", ["path": .string(csv), "delimiter": .string(delimiter)])["imported"] == 2)
        let rows = try s.execute("variables.list")
        #expect(rows["dataSets"]?[0]?["name"] == "Набор 日本語")
        #expect(rows["dataSets"]?[0]?["values"]?[1]?["variable"] == "заголовок café")
        #expect(rows["dataSets"]?[1]?["values"]?[1]?["value"] == .string(text))
        try s.execute("image.applyDataSet", ["name": "Набор 日本語"])
        #expect(textOf(s, title) == "Café")
        try s.execute("image.applyDataSet", ["name": "Строка \"été\""])
        #expect(textOf(s, title) == text)
        #expect(doc(s).layer(badge)?.visible == false)
        #expect(s.undo())
        #expect(textOf(s, title) == "Café")
        #expect(doc(s).layer(badge)?.visible == true)
        #expect(s.redo())
        #expect(textOf(s, title) == text)
    }

    @Test(arguments: ["\n", "\r\n"]) func csvMultilineValuesApply(ending: String) throws {
        let (s, _, badge, title) = try session()
        try defineBadgeAndHeadline(s, badge, title)
        let first = "Café, \"quoted\"\(ending)\(ending)日本語 👩‍🎨"
        let second = "Fin\(ending)e\u{301}"
        let csv = try tmp("multiline-\(ending.count)-\(ending.utf8.count)") + "/sets.csv"
        // Blank physical lines inside a quoted field are data; blank records between rows are
        // ignored. The last quoted field ends at EOF, without a final record terminator.
        let body = "DataSet,showBadge,headline\(ending)one,true,\"\(first.replacingOccurrences(of: "\"", with: "\"\""))\"\(ending)\(ending)two,false,\"\(second)\""
        try Data(body.utf8).write(to: URL(fileURLWithPath: csv))
        #expect(try s.execute("file.import.variableDataSets", ["path": .string(csv)])["imported"] == 2)
        let rows = try s.execute("variables.list")
        #expect(rows["dataSets"]?[0]?["values"]?[1]?["value"] == .string(first))
        #expect(rows["dataSets"]?[1]?["values"]?[1]?["value"] == .string(second))
        for (name, text, visible) in [("one", first, true), ("two", second, false)] {
            try s.execute("image.applyDataSet", ["name": .string(name)])
            #expect(textOf(s, title) == text)
            #expect(doc(s).layer(badge)?.visible == visible)
        }
    }

    @Test func csvMultilineDefaultNamesCountLogicalNonblankRecords() throws {
        let csv = try tmp("multiline-default-names") + "/sets.csv"
        for (header, first, second) in [("headline", "\"first\n\nline\"", "\"\""), ("DataSet,headline", ",\"first\n\nline\"", ",\"\"")] {
            let (s, _, _, title) = try session()
            try s.execute("image.variables.define", ["defs": [["name": "headline", "layer": .id(title), "type": "textReplacement"]]])
            try Data("\n \t\n\(header)\n\n\(first)\n \n\(second)".utf8).write(to: URL(fileURLWithPath: csv))
            #expect(try s.execute("file.import.variableDataSets", ["path": .string(csv)])["imported"] == 2)
            let rows = try s.execute("variables.list")
            #expect(rows["dataSets"]?[0]?["name"] == "Data Set 1")
            #expect(rows["dataSets"]?[1]?["name"] == "Data Set 2")
            #expect(rows["dataSets"]?[0]?["values"]?[0]?["value"] == "first\n\nline")
            #expect(rows["dataSets"]?[1]?["values"]?[0]?["value"] == "", "a quoted empty field is a record")
        }
    }

    @Test func csvImportErrorsLeaveExistingDataSetsUnchanged() throws {
        let (s, _, _, _) = try session()
        try s.execute("image.variables.dataSets", ["dataSets": [["name": "Сохранённый набор", "values": []]]])
        let csv = try tmp("invalid-csv") + "/sets.csv"
        for bytes in [[UInt8](), Array("DataSet,headline\nrow,".utf8) + [0xFF]] {
            try Data(bytes).write(to: URL(fileURLWithPath: csv))
            let before = doc(s)
            let revision = s.active?.revision
            #expect(throws: (any Error).self) { try s.execute("file.import.variableDataSets", ["path": .string(csv)]) }
            #expect(doc(s) == before && s.active?.revision == revision)
            #expect(doc(s).variables.dataSets[0].name == "Сохранённый набор")
        }
    }

    /// An 8×8 solid-blue PNG at a new temporary path.
    func bluePNG(_ name: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-vars-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var surf = Surface(format: .rgba8)
        surf.fill(PixelRect(x: 0, y: 0, width: 8, height: 8), with: [0, 0, 1, 1])
        let url = dir.appendingPathComponent(name)
        try ImageCodecs.encode(surf, rect: PixelRect(x: 0, y: 0, width: 8, height: 8), as: .png).write(to: url)
        return url.path
    }

    @Test func pixelReplacementChangesTheLayer() throws {
        let (s, photo, _, _) = try session()
        let png = try bluePNG("blue.png")
        try s.execute("image.variables.define", ["defs": [["name": "img", "layer": .id(photo), "type": "pixelReplacement", "method": "conform"]]])
        try s.execute("image.variables.dataSets", ["dataSets": [["name": "blue", "values": [["variable": "img", "kind": "pixels", "value": .string(png)]]]]])
        let before = try s.execute("document.pixel", ["x": 32, "y": 24])
        try s.execute("image.applyDataSet", ["name": "blue"])
        let after = try s.execute("document.pixel", ["x": 32, "y": 24])
        #expect(before != after, "pixel layer content changed")
        #expect((after[2]?.doubleValue ?? 0) > (after[0]?.doubleValue ?? 1), "replacement is blue-ish: \(after)")
        // Conform fills the layer's bounds exactly with the bicubic-scaled image.
        #expect(doc(s).layer(photo)?.surface?.pixel(x: 32, y: 24) == [0, 0, 1, 1])
        // An untrusted session's gate judges the path first; nothing is applied.
        let b = doc(s)
        s.authorize = { id, p in if id == "image.applyDataSet", p["path"] != nil { throw EngineError.other("path refused") } }
        #expect(throws: EngineError.other("path refused")) { try s.execute("image.applyDataSet", ["name": "blue"]) }
        #expect(doc(s) == b)
    }

    @Test func csvImportPreservesUnicodePixelPaths() throws {
        let (s, photo, _, _) = try session()
        let png = try bluePNG("изображение,日本語.png")
        let csv = (png as NSString).deletingLastPathComponent + "/sets.csv"
        try s.execute("image.variables.define", ["defs": [["name": "фото", "layer": .id(photo), "type": "pixelReplacement", "method": "conform"]]])
        try "DataSet,фото\nсиний,\"\(png)\"\n".write(toFile: csv, atomically: true, encoding: .utf8)
        try s.execute("file.import.variableDataSets", ["path": .string(csv)])
        let rows = try s.execute("variables.list")
        #expect(rows["dataSets"]?[0]?["values"]?[0]?["value"] == .string(png))
        try s.execute("image.applyDataSet", ["name": "синий"])
        #expect(doc(s).layer(photo)?.surface?.pixel(x: 32, y: 24) == [0, 0, 1, 1])
    }

    @Test func pixelReplacementOfALayeredFileImportsItsComposite() throws {
        let (s, photo, badge, _) = try session()
        try s.execute("image.variables.define", ["defs": [
            ["name": "img", "layer": .id(photo), "type": "pixelReplacement", "method": "conform"],
            ["name": "showBadge", "layer": .id(badge), "type": "visibility"],
        ]])
        // A two-layer PSD: blue under a half-covering green layer.
        let src = Session()
        try src.execute("file.new", ["width": 8, "height": 8, "background": "#0000ff"])
        try src.edit("green") { doc, _ in
            let fmt = doc.pixelFormat
            var g = Layer.raster("green", format: fmt)
            g.withRaster { $0.fill(PixelRect(x: 0, y: 0, width: 4, height: 8), with: PixelCodec.fromRGBA(fmt, SIMD4(0, 1, 0, 1))) }
            doc.layers.append(g)
        }
        let psd = try tmp("layered-px") + "/layered.psd"
        try src.saveDocument(to: psd)
        dropForOracle(URL(fileURLWithPath: psd), as: "variables-pixel-replacement.psd")
        try s.execute("image.variables.dataSets", ["dataSets": [
            ["name": "blue", "values": [["variable": "showBadge", "kind": "visibility", "value": false], ["variable": "img", "kind": "pixels", "value": .string(psd)]]],
        ]])
        try s.execute("image.applyDataSet", ["name": "blue"])
        let surf = try #require(doc(s).layer(photo)?.surface)
        #expect(surf.pixel(x: 8, y: 24) == [0, 1, 0, 1], "the left half is the PSD's top layer")
        #expect(surf.pixel(x: 56, y: 24) == [0, 0, 1, 1], "the right half its background")
        #expect(doc(s).layer(badge)?.visible == false)
    }

    @Test func appliedTextIsRendered() throws {
        // Applying a text value cleared the type layer's render cache and nothing rebuilt it, so
        // the text vanished from the canvas (#990).
        let s = Session()
        try s.execute("file.new", ["width": 200, "height": 60, "background": "white"])
        let id = try s.edit("type") { doc, active -> LayerId in
            var t = TextLayer(text: "HELLO", sizePt: 32)
            t.transform = .translate(4, 40)
            let l = Layer(name: "HELLO", content: .text(t))
            let id = doc.insertAbove(active, l)
            active = id
            return id
        }
        try s.execute("image.variables.define", ["defs": [["name": "headline", "layer": .id(id), "type": "textReplacement"]]])
        try s.execute("image.variables.dataSets", ["dataSets": [["name": "row1", "values": [["variable": "headline", "kind": "text", "value": "BYE"]]]]])
        try s.execute("image.applyDataSet", ["name": "row1"])
        guard case .text(let t)? = doc(s).layer(id)?.content else { Issue.record("not a text layer"); return }
        let cache = try #require(t.cache, "the applied text is drawn")
        #expect(!cache.contentBounds.isEmpty)
        #expect(t.psdRaw == nil)
    }

    @Test func appliedTextKeepsTheCharacterStyle() throws {
        // Applying a text value cleared the style runs (#2742): the new text takes the first
        // character's style and the first paragraph's settings.
        let (s, _, _, title) = try session()
        var bold = CharStyle(fontFamily: "Helvetica", sizePt: 40, color: .rgb(0.75, 0.22, 0.17, 1))
        bold.weight = 700
        bold.italic = true
        bold.underline = true
        bold.tracking = 120
        var regular = bold
        regular.weight = 400
        regular.italic = false
        let para = ParagraphStyle(align: .center)
        try s.edit("style") { doc, _ in
            doc.updateLayer(title) { l in
                l.withText { t in
                    t.text = "Before"
                    t.runs = [TextRun(len: 3, style: bold), TextRun(len: 3, style: regular)]
                    t.paragraphs = [ParagraphRun(len: 6, style: para)]
                    t.syncSummary()
                }
            }
        }
        try s.execute("image.variables.define", ["defs": [["name": "headline", "layer": .id(title), "type": "textReplacement"]]])
        try s.execute("image.variables.dataSets", ["dataSets": [
            ["name": "s0", "values": [["variable": "headline", "kind": "text", "value": "One style"]]],
            ["name": "s1", "values": [["variable": "headline", "kind": "text", "value": ""]]],
        ]])
        try s.execute("image.applyDataSet", ["name": "s0"])
        guard case .text(let after)? = doc(s).layer(title)?.content else { Issue.record("not a text layer"); return }
        #expect(after.text == "One style")
        let runs = after.charRuns()
        #expect(runs.count == 1, "the replacement is one run")
        #expect(runs.first?.len == "One style".utf8.count)
        #expect(runs.first?.style == bold, "in the first run's style")
        #expect(after.paragraphRuns().first?.style == para, "paragraph settings are kept")
        #expect(after.fontFamily == bold.fontFamily && after.sizePt == bold.sizePt && after.color == bold.color)

        // An empty value empties the layer without trapping and keeps the style for later text.
        try s.execute("image.applyDataSet", ["name": "s1"])
        guard case .text(let empty)? = doc(s).layer(title)?.content else { Issue.record("not a text layer"); return }
        #expect(empty.text == "")
        #expect(empty.charRuns().first?.style == bold)
        try s.execute("image.applyDataSet", ["name": "s0"])

        // Undo restores the previous text and runs.
        #expect(s.undo())
        guard case .text(let undone)? = doc(s).layer(title)?.content else { Issue.record("not a text layer"); return }
        #expect(undone.text == "")
    }

    @Test func exportDataSetsAsFiles() throws {
        let (s, _, badge, title) = try session()
        try defineBadgeAndHeadline(s, badge, title)
        try s.execute("image.variables.dataSets", ["dataSets": [
            ["name": "one", "values": [["variable": "headline", "kind": "text", "value": "1"]]],
            ["name": "two", "values": [["variable": "showBadge", "kind": "visibility", "value": false]]],
        ]])
        let dir = try tmp("out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let r = try s.execute("file.export.dataSetsAsFiles", ["dir": .string(dir), "format": "png"])
        #expect(r["count"] == 2)
        #expect(FileManager.default.fileExists(atPath: "\(dir)/one.png"))
        #expect(FileManager.default.fileExists(atPath: "\(dir)/two.png"))
        // Filename template with {index}.
        let d2 = try tmp("tmpl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: d2) }
        try s.execute("file.export.dataSetsAsFiles", ["dir": .string(d2), "format": "png", "naming": "row-{index}"])
        #expect(FileManager.default.fileExists(atPath: "\(d2)/row-001.png"))
        #expect(FileManager.default.fileExists(atPath: "\(d2)/row-002.png"))
        // Exporting doesn't mutate the live document.
        #expect(doc(s).layer(badge)?.visible == true)
        #expect(textOf(s, title) == "Old")
    }

    func visibilityExportSession(_ names: [String]) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 8, "background": "white", "name": "card"])
        let layer = doc(s).layers[0].id
        try s.execute("image.variables.define", ["defs": [["name": "show", "layer": .id(layer), "type": "visibility"]]])
        let sets: [JSONValue] = names.enumerated().map { i, n in
            ["name": .string(n), "values": [["variable": "show", "kind": "visibility", "value": .bool(i == 0)]]]
        }
        try s.execute("image.variables.dataSets", ["dataSets": .array(sets)])
        return s
    }

    @Test(arguments: [("sanitized", ["unique", "a b", "a_b"], "{name}", "a_b.png"), ("constant", ["unique", "a b", "a_b"], "{document}", "card.png"),
                      ("case", ["unique", "Card", "card"], "{name}", "card.png")])
    func exportDataSetsRejectsCollisionsBeforeWriting(_ c: (String, [String], String, String)) throws {
        let (label, names, naming, collision) = c
        let s = try visibilityExportSession(names)
        let before = doc(s)
        let revision = s.active?.revision
        let dir = try tmp("collision-\(label)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data("keep earlier export".utf8).write(to: URL(fileURLWithPath: "\(dir)/unique.png"))
        try Data("keep colliding export".utf8).write(to: URL(fileURLWithPath: "\(dir)/\(collision)"))
        do {
            try s.execute("file.export.dataSetsAsFiles", ["dir": .string(dir), "naming": .string(naming)])
            Issue.record("colliding names are refused")
        } catch let e as EngineError {
            guard case .badParams = e else { Issue.record("\(e)"); return }
            #expect(e.description.contains(collision) && e.description.contains("{index}"), "\(e)")
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: "\(dir)/unique.png")) == Data("keep earlier export".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(collision)")) == Data("keep colliding export".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).count == 2)
        let absent = "\(dir)/not-created"
        #expect(throws: (any Error).self) { try s.execute("file.export.dataSetsAsFiles", ["dir": .string(absent), "naming": .string(naming)]) }
        #expect(!FileManager.default.fileExists(atPath: absent))
        #expect(doc(s) == before && s.active?.revision == revision)
    }

    @Test(arguments: [("indexed", ["a b", "a_b"], "card-{index}", nil, ["card-001.png", "card-002.png"]),
                      ("distinct", ["a-b", "a_b"], "{name}", nil, ["a-b.png", "a_b.png"]),
                      ("subset", ["a b", "a_b"], "{name}", ["a b"], ["a_b.png"])] as [(String, [String], String, [String]?, [String])])
    func exportDataSetsUniquePathsPreserveVariationsAndDocument(_ c: (String, [String], String, [String]?, [String])) throws {
        let (label, names, naming, selected, expected) = c
        let s = try visibilityExportSession(names)
        let before = doc(s)
        let revision = s.active?.revision
        let dir = try tmp("unique-\(label)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var p: [String: JSONValue] = ["dir": .string(dir), "naming": .string(naming)]
        if let selected { p["dataSets"] = .strings(selected) }
        let result = try s.execute("file.export.dataSetsAsFiles", .object(p))
        let paths = expected.map { "\(dir)/\($0)" }
        #expect(result == ["files": .strings(paths), "count": .int(paths.count)])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).count == paths.count)
        for (i, path) in paths.enumerated() {
            let exported = try EngineIO.importPath(path, services: s.services).document
            let px = try s.services.renderer.render(exported, region: PixelRect(x0: 0, y0: 0, x1: 1, y1: 1)).px[0]
            #expect(px == (i == 0 ? SIMD4(repeating: 1) : SIMD4(repeating: 0)), "\(path)")
        }
        #expect(doc(s) == before && s.active?.revision == revision)
    }

    @Test func exportedMultilineRowsDiffer() throws {
        try multilineDataSetsPersistAndExport(reopen: false)
    }

    @Test func multilineDataSetsPersistAndExport() throws {
        try multilineDataSetsPersistAndExport(reopen: true)
    }

    func multilineDataSetsPersistAndExport(reopen: Bool) throws {
        let (s0, _, badge, title) = try session()
        var s = s0
        try defineBadgeAndHeadline(s, badge, title)
        try s.execute("image.variables.dataSets", ["dataSets": [
            ["name": "one", "values": [["variable": "showBadge", "kind": "visibility", "value": true], ["variable": "headline", "kind": "text", "value": "Café\n\n日本語"]]],
            ["name": "two", "values": [["variable": "showBadge", "kind": "visibility", "value": false], ["variable": "headline", "kind": "text", "value": "Fin"]]],
        ]])
        let dir = try tmp("multiline-out-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try s.execute("image.applyDataSet", ["name": "two"])
        if reopen {
            let native = "\(dir)/multiline.pcraft"
            try s.saveDocument(to: native)
            let reopened = Session()
            try reopened.openFile(native)
            #expect(doc(reopened).variables == doc(s).variables)
            #expect(textOf(reopened, title) == "Fin")
            try reopened.execute("image.applyDataSet", ["name": "one"])
            #expect(textOf(reopened, title) == "Café\n\n日本語")
            s = reopened
        }
        let before = doc(s)
        let out = try s.execute("file.export.dataSetsAsFiles", ["dir": .string(dir + "/out"), "format": "png"])
        #expect(out["count"] == 2)
        let images = try (out["files"]?.arrayValue ?? []).compactMap(\.stringValue).map { try EngineIO.importPath($0, services: s.services).document }
        try #require(images.count == 2)
        #expect(images.allSatisfy { $0.size == before.size })
        #expect(images[0].layers[0].surface != images[1].layers[0].surface, "the exported rows have different content")
        #expect(doc(s) == before, "export keeps the live document unchanged")
    }

    @Test func appliedTextIsRenderedInExports() throws {
        let s = Session()
        try s.execute("file.new", ["width": 200, "height": 60, "background": "white"])
        let id = try s.edit("type") { doc, active -> LayerId in
            var t = TextLayer(text: "HELLO", sizePt: 32)
            t.transform = .translate(4, 40)
            TextEngine.renderLayer(&t, dpi: Double(doc.resolutionDpi), format: doc.pixelFormat)
            let id = doc.insertAbove(active, Layer(name: "HELLO", content: .text(t)))
            active = id
            return id
        }
        func dark(_ d: Document) throws -> Int { try s.services.renderer.render(d, region: d.bounds).px.filter { $0.x < 0.5 }.count }
        #expect(try dark(doc(s)) > 0)
        try s.execute("image.variables.define", ["defs": [["name": "headline", "layer": .id(id), "type": "textReplacement"]]])
        try s.execute("image.variables.dataSets", ["dataSets": [["name": "row1", "values": [["variable": "headline", "kind": "text", "value": "BYE"]]]]])
        let dir = try tmp("text-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = try s.execute("file.export.dataSetsAsFiles", ["dir": .string(dir), "format": "png"])
        let exported = try EngineIO.importPath(try #require(out["files"]?[0]?.stringValue), services: s.services).document
        #expect(try dark(exported) > 0, "the exported row keeps its text")
    }

    @Test func exportedDataSetsKeepTheCharacterStyle() throws {
        // file.export.dataSetsAsFiles applies each set to a copy of the document the same way.
        let (s, _, _, title) = try session()
        var bold = CharStyle(fontFamily: "Helvetica", sizePt: 40, color: .rgb(0.75, 0.22, 0.17, 1))
        bold.weight = 700
        bold.italic = true
        bold.underline = true
        try s.edit("style") { doc, _ in
            doc.updateLayer(title) { l in
                l.withText { t in
                    t.text = "Before"
                    t.runs = [TextRun(len: 6, style: bold)]
                    t.syncSummary()
                }
            }
        }
        try s.execute("image.variables.define", ["defs": [["name": "headline", "layer": .id(title), "type": "textReplacement"]]])
        try s.execute("image.variables.dataSets", ["dataSets": [["name": "s0", "values": [["variable": "headline", "kind": "text", "value": "After"]]]]])
        let dir = try tmp("styled-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = try s.execute("file.export.dataSetsAsFiles", ["dir": .string(dir), "format": "psd"])
        let path = try #require(out["files"]?[0]?.stringValue)
        dropForOracle(URL(fileURLWithPath: path), as: "variables-styled-export.psd")
        let exported = try EngineIO.importPath(path, services: s.services).document
        let t = try #require(exported.layers.lazy.compactMap { l -> TextLayer? in
            if case .text(let t) = l.content { return t }
            return nil
        }.first, "the export keeps the type layer")
        #expect(t.text == "After")
        let got = try #require(t.charRuns().first?.style)
        #expect(got.weight == bold.weight && got.italic == bold.italic && got.underline == bold.underline)
    }
}
