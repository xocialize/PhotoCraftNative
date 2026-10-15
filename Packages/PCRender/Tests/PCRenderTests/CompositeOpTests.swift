// Port of photocraft-compose (crates/compose/src/masks.rs, advanced.rs, gradient_fill.rs, pattern.rs tests) and photocraft-gpu (parity tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
import PCDocument
import PCFoundation
@testable import PCRender

enum OpFixtures {
    static let canvas = PixelRect(x: 0, y: 0, width: 80, height: 64)
    static let a = LeafID(layer: 1, role: .content), b = LeafID(layer: 2, role: .content), c = LeafID(layer: 3, role: .content)
    static let mask = LeafID(layer: 2, role: .mask), vmask = LeafID(layer: 2, role: .vectorMask), mask8 = LeafID(layer: 3, role: .mask)

    static func source() -> LeafTable {
        var m = Surface(format: .gray8, defaultPixel: [0.2])
        m.writeRegion(PixelRect(x: 10, y: 8, width: 50, height: 40), (0..<(50 * 40)).map { Float(($0 % 50) * 5 % 256) / 255 })
        var vm = FloatImage(rect: PixelRect(x: 18, y: 12, width: 44, height: 36), channels: 1)
        for y in 0..<36 { for x in 0..<44 {
            let d = ((Float(x) - 22) * (Float(x) - 22) + (Float(y) - 18) * (Float(y) - 18)).squareRoot()
            vm.data[y * 44 + x] = min(max(16 - d, 0), 1)
        } }
        var m8 = Surface(format: .gray8, defaultPixel: [1])
        m8.fill(PixelRect(x: 0, y: 30, width: 80, height: 10), with: [0])
        return LeafTable(leaves: [
            a: .surface(TS.blob(canvas, seed: 21, cx: 40, cy: 32, r: 60)),
            b: .surface(TS.blob(canvas, seed: 22, cx: 30, cy: 28, r: 22, opaqueInside: false)),
            c: .surface(TS.blob(canvas, seed: 23, cx: 52, cy: 36, r: 18)),
            mask: .surface(m),
            vmask: .image(vm, outside: .zero, version: 3),
            mask8: .surface(m8),
        ], patterns: [FxFixtures.pattern])
    }

    static var masks: [(String, MaskSpec)] {
        [
            ("pixel", MaskSpec(pixel: mask)),
            ("pixel-density", MaskSpec(pixel: mask, density: 0.6)),
            ("pixel-feather", MaskSpec(pixel: mask, density: 0.8, feather: 3.5)),
            ("vector", MaskSpec(vector: vmask)),
            ("vector-feather", MaskSpec(vector: vmask, vectorFeather: 2)),
            ("both-feathered", MaskSpec(pixel: mask, density: 0.9, feather: 1.5, vector: vmask, vectorFeather: 4)),
            ("both", MaskSpec(pixel: mask, vector: vmask)),
        ]
    }

    static func check(_ name: String, _ ops: [DrawOp], ctx: RenderContext = RenderContext(canvas: canvas), levels: Int = 1,
                      source: LeafTable = source()) throws {
        let (cpu, gpu) = try TS.both(RenderPlan(context: ctx, ops: ops), canvas, source)
        guard let gpu else { return }
        let d = TS.diff(cpu, gpu)
        #expect(d.levels <= levels, "\(name): \(d.max) at \(d.at): cpu \(cpu.px[d.at]) gpu \(gpu.px[d.at])")
    }

    static var base: [DrawOp] { [.pushTransparent, .drawTiles(DrawTiles(leaf: a)), .composite(LayerBlend())] }
}

