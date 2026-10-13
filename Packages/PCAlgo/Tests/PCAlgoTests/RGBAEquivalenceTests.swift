// Port of photocraft-algo's colour-model handling (crates/algo/src/fxutil.rs `rgba`/`set_rgba`, crates/raster to_rgba/from_rgba), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// `Filter.rgbaEquivalent`: for CMYK and Lab documents, the CPU reference must equal its sRGB
/// conversion filtered as RGB and converted back — the engine's GPU route for those documents.
@Suite struct RGBAEquivalenceTests {
    static let out = PixelRect(x: 2, y: 3, width: 37, height: 29)

    static func check<F: Filter>(_ f: F, mode: ColorMode, alpha: Bool) -> Float {
        let ch = mode.colorChannels + (alpha ? 1 : 0)
        let r: Int32
        switch f.halo(bounds: out) { case .bounds: r = 0; case .radius(let h): r = h }
        var src = TestImage.make(out.outset(by: r), channels: ch, alpha: alpha, seed: 6)
        if mode == .lab { for i in 0..<src.rect.area { src.data[i * ch] = 0.2 + 0.6 * src.data[i * ch] } }
        let ctx = FilterContext(bounds: out, mode: mode, alpha: alpha)
        let direct = f.cpu(src, out: out, ctx: ctx)
        let (rgb, rgbCtx) = FilterEngine.toRGBA(src, ctx)
        let back = FilterEngine.fromRGBA(f.cpu(rgb, out: out, ctx: rgbCtx), original: src.crop(out), ctx)
        return Parity.maxError(direct, back, alpha: alpha)
    }

    /// Every filter declaring `rgbaEquivalent` keeps the identity (and the GPU route agrees).
    @Test func declaredFiltersAreEquivalent() throws {
        for e in QA.catalog where e.filter.rgbaEquivalent {
            for (mode, alpha) in [(ColorMode.lab, false), (.lab, true), (.cmyk, false), (.cmyk, true)] {
                func go<F: Filter>(_ f: F) throws {
                    let err = Self.check(f, mode: mode, alpha: alpha)
                    #expect(err <= 2e-5, "\(f.label) \(mode)\(alpha ? "+A" : ""): \(err)")
                    let ch = mode.colorChannels + (alpha ? 1 : 0)
                    let ctx = FilterContext(bounds: Self.out, mode: mode, alpha: alpha)
                    if AlgoGPU.isAvailable && FilterEngine.rgbaRoundTrip(f, channels: ch, context: ctx) {
                        let r: Int32
                        switch f.halo(bounds: Self.out) { case .bounds: r = 0; case .radius(let h): r = h }
                        let src = TestImage.make(Self.out.outset(by: r), channels: ch, alpha: alpha, seed: 6)
                        _ = try Parity.check(f, src: src, out: Self.out, ctx: ctx)
                    }
                }
                try go(e.filter)
            }
        }
    }

    /// Survey (opt-in, `PCALGO_RGBA_SURVEY=1`): which joint filters satisfy the identity.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PCALGO_RGBA_SURVEY"] != nil))
    func survey() {
        for e in QA.catalog where e.filter.gpuChannels == .joint || !e.filter.supportsGPU(FilterContext(bounds: Self.out, mode: .lab, alpha: true), channels: 4) {
            var worst: Float = 0
            for (mode, alpha) in [(ColorMode.lab, false), (.lab, true), (.cmyk, false), (.cmyk, true)] {
                func go<F: Filter>(_ f: F) -> Float { Self.check(f, mode: mode, alpha: alpha) }
                worst = max(worst, go(e.filter))
            }
            print("RGBA-SURVEY\t\(type(of: e.filter))\t\(e.filter.label)\t\(worst)")
        }
    }
}

@Suite struct RGBARouteTests {
    @Test func labAndCMYKRouteThroughRGBOnTheGPU() throws {
        guard AlgoGPU.isAvailable else { return }
        let b = PixelRect(x: 0, y: 0, width: 20, height: 20)
        let lab = FilterContext(bounds: b, mode: .lab, alpha: true), cmyk = FilterContext(bounds: b, mode: .cmyk, alpha: true)
        #expect(FilterEngine.runsOnGPU(Desaturate(), channels: 4, context: lab))
        #expect(FilterEngine.runsOnGPU(HsbHsl(input: .rgb, output: .hsb), channels: 5, context: cmyk))
        #expect(!FilterEngine.runsOnGPU(SmartBlur(), channels: 5, context: cmyk))
        let src = TestImage.make(b, channels: 5, alpha: true, seed: 2)
        let (_, s) = try FilterEngine.applyMeasured(Desaturate(), to: src, context: cmyk, on: .auto)
        #expect(s.backend == .gpu)
    }
}
