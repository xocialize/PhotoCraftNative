// Type layers whose EngineData Photoshop can't open (hand-built, third-party: ag-psd, GIMP) are
// re-exported with complete EngineData; Photoshop's own is kept byte for byte. Photoshop 27.11
// crashes on open (null dereference) when a type layer lacks the structures PCPSD's
// `photoshopStructureGaps()` lists, and refuses the file when the font set is incomplete
// (diagnosed by the port's Photoshop oracle). New in the port; MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
@testable import PCIOText
import PCPSD
import Testing
@testable import PCIO

@Suite struct TypeLayerEngineDataTests {
    init() { ExportSweep.install() }

    /// A `TySh` around `engine` (nil: no EngineData at all), as another application writes it.
    static func tysh(_ text: String, _ engine: PSDEngineData?) -> [UInt8] {
        var desc = PSDDescriptor(classID: "TxLr")
            .with("Txt ", .text(.nulTerminated(text)))
            .with("Ornt", .enumerated(type: "Ornt", value: "Hrzn"))
            .with("TextIndex", .integer(0))
        if let e = engine { desc = desc.with("EngineData", .rawData(Data(PSDText.engineDataBytes(e)))) }
        return PSDText.writeTySh(PSDText.TySh(transform: .translate(20, 40), text: desc))
    }

    /// Minimal EngineData of the kind third-party writers produce: text, one style run with a font
    /// and size, one paragraph run, the font set by name only.
    static func minimal(_ text: String) -> PSDEngineData {
        let n = Int64((text + "\r").utf16.count)
        return .d([
            ("EngineDict", .d([
                ("Editor", .d([("Text", .string(text + "\r"))])),
                ("ParagraphRun", .d([("RunArray", .array([.d([("ParagraphSheet", .d([("Properties", .d([("Justification", .int(0))]))]))])])),
                                     ("RunLengthArray", .array([.int(n)]))])),
                ("StyleRun", .d([("RunArray", .array([.d([("StyleSheet", .d([("StyleSheetData", .d([("Font", .int(0)), ("FontSize", .real(24))]))]))])])),
                                 ("RunLengthArray", .array([.int(n)]))])),
            ])),
            ("ResourceDict", .d([("FontSet", .array([.d([("Name", .string("Inter-Regular"))])]))])),
        ])
    }

    static func document(_ blocks: [[UInt8]]) -> Document {
        var d = Document(name: "t", size: PixelSize(width: 200, height: 100), mode: .rgb, depth: .u8)
        for (i, b) in blocks.enumerated() {
            var t = PSDText.textLayer(fromTySh: b, dpi: 72) ?? TextLayer(text: "Hello")
            t.psdRaw = b
            var s = Surface(format: d.pixelFormat)
            s.fill(PixelRect(x0: 20, y0: 20, x1: 80, y1: 44), with: [0, 0, 0, 1])
            t.cache = s
            d.layers.append(Layer(name: "Type \(i)", content: .text(t)))
        }
        return d
    }

    @Test(arguments: [false, true]) func incompleteEngineDataIsRebuiltOnExport(_ photoshop: Bool) throws {
        let blocks = [Self.tysh("Hello", Self.minimal("Hello")), Self.tysh("Hello", nil)]
        for b in blocks { #expect(!(try PSDTypeTool(bytes: Data(b)).photoshopStructureGaps().isEmpty), "the input is incomplete") }
        var o = photocraftOptions()
        o.photoshopRecordConventions = photoshop
        let doc = Self.document(blocks)
        let bytes = try ExportSweep.$name.withValue("synthetic-incompleteEngineDataIsRebuiltOnExport-\(photoshop ? "photoshop" : "photocraft").psd") {
            try DocumentIO.export(doc, as: "t.psd", options: o).bytes
        }
        let file = try PSDFile(bytes: bytes)
        let types = file.layers.compactMap { $0.block("TySh") }
        #expect(types.count == 2)
        for t in types { #expect(try PSDTypeTool(bytes: t.data).photoshopStructureGaps().isEmpty) }
        // PCPSD's linter has a rule for it: the export is clean.
        #expect(file.compatibilityIssues(decodeChannels: true).filter { $0.severity == .error }.isEmpty)
        // The text, transform and size survive the rebuild.
        let back = try DocumentIO.importFile(name: "t.psd", bytes: bytes, options: o).document
        for l in back.layers {
            guard case let .text(t) = l.content else { Issue.record("not a type layer"); continue }
            #expect(t.text == "Hello")
            #expect(t.transform.m == [1, 0, 0, 1, 20, 40])
        }
        if case let .text(t)? = back.layers.first?.content { #expect(abs((t.runs.first?.style.sizePt ?? 0) - 24) < 0.01) }
    }

    /// `buildTySh` takes Photoshop-complete EngineData as its template and rebuilds anything else.
    @Test func buildTyShNeverKeepsAnIncompleteTemplate() throws {
        var t = try #require(PSDText.textLayer(fromTySh: Self.tysh("Hello", Self.minimal("Hello")), dpi: 72))
        t.psdRaw = Self.tysh("Hello", Self.minimal("Hello"))
        let built = PSDText.buildTySh(t, dpi: 72, ink: nil)
        #expect(try PSDTypeTool(bytes: Data(built)).photoshopStructureGaps().isEmpty)
    }

    /// Photoshop's own type layers keep their `TySh` byte for byte (corpus).
    @Test(.enabled(if: Corpus.available || Corpus.psAvailable, "no PSD corpus present (set PHOTOCRAFT_FIXTURES, PCPSD_CORPUS or PCIO_PS_CORPUS)")) func photoshopTypeLayersStayByteIdentical() throws {
        var checked = 0
        for url in Corpus.files + Corpus.psFiles {
            let file = try PSDFile(contentsOf: url)
            let originals = file.layers.compactMap { r in r.block("TySh").map { (r.displayName, $0.data) } }
            if originals.isEmpty { continue }
            for (_, data) in originals { #expect(try PSDTypeTool(bytes: data).photoshopStructureGaps().isEmpty, "\(url.lastPathComponent)") }
            let doc = try DocumentIO.importFile(contentsOf: url, options: IOOptions(compositor: StoredPixelsCompositor())).document
            let out = try ExportSweep.$name.withValue("") {
                try PSDFile(bytes: try DocumentIO.export(doc, as: "x.psd", options: IOOptions(compositor: MapsKit.compositor)).bytes)
            }
            let written = out.layers.compactMap { r in r.block("TySh").map { $0.data } }
            for (name, data) in originals {
                checked += 1
                #expect(written.contains(data), "\(url.lastPathComponent)/\(name): TySh rewritten")
            }
        }
        print("MEASURE Photoshop type layers kept byte-identical: \(checked) checked")
        #expect(checked > 0)
    }
}
