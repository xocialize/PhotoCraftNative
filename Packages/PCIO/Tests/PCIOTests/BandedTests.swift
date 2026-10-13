// Port of photocraft-io (crates/io/tests/banded.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Exports that render the composite in bands (issue #49): results must equal the one-shot
// composite, across band boundaries, depths and alpha. The composite is PCRender's (photocraft:
// photocraft-compose); flat files go through the default `ImageIOCodec` (photocraft-codecs). Sizes
// are photocraft's.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import PCRender
import Testing
@testable import PCIO

@Suite(.serialized) struct BandedTests {
    init() { ExportSweep.install() }
    /// Two layers over more than one export band (a band is ~8 MP), with a gradient, so every row
    /// differs; `alpha` < 1 leaves the top-right translucent.
    static func layered(_ w: Int, _ h: Int, _ depth: SampleType, _ alpha: Float) -> Document {
        var d = Document(name: "b", size: PixelSize(width: w, height: h), mode: .rgb, depth: depth)
        let fmt = d.pixelFormat
        var bg = Surface(format: fmt)
        var row = [Float](repeating: 0, count: w * 4)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let a: Float = x > w / 2 && y < h / 2 ? alpha : 1
                row[x * 4] = Float(x) / Float(w)
                row[x * 4 + 1] = Float(y) / Float(h)
                row[x * 4 + 2] = 0.5
                row[x * 4 + 3] = a
            }
            bg.writeRegion(PixelRect(x0: 0, y0: Int32(y), x1: Int32(w), y1: Int32(y + 1)), row)
        }
        d.layers.append(Layer(name: "bg", content: .raster(bg)))
        var top = Layer.raster("top", format: fmt)
        top.withRaster { $0.fill(rect(10, 10, Int32(w) - 10, 40), with: [1, 0, 0, 1]) }
        top.opacity = 0.5
        d.layers.append(top)
        return d
    }

    static func compositeQ(_ d: Document, _ scale: Float, compositor: RenderCompositor? = nil) throws -> [Float] {
        let px = try compositor.map { try PSDKit.flatten(d, compositor: $0) } ?? PSDKit.flatten(d)
        return px.flatMap { p in (0 ..< 4).map { (min(max(p[$0], 0), 1) * scale).rounded() } }
    }

    static func decodedQ(_ img: DecodedImage, _ scale: Float) -> [Float] {
        let r = PixelRect(x0: 0, y0: 0, x1: Int32(img.width), y1: Int32(img.height))
        return img.surface.readRGBA(r).flatMap { p in (0 ..< 4).map { (p[$0] * scale).rounded() } }
    }

    @Test func layeredPNGExportSpansBands() throws {
        // 3000 × 3000 = 9 MP: two bands.
        for (depth, scale) in [(SampleType.u8, Float(255)), (.u16, 65535)] {
            for alpha: Float in [1, 0.5] {
                let d = BandedTests.layered(3000, 3000, depth, alpha)
                let r = try PSDKit.export(d, "x.png")
                let img = try ImageIOCodec().decode(r.bytes)
                #expect(img.hasAlpha == (alpha < 1), "\(depth) alpha \(alpha)")
                let got = BandedTests.decodedQ(img, scale)
                let want = try BandedTests.compositeQ(d, scale)
                #expect(got == want, "\(depth) alpha \(alpha): pixels differ (\(zip(got, want).filter { $0 != $1 }.count) samples)")
            }
        }
    }

    @Test func singleLayerNativeExportStripsOpaqueAlpha() throws {
        for alpha: Float in [1, 0.25] {
            var d = BandedTests.layered(700, 300, .u16, alpha)
            d.layers.removeLast(d.layers.count - 1)
            let r = try PSDKit.export(d, "x.tiff")
            let back = try PSDKit.importFile("x.tiff", r.bytes).document
            let (a, b) = (try #require(d.layers.first?.surface), try #require(back.layers.first?.surface))
            #expect(a.readRegion(d.bounds) == b.readRegion(d.bounds), "alpha \(alpha)")
            #expect(try ImageIOCodec().decode(r.bytes).hasAlpha == (alpha < 1), "alpha \(alpha)")
        }

        var d = BandedTests.layered(8, 4, .u16, 1)
        d.layers.removeLast(d.layers.count - 1)
        // A fractional edge exercises coverage rather than merely cropping raw samples.
        let edge = VectorPath([Subpath(closed: true, knots: [.corner(0, 0), .corner(4.5, 0), .corner(4.5, 4), .corner(0, 4)])])
        d.updateLayer(at: [0]) { $0.vectorMask = VectorMask(path: edge) }
        // Path coverage comes from the engine's rasterizer (PCPlatform); the default placeholder
        // reveals everything, so a rectangle-only stand-in supplies it.
        let compositor = RenderCompositor(rasterizer: PSDKit.RectCoverageRasterizer())
        var o = IOOptions()
        o.compositor = compositor
        let r = try PSDKit.export(d, "x.png", o)
        let img = try ImageIOCodec().decode(r.bytes)
        #expect(img.surface.format.sample == .u16)
        #expect(img.hasAlpha)
        #expect(BandedTests.decodedQ(img, 65535) == (try BandedTests.compositeQ(d, 65535, compositor: compositor)), "active vector mask: pixels differ")
    }

    @Test func psdMergedImageMatchesCompositeAndDropsNearOpaqueAlpha() throws {
        // Alpha 0.999 rounds to 255: no alpha channel, so the merged image must not be matted.
        for alpha: Float in [1, 0.999, 0.5] {
            let d = BandedTests.layered(400, 300, .u8, alpha)
            let file = PSDKit.documentToPSD(d)
            #expect(file.mergedHasAlpha == (alpha < 0.99), "alpha \(alpha)")
            let merged = try MergedImage.composite(file)
            let want = try PSDKit.flatten(d)
            var m: Float = 0
            for (a, b) in zip(merged, want) { for i in 0 ..< 4 { m = max(m, abs(a[i] - b[i])) } }
            // Un-matting divides the 8-bit rounding error by alpha.
            #expect(m <= 1 / (255 * alpha) + 1e-4, "alpha \(alpha): max diff \(m)")
        }
    }

    @Test func flatImportConvertsRGBInBands() throws {
        // An opaque RGB file becomes an RGBA document (converted in ~32 MB bands: 36 MB here).
        let (w, h) = (4000, 3000)
        let px = (0 ..< w * h * 3).map { UInt8($0 % 251) }
        let r = PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h))
        let src = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: false), rect: r, interleaved: px)
        let bytes = try ImageIOCodec().encode(src, rect: r, as: .png, quality: nil, iccProfile: nil)
        let doc = try PSDKit.importFile("x.png", bytes).document
        let s = try #require(doc.layers.first?.surface)
        #expect(s.format == .rgba8)
        let back = s.readInterleaved(doc.bounds)
        var rgb = [UInt8]()
        rgb.reserveCapacity(w * h * 3)
        var opaque = true
        for i in 0 ..< w * h {
            rgb += back[i * 4 ..< i * 4 + 3]
            if back[i * 4 + 3] != 255 { opaque = false }
        }
        #expect(rgb == px)
        #expect(opaque)
    }
}
