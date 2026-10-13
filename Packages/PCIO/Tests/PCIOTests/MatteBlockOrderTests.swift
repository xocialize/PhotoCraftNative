// Merged transparency in 16/32-bit files, as Photoshop writes it (ps-corpus `transparent-*`): an
// empty `Mt16`/`Mt32` matte block first, then the `Lr16`/`Lr32` layer info with a positive layer
// count. Photoshop 27.11 refuses the file when the layer info comes before the matte block (PCPSD
// `layerInfoBeforeMatteBlock`). 8-bit files keep the negative layer count and no matte block.
// New in the port; MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import Testing
@testable import PCIO

@Suite struct MatteBlockOrderTests {
    init() { ExportSweep.install() }

    /// Two layers over nothing (the merged image has transparency) or over an opaque background.
    static func doc(_ depth: SampleType, background: Bool) -> Document {
        var d = Document(name: "matte", size: PixelSize(width: 12, height: 8), mode: .rgb, depth: depth)
        let fmt = d.pixelFormat
        if background { d.layers.append(rasterLayer("Background", fmt, d.bounds, 1, false)) }
        d.layers.append(rasterLayer("one", fmt, PixelRect(x0: 1, y0: 1, x1: 6, y1: 5), 2, true))
        d.layers.append(rasterLayer("two", fmt, PixelRect(x0: 4, y0: 2, x1: 10, y1: 7), 3, true))
        return d
    }

    static func globalKeys(_ f: PSDFile) -> [String] {
        var keys = f.globalBlocks.map(\.key.string)
        if case let .globalBlock(index, _, key, _, _) = f.layerInfoPlacement { keys.insert(key.string, at: min(index, keys.count)) }
        return keys
    }

    @Test(arguments: [SampleType.u8, .u16, .f32], PSDKit.conventions) func matteBlockPrecedesTheLayerInfo(_ depth: SampleType, _ photoshop: Bool) throws {
        var o = photocraftOptions()
        o.photoshopRecordConventions = photoshop
        for background in [false, true] {
            let d = Self.doc(depth, background: background)
            let bytes = try DocumentIO.export(d, as: "m.psd", options: o).bytes
            let f = try PSDFile(bytes: bytes)
            #expect(f.compatibilityIssues(decodeChannels: true).filter { $0.severity == .error }.isEmpty)
            #expect(!f.compatibilityIssues(decodeChannels: false).contains { $0.rule == .layerInfoBeforeMatteBlock })
            let keys = Self.globalKeys(f)
            let info = try #require(f.layerInfo)
            switch (depth, background) {
            case (.u8, _):
                #expect(!keys.contains { ["Mt16", "Mt32", "Mtrn"].contains($0) }, "\(keys)")
                #expect(info.mergedAlpha == !background)
            case (_, false):
                let (mt, lr) = depth == .u16 ? ("Mt16", "Lr16") : ("Mt32", "Lr32")
                #expect(Array(keys.prefix(2)) == [mt, lr], "\(depth): \(keys)")
                #expect(f.globalBlock(FourCC(mt))?.data.isEmpty == true)
                #expect(!info.mergedAlpha, "Photoshop's count is positive beside the matte block")
            case (_, true):
                #expect(!keys.contains { ["Mt16", "Mt32", "Mtrn"].contains($0) }, "\(depth): \(keys)")
            }
            #expect(f.mergedHasAlpha == !background, "\(depth) background \(background)")
            let back = try DocumentIO.importFile(name: "m.psd", bytes: bytes, options: IOOptions(compositor: StoredPixelsCompositor())).document
            #expect(back.layers.map(\.name) == d.layers.map(\.name))
        }
    }

    /// A kept matte block is never written ahead of (or beside) the regenerated one: another
    /// writer's `Mtrn`, or an `Mt16` that no longer matches an opaque merged image, is dropped.
    @Test func keptMatteBlocksAreReplaced() throws {
        for (background, kept) in [(false, "Mtrn"), (true, "Mt16"), (false, "Mt16")] {
            var d = Self.doc(.u16, background: background)
            d.metadata.psdGlobalBlocks = [PSDGlobalBlock(signature: "8BIM", key: PSDKey(kept), data: []), PSDGlobalBlock(signature: "8BIM", key: "Patt", data: [])]
            let f = try PSDFile(bytes: DocumentIO.export(d, as: "m.psd", options: IOOptions(compositor: MapsKit.compositor)).bytes)
            let keys = Self.globalKeys(f)
            #expect(keys == (background ? ["Lr16", "Patt"] : ["Mt16", "Lr16", "Patt"]), "\(kept) background \(background): \(keys)")
            #expect(f.mergedHasAlpha == !background)
        }
    }

    /// Photoshop's own transparent 16/32-bit files keep their layout through a round trip.
    @Test(.enabled(if: Corpus.psAvailable, "Photoshop corpus not present (set PHOTOCRAFT_FIXTURES or PCIO_PS_CORPUS)"))
    func photoshopTransparentFilesKeepTheirLayout() throws {
        for name in ["transparent-rgb-16.psd", "transparent-grayscale-16.psd", "transparent-rgb-32.psd"] {
            guard let url = Corpus.psFiles.first(where: { $0.lastPathComponent == name }) else { continue }
            let orig = try PSDFile(contentsOf: url)
            let doc = try DocumentIO.importFile(contentsOf: url, options: IOOptions(compositor: StoredPixelsCompositor())).document
            let f = try PSDFile(bytes: DocumentIO.export(doc, as: name, options: IOOptions(compositor: MapsKit.compositor)).bytes)
            #expect(Array(Self.globalKeys(f).prefix(2)) == Array(Self.globalKeys(orig).prefix(2)), "\(name)")
            #expect(f.layerInfo?.mergedAlpha == orig.layerInfo?.mergedAlpha, "\(name)")
            #expect(f.mergedHasAlpha, "\(name)")
        }
    }
}
