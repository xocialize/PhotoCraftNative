// Port of photocraft-algo (crates/algo/src/noise.rs, denoise.rs, blur.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct NoiseTests {
    @Test func addNoiseParity() throws {
        var w: Float = 0
        for d in Distribution.allCases {
            for mono in [false, true] {
                w = max(w, try Parity.checkVariants(AddNoise(amount: 40, distribution: d, monochromatic: mono, seed: 7)))
            }
        }
        w = max(w, try Parity.checkVariants(AddNoise(amount: 400, distribution: .gaussian, seed: 3)))
        ParityLog.record("AddNoise", w)
    }

    @Test func medianSelectMatchesSort() {
        var s: UInt32 = 0x2545_f491
        for len in [1, 2, 9, 13, 37, 101] {
            var v: [Float] = (0..<len).map { _ in
                s ^= s << 13; s ^= s >> 17; s ^= s << 5
                return [0, -0.0, 0.25, 1.5, -2, Float(s % 1000) / 997][Int(s % 6)]
            }
            let sorted = v.sorted { MedianKit.key($0) < MedianKit.key($1) }
            let m = MedianKit.select(&v, len / 2)
            #expect(m.bitPattern == sorted[len / 2].bitPattern)
        }
    }

    /// photocraft `median_histogram_matches_the_direct_selection`: 8-bit levels, 16-bit levels and
    /// floats with ties, signed zeros, values outside 0…1 and a NaN; output reaching past the source.
    @Test func medianHistogramMatchesDirectSelection() {
        let srcRect = PixelRect(x0: -10, y0: -8, x1: 36, y1: 30)
        let out = PixelRect(x0: -14, y0: -3, x1: 30, y1: 34)
        for kind in 0..<3 {
            var img = FloatImage(rect: srcRect, channels: 4)
            var s: UInt32 = 0x2545_f491 ^ UInt32(kind)
            for i in 0..<img.data.count {
                s ^= s << 13; s ^= s >> 17; s ^= s << 5
                switch kind {
                case 0: img.data[i] = i % 2 == 0 ? Float(s % 256) / 255 : Float(s % 4 * 85) / 255
                case 1: img.data[i] = Float(s % 65536) / 65535
                default: img.data[i] = [0, -0.0, 0.25, 1.5, -2, Float(s % 1000) / 997][Int(s % 6)]
                }
            }
            if kind == 2 { img.data[100] = .nan }
            for r: Int32 in [2, 3, 7, 16] {
                for t: Float? in [nil, 0, 10.0 / 255, 1] {
                    let fast = MedianKit.medianRanked(img, out, r, t), slow = MedianKit.medianDirect(img, out, r, t)
                    #expect(fast.data.map(\.bitPattern) == slow.data.map(\.bitPattern), "kind \(kind) r \(r) t \(String(describing: t))")
                }
            }
        }
    }

    @Test func medianParity() throws {
        var w: Float = 0
        for r: Float in [1, 2, 4] {
            w = max(w, try Parity.checkVariants(Median(radius: r)))
        }
        #expect(w == 0, "the median picks the same sample")
        ParityLog.record("Median", w)
    }

    @Test func medianOnFloatsWithTiesAndSignedZeros() throws {
        let rect = PixelRect(x: -10, y: -8, width: 46, height: 38)
        var img = FloatImage(rect: rect, channels: 4)
        var s: UInt32 = 0x2545_f493
        for i in 0..<img.data.count {
            s ^= s << 13; s ^= s >> 17; s ^= s << 5
            img.data[i] = [0, -0.0, 0.25, 1.5, -2, Float(s % 1000) / 997][Int(s % 6)]
        }
        let ctx = FilterContext(bounds: rect, mode: .rgb, alpha: false)
        let e = try Parity.check(Median(radius: 3), src: img, out: PixelRect(x: -14, y: -3, width: 44, height: 37), ctx: ctx, tol: 0)
        #expect(e == nil || e == 0)
    }

    @Test func dustAndScratchesParity() throws {
        var w: Float = 0
        for (r, t): (Float, Float) in [(1, 0), (2, 10), (3, 255)] {
            w = max(w, try Parity.checkVariants(DustAndScratches(radius: r, threshold: t)))
        }
        ParityLog.record("DustAndScratches", w)
    }

    @Test func surfaceBlurParity() throws {
        var w: Float = 0
        for (r, t): (Float, Float) in [(1, 2), (4, 15), (7, 60), (5, 255)] {
            w = max(w, try Parity.checkVariants(SurfaceBlur(radius: r, threshold: t)))
        }
        ParityLog.record("SurfaceBlur", w)
    }

    @Test func despeckleParity() throws {
        ParityLog.record("Despeckle", try Parity.checkVariants(Despeckle()))
    }

    @Test func reduceNoiseParity() throws {
        var w: Float = 0
        for spec in [ReduceNoise(), ReduceNoise(strength: 10, preserveDetails: 0, reduceColorNoise: 100, sharpenDetails: 100, removeJpegArtifact: true),
                     ReduceNoise(strength: 2, preserveDetails: 100, reduceColorNoise: 0, sharpenDetails: 0)] {
            w = max(w, try Parity.checkVariants(spec, out: PixelRect(x: 3, y: -2, width: 40, height: 33)))
        }
        // Lab: L smoothed as luma, a/b as chroma (one plane on the GPU).
        let out = PixelRect(x: 0, y: 0, width: 40, height: 30)
        if case .radius(let r) = ReduceNoise().halo(bounds: out) {
            for alpha in [false, true] {
                let img = TestImage.make(out.outset(by: r), channels: alpha ? 4 : 3, alpha: alpha, seed: 5)
                if let e = try Parity.check(ReduceNoise(strength: 8, reduceColorNoise: 70, sharpenDetails: 40, removeJpegArtifact: true),
                                            src: img, out: out, ctx: FilterContext(bounds: out, mode: .lab, alpha: alpha)) { w = max(w, e) }
            }
        }
        ParityLog.record("ReduceNoise", w)
    }
}
