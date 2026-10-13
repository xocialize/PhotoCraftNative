// Port of photocraft-engine (crates/engine/src/extra_cmds.rs: clouds and its tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct RenderCloudsTests {
    @Test func cloudsParity() throws {
        var worst: Float = 0
        for difference in [false, true] {
            for (seed, size) in [(UInt32(0), PixelSize(width: 256, height: 256)), (3, PixelSize(width: 40, height: 30)),
                                 (0xdead_beef, PixelSize(width: 9000, height: 3000)), (77, PixelSize(width: 1200, height: 4000))] {
                worst = max(worst, try Parity.checkVariants(Clouds(seed: seed, difference: difference, foreground: SIMD4(0.9, 0.3, 0.1, 1),
                                                                   background: SIMD4(0.05, 0.2, 0.8, 1), documentSize: size)))
            }
        }
        // Far from the origin.
        worst = max(worst, try Parity.checkVariants(Clouds(seed: 5, difference: true), out: PixelRect(x: -7000, y: 12000, width: 60, height: 40)))
        ParityLog.record("Clouds/Difference Clouds", worst)
    }

    /// photocraft-engine `average_and_clouds` (the Clouds half): clouds vary, are smooth, and
    /// Difference Clouds over the same clouds cancels to black.
    @Test func cloudsVaryAreSmoothAndDifferenceCancels() throws {
        let r = PixelRect(x: 0, y: 0, width: 40, height: 30)
        let ctx = FilterContext(bounds: r, mode: .rgb, alpha: true)
        let size = PixelSize(width: 40, height: 30)
        let src = RenderTestKit.flat(SIMD4(0.5, 0.5, 0.5, 1))
        let clouds = Clouds(seed: 3, documentSize: size).cpu(src, out: r, ctx: ctx)
        let row = (0..<40).map { clouds.data[clouds.index(x: Int32($0), y: 12)] }
        #expect(row.max()! - row.min()! > 0.05, "clouds vary")
        #expect(zip(row, row.dropFirst()).allSatisfy { abs($0 - $1) < 0.2 }, "clouds are smooth")
        let diff = Clouds(seed: 3, difference: true, documentSize: size).cpu(clouds, out: r, ctx: ctx)
        let p = RenderTestKit.pixel(diff, 7, 7)
        #expect(p[0] < 0.01 && p[1] < 0.01 && p[2] < 0.01, "\(p)")
        #expect(p[3] == 1, "Difference Clouds keeps alpha")
    }

    /// The base wavelength follows the document size, clamped to 16…512.
    @Test func baseFollowsDocumentSize() {
        #expect(Clouds(documentSize: PixelSize(width: 256, height: 100)).base == 64)
        #expect(Clouds(documentSize: PixelSize(width: 20, height: 10)).base == 16)
        #expect(Clouds(documentSize: PixelSize(width: 100, height: 9000)).base == 512)
        #expect(Clouds().label == "Clouds" && Clouds(difference: true).label == "Difference Clouds")
    }

    /// Clouds are opaque and lie between the colours; Gray documents get the grey of the colour.
    @Test func cloudsLieBetweenColours() {
        let r = PixelRect(x: 0, y: 0, width: 33, height: 21)
        let img = TestImage.make(r, channels: 2, alpha: true)
        let out = Clouds(seed: 9, foreground: SIMD4(0.2, 0.2, 0.2, 1), background: SIMD4(0.6, 0.6, 0.6, 1))
            .cpu(img, out: r, ctx: FilterContext(bounds: r, mode: .grayscale, alpha: true))
        for i in 0..<r.area {
            #expect(out.data[i * 2] >= 0.2 - 1e-6 && out.data[i * 2] <= 0.6 + 1e-6)
            #expect(out.data[i * 2 + 1] == 1)
        }
    }
}
