// Port of photocraft-algo (crates/algo/src/pixelate.rs, pixelate/tests.rs, tests_ext.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct StylizePixelateParityTests {
    @Test func halftoneParity() throws {
        var worst: Float = 0
        for r: Float in [1, 2, 3.75, 4, 8, 20] {
            for a: SIMD4<Float> in [SIMD4(108, 162, 90, 45), SIMD4(0, -17.5, 359.99, 720)] {
                worst = max(worst, try Parity.checkVariants(ColorHalftone(maxRadius: r, angles: a)))
            }
        }
        ParityLog.record("ColorHalftone", worst)
    }
    @Test func crystallizeParity() throws {
        var worst: Float = 0
        for c: Float in [0, 3, 6, 10, 23.5, 60] {
            for s: UInt32 in [0, 1] { worst = max(worst, try Parity.checkVariants(Crystallize(cellSize: c, seed: s))) }
        }
        ParityLog.record("Crystallize", worst)
    }
    @Test func facetParity() throws { ParityLog.record("Facet", try Parity.checkVariants(Facet())) }
    @Test func fragmentParity() throws { ParityLog.record("Fragment", try Parity.checkVariants(Fragment())) }
    @Test func mezzotintParity() throws {
        var worst: Float = 0
        for k in MezzotintType.allCases { for s: UInt32 in [0, 2] { worst = max(worst, try Parity.checkVariants(Mezzotint(kind: k, seed: s))) } }
        ParityLog.record("Mezzotint", worst)
    }
    @Test func pointillizeParity() throws {
        var worst: Float = 0
        for c: Float in [0, 3, 5, 10, 31] {
            for bg: SIMD4<Float> in [SIMD4(1, 1, 1, 1), SIMD4(1, 0, 0, 0.5)] {
                worst = max(worst, try Parity.checkVariants(Pointillize(cellSize: c, seed: 3, background: bg)))
            }
        }
        ParityLog.record("Pointillize", worst)
    }
}

/// pixelate/reference.rs and pixelate/tests.rs fixtures: the original scalar kernels as oracles.
enum PixOracle {
    /// pixelate/tests.rs `fixture`: constant, edge, random, HDR/negative and non-finite patterns.
    static func fixture(_ rect: PixelRect, _ ctx: FilterContext, _ pattern: Int, channels: Int? = nil) -> FloatImage {
        let n = channels ?? PixelFormat(mode: ctx.mode, sample: .f32, alpha: ctx.alpha).channels
        var img = FloatImage(rect: rect, channels: n)
        for i in 0..<rect.area {
            let (x, y) = pixelXY(rect, i)
            let seed = UInt32(bitPattern: x) &* 0x9e37_79b9 ^ UInt32(bitPattern: y) &* 0x85eb_ca6b
            for c in 0..<n {
                let r = UInt32((c * 7) % 32)
                let rot = r == 0 ? seed : (seed << r) | (seed >> (32 - r))
                let v: Float
                switch pattern {
                case 0: v = 0.5
                case 1: v = x + y > -4 ? 0.9 : 0.1
                case 2: v = Float(rot % 65536) / 65535
                case 3: v = Float(rot % 65536) / 16384 - 1
                default:
                    switch (seed &+ UInt32(c)) % 7 { case 0: v = .nan; case 1: v = .infinity; case 2: v = -.infinity; default: v = 0.5 }
                }
                img.data[i * n + c] = v
            }
            if ctx.alpha && seed % 5 == 0 { img.data[i * n + n - 1] = 0 }
        }
        return img
    }

