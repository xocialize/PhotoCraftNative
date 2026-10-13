// Port of photocraft-compose (crates/compose/src/effects.rs tests, stroke_tests.rs) and photocraft-gpu (effect parity), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
import PCDocument
import PCFoundation
@testable import PCRender

enum FxFixtures {
    static let canvas = PixelRect(x: 0, y: 0, width: 96, height: 80)
    static let bg = LeafID(layer: 1, role: .content)
    static let layer = LeafID(layer: 2, role: .content)
    static let shapeLeaf = LeafID(layer: 2, role: .effectShape)
    static let stroke = LeafID(layer: 2, role: .shapeStroke)

    static let cone = Contour.custom(.init(name: "Cone", points: [CurvePoint(input: 0, output: 0), CurvePoint(input: 0.5, output: 1), CurvePoint(input: 1, output: 0)]))
    static let ring = Contour.custom(.init(name: "Ring", points: [CurvePoint(input: 0, output: 0.2), CurvePoint(input: 0.3, output: 0.9),
                                                                  CurvePoint(input: 0.6, output: 0.1), CurvePoint(input: 1, output: 1)], corners: [false, true, false, false]))
    static let gradient = StyleGradient(stops: [ColorStop(0, .rgb(0.9, 0.1, 0.1)), ColorStop(0.5, .rgb(0.1, 0.8, 0.2)), ColorStop(1, .rgb(0.1, 0.2, 0.9))],
                                        opacityStops: [OpacityStop(0, 1), OpacityStop(1, 0.4)], style: .linear, angle: 30)

    static let pattern: PatternTile = {
        var px: [SIMD4<Float>] = []
        for y in 0..<5 { for x in 0..<7 { px.append(SIMD4(Float(x) / 6, Float(y) / 4, Float((x + y) % 3) / 2, (x + y) % 4 == 0 ? 0.5 : 1)) } }
        return PatternTile(id: "pat-1", name: "Checks", width: 7, height: 5, straight: px)
    }()

    /// A layer: a soft-edged ellipse with a hole and a translucent wing.
    static func content(_ seed: UInt64 = 5) -> Surface {
        var rng = Rng(seed)
        return TS.surface(canvas) { x, y in
            let fx: Float = Float(x) + 0.5, fy: Float = Float(y) + 0.5
            let u: Float = (fx - 44) / 26, v: Float = (fy - 38) / 19
            let e: Float = u * u + v * v
            var a: Float = min(max((1 - e) * 12, 0), 1)
            let hx: Float = fx - 40, hy: Float = fy - 36
            let hole: Float = (hx * hx + hy * hy).squareRoot()
            a *= min(max(hole - 5, 0), 1)
            if fx > 62 && fx < 76 && fy > 20 && fy < 60 { a = max(a, 0.55) }
            return SIMD4(0.2 + 0.6 * rng.float(), 0.3, 0.5 + 0.3 * sinf(fx * 0.2), a)
        }
    }

    static func source(vectorStroke: Bool = false) -> LeafTable {
        let c = content()
        var shape = FloatImage(rect: canvas.outset(by: 40), channels: 1)
        let alpha = c.readRegion(shape.rect)
        for i in 0..<shape.rect.area { shape.data[i] = alpha[i * 4 + 3] }
        var leaves: [LeafID: RenderLeaf] = [
            bg: .surface(TS.blob(canvas, seed: 9, cx: 50, cy: 40, r: 70)),
            layer: .surface(c),
            shapeLeaf: .image(shape, outside: .zero, version: 1),
        ]
        if vectorStroke {
            leaves[stroke] = .surface(TS.surface(canvas) { x, y in
                let u: Float = (Float(x) + 0.5 - 44) / 26
                let v: Float = (Float(y) + 0.5 - 38) / 19
                let d: Float = abs(u * u + v * v - 1)
                let a: Float = min(max(1 - d * 8, 0), 1)
                return SIMD4<Float>(0.95, 0.9, 0.1, a)
            })
        }
        return LeafTable(leaves: leaves, patterns: [pattern])
    }

    static func spec(_ items: [Effect], blend: BlendMode = .normal, opacity: Float = 1, fill: Float = 1, vectorShape: Bool = false,
                     outline: Bool = false, shapeless: Bool = false, interior: Bool = false, vectorStroke: Bool = false) -> EffectsSpec {
        let fx = Effects(enabled: true, items: items)
        let m = EffectMath.margin(fx)
        let bounds = PixelRect(x: 17, y: 18, width: 59, height: 42)
        let region = bounds.outset(by: m).intersect(canvas.outset(by: m))
        return EffectsSpec(layerID: 2, effects: fx, shape: shapeLeaf, region: region, bounds: bounds, blend: blend, opacity: opacity,
                           fillOpacity: fill, vectorShape: vectorShape, outline: outline, shapeless: shapeless, blendInterior: interior,
                           vectorStroke: vectorStroke ? stroke : nil, vectorStrokeMask: nil)
    }