@Suite struct MaskParityTests {
    @Test(arguments: OpFixtures.masks.map(\.0))
    func maskParity(_ name: String) throws {
        let m = OpFixtures.masks.first { $0.0 == name }!.1
        try OpFixtures.check(name, OpFixtures.base + [.drawTiles(DrawTiles(leaf: OpFixtures.b, mask: m)), .composite(LayerBlend(.multiply, opacity: 0.9))])
        try OpFixtures.check(name + " adjust", OpFixtures.base + [.pick(0), .adjust(.invert), .adjustMix(AdjustMix(mode: .normal, opacity: 0.8, mask: m))])
        try OpFixtures.check(name + " group", OpFixtures.base + [.pushGroup(.passThrough), .drawTiles(DrawTiles(leaf: OpFixtures.b)), .composite(LayerBlend()),
                                                                 .popGroup(.passThrough(opacity: 0.7, mask: m))])
        try OpFixtures.check(name + " shape", OpFixtures.base + [.pushMaskShape(m), .drawTiles(DrawTiles(leaf: OpFixtures.c)), .swap, .mask(m), .composite(LayerBlend()),
                                                                 .composite(LayerBlend(.screen))])
    }

    /// The combined (feathered) mask equals photocraft's: a hard edge feathered stays symmetric.
    @Test func featherBlursSymmetrically() {
        var s = Surface(format: .gray8, defaultPixel: [0])
        s.fill(PixelRect(x: 20, y: 0, width: 20, height: 40), with: [1])
        let m = MaskMath.buildCombined(MaskSpec(pixel: LeafID(raw: 1), feather: 4), pixel: .surface(s), vector: nil, canvas: PixelRect(x: 0, y: 0, width: 60, height: 40))
        let row = m.read(PixelRect(x: 0, y: 20, width: 60, height: 1))
        #expect(abs(row[19] + row[20] - 1) < 0.01, "\(row[19]) \(row[20])")
        #expect(row[30] > 0.97 && row[2] < 0.01, "\(row)")
    }
}

@Suite struct AdvancedOpParityTests {
    @Test func knockoutShallowDeepAndClipAlpha() throws {
        for (opacity, clip) in [(Float(1), false), (0.6, false), (0.75, true)] {
            try OpFixtures.check("knockout o\(opacity) clip\(clip)", OpFixtures.base + [
                .saveFloor,
                .drawTiles(DrawTiles(leaf: OpFixtures.b)), .composite(LayerBlend(.overlay)),
                .pushFloor, .drawTiles(DrawTiles(leaf: OpFixtures.c, mask: MaskSpec(pixel: OpFixtures.mask))), .pick(2), .remove(3),
                .knockoutBegin(clipAlpha: clip),
                .drawTiles(DrawTiles(leaf: OpFixtures.c, mask: MaskSpec(pixel: OpFixtures.mask))), .composite(LayerBlend(.normal, opacity: opacity, fill: 0.7)),
                .knockoutEnd(opacity: opacity),
                .dropFloor,
            ])
        }
    }

    @Test func finishLayerChannelsAndBlendIf() throws {
        var bi = BlendIf()
        bi.set(0, BlendRangePair(BlendRange(black: SIMD2(30, 90), white: SIMD2(200, 250)), BlendRange(black: SIMD2(10, 10), white: SIMD2(220, 240))))
        bi.set(2, BlendRangePair(.full, BlendRange(black: SIMD2(0, 60), white: SIMD2(255, 255))))
        for mode in [ColorMode.rgb, .grayscale] {
            let ctx = RenderContext(canvas: OpFixtures.canvas, mode: mode)
            try OpFixtures.check("channels \(mode)", OpFixtures.base + [.pick(0), .drawTiles(DrawTiles(leaf: OpFixtures.b)), .composite(LayerBlend(.difference)),
                                                                        .finishLayer(FinishLayer(channels: SIMD3(1, 0, 1)))], ctx: ctx)
            try OpFixtures.check("blend if own \(mode)", OpFixtures.base + [.pick(0), .drawTiles(DrawTiles(leaf: OpFixtures.b)), .swap,
                                                                            .drawTiles(DrawTiles(leaf: OpFixtures.b)), .composite(LayerBlend(.normal, opacity: 0.9)),
                                                                            .finishLayer(FinishLayer(channels: SIMD3(0, 1, 1), blendIf: bi, hasOwn: true))], ctx: ctx)
            try OpFixtures.check("blend if adjustment \(mode)", OpFixtures.base + [.pick(0), .pick(0), .adjust(.posterize(levels: 3)),
                                                                                   .adjustMix(AdjustMix(mode: .normal, opacity: 1)),
                                                                                   .finishLayer(FinishLayer(blendIf: bi, hasOwn: false))], ctx: ctx)
        }
    }

