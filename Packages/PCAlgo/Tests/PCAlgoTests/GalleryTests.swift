// Port of photocraft-algo (crates/algo/src/gallery.rs, tests_iris.rs, tests_tilt_shift.rs, gallery/prepared_spin_tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct GalleryTests {
    let out = PixelRect(x: 3, y: -2, width: 48, height: 40)

    @Test func tiltShiftParity() throws {
        var w: Float = 0
        for f in [TiltShift(blur: 6), TiltShift(blur: 12, centerX: 0.3, centerY: 0.7, angle: 30, focus: 0.05, transition: 0.3),
                  TiltShift(blur: 0.2), TiltShift(blur: 3, angle: -80, focus: 0, transition: 0)] {
            w = max(w, try Parity.checkVariants(f, out: out))
        }
        ParityLog.record("TiltShift", w)
    }

    @Test func irisParity() throws {
        var w: Float = 0
        for f in [IrisBlur(), IrisBlur(pins: [IrisPin(x: 0.3, y: 0.4, radiusX: 0.2, radiusY: 0.3, angle: 25, roundness: 60, feather: 0.2, blur: 9),
                                              IrisPin(x: 0.8, y: 0.7, blur: 4)]), IrisBlur(pins: [])] {
            w = max(w, try Parity.checkVariants(f, out: out))
        }
        ParityLog.record("IrisBlur", w)
    }

    @Test func fieldParity() throws {
        var w: Float = 0
        for f in [FieldBlur(), FieldBlur(pins: [FieldPin(x: 0.1, y: 0.1, blur: 0), FieldPin(x: 0.9, y: 0.8, blur: 10)])] {
            w = max(w, try Parity.checkVariants(f, out: out))
        }
        ParityLog.record("FieldBlur", w)
    }

    @Test func spinParity() throws {
        var w: Float = 0
        for f in [SpinBlur(), SpinBlur(pins: [SpinPin(x: 0.3, y: 0.4, radiusX: 0.4, radiusY: 0.2, angle: 30, blurAngle: 90),
                                              SpinPin(x: 0.7, y: 0.6, radiusX: 0.2, radiusY: 0.3, blurAngle: 360)])] {
            w = max(w, try Parity.checkVariants(f, out: out))
        }
        ParityLog.record("SpinBlur", w)
    }

    @Test func pathParity() throws {
        var w: Float = 0
        for f in [PathBlur(), PathBlur(paths: [BlurPath(points: [SIMD2(0.1, 0.1), SIMD2(0.5, 0.6), SIMD2(0.9, 0.2)], speed: 30, taper: 50),
                                               BlurPath(points: [SIMD2(0.2, 0.9), SIMD2(0.8, 0.9)], speed: -12)])] {
            w = max(w, try Parity.checkVariants(f, out: out))
        }
        ParityLog.record("PathBlur", w)
    }

    /// photocraft: σ 0 at the iris centre leaves the pixel untouched; far outside it is the full blur.
    @Test func irisKeepsTheCentreSharp() {
        let b = PixelRect(x: 0, y: 0, width: 64, height: 64)
        let src = TestImage.make(b.outset(by: 40), channels: 4, alpha: true)
        let ctx = FilterContext(bounds: b, mode: .rgb, alpha: true)
        let res = IrisBlur(pins: [IrisPin(blur: 10)]).cpu(src, out: b, ctx: ctx)
        let i = res.index(x: 32, y: 32), j = src.index(x: 32, y: 32)
        for c in 0..<4 { #expect(abs(res.data[i + c] - src.data[j + c]) < 1e-5) }
    }

    @Test func levelWeightsPartitionUnity() {
        let lv = GalleryKit.levelSigmas(12)
        for s: Float in [0, 0.1, 0.375, 1, 5, 11.9, 12] {
            let total = (0..<lv.count).map { GalleryKit.weight(lv, $0, s) }.reduce(0, +)
            #expect(abs(total - 1) < 1e-5, "σ \(s)")
        }
    }
}

/// photocraft `iris_matches_frozen_kernel…` / `tilt_shift_matches_frozen_kernel…`: trimming each
/// level to the output plus its own reach leaves every output bit unchanged.
@Suite struct GalleryTrimTests {
    @Test func trimmedLevelsMatchFullWindows() {
        let out = PixelRect(x: 10, y: 5, width: 50, height: 37)
        let tsF = TiltShift(blur: 9, centerX: 0.4, angle: 20, focus: 0.05, transition: 0.2)
        guard case .radius(let r) = tsF.halo(bounds: out) else { return }
        for (ch, alpha) in [(4, true), (1, false), (5, true)] {
            let src = TestImage.make(out.outset(by: r), channels: ch, alpha: alpha, seed: 8, eightBit: false, hdr: true)
            let ctx = FilterContext.inferred(channels: ch, bounds: out)
            let g = tsF.geometry(ctx.bounds)
            let sigma: (Float, Float) -> Float = { x, y in g.smax * smoothstep(g.f0, g.f1, abs((x - g.cx) * g.nx + (y - g.cy) * g.ny) / g.ss) }
            let a = GalleryKit.variableBlur(src, out, ctx, g.smax, trim: true, sigma)
            let b = GalleryKit.variableBlur(src, out, ctx, g.smax, trim: false, sigma)
            #expect(a.data.map(\.bitPattern) == b.data.map(\.bitPattern), "\(ch) channels")
        }
    }
}
