// Every layer block PCIO generates is 4-aligned, the zero pad inside the length, as Photoshop
// writes all of its own (12,949 of 12,949 measured); Photoshop 27.11 refuses a file whose `grdm`
// isn't. Blocks kept verbatim from a file keep their bytes. New in the port; MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCIOMaps
import PCPSD
import Testing
@testable import PCIO

@Suite struct LayerBlockAlignmentTests {
    init() { ExportSweep.install() }

    static func alignmentIssues(_ bytes: [UInt8]) throws -> [String] {
        try PSDFile(bytes: bytes).compatibilityIssues(decodeChannels: false).filter { $0.rule == .layerBlockNotFourAligned }.map(\.description)
    }

    @Test(arguments: BlendModeAcceptanceTests.kinds.indices, PSDKit.conventions) func generatedBlocksAreFourAligned(_ i: Int, _ photoshop: Bool) throws {
        let (mode, depth) = BlendModeAcceptanceTests.kinds[i]
        var o = photocraftOptions()
        o.photoshopRecordConventions = photoshop
        let bytes = try DocumentIO.export(genDoc(mode, depth, .all), as: "a.psd", options: o).bytes
        #expect(try Self.alignmentIssues(bytes).isEmpty, "\(mode) \(depth)")
        for r in try PSDFile(bytes: bytes).layers {
            for b in r.blocks { #expect(b.data.count % 4 == 0, "\(mode) \(depth) \(r.displayName): \(b.key.string) is \(b.data.count) bytes") }
        }
    }

    /// The `grdm` Photoshop refused (126/146 bytes): written 4-aligned, read back the same.
    @Test(arguments: [2, 3, 7]) func gradientMapsAreFourAligned(_ stops: Int) throws {
        var d = Document(name: "g", size: PixelSize(width: 8, height: 4), mode: .rgb, depth: .u8)
        d.layers.append(rasterLayer("Background", d.pixelFormat, d.bounds, 3, false))
        let map = (0 ..< stops).map { k in GradientMapStop(Float(k) / Float(stops - 1), SIMD3(Float(k % 2), 0.5, Float(k) / Float(stops))) }
        let adj = Adjustment.gradientMap(.init(stops: map, reverse: false, dither: false))
        d.layers.append(Layer(name: "Map", content: .adjustment(adj)))
        #expect(AdjustMap.write(adj).first.map { $0.data.count % 4 != 0 } ?? false, "the bare writer's block is unaligned, as photocraft's")
        let bytes = try DocumentIO.export(d, as: "g.psd").bytes
        let grdm = try #require(try PSDFile(bytes: bytes).layers.lazy.compactMap { $0.block("grdm") }.first)
        #expect(grdm.data.count % 4 == 0, "\(grdm.data.count)")
        #expect(try PSDFile(bytes: bytes).compatibilityIssues(decodeChannels: true).filter { $0.severity == .error }.isEmpty)
        let back = try DocumentIO.importFile(name: "g.psd", bytes: bytes).document
        // What the unpadded block reads as (locations and colours quantised by the format).
        let expected = AdjustMap.parse("grdm", try #require(AdjustMap.write(adj).first).data, nil, .rgb)
        #expect(back.layers.last?.content == .adjustment(expected))
    }

    /// Blocks kept verbatim from a file keep their bytes (an odd one gains its pad byte, #200).
    @Test func preservedBlocksKeepTheirBytes() throws {
        var d = genDoc(.rgb, .u8, .pixels)
        d.layers[1].psdBlocks = [PSDLayerBlock(key: "Zzzz", data: [1, 2, 3, 4, 5, 6]), PSDLayerBlock(key: "Yyyy", data: [7])]
        let r = try #require(record(try PSDFile(bytes: try DocumentIO.export(d, as: "p.psd").bytes), d.layers[1].name))
        #expect(r.block("Zzzz").map { [UInt8]($0.data) } == [1, 2, 3, 4, 5, 6])
        #expect(r.block("Yyyy").map { [UInt8]($0.data) } == [7, 0])
    }
}
