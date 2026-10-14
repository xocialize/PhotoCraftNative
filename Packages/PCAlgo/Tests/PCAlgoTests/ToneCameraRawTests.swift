// Port of photocraft-algo (crates/algo/src/camera_raw.rs, histogram.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// AB-T-0241 departs from photocraft on purpose: white balance, Exposure, Contrast, Highlights, Shadows, Whites, Blacks,
// Saturation, Vibrance, the parametric curve (at its default dividers), the Color Mixer and Color Grading are
// Photoshop's Camera Raw Filter's, fitted (CameraRawModel.swift), and Calibration is new. photocraft's tests of those
// formulas say where they now hold differently; its local_tone.rs and whites_blacks.rs tests went with the local
// Laplacian Highlights/Shadows and the adaptive Whites/Blacks curves the fit replaced, and the fitted model's own
// tests are below them.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation
import simd

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

    /// A picture's brightness, for the adaptive sliders to run per pixel.
    static let bright = CameraRawStatistics(brightest: 0.7, logBrightest: 0.6, luminance: 0.55)

    static let perPixelCases: [CameraRaw] = [
        settings { $0.temperature = 40; $0.tint = -30; $0.exposure = 0.7 },
        settings { $0.contrast = 80; $0.statistics = bright },
        settings { $0.contrast = -100; $0.exposure = -1.2; $0.statistics = CameraRawStatistics(brightest: 0.2, logBrightest: 0.2, luminance: 0.2) },
        settings { $0.highlights = -70; $0.shadows = 60; $0.statistics = bright },
        settings { $0.whites = 40; $0.blacks = -55 },
        settings { $0.calibrationRedHue = 30; $0.calibrationGreenSaturation = -60; $0.calibrationBlueHue = 80 },
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
            $0.vignetteAmount = -30; $0.grainAmount = 25; $0.statistics = bright
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

    /// Non-per-pixel settings fall back to the CPU under `.auto` and are refused by `.gpu`: a neighbourhood, or an adaptive
    /// slider without the picture's brightness.
    @Test func statisticalStagesRunOnTheCPU() throws {
        for p in [Self.settings { $0.clarity = 50 }, Self.settings { $0.shadows = 50 }] {
            let f = CameraRawFilter(settings: p)
            let ctx = FilterContext(bounds: PixelRect(x: 0, y: 0, width: 8, height: 8), mode: .rgb, alpha: true)
            #expect(!f.supportsGPU(ctx, channels: 4))
            var px = Self.img(8, 8), q = px
            try ToneKit.develop(&px, w: 8, h: 8, p, float: false, on: .auto)
            ToneKit.develop(&q, w: 8, h: 8, p, float: false)
            #expect(px == q)
        }
        var known = Self.settings { $0.shadows = 50 }
        known.statistics = CameraRawStatistics.measure(Self.img(8, 8))
        #expect(known.isPerPixel)
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
        // Photoshop's Saturation −100 makes greys; the fitted model gets within about a level of grey (photocraft's
        // formula was exact).
        let desat = run(Self.settings { $0.saturation = -100 })
        #expect(desat.allSatisfy { abs($0.x - $0.y) < 1.5 / 255 && abs($0.y - $0.z) < 1.5 / 255 }, "\(desat.map { $0.max() - $0.min() }.max()! * 255)")
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
        // photocraft's band weights went with its Color Mixer formula (the fitted Mixer has its own hue maps).
        let (w, h) = (48, 32)
        var hs = [Float](repeating: 0, count: 8)
        hs[0] = -100
        var a = [SIMD4<Float>](repeating: SIMD4(0.8, 0.2, 0.2, 1), count: w * h)
        ToneKit.develop(&a, w: w, h: h, Self.settings { $0.hslSat = hs }, float: false)
        // Photoshop's Red Saturation −100 keeps about a quarter of this red's chroma (0.16 of 0.6, its neighbours'
        // bands overlapping it); photocraft's took it below 0.1.
        #expect(a[0].x - a[0].y < 0.2, "reds desaturated: \(a[0])")
        // Blues keep their color within a level: the fitted map moves them a little, where photocraft's left them exact.
        var b = [SIMD4<Float>](repeating: SIMD4(0.2, 0.2, 0.8, 1), count: w * h)
        ToneKit.develop(&b, w: w, h: h, Self.settings { $0.hslSat = hs }, float: false)
        #expect(abs(b[0].z - 0.8) < 1.0 / 255 && abs(b[0].x - 0.2) < 1.0 / 255, "blues untouched: \(b[0])")
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

    // MARK: The fitted model (AB-T-0241)

    static func grey(_ v: Float) -> SIMD4<Float> { SIMD4(v, v, v, 1) }

    /// Runs `p` on a few colors (the picture's brightness given, so the adaptive sliders don't read these colors).
    static func colors(_ p: CameraRaw, _ c: [SIMD4<Float>]) -> [SIMD4<Float>] {
        var px = c, q = p
        if q.statistics == nil { q.statistics = CameraRawStatistics() }
        ToneKit.develop(&px, w: px.count, h: 1, q, float: false)
        return px
    }

    @Test func theFittedModelLoads() {
        #expect(CameraRawKit.Model.library != nil)
    }

    /// Every slider at zero leaves the picture as it is, and a slider moves its stops' way.
    @Test func slidersMoveAsPhotoshopsDo() {
        let greys = [0.1, 0.3, 0.5, 0.7, 0.9].map { Self.grey(Float($0)) }
        func mean(_ p: CameraRaw) -> Float { Self.colors(p, greys).reduce(0) { $0 + $1.x + $1.y + $1.z } / Float(3 * greys.count) }
        let base = mean(CameraRaw())
        #expect(mean(Self.settings { $0.exposure = 1 }) > base + 0.05)
        #expect(mean(Self.settings { $0.exposure = -1 }) < base - 0.05)
        #expect(mean(Self.settings { $0.whites = 100 }) > base + 0.02)
        #expect(mean(Self.settings { $0.blacks = -100 }) < base - 0.02)
        #expect(mean(Self.settings { $0.shadows = 100 }) > base + 0.01)
        #expect(mean(Self.settings { $0.highlights = -100 }) < base - 0.01)
        // Photoshop's Temperature +60 takes mid grey to about (211, 175, 119): warmer and brighter, blue nearly kept.
        let warm = Self.colors(Self.settings { $0.temperature = 60 }, [Self.grey(0.5)])[0]
        #expect(warm.x > 0.75 && warm.y > warm.z && warm.z < 0.5, "\(warm * 255)")
        let magenta = Self.colors(Self.settings { $0.tint = 60 }, [Self.grey(0.5)])[0]
        #expect(magenta.y < magenta.x && magenta.y < magenta.z, "\(magenta)")
        // Photoshop's Temperature +100 takes mid grey to about (236, 188, 116).
        let hot = Self.colors(Self.settings { $0.temperature = 100 }, [Self.grey(128.0 / 255)])[0] * 255
        #expect(abs(hot.x - 236) < 6 && abs(hot.y - 188) < 6 && abs(hot.z - 116) < 6, "\(hot)")
    }

    /// The adaptive sliders follow the picture: Shadows lifts a mid grey more in a bright picture than in a dark one, and
    /// Highlights lowers it more in a dark one.
    @Test func adaptiveSlidersReadThePicture() {
        func at(_ p: CameraRaw, _ level: Float) -> Float {
            var q = p
            q.statistics = CameraRawStatistics(brightest: level, logBrightest: level, luminance: level)
            return Self.colors(q, [Self.grey(0.5)])[0].x
        }
        let lift = Self.settings { $0.shadows = 100 }
        #expect(at(lift, 224.0 / 255) > at(lift, 53.0 / 255) + 0.05)
        let cut = Self.settings { $0.highlights = -100 }
        #expect(at(cut, 53.0 / 255) < at(cut, 224.0 / 255) - 0.05)
        // Measured from the pixels when the settings don't carry it.
        let px = (0..<64).map { i in Self.grey(Float(i) / 63) }
        let s = CameraRawStatistics.measure(px)
        #expect(abs(s.luminance - 0.5) < 0.2 && s.brightest > 0.3)
    }

    /// Calibration, new with the fit: Red Hue moves reds, and leaves greys.
    @Test func calibrationMovesPrimaries() {
        let out = Self.colors(Self.settings { $0.calibrationRedHue = 100 }, [SIMD4(0.8, 0.1, 0.1, 1), Self.grey(0.5)])
        #expect(abs(out[0].y - 0.1) > 0.02, "\(out[0])")
        #expect(abs(out[1].x - 0.5) < 1.5 / 255 && abs(out[1].z - 0.5) < 1.5 / 255, "\(out[1])")
        #expect(CameraRaw().isIdentity && !Self.settings { $0.calibrationBlueSaturation = 10 }.isIdentity)
    }

    /// The lattice develop applies stays near the stages themselves between its points too (the fitted stages bend
    /// sharply at the gamut's edge, so its colors that fall between lattice points are a few levels off at worst).
    @Test func theLatticeFollowsTheStages() {
        let p = Self.settings {
            $0.temperature = 30; $0.exposure = 0.6; $0.contrast = 40; $0.vibrance = 30; $0.hslHue[5] = -40
            $0.gradeShadows = CameraRawWheel(hue: 210, sat: 40, lum: 0); $0.statistics = CameraRawStatistics()
        }
        var colors: [SIMD3<Float>] = (0..<2000).map { i in
            SIMD3(CameraRawKit.hash01(Int64(i), 0, 1), CameraRawKit.hash01(Int64(i), 1, 1), CameraRawKit.hash01(Int64(i), 2, 1))
        }
        var px = colors.map { SIMD4($0, 1) }
        ToneKit.cameraRawColors(&colors, p)
        ToneKit.develop(&px, w: px.count, h: 1, p, float: false)
        let errors = zip(colors, px).map { a, b in simd_reduce_max(simd_abs(a - SIMD3(b.x, b.y, b.z))) * 255 }.sorted()
        let p99 = errors[Int(Double(errors.count) * 0.99)], mean = errors.reduce(0, +) / Float(errors.count)
        // 65³ measured p99 2.2, mean 0.16 here (33³: 6.2 and 0.44).
        #expect(p99 < 3 && mean < 0.25, "p99 \(p99) mean \(mean) max \(errors.last!)")
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