    /// reference.rs `facet`: four 3×3 quadrants per pixel, scanned directly.
    static func facet(_ src: FloatImage, _ out: PixelRect, _ ctx: FilterContext) -> [Float] {
        let n = src.channels
        var res = src.crop(out).data
        var tmp = [Float](repeating: 0, count: n)
        for i in 0..<out.area {
            let (x, y) = pixelXY(out, i)
            var best: (Float, [Float]) = (.greatestFiniteMagnitude, [Float](repeating: 0, count: n))
            for (qx, qy): (Int32, Int32) in [(-2, -2), (0, -2), (-2, 0), (0, 0)] {
                var sum = [Float](repeating: 0, count: n)
                var s: Float = 0, s2: Float = 0
                for yy in (y + qy)...(y + qy + 2) {
                    for xx in (x + qx)...(x + qx + 2) {
                        for c in 0..<n { tmp[c] = src.get(xx, yy, c); sum[c] += tmp[c] }
                        let l = tmp.withUnsafeBufferPointer { ctx.luma($0) }
                        s += l
                        s2 += l * l
                    }
                }
                let cnt: Float = 9
                let v = s2 / cnt - (s / cnt) * (s / cnt)
                if v < best.0 { best = (v, sum.map { $0 / cnt }) }
            }
            for c in 0..<n { res[i * n + c] = best.1[c] }
        }
        return res
    }

    /// reference.rs `halftone`: every dot's five taps evaluated per pixel (no radius table).
    static func halftone(_ src: FloatImage, _ out: PixelRect, _ ctx: FilterContext, _ maxRadius: Float, _ angles: SIMD4<Float>) -> [Float] {
        let n = src.channels, cc = ctx.colorChannels(n)
        let rmax = StylizeKit.fmax(maxRadius, 1)
        let cell = rmax * Float(2).squareRoot()
        let sub = ctx.subtractive, rgb = ctx.mode == .lab
        var res = src.crop(out).data
        let b = ctx.bounds
        let (ox, oy) = (Float(b.x0), Float(b.y0))
        let rot = (0..<max(cc, 3)).map { c -> (Float, Float) in
            let r = PCAMath.radians(angles[min(c, 3)])
            return (sinf(r), cosf(r))
        }
        let clip = b.intersect(src.rect)
        if clip.isEmpty { return res }
        var px = [Float](repeating: 0, count: n)
        func value(_ x: Float, _ y: Float, _ c: Int) -> Float {
            let d = cell * 0.25
            var acc: Float = 0
            for (dx, dy) in [(Float(0), Float(0)), (-d, -d), (d, -d), (-d, d), (d, d)] {
                let ix = min(max(StylizeKit.i32((x + dx).rounded(.down)), clip.x0), clip.x1 - 1)
                let iy = min(max(StylizeKit.i32((y + dy).rounded(.down)), clip.y0), clip.y1 - 1)
                if rgb {
                    for k in 0..<n { px[k] = src.get(ix, iy, k) }
                    acc += px.withUnsafeBufferPointer { ctx.rgba($0) }[c]
                } else {
                    acc += src.get(ix, iy, c)
                }
            }
            return acc / 5
        }
        let chans = rgb ? 3 : cc
        var vals = [Float](repeating: 0, count: max(chans, 1))
        for i in 0..<out.area {
            let (x, y) = pixelXY(out, i)
            let (fx, fy) = (Float(x) + 0.5 - ox, Float(y) + 0.5 - oy)
            for c in 0..<chans {
                let (s, co) = rot[c]
                let (u, w2) = (fx * co + fy * s, -fx * s + fy * co)
                let (cu, cv) = ((u / cell).rounded(.down), (w2 / cell).rounded(.down))
                var cov: Float = 0
                for dj: Float in [-1, 0, 1] {
                    for di: Float in [-1, 0, 1] {
                        let (mu, mv) = ((cu + di + 0.5) * cell, (cv + dj + 0.5) * cell)
                        let d = ((u - mu) * (u - mu) + (w2 - mv) * (w2 - mv)).squareRoot()
                        if d >= rmax + 0.5 { continue }
                        let (dx, dy) = (mu * co - mv * s + ox, mu * s + mv * co + oy)
                        let raw = clampf(value(dx, dy, c), 0, 1)
                        let ink = sub && !rgb ? raw : 1 - raw
                        let touch: Float = 0.785_398_16
                        let r = ink <= touch ? cell * (ink / PCAMath.pi).squareRoot()
                            : cell * (0.5 + (ink - touch) / (1 - touch) * (0.707_106_77 - 0.5))
                        cov = StylizeKit.fmax(cov, StylizeKit.fmin(clampf(r - d + 0.5, 0, 1), PCAMath.pi * r * r))
                    }
                }
                vals[c] = sub && !rgb ? cov : 1 - cov
            }
            if rgb {
                var p = Array(res[(i * n)..<((i + 1) * n)])
                let a: Float = ctx.alpha ? p[n - 1] : 1
                p.withUnsafeMutableBufferPointer { ctx.setRGBA($0, SIMD4(vals[0], vals[1], vals[2], a)) }
                for k in 0..<n { res[i * n + k] = p[k] }
            } else {
                for k in 0..<cc { res[i * n + k] = vals[k] }
            }
        }
        return res
    }
}

