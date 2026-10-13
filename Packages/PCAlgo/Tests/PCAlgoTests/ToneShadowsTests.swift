// Port of photocraft-algo (crates/algo/src/tone/shadows_highlights.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct ToneShadowsTests {
    typealias SH = ToneKit.SH

    static let cases: [ShadowsHighlights] = [
        ShadowsHighlights(),
        ShadowsHighlights(shadowAmount: 100, shadowTone: 100, shadowRadius: 10, color: 0, blackClip: 0, whiteClip: 0),
        ShadowsHighlights(shadowAmount: 60, shadowTone: 20, shadowRadius: 3, highlightAmount: 70, highlightTone: 30,
                          highlightRadius: 3, color: -40, midtone: 35, blackClip: 2, whiteClip: 5),
        ShadowsHighlights(shadowAmount: 15, shadowTone: 0, shadowRadius: 0, highlightAmount: 50, highlightTone: 80,
                          highlightRadius: 45, color: 100, midtone: -70, blackClip: 0.5, whiteClip: 0),
        ShadowsHighlights(shadowAmount: 0, highlightAmount: 100, highlightTone: 95, highlightRadius: 1, color: -100, midtone: 100,
                          blackClip: 50, whiteClip: 50),
    ]

    /// The 8-bit quantisation of the neighbourhood (a 256-level mask lookup) and the clip
    /// histogram's bins are thresholds where a few-ulp CPU/GPU difference (f64 vs f32 box sums,
    /// MSL exp/pow) could move a pixel one mask level (up to ~0.04). With the GPU gathering grid
    /// cells in the CPU's order and contraction off, none flips on these images (measured max
    /// 4.8e-7, 0 samples beyond 1/255), so the standard tolerance holds; the fraction is logged.
    @Test func shadowsHighlightsParity() throws {
        guard AlgoGPU.isAvailable else { return }
        var worst: Float = 0, worstFrac: Double = 0
        let out = PixelRect(x: 3, y: -2, width: 61, height: 47)
        for (k, f) in Self.cases.enumerated() {
            for (img, ctx0) in TestImage.variants(out, seed: UInt32(k + 1)) where f.supportsGPU(ctx0, channels: img.channels) {
                var ctx = ctx0
                ctx.bounds = out
                let cpu = try FilterEngine.apply(f, to: img, output: out, context: ctx, on: .cpu)
                let gpu = try FilterEngine.apply(f, to: img, output: out, context: ctx, on: .gpu)
                let e = Parity.maxError(cpu, gpu, alpha: ctx.alpha)
                var bad = 0
                for i in 0..<cpu.data.count where abs(cpu.data[i] - gpu.data[i]) > 1.0 / 255.0 { bad += 1 }
                let frac = Double(bad) / Double(cpu.data.count)
                worst = max(worst, e); worstFrac = max(worstFrac, frac)
                #expect(e <= 1.0 / 255.0, "case \(k) \(ctx.mode) \(img.channels)ch: \(e)")
                #expect(frac == 0, "case \(k) \(ctx.mode) \(img.channels)ch: \(frac) of samples beyond 1/255")
            }
        }
        print("PARITY-FRACTION\tShadowsHighlights\t\(worstFrac)")
        ParityLog.record("ShadowsHighlights", worst)
    }

    /// Larger image (coarser grid, d > 1 at the default radius) through the buffer API.
    @Test func bufferAPIOnGPU() throws {
        guard AlgoGPU.isAvailable else { return }
        let (w, h) = (160, 120)
        let img = TestImage.make(PixelRect(x: 0, y: 0, width: w, height: h), channels: 4, alpha: true, seed: 7)
        let px = (0..<(w * h)).map { i in SIMD4(img.data[i * 4], img.data[i * 4 + 1], img.data[i * 4 + 2], img.data[i * 4 + 3]) }
        for p in Self.cases {
            var a = px, b = px
            ToneKit.shadowsHighlights(&a, w: w, h: h, p)
            try ToneKit.shadowsHighlights(&b, w: w, h: h, p, on: .gpu)
            var bad = 0
            var worst: Float = 0
            for i in 0..<a.count {
                for c in 0..<3 {
                    let d = abs(a[i][c] - b[i][c]) * a[i].w
                    worst = max(worst, d)
                    if d > 1.0 / 255.0 { bad += 1 }
                }
            }
            // Measured worst 2.3e-3 (premultiplied), no sample beyond 1/255.
            #expect(worst <= 1.0 / 255.0 && bad == 0, "\(p): worst \(worst), \(bad) beyond 1/255")
        }
    }

    // MARK: photocraft shadows_highlights.rs tests (CPU and GPU)

    /// A flat `w × h` grey or colour image with one different pixel in the middle; returns that
    /// pixel after Shadows/Highlights.
    static func probe(_ bg: SIMD3<Float>, _ px: SIMD3<Float>, _ p: ShadowsHighlights, _ backend: Backend) throws -> SIMD3<Float> {
        let (w, h) = (121, 121)
        var img = [SIMD4<Float>](repeating: SIMD4(bg, 1), count: w * h)
        img[60 * w + 60] = SIMD4(px, 1)
        try ToneKit.shadowsHighlights(&img, w: w, h: h, p, on: backend)
        let q = img[60 * w + 60]
        return SIMD3(q.x, q.y, q.z)
    }

    static func levels(_ v: SIMD3<Int>) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) / 32768 }

    static func off(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) * 255
    }

    static var backends: [Backend] { AlgoGPU.isAvailable ? [.cpu, .gpu] : [.cpu] }

    /// photocraft `grey_matches_photoshop`: Photoshop 25.4's 16-bit results for grey pixels lifted
    /// by the default Shadows (Color 0), in black and in grey 0.5 surroundings.
    @Test func greyMatchesPhotoshop() throws {
        let p = ShadowsHighlights(color: 0, blackClip: 0, whiteClip: 0)
        for backend in Self.backends {
            for (bg, want) in [(Float(0), [11389, 19422, 28451, 31931]), (0.5, [5211, 9909, 18229, 25700])] {
                for (v, w) in zip([Float(0.125), 0.25, 0.5, 0.749969], want) {
                    let got = try Self.probe(SIMD3(repeating: bg), SIMD3(repeating: v), p, backend)
                    #expect(Self.off(got, Self.levels(SIMD3(repeating: w))) < 2, "\(backend) bg \(bg) v \(v): \(got.x * 32768) vs \(w)")
                }
            }
        }
    }

    /// photocraft `colour_matches_photoshop` (Color +20, Amount 35 %, Radius 10 px).
    @Test func colourMatchesPhotoshop() throws {
        let p = ShadowsHighlights(shadowRadius: 10, blackClip: 0, whiteClip: 0)
        let cases: [(Float, SIMD3<Int>, SIMD3<Int>)] = [
            (0, SIMD3(3277, 1638, 0), SIMD3(8235, 5202, 2170)),
            (0, SIMD3(8192, 6554, 4915), SIMD3(19350, 16514, 13676)),
            (4915.0 / 32768.0, SIMD3(4915, 3277, 1638), SIMD3(10124, 7424, 4723)),
            (9830.0 / 32768.0, SIMD3(11469, 9830, 8192), SIMD3(16540, 14376, 12214)),
        ]
        for backend in Self.backends {
            for (bg, px, want) in cases {
                let got = try Self.probe(SIMD3(repeating: bg), Self.levels(px), p, backend)
                #expect(Self.off(got, Self.levels(want)) < 2, "\(backend) \(px) on \(bg): \(got * 32768) vs \(want)")
            }
        }
    }

    /// photocraft `edge_matches_photoshop`: across a strong edge the neighbourhood barely leaks.
    @Test func edgeMatchesPhotoshop() throws {
        let (w, h) = (200, 24)
        let (a, b): (Float, Float) = (3277.0 / 32768.0, 29491.0 / 32768.0)
        let p = ShadowsHighlights(shadowAmount: 100, shadowTone: 100, shadowRadius: 10, color: 0, blackClip: 0, whiteClip: 0)
        for backend in Self.backends {
            var img: [SIMD4<Float>] = (0..<(w * h)).map { i in i % w < 100 ? SIMD4(a, a, a, 1) : SIMD4(b, b, b, 1) }
            try ToneKit.shadowsHighlights(&img, w: w, h: h, p, on: backend)
            for (x, want) in [(92, 16370), (98, 14439), (99, 12146), (100, 30891), (101, 30403), (102, 30146), (108, 29979)] {
                let got = img[12 * w + x].x * 32768
                #expect(abs(got - Float(want)) / 32768 * 255 < 6, "\(backend) x \(x): \(got) vs \(want)")
            }
        }
    }

    /// photocraft `strength_and_curve_follow_photoshop`.
    @Test func strengthAndCurveFollowPhotoshop() {
        #expect(abs(SH.strength(50) - 2) < 2e-3 && abs(SH.strength(100) - 3) < 1e-4)
        #expect(abs(SH.strength(15) - 1.02) < 0.01 && abs(SH.strength(1) - 0.19) < 0.01)
        for v: Float in [0.1, 0.3, 0.6] {
            let c = 1 - v
            #expect(abs(SH.lift(2, v) - (1 - c * c * c * c)) < 1e-6)
        }
    }

    /// photocraft `tonal_mask_spans_photoshop_tones`.
    @Test func tonalMaskSpansPhotoshopTones() {
        let m95 = SH.tonalMask(95)
        #expect(abs(m95[128] - (1 - 128.0 / 255.0)) < 1e-3, "\(m95[128])")
        #expect(SH.tonalMask(100) == m95)
        let m0 = SH.tonalMask(0)
        #expect(m0[0] > 0.999 && abs(m0[18] - 0.5) < 0.03 && m0[60] < 0.02, "\(m0[18]) \(m0[60])")
    }
}
