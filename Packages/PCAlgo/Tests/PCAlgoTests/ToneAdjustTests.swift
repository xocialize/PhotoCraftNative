// Port of photocraft-algo (crates/algo/src/tone.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct ToneAdjustTests {
    static func ramp(_ w: Int, _ h: Int) -> [SIMD4<Float>] {
        (0..<(w * h)).map { i in
            let x = Float(i % w) / Float(w - 1)
            return SIMD4(x, x * 0.8, x * 0.6 + 0.1, 1)
        }
    }

    static func luma(_ q: SIMD4<Float>) -> Float { ToneKit.luma(SIMD3(q.x, q.y, q.z)) }

    static func diff(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float { (0..<4).map { abs(a[$0] - b[$0]) }.max()! }

    // MARK: Parity

    @Test func replaceColorParity() throws {
        var worst: Float = 0
        for f in [
            ReplaceColor(color: SIMD3(0.5, 0.45, 0.6), fuzziness: 40, hue: 120),
            ReplaceColor(color: SIMD3(0.8, 0.3, 0.2), fuzziness: 200, hue: -90, saturation: 50, lightness: -30),
            ReplaceColor(color: SIMD3(0.2, 0.6, 0.5), fuzziness: 0, hue: 180, saturation: -100, lightness: 100),
            ReplaceColor(color: SIMD3(0.5, 0.5, 0.5), fuzziness: 120, hue: 30, saturation: -40, lightness: 20),
        ] {
            worst = max(worst, try Parity.checkVariants(f))
        }
        ParityLog.record("ReplaceColor", worst)
    }

    @Test func matchColorParity() throws {
        let r = PixelRect(x: 0, y: 0, width: 61, height: 47)
        let tgt = TestImage.make(r, channels: 4, alpha: true, seed: 1)
        let srcImg = TestImage.make(r, channels: 3, alpha: false, seed: 9)
        let ctxT = FilterContext(bounds: r, mode: .rgb, alpha: true)
        let t = try #require(ToneKit.labStats(tgt, context: ctxT))
        let s = try #require(ToneKit.labStats(srcImg, context: FilterContext(bounds: r, mode: .rgb, alpha: false)))
        var worst: Float = 0
        for f in [
            MatchColorFilter(target: t, source: s),
            MatchColorFilter(options: MatchColor(luminance: 150, intensity: 40, fade: 30), target: t, source: s),
            MatchColorFilter(options: MatchColor(luminance: 80, intensity: 180, neutralize: true), target: t),
            MatchColorFilter(options: MatchColor(luminance: 1, intensity: 1, fade: 100), target: t, source: s),
        ] {
            worst = max(worst, try Parity.checkVariants(f))
        }
        ParityLog.record("MatchColor", worst)
    }

    @Test func hdrToningParity() throws {
        var worst: Float = 0
        for f in [
            HdrToning(),
            HdrToning(radius: 7, strength: 2, gamma: 0.6, exposure: 1, detail: 150, shadow: 40, highlight: -30, vibrance: 50, saturation: -20),
            HdrToning(radius: 1, strength: 0.1, gamma: 2, exposure: -2, detail: -100, vibrance: -100, saturation: 100,
                      curve: [SIMD2(1, 0), SIMD2(0, 1), SIMD2(0.5, 0.3)]),
            HdrToning(radius: 120, strength: 4, detail: 300, curve: [SIMD2(0, 0.1), SIMD2(0.4, 0.6), SIMD2(1, 0.9)]),
        ] {
            worst = max(worst, try Parity.checkVariants(f))
        }
        ParityLog.record("HdrToning", worst)
    }

    /// The buffer API's GPU entry point agrees with the CPU function.
    @Test func bufferAPIOnGPU() throws {
        guard AlgoGPU.isAvailable else { return }
        let (w, h) = (40, 10)
        var a = Self.ramp(w, h), b = a
        let p = HdrToning(strength: 2, detail: 0, saturation: 0)
        ToneKit.hdrToning(&a, w: w, h: h, p)
        try ToneKit.hdrToning(&b, w: w, h: h, p, on: .gpu)
        for i in 0..<a.count { #expect(Self.diff(a[i], b[i]) < 1e-5) }
        var c = Self.ramp(w, h), d = c
        ToneKit.replaceColor(&c, color: SIMD3(0.5, 0.4, 0.4), fuzziness: 60, hue: 90, saturation: 10, lightness: 0)
        try ToneKit.replaceColor(&d, w: w, h: h, ReplaceColor(color: SIMD3(0.5, 0.4, 0.4), fuzziness: 60, hue: 90, saturation: 10), on: .gpu)
        for i in 0..<c.count { #expect(Self.diff(c[i], d[i]) < 1e-5) }
    }

    // MARK: photocraft tone.rs

    /// photocraft `replace_color_only_touches_matching_pixels`.
    @Test func replaceColorOnlyTouchesMatchingPixels() {
        var px: [SIMD4<Float>] = [SIMD4(1, 0, 0, 1), SIMD4(0, 0, 1, 1)]
        let m = ToneKit.replaceColor(&px, color: SIMD3(1, 0, 0), fuzziness: 40, hue: 120, saturation: 0, lightness: 0)
        #expect(m[1] == 0)
        #expect(px[0].y > 0.9 && px[0].x < 0.1, "\(px[0])")
        #expect(px[1] == SIMD4(0, 0, 1, 1))
    }

    /// photocraft `match_color_moves_statistics_toward_source`.
    @Test func matchColorMovesStatisticsTowardSource() throws {
        let src: [SIMD4<Float>] = (0..<64).map { i in SIMD4(0.8, 0.4 + Float(i % 8) * 0.02, 0.2, 1) }
        var tgt: [SIMD4<Float>] = (0..<64).map { i in SIMD4(0.2, 0.3, 0.6 + Float(i % 8) * 0.03, 1) }
        let s = try #require(ToneKit.labStats(src))
        let t = try #require(ToneKit.labStats(tgt))
        ToneKit.matchColor(&tgt, target: t, source: s, options: MatchColor())
        let after = try #require(ToneKit.labStats(tgt))
        for k in 0..<3 {
            #expect(abs(after.mean[k] - s.mean[k]) < abs(t.mean[k] - s.mean[k]) * 0.2 + 1, "\(k): \(after) vs \(s)")
        }
        var tint: [SIMD4<Float>] = (0..<16).map { i in SIMD4(0.7, 0.5, 0.3 + Float(i) * 0.01, 1) }
        let tt = try #require(ToneKit.labStats(tint))
        ToneKit.matchColor(&tint, target: tt, source: nil, options: MatchColor(neutralize: true))
        let n = try #require(ToneKit.labStats(tint))
        #expect(abs(n.mean[1]) < 2 && abs(n.mean[2]) < 2, "\(n)")
    }

    /// photocraft `hdr_toning_compresses_range_and_keeps_bounds` (CPU and GPU).
    @Test func hdrToningCompressesRangeAndKeepsBounds() throws {
        for backend in [Backend.cpu, .auto] {
            var px = Self.ramp(40, 10)
            try ToneKit.hdrToning(&px, w: 40, h: 10, HdrToning(strength: 2, detail: 0, saturation: 0), on: backend)
            #expect(Self.luma(px[38]) > Self.luma(px[2]))
            #expect(px.allSatisfy { q in (0...1).contains(q.x) && (0...1).contains(q.y) && (0...1).contains(q.z) })
            var inv = Self.ramp(40, 10)
            try ToneKit.hdrToning(&inv, w: 40, h: 10, HdrToning(strength: 0, detail: 0, saturation: 0, curve: [SIMD2(0, 1), SIMD2(1, 0)]), on: backend)
            #expect(Self.luma(inv[2]) > Self.luma(inv[38]))
        }
    }

    /// Codable mirrors photocraft's field names (camelCase like the engine's parameters).
    @Test func codableRoundTrip() throws {
        let p = HdrToning(radius: 12, curve: [SIMD2(0, 0.1), SIMD2(1, 0.9)])
        let back = try JSONDecoder().decode(HdrToning.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        let m = MatchColor(luminance: 120, neutralize: true)
        #expect(try JSONDecoder().decode(MatchColor.self, from: JSONEncoder().encode(m)) == m)
    }
}

import Foundation
