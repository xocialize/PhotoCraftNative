// Port of photocraft-compose (crates/compose/src/adjust.rs tests) and photocraft-gpu (adjustment parity), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
import PCDocument
import PCFoundation
@testable import PCRender

enum AdjustFixtures {
    static let line = [CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)]
    static func lut3D(_ n: Int, warp: Bool) -> [Float] {
        var t: [Float] = []
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let c = SIMD3(Float(r), Float(g), Float(b)) / Float(n - 1)
            let o = warp ? SIMD3(c.y * 0.8 + 0.1 * c.x, sqrtf(c.x), c.z * c.z) : c
            t += [o.x, o.y, o.z]
        } } }
        return t
    }
    static var ranges: [HueRange] {
        var r = HueRange.defaults
        r[0].saturation = -60; r[2].hue = 40; r[4].lightness = 35; r[5].saturation = 30; r[5].lightness = -20
        return r
    }

    /// Every adjustment variant the compositor evaluates.
    static var all: [(String, Adjustment)] {
        var a: [(String, Adjustment)] = []
        a.append(("invert", .invert))
        a.append(("threshold", .threshold(level: 0.47)))
        a.append(("posterize4", .posterize(levels: 4)))
        a.append(("posterize13", .posterize(levels: 13)))
        a.append(("bc-legacy+", .brightnessContrast(brightness: 40, contrast: 30, legacy: true)))
        a.append(("bc-legacy-", .brightnessContrast(brightness: -23, contrast: -26, legacy: true)))
        a.append(("bc-modern", .brightnessContrast(brightness: 60, contrast: 45, legacy: false)))
        a.append(("bc-modern-", .brightnessContrast(brightness: -80, contrast: -30, legacy: false)))
        a.append(("exposure", .exposure(exposure: 0.8, offset: 0.02, gamma: 1.3)))
        a.append(("exposure-", .exposure(exposure: -1.2, offset: -0.01, gamma: 0.8)))
        a.append(("levels", .levels(master: LevelsChannel(inBlack: 0.1, inWhite: 0.9, gamma: 1.6, outBlack: 0.05, outWhite: 0.95),
                               perChannel: [LevelsChannel(gamma: 0.7), LevelsChannel(inBlack: 0.2), LevelsChannel(outWhite: 0.8)],
                               space: .rgb, black: .identity)))
        a.append(("levels-lab", .levels(master: .identity, perChannel: [LevelsChannel(gamma: 1.4), LevelsChannel(inBlack: 0.3), .identity], space: .lab, black: .identity)))
        a.append(("levels-cmyk", .levels(master: LevelsChannel(gamma: 0.9), perChannel: [LevelsChannel(inBlack: 0.1), .identity, .identity], space: .cmyk,
                                    black: LevelsChannel(outWhite: 0.7))))
        a.append(("curves", .curves(master: [CurvePoint(input: 0, output: 0.05), CurvePoint(input: 0.4, output: 0.55), CurvePoint(input: 1, output: 0.95)],
                               perChannel: [line, [CurvePoint(input: 0, output: 0), CurvePoint(input: 0.5, output: 0.3), CurvePoint(input: 1, output: 1)], line],
                               space: .rgb, black: [], pencil: false)))
        a.append(("curves-pencil", .curves(master: curveMap((0..<256).map { Float($0) / 255 * 0.9 + (Float($0 % 32) / 31) * 0.05 }), perChannel: [line, line, line],
                                      space: .rgb, black: [], pencil: true)))
        a.append(("curves-lab", .curves(master: line, perChannel: [[CurvePoint(input: 0, output: 0.2), CurvePoint(input: 1, output: 1)], line, line],
                                   space: .lab, black: [], pencil: false)))
        a.append(("hue-sat", .hueSaturation(hue: 40, saturation: 25, lightness: -10, colorize: false, ranges: HueRange.defaults)))
        a.append(("hue-sat-ranges", .hueSaturation(hue: -15, saturation: -20, lightness: 10, colorize: false, ranges: ranges)))
        a.append(("colorize", .hueSaturation(hue: 200, saturation: 45, lightness: 20, colorize: true, ranges: HueRange.defaults)))
        a.append(("vibrance+", .vibrance(vibrance: 60, saturation: 20)))
        a.append(("vibrance-", .vibrance(vibrance: -70, saturation: -30)))
        a.append(("color-balance", .colorBalance(shadows: SIMD3(-40, 20, 10), midtones: SIMD3(30, -15, 50), highlights: SIMD3(60, 0, -25), preserveLuminosity: false)))
        a.append(("color-balance-pl", .colorBalance(shadows: SIMD3(50, 0, 50), midtones: SIMD3(100, 0, 0), highlights: SIMD3(-50, 50, 0), preserveLuminosity: true)))
        a.append(("black-white", .blackWhite(weights: [40, 60, 40, 60, 20, 80], tint: nil)))
        a.append(("black-white-tint", .blackWhite(weights: [70, 30, 50, 90, 10, 60], tint: SIMD3(0.88, 0.83, 0.70))))
        a.append(("photo-filter", .photoFilter(color: SIMD3(0.93, 0.54, 0.09), density: 0.25, preserveLuminosity: false)))
        a.append(("photo-filter-pl", .photoFilter(color: SIMD3(0.1, 0.4, 0.9), density: 0.6, preserveLuminosity: true)))
        a.append(("channel-mixer", .channelMixer(matrix: [SIMD4(0.8, 0.3, -0.1, 0.02), SIMD4(0.1, 0.9, 0.1, 0), SIMD4(-0.2, 0.2, 1.1, -0.03)], monochrome: false)))
        a.append(("channel-mixer-mono", .channelMixer(matrix: [SIMD4(0.4, 0.4, 0.2, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0)], monochrome: true)))
        a.append(("lookup-tri", .colorLookup(name: "warp", lut: lut3D(9, warp: true), size: 9, tetrahedral: false, dither: false)))
        a.append(("lookup-tet-dither", .colorLookup(name: "warp", lut: lut3D(5, warp: true), size: 5, tetrahedral: true, dither: true)))
        a.append(("gradient-map", .gradientMap(stops: [GradientMapStop(0, SIMD3(0.1, 0, 0.3)), GradientMapStop(0.4, SIMD3(0.9, 0.2, 0.1)), GradientMapStop(1, SIMD3(1, 1, 0.8))],
                                          reverse: false, dither: false)))
        a.append(("gradient-map-rev-dither", .gradientMap(stops: [GradientMapStop(0, SIMD3(0, 0, 0)), GradientMapStop(1, SIMD3(1, 1, 1))], reverse: true, dither: true)))
        var rel: [SIMD4<Float>] = [], abso: [SIMD4<Float>] = []
        for i in 0..<9 {
            let f = Float(i)
            rel.append(SIMD4<Float>(f * 4 - 20, 25 - f * 6, f * 3 - 15, 10 - f * 2))
            abso.append(SIMD4<Float>(f * 7 - 30, 20 - f * 5, 25, -10))
        }
        a.append(("selective-rel", .selectiveColor(relative: true, adjustments: rel)))
        a.append(("selective-abs", .selectiveColor(relative: false, adjustments: abso)))
        a.append(("unsupported", .unsupported(psdKey: "xxxx", raw: [])))
        return a
    }

    static let rect = PixelRect(x: 3, y: -2, width: 64, height: 36)
    static let leaf = LeafID(layer: 9, role: .content)

    /// A colourful, partly transparent test image (greys, saturated hues, a ramp).
    static func source(_ depth: SampleType) -> LeafTable {
        var rng = Rng(77)
        let fmt = PixelFormat(mode: .rgb, sample: depth, alpha: true)
        let s = TS.surface(rect, format: fmt) { x, y in
            let u = Float(x - rect.x0) / 63, v = Float(y - rect.y0) / 35
            if y - rect.y0 < 4 { return SIMD4(u, u, u, 1) }
            if (x + y) % 7 == 0 { return SIMD4(0, 0, 0, 0) }
            let hue = SIMD3<Float>(0.5 + 0.5 * cosf(6.283 * u), 0.5 + 0.5 * cosf(6.283 * (u - 0.333)), 0.5 + 0.5 * cosf(6.283 * (u - 0.667)))
            let c = hue * (1 - v) + SIMD3(repeating: v) * rng.float(0.2, 1)
            return SIMD4(c, rng.float(0.4, 1))
        }
        return LeafTable(leaves: [leaf: .surface(s)])
    }

    static func plan(_ adj: Adjustment, _ ctx: RenderContext, quantize: Bool = true) -> RenderPlan {
        var ops: [DrawOp] = [.pushTransparent, .drawTiles(DrawTiles(leaf: leaf)), .composite(LayerBlend()),
                             .pick(0), .adjust(adj), .adjustMix(AdjustMix(mode: .normal, opacity: 1))]
        if quantize, let q = ctx.quantum { ops.append(.quantize(q)) }
        return RenderPlan(context: ctx, ops: ops)
    }
}

