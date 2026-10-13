// Port of photocraft-algo (crates/algo/src/stack.rs, trap.rs, vectorscope.rs, redeye.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import simd
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct StackTests {
    func px(_ v: Float) -> [SIMD4<Float>] { [SIMD4(v, v, v, 1)] }

    @Test func basicStatistics() throws {
        let layers = [px(0.1), px(0.9), px(0.2), px(0.3), px(0.1)]
        for b in [Backend.cpu, .auto] {
            func at(_ s: StackStat) throws -> Float { try Stack.combine(layers, s, on: b)[0].x }
            #expect(abs(try at(.mean) - 0.32) < 1e-6)
            #expect(abs(try at(.median) - 0.2) < 1e-6)
            let mn = try at(.minimum), mx = try at(.maximum), rg = try at(.range), sm = try at(.summation)
            let sd = try at(.standardDeviation), vr = try at(.variance), sk = try at(.skewness), en = try at(.entropy), ku = try at(.kurtosis)
            #expect(mn == 0.1 && mx == 0.9)
            #expect(abs(rg - 0.8) < 1e-6 && abs(sm - 1.6) < 1e-6)
            #expect(abs(sd - vr.squareRoot()) < 1e-6)
            #expect(sk > 0.5)
            #expect(en > 0 && en <= 1)
            #expect(ku > 0)
        }
    }

    @Test func statisticsPreserveHDRAndSignedSamples() throws {
        let layers = [px(-2), px(4)]
        for (mode, e): (StackStat, Float) in [(.mean, 1), (.median, 1), (.minimum, -2), (.maximum, 4), (.range, 6), (.summation, 2), (.variance, 9), (.standardDeviation, 3)] {
            #expect(try Stack.combine(layers, mode, on: .cpu)[0] == SIMD4(e, e, e, 1), "\(mode)")
        }
        for mode in [StackStat.mean, .median] {
            #expect(try Stack.combine([px(2), px(4)], mode, on: .cpu)[0] == SIMD4(3, 3, 3, 1))
        }
    }

    @Test func transparentSamplesAreIgnored() throws {
        #expect(try Stack.combine([[SIMD4(0.5, 0.5, 0.5, 1)], [SIMD4(1, 1, 1, 0)]], .mean, on: .cpu)[0] == SIMD4(0.5, 0.5, 0.5, 1))
        #expect(try Stack.combine([[SIMD4(1, 1, 1, 0)]], .mean, on: .cpu)[0].w == 0)
    }

    @Test func gpuMatchesCPU() throws {
        guard AlgoGPU.isAvailable else { return }
        var s: UInt32 = 0x1234_5678
        func r() -> Float { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return Float(s % 1000) / 999 }
        let layers: [[SIMD4<Float>]] = (0..<9).map { _ in (0..<500).map { _ in SIMD4(r() * 1.5 - 0.2, r(), r(), r() < 0.2 ? 0 : r()) } }
        var worst: Float = 0
        for st in StackStat.allCases {
            let c = try Stack.combine(layers, st, on: .cpu), g = try Stack.combine(layers, st, on: .gpu)
            for i in 0..<c.count { worst = max(worst, simd_reduce_max(simd_abs(c[i] - g[i]))) }
        }
        #expect(worst <= 1e-5)
        ParityLog.record("Stack (all statistics)", worst)
    }
}

@Suite struct TrapTests {
    func twoBlocks() -> ([Float], Int, Int) {
        let (w, h, ch) = (8, 4, 4)
        var px = [Float](repeating: 0, count: w * h * ch)
        for y in 0..<h { for x in 0..<w { px[(y * w + x) * ch + (x < 4 ? 0 : 1)] = 1 } }
        return (px, w, h)
    }

    @Test func trapsTheInternalColourEdge() throws {
        for b in [Backend.cpu, .auto] {
            var (px, w, h) = twoBlocks()
            try Trap.trap(&px, width: w, height: h, channels: 4, trapWidth: 1, on: b)
            func at(_ x: Int, _ y: Int, _ c: Int) -> Float { px[(y * w + x) * 4 + c] }
            #expect(at(3, 0, 1) > 0.5 && at(4, 0, 0) > 0.5)
            #expect(at(0, 0, 1) == 0 && at(7, 0, 0) == 0)
        }
    }

