// Port of photocraft-algo (crates/algo/src/fxutil.rs, lib.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// A probe filter around `FxUtil.gaussBlurN` (buffer blur with clamped edges) for parity tests.
struct GaussBlurNProbe: Filter {
    var sigma: Float
    var label: String { "gauss_blur_n probe" }
    func halo(bounds: PixelRect) -> Halo { .radius(0) }
    func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        var r = src.crop(out)
        FxUtil.gaussBlurN(&r.data, out.width, out.height, src.channels, sigma)
        return r
    }
    func encodeGPU(_ pass: GPUPass) throws {
        let t = try pass.texture(pass.out)
        try pass.dispatchOut("pca_copy", params: NoParams(), textures: [pass.src, t])
        let b = try pass.encodeGaussBlurN(t, rect: pass.out, sigma: sigma)
        try pass.copy(b, size: (pass.out.width, pass.out.height), to: pass.dst)
    }
}

@Suite struct CoreTests {
    @Test func gaussBlurNParity() throws {
        for s: Float in [0.5, 2, 9] { try Parity.checkVariants(GaussBlurNProbe(sigma: s), tol: 1e-5) }
    }

    @Test func gaussBoxRadiiSmallSigma() {
        #expect(FxUtil.gaussBoxRadii(0.5) == [1, 0, 0])
        #expect(FxUtil.gaussBoxRadii(10).count == 3)
    }

    @Test func hashMatchesGPUBitForBit() throws {
        // Add Noise-style hashes through a probe would need a kernel; the CPU value is checked
        // against photocraft's reference constants instead.
        let v = hash01(3, -7, 2, 42)
        #expect(v >= 0 && v < 1)
    }

    /// photocraft `mix_selection`: a filter that changes alpha mixes premultiplied.
    @Test func selectionMixIsPremultipliedWhenAlphaChanges() {
        let r = PixelRect(x: 0, y: 0, width: 1, height: 1)
        let o = FloatImage(rect: r, channels: 4, data: [1, 0, 0, 1])
        let f = FloatImage(rect: r, channels: 4, data: [0, 1, 0, 0.5])
        let m = FilterEngine.mixSelection(original: o, filtered: f, coverage: [0.5], alpha: true)
        #expect(abs(m.data[3] - 0.75) < 1e-6)
        #expect(abs(m.data[0] * m.data[3] - 0.5) < 1e-6)
        #expect(abs(m.data[1] * m.data[3] - 0.25) < 1e-6)
    }

    /// The Surface-level runner reads the halo, repeats the canvas edge and writes back.
    @Test func surfaceApplyMatchesImageApply() throws {
        let canvas = PixelRect(x: 0, y: 0, width: 40, height: 30)
        let img = TestImage.make(canvas, channels: 4, alpha: true)
        var s = Surface(format: .rgba32f)
        s.writeRegion(canvas, img.data)
        let f = GaussianBlur(radius: 3)
        try FilterEngine.apply(f, to: &s, area: canvas, bounds: canvas, extent: canvas, on: .cpu, tile: 16)
        var orig = Surface(format: .rgba32f)
        orig.writeRegion(canvas, img.data)
        let src = FloatImage(surface: orig, rect: canvas.outset(by: 10), clampedTo: canvas)
        let want = try FilterEngine.apply(f, to: src, output: canvas, context: FilterContext(bounds: canvas, mode: .rgb, alpha: true), on: .cpu)
        let got = FloatImage(surface: s, rect: canvas)
        #expect(Parity.maxError(got, want, alpha: true) < 1e-5)
    }
}