    @Test func mixByAddDifferenceRestrictQuantize() throws {
        try OpFixtures.check("mixBy", OpFixtures.base + [.pick(0), .drawTiles(DrawTiles(leaf: OpFixtures.c)), .composite(LayerBlend(.colorBurn)),
                                                         .drawTiles(DrawTiles(leaf: OpFixtures.b)), .mixBy(0.8)])
        try OpFixtures.check("addDifference", OpFixtures.base + [.pick(0), .drawTiles(DrawTiles(leaf: OpFixtures.b)), .composite(LayerBlend(.linearLight)),
                                                                 .pick(1), .drawTiles(DrawTiles(leaf: OpFixtures.c)), .composite(LayerBlend()),
                                                                 .addDifference])
        try OpFixtures.check("restrict", OpFixtures.base + [.pick(0), .fill(FillOp(fill: .solid(.white), frame: OpFixtures.canvas)), .composite(LayerBlend()),
                                                            .drawTiles(DrawTiles(leaf: OpFixtures.b)), .composite(LayerBlend()),
                                                            .restrictTo(PixelRect(x: 12, y: 9, width: 33, height: 27))])
        try OpFixtures.check("quantize16", OpFixtures.base + [.quantize(32768)])
    }
}

@Suite struct FillParityTests {
    static func gradient(_ style: GradientStyle, reverse: Bool, dither: Bool, mids: Bool) -> Fill {
        .gradient(GradientFill(stops: [ColorStop(0.1, .rgb(0.9, 0.1, 0.1, 1)), ColorStop(0.55, .rgb(0.2, 0.8, 0.2, 0.7)), ColorStop(0.9, .rgb(0.1, 0.1, 0.9, 1))],
                               angle: 37, scale: 0.8, style: style, reverse: reverse, opacityStops: [OpacityStop(0, 1), OpacityStop(0.7, 0.3), OpacityStop(1, 0.9)],
                               midpoints: mids ? [0.3, 0.75] : [], offset: SIMD2(0.1, -0.05), dither: dither))
    }

    @Test(arguments: GradientStyle.allCases)
    func gradientFillParity(_ style: GradientStyle) throws {
        for (reverse, dither, mids) in [(false, false, false), (true, true, true)] {
            for depth in [SampleType.u8, .u16, .f32] {
                let ctx = RenderContext(canvas: OpFixtures.canvas, depth: depth)
                try OpFixtures.check("\(style) r\(reverse) d\(dither) m\(mids) \(depth)", OpFixtures.base + [
                    .fill(FillOp(fill: Self.gradient(style, reverse: reverse, dither: dither, mids: mids), frame: PixelRect(x: 6, y: 4, width: 61, height: 50),
                                 mask: MaskSpec(pixel: OpFixtures.mask))),
                    .composite(LayerBlend(.normal, opacity: 0.9)),
                ], ctx: ctx)
            }
        }
    }

    @Test func patternAndSolidFillParity() throws {
        // Fills round to the document's depth: an interpolated pattern sample on a rounding
        // boundary can land one level apart on the CPU and the GPU, which Hard Light doubles.
        for (link, angle, scale) in [(true, Float(0), Float(1)), (false, 30, 2.5), (true, -45, 0.6)] {
            try OpFixtures.check("pattern l\(link) a\(angle) s\(scale)", OpFixtures.base + [
                .fill(FillOp(fill: .pattern(PatternFill(name: "Checks", scale: scale, id: "pat-1", angle: angle, link: link, phase: SIMD2(2, 3))),
                             frame: PixelRect(x: 5, y: 7, width: 40, height: 30))),
                .composite(LayerBlend(.hardLight, opacity: 0.8)),
            ], levels: 2)
        }
        try OpFixtures.check("missing pattern", OpFixtures.base + [.fill(FillOp(fill: .pattern(PatternFill(name: "nope", id: "x")), frame: OpFixtures.canvas)),
                                                                   .composite(LayerBlend())])
        try OpFixtures.check("solid", OpFixtures.base + [.fill(FillOp(fill: .solid(.rgb(0.3, 0.6, 0.9, 0.5)), frame: OpFixtures.canvas, mask: MaskSpec(vector: OpFixtures.vmask))),
                                                         .composite(LayerBlend(.color))])
    }

