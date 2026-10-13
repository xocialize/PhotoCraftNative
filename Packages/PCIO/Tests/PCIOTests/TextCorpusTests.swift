// Port of photocraft-io (crates/io/tests/text_corpus.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Type layers through whole-file import and export: the corpus checks run over the Photoshop
// corpus (PCPSD_CORPUS; skipped when absent) instead of photocraft's external corpus, plus a type
// layer created here. The TySh-level halves are PCIOTextTests' CorpusTextTests and
// CreatedTextLayerTests.
//
// - `corpus_text_layers`: the model of every imported type layer, and its rebuild through our
//   TySh writer. Not ported: the geometry comparison of a re-render with Photoshop's pixels (it
//   needs the text engine).
// - `corpus_tysh_lossless` (one ag-psd file in photocraft): every unedited `TySh` of the corpus is
//   written back byte for byte.
// - `corpus_photoshop_txt2_survives_an_unedited_save` (photocraft's Photoshop 2026 type files):
//   every corpus file's `Txt2` survives an unedited save.
// - `created_text_layer_roundtrips_through_psd`: without the rendered-pixels assertion (no font
//   renderer: the layer is saved without pixels).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
@testable import PCIOText
import PCPSD
import Testing
@testable import PCIO

@Suite struct TextCorpusTests {
    init() { ExportSweep.install() }
    /// PCRender for the merged image (MapsKit's): these exports reach the Photoshop oracle.
    static func options() -> IOOptions { MapsKit.options() }

    static func txt2(_ doc: Document) -> [UInt8]? { doc.metadata.psdGlobalBlocks.first { $0.key == "Txt2" }?.data }

    @Test(.enabled(if: Corpus.available, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)")) func corpusTextLayers() throws {
        var n = 0
        for url in Corpus.files {
            let bytes = [UInt8](try Data(contentsOf: url))
            guard (0 ..< max(bytes.count - 3, 0)).contains(where: { bytes[$0] == 0x54 && bytes[$0 + 1] == 0x79 && bytes[$0 + 2] == 0x53 && bytes[$0 + 3] == 0x68 }) else { continue }
            let name = url.lastPathComponent
            let doc = try MapsKit.importFile(bytes, name, options: Self.options()).document
            // The document's Txt2 (kept verbatim on export) carries what EngineData can't, e.g.
            // optical kerning; re-reads apply it like an import does.
            let txt2 = Self.txt2(doc).flatMap(PSDText.parseTxt2)
            var layers: [Layer] = []
            doc.forEachLayer { _, _, l in layers.append(l) }
            for l in layers {
                guard case let .text(t) = l.content else { continue }
                n += 1
                #expect(t.psdRaw != nil, "\(name)/\(l.name)")
                // An empty type layer keeps its one zero-length style run (font, size); photocraft's
                // `apply_txt2` drops it, fixed in PCIOText.
                #expect(!t.runs.isEmpty, "\(name)/\(l.name): no style runs parsed")
                #expect(min(t.runs.reduce(0) { $0 + $1.len }, t.text.utf8.count) == t.text.utf8.count, "\(name)/\(l.name): runs cover text")
                guard let st = t.runs.first?.style else { continue }
                #expect(st.sizePt > 0 && st.postscriptName != nil, "\(name)/\(l.name): \(st)")
                // Round trip of the model through our own TySh writer.
                let rebuilt = PSDText.buildTySh(t, dpi: doc.resolutionDpi, ink: nil)
                var back = try #require(PSDText.textLayer(fromTySh: rebuilt, dpi: doc.resolutionDpi), "\(name)/\(l.name)")
                if let txt2 { PSDText.applyTxt2(&back, tysh: rebuilt, txt2: txt2) }
                #expect(back.text == t.text, "\(name)/\(l.name)")
                #expect(back.charRuns() == t.charRuns(), "\(name)/\(l.name)")
                #expect(back.paragraphRuns() == t.paragraphRuns(), "\(name)/\(l.name)")
                #expect(back.shape == t.shape, "\(name)/\(l.name)")
            }
        }
        print("text layers: \(n)")
        #expect(n > 0)
    }

