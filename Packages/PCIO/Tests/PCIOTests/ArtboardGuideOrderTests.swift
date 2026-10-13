// Port of photocraft-io (crates/io/tests/artboard_guide_order.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Regression tests for issue #722: an artboard's `guideIndeces` must name the guides in resource
// 1032's own order. The export writes 1032 vertical first and then horizontal, but `guides_in`
// numbered horizontal first, so a document with guides of both orientations associated the
// artboard with the wrong guides. `guides_in_numbers_vertical_first_like_resource_1032` is
// PCIOMapsTests' CompsMapTests.guidesInNumbersVerticalFirstLikeResource1032; this is the
// whole-file half.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import Testing
@testable import PCIO

@Suite struct ArtboardGuideOrderTests {
    init() { ExportSweep.install() }
    static func docWithBoard(_ r: PixelRect) -> Document {
        var d = Document(name: "s", size: PixelSize(width: 100, height: 100), mode: .rgb, depth: .u8)
        var a = Layer.raster("A", format: PixelFormat(mode: .rgb, sample: .u8, alpha: true))
        a.withRaster { $0.fill(rect(1, 1, 2, 2), with: [1, 0, 0, 1]) }
        var g1 = Layer.group("Board", [a])
        g1.withGroup { $0.artboard = Artboard(rect: r, background: .white, preset: "") }
        d.layers = [g1]
        d.guides = Guides(horizontal: [90], vertical: [20])
        return d
    }

    @Test(arguments: [false, true]) func exportedArtboardIndicesMatchGuidesResource(_ photoshop: Bool) throws {
        let d = Self.docWithBoard(rect(10, 0, 30, 50))
        let bytes = try MapsKit.export(d, "x.psd", options: MapsKit.options(photoshop: photoshop)).bytes
        let f = try PSDFile(bytes: bytes)
        let res = [UInt8](try #require(f.resources.first { $0.id == 1032 }, "guides resource").data)
        // 1032: version(4) hRes(4) vRes(4) count(4), then 5 bytes per guide: loc(4) dir(1).
        let n = Int(MapsKit.be32(res, 12))
        let order = (0 ..< n).compactMap { i in 16 + i * 5 + 4 < res.count ? res[16 + i * 5 + 4] : nil }
        #expect(order == [0, 1], "1032 must be vertical-first")

        let artb = try #require(MapsKit.layerBlock(f, "Board", "artb"), "artb block")
        // Find guideIndeces in the descriptor bytes: key(12) + type(4) + count(4) + elements.
        let key = Array("guideIndeces".utf8)
        let pos = try #require((0 ... artb.count - key.count).first { Array(artb[$0 ..< $0 + key.count]) == key }, "guideIndeces key")
        #expect(MapsKit.be32(artb, pos + 16) == 1, "exactly one guide inside the board")
        // element: type(4) + int(4)
        #expect(Int32(bitPattern: MapsKit.be32(artb, pos + 24)) == 0, "the inside guide is the vertical one, 1032 index 0")
    }

    /// Artboards are written as Photoshop writes them (ps-corpus `artboard-blend.psd`): Normal in
    /// the record and the section divider, `lnsr` `artb`, `artb` before `fxrp`; a Pass Through
    /// artboard (the model's default) is written as Normal with a warning. A plain Pass Through
    /// group keeps `pass` in its divider and Normal in its record, as Photoshop's groups do.
    @Test func artboardsAreWrittenAsPhotoshopWritesThem() throws {
        var d = Self.docWithBoard(rect(10, 0, 30, 50))
        d.layers[0].blend = .passThrough
        d.layers.append(Layer.group("Group", [Layer.raster("B", format: PixelFormat(mode: .rgb, sample: .u8, alpha: true))]))
        d.layers[1].blend = .passThrough
        let r = try MapsKit.export(d, "x.psd", options: MapsKit.options(photoshop: true))
        #expect(r.warnings.contains { $0.contains("artboard \"Board\"") && $0.contains("written as Normal") }, "\(r.warnings)")
        let f = try PSDFile(bytes: r.bytes)
        let board = try #require(f.layers.first { $0.displayName == "Board" })
        #expect(board.blendMode.key == "norm")
        #expect(board.sectionDivider?.blendMode?.key == "norm")
        #expect(board.block("lnsr").map { [UInt8]($0.data) } == Array("artb".utf8))
        let keys = board.blocks.map(\.key)
        #expect(try #require(keys.firstIndex(of: "artb")) < #require(keys.firstIndex(of: "fxrp")), "\(keys.map(\.string))")
        let group = try #require(f.layers.first { $0.displayName == "Group" })
        #expect(group.blendMode.key == "norm" && group.sectionDivider?.blendMode?.key == "pass")
        #expect(group.block("lnsr").map { [UInt8]($0.data) } == Array("lset".utf8))
        // Read back: the artboard is Normal, the group still Pass Through.
        let back = try MapsKit.importFile(r.bytes, "x.psd").document
        #expect(back.layers[0].blend == .normal && back.layers[1].blend == .passThrough)
    }

    /// Photoshop's own artboard file comes back with its artboards' records unchanged.
    @Test(.enabled(if: Corpus.psFiles.contains { $0.lastPathComponent == "artboard-blend.psd" }, "artboard-blend.psd not present (set PHOTOCRAFT_FIXTURES or PCIO_PS_CORPUS)"))
    func photoshopArtboardsRoundTrip() throws {
        let url = try #require(Corpus.psFiles.first { $0.lastPathComponent == "artboard-blend.psd" })
        let orig = try PSDFile(contentsOf: url)
        let doc = try DocumentIO.importFile(contentsOf: url, options: IOOptions(compositor: StoredPixelsCompositor())).document
        // The default compositor (PCRender): the merged image must show "Mul" multiplied. The
        // stored-pixels stand-in blends everything as Normal (C‴ found its merged image off by
        // Normal − Multiply in that square).
        let r = try DocumentIO.export(doc, as: "artboard-blend.psd", options: IOOptions())
        #expect(!r.warnings.contains { $0.contains("artboard") }, "\(r.warnings)")
        let f = try PSDFile(bytes: r.bytes)
        for name in ["Artboard 1", "Artboard 2", "Group"] {
            let a = try #require(orig.layers.first { $0.displayName == name }), b = try #require(f.layers.first { $0.displayName == name })
            #expect(a.blendMode == b.blendMode && a.sectionDivider == b.sectionDivider, "\(name)")
            if name != "Group" {
                #expect(a.blocks.map(\.key) == b.blocks.map(\.key), "\(name): \(a.blocks.map(\.key.string)) vs \(b.blocks.map(\.key.string))")
            }
        }
    }
}
