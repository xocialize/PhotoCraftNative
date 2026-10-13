// Port of photocraft-algo (crates/algo/src/quantize.rs, quantize/nearest.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct ToneQuantizeTests {
    typealias Rgb8 = Quantize.Rgb8

    static func gradient(_ w: Int, _ h: Int) -> [SIMD4<Float>] {
        (0..<(w * h)).map { i in SIMD4(Float(i % w) / Float(w - 1), Float(i / w) / Float(h - 1), 0.3, 1) }
    }

    /// The source of photocraft's `all_dithers_match_the_original_linear_palette_search_exactly`.
    static func mixedSource() -> [SIMD4<Float>] {
        var s = gradient(93, 61)
        for i in 0..<s.count {
            s[i].z = Float(i % 71) / 70
            s[i].w = [Float(0), 0.2, 0.7, 1][i % 4]
        }
        return s
    }

    static func linearNearest(_ pal: [Rgb8], _ c: SIMD3<Float>) -> Int {
        var best: (Float, Int) = (.greatestFiniteMagnitude, 0)
        for (i, e) in pal.enumerated() {
            var d: Float = 0
            for k in 0..<3 { let t = c[k] * 255 - Float(e[k]); d += t * t }
            if d < best.0 { best = (d, i) }
        }
        return best.1
    }

    // MARK: Parity

    /// GPU mapping equals the CPU's exactly: indices and pixels, every palette size, dither and
    /// transparency option (diffusion is CPU-only).
    @Test func quantizeParityIsExact() throws {
        guard AlgoGPU.isAvailable else { return }
        let source = Self.mixedSource()
        let big = TestImage.make(PixelRect(x: 0, y: 0, width: 160, height: 120), channels: 4, alpha: true, seed: 2)
        let bigPx = (0..<(160 * 120)).map { i in SIMD4(big.data[i * 4], big.data[i * 4 + 1], big.data[i * 4 + 2], big.data[i * 4 + 3]) }
        var cases = 0
        for (src, w) in [(source, 93), (bigPx, 160)] {
            for count in [2, 8, 16, 64, 256] {
                for kind in [Quantize.PaletteKind.selective, .adaptive, .web] {
                    let pal = try Quantize.buildPalette(src, kind: kind, colors: count, forced: .blackWhite)
                    for dither in [Quantize.Dither.none, .pattern, .noise] {
                        for transparent in [nil, 1] as [Int?] {
                            for amount: Float in [0.75] {
                                var a = src, b = src
                                let ia = Quantize.quantize(&a, w: w, palette: pal, dither: dither, amount: amount, transparent: transparent)
                                let ib = try Quantize.quantize(&b, w: w, palette: pal, dither: dither, amount: amount, transparent: transparent, on: .gpu)
                                #expect(ia == ib, "\(count) \(kind) \(dither) \(String(describing: transparent))")
                                #expect(a == b, "\(count) \(kind) \(dither) \(String(describing: transparent))")
                                cases += 1
                            }
                        }
                    }
                }
            }
        }
        #expect(cases > 0)
        ParityLog.record("Quantize (indices, exact)", 0)
    }

    @Test func bitmapParityIsExact() throws {
        guard AlgoGPU.isAvailable else { return }
        let w = 97
        let src: [Float] = (0..<(w * 73)).map { i in
            let (x, y) = (Float(i % w), Float(i / w))
            return 0.5 + 0.45 * sinf(x * 0.07) * cosf(y * 0.05)
        }
        var methods: [Quantize.BitmapMethod] = [.threshold, .pattern]
        for s in Quantize.HalftoneShape.allCases {
            for (cell, angle) in [(Float(6), Float(45)), (2, 0), (11.5, -30), (1, 200)] { methods.append(.halftone(cell: cell, angle: angle, shape: s)) }
        }
        for m in methods {
            var a = src, b = src
            Quantize.toBitmap(&a, w: w, method: m)
            try Quantize.toBitmap(&b, w: w, method: m, on: .gpu)
            #expect(a == b, "\(m)")
        }
        ParityLog.record("Bitmap (exact)", 0)
    }

    // MARK: photocraft quantize.rs tests

    @Test func fixedPalettesHaveExpectedSizes() {
        #expect(Quantize.webPalette().count == 216)
        #expect(Quantize.macPalette().count == 256)
        #expect(Quantize.windowsPalette().count == 256)
        #expect(Quantize.uniformPalette(27).count == 27)
        #expect(Set(Quantize.macPalette().map { [$0.x, $0.y, $0.z] }).count == 256, "mac palette entries are unique")
    }

    @Test func exactPaletteAndFailure() throws {
        let px: [SIMD4<Float>] = [SIMD4(1, 0, 0, 1), SIMD4(0, 0, 1, 1), SIMD4(1, 0, 0, 1)]
        #expect(try Quantize.buildPalette(px, kind: .exact, colors: 256, forced: .none).count == 2)
        #expect(throws: Quantize.PaletteError.self) { try Quantize.buildPalette(Self.gradient(64, 64), kind: .exact, colors: 256, forced: .none) }
    }

    @Test func adaptiveAndPerceptualRespectCountAndForced() throws {
        let px = Self.gradient(40, 40)
        for kind in [Quantize.PaletteKind.adaptive, .perceptual, .selective] {
            let pal = try Quantize.buildPalette(px, kind: kind, colors: 16, forced: .blackWhite)
            #expect(pal.count <= 16 && pal.count >= 8, "\(kind) \(pal.count)")
            #expect(Array(pal.prefix(2)) == [Rgb8(0, 0, 0), Rgb8(255, 255, 255)])
        }
    }

    @Test func forcedColoursFillingTheCountDoNotCrash() throws {
        let px = [SIMD4<Float>](repeating: SIMD4(1, 1, 1, 1), count: 16)
        for kind in [Quantize.PaletteKind.adaptive, .perceptual, .selective] {
            #expect(try Quantize.buildPalette(px, kind: kind, colors: 2, forced: .blackWhite) == [Rgb8(0, 0, 0), Rgb8(255, 255, 255)])
            #expect(try Quantize.buildPalette(Self.gradient(8, 8), kind: kind, colors: 8, forced: .primaries).count == 8)
        }
    }

    /// photocraft `all_dithers_match_the_original_linear_palette_search_exactly`: the kd-tree gives
    /// the linear search's answers for every dither, palette size and transparency option.
    @Test func allDithersMatchTheLinearPaletteSearchExactly() throws {
        let source = Self.mixedSource()
        for count in [8, 16, 32, 64, 128, 256] {
            let pal = try Quantize.buildPalette(source, kind: .selective, colors: count, forced: .blackWhite)
            for dither in Quantize.Dither.allCases {
                for transparent in [nil, 1] as [Int?] {
                    var actual = source, expected = source
                    let indices = Quantize.quantize(&actual, w: 93, palette: pal, dither: dither, amount: 0.75, transparent: transparent)
                    let old = Quantize.quantizeWith(&expected, 93, pal, dither, 0.75, transparent) { Self.linearNearest(pal, $0) }
                    #expect(indices == old, "\(count) \(dither)")
                    #expect(actual == expected, "\(count) \(dither)")
                }
            }
        }
    }

    @Test func quantizeMapsToPaletteWithEachDither() throws {
        let pal = [Rgb8(0, 0, 0), Rgb8(255, 255, 255)]
        for d in Quantize.Dither.allCases {
            for backend in [Backend.cpu, .auto] {
                var px: [SIMD4<Float>] = (0..<64).map { i in let v = Float(i) / 63; return SIMD4(v, v, v, 1) }
                let idx = try Quantize.quantize(&px, w: 8, palette: pal, dither: d, amount: 1, transparent: nil, on: backend)
                #expect(px.allSatisfy { $0.x == 0 || $0.x == 1 }, "\(d)")
                #expect(idx.count == 64)
                if d == .diffusion {
                    let mean = px.reduce(Float(0)) { $0 + $1.x } / 64
                    #expect(abs(mean - 0.5) < 0.08, "\(mean)")
                }
            }
        }
        var px: [SIMD4<Float>] = [SIMD4(1, 1, 1, 0.2)]
        let idx = Quantize.quantize(&px, w: 1, palette: pal, dither: .none, amount: 1, transparent: 1)
        #expect(idx[0] == 1 && px[0].w == 0)
    }

    @Test func bitmapMethodsAreBinaryAndTrackTone() throws {
        for m in [Quantize.BitmapMethod.threshold, .pattern, .diffusion, .halftone(cell: 6, angle: 45, shape: .round)] {
            for backend in [Backend.cpu, .auto] {
                var g = [Float](repeating: 0.25, count: 32 * 32)
                try Quantize.toBitmap(&g, w: 32, method: m, on: backend)
                #expect(g.allSatisfy { $0 == 0 || $0 == 1 })
                let mean = g.reduce(0, +) / Float(g.count)
                if m != .threshold { #expect(abs(mean - 0.25) < 0.15, "\(m) \(mean)") } else { #expect(mean == 0) }
            }
        }
    }

    // MARK: photocraft nearest.rs test

    /// photocraft `search_matches_linear_oracle_in_rgb_and_lab_with_ties_and_nonfinite_input`.
    @Test func searchMatchesLinearOracle() {
        var seed: UInt32 = 123_456_789
        func random() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / 16_777_215
        }
        func linear(_ points: [SIMD3<Float>], _ q: SIMD3<Float>) -> Int {
            var best: (Float, Int) = (.greatestFiniteMagnitude, 0)
            for (i, p) in points.enumerated() {
                let d = Quantize.Nearest.distance(p, q)
                if d < best.0 { best = (d, i) }
            }
            return best.1
        }
        for count in [0, 2, 8, 16, 17, 32, 64, 65, 128, 256] {
            for (offset, scale): (Float, Float) in [(0, 255), (-128, 256)] {
                let points: [SIMD3<Float>] = (0..<count).map { _ in SIMD3(random() * scale + offset, random() * scale + offset, random() * scale + offset) }
                let lookup = Quantize.Nearest(points)
                for _ in 0..<3000 {
                    let q = SIMD3(random() * scale + offset, random() * scale + offset, random() * scale + offset)
                    #expect(lookup.find(q) == linear(points, q), "count \(count) \(q)")
                }
                for q in [SIMD3<Float>(repeating: .nan), SIMD3<Float>(repeating: .infinity), SIMD3<Float>(repeating: .greatestFiniteMagnitude), SIMD3<Float>(repeating: 0)] {
                    #expect(lookup.find(q) == linear(points, q))
                }
            }
        }
        var points = [SIMD3<Float>](repeating: SIMD3(repeating: 1), count: 256)
        points[250] = SIMD3(repeating: -1)
        #expect(Quantize.Nearest(points).find(.zero) == 0, "equidistant entries preserve original order")
        points[0] = SIMD3(repeating: .nan)
        #expect(Quantize.Nearest(points).find(.zero) == 1)
    }
}
