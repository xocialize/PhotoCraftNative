// Port of photocraft-algo (crates/algo/src/blur.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct GaussianBoxTests {
    @Test func gaussianParity() throws {
        var worst: Float = 0
        for r: Float in [0.3, 1, 2.5, 4, 4.5, 9.3, 25] {
            worst = max(worst, try Parity.checkVariants(GaussianBlur(radius: r)))
        }
        ParityLog.record("GaussianBlur", worst)
    }

    @Test func boxParity() throws {
        var worst: Float = 0
        for r: Float in [1, 3, 5, 17, 40] {
            worst = max(worst, try Parity.checkVariants(BoxBlur(radius: r)))
        }
        ParityLog.record("BoxBlur", worst)
    }

    @Test func presetsParity() throws {
        let w = max(try Parity.checkVariants(BlurPreset(.blur)), try Parity.checkVariants(BlurPreset(.blurMore)))
        ParityLog.record("Blur/BlurMore", w)
    }

    /// photocraft `box_gaussian_matches_exact_kernel`: three boxes approximate σ 12 within 0.02.
    @Test func boxGaussianMatchesExactKernel() {
        let srcRect = PixelRect(x0: -60, y0: -60, x1: 180, y1: 68)
        var img = FloatImage(rect: srcRect, channels: 2)
        for y in srcRect.y0..<srcRect.y1 {
            for x in srcRect.x0..<srcRect.x1 {
                let i = img.index(x: x, y: y)
                img.data[i] = x < 60 ? 1 : 0
                img.data[i + 1] = 1
            }
        }
        let out = PixelRect(x0: 0, y0: 0, x1: 120, y1: 8)
        let k = BlurCore.gaussianKernel(12)
        let exact = BlurCore.convSep(img, out, k, k, true)
        let fast = BlurCore.boxPasses(img, out, true, BlurCore.boxesForGauss(12, 3))
        let err = zip(exact.data, fast.data).map { abs($0 - $1) }.max()!
        #expect(err < 0.02)
    }

    /// photocraft `box_passes_match_the_direct_box_kernel`.
    @Test func boxPassesMatchDirectKernel() {
        for r in [5, 17, 60] {
            let (w, h, m) = (40, 24, Int32(r + 2))
            let srcRect = PixelRect(x0: -m, y0: -m, x1: Int32(w) + m, y1: Int32(h) + m)
            let img = TestImage.make(srcRect, channels: 4, alpha: true, seed: 3)
            let out = PixelRect(x: 0, y: 0, width: w, height: h)
            let k = [Float](repeating: 1 / Float(2 * r + 1), count: 2 * r + 1)
            let direct = BlurCore.convSep(img, out, k, k, true)
            let fast = BoxBlur(radius: Float(r)).cpu(img, out: out, ctx: FilterContext(bounds: srcRect, mode: .rgb, alpha: true))
            #expect(Parity.maxError(direct, fast, alpha: true) < 1e-5, "radius \(r)")
        }
    }

    /// Results don't depend on the tiling: two halves equal the whole.
    @Test func tileIndependence() throws {
        let out = PixelRect(x: 0, y: 0, width: 64, height: 40)
        for f in [GaussianBlur(radius: 7)] {
            guard case .radius(let r) = f.halo(bounds: out) else { continue }
            let img = TestImage.make(out.outset(by: r + 20), channels: 4, alpha: true)
            let ctx = FilterContext(bounds: out, mode: .rgb, alpha: true)
            let whole = f.cpu(img, out: out, ctx: ctx)
            let left = PixelRect(x0: 0, y0: 0, x1: 30, y1: 40), right = PixelRect(x0: 30, y0: 0, x1: 64, y1: 40)
            let l = f.cpu(img.crop(left.outset(by: r)), out: left, ctx: ctx), rr = f.cpu(img.crop(right.outset(by: r)), out: right, ctx: ctx)
            for y in out.y0..<out.y1 {
                for x in out.x0..<out.x1 {
                    let part = x < 30 ? l : rr
                    for c in 0..<4 {
                        #expect(abs(whole.data[whole.index(x: x, y: y) + c] - part.data[part.index(x: x, y: y) + c]) < 1e-5)
                    }
                }
            }
        }
    }
}