@Suite struct AdjustmentParityTests {
    @Test(arguments: AdjustFixtures.all.map(\.0))
    func adjustmentParity(_ name: String) throws {
        let adj = AdjustFixtures.all.first { $0.0 == name }!.1
        for depth in [SampleType.u8, .u16, .f32] {
            for mode in [ColorMode.rgb, .lab] {
                let ctx = RenderContext(canvas: AdjustFixtures.rect, mode: mode, depth: depth)
                let plan = AdjustFixtures.plan(adj, ctx, quantize: false)
                let (cpu, gpu) = try TS.both(plan, AdjustFixtures.rect, AdjustFixtures.source(depth))
                guard let gpu else { return }
                let d = TS.diff(cpu, gpu)
                #expect(d.max <= 1.0 / 255, "\(name) \(depth) \(mode): \(d.max) at \(d.at): cpu \(cpu.px[d.at]) gpu \(gpu.px[d.at])")
            }
        }
    }

    @Test func adjustmentLayerChainParityWithQuantize() throws {
        let ctx = RenderContext(canvas: AdjustFixtures.rect, depth: .u8)
        var ops: [DrawOp] = [.pushTransparent, .drawTiles(DrawTiles(leaf: AdjustFixtures.leaf)), .composite(LayerBlend())]
        for (_, a) in AdjustFixtures.all.prefix(12) { ops += [.pick(0), .adjust(a), .adjustMix(AdjustMix(mode: .normal, opacity: 0.85)), .quantize(255)] }
        let (cpu, gpu) = try TS.both(RenderPlan(context: ctx, ops: ops), AdjustFixtures.rect, AdjustFixtures.source(.u8))
        guard let gpu else { return }
        let d = TS.diff(cpu, gpu)
        #expect(d.levels <= 1, "\(d.max)")
    }
}

