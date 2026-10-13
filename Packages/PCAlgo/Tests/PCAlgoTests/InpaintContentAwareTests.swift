// Port of photocraft-algo (crates/algo/src/content_aware.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Synchronization
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct InpaintContentAwareTests {
    typealias K = InpaintKit

    /// Vertical stripes (period 6) in grey, with a hole in the middle.
    static func stripes(_ w: Int, _ h: Int) -> ([Float], [Bool]) {
        let img: [Float] = (0..<(w * h)).map { ($0 % w) % 6 < 3 ? 0.2 : 0.8 }
        let hole: [Bool] = (0..<(w * h)).map { abs($0 % w - w / 2) < 4 && abs($0 / w - h / 2) < 4 }
        return (img, hole)
    }

    /// I.i.d. noise: every value occurs once, so a filled pixel equal to an image pixel was copied.
    static func noise(_ w: Int, _ h: Int, _ seed: UInt64) -> [Float] {
        var z = seed
        return (0..<(w * h * 3)).map { _ in
            z = z &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return 0.2 + 0.6 * (Float(z >> 40) / Float(1 << 24))
        }
    }

    /// photocraft `cancelled_fill_stops_and_progress_reaches_one`.
    @Test func cancelledFillStopsAndProgressReachesOne() throws {
        let (w, h) = (60, 40)
        let (img, hole) = Self.stripes(w, h)
        let source = [Bool](repeating: true, count: w * h)
        #expect(throws: K.Cancelled.self) {
            _ = try K.fillWith(width: w, height: h, channels: 1, image: img, hole: hole, source: source, options: K.FillOptions(), interrupt: .cancelOnly { true })
        }
        let last = Mutex<Float>(0)
        let backwards = Mutex<Bool>(false)
        let ctl = K.Interrupt(cancel: { false }, progress: { f in
            last.withLock { l in
                if f < l { backwards.withLock { $0 = true } }
                l = f
            }
        })
        let out = try K.fillWith(width: w, height: h, channels: 1, image: img, hole: hole, source: source, options: K.FillOptions(), interrupt: ctl)
        #expect(!backwards.withLock { $0 }, "progress went backwards")
        #expect(last.withLock { $0 } == 1)
        #expect(out == K.fill(width: w, height: h, channels: 1, image: img, hole: hole, source: source), "same result as the plain fill")
    }

    /// photocraft `filling_in_place_is_filling_a_copy` (Swift arrays are values: the fill is
    /// deterministic and changes only the hole), with the GPU stages giving the same bits.
    @Test func fillChangesOnlyTheHoleOnEveryBackend() throws {
        let (w, h) = (90, 70)
        let rgb: [Float] = Self.noise(w, h, 4).enumerated().map { i, v in v * 0.5 + 0.3 * Float(((i / 3 % w) % 11 < 5) ? 1 : 0) }
        let hole: [Bool] = (0..<(w * h)).map { (30..<52).contains($0 % w) && (25..<44).contains($0 / w) }
        let source: [Bool] = (0..<(w * h)).map { $0 % w < 75 }
        let backends: [Backend] = AlgoGPU.isAvailable ? [.cpu, .gpu] : [.cpu]
        for opts in [K.FillOptions(), K.FillOptions(colorAdaptation: .none, mirror: true)] {
            var outs: [[Float]] = []
            for b in backends {
                let out = try K.fillWith(width: w, height: h, channels: 3, image: rgb, hole: hole, source: source, options: opts, interrupt: .none, on: b)
                #expect((0..<(w * h)).allSatisfy { i in hole[i] || (0..<3).allSatisfy { out[i * 3 + $0].bitPattern == rgb[i * 3 + $0].bitPattern } })
                outs.append(out)
            }
            if outs.count == 2 { #expect(outs[0].map(\.bitPattern) == outs[1].map(\.bitPattern), "GPU stages change the fill") }
        }
        // Nothing to copy from: the membrane.
        let nowhere = [Bool](repeating: false, count: w * h)
        let a = try K.fillWith(width: w, height: h, channels: 3, image: rgb, hole: hole, source: nowhere, options: K.FillOptions(), interrupt: .none)
        #expect(a == Poisson.membraneFill(width: w, height: h, channels: 3, image: rgb, hole: hole))
        ParityLog.record("ContentAware fill (bits)", 0)
    }

    /// photocraft `auto_sampling_can_be_cancelled`.
    @Test func autoSamplingCanBeCancelled() throws {
        let (w, h) = (200, 160)
        let img: [Float] = Self.noise(w, h, 5).enumerated().map { i, v in v * 0.1 + ((i / 3) % w < 120 ? 0.3 : 0.6) }
        let hole: [Bool] = (0..<(w * h)).map { (80..<110).contains($0 % w) && (60..<90).contains($0 / w) }
        #expect(throws: K.Cancelled.self) { _ = try K.autoSamplingWith(width: w, height: h, channels: 3, image: img, hole: hole, interrupt: .cancelOnly { true }) }
        #expect(try K.autoSamplingWith(width: w, height: h, channels: 3, image: img, hole: hole, interrupt: .none) == K.autoSampling(width: w, height: h, channels: 3, image: img, hole: hole))
    }

    /// photocraft `fills_only_the_hole_with_known_texture`.
    @Test func fillsOnlyTheHoleWithKnownTexture() {
        let (w, h) = (48, 32)
        let (img, hole) = Self.stripes(w, h)
        let out = K.fill(width: w, height: h, channels: 1, image: img, hole: hole, source: [Bool](repeating: true, count: w * h),
                         options: K.FillOptions(colorAdaptation: .none))
        for i in 0..<(w * h) where !hole[i] { #expect(out[i] == img[i]) }
        let vals = (0..<(w * h)).filter { hole[$0] }.map { out[$0] }
        #expect(vals.contains { $0 < 0.35 } && vals.contains { $0 > 0.65 }, "\(vals)")
    }

    /// photocraft `sampling_area_restricts_sources`.
    @Test func samplingAreaRestrictsSources() {
        let (w, h) = (40, 20)
        let img: [Float] = (0..<(w * h)).map { $0 % w < 20 ? 0.1 : 0.9 }
        let hole: [Bool] = (0..<(w * h)).map { (16..<24).contains($0 % w) && (6..<14).contains($0 / w) }
        let right: [Bool] = (0..<(w * h)).map { $0 % w >= 24 }
        let out = K.fill(width: w, height: h, channels: 1, image: img, hole: hole, source: right, options: K.FillOptions(colorAdaptation: .none))
        let mean = (0..<(w * h)).filter { hole[$0] }.reduce(Float(0)) { $0 + out[$1] } / 64
        #expect(mean > 0.8, "mean \(mean)")
    }

    /// photocraft `adaptations_run_and_stay_deterministic`.
    @Test func adaptationsRunAndStayDeterministic() {
        let (w, h) = (32, 24)
        let (img, hole) = Self.stripes(w, h)
        let rgb = img.flatMap { [$0, $0 * 0.5, 1 - $0] }
        let src = [Bool](repeating: true, count: w * h)
        let opts = K.FillOptions(colorAdaptation: K.colorLevel("high"), rotations: K.rotationLevel("low"), scale: true, mirror: true, seed: 7)
        let a = K.fill(width: w, height: h, channels: 3, image: rgb, hole: hole, source: src, options: opts)
        let b = K.fill(width: w, height: h, channels: 3, image: rgb, hole: hole, source: src, options: opts)
        #expect(a == b)
        #expect(a.allSatisfy { $0.isFinite && (0...1).contains($0) })
    }

    /// photocraft `color_adaptation_follows_a_gradient`.
    @Test func colorAdaptationFollowsAGradient() {
        let (w, h) = (40, 20)
        let img: [Float] = (0..<(w * h)).map { Float($0 % w) / Float(w) }
        let hole: [Bool] = (0..<(w * h)).map { (14..<26).contains($0 % w) && (5..<15).contains($0 / w) }
        let out = K.fill(width: w, height: h, channels: 1, image: img, hole: hole, source: [Bool](repeating: true, count: w * h),
                         options: K.FillOptions(colorAdaptation: K.colorLevel("veryHigh")))
        let err = (0..<(w * h)).filter { hole[$0] }.reduce(Float(0)) { $0 + abs(out[$1] - img[$1]) } / 120
        #expect(err < 0.12, "mean error \(err)")
    }

    /// photocraft `sampling_window_is_photoshops`.
    @Test func samplingWindowIsPhotoshops() {
        let canvas = PixelRect(x0: 0, y0: 0, x1: 800, y1: 800)
        func sq(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int) -> PixelRect { PixelRect(x: x0, y: y0, width: w, height: h) }
        #expect(K.samplingWindow(hole: sq(375, 375, 50, 50), canvas: canvas) == sq(300, 300, 200, 200))
        #expect(K.samplingWindow(hole: sq(350, 350, 100, 100), canvas: canvas) == sq(200, 200, 400, 400))
        #expect(K.samplingWindow(hole: sq(395, 395, 10, 10), canvas: canvas) == sq(300, 300, 200, 200))
        #expect(K.samplingWindow(hole: sq(370, 370, 60, 60), canvas: canvas) == sq(280, 280, 240, 240))
        #expect(K.samplingWindow(hole: sq(350, 385, 100, 30), canvas: canvas) == sq(258, 258, 283, 283))
        #expect(K.samplingWindow(hole: sq(300, 375, 200, 50), canvas: canvas) == sq(200, 200, 400, 400))
        #expect(K.samplingWindow(hole: sq(250, 350, 300, 100), canvas: canvas) == sq(53, 53, 693, 693))
        #expect(K.samplingWindow(hole: sq(10, 375, 50, 50), canvas: canvas) == sq(0, 300, 200, 200))
        #expect(K.samplingWindow(hole: sq(5, 5, 60, 60), canvas: canvas) == sq(0, 0, 240, 240))
        #expect(K.samplingWindow(hole: sq(40, 40, 50, 50), canvas: PixelRect(x0: 0, y0: 0, x1: 150, y1: 120)) == PixelRect(x0: 0, y0: 0, x1: 150, y1: 120))
        #expect(K.samplingWindow(hole: sq(100, 995, 1800, 10), canvas: PixelRect(x0: 0, y0: 0, x1: 2000, y1: 2000)) == sq(100, 400, 1800, 1200))
        #expect(K.samplingWindow(hole: .empty, canvas: canvas) == .empty)
    }

    /// photocraft `auto_sampling_keeps_what_looks_like_the_surroundings`.
    @Test func autoSamplingKeepsWhatLooksLikeTheSurroundings() {
        let (w, h) = (200, 200)
        let tex = Self.noise(w, h, 3)
        func shade(_ x: Int, _ band: Bool) -> Float {
            band ? ((130..<150).contains(x) ? 0.55 : 0.35) : (x < 135 ? 0.35 : 0.55)
        }
        for band in [false, true] {
            let img: [Float] = (0..<(w * h * 3)).map { shade(($0 / 3) % w, band) + (tex[$0] - 0.5) * 0.1 }
            let hole: [Bool] = (0..<(w * h)).map { (75..<125).contains($0 % w) && (75..<125).contains($0 / w) }
            let area = K.autoSampling(width: w, height: h, channels: 3, image: img, hole: hole)
            func frac(_ x0: Int, _ x1: Int) -> Float {
                let n = (0..<(w * h)).filter { (x0..<x1).contains($0 % w) && !hole[$0] }.count
                return Float((0..<(w * h)).filter { (x0..<x1).contains($0 % w) && area[$0] }.count) / Float(n)
            }
            #expect(zip(hole, area).allSatisfy { !($0 && $1) }, "never the hole")
            #expect(frac(0, 125) > 0.95, "the dark side is sampled (\(frac(0, 125)))")
            if band {
                #expect(frac(133, 147) < 0.05, "the band is excluded (\(frac(133, 147)))")
                #expect(frac(155, 200) > 0.9, "beyond the band is sampled (\(frac(155, 200)))")
            } else {
                #expect(frac(140, 200) < 0.05, "the bright side is excluded (\(frac(140, 200)))")
            }
        }
    }

    /// photocraft `without_colour_adaptation_the_fill_copies_pixels_exactly`.
    @Test func withoutColourAdaptationTheFillCopiesPixelsExactly() {
        let (w, h) = (120, 120)
        let fine = Self.noise(w, h, 9)
        let img: [Float] = (0..<(w * h * 3)).map { i in
            let (x, y, c) = (Float((i / 3) % w), Float((i / 3) / w), i % 3)
            return 0.5 + 0.2 * sinf(x * 0.21 + Float(c)) * cosf(y * 0.17) + 0.1 * sinf(x * 0.05 - y * 0.08) + (fine[i] - 0.5) * 0.08
        }
        let hole: [Bool] = (0..<(w * h)).map { (40..<80).contains($0 % w) && (40..<80).contains($0 / w) }
        func key(_ v: [Float], _ i: Int) -> [Int64] { (0..<3).map { Int64((v[i * 3 + $0] * 1e5).rounded()) } }
        let known = Set((0..<(w * h)).filter { !hole[$0] }.map { key(img, $0) })
        let out = K.fill(width: w, height: h, channels: 3, image: img, hole: hole, source: [Bool](repeating: true, count: w * h),
                         options: K.FillOptions(colorAdaptation: .none))
        let exact = (0..<(w * h)).filter { hole[$0] && known.contains(key(out, $0)) }.count
        #expect(Float(exact) > 0.2 * 1600, "\(exact) of 1600 filled pixels are exact copies")
        func lap(_ v: [Float], _ x: Int, _ y: Int) -> Float {
            let p = { (x: Int, y: Int) in v[(y * w + x) * 3] }
            return abs(4 * p(x, y) - p(x - 1, y) - p(x + 1, y) - p(x, y - 1) - p(x, y + 1))
        }
        func mean(_ inside: Bool) -> Float {
            var s: Float = 0
            var n = 0
            for y in 1..<(h - 1) { for x in 1..<(w - 1) where hole[y * w + x] == inside { s += lap(out, x, y); n += 1 } }
            return s / Float(n)
        }
        #expect(mean(true) > 0.6 * mean(false), "fill detail \(mean(true)) against \(mean(false))")
    }

    /// photocraft `patch_color_shifts_up_to_about_four_hundredths_per_step`.
    @Test func patchColorShiftsUpToAboutFourHundredthsPerStep() {
        let from: [Float] = (0..<300).map { 0.7 + 0.05 * (Float($0 % 7) / 7) }
        let to = from.map { $0 - 0.4 }
        let level = from.reduce(0, +) / 300
        func shift(_ c: UInt8) -> Float {
            let gb = K.levelTransform(channels: 1, from: from, to: to, adapt: K.colorAmount(c))
            return level - from.reduce(Float(0)) { $0 + gb[0].x * $1 + gb[0].y } / 300
        }
        #expect(shift(0) == 0)
        #expect(abs(shift(3) - 0.12) < 0.01, "\(shift(3))")
        #expect(abs(shift(10) - 0.4) < 0.01, "\(shift(10))")
    }

    /// photocraft `variant_geometry`.
    @Test func variantGeometry() throws {
        let img = [Float](repeating: 0.5, count: 60), ok = [Bool](repeating: true, count: 60)
        let v = try K.variant(10, 6, 1, img, ok, 90, 1, false, .none)
        #expect((v.w, v.h) == (6, 10))
        let v2 = try K.variant(10, 6, 1, img, ok, 0, 0.8, true, .none)
        #expect((v2.w, v2.h) == (8, 5))
        #expect(v2.ok.filter { $0 }.count > 20)
    }
}
