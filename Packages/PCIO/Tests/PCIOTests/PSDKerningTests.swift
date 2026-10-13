// Port of photocraft-io (crates/io/tests/psd_kerning.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Kerning of PSD type layers (#206) through whole-file export and import: manual kerning in
// EngineData, the automatic mode in the document `Txt2`, and what a save does to `Txt2`. The
// TySh-level halves (EngineData pair fields, `hostile_kerning_values`, the `Txt2` builder) are
// PCIOTextTests' PSDKerningIOTests. Photocraft renders each layer before saving; PCIO has no font
// renderer here, so the layers are saved without pixels (the TySh carries the model).
// Not ported: `photoshop_kerning_oracles` (photocraft's Photoshop-authored corpus
// photoshop/text/kerning-*.psd, and glyph positions from a font engine).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
@testable import PCIOText
import PCPSD
import Testing
@testable import PCIO

@Suite struct PSDKerningTests {
    init() { ExportSweep.install() }
    /// Per character: (mode, manual kern).
    static func chars(_ t: TextLayer) -> [String] {
        var out: [String] = []
        let b = Array(t.text.utf8)
        var at = 0
        for r in t.charRuns() {
            let n = at + r.len <= b.count ? String(decoding: b[at ..< at + r.len], as: UTF8.self).unicodeScalars.count : 0
            out += Array(repeating: "\(r.style.kerning)/\(r.style.kern)", count: n)
            at += r.len
        }
        return out
    }

    static func layer(_ text: String, _ runs: [(Int, Kerning, Float)]) -> TextLayer {
        var t = TextLayer(text: text)
        t.runs = runs.map { len, kerning, kern in
            var s = CharStyle(fontFamily: "Inter", sizePt: 24)
            s.kerning = kerning
            s.kern = kern
            return TextRun(len: len, style: s)
        }
        t.syncSummary()
        return t
    }

    static func doc() -> Document { Document(name: "k", size: PixelSize(width: 64, height: 32), mode: .rgb, depth: .u8) }

    static func text(_ l: Layer) throws -> TextLayer {
        guard case let .text(t) = l.content else { throw PCIOError.unsupported("\(l.name) is not text") }
        return t
    }

    static func txt2(_ bytes: [UInt8]) throws -> PSDEngineData {
        let f = try PSDFile(bytes: bytes)
        let b = try #require(f.globalBlock("Txt2"), "Txt2 block")
        return try #require(PSDText.parseTxt2([UInt8](b.data)), "Txt2 parses")
    }

    /// The model survives a PSD round trip ("AVATAR Wave": +100 after A, -50 after T, characters
    /// 6..8 without automatic kerning).
    @Test(arguments: [false, true]) func manualAndOffKerningRoundTripThroughPSD(_ photoshop: Bool) throws {
        let o = MapsKit.options(photoshop: photoshop)
        let t = Self.layer("AVATAR Wave", [(1, .off, 100), (2, .metrics, 0), (1, .off, -50), (2, .metrics, 0), (3, .off, 0), (2, .metrics, 0)])
        var doc = Self.doc()
        doc.layers.append(Layer(name: "kerned", content: .text(t)))
        let bytes = try MapsKit.export(doc, "k.psd", options: o).bytes
        let back = try MapsKit.importFile(bytes, "k.psd", options: o).document
        #expect(Self.chars(try Self.text(back.layers[0])) == Self.chars(t))
    }

    /// Optical kerning lives only in the document `Txt2` block (#1348). Photoshop 27.11 refuses
    /// files with a `Txt2` PCIO generates, so until the offending field is known export writes
    /// none: Optical comes back as Metrics, and the export says so, naming the layers.
    @Test(arguments: [false, true]) func opticalKerningIsWrittenAsMetricsWithAWarning(_ photoshop: Bool) throws {
        let o = MapsKit.options(photoshop: photoshop)
        let t1 = Self.layer("AVATAR", [(4, .optical, 0), (2, .metrics, 0)])
        let t2 = Self.layer("Wave", [(2, .metrics, 0), (2, .optical, 0)])
        var doc = Self.doc()
        doc.layers = [Layer(name: "one", content: .text(t1)), Layer(name: "two", content: .text(t2))]
        let r = try MapsKit.export(doc, "k.psd", options: o)
        #expect(try PSDFile(bytes: r.bytes).globalBlock("Txt2") == nil)
        #expect(r.warnings.contains { $0.contains("\"one\", \"two\"") && $0.contains("Optical kerning is written as Metrics") }, "\(r.warnings)")
        let back = try MapsKit.importFile(r.bytes, "k.psd", options: o).document
        for (want, l) in zip([t1, t2], back.layers) {
            let metrics = Self.chars(want).map { $0.replacingOccurrences(of: "optical/", with: "metrics/") }
            #expect(Self.chars(try Self.text(l)) == metrics, "\(l.name)")
        }
    }