    /// Unedited text layers are written back byte-for-byte.
    @Test(.enabled(if: Corpus.available, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)")) func corpusTyShLossless() throws {
        var checked = 0
        for url in Corpus.files {
            let src = try PSDFile(contentsOf: url)
            guard src.layers.contains(where: { $0.block("TySh") != nil }) else { continue }
            let doc = try MapsKit.importFile([UInt8](try Data(contentsOf: url)), url.lastPathComponent, options: Self.options()).document
            let out = try PSDFile(bytes: MapsKit.export(doc, "out.psd", options: Self.options()).bytes)
            #expect(out.layers.count == src.layers.count, "\(url.lastPathComponent)")
            for (a, b) in zip(src.layers, out.layers) {
                guard let t = a.block("TySh") else { continue }
                checked += 1
                #expect(b.block("TySh")?.data == t.data, "\(url.lastPathComponent): \(a.displayName)")
            }
        }
        #expect(checked > 0)
    }

    /// An unedited save of a Photoshop-authored type file writes its `Txt2` back byte-for-byte
    /// (#2374: a regenerated `Txt2` made Photoshop refuse the re-saved file).
    @Test(.enabled(if: Corpus.available, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)")) func corpusPhotoshopTxt2SurvivesAnUneditedSave() throws {
        var checked = 0
        for url in Corpus.files {
            let name = url.lastPathComponent
            let doc = try MapsKit.importFile([UInt8](try Data(contentsOf: url)), name, options: Self.options()).document
            guard let before = Self.txt2(doc) else { continue }
            let out = try MapsKit.export(doc, name, options: Self.options()).bytes
            let back = try MapsKit.importFile(out, name, options: Self.options()).document
            #expect(Self.txt2(back) == before, "\(name): Txt2 changed on an unedited save")
            checked += 1
        }
        #expect(checked > 0, "no Photoshop type files with Txt2 in the corpus")
        print("Txt2 kept byte-for-byte in \(checked) Photoshop type files")
    }

    /// A text layer created in PhotoCraft (no PSD data) exports as an editable type layer and
    /// imports back with the same model.
    @Test(arguments: [false, true]) func createdTextLayerRoundtripsThroughPSD(_ photoshop: Bool) throws {
        var doc = Document(name: "t", size: PixelSize(width: 120, height: 80), mode: .rgb, depth: .u8)
        doc.resolutionDpi = 144
        let a = CharStyle(fontFamily: "Inter", sizePt: 10, color: .rgb(0.2, 0.4, 0.6))
        var b = a
        b.fauxBold = true
        b.underline = true
        b.tracking = 50
        b.leadingPt = 14
        var t = TextLayer(text: "Größe\nzwei")
        t.runs = [TextRun(len: 3, style: a), TextRun(len: 9, style: b)]
        var p1 = ParagraphStyle(align: .center)
        p1.spaceAfterPt = 3
        t.paragraphs = [ParagraphRun(len: 7, style: p1), ParagraphRun(len: 5, style: ParagraphStyle(align: .justifyAll))]
        t.shape = .box(.init(x: 0, y: 0, width: 100, height: 60))
        t.transform = .translate(8, 6)
        t.syncSummary()
        doc.layers.append(Layer(name: "t", content: .text(t)))
        let o = MapsKit.options(photoshop: photoshop)
        let out = try MapsKit.export(doc, "t.psd", options: o)
        #expect(!out.warnings.contains { $0.contains("text layer") }, "\(out.warnings)")
        let back = try MapsKit.importFile(out.bytes, "t.psd", options: o).document
        guard case let .text(bt)? = back.layers.first?.content else {
            Issue.record("not text")
            return
        }
        func strip(_ v: [TextRun]) -> [TextRun] {
            v.map { r in
                var r = r
                r.style.postscriptName = nil
                r.style.color.c = (r.style.color.c * 1000).rounded(.toNearestOrAwayFromZero) / 1000
                return r
            }
        }
        #expect(bt.text == t.text)
        #expect(strip(bt.charRuns()) == strip(t.charRuns()))
        #expect(bt.paragraphRuns() == t.paragraphRuns())
        #expect(bt.shape == t.shape)
        #expect(bt.transform == t.transform)
    }
}