    @Test func rampMidpointsAndOpacity() {
        let f = GradientFill(stops: [ColorStop(1, .white), ColorStop(0, .black)], angle: 0, scale: 1, style: .linear, reverse: false,
                             opacityStops: [OpacityStop(0, 1), OpacityStop(1, 0)], midpoints: [0.25])
        let r = GradientMath.FillRamp(f)
        #expect(abs(r.sample(0.25).x - 0.5) < 1e-5 && abs(r.sample(0.25).w - 0.75) < 1e-5)
        #expect(r.sample(1) == SIMD4(1, 1, 1, 0))
        #expect(GradientMath.midpointRemap(0.3, 0.5) == 0.3)
    }

    @Test func patternIdentityPlacementTilesExactly() {
        var px: [SIMD4<Float>] = []
        for y in 0..<4 { for x in 0..<4 { px.append((x < 2) == (y < 2) ? SIMD4(0, 0, 1, 1) : SIMD4(1, 0, 0, 1)) } }
        let t = PatternTile(id: "c", name: "checker", width: 4, height: 4, straight: px)
        let p = PatternPlacement(frame: PixelRect(x: 0, y: 0, width: 10, height: 10), link: false, phase: .zero, scale: 1, angle: 0)
        func at(_ x: Double) -> SIMD4<Float> { let (u, v) = p.map(x + 0.5, 0.5); return t.sample(u, v) }
        #expect(at(-4) == SIMD4(0, 0, 1, 1) && at(2) == SIMD4(1, 0, 0, 1) && at(4) == SIMD4(0, 0, 1, 1))
        let rot = PatternPlacement(frame: .empty, link: false, phase: .zero, scale: 1, angle: 90)
        let (u, v) = rot.map(1, 3)
        #expect(abs(u + 3) < 1e-9 && abs(v - 1) < 1e-9)
    }
}

@Suite struct ExecutorTests {
    static var bigPlan: (RenderPlan, LeafTable, PixelRect) {
        let canvas = PixelRect(x: 0, y: 0, width: 700, height: 530)
        let l1 = LeafID(layer: 1, role: .content), l2 = LeafID(layer: 2, role: .content)
        let src = LeafTable(leaves: [l1: .surface(TS.blob(canvas, seed: 31, cx: 300, cy: 260, r: 400)),
                                     l2: .surface(TS.blob(canvas, seed: 32, cx: 380, cy: 250, r: 140, opaqueInside: false))])
        let ops: [DrawOp] = [.pushTransparent, .drawTiles(DrawTiles(leaf: l1)), .composite(LayerBlend()),
                             .drawTiles(DrawTiles(leaf: l2)), .composite(LayerBlend(.softLight, opacity: 0.8)),
                             .pick(0), .adjust(.hueSaturation(hue: 30, saturation: 10, lightness: 0, colorize: false, ranges: HueRange.defaults)),
                             .adjustMix(AdjustMix(mode: .normal, opacity: 0.7)), .quantize(255)]
        return (RenderPlan(context: RenderContext(canvas: canvas), ops: ops), src, canvas)
    }

