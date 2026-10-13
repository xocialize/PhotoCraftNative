// Port of photocraft-algo's parity contract at larger sizes (crates/algo/src/blur.rs, gallery.rs, noise.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// Larger images (opt-in: `PCALGO_STRESS=1`): rare threshold flips (interval counts, rim tests,
/// rank selection) only show up over many pixels.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PCALGO_STRESS"] != nil))
struct StressParityTests {
    @Test func leadFiltersAt512() throws {
        let out = PixelRect(x: -17, y: 9, width: 512, height: 384)
        let filters: [any Filter] = [RadialBlur(amount: 37, method: .spin, quality: .best, centerX: 0.31, centerY: 0.62),
                                     RadialBlur(amount: 80, method: .zoom, centerX: 0.7, centerY: 0.2), SpinBlur(pins: [SpinPin(radiusX: 0.4, radiusY: 0.35, blurAngle: 120)]),
                                     PathBlur(paths: [BlurPath(points: [SIMD2(0.1, 0.2), SIMD2(0.5, 0.9), SIMD2(0.9, 0.1)], speed: 40, taper: 30)]),
                                     IrisBlur(pins: [IrisPin(roundness: 50, blur: 12)]), LensBlur(radius: 11, depth: .transparency, focalDistance: 100, brightness: 50, threshold: 180, noise: 10),
                                     Median(radius: 4), SurfaceBlur(radius: 6, threshold: 30), SmartBlur(radius: 7, threshold: 20, quality: .high),
                                     GaussianBlur(radius: 33), UnsharpMask(amount: 300, radius: 2.5, threshold: 3), ReduceNoise(strength: 9, reduceColorNoise: 80, removeJpegArtifact: true)]
        for f in filters {
            func go<F: Filter>(_ f: F) throws {
                let r: Int32
                switch f.halo(bounds: out) { case .bounds: r = 0; case .radius(let h): r = h }
                let img = TestImage.make(out.outset(by: r), channels: 4, alpha: true, seed: 17)
                let e = try Parity.check(f, src: img, out: out, ctx: FilterContext(bounds: out, mode: .rgb, alpha: true))
                print("STRESS\t\(f.label)\t\(e ?? -1)")
            }
            try go(f)
        }
    }
}
