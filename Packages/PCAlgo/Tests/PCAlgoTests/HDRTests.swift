// Port of photocraft-algo's depth-agnostic contract (crates/algo/src/lib.rs; tests.rs `float_surfaces_keep_hdr_values`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Testing
@testable import PCAlgo
import PCFoundation

/// 32-bit float documents: values up to 4, nothing clamped, GPU vs CPU relative error.
@Suite struct HDRTests {
    @Test func blurSharpenNoiseOtherKeepHDR() throws {
        guard AlgoGPU.isAvailable else { return }
        let out = PixelRect(x: 2, y: 1, width: 45, height: 33)
        let filters: [any Filter] = [GaussianBlur(radius: 2), GaussianBlur(radius: 7), BoxBlur(radius: 6), MotionBlur(angle: 20, distance: 9),
                                     RadialBlur(amount: 15), SurfaceBlur(radius: 3, threshold: 20), SmartBlur(), LensBlur(radius: 5),
                                     ShapeBlur(radius: 6, shape: .star), UnsharpMask(amount: 120, radius: 2), HighPass(radius: 3), AddNoise(amount: 30),
                                     Median(radius: 2), Maximum(radius: 2, preserve: .roundness), CustomKernel(kernel: [1, 2, 1], scale: 4),
                                     TiltShift(blur: 5), IrisBlur(pins: [IrisPin(blur: 5)]), SpinBlur(), PathBlur(), ReduceNoise()]
        var worst: Float = 0
        for f in filters {
            func go<F: Filter>(_ f: F) throws {
                let r: Int32
                switch f.halo(bounds: out) { case .bounds: r = 0; case .radius(let h): r = h }
                let img = TestImage.make(out.outset(by: r), channels: 4, alpha: true, seed: 2, hdr: true)
                #expect(img.data.contains { $0 > 1.5 })
                let ctx = FilterContext(bounds: out, mode: .rgb, alpha: true)
                let cpu = try FilterEngine.apply(f, to: img, output: out, context: ctx, on: .cpu)
                if !(f is AddNoise) && !(f is HighPass) { #expect(cpu.data.contains { $0 > 1.2 }, "\(f.label) clamped HDR") }
                if let e = try Parity.check(f, src: img, out: out, ctx: ctx, tol: 1.0 / 255, relative: true) { worst = max(worst, e) }
            }
            try go(f)
        }
        ParityLog.record("HDR (relative, lead filters)", worst)
    }
}