/// photocraft's adjust.rs tests (Photoshop 27.11 measurements) against the Swift reference.
@Suite struct AdjustmentReferenceTests {
    func apply(_ adj: Adjustment, _ c: SIMD3<Float>, mode: ColorMode = .rgb, depth: SampleType? = nil) -> SIMD3<Float> {
        var b = RGBABuffer(rect: PixelRect(x: 0, y: 0, width: 1, height: 1), filled: SIMD4(c, 1))
        PreparedAdjustment(adj, transfer: .srgb, depth: depth, mode: mode).apply(to: &b)
        return SIMD3(b.px[0].x, b.px[0].y, b.px[0].z)
    }

    @Test func legacyBrightnessContrastMatchesPhotoshop() {
        let x: [Float] = [0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224, 240, 255]
        let measured: [(Float, Float, [Float])] = [
            (40, 0, [40, 56, 72, 88, 104, 120, 136, 152, 168, 184, 200, 216, 232, 248, 255, 255, 255]),
            (-40, 0, [0, 0, 0, 8, 24, 40, 56, 72, 88, 104, 120, 136, 152, 168, 184, 200, 215]),
            (0, 30, [0, 0, 0, 14, 37, 60, 82, 105, 128, 151, 174, 196, 219, 242, 255, 255, 255]),
            (0, -30, [38, 49, 61, 72, 83, 94, 106, 117, 128, 139, 150, 162, 173, 184, 195, 207, 217]),
            (40, 30, [3, 25, 48, 71, 94, 117, 139, 162, 185, 208, 231, 253, 255, 255, 255, 255, 255]),
            (100, 0, [100, 116, 132, 148, 164, 180, 196, 212, 228, 244, 255, 255, 255, 255, 255, 255, 255]),
            (0, 80, [0, 0, 0, 0, 0, 0, 0, 48, 128, 208, 255, 255, 255, 255, 255, 255, 255]),
        ]
        for (b, c, want) in measured {
            for (i, xv) in x.enumerated() {
                let got = (apply(.brightnessContrast(brightness: b, contrast: c, legacy: true), SIMD3(repeating: xv / 255)).x * 255).rounded()
                #expect(abs(got - want[i]) <= 1, "b\(b) c\(c) at \(xv): \(got) vs \(want[i])")
            }
        }
    }