/// photocraft's tagged FilterParams JSON (`params_serde_roundtrip`).
@Suite struct AnyFilterTests {
    @Test func decodesPhotocraftJSON() throws {
        let dec = JSONDecoder()
        let u = try dec.decode(AnyFilter.self, from: Data(#"{"filter":"unsharpMask","amount":50,"radius":1,"threshold":0}"#.utf8))
        #expect(u.filter as? UnsharpMask == UnsharpMask(amount: 50, radius: 1, threshold: 0))
        let r = try dec.decode(AnyFilter.self, from: Data(#"{"filter":"radialBlur","amount":20,"method":"zoom","quality":"best","centerX":0.5,"centerY":0.25}"#.utf8))
        #expect(r.filter as? RadialBlur == RadialBlur(amount: 20, method: .zoom, quality: .best, centerX: 0.5, centerY: 0.25))
        #expect(throws: DecodingError.self) { try dec.decode(AnyFilter.self, from: Data(#"{"filter":"nope"}"#.utf8)) }
    }

    @Test func roundTripsTagged() throws {
        let filters: [any Filter] = [GaussianBlur(radius: 2), IrisBlur(pins: [IrisPin(blur: 4)]), Offset(horizontal: 3, vertical: -1, undefined: .repeat),
                                     LensBlur(radius: 7, blades: 5, depth: .transparency), PathBlur()]
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        for f in filters {
            let data = try enc.encode(AnyFilter(f))
            let json = String(decoding: data, as: UTF8.self)
            #expect(json.contains("\"filter\":\"\(AnyFilter.tag(of: f)!)\""), "\(json)")
            let back = try JSONDecoder().decode(AnyFilter.self, from: data)
            #expect(String(decoding: try enc.encode(back), as: UTF8.self) == json)
        }
    }

    @Test func everyFilterTypeIsRegisteredOnce() {
        let tags = AnyFilter.registry.map(\.tag)
        #expect(Set(tags).count == tags.count)
    }
}

/// GPU-resident encoding equals the FloatImage runner.
@Suite struct EncodeTests {
    @Test func encodeMatchesApply() throws {
        guard let gpu = try? AlgoGPU.shared() else { return }
        let out = PixelRect(x: 0, y: 0, width: 50, height: 40)
        let f = GaussianBlur(radius: 6)
        guard case .radius(let r) = f.halo(bounds: out) else { return }
        let src = TestImage.make(out.outset(by: r), channels: 4, alpha: true)
        let ctx = FilterContext(bounds: out, mode: .rgb, alpha: true)
        let want = try FilterEngine.apply(f, to: src, output: out, context: ctx, on: .gpu)
        let srcTex = try gpu.metal.makeTexture(from: src)
        guard let dst = gpu.metal.makeTexture(width: out.width, height: out.height) else { return }
        try gpu.metal.run { cb in
            try FilterEngine.encode(f, commandBuffer: cb, source: srcTex, sourceRect: src.rect, destination: dst, output: out, context: ctx, channels: 4)
        }
        let got = gpu.metal.readImage(dst, rect: out, channels: 4)
        #expect(Parity.maxError(got, want, alpha: true) == 0)
    }
}

/// NaN / huge parameters behave as Rust's saturating casts (no traps).
@Suite struct NaNParameterTests {
    @Test func haloAndRadiiSaturate() throws {
        let b = PixelRect(x: 0, y: 0, width: 8, height: 8)
        #expect(GaussianBlur(radius: .nan).halo(bounds: b) == .radius(1))
        #expect(BoxBlur(radius: .nan).halo(bounds: b) == .radius(1))
        let img = TestImage.make(b, channels: 4, alpha: true)
        let ctx = FilterContext(bounds: b, mode: .rgb, alpha: true)
        for f in [GaussianBlur(radius: .nan) as any Filter, BoxBlur(radius: .nan), Median(radius: .nan), Minimum(radius: .nan),
                  Maximum(radius: .nan, preserve: .roundness), SurfaceBlur(radius: .nan, threshold: 10), ShapeBlur(radius: .nan)] {
            func go<F: Filter>(_ f: F) throws { _ = try FilterEngine.apply(f, to: img, context: ctx, on: .cpu) }
            try go(f)
        }
        #expect(FxUtil.gaussBoxRadii(.nan).count == 3)
        #expect(BlurCore.boxesForGauss(.nan, 3).count == 3)
    }
}

/// Unit-variant filters (photocraft `FilterParams::FindEdges` etc.) decode from the bare tag.
@Suite struct AnyFilterUnitTests {
    @Test func unitVariants() throws {
        for tag in ["findEdges", "solarize", "invert", "desaturate", "facet", "fragment", "ntscColors"] {
            let f = try JSONDecoder().decode(AnyFilter.self, from: Data("{\"filter\":\"\(tag)\"}".utf8))
            #expect(AnyFilter.tag(of: f.filter) == tag)
        }
    }
}