    @Test func leavesPaperUntouchedAndWidthZeroIsIdentity() throws {
        var px = [Float](repeating: 0, count: 6 * 3 * 4)
        px[(6 + 3) * 4] = 1
        let before = px
        try Trap.trap(&px, width: 6, height: 3, channels: 4, trapWidth: 1)
        for i in 0..<18 where before[i * 4] == 0 { #expect(px[i * 4] == 0) }
        var (p2, w, h) = twoBlocks()
        let orig = p2
        try Trap.trap(&p2, width: w, height: h, channels: 4, trapWidth: 0)
        #expect(p2 == orig)
    }

    /// photocraft `trap_preserves_paper_alpha_and_spare_channels_exactly` on both backends.
    @Test func matchesDirectDilationExactly() throws {
        for (w, h, ch) in [(1, 31, 5), (47, 1, 4), (37, 29, 4), (37, 29, 5), (23, 19, 8)] {
            for radius in [1, 3, 10, 128] {
                let src: [Float] = (0..<(w * h * ch)).map { i in (i / ch) % 5 == 0 ? 0 : Float((i * 71 + i / ch * 103) % 65536) / 65535 }
                var want = src
                for y in 0..<h { for x in 0..<w {
                    let index = (y * w + x) * ch
                    if !(0..<4).contains(where: { src[index + $0] > 1e-4 }) { continue }
                    for c in 0..<4 {
                        var m: Float = 0
                        for yy in max(y - radius, 0)...min(y + radius, h - 1) { for xx in max(x - radius, 0)...min(x + radius, w - 1) { m = Float.maximum(m, src[(yy * w + xx) * ch + c]) } }
                        want[index + c] = Float.maximum(src[index + c], m)
                    }
                } }
                for b in [Backend.cpu, .auto] {
                    var got = src
                    try Trap.trap(&got, width: w, height: h, channels: ch, trapWidth: radius, on: b)
                    #expect(got.map(\.bitPattern) == want.map(\.bitPattern), "\(w)×\(h)×\(ch) r \(radius) \(b)")
                }
            }
        }
    }
}

@Suite struct VectorscopeTests {
    @Test func primariesNeutralsAndTransparency() throws {
        for (rgb, e): (SIMD3<Float>, Float) in [(SIMD3(1, 0, 0), 0), (SIMD3(1, 1, 0), 1.0 / 6), (SIMD3(0, 1, 0), 1.0 / 3), (SIMD3(0, 0, 1), 2.0 / 3)] {
            let (h, s) = Vectorscope.hueSaturation(rgb)
            #expect(abs(h - e) < 1e-6 && s == 1)
        }
        for b in [Backend.cpu, .auto] {
            let v = try Vectorscope.fromRGBA([SIMD4(0.5, 0.5, 0.5, 1), SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 0), SIMD4(.nan, 0, 0, 1)], on: b)
            #expect(v.samples == 2 && v.counts[0] == 1 && v.counts[Vectorscope.saturations - 1] == 1)
        }
    }

    @Test func gpuCountsMatchExactly() throws {
        guard AlgoGPU.isAvailable else { return }
        let img = TestImage.make(PixelRect(x: 0, y: 0, width: 200, height: 150), channels: 4, alpha: true, eightBit: false)
        let px = (0..<img.rect.area).map { SIMD4(img.data[$0 * 4], img.data[$0 * 4 + 1], img.data[$0 * 4 + 2], img.data[$0 * 4 + 3]) }
        let c = try Vectorscope.fromRGBA(px, on: .cpu), g = try Vectorscope.fromRGBA(px, on: .gpu)
        #expect(c == g)
        ParityLog.record("Vectorscope (exact counts)", 0)
    }
}

@Suite struct RedEyeTests {
    func disc(_ x: Int, _ y: Int, _ cx: Float, _ cy: Float, _ r: Float) -> Bool { hypotf(Float(x) - cx, Float(y) - cy) <= r }
    func portrait(_ x: Int, _ y: Int) -> SIMD4<Float> {
        if disc(x, y, 16, 16, 1.2) { return SIMD4(1, 1, 1, 1) }
        if disc(x, y, 16, 16, 10) { return SIMD4(0.95, 0.10, 0.10, 1) }
        return SIMD4(0.38, 0.28, 0.16, 1)
    }

    @Test func haloCoversErodeAndBlur() {
        #expect(RedEye.haloRadius() == 5)
        #expect(RedEye.searchRadius(50) == 64 && RedEye.searchRadius(0) == 8 && RedEye.searchRadius(101) == RedEye.searchRadius(100))
        #expect(RedEye.unclampedWindowSide(50).map { $0 < RedEye.maxWindow } == true)
        #expect(RedEye.unclampedWindowSide(10_000) == nil && RedEye.unclampedWindowSide(.nan) == nil)
    }