    static func plan(_ spec: EffectsSpec, atop: Bool = false, ctx: RenderContext = RenderContext(canvas: canvas)) -> RenderPlan {
        var ops: [DrawOp] = [.pushTransparent, .drawTiles(DrawTiles(leaf: bg)), .composite(LayerBlend())]
        if atop {
            ops += [.pushTransparent, .drawTiles(DrawTiles(leaf: bg, mask: nil)), .composite(LayerBlend()), .drawTiles(DrawTiles(leaf: layer)), .effect(spec, atop: true),
                    .composite(LayerBlend())]
        } else {
            ops += [.drawTiles(DrawTiles(leaf: layer)), .effect(spec, atop: false)]
        }
        return RenderPlan(context: ctx, ops: ops)
    }

    static func shadow(_ inner: Bool, spread: Float = 0, contour: Contour = .linear, noise: Float = 0, knocks: Bool = true, distance: Float = 6) -> Effect {
        let s = Shadow(common: FxCommon(inner ? .multiply : .multiply, 0.8), color: .rgb(0.1, 0.05, 0.3), angle: 120, useGlobalLight: false,
                       distance: distance, spread: spread, size: 7, contour: contour, noise: noise, knocksOut: knocks)
        return inner ? .innerShadow(s) : .dropShadow(s)
    }

    static func glow(_ inner: Bool, technique: GlowTechnique = .softer, spread: Float = 0.15, paint: FxPaint = .color(.rgb(1, 0.9, 0.2)),
                     contour: Contour = .linear, range: Float = 0.5, noise: Float = 0, source: GlowSource = .edge) -> Effect {
        let g = Glow(common: FxCommon(.screen, 0.85), paint: paint, technique: technique, spread: spread, size: 9, contour: contour, range: range,
                     noise: noise, source: source)
        return inner ? .innerGlow(g) : .outerGlow(g)
    }

    static func bevel(_ style: BevelStyle, _ technique: BevelTechnique, contour: BevelContour? = nil, texture: BevelTexture? = nil, soften: Float = 0,
                      up: Bool = true, gloss: Contour = .linear) -> Effect {
        .bevelEmboss(Bevel(style: style, technique: technique, depth: 1.4, up: up, size: 8, soften: soften, angle: 120, altitude: 30,
                           useGlobalLight: true, glossContour: gloss, contour: contour, texture: texture))
    }

    static func stroke(_ pos: StrokePosition, _ paint: FxPaint, size: Float = 4, blend: BlendMode = .normal) -> Effect {
        .stroke(StrokeFx(common: FxCommon(blend, 0.9), size: size, position: pos, paint: paint))
    }

