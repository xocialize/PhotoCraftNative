// Port of photocraft-algo (crates/algo/src/other2.rs, video.rs, color_to_alpha.rs tests; tests_ext.rs, tests_selection_mix.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct ToneFilterTests {
    /// `Parity.check` returns nil (and the parity tests pass vacuously) when the shader library
    /// fails to compile; with a Metal device that must be an error.
    @Test func shaderLibraryCompiles() throws {
        if MetalContext.shared != nil { _ = try AlgoGPU.shared() }
    }

    // MARK: Parity

    @Test func hsbHslParity() throws {
        var worst: Float = 0
        for i in HsbModel.allCases {
            for o in HsbModel.allCases {
                worst = max(worst, try Parity.checkVariants(HsbHsl(input: i, output: o)))
            }
        }
        // HDR input (clamped to 0–1 first).
        let r = PixelRect(x: 0, y: 0, width: 40, height: 31)
        let hdr = TestImage.make(r, channels: 4, alpha: true, seed: 4, eightBit: false, hdr: true)
        for (i, o) in [(HsbModel.rgb, HsbModel.hsl), (.hsb, .rgb), (.hsl, .hsb)] {
            if let e = try Parity.check(HsbHsl(input: i, output: o), src: hdr, ctx: FilterContext(bounds: r, mode: .rgb, alpha: true)) {
                worst = max(worst, e)
            }
        }
        ParityLog.record("HsbHsl", worst)
    }

    @Test func deInterlaceParity() throws {
        var worst: Float = 0
        for e in [false, true] {
            for i in [false, true] {
                worst = max(worst, try Parity.checkVariants(DeInterlace(eliminateEven: e, interpolate: i)))
                // Bounds inside the output: edge lines, and pixels outside kept.
                let out = PixelRect(x: 0, y: 0, width: 30, height: 24)
                let bounds = PixelRect(x: 4, y: 3, width: 20, height: 15)
                let img = TestImage.make(out.outset(by: 2), channels: 4, alpha: true, seed: 2)
                if let err = try Parity.check(DeInterlace(eliminateEven: e, interpolate: i), src: img, out: out,
                                              ctx: FilterContext(bounds: bounds, mode: .rgb, alpha: true)) {
                    worst = max(worst, err)
                }
            }
        }
        ParityLog.record("DeInterlace", worst)
    }

    @Test func ntscParity() throws {
        var worst = try Parity.checkVariants(NTSCColors())
        let r = PixelRect(x: 0, y: 0, width: 40, height: 31)
        for ch in [3, 4] {
            let hdr = TestImage.make(r, channels: ch, alpha: ch == 4, seed: 6, eightBit: false, hdr: true)
            if let e = try Parity.check(NTSCColors(), src: hdr, ctx: FilterContext(bounds: r, mode: .rgb, alpha: ch == 4), relative: true) {
                worst = max(worst, e)
            }
        }
        // Saturated colours (the limit actually acts).
        var sat = FloatImage(rect: r, channels: 4)
        for i in 0..<r.area {
            let h = Float(i % 97) / 97, s = Float(i % 13) / 12
            let rgb = ToneKit.hsbToRGB(SIMD3(h, s, 1))
            sat.data[i * 4] = rgb.x; sat.data[i * 4 + 1] = rgb.y; sat.data[i * 4 + 2] = rgb.z; sat.data[i * 4 + 3] = 1
        }
        if let e = try Parity.check(NTSCColors(), src: sat, ctx: FilterContext(bounds: r, mode: .rgb, alpha: true)) { worst = max(worst, e) }
        ParityLog.record("NTSCColors", worst)
    }

    @Test func colorToAlphaParity() throws {
        var worst: Float = 0
        let cases = [
            ColorToAlpha(),
            ColorToAlpha(color: SIMD4(0.5, 0.25, 0.75, 1), transparencyThreshold: 0.1, opacityThreshold: 0.9),
            ColorToAlpha(color: SIMD4(0, 0, 0, 1)),
            ColorToAlpha(color: SIMD4(1, 0, 0.5, 1), transparencyThreshold: 0.6, opacityThreshold: 0.4),
            ColorToAlpha(color: SIMD4(0.3, 0.6, 0.2, 1), transparencyThreshold: 0.5, opacityThreshold: 0.5),
        ]
        for f in cases { worst = max(worst, try Parity.checkVariants(f)) }
        // Lab + alpha runs on the GPU too (per stored channel).
        let r = PixelRect(x: 0, y: 0, width: 33, height: 21)
        let lab = TestImage.make(r, channels: 4, alpha: true, seed: 3)
        for f in cases {
            if let e = try Parity.check(f, src: lab, ctx: FilterContext(bounds: r, mode: .lab, alpha: true)) { worst = max(worst, e) }
        }
        ParityLog.record("ColorToAlpha", worst)
    }

    // MARK: photocraft other2.rs / tests_ext.rs

    /// photocraft `hsb_hsl_round_trip`.
    @Test func hsbHslRoundTrip() {
        for c: SIMD3<Float> in [SIMD3(0.2, 0.7, 0.4), SIMD3(1, 0, 0), SIMD3(0.5, 0.5, 0.5), SIMD3(0.1, 0.2, 0.9), SIMD3(0.9, 0.8, 0.05)] {
            let a = ToneKit.hsbToRGB(ToneKit.rgbToHSB(c))
            let b = ToneKit.hslToRGB(ToneKit.rgbToHSL(c))
            for k in 0..<3 { #expect(abs(a[k] - c[k]) < 1e-5 && abs(b[k] - c[k]) < 1e-5, "\(c) \(a) \(b)") }
        }
        #expect(ToneKit.rgbToHSB(SIMD3(1, 0, 0)) == SIMD3(0, 1, 1))
        let l = ToneKit.rgbToHSL(SIMD3(0, 0, 1))
        #expect(abs(l[0] - 2.0 / 3.0) < 1e-6 && abs(l[2] - 0.5) < 1e-6)
    }

    static let r = PixelRect(x: 0, y: 0, width: 40, height: 30)
    static let ctx = FilterContext(bounds: r, mode: .rgb, alpha: true)

    static func flat(_ px: SIMD4<Float>) -> FloatImage {
        FloatImage(rect: r, channels: 4, data: (0..<r.area).flatMap { _ in [px.x, px.y, px.z, px.w] })
    }

    static func run<F: Filter>(_ img: FloatImage, _ f: F, on backend: Backend = .cpu) throws -> FloatImage {
        var src = img
        if case .radius(let h) = f.halo(bounds: r), h > 0 { src = img.crop(r.outset(by: h)) }
        return try FilterEngine.apply(f, to: src, output: r, context: ctx, on: backend)
    }

    static func px(_ img: FloatImage, _ x: Int32, _ y: Int32) -> [Float] {
        let i = img.index(x: x, y: y)
        return Array(img.data[i..<i + img.channels])
    }

    /// photocraft `hsb_filter_encodes_and_decodes`.
    @Test func hsbFilterEncodesAndDecodes() throws {
        for backend in [Backend.cpu, .auto] {
            let s = Self.flat(SIMD4(1, 0, 0, 1))
            let hsb = try Self.run(s, HsbHsl(input: .rgb, output: .hsb), on: backend)
            #expect(Self.px(hsb, 3, 3) == [0, 1, 1, 1])
            let back = try Self.run(hsb, HsbHsl(input: .hsb, output: .rgb), on: backend)
            #expect(Self.px(back, 3, 3) == Self.px(s, 3, 3))
        }
    }

    /// photocraft `identities_at_zero_strength` (HSB → HSB).
    @Test func hsbIdentity() throws {
        let s = TestImage.make(Self.r, channels: 4, alpha: true)
        let out = try Self.run(s, HsbHsl(input: .hsb, output: .hsb), on: .auto)
        #expect(out == s)
    }

    /// photocraft `deinterlace_rebuilds_a_field`.
    @Test func deinterlaceRebuildsAField() throws {
        for backend in [Backend.cpu, .gpu] where backend == .cpu || AlgoGPU.isAvailable {
            var s = FloatImage(rect: Self.r, channels: 4)
            for y in 0..<Int32(30) {
                let v: Float = y % 2 == 0 ? 0.8 : 0.2
                for x in 0..<Int32(40) { let i = s.index(x: x, y: y); s.data[i..<i + 4] = [v, v, v, 1] }
            }
            // Eliminate odd lines (offsets 0, 2…): the kept 0.2 lines fill in.
            let out = try Self.run(s, DeInterlace(eliminateEven: false, interpolate: false), on: backend)
            for y in 0..<Int32(30) { #expect(abs(Self.px(out, 10, y)[0] - 0.2) < 1e-6, "y=\(y)") }
            let even = try Self.run(s, DeInterlace(eliminateEven: true, interpolate: true), on: backend)
            #expect(abs(Self.px(even, 10, 5)[0] - 0.8) < 1e-6)
        }
    }

    /// photocraft `flat_images_stay_flat` (De-Interlace).
    @Test func deinterlaceKeepsFlat() throws {
        let c = SIMD4<Float>(0.3, 0.55, 0.8, 1)
        let out = try Self.run(Self.flat(c), DeInterlace(eliminateEven: true, interpolate: true), on: .auto)
        let p = Self.px(out, 20, 15)
        for k in 0..<4 { #expect(abs(p[k] - c[k]) < 2e-3) }
    }

    /// photocraft `ntsc_limits_saturated_colours_only`.
    @Test func ntscLimitsSaturatedColoursOnly() throws {
        for backend in [Backend.cpu, .auto] {
            let gray = Self.flat(SIMD4(0.5, 0.5, 0.5, 1))
            #expect(Self.px(try Self.run(gray, NTSCColors(), on: backend), 3, 3) == Self.px(gray, 3, 3))
            let yellow = Self.flat(SIMD4(1, 1, 0, 1))
            let y = Self.px(try Self.run(yellow, NTSCColors(), on: backend), 3, 3)
            #expect(y[2] > 0.05, "yellow desaturated: \(y)")
            let l = { (p: [Float]) in 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2] }
            #expect(abs(l(y) - l([1, 1, 0])) < 1e-3, "luma kept")
        }
    }

    // MARK: photocraft color_to_alpha.rs

    static func close(_ a: Float, _ b: Float, _ tol: Float) -> Bool { abs(a - b) <= tol }

    @Test func keyColourBecomesFullyTransparent() {
        var px: [Float] = [1, 1, 1]
        #expect(ColorToAlpha.unmix(&px, key: [1, 1, 1], transparency: 0, opacityThreshold: 1) == 0)
        px = [0.2, 0.4, 0.6]
        #expect(ColorToAlpha.unmix(&px, key: [0.2, 0.4, 0.6], transparency: 0, opacityThreshold: 1) == 0)
    }

    @Test func greyOnWhiteIsBlackWithPartialAlpha() {
        var px: [Float] = [0.7, 0.7, 0.7]
        let a = ColorToAlpha.unmix(&px, key: [1, 1, 1], transparency: 0, opacityThreshold: 1)
        #expect(Self.close(a, 0.3, 1e-6))
        #expect(px.allSatisfy { Self.close($0, 0, 1e-5) })
        px = [0, 0, 0]
        #expect(ColorToAlpha.unmix(&px, key: [1, 1, 1], transparency: 0, opacityThreshold: 1) == 1)
        #expect(px == [0, 0, 0])
    }

    @Test func unmixedColourCompositedOverTheKeyGivesBackThePixel() {
        let key: [Float] = [0.2, 0.6, 0.9]
        for p: [Float] in [[0.5, 0.5, 0.5], [0.1, 0.9, 0.95], [0.25, 0.6, 0], [1, 0, 0.3]] {
            var q = p
            let a = ColorToAlpha.unmix(&q, key: key, transparency: 0, opacityThreshold: 1)
            #expect(q.allSatisfy { (0...1).contains($0) })
            for i in 0..<3 { #expect(Self.close(a * q[i] + (1 - a) * key[i], p[i], 1e-5), "\(p) → \(q) a=\(a)") }
        }
    }

    @Test func thresholdsClipAndStretchTheOpacity() {
        #expect(ColorToAlpha.remap(0.1, transparency: 0.2, opacity: 0.8) == 0)
        #expect(ColorToAlpha.remap(0.2, transparency: 0.2, opacity: 0.8) == 0)
        #expect(ColorToAlpha.remap(0.8, transparency: 0.2, opacity: 0.8) == 1)
        #expect(Self.close(ColorToAlpha.remap(0.5, transparency: 0.2, opacity: 0.8), 0.5, 1e-6))
        #expect(ColorToAlpha.remap(0.5, transparency: 0.6, opacity: 0.4) == 0)
        #expect(ColorToAlpha.remap(0.7, transparency: 0.6, opacity: 0.4) == 1)
        #expect(ColorToAlpha.remap(0.5, transparency: 0.5, opacity: 0.5) == 0)
        var px: [Float] = [0.95, 0.95, 0.95]
        #expect(ColorToAlpha.unmix(&px, key: [1, 1, 1], transparency: 0.1, opacityThreshold: 1) == 0)
        px = [0.4, 0.4, 0.4]
        #expect(ColorToAlpha.unmix(&px, key: [1, 1, 1], transparency: 0, opacityThreshold: 0.5) == 1)
        #expect(px == [0.4, 0.4, 0.4])
    }

    @Test func hdrAndNonFiniteSamplesStayOpaqueAndFinite() {
        var px: [Float] = [1.5, 1, 1]
        #expect(ColorToAlpha.unmix(&px, key: [1, 1, 1], transparency: 0, opacityThreshold: 1) == 1)
        #expect(px == [1.5, 1, 1])
        px = [.nan, 0.5, 0.5]
        let a = ColorToAlpha.unmix(&px, key: [1, 1, 1], transparency: 0, opacityThreshold: 1)
        #expect(a.isFinite && Self.close(a, 0.5, 1e-6))
        px = [0.25, 0.5, 0]
        let b = ColorToAlpha.unmix(&px, key: [0, 0, 0], transparency: 0, opacityThreshold: 1)
        #expect(Self.close(b, 0.5, 1e-6))
        #expect(Self.close(px[0], 0.5, 1e-6) && Self.close(px[1], 1, 1e-6) && Self.close(px[2], 0, 1e-6), "\(px)")
    }

    /// photocraft `works_at_every_depth_and_multiplies_existing_alpha`.
    @Test func worksAtEveryDepthAndMultipliesExistingAlpha() throws {
        let r = PixelRect(x: 0, y: 0, width: 4, height: 1)
        for format in [PixelFormat.rgba8, .rgba16, .rgba32f] {
            for backend in [Backend.cpu, .auto] {
                var s = Surface(format: format)
                s.writeRegion(r, [1, 1, 1, 1, 0.6, 0.6, 0.6, 1, 0, 0, 0, 1, 0.6, 0.6, 0.6, 0.5])
                let orig = s
                try FilterEngine.apply(ColorToAlpha(), to: &s, area: r, bounds: r, on: backend)
                let tol: Float = format.sample == .u8 ? 2.0 / 255.0 : 1e-3
                #expect(Self.close(s.pixel(x: 0, y: 0)[3], 0, tol), "\(format) white gone")
                let edge = s.pixel(x: 1, y: 0)
                #expect(Self.close(edge[3], 0.4, tol) && Self.close(edge[0], 0, tol), "\(format) edge \(edge)")
                #expect(s.pixel(x: 2, y: 0) == orig.pixel(x: 2, y: 0), "\(format) black kept")
                #expect(Self.close(s.pixel(x: 3, y: 0)[3], 0.2, tol), "\(format) alpha multiplied")
            }
        }
    }

    /// photocraft `grayscale_uses_the_key_converted_to_gray`.
    @Test func grayscaleUsesTheKeyConvertedToGray() throws {
        let r = PixelRect(x: 0, y: 0, width: 2, height: 1)
        for sample in [SampleType.u8, .u16, .f32] {
            var s = Surface(format: PixelFormat(mode: .grayscale, sample: sample, alpha: true))
            s.writeRegion(r, [1, 1, 0.75, 1])
            try FilterEngine.apply(ColorToAlpha(), to: &s, area: r, bounds: r, on: .auto)
            let tol: Float = sample == .u8 ? 2.0 / 255.0 : 1e-3
            #expect(Self.close(s.pixel(x: 0, y: 0)[1], 0, tol))
            let p = s.pixel(x: 1, y: 0)
            #expect(Self.close(p[0], 0, tol) && Self.close(p[1], 0.25, tol), "\(sample) \(p)")
        }
    }

    /// photocraft `coloured_key_on_a_coloured_background`.
    @Test func colouredKeyOnAColouredBackground() throws {
        let r = PixelRect(x: 0, y: 0, width: 2, height: 1)
        var s = Surface(format: .rgba32f)
        s.writeRegion(r, [0.2, 0.4, 0.8, 1, 0.1, 0.2, 0.4, 1])
        try FilterEngine.apply(ColorToAlpha(color: SIMD4(0.2, 0.4, 0.8, 1)), to: &s, area: r, bounds: r, on: .auto)
        #expect(s.pixel(x: 0, y: 0)[3] < 1e-6)
        let p = s.pixel(x: 1, y: 0)
        #expect(Self.close(p[3], 0.5, 1e-5) && p[0..<3].allSatisfy { Self.close($0, 0, 1e-5) }, "\(p)")
    }

    /// photocraft `surfaces_without_alpha_are_left_alone`.
    @Test func surfacesWithoutAlphaAreLeftAlone() throws {
        let r = PixelRect(x: 0, y: 0, width: 2, height: 2)
        var s = Surface(format: .gray8)
        s.fill(r, with: [1])
        let before = s.readRegion(r)
        try FilterEngine.apply(ColorToAlpha(), to: &s, area: r, bounds: r, on: .auto)
        #expect(s.readRegion(r) == before)
    }

    /// photocraft `feathered_color_to_alpha_preserves_appearance_over_the_key` (tests_selection_mix.rs).
    @Test func featheredColorToAlphaPreservesAppearanceOverTheKey() throws {
        let r = PixelRect(x: 0, y: 0, width: 1, height: 1)
        for sample in [SampleType.u8, .u16, .f32] {
            for mode in [ColorMode.rgb, .grayscale] {
                for alpha: Float in [0.5, 1] {
                    let format = PixelFormat(mode: mode, sample: sample, alpha: true)
                    var p = [Float](repeating: 0.5, count: format.channels)
                    p[p.count - 1] = alpha
                    var s0 = Surface(format: format)
                    s0.setPixel(x: 0, y: 0, p)
                    let original = s0.pixel(x: 0, y: 0)
                    let a = format.channels - 1
                    for coverage: Float in [0, 0.25, 0.5, 0.75, 1] {
                        var s = s0
                        let sel = Surface(format: PixelFormat(mode: .grayscale, sample: .f32, alpha: false), defaultPixel: [coverage])
                        try FilterEngine.apply(ColorToAlpha(), to: &s, area: r, bounds: r, selection: sel, on: .auto)
                        let actual = s.pixel(x: 0, y: 0)
                        let tol: Float = sample == .u8 ? 2.0 / 255.0 : 1e-4
                        for c in 0..<a {
                            let before = original[c] * original[a] + 1 - original[a]
                            let after = actual[c] * actual[a] + 1 - actual[a]
                            #expect(abs(before - after) < tol, "\(sample)/\(mode) alpha \(alpha) coverage \(coverage): \(original) → \(actual)")
                        }
                    }
                }
            }
        }
    }
}