    @Test func redDiscIsNeutralizedAndIrisLeftAlone() {
        let w = 32
        var px = (0..<(w * w)).map { portrait($0 % w, $0 / w) }
        let irisBefore = px[2 * w + 2]
        let n = RedEye.apply(&px, width: w, height: w, click: (16, 16), origin: (0, 0), pupilSize: 50, darken: 100)
        #expect(n > 0)
        let after = px[11 * w + 16]
        #expect(abs(after.x - after.y) < 0.08 && abs(after.x - after.z) < 0.08)
        #expect(abs(after.x - 0.1 * 0.55) < 0.08)
        #expect(px[2 * w + 2] == irisBefore)
        let c = px[16 * w + 16]
        #expect(c.x >= 0.9 && c.y >= 0.9 && c.z >= 0.9)
    }

    @Test func grayPixelsAreNotRedEye() {
        var px = [SIMD4<Float>](repeating: SIMD4(0.4, 0.4, 0.4, 1), count: 256)
        #expect(RedEye.apply(&px, width: 16, height: 16, click: (8, 8), origin: (0, 0), pupilSize: 50, darken: 50) == 0)
    }
}

@Suite struct GradientToolTests {
    @Test func gradientTShapes() {
        let f = SIMD2<Float>(0, 0), t = SIMD2<Float>(10, 0)
        #expect(GradientTool.t(.linear, from: f, to: t, x: 5, y: 3) == 0.5)
        #expect(GradientTool.t(.linear, from: f, to: t, x: -5, y: 0) == 0)
        #expect(GradientTool.t(.radial, from: f, to: t, x: 0, y: 5) == 0.5)
        #expect(GradientTool.t(.reflected, from: f, to: t, x: -5, y: 0) == 0.5)
        #expect(GradientTool.t(.diamond, from: f, to: t, x: 2.5, y: 2.5) == 0.5)
        #expect(abs(GradientTool.t(.angle, from: f, to: t, x: 0, y: 5) - 0.25) < 1e-5)
    }

    @Test func gradientPaintsRampWithinSelection() throws {
        for b in [Backend.cpu, .auto] {
            var s = Surface(format: .rgba8)
            let a = PixelRect(x0: 0, y0: 0, x1: 11, y1: 2)
            var sel = Surface(format: .gray8)
            sel.fill(PixelRect(x0: 0, y0: 0, x1: 11, y1: 1), with: [1])
            try GradientTool.paint(&s, area: a, from: SIMD2(0.5, 0), to: SIMD2(10.5, 0), shape: .linear,
                                   stops: [(0, SIMD4(0, 0, 0, 1)), (1, SIMD4(1, 1, 1, 1))], selection: sel, on: b)
            #expect(s.pixel(x: 0, y: 0)[0] < 0.01 && s.pixel(x: 10, y: 0)[0] > 0.99)
            #expect(abs(s.pixel(x: 5, y: 0)[0] - 0.5) < 0.01)
            #expect(s.pixel(x: 5, y: 1)[3] == 0)
        }
    }

    @Test func gpuMatchesCPU() throws {
        guard AlgoGPU.isAvailable else { return }
        let area = PixelRect(x: -3, y: 2, width: 60, height: 41)
        var worst: Float = 0
        for (fmt, mode) in [(PixelFormat.rgba32f, BlendMode.normal), (.rgba32f, .multiply), (.rgba32f, .hue), (PixelFormat(mode: .grayscale, sample: .f32, alpha: true), .screen),
                            (PixelFormat(mode: .rgb, sample: .f32, alpha: false), .overlay)] {
            for shape in GradientShape.allCases {
                let img = TestImage.make(area, channels: fmt.channels, alpha: fmt.alpha, seed: 3, eightBit: false)
                var a = Surface(format: fmt), b = Surface(format: fmt)
                a.writeRegion(area, img.data); b.writeRegion(area, img.data)
                let stops: [(Float, SIMD4<Float>)] = [(0, SIMD4(1, 0, 0, 1)), (0.4, SIMD4(0, 1, 0, 0.5)), (1, SIMD4(0, 0, 1, 1))]
                try GradientTool.paint(&a, area: area, from: SIMD2(5, 7), to: SIMD2(40, 30), shape: shape, stops: stops, opacity: 0.8, blendMode: mode, dither: true, on: .cpu)
                try GradientTool.paint(&b, area: area, from: SIMD2(5, 7), to: SIMD2(40, 30), shape: shape, stops: stops, opacity: 0.8, blendMode: mode, dither: true, on: .gpu)
                let ca = FloatImage(surface: a, rect: area), cb = FloatImage(surface: b, rect: area)
                worst = max(worst, Parity.maxError(ca, cb, alpha: fmt.alpha))
            }
        }
        #expect(worst <= 1.0 / 255)
        ParityLog.record("GradientTool", worst)
    }
}