    static var cases: [(String, [Effect])] {
        var c: [(String, [Effect])] = []
        c.append(("drop-shadow", [shadow(false)]))
        c.append(("drop-shadow-spread-contour", [shadow(false, spread: 0.3, contour: cone)]))
        c.append(("drop-shadow-noise", [shadow(false, noise: 0.25)]))
        c.append(("drop-shadow-no-knockout", [shadow(false, knocks: false)]))
        c.append(("inner-shadow", [shadow(true)]))
        c.append(("inner-shadow-choke-ring", [shadow(true, spread: 0.4, contour: ring)]))
        c.append(("outer-glow-softer", [glow(false)]))
        c.append(("outer-glow-precise-gradient", [glow(false, technique: .precise, paint: .gradient(gradient), range: 0.7)]))
        c.append(("outer-glow-contour-noise", [glow(false, contour: cone, noise: 0.2)]))
        c.append(("inner-glow-edge", [glow(true)]))
        c.append(("inner-glow-center-precise", [glow(true, technique: .precise, spread: 0.3, source: .center)]))
        c.append(("inner-glow-pattern", [glow(true, paint: .pattern(.init(name: "Checks", id: "pat-1", scale: 1.5)))]))
        c.append(("satin", [.satin(Satin(common: FxCommon(.multiply, 0.7), color: .rgb(0.3, 0.1, 0.6), angle: 19, distance: 7, size: 8, invert: true))]))
        c.append(("satin-contour", [.satin(Satin(common: FxCommon(.overlay, 0.9), color: .rgb(0.9, 0.6, 0.1), angle: 140, distance: 3, size: 5,
                                                 contour: cone, invert: false))]))
        for style in BevelStyle.allCases {
            for tech in BevelTechnique.allCases {
                c.append(("bevel-\(style.rawValue)-\(tech.rawValue)", [bevel(style, tech)]))
            }
        }
        c.append(("bevel-contour-texture-soften", [bevel(.innerBevel, .smooth, contour: BevelContour(contour: ring, range: 0.5),
                                                         texture: BevelTexture(name: "Checks", id: "pat-1", scale: 2, depth: 0.6, invert: true, link: true),
                                                         soften: 2, up: false, gloss: cone)]))
        c.append(("color-overlay", [.colorOverlay(.init(common: FxCommon(.color, 0.75), color: .rgb(0.1, 0.5, 0.9)))]))
        for st in GradientStyle.allCases {
            var g = gradient; g.style = st; g.reverse = st == .angle
            c.append(("gradient-overlay-\(st.rawValue)", [.gradientOverlay(.init(common: FxCommon(.normal, 0.8), gradient: g))]))
        }
        c.append(("pattern-overlay", [.patternOverlay(.init(common: FxCommon(.multiply, 0.9), name: "Checks", id: "pat-1", scale: 2, angle: 30, link: true,
                                                            phase: SIMD2(3, 1)))]))
        for pos in [StrokePosition.inside, .center, .outside] {
            c.append(("stroke-\(pos.rawValue)-color", [stroke(pos, .color(.rgb(1, 0.2, 0.1)))]))
            c.append(("stroke-\(pos.rawValue)-gradient", [stroke(pos, .gradient(gradient), size: 5)]))
            c.append(("stroke-\(pos.rawValue)-pattern", [stroke(pos, .pattern(.init(name: "Checks", id: "pat-1", scale: 1)), size: 3)]))
        }
        c.append(("strokes-stacked", [stroke(.outside, .color(.rgb(0.1, 0.9, 0.3)), size: 3, blend: .multiply), stroke(.outside, .color(.rgb(1, 1, 1)), size: 7),
                                      stroke(.inside, .color(.rgb(0, 0, 0)), size: 2)]))
        c.append(("everything", [shadow(false), glow(false), shadow(true), glow(true), .satin(Satin(common: FxCommon(.multiply, 0.5), color: .black, angle: 19,
                                                                                                            distance: 5, size: 6)),
                                 .colorOverlay(.init(common: FxCommon(.softLight, 0.6), color: .rgb(0.9, 0.3, 0.2))),
                                 .gradientOverlay(.init(common: FxCommon(.overlay, 0.5), gradient: gradient)),
                                 stroke(.outside, .color(.rgb(0, 0, 0)), size: 3), bevel(.emboss, .smooth), bevel(.innerBevel, .chiselHard)]))
        return c
    }
}

@Suite struct EffectParityTests {
    func check(_ name: String, _ plan: RenderPlan, _ src: any RenderSource, levels: Int = 1) throws {
        let (cpu, gpu) = try TS.both(plan, FxFixtures.canvas, src)
        guard let gpu else { return }
        let d = TS.diff(cpu, gpu)
        #expect(d.levels <= levels, "\(name): \(d.max) at \(d.at) cpu \(cpu.px[d.at]) gpu \(gpu.px[d.at])")
    }

    @Test(arguments: FxFixtures.cases.map(\.0))
    func effectParity(_ name: String) throws {
        let items = FxFixtures.cases.first { $0.0 == name }!.1
        let src = FxFixtures.source()
        try check(name, FxFixtures.plan(FxFixtures.spec(items, blend: .normal)), src)
        try check(name + " fill 40% multiply op 0.8", FxFixtures.plan(FxFixtures.spec(items, blend: .multiply, opacity: 0.8, fill: 0.4)), src)
    }

    @Test func advancedEffectSwitchesParity() throws {
        let items = FxFixtures.cases.first { $0.0 == "everything" }!.1
        let src = FxFixtures.source(vectorStroke: true)
        for (label, spec) in [
            ("interior-group", FxFixtures.spec(items, fill: 0.5, interior: true)),
            ("shapeless", FxFixtures.spec(items, shapeless: true)),
            ("outline", FxFixtures.spec(items, vectorShape: true, outline: true)),
            ("vector-shape", FxFixtures.spec(items + [FxFixtures.stroke(.outside, .color(.rgb(0.2, 0.2, 1)), size: 5)], vectorShape: true)),
            ("vector-stroke", FxFixtures.spec(items, vectorShape: true, vectorStroke: true)),
        ] {
            try check(label, FxFixtures.plan(spec), src)
        }
        try check("atop", FxFixtures.plan(FxFixtures.spec(items, opacity: 0.85), atop: true), src)
        try check("lab", FxFixtures.plan(FxFixtures.spec(items), ctx: RenderContext(canvas: FxFixtures.canvas, mode: .lab)), src)
        try check("hdr", FxFixtures.plan(FxFixtures.spec(items), ctx: RenderContext(canvas: FxFixtures.canvas, depth: .f32)), src)
    }