    @Test func chunkingAndTilingDontChangeTheResult() throws {
        let (plan, src, canvas) = Self.bigPlan
        let cpu = try CPUCompositor(tileSize: 256).render(plan, region: canvas, source: src)
        #expect(try CPUCompositor(tileSize: 100).render(plan, region: canvas, source: src) == cpu)
        guard TS.metal != nil else { return }
        let small = try MetalCompositor(chunkSize: 256), large = try MetalCompositor(chunkSize: 2048)
        small.precision = .float; large.precision = .float
        let a = try small.renderBuffer(plan, region: canvas, source: src), b = try large.renderBuffer(plan, region: canvas, source: src)
        #expect(a == b)
        #expect(TS.diff(a, cpu).levels <= 1)
        // A sub-region equals the same pixels of the whole.
        let part = PixelRect(x: 250, y: 100, width: 300, height: 300)
        #expect(try large.renderBuffer(plan, region: part, source: src) == b.cropped(to: part))
    }

    @Test func residencyUploadsOnlyChangedTiles() throws {
        let canvas = PixelRect(x: 0, y: 0, width: 600, height: 520)
        let leaf = LeafID(layer: 7, role: .content)
        var s = TS.blob(canvas, seed: 3, cx: 300, cy: 260, r: 500)
        let plan = RenderPlan(context: RenderContext(canvas: canvas), ops: [.pushTransparent, .drawTiles(DrawTiles(leaf: leaf)), .composite(LayerBlend())])
        let m = try MetalCompositor(chunkSize: 1024)
        _ = try m.renderBuffer(plan, region: canvas, source: LeafTable(leaves: [leaf: .surface(s)]))
        let first = m.tilesUploaded
        #expect(first == s.tileCount)
        _ = try m.renderBuffer(plan, region: canvas, source: LeafTable(leaves: [leaf: .surface(s)]))
        #expect(m.tilesUploaded == first, "an unchanged surface uploads nothing")
        s.setPixel(x: 10, y: 10, [1, 0, 0, 1])
        let out = try m.renderBuffer(plan, region: canvas, source: LeafTable(leaves: [leaf: .surface(s)]))
        #expect(m.tilesUploaded == first + 1, "one dab re-uploads one tile")
        #expect(out.get(10, 10) == SIMD4(1, 0, 0, 1), "\(out.get(10, 10)) \(s.pixel(x: 10, y: 10))")
        m.residency.budget = 1
        _ = try m.renderBuffer(plan, region: canvas, source: LeafTable(leaves: [leaf: .surface(s)]))
        #expect(m.residentBytes > 0, "pages in use survive eviction")
    }

    @Test func halfAccumulatorsStayWithinAMeasuredTolerance() throws {
        // A compositor of its own: the parity suites render through `TS.metal` in parallel, at `.float`.
        guard TS.metal != nil, let m = try? MetalCompositor(chunkSize: 256) else { return }
        let (plan, src, canvas) = Self.bigPlan
        let cpu = try CPUCompositor().render(plan, region: canvas, source: src)
        m.precision = .half
        let half = try m.renderBuffer(plan, region: canvas, source: src)
        let d = TS.diff(cpu, half)
        // rgba16Float carries 11 significant bits; 8-bit documents quantise adjustment results.
        #expect(d.levels <= 1, "half accumulators: \(d.max)")
    }

    @Test func planValidation() {
        let ctx = RenderContext(canvas: OpFixtures.canvas)
        #expect(throws: PlanError.stackUnderflow(op: 0)) { try RenderPlan(context: ctx, ops: [.composite(LayerBlend())]).validate() }
        #expect(throws: PlanError.unbalanced(finalDepth: 2)) { try RenderPlan(context: ctx, ops: [.pushTransparent, .pushTransparent]).validate() }
        #expect(throws: PlanError.noFloor(op: 1)) { try RenderPlan(context: ctx, ops: [.pushTransparent, .pushFloor]).validate() }
        #expect(throws: PlanError.missingLeaf(LeafID(raw: 99))) {
            try CPUCompositor().render(RenderPlan(context: ctx, ops: [.drawTiles(DrawTiles(leaf: LeafID(raw: 99)))]), region: OpFixtures.canvas, source: LeafTable())
        }
    }
}