@Suite struct StylizePixelateOracleTests {
    @Test func facetReuseMatchesScalarInEveryModel() {
        let out = PixelRect(x0: -17, y0: -9, x1: 20, y1: 18)
        for mode in StyOracle.models {
            for alpha in [false, true] {
                let ctx = FilterContext(bounds: out, mode: mode, alpha: alpha)
                for pattern in 0..<5 {
                    let src = PixOracle.fixture(out.outset(by: 3), ctx, pattern)
                    #expect(StyOracle.sameBits(Facet().cpu(src, out: out, ctx: ctx).data, PixOracle.facet(src, out, ctx)), "\(mode) alpha \(alpha) pattern \(pattern)")
                }
            }
        }
    }

    @Test func facetPartialHaloAndThinRegionsMatchScalar() {
        for out in [PixelRect(x0: -3, y0: 7, x1: -2, y1: 8), PixelRect(x0: -5, y0: 0, x1: 30, y1: 1), PixelRect(x0: 9, y0: -8, x1: 10, y1: 29)] {
            let ctx = FilterContext(bounds: out, mode: .rgb, alpha: true)
            for halo: Int32 in 0...3 {
                let src = PixOracle.fixture(out.outset(by: halo), ctx, 2)
                #expect(StyOracle.sameBits(Facet().cpu(src, out: out, ctx: ctx).data, PixOracle.facet(src, out, ctx)))
            }
        }
    }

    @Test func halftoneTableMatchesScalarScreenAnglesRadiiAndModels() {
        let out = PixelRect(x0: -17, y0: -9, x1: 20, y1: 18)
        for mode in StyOracle.models {
            for alpha in [false, true] {
                let ctx = FilterContext(bounds: PixelRect(x0: -23, y0: -15, x1: 29, y1: 31), mode: mode, alpha: alpha)
                for pattern in 0..<5 {
                    let src = PixOracle.fixture(ctx.bounds, ctx, pattern)
                    for radius: Float in [1, 2, 3.75, 8, 64] {
                        for angles: SIMD4<Float> in [SIMD4(108, 162, 90, 45), SIMD4(0, -17.5, 359.99, 720)] {
                            let got = ColorHalftone(maxRadius: radius, angles: angles).cpu(src, out: out, ctx: ctx).data
                            #expect(StyOracle.sameBits(got, PixOracle.halftone(src, out, ctx, radius, angles)), "\(mode) alpha \(alpha) pattern \(pattern) r \(radius)")
                        }
                    }
                }
            }
        }
    }

    @Test func halftoneUnusualCoordinatesAndParamsKeepDirectSemantics() {
        for out in [PixelRect(x0: 16_777_211, y0: -3, x1: 16_777_220, y1: 4), PixelRect(x0: -3, y0: 4, x1: -2, y1: 5)] {
            let ctx = FilterContext(bounds: out, mode: .rgb, alpha: true)
            let src = PixOracle.fixture(out.outset(by: 2), ctx, 2)
            for radius: Float in [.nan, .infinity, -10, 1] {
                for angles: SIMD4<Float> in [SIMD4(.nan, 0, .infinity, 45), .zero] {
                    let got = ColorHalftone(maxRadius: radius, angles: angles).cpu(src, out: out, ctx: ctx).data
                    #expect(StyOracle.sameBits(got, PixOracle.halftone(src, out, ctx, radius, angles)), "r \(radius) angles \(angles)")
                }
            }
        }
        #expect(ColorHalftone.Screen(PixelRect(x0: 0, y0: 0, x1: 100_000, y1: 100_000), (0, 0), (0, 1), 1) == nil)
        #expect(ColorHalftone.Screen(PixelRect(x0: 8_000_000, y0: 0, x1: 8_000_010, y1: 10), (0, 0), (0, 1), 1) == nil)
        #expect(ColorHalftone.Screen(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1), (0, 0), (0, 1), 1) != nil)
    }

