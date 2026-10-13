// Adjustment layers Photoshop can hold. Photoshop 27.11 opens an adjustment layer whose kind it
// doesn't offer in the document's mode and depth ("that content type is not supported for this
// color mode") as an empty pixel layer, and also a Color Lookup written with its table as
// `LUT3DFileData` without the colour profile Photoshop builds; a Color Lookup with no table chosen
// opens when written as Photoshop writes it. Measured by the Photoshop oracle (C′); new in the
// port. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCIOMaps
import PCPSD
import Testing
@testable import PCIO

@Suite struct AdjustmentAvailabilityTests {
    init() { ExportSweep.install() }

    /// The kinds Photoshop refused to create in the ps-corpus builder (its notes for
    /// `adj-stack-cmyk-8`, `-lab-8`, `-gray-16`, `-rgb-32`), and every other kind offered.
    @Test func theTableIsPhotoshopsBuilderNotes() {
        let all: [FourCC] = ["levl", "curv", "brit", "hue2", "blnc", "blwh", "mixr", "expA", "grdm", "nvrt", "phfl", "post", "selc", "thrs", "vibA", "clrL"]
        let refused: [(ColorMode, SampleType, Set<FourCC>)] = [
            (.cmyk, .u8, ["blwh", "expA", "vibA"]),
            (.lab, .u8, ["blwh", "mixr", "expA", "selc", "vibA"]),
            (.grayscale, .u16, ["hue2", "blnc", "blwh", "mixr", "phfl", "selc", "vibA", "clrL"]),
            (.rgb, .f32, ["grdm", "nvrt", "post", "thrs", "vibA"]),
            (.rgb, .u16, []),
            (.rgb, .u8, []),
        ]
        for (mode, depth, missing) in refused {
            for k in all { #expect(AdjustMap.photoshopOffers(k, mode: mode, depth: depth) == !missing.contains(k), "\(mode) \(depth) \(k.string)") }
        }
        #expect(!AdjustMap.photoshopOffers("hue ", mode: .grayscale, depth: .u8), "the legacy Hue/Saturation key too")
        #expect(AdjustMap.photoshopOffers("zzzz", mode: .lab, depth: .f32), "unknown keys are not judged")
    }

    /// Every kind in every mode/depth the export writes: a warning names the layer exactly when
    /// Photoshop will open it as a pixel layer, and the block is still written and read back.
    @Test(arguments: BlendModeAcceptanceTests.kinds.indices) func unofferedKindsWarnAndStillRoundTrip(_ i: Int) throws {
        let (mode, depth) = BlendModeAcceptanceTests.kinds[i]
        for (adj, _) in AdjustBlendRoundtripTests.adjustments() {
            if case .unsupported = adj { continue }
            guard let key = AdjustMap.psdKey(adj) else { continue }
            var d = Document(name: "a", size: PixelSize(width: 6, height: 4), mode: mode, depth: depth)
            d.layers = [rasterLayer("Background", d.pixelFormat, d.bounds, 1, false), Layer(name: "adj", content: .adjustment(adj))]
            let offered = AdjustMap.photoshopOffers(key, mode: mode, depth: depth)
            // What Photoshop can't hold (and a Color Lookup with a table, a known gap covered by
            // the other tests' exports) stays out of the acceptance set.
            var table = false
            if case let .colorLookup(c) = adj { table = c.lut != nil }
            let options = IOOptions(compositor: MapsKit.compositor)
            let r = offered && !table ? try DocumentIO.export(d, as: "a.psd", options: options)
                : try ExportSweep.excluded { try DocumentIO.export(d, as: "a.psd", options: options) }
            let warned = r.warnings.contains { $0.contains("\"adj\"") && $0.contains("opens the layer as an empty pixel layer") }
            #expect(warned == !offered, "\(mode) \(depth) \(key.string): \(r.warnings)")
            let rec = try #require(try PSDFile(bytes: r.bytes).layers.last)
            #expect(rec.block(key) != nil, "\(mode) \(depth) \(key.string): written")
        }
    }

    /// The generated test document (the acceptance exports' source) holds only what Photoshop
    /// offers, in every mode and depth.
    @Test(arguments: BlendModeAcceptanceTests.kinds.indices) func generatedDocumentsHoldOnlyOfferedAdjustments(_ i: Int) throws {
        let (mode, depth) = BlendModeAcceptanceTests.kinds[i]
        let r = try DocumentIO.export(genDoc(mode, depth, .all), as: "g.psd", options: photocraftOptions())
        let f = try PSDFile(bytes: r.bytes)
        let written: SampleType = f.header.depth == 32 ? .f32 : f.header.depth == 16 ? .u16 : .u8
        for rec in f.layers {
            guard let b = rec.blocks.first(where: { AdjustMap.adjustmentKeys.contains($0.key) }) else { continue }
            #expect(AdjustMap.photoshopOffers(b.key, mode: mode, depth: written), "\(mode) \(depth): \(b.key.string)")
        }
        #expect(!r.warnings.contains { $0.contains("empty pixel layer") }, "\(r.warnings)")
    }

    /// A Color Lookup with no table chosen is written as Photoshop writes it and read back as
    /// itself; Photoshop's own block reads as that lookup and is kept byte for byte.
    @Test func colorLookupWithoutATableIsPhotoshopsBlock() throws {
        let none = Adjustment.colorLookup(.init(name: "", lut: nil, size: 0, tetrahedral: false, dither: false))
        #expect(AdjustMap.write(none).map(\.key) == ["clrL"])
        #expect(AdjustMap.write(none).first?.data == AdjustMap.photoshopEmptyLookup)
        #expect(AdjustMap.parse("clrL", AdjustMap.photoshopEmptyLookup, nil, .rgb) == none)
        #expect(AdjustMap.unreadableReason("clrL", AdjustMap.photoshopEmptyLookup) == nil)
        guard let url = Corpus.psFiles.first(where: { $0.lastPathComponent == "adj-colorLookup.psd" }) else { return }
        let ps = try #require(try PSDFile(contentsOf: url).layers.first { $0.block("clrL") != nil }?.block("clrL"))
        #expect([UInt8](ps.data) == AdjustMap.photoshopEmptyLookup, "Photoshop's own block")
        let imp = try DocumentIO.importFile(contentsOf: url, options: IOOptions(compositor: StoredPixelsCompositor()))
        #expect(imp.document.layers.contains { $0.content == .adjustment(none) })
        #expect(!imp.warnings.contains { $0.contains("Color Lookup") }, "\(imp.warnings)")
    }

    /// A Color Lookup with a table: Photoshop opens it as a pixel layer (the colour profile it
    /// builds from the table isn't written), so the export says so; PCIO reads the table back.
    @Test func colorLookupWithATableWarns() throws {
        let lut: [Float] = (0 ..< 8).flatMap { i in [Float(i & 1), Float((i >> 1) & 1), Float((i >> 2) & 1)] }
        let adj = Adjustment.colorLookup(.init(name: "id.cube", lut: lut, size: 2, tetrahedral: false, dither: false))
        var d = Document(name: "a", size: PixelSize(width: 6, height: 4), mode: .rgb, depth: .u8)
        d.layers = [rasterLayer("Background", d.pixelFormat, d.bounds, 1, false), Layer(name: "lut", content: .adjustment(adj))]
        let r = try ExportSweep.excluded { try DocumentIO.export(d, as: "a.psd", options: IOOptions(compositor: StoredPixelsCompositor())) }
        #expect(r.warnings.contains { $0.contains("\"lut\"") && $0.contains("Color Lookup as an empty pixel layer") }, "\(r.warnings)")
        let back = try DocumentIO.importFile(name: "a.psd", bytes: r.bytes, options: IOOptions(compositor: StoredPixelsCompositor())).document
        #expect(back.layers.last?.content == .adjustment(adj))
    }

    /// The Photoshop oracle's C′ run (when its results are on disk): of every adjustment layer in
    /// the files Photoshop opened, the ones it turned into pixel layers are exactly the ones the
    /// table (plus a Color Lookup with a table) predicts, except fixtures damaged on purpose.
    /// The oracle's results: `PCIO_PS_ORACLE`, default `<fixtures>/ps-oracle`.
    static var oracleDirectory: URL? { Fixtures.directory("PCIO_PS_ORACLE", default: "ps-oracle") }

    @Test(.enabled(if: AdjustmentAvailabilityTests.oracleDirectory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("pcio-c2/pcio-c2.json").path) } ?? false,
                   "Photoshop oracle run C′ not present (set PHOTOCRAFT_FIXTURES or PCIO_PS_ORACLE)"))
    func photoshopOracleRunAgreesWithTheTable() throws {
        let root = try #require(Self.oracleDirectory).path
        let runs = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(root)/pcio-c2/pcio-c2.json"))) as? [[String: Any]] ?? []
        var layers = 0, pixel = 0, predicted = 0
        var disagree: [String] = []
        for e in runs {
            guard (e["opened"] as? Bool) == true, let name = e["file"] as? String,
                  let f = try? PSDFile(contentsOf: URL(fileURLWithPath: "\(root)/pcio-snapshot-c2/\(name)")) else { continue }
            let converted = Set((e["mismatches"] as? [[String: Any]] ?? []).filter {
                ($0["field"] as? String) == "kind" && (($0["pcpsd"] as? String) ?? "").hasPrefix("adjustment") && ($0["photoshop"] as? String) == "pixel"
            }.compactMap { $0["record"] as? Int })
            let mode: ColorMode = switch f.header.colorMode { case .grayscale: .grayscale; case .cmyk: .cmyk; case .lab: .lab; default: .rgb }
            let depth: SampleType = f.header.depth == 32 ? .f32 : f.header.depth == 16 ? .u16 : .u8
            for (i, r) in f.layers.enumerated() {
                guard let b = r.blocks.first(where: { AdjustMap.adjustmentKeys.contains($0.key) || $0.key == "hue " }) else { continue }
                layers += 1
                let table = b.key == "clrL" && [UInt8](b.data) != AdjustMap.photoshopEmptyLookup
                let expect = !AdjustMap.photoshopOffers(b.key, mode: mode, depth: depth) || table
                if converted.contains(i) { pixel += 1 }
                if expect { predicted += 1 }
                if expect != converted.contains(i) { disagree.append("\(name) #\(i) \(b.key.string)") }
            }
        }
        print("MEASURE oracle C′ adjustment layers: \(layers) in opened files; Photoshop made \(pixel) pixel layers; the table predicts \(predicted); disagreements \(disagree)")
        // The one exception: a truncated Levels block kept verbatim on purpose.
        #expect(disagree.allSatisfy { $0.hasPrefix("synthetic-unreadableAdjustmentsWarnOnOpen") }, "\(disagree)")
        #expect(layers > 1000 && pixel > 200)
    }
}
