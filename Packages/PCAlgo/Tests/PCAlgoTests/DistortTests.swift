// Port of photocraft-algo (crates/algo/src/distort.rs, tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// Shared helpers of the distortion tests.
enum DistortTestKit {
    /// The source covers more than the bounds (as the Surface-level runner reads `bounds ∪ area`),
    /// and the output is a tile that straddles the bounds' edge: exercises edge policies relative
    /// to the bounds (not the source) and samples beyond the source.
    static func offBoundsCases<F: Filter>(_ f: F, sourceLocation: SourceLocation = #_sourceLocation) throws -> Float {
        let bounds = PixelRect(x: 5, y: 4, width: 50, height: 37)
        let srcRect = PixelRect(x: -6, y: -3, width: 70, height: 52)
        let outs = [bounds, PixelRect(x: 30, y: 20, width: 34, height: 28), PixelRect(x: -4, y: -2, width: 20, height: 15)]
        var worst: Float = 0
        for (img, ctx0) in TestImage.variants(srcRect, seed: 4) {
            var ctx = ctx0
            ctx.bounds = bounds
            for o in outs {
                if let e = try Parity.check(f, src: img, out: o, ctx: ctx, sourceLocation: sourceLocation) { worst = max(worst, e) }
            }
        }
        return worst
    }

    /// `FloatImage.samplePremul` (core, photocraft `Image::sample`) as an independent reference
    /// for `DistortKit.remap`.
    static func referenceRemap(_ src: FloatImage, _ out: PixelRect, _ ctx: FilterContext, _ edge: EdgeMode,
                               _ f: (Float, Float) -> (Float, Float)) -> FloatImage {
        var res = FloatImage(rect: out, channels: src.channels)
        var tmp = [Float](repeating: 0, count: src.channels)
        for y in out.y0..<out.y1 {
            for x in out.x0..<out.x1 {
                let (sx, sy) = f(Float(x) + 0.5, Float(y) + 0.5)
                src.samplePremul(sx, sy, edge, ctx.bounds, ctx.alpha, &tmp)
                let i = res.index(x: x, y: y)
                for c in 0..<src.channels { res.data[i + c] = tmp[c] }
            }
        }
        return res
    }
}

@Suite struct DistortTests {
    @Test func twirlParity() throws {
        var worst: Float = 0
        for a: Float in [0, 50, -90, 360, 999, -999] { worst = max(worst, try Parity.checkVariants(Twirl(angle: a))) }
        worst = max(worst, try DistortTestKit.offBoundsCases(Twirl(angle: 140)))
        ParityLog.record("Twirl", worst)
    }

    @Test func pinchParity() throws {
        var worst: Float = 0
        for a: Float in [0, 50, -50, 100, -100, 250] { worst = max(worst, try Parity.checkVariants(Pinch(amount: a))) }
        worst = max(worst, try DistortTestKit.offBoundsCases(Pinch(amount: 75)))
        ParityLog.record("Pinch", worst)
    }

    @Test func spherizeParity() throws {
        var worst: Float = 0
        for m in SpherizeMode.allCases {
            for a: Float in [0, 100, -100, 60, -60, 300] { worst = max(worst, try Parity.checkVariants(Spherize(amount: a, mode: m))) }
            worst = max(worst, try DistortTestKit.offBoundsCases(Spherize(amount: 80, mode: m)))
        }
        ParityLog.record("Spherize", worst)
    }

    @Test func waveParity() throws {
        var worst: Float = 0
        for t in WaveType.allCases {
            for u in UndefinedAreas.allCases {
                worst = max(worst, try Parity.checkVariants(Wave(waveType: t, undefined: u, seed: 3)))
                worst = max(worst, try Parity.checkVariants(Wave(generators: 3, wavelengthMin: 5, wavelengthMax: 20, amplitudeMin: 1,
                                                                 amplitudeMax: 4, waveType: t, undefined: u, seed: 9)))
                worst = max(worst, try DistortTestKit.offBoundsCases(Wave(generators: 2, wavelengthMin: 7, wavelengthMax: 40,
                                                                          amplitudeMin: 3, amplitudeMax: 18, waveType: t, undefined: u, seed: 1)))
            }
        }
        // Edge cases: one generator, generators clamped to 64, min > max, wavelength below 1.
        worst = max(worst, try Parity.checkVariants(Wave(generators: 1, wavelengthMin: 30, wavelengthMax: 30, amplitudeMin: 10, amplitudeMax: 10)))
        worst = max(worst, try Parity.checkVariants(Wave(generators: 999, seed: 5)))
        worst = max(worst, try Parity.checkVariants(Wave(generators: 4, wavelengthMin: 50, wavelengthMax: 3, amplitudeMin: 40, amplitudeMax: 2)))
        worst = max(worst, try Parity.checkVariants(Wave(generators: 2, wavelengthMin: 0.2, wavelengthMax: 0.5, amplitudeMin: 2, amplitudeMax: 3, waveType: .triangle)))
        // Square waves are hard thresholds on rem_euclid(phase, τ): a large area with short
        // wavelengths puts thousands of pixels next to an edge (needs the exact GPU fmod).
        let big = PixelRect(x: -37, y: 11, width: 400, height: 300)
        worst = max(worst, try Parity.checkVariants(Wave(generators: 9, wavelengthMin: 2, wavelengthMax: 13, amplitudeMin: 3,
                                                         amplitudeMax: 30, waveType: .square, undefined: .wrap, seed: 21), out: big))
        ParityLog.record("Wave", worst)
    }

