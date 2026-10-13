// Port of photocraft-io (crates/io/tests/large_psb.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Large PSB files (#375): planes past 2 GiB decode, and a channel that can't be decoded leaves its
// layer empty instead of painting it opaque black.

import Foundation
import PCDocument
import PCPSD
import Testing
@testable import PCIO

@Suite struct LargePSBTests {
    init() { ExportSweep.install() }
    /// A layer whose red channel is damaged: the warning says "treated as empty", and the layer must
    /// be empty, not opaque black (the transparency channel is still fine).
    @Test(arguments: [PSDVersion.psd, .psb]) func undecodableChannelLeavesTheLayerEmpty(_ version: PSDVersion) throws {
        var b = PSDKit.builder(4, 4, version: version)
        b.compression = .rle
        b.pushLayer(PSDLayerSpec(name: "Damaged", left: 0, top: 0, width: 4, height: 4, pixels: .u8([UInt8](repeating: 200, count: 64))))
        var file = try b.build()
        let red = try #require(file.layers[0].channels.firstIndex { $0.id == 0 })
        file.layers[0].channels[red].data = file.layers[0].channels[red].data.prefix(1)
        let (doc, warnings) = try PSDKit.psdToDocument(file)
        #expect(warnings.contains { $0.contains("Damaged") && $0.contains("could not be decoded") }, "\(warnings)")
        let s = try #require(doc.layers.first?.surface)
        #expect(s.pixel(x: 1, y: 1)[3] == 0, "\(version): the damaged layer must be transparent")
    }

    /// A flattened 29000² RGB PSB: its merged image decodes to 2.52 GB, past the old 2 GiB cap,
    /// which opened it as a document with no layers. Needs about 12 GB of memory, so it is opt-in
    /// like photocraft's `#[ignore]`d test: set `PCIO_BIG_PSB` and run in release.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PCIO_BIG_PSB"] != nil, "allocates ~12 GB; set PCIO_BIG_PSB"))
    func flattenedPSBWithAMergedImageOver2GiBOpens() throws {
        let side: UInt32 = 29_000
        let file = try PSDKit.mergedOnly(.psb, .rgb, 8, .rle, side, side)
        #expect(!file.imageData.data.isEmpty, "the generator could not encode the merged image")
        let (doc, warnings) = try PSDKit.psdToDocument(file)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(doc.layers.count == 1)
        let s = try #require(doc.layers.first?.surface)
        // patternPlane at 8 bits, channel c seeded with c.
        func want(_ x: Int, _ y: Int, _ c: Int) -> UInt8 { (x / 4 + y) % 3 == 0 ? UInt8(truncatingIfNeeded: c * 17) : UInt8(truncatingIfNeeded: x * 3 + y * 7 + c) }
        let n = Int(side)
        for (x, y) in [(0, 0), (n - 1, 0), (n / 2, n / 2), (n - 2, n - 1)] {
            let got = s.pixel(x: Int32(x), y: Int32(y))
            for c in 0 ..< 3 { #expect(UInt8((got[c] * 255).rounded()) == want(x, y, c), "(\(x), \(y)) channel \(c)") }
            #expect(got[3] == 1)
        }
    }
}