    /// Tiling the CPU reference and chunking the GPU don't change effects (maps are region-wide).
    @Test func effectsAreTileIndependent() throws {
        let items = FxFixtures.cases.first { $0.0 == "everything" }!.1
        let plan = FxFixtures.plan(FxFixtures.spec(items))
        let src = FxFixtures.source()
        let a = try CPUCompositor(tileSize: 16).render(plan, region: FxFixtures.canvas, source: src)
        let b = try CPUCompositor(tileSize: 512).render(plan, region: FxFixtures.canvas, source: src)
        #expect(a == b)
        let part = PixelRect(x: 30, y: 10, width: 40, height: 50)
        let c = try CPUCompositor(tileSize: 32).render(plan, region: part, source: src)
        #expect(c == a.cropped(to: part))
    }
}

/// photocraft effects.rs unit tests against the Swift reference.
@Suite struct EffectReferenceTests {
    @Test func edtIsExact() {
        var inside = [Bool](repeating: false, count: 49)
        inside[3 * 7 + 3] = true
        let (d, _) = DistanceFields.edtNearest(inside, 7, 7)
        #expect(d[3 * 7 + 3] == 0 && abs(d[0] - (18 as Float).squareRoot()) < 1e-5 && d[3 * 7 + 6] == 3)
    }

    @Test func chamferUsesEuclideanStepLengths() {
        var start = [Float](repeating: DistanceFields.chamferInf, count: 64)
        start[0] = 0
        let d = DistanceFields.chamferFrom(start, 8, 8)
        #expect(abs(d[3 * 8 + 1] - (2.236068 + 1)) < 1e-4, "\(d[3 * 8 + 1])")
        #expect(abs(d[3 * 8 + 2] - (2.236068 + 1.4142135)) < 1e-4)
    }

    @Test func tentKernelIsTwoBoxesAndRunningSumMatchesIt() {
        for w: Float in [1, 2.5, 5, 7.3, 12] {
            let (r, k) = EffectMath.tentKernel(w)
            #expect(abs(k.reduce(0, +) - 1) < 1e-5)
            #expect(k.count == 2 * r + 1)
            var m = FxMap(w: 31, h: 9)
            m.v[4 * 31 + 15] = 1
            EffectMath.tent(&m, w)
            if r > 0 {
                for i in -r...r { #expect(abs(m.v[4 * 31 + 15 + i] - k[r + i] * k[r]) < 1e-5) }
            }
        }
    }

    @Test func offsetsFollowLight() {
        #expect(EffectMath.offset(120, 5) == (3, 4))
        #expect(EffectMath.offset(90, 5) == (0, 5))
    }

    @Test func gradientGeometry() {
        let r = PixelRect(x: 0, y: 0, width: 100, height: 50)
        #expect(abs(GradientMath.t(.linear, angle: 0, scale: 1, reverse: false, offset: .zero, bounds: r, x: 0.5, y: 25) - 0) < 1e-3)
        #expect(abs(GradientMath.t(.radial, angle: 0, scale: 1, reverse: false, offset: .zero, bounds: r, x: 50, y: 25) - 0) < 1e-3)
        #expect(GradientMath.t(.linear, angle: 0, scale: 1, reverse: true, offset: .zero, bounds: r, x: 99.5, y: 25) < 0.02)
    }

    @Test func smallReflectedThirtyDegreesSnapsToTheCorner() {
        let f = PixelRect(x: 0, y: 0, width: 4, height: 4)
        let (a, s, o) = GradientMath.layout(.reflected, angle: 30, scale: 1, offset: .zero, frame: f)
        for y in 0..<4 {
            for x in 0..<4 {
                let t = GradientMath.t(.reflected, angle: a, scale: s, reverse: false, offset: o, bounds: f, x: Float(x) + 0.5, y: Float(y) + 0.5)
                #expect(abs(t - abs(Float(x - y)) / 4) < 1e-4)
            }
        }
    }

    @Test func glowRangeStretchesTheContour() {
        let l = EffectMath.rangedLUT(.linear, 0.5)!
        #expect(abs(EffectMath.lutAt(l, 0.25) - 0.5) < 1e-3 && EffectMath.lutAt(l, 0.6) == 1)
        #expect(EffectMath.rangedLUT(.linear, 1) == nil)
    }

    @Test func outlineShare() {
        #expect(EffectsCPU.outlineShare(0.58, 1) == 1)
        #expect(abs(EffectsCPU.outlineShare(0.5, 0) - 0.5) < 1e-6)
    }

    @Test func marginCoversEveryEffect() {
        let fx = Effects(enabled: true, items: [FxFixtures.shadow(false, distance: 10), FxFixtures.stroke(.outside, .color(.black), size: 30)])
        #expect(EffectMath.margin(fx) == 32)
    }
}