    @Test func rippleParity() throws {
        var worst: Float = 0
        for s in RippleSize.allCases {
            for a: Float in [0, 100, -100, 999, -999] { worst = max(worst, try Parity.checkVariants(Ripple(amount: a, size: s))) }
            worst = max(worst, try DistortTestKit.offBoundsCases(Ripple(amount: 250, size: s)))
        }
        ParityLog.record("Ripple", worst)
    }

    @Test func polarParity() throws {
        var worst: Float = 0
        for m in PolarMode.allCases {
            worst = max(worst, try Parity.checkVariants(PolarCoordinates(mode: m)))
            worst = max(worst, try Parity.checkVariants(PolarCoordinates(mode: m), out: PixelRect(x: 0, y: 0, width: 41, height: 41)))
            worst = max(worst, try DistortTestKit.offBoundsCases(PolarCoordinates(mode: m)))
        }
        ParityLog.record("Polar Coordinates", worst)
    }

    /// The fast sampler behind `remap` equals photocraft `Image::sample` (core `samplePremul`) for
    /// every edge policy, including positions far outside the bounds and the source.
    @Test func remapMatchesImageSample() {
        let bounds = PixelRect(x: 2, y: 1, width: 23, height: 17)
        let src = TestImage.make(PixelRect(x: -3, y: -2, width: 30, height: 22), channels: 4, alpha: true, seed: 7)
        let out = PixelRect(x: -8, y: -6, width: 45, height: 33)
        let ctx = FilterContext(bounds: bounds, mode: .rgb, alpha: true)
        let map: (Float, Float) -> (Float, Float) = { x, y in (x * 1.37 - 9.3 + sinf(y * 0.4) * 6, y * 1.21 - 5.1 + cosf(x * 0.3) * 7) }
        for edge in [EdgeMode.transparent, .repeatEdge, .wrap] {
            for (img, c) in [(src, ctx), (TestImage.make(src.rect, channels: 3, alpha: false), FilterContext(bounds: bounds, mode: .rgb, alpha: false))] {
                let fast = DistortKit.remap(img, out, c, edge, map)
                let ref = DistortTestKit.referenceRemap(img, out, c, edge, map)
                #expect(fast.data == ref.data, "\(edge)")
            }
        }
    }

    /// photocraft `distortions_are_identity_at_zero` (the Rust test compares 8-bit surfaces; in
    /// float the premultiply/unpremultiply round trip may move the last bit).
    @Test func identityAtZero() throws {
        let r = PixelRect(x: 0, y: 0, width: 40, height: 30)
        let img = TestImage.make(r, channels: 4, alpha: true)
        let ctx = FilterContext(bounds: r, mode: .rgb, alpha: true)
        let filters: [any Filter] = [Twirl(angle: 0), Pinch(amount: 0), Spherize(amount: 0), Ripple(amount: 0, size: .large)]
        for f in filters {
            let out = f.cpu(img, out: r, ctx: ctx)
            #expect(Parity.maxError(out, img, alpha: true) < 1e-6, "\(f.label)")
        }
    }

    /// photocraft `twirl_keeps_centre_and_outside`.
    @Test func twirlKeepsCentreAndOutside() {
        let b = PixelRect(x: 0, y: 0, width: 40, height: 40)
        let img = TestImage.make(b, channels: 4, alpha: false)
        let ctx = FilterContext(bounds: b, mode: .rgb, alpha: false)
        let out = Twirl(angle: 180).cpu(img, out: b, ctx: ctx)
        let i0 = img.index(x: 0, y: 0), i1 = img.index(x: 20, y: 12)
        #expect(Array(out.data[i0..<i0 + 4]) == Array(img.data[i0..<i0 + 4]), "corner is outside the twirl circle")
        #expect(Array(out.data[i1..<i1 + 4]) != Array(img.data[i1..<i1 + 4]))
    }