    @Test func colorBalanceMatchesPhotoshop() {
        func two(_ tones: [SIMD3<Float>], _ x: Float) -> [Int] { (0..<3).map { Int((AdjustMath.colorBalanceChannel(tones, true, $0, x / 255) * 255).rounded()) } }
        #expect(two([SIMD3(50, 0, 50), .zero, .zero], 128) == [128, 97, 128])
        let hi = two([.zero, .zero, SIMD3(-50, 50, 0)], 128)
        #expect(abs(hi[0] - 128) <= 1 && abs(hi[1] - 211) <= 1 && abs(hi[2] - 159) <= 1, "\(hi)")
        let x: [Float] = [0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224, 240, 255]
        let midRed: [Float] = [0, 36, 59, 78, 96, 112, 128, 142, 156, 170, 183, 196, 209, 221, 233, 244, 255]
        for (i, xv) in x.enumerated() {
            let r = (AdjustMath.colorBalanceChannel([.zero, SIMD3(50, 0, 0), .zero], false, 0, xv / 255) * 255).rounded()
            #expect(abs(r - midRed[i]) <= 1)
        }
    }

    @Test func hueSaturationMatchesPhotoshop() {
        let measured: [(SIMD3<Float>, Float, Float, Float, Bool, SIMD3<Float>)] = [
            (SIMD3(204, 102, 102), 0, 50, 0, false, SIMD3(254, 51, 51)),
            (SIMD3(204, 159, 102), 0, 50, 0, false, SIMD3(254, 164, 51)),
            (SIMD3(204, 102, 102), 0, -50, 0, false, SIMD3(178, 127, 127)),
            (SIMD3(0, 0, 0), 120, 100, 30, true, SIMD3(0, 152, 0)),
            (SIMD3(28, 28, 28), 120, 100, 30, true, SIMD3(0, 192, 0)),
            (SIMD3(160, 160, 160), 30, 25, -40, true, SIMD3(120, 96, 73)),
            (SIMD3(255, 143, 0), 30, 25, -40, true, SIMD3(95, 76, 58)),
        ]
        for (input, h, s, l, colorize, want) in measured {
            let got = apply(.hueSaturation(hue: h, saturation: s, lightness: l, colorize: colorize, ranges: HueRange.defaults), input / 255) * 255
            for i in 0..<3 { #expect(abs(got[i] - want[i]) <= 2, "\(input) \(i): \(got[i]) vs \(want[i])") }
        }
    }

    @Test func rangeLightnessMatchesPhotoshop() {
        let measured: [(SIMD3<Float>, Float, SIMD3<Float>)] = [
            (SIMD3(0, 29, 115), 0.5, SIMD3(57, 71, 115)), (SIMD3(102, 128, 204), -0.5, SIMD3(102, 115, 154)), (SIMD3(0, 18, 115), -0.5, SIMD3(0, 9, 58)),
        ]
        for (input, l, want) in measured {
            let got = AdjustMath.rangeLightness(input / 255, l) * 255
            for i in 0..<3 { #expect(abs(got[i] - want[i]) <= 2.5) }
        }
    }

    @Test func blackWhiteTintMatchesPhotoshop() {
        let measured: [(SIMD3<Float>, Float, SIMD3<Float>)] = [
            (SIMD3(255, 0, 0), 24, SIMD3(81, 1, 1)), (SIMD3(255, 0, 0), 120, SIMD3(255, 64, 64)), (SIMD3(0xe1, 0xd3, 0xb3), 120, SIMD3(133, 119, 87)),
            (SIMD3(0x40, 0x20, 0x10), 120, SIMD3(144, 112, 96)),
        ]
        for (tint, grey, want) in measured {
            let got = apply(.blackWhite(weights: [40, 60, 40, 60, 20, 80], tint: tint / 255), SIMD3(repeating: grey / 255)) * 255
            for i in 0..<3 { #expect(abs(got[i] - want[i]) <= 2.5, "\(tint) \(grey) \(i): \(got[i]) vs \(want[i])") }
        }
    }

    @Test func absoluteSelectiveColorMatchesPhotoshop() {
        let measured: [(Int, Float, Float, Float)] = [(7, 50, 64, 32), (7, 50, 192, 129), (7, -50, 192, 223), (7, -50, 64, 128), (6, -50, 192, 224),
                                                       (6, -50, 240, 253), (8, 50, 64, 32), (8, 50, 16, 2)]
        for (range, cyan, grey, want) in measured {
            var adj = [SIMD4<Float>](repeating: .zero, count: 9)
            adj[range].x = cyan
            let got = AdjustMath.selectiveColor(SIMD3(repeating: grey / 255), false, adj).x * 255
            #expect(abs(got - want) <= 1.5)
        }
    }

    @Test func levelsAndCurvesApplyEachChannelBeforeTheMaster() {
        let line = { (a: Float, b: Float) in [CurvePoint(input: 0, output: a), CurvePoint(input: 1, output: b)] }
        let levels = Adjustment.levels(master: LevelsChannel(outWhite: 0.5), perChannel: Array(repeating: LevelsChannel(outBlack: 0.5), count: 3), space: .rgb, black: .identity)
        let curves = Adjustment.curves(master: line(0, 0.5), perChannel: Array(repeating: line(0.5, 1), count: 3), space: .rgb, black: [], pencil: false)
        for depth in [nil, SampleType.u8, .u16, .f32] {
            for adj in [levels, curves] {
                let got = apply(adj, .zero, depth: depth)
                #expect(abs(got.x - 0.25) < 0.01, "\(String(describing: depth)) \(adj.label): \(got)")
            }
        }
    }

    @Test func colorizeAtZeroSaturationIsGrey() {
        for c in [SIMD3<Float>(0.9, 0.2, 0.1), SIMD3(0.1, 0.6, 0.8)] {
            let g = apply(.hueSaturation(hue: 200, saturation: 0, lightness: 30, colorize: true, ranges: HueRange.defaults), c)
            #expect(abs(g.x - g.y) < 1e-4 && abs(g.y - g.z) < 1e-4)
        }
    }

    @Test func labInvertFlipsLAB() {
        let c = ColorConvert.labToSRGB(SIMD3(30, 12, -18))
        let got = ColorConvert.srgbToLab(apply(.invert, c, mode: .lab, depth: .u8))
        #expect(abs(got.x - 70) < 0.6 && abs(got.y + 13) < 0.6 && abs(got.z - 17) < 0.6, "\(got)")
    }

    @Test func hueRangeWeights() {
        let reds = HueRange.neutral(0)
        #expect(reds.weight(0) == 1 && reds.weight(350) == 1 && abs(reds.weight(30) - 0.5) < 1e-5 && reds.weight(60) == 0)
        #expect(HueRange.neutral(4).weight(240) == 1)
        #expect(HueRange(hue: 0, saturation: 0, lightness: 0, bounds: [10, 10, 10, 10]).weight(200).isFinite)
    }

    @Test func lut3DLengthRejectsBadSizes() {
        #expect(lut3DLength(0) == nil && lut3DLength(1) == nil && lut3DLength(2) == 24 && lut3DLength(33) == 33 * 33 * 33 * 3)
        #expect(lut3DLength(UInt32.max) == nil)
    }

    @Test func posterizeIsExactOnThePhotoshopGrid() {
        #expect(AdjustMath.posterize(0.5, 2) == 1)
        #expect(AdjustMath.posterize(0.49, 2) == 0)
        #expect(AdjustMath.posterize(1, 4) == 1)
    }
}