    /// No generated `Txt2` at all: neither for ordinary Metrics type (#3514: Photoshop never
    /// writes the empty stub, and Photopea rejects it) nor for Optical.
    @Test(arguments: [false, true]) func freshTextWritesNoTxt2Block(_ photoshop: Bool) throws {
        for kerning in [Kerning.metrics, .optical] {
            var doc = Self.doc()
            doc.layers.append(Layer(name: "t", content: .text(Self.layer("AV", [(2, kerning, 0)]))))
            let bytes = try MapsKit.export(doc, "k.psd", options: MapsKit.options(photoshop: photoshop)).bytes
            #expect(try PSDFile(bytes: bytes).globalBlock("Txt2") == nil, "\(kerning)")
        }
    }

    /// Two imported layers can name the same `Txt2` object: export renumbers the second preserved
    /// TySh so each layer keeps a `TextIndex` of its own.
    @Test(arguments: [false, true]) func duplicatePreservedTextIndicesGetDistinctNumbers(_ photoshop: Bool) throws {
        let o = MapsKit.options(photoshop: photoshop)
        var doc = Self.doc()
        for (name, text) in [("first", "AV"), ("second", "BC")] {
            var t = Self.layer(text, [(text.utf8.count, .metrics, 0)])
            t.psdRaw = try #require(PSDText.setTextIndex(PSDText.buildTySh(t, dpi: doc.resolutionDpi, ink: nil), 0))
            doc.layers.append(Layer(name: name, content: .text(t)))
        }
        let bytes = try MapsKit.export(doc, "k.psd", options: o).bytes
        let indices = try PSDFile(bytes: bytes).layers.compactMap { $0.block("TySh").flatMap { PSDText.textIndex([UInt8]($0.data)) } }
        #expect(indices.count == 2 && Set(indices).count == 2, "\(indices)")
        let back = try MapsKit.importFile(bytes, "k.psd", options: o).document
        #expect(back.layers.compactMap { l -> String? in if case let .text(t) = l.content { t.text } else { nil } } == ["AV", "BC"])
    }

    /// A file-controlled `TextIndex` must not size anything: Int32.max is renumbered and the
    /// document still saves and reopens with its text.
    @Test(arguments: [false, true]) func hostileTextIndexNeverSizesTheSave(_ photoshop: Bool) throws {
        let o = MapsKit.options(photoshop: photoshop)
        let t = Self.layer("AV", [(2, .metrics, 0)])
        var r = t
        r.psdRaw = try #require(PSDText.setTextIndex(PSDText.buildTySh(r, dpi: 72, ink: nil), .max))
        var doc = Self.doc()
        doc.layers.append(Layer(name: "hostile", content: .text(r)))
        let bytes = try MapsKit.export(doc, "k.psd", options: o).bytes
        let file = try PSDFile(bytes: bytes)
        #expect(file.globalBlock("Txt2") == nil)
        let index = try #require(file.layers.compactMap { $0.block("TySh").flatMap { PSDText.textIndex([UInt8]($0.data)) } }.first)
        #expect((0 ... 8).contains(index), "a file-controlled TextIndex survived: \(index)")
        let back = try MapsKit.importFile(bytes, "k.psd", options: o).document
        let b = try Self.text(back.layers[0])
        #expect(b.text == "AV")
        #expect(Self.chars(b) == Self.chars(t))
    }

    /// The file's own `Txt2` is kept, byte for byte with everything it holds beyond the style runs
    /// (`/21 /1` glyph pen positions), while the text is unchanged; once the text changes it is
    /// dropped with a warning rather than regenerated (Photoshop rebuilds it).
    @Test(arguments: [false, true]) func txt2IsKeptOnlyWhileTheTextIsUnchanged(_ photoshop: Bool) throws {
        let layer = Self.layer("AV", [(2, .metrics, 0)])
        var outer = try #require(PSDText.parseTxt2(PSDText.buildTxt2([(0, layer)], previous: nil)))
        outer.update("1") { list in
            list.update("1") { objects in
                guard var all = objects.arr, var first = all.first else { return }
                first.put("21", .d([("1", .array([.real(10), .real(20)]))]))
                all[0] = first
                objects = .array(all)
            }
        }
        let prev = PSDText.engineDataBareBytes(outer.entries ?? [])
        func save(_ text: String) throws -> ExportResult {
            var doc = Self.doc()
            doc.layers.append(Layer(name: "kept", content: .text(Self.layer(text, [(text.utf8.count, .metrics, 0)]))))
            doc.metadata.psdGlobalBlocks.append(PSDGlobalBlock(signature: "8BIM", key: "Txt2", data: prev))
            return try MapsKit.export(doc, "k.psd", options: MapsKit.options(photoshop: photoshop))
        }
        // The kept block is PCIO-built here (Photoshop refuses those): not swept.
        let kept = try ExportSweep.excluded { try save("AV") }
        #expect(try PSDFile(bytes: kept.bytes).globalBlock("Txt2").map { [UInt8]($0.data) } == prev, "unchanged text keeps the file's Txt2")
        let changed = try save("AX")
        #expect(try PSDFile(bytes: changed.bytes).globalBlock("Txt2") == nil, "changed text: no Txt2")
        #expect(changed.warnings.contains { $0.contains("Txt2") }, "\(changed.warnings)")
    }
}
