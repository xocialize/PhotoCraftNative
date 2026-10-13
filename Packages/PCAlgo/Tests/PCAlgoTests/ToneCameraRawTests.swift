// Port of photocraft-algo (crates/algo/src/camera_raw.rs, camera_raw/local_tone.rs, camera_raw/whites_blacks.rs, histogram.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct ToneCameraRawTests {
    typealias Kit = CameraRawKit

    static func img(_ w: Int, _ h: Int) -> [SIMD4<Float>] {
        (0..<(w * h)).map { i in
            let (x, y) = (Float(i % w) / Float(w), Float(i / w) / Float(h))
            return SIMD4(0.2 + 0.6 * x, 0.3 + 0.4 * y, 0.5 - 0.3 * x * y, 1)
        }
    }

    static func mean(_ px: [SIMD4<Float>], _ c: Int) -> Float { px.reduce(Float(0)) { $0 + $1[c] } / Float(px.count) }

    static func settings(_ edit: (inout CameraRaw) -> Void) -> CameraRaw {
        var p = CameraRaw()
        edit(&p)
        return p
    }

    // MARK: Parity (per-pixel stages)

    static let perPixelCases: [CameraRaw] = [
        settings { $0.temperature = 40; $0.tint = -30; $0.exposure = 0.7 },
        settings { $0.contrast = 80 },
        settings { $0.contrast = -100; $0.exposure = -1.2 },
        settings { $0.vibrance = 70; $0.saturation = -30 },
        settings { $0.curveShadows = 60; $0.curveHighlights = -40; $0.curveSplits = [20, 55, 80] },
        settings { $0.pointCurve = [SIMD2(0, 20), SIMD2(90, 70), SIMD2(200, 230), SIMD2(255, 250)]; $0.pointCurveRed = [SIMD2(0, 0), SIMD2(128, 160), SIMD2(255, 255)] },
        settings { $0.hslHue = [40, -20, 0, 60, 0, -50, 0, 30]; $0.hslSat = [-100, 50, 20, 0, 80, -40, 0, 0]; $0.hslLum = [30, 0, -60, 0, 0, 40, 20, 0] },
        settings {
            $0.gradeShadows = CameraRawWheel(hue: 220, sat: 80, lum: -20); $0.gradeHighlights = CameraRawWheel(hue: 40, sat: 50, lum: 30)
            $0.gradeMidtones = CameraRawWheel(hue: 120, sat: 20, lum: 0); $0.gradeGlobal = CameraRawWheel(hue: 300, sat: 10, lum: 10)
            $0.gradeBlending = 80; $0.gradeBalance = -40
        },
        settings { $0.vignetteAmount = -80; $0.vignetteHighlights = 60; $0.vignetteRoundness = 40 },
        settings { $0.vignetteAmount = 60; $0.vignetteStyle = "colorPriority"; $0.vignetteRoundness = -70; $0.vignetteFeather = 10 },
        settings { $0.vignetteAmount = -50; $0.vignetteStyle = "paintOverlay"; $0.vignetteMidpoint = 20 },
        settings { $0.grainAmount = 60; $0.grainSize = 70; $0.grainRoughness = 30; $0.seed = 9; $0.pixelScale = 0.5 },
        settings {
            $0.temperature = -25; $0.exposure = 0.4; $0.contrast = 30; $0.vibrance = 40; $0.curveDarks = -30
            $0.hslSat = [0, 0, 0, 50, 0, 0, 0, 0]; $0.gradeMidtones = CameraRawWheel(hue: 30, sat: 40, lum: 10)
            $0.vignetteAmount = -30; $0.grainAmount = 25
        },
        CameraRaw(),
    ]

    @Test func cameraRawParity() throws {
        var worst: Float = 0
        for p in Self.perPixelCases {
            #expect(p.isPerPixel)
            worst = max(worst, try Parity.checkVariants(CameraRawFilter(settings: p)))
        }
        // 32-bit documents keep values above 1.
        let r = PixelRect(x: 0, y: 0, width: 48, height: 33)
        let hdr = TestImage.make(r, channels: 4, alpha: true, seed: 7, eightBit: false, hdr: true)
        for p in Self.perPixelCases {
            if let e = try Parity.check(CameraRawFilter(settings: p, float: true), src: hdr, ctx: FilterContext(bounds: r, mode: .rgb, alpha: true), relative: true) {
                worst = max(worst, e)
            }
        }
        ParityLog.record("CameraRaw (per-pixel stages)", worst)
    }

    /// Non-per-pixel settings fall back to the CPU under `.auto` and are refused by `.gpu`.
    @Test func statisticalStagesRunOnTheCPU() throws {
        let p = Self.settings { $0.clarity = 50 }
        let f = CameraRawFilter(settings: p)
        let ctx = FilterContext(bounds: PixelRect(x: 0, y: 0, width: 8, height: 8), mode: .rgb, alpha: true)
        #expect(!f.supportsGPU(ctx, channels: 4))
        var px = Self.img(8, 8), q = px
        try ToneKit.develop(&px, w: 8, h: 8, p, float: false, on: .auto)
        ToneKit.develop(&q, w: 8, h: 8, p, float: false)
        #expect(px == q)
    }

    // MARK: photocraft camera_raw.rs tests

    /// photocraft `new_curves_are_validated_but_saved_curves_still_load_and_render`.
    @Test func newCurvesAreValidatedButSavedCurvesStillLoadAndRender() throws {
        func decode(_ json: String) throws -> CameraRaw { try JSONDecoder().decode(CameraRaw.self, from: Data(json.utf8)) }
        let ramp17 = "[" + (0..<17).map { "[\($0 * 15),\($0 * 15)]" }.joined(separator: ",") + "]"
        let ramp16 = "[" + (0..<16).map { "[\($0 * 17),\($0 * 17)]" }.joined(separator: ",") + "]"
        for field in ["pointCurve", "pointCurveRed", "pointCurveGreen", "pointCurveBlue"] {
            for points in ["[[128,128]]", "[[255,255],[0,0]]", "[[0,0],[0,255]]", "[[0,-1],[255,255]]", "[[0,0],[256,255]]", "[[0,0],[1e30,255]]", ramp17] {
                let p = try decode("{\"\(field)\": \(points)}")
                #expect(p.validate() != nil, "\(field): \(points)")
            }
            for points in ["[]", "[[0,0],[255,255]]", ramp16] {
                let p = try decode("{\"\(field)\": \(points)}")
                #expect(p.validate() == nil, "\(field): \(points)")
            }
        }
        #expect(try decode("{}") == CameraRaw())
        // An older editor could stack two points on one input and exceed 16 points.
        var legacy: [SIMD2<Float>] = (0..<20).map { SIMD2(Float($0) * 12, Float($0) * 12) }
        legacy.insert(SIMD2(60, 200), at: 5)
        var p = CameraRaw()
        p.pointCurve = legacy
        #expect(p.validate() != nil)
        var edited = p
        edited.exposure = 1
        #expect(edited.validateChanges(p) == nil, "an unchanged stored curve stays editable")
        var broken = p
        broken.pointCurve = [SIMD2(10, 10)]
        #expect(broken.validateChanges(p) != nil, "a changed curve is validated")
        var px = Self.img(4, 4)
        ToneKit.develop(&px, w: 4, h: 4, p, float: false)
        #expect(px.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
    }

    /// photocraft `defaults_are_identity`.
    @Test func defaultsAreIdentity() {
        var a = Self.img(40, 30)
        let b = a
        ToneKit.develop(&a, w: 40, h: 30, CameraRaw(), float: false)
        #expect(a == b)
    }

    /// photocraft `basic_panel_moves_the_right_way`.
    @Test func basicPanelMovesTheRightWay() {
        let (w, h) = (64, 48)
        let base = Self.img(w, h)
        func run(_ p: CameraRaw) -> [SIMD4<Float>] {
            var a = base
            ToneKit.develop(&a, w: w, h: h, p, float: false)
            return a
        }
        let warm = run(Self.settings { $0.temperature = 50 })
        #expect(Self.mean(warm, 0) > Self.mean(base, 0) && Self.mean(warm, 2) < Self.mean(base, 2))
        let bright = run(Self.settings { $0.exposure = 1 })
        #expect(Self.mean(bright, 1) > Self.mean(base, 1) + 0.1)
        let shadows = run(Self.settings { $0.shadows = 100 })
        #expect(shadows[0].y > base[0].y)
        let hl = run(Self.settings { $0.highlights = -100 })
        #expect(hl[w * h - 1].x < base[w * h - 1].x)
        let con = run(Self.settings { $0.contrast = 100 })
        #expect(con[0].y < base[0].y && con[w * h - 1].x > base[w * h - 1].x)
        let desat = run(Self.settings { $0.saturation = -100 })
        #expect(desat.allSatisfy { abs($0.x - $0.y) < 1e-4 && abs($0.y - $0.z) < 1e-4 })
        let vib = run(Self.settings { $0.vibrance = 100 })
        let spread = { (q: SIMD4<Float>) in max(q.x, q.y, q.z) - min(q.x, q.y, q.z) }
        #expect(spread(vib[w * h / 2]) > spread(base[w * h / 2]))
        for p in [
            Self.settings { $0.clarity = 80 }, Self.settings { $0.texture = 80 }, Self.settings { $0.dehaze = 60 },
            Self.settings { $0.dehaze = -60 }, Self.settings { $0.whites = 50; $0.blacks = -50 },
        ] {
            let out = run(p)
            #expect(out.allSatisfy { q in [q.x, q.y, q.z].allSatisfy { $0.isFinite && (0...1).contains($0) } })
            #expect(out != base)
        }
    }

    /// photocraft `curves_hsl_grading_detail_effects`.
    @Test func curvesHSLGradingDetailEffects() {
        let lut = ToneKit.curveLUT([SIMD2(0, 0), SIMD2(64, 40), SIMD2(192, 220), SIMD2(255, 255)], count: 256)
        #expect(abs(lut[64] - 40.0 / 255.0) < 0.01 && abs(lut[192] - 220.0 / 255.0) < 0.01)
        #expect(zip(lut, lut.dropFirst()).allSatisfy { $1 >= $0 })
        for hh in stride(from: 0, to: 360, by: 7) {
            let s = ToneKit.bandWeights(Float(hh)).reduce(0, +)
            #expect(abs(s - 1) < 1e-4, "\(hh): \(s)")
        }
        let (w, h) = (48, 32)
        var hs = [Float](repeating: 0, count: 8)
        hs[0] = -100
        var a = [SIMD4<Float>](repeating: SIMD4(0.8, 0.2, 0.2, 1), count: w * h)
        ToneKit.develop(&a, w: w, h: h, Self.settings { $0.hslSat = hs }, float: false)
        #expect(a[0].x - a[0].y < 0.1, "reds desaturated: \(a[0])")
        var b = [SIMD4<Float>](repeating: SIMD4(0.2, 0.2, 0.8, 1), count: w * h)
        ToneKit.develop(&b, w: w, h: h, Self.settings { $0.hslSat = hs }, float: false)
        #expect(abs(b[0].z - 0.8) < 1e-4, "blues untouched")
        var g: [SIMD4<Float>] = [SIMD4(0.1, 0.1, 0.1, 1), SIMD4(0.95, 0.95, 0.95, 1)]
        ToneKit.develop(&g, w: 2, h: 1, Self.settings { $0.gradeShadows = CameraRawWheel(hue: 220, sat: 80, lum: 0) }, float: false)
        #expect(g[0].z > g[0].x + 0.05 && abs(g[1].z - g[1].x) < 0.02, "\(g)")
        var c = Self.img(w, h)
        ToneKit.develop(&c, w: w, h: h, Self.settings { $0.pointCurve = [SIMD2(0, 30), SIMD2(255, 255)]; $0.curveShadows = 50 }, float: false)
        #expect(c.allSatisfy { $0.y >= 30.0 / 255.0 - 1e-4 })
        let noisy: [SIMD4<Float>] = (0..<(w * h)).map { i in
            let n = Kit.hash01(Int64(i), 0, 3) * 0.2
            return SIMD4(0.4 + n, 0.4 + n, 0.4 + n, 1)
        }
        func variance(_ a: [SIMD4<Float>]) -> Float {
            let m = Self.mean(a, 1)
            return a.reduce(Float(0)) { $0 + ($1.y - m) * ($1.y - m) } / Float(a.count)
        }
        var nr = noisy
        ToneKit.develop(&nr, w: w, h: h, Self.settings { $0.noiseLuminance = 80 }, float: false)
        #expect(variance(nr) < variance(noisy) * 0.5)
        var sh = noisy
        ToneKit.develop(&sh, w: w, h: h, Self.settings { $0.sharpenAmount = 100 }, float: false)
        #expect(variance(sh) > variance(noisy))
        var g1 = Self.img(w, h), g2 = Self.img(w, h)
        let gp = Self.settings { $0.grainAmount = 50; $0.seed = 4 }
        ToneKit.develop(&g1, w: w, h: h, gp, float: false)
        ToneKit.develop(&g2, w: w, h: h, gp, float: false)
        #expect(g1 == g2)
        #expect(g1 != Self.img(w, h))
        var v = [SIMD4<Float>](repeating: SIMD4(0.5, 0.5, 0.5, 1), count: w * h)
        ToneKit.develop(&v, w: w, h: h, Self.settings { $0.vignetteAmount = -80 }, float: false)
        #expect(v[0].x < 0.35 && abs(v[(h / 2) * w + w / 2].x - 0.5) < 0.01, "\(v[0])")
    }

    /// photocraft `float_documents_keep_overrange`.
    @Test func floatDocumentsKeepOverrange() throws {
        for backend in [Backend.cpu, .auto] {
            var a = [SIMD4<Float>](repeating: SIMD4(2, 1.5, 0.5, 1), count: 16)
            try ToneKit.develop(&a, w: 4, h: 4, Self.settings { $0.exposure = 0.5 }, float: true, on: backend)
            #expect(a[0].x > 2)
        }
    }

    // MARK: photocraft local_tone.rs tests

    static let srgb = Kit.Encoding(gamma: 0)

    static func grey(_ w: Int, _ h: Int, _ f: (Int, Int) -> Float) -> [SIMD4<Float>] {
        (0..<(w * h)).map { i in let v = f(i % w, i / w); return SIMD4(v, v, v, 1) }
    }

    @Test func aFlatImageIsUnchanged() {
        var px = Self.grey(64, 48) { _, _ in 0.4 }
        Kit.LocalTone.apply(&px, 64, 48, 100, -100, Self.srgb)
        #expect(px.allSatisfy { abs($0.x - 0.4) < 1e-5 })
    }

    @Test func shadowsRaiseADarkAreaWithoutAHalo() {
        let (w, h) = (256, 128)
        var px = Self.grey(w, h) { x, _ in x < w / 2 ? 0.1 : 0.6 }
        Kit.LocalTone.apply(&px, w, h, 100, 0, Self.srgb)
        let row = Array(px[(64 * w)..<(65 * w)])
        #expect(abs(row[w / 2 + 1].x - 0.6) < 0.002 && abs(row[w - 5].x - 0.6) < 0.002)
        let (far, near) = (row[10].x, row[w / 2 - 1].x)
        #expect(abs(far - 0.1) < 0.004 && abs(far - near) < 0.004, "\(far) \(near)")
    }

    @Test func greyMovesAsInPhotoshop() {
        let n = 256
        func image(_ c: Float) -> [SIMD4<Float>] {
            Self.grey(n, n) { x, y in x >= n - 26 && y >= n - 26 ? 0.97 : (x >= n - 26 && y < 26 ? 0.015 : c) }
        }
        for (s, hl, want) in [(Float(100), Float(0), Float(165.3)), (0, -100, 89.6)] {
            var px = image(0.5)
            Kit.LocalTone.apply(&px, n, n, s, hl, Self.srgb)
            let got = px[175 * n + 100].x * 255
            #expect(abs(got - want) < 5, "\(s) \(hl): \(got) vs \(want)")
        }
    }

    @Test func highlightsLowerABrightAreaAndKeepTheDarkest() {
        let (w, h) = (192, 192)
        var px = Self.grey(w, h) { x, y in (64..<128).contains(x) && (64..<128).contains(y) ? 0.8 : 0.2 }
        Kit.LocalTone.apply(&px, w, h, 0, -100, Self.srgb)
        #expect(px[96 * w + 96].x < 0.75, "\(px[96 * w + 96].x)")
        #expect(abs(px[5 * w + 5].x - 0.2) < 0.01, "\(px[5 * w + 5].x)")
    }

    @Test func smoothGradientsStaySmooth() {
        let (w, h) = (640, 48)
        let px = Self.grey(w, h) { x, _ in ColorConvert.linearToSRGB(exp2f(Float(x) / Float(w - 1) * 8 - 9)) }
        for (s, hl) in [(Float(100), Float(0)), (0, -100), (-100, 100)] {
            var p = px
            Kit.LocalTone.apply(&p, w, h, s, hl, Self.srgb)
            let row = (0..<w).map { x in log2f(Float.maximum(ColorConvert.srgbToLinear(p[24 * w + x].x), 1e-6)) }
            let steps = zip(row, row.dropFirst()).map { $1 - $0 }
            #expect(steps.allSatisfy { $0 > 0 }, "\(s) \(hl): the ramp reverses")
            let jumps = zip(steps, steps.dropFirst()).map { abs($1 - $0) }
            let ripple = jumps[16..<(jumps.count - 16)].reduce(Float(0), max)
            #expect(ripple < 0.004, "\(s) \(hl): slope jumps by \(ripple) stops per pixel")
        }
    }

    @Test func theResultDoesNotDependOnTheImageSize() {
        func at(_ n: Int) -> (Float, Float) {
            var px = Self.grey(n, n) { x, y in x < n / 3 || y < n / 4 ? 0.08 : 0.7 }
            Kit.LocalTone.apply(&px, n, n, 70, -60, Self.srgb)
            return (px[(n / 8) * n + n / 8].x, px[(3 * n / 4) * n + 3 * n / 4].x)
        }
        let (a, b) = (at(96), at(384))
        #expect(abs(a.0 - b.0) < 0.02 && abs(a.1 - b.1) < 0.02, "\(a) \(b)")
    }

    // MARK: photocraft whites_blacks.rs tests

    @Test func fullRangeRowsMatchPhotoshop() {
        typealias WB = Kit.WhitesBlacks
        #expect(abs(WB.whites(97.1 / 255, 100) * 255 - 137.4) < 0.6)
        #expect(abs(WB.whites(194.3 / 255, -100) * 255 - 167.6) < 0.6)
        #expect(abs(WB.blacks(97.1 / 255, -100) * 255 - 60.0) < 0.6)
        #expect(abs(WB.blacks(48.6 / 255, 100) * 255 - 67.0) < 0.6)
        #expect(WB.whites(1, -100) == 1)
        #expect(WB.blacks(0, 100) == 0)
    }

    @Test func theClippingDirectionsAdaptToTheImage() {
        typealias WB = Kit.WhitesBlacks
        let (w, _) = WB.amounts(50, 0, 0.05, 0.6)
        #expect(abs(w - 94.5) < 2, "\(w)")
        let (_, b) = WB.amounts(0, -40, 0.6, 1)
        #expect(abs(b + 58) < 1, "\(b)")
        #expect(abs(WB.amounts(0, -50, 0, 1).1 + 60) < 1e-3)
        #expect(WB.amounts(-50, 50, 0.3, 0.6) == (-50, 50))
    }

    // MARK: photocraft histogram.rs (needs develop)

    /// photocraft `exposure_of_an_eight_bit_gradient_reproduces_the_quantization_comb`.
    @Test func exposureOfAnEightBitGradientReproducesTheQuantizationComb() throws {
        var pixels: [SIMD4<Float>] = (0..<256).map { i in let v = Float(i) / 255; return SIMD4(v, v, v, 1) }
        #expect(RgbHistogram(rgba: pixels).channels[0].allSatisfy { $0 == 1 })
        try ToneKit.develop(&pixels, w: 256, h: 1, Self.settings { $0.exposure = 0.5 }, float: true, on: .auto)
        let h = RgbHistogram(rgba: pixels)
        #expect(h.channels[0][10..<230].filter { $0 == 0 }.count > 10)
        #expect(h.samples == 256)
        #expect(h.overflow[0] > 0)
    }
}
