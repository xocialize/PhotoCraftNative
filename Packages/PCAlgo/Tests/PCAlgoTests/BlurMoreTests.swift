// Port of photocraft-algo (crates/algo/src/blur.rs, blur/motion_tests.rs, blur/radial tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct MotionRadialTests {
    @Test func motionParity() throws {
        var w: Float = 0
        for (a, d): (Float, Float) in [(0, 1), (0, 9), (30, 7), (90, 12), (-45, 20), (137, 33.5), (200, 40), (10, 0.3)] {
            w = max(w, try Parity.checkVariants(MotionBlur(angle: a, distance: d)))
        }
        ParityLog.record("MotionBlur", w)
    }

    /// photocraft `motion_kernel_matches_the_per_pixel_samples`.
    @Test func motionKernelMatchesPerPixelSamples() {
        let srcRect = PixelRect(x0: -30, y0: -30, x1: 50, y1: 40)
        let img = TestImage.make(srcRect, channels: 4, alpha: true, seed: 11, eightBit: false)
        let out = PixelRect(x0: -12, y0: -6, x1: 30, y1: 22)
        for alpha in [true, false] {
            let ctx = FilterContext(bounds: srcRect, mode: .rgb, alpha: alpha)
            for (angle, distance): (Float, Float) in [(0, 1), (30, 7), (-45, 20), (137, 33.5)] {
                let fast = MotionBlur(angle: angle, distance: distance).cpu(img, out: out, ctx: ctx)
                let offs = MotionKit.offsets(angle, distance)
                var slow = FloatImage(rect: out, channels: 4)
                var tmp = [Float](repeating: 0, count: 4)
                for y in out.y0..<out.y1 {
                    for x in out.x0..<out.x1 {
                        var acc = [Float](repeating: 0, count: 4)
                        for (dx, dy) in offs {
                            img.samplePremul(Float(x) + 0.5 + dx, Float(y) + 0.5 + dy, .transparent, img.rect, alpha, &tmp)
                            let a: Float = alpha ? tmp[3] : 1
                            for c in 0..<4 { acc[c] += alpha && c < 3 ? tmp[c] * a : tmp[c] }
                        }
                        let k = 1 / Float(offs.count)
                        let i = slow.index(x: x, y: y)
                        for c in 0..<4 { slow.data[i + c] = acc[c] * k }
                        if alpha { let av = acc[3] * k; for c in 0..<3 { slow.data[i + c] = av > 1e-7 ? slow.data[i + c] / av : 0 } }
                    }
                }
                #expect(Parity.maxError(fast, slow, alpha: alpha) < 1e-5, "angle \(angle) distance \(distance)")
            }
        }
    }

    @Test func radialParity() throws {
        var w: Float = 0
        for m in RadialMethod.allCases {
            for q in RadialQuality.allCases {
                for (amount, cx, cy): (Float, Float, Float) in [(10, 0.5, 0.5), (100, 0.2, 0.8), (35, 1.3, -0.2)] {
                    w = max(w, try Parity.checkVariants(RadialBlur(amount: amount, method: m, quality: q, centerX: cx, centerY: cy),
                                                        out: PixelRect(x: 3, y: -2, width: 41, height: 33)))
                }
            }
        }
        ParityLog.record("RadialBlur", w)
    }

    @Test func radialIntervals() {
        #expect(RadialKit.intervals(.infinity, .draft) == 64)
        #expect(RadialKit.intervals(.infinity, .good) == 256)
        #expect(RadialKit.intervals(.infinity, .best) == 4096)
        #expect(RadialKit.intervals(.nan, .best) == 1)
    }
}