    /// photocraft `halos_and_output_area` / `every_filter_changes_something`.
    @Test func halosAreBoundsAndFiltersChangeSomething() throws {
        let r = PixelRect(x: 0, y: 0, width: 40, height: 30)
        let img = TestImage.make(r, channels: 4, alpha: true)
        let ctx = FilterContext(bounds: r, mode: .rgb, alpha: true)
        let filters: [any Filter] = [
            Twirl(angle: 90), Pinch(amount: 50), Spherize(amount: -60, mode: .horizontalOnly),
            Wave(generators: 3, wavelengthMin: 5, wavelengthMax: 20, amplitudeMin: 1, amplitudeMax: 4, waveType: .triangle, undefined: .repeat, seed: 9),
            Ripple(amount: 200, size: .small), PolarCoordinates(mode: .rectangularToPolar), PolarCoordinates(mode: .polarToRectangular),
        ]
        for f in filters {
            #expect(f.halo(bounds: r) == .bounds)
            #expect(FilterEngine.outputArea(f, content: PixelRect(x: 10, y: 10, width: 10, height: 10), bounds: r) == r)
            #expect(f.cpu(img, out: r, ctx: ctx).data != img.data, "\(f.label) did nothing")
        }
    }

    /// Results don't depend on the tiling (photocraft `every_filter_is_tile_independent`).
    @Test func tileIndependence() throws {
        let r = PixelRect(x: 0, y: 0, width: 40, height: 30)
        let img = TestImage.make(r, channels: 4, alpha: true)
        let ctx = FilterContext(bounds: r, mode: .rgb, alpha: true)
        let filters: [any Filter] = [Twirl(angle: 90), Wave(undefined: .wrap, seed: 2), PolarCoordinates(mode: .polarToRectangular)]
        for f in filters {
            let whole = f.cpu(img, out: r, ctx: ctx)
            for tile in [PixelRect(x: 0, y: 0, width: 17, height: 11), PixelRect(x: 17, y: 11, width: 23, height: 19)] {
                let part = f.cpu(img, out: tile, ctx: ctx)
                #expect(part.data == whole.crop(tile).data, "\(f.label)")
            }
        }
    }

    /// Wave's undefined areas: transparent leaves holes past the bounds, wrap/repeat don't.
    @Test func waveUndefinedAreas() {
        let r = PixelRect(x: 0, y: 0, width: 40, height: 30)
        var img = FloatImage(rect: r, channels: 2)
        for i in 0..<r.area { img.data[i * 2] = 0.5; img.data[i * 2 + 1] = 1 }
        let ctx = FilterContext(bounds: r, mode: .grayscale, alpha: true)
        let w = Wave(generators: 1, wavelengthMin: 200, wavelengthMax: 200, amplitudeMin: 30, amplitudeMax: 30, seed: 1)
        let minAlpha = { (u: UndefinedAreas) -> Float in
            var f = w; f.undefined = u
            let o = f.cpu(img, out: r, ctx: ctx)
            return stride(from: 1, to: o.data.count, by: 2).map { o.data[$0] }.min()!
        }
        #expect(minAlpha(.transparent) < 0.01)
        #expect(minAlpha(.wrap) > 0.9999)
        #expect(minAlpha(.repeat) > 0.9999)
    }

    /// Parameters encode with photocraft's serde names.
    @Test func codableNames() throws {
        let w = Wave(generators: 3, wavelengthMin: 5, wavelengthMax: 20, amplitudeMin: 1, amplitudeMax: 4, waveType: .triangle, undefined: .repeat, seed: 9)
        let j = String(data: try JSONEncoder().encode(w), encoding: .utf8)!
        for key in ["\"generators\"", "\"wavelengthMin\"", "\"amplitudeMax\"", "\"waveType\":\"triangle\"", "\"undefined\":\"repeat\""] {
            #expect(j.contains(key), "\(j)")
        }
        #expect(try JSONDecoder().decode(Wave.self, from: Data(j.utf8)) == w)
        let s = try JSONDecoder().decode(Spherize.self, from: Data(#"{"amount":-60,"mode":"horizontalOnly"}"#.utf8))
        #expect(s == Spherize(amount: -60, mode: .horizontalOnly))
        let p = try JSONDecoder().decode(PolarCoordinates.self, from: Data(#"{"mode":"polarToRectangular"}"#.utf8))
        #expect(p.mode == .polarToRectangular)
    }
}