    @Test func extendedChannelsAndLargeScreenOffsetsMatchScalar() {
        let out = PixelRect(x0: 16_777_211, y0: -3, x1: 16_777_220, y1: 4)
        let ctx = FilterContext(bounds: PixelRect(x0: 0, y0: -10, x1: out.x1 + 10, y1: 10), mode: .multichannel, alpha: true)
        for n in 5...8 {
            var src = FloatImage(rect: out.outset(by: 3), channels: n)
            for i in 0..<src.data.count { src.data[i] = Float(i * 73 % 257) / 256 }
            #expect(StyOracle.sameBits(Facet().cpu(src, out: out, ctx: ctx).data, PixOracle.facet(src, out, ctx)))
            #expect(StyOracle.sameBits(ColorHalftone(maxRadius: 1, angles: .zero).cpu(src, out: out, ctx: ctx).data,
                                       PixOracle.halftone(src, out, ctx, 1, .zero)))
        }
    }

    @Test func tiledFiltersMatchScalarAtAllDepthsWithSoftSelection() throws {
        let bounds = PixelRect(x0: -17, y0: -9, x1: 26, y1: 24)
        for mode in [ColorMode.rgb, .grayscale, .cmyk, .lab] {
            for depth in [SampleType.u8, .f32] {
                for alpha in [false, true] {
                    let ctx = FilterContext(bounds: bounds, mode: mode, alpha: alpha)
                    let fmt = PixelFormat(mode: mode, sample: depth, alpha: alpha)
                    var surface = Surface(format: fmt)
                    surface.writeRegion(bounds, PixOracle.fixture(bounds, ctx, 2).data)
                    var selection = Surface(format: .gray8)
                    selection.writeRegion(bounds, (0..<bounds.area).map { Float($0 % 7) / 6 })
                    let cov = (0..<bounds.area).map { i -> Float in
                        let (x, y) = pixelXY(bounds, i)
                        return selection.pixel(x: x, y: y)[0]
                    }
                    let halftone = ColorHalftone(maxRadius: 3.75)
                    for which in 0..<2 {
                        for extent in [nil, bounds] {
                            let halo: Int32 = which == 0 ? 4 : 13
                            let image = extent.map { FloatImage(surface: surface, rect: bounds.outset(by: halo), clampedTo: $0) }
                                ?? FloatImage(surface: surface, rect: bounds.outset(by: halo))
                            let raw = which == 0 ? PixOracle.facet(image, bounds, ctx) : PixOracle.halftone(image, bounds, ctx, 3.75, halftone.angles)
                            let mixed = FilterEngine.mixSelection(original: image.crop(bounds), filtered: FloatImage(rect: bounds, channels: fmt.channels, data: raw),
                                                                  coverage: cov, alpha: alpha)
                            var want = surface
                            want.writeRegion(bounds, mixed.data)
                            for tile in [17, 256] {
                                var got = surface
                                if which == 0 {
                                    try FilterEngine.apply(Facet(), to: &got, area: bounds, bounds: bounds, selection: selection, extent: extent, on: .cpu, tile: tile)
                                } else {
                                    try FilterEngine.apply(halftone, to: &got, area: bounds, bounds: bounds, selection: selection, extent: extent, on: .cpu, tile: tile)
                                }
                                #expect(StyOracle.sameBits(got.readRegion(bounds), want.readRegion(bounds)), "\(mode) \(depth) alpha \(alpha) \(which) tile \(tile)")
                            }
                        }
                    }
                }
            }
        }
    }
}
