// Port of photocraft-compose (crates/compose/src/stroke_tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Shape layers through the planner: effects follow a filled shape's outline, the vector stroke
// sits above clipped layers and interior effects, the mask covers fill and stroke together. Shape
// caches and fill / stroke splits come from the test CoreGraphics rasterizer (photocraft uses its
// vector crate), so pixel expectations keep photocraft's tolerances.

import Foundation
import Testing
import PCDocument
import PCFoundation
@testable import PCRender

@Suite("Shape layers and strokes (compose stroke_tests.rs)")
struct DocumentShapeTests {
    static let blue = FxPaint.color(.rgb(0, 0, 1))

    static func stroke(_ size: Float, _ position: StrokePosition, _ paint: FxPaint) -> Effect {
        .stroke(StrokeFx(common: FxCommon(.normal, 1), size: size, position: position, paint: paint))
    }

    /// A shape layer over the square x0..x1 with its cached pixels (the rasterizer's rendering).
    static func shape(_ x0: Double, _ x1: Double, fill: Fill, stroke: ShapeStroke? = nil, format: PixelFormat = DT.rgba8,
                      canvas: PixelRect = DT.rect(0, 0, 40, 40)) -> Layer {
        var sh = ShapeLayer(path: DT.polygon([(x0, x0), (x1, x0), (x1, x1), (x0, x1)]), fill: fill, stroke: stroke)
        sh.cache = DT.rasterizer.renderShape(sh, format: format, clip: canvas)
        return Layer(name: "shape", content: .shape(sh))
    }

    @Test func filledShapeStrokeFollowsTheOutlineWhereTheFillFadesOut() {
        var d = DT.docWhite(40, 40)
        let fade = Fill.gradient(GradientFill(stops: [ColorStop(0, .rgb(1, 0, 0)), ColorStop(1, .rgb(1, 0, 0, 0))], angle: 0, scale: 1, style: .linear, reverse: false))
        var l = Self.shape(10, 30, fill: fade)
        l.effects.items = [Self.stroke(3, .outside, Self.blue), Self.stroke(2, .inside, .color(.rgb(0, 1, 0)))]
        d.layers.append(l)
        let r = DT.render(d)
        #expect(DT.close4(r.get(8, 20), DT.rgba(0, 0, 1)), "\(r.get(8, 20))")
        #expect(DT.close4(r.get(31, 20), DT.rgba(0, 0, 1)), "\(r.get(31, 20))")
        #expect(DT.close4(r.get(28, 20), DT.rgba(0, 1, 0)), "\(r.get(28, 20))")
        #expect(r.get(25, 20).x > 0.9 && r.get(25, 20).y > 0.5, "\(r.get(25, 20))")
    }

    @Test func outsideStrokeFillsTheRestOfAShapesEdgePixel() {
        var d = Document(name: "t", size: PixelSize(width: 40, height: 40), mode: .rgb, depth: .u8)
        var l = Self.shape(10, 30.5, fill: .solid(.rgb(1, 0, 0)))
        l.effects.items = [Self.stroke(3, .outside, Self.blue)]
        d.layers = [l]
        let p = DT.px(d, 30, 20)
        #expect(abs(p.w - 1) <= 2 / 255, "\(p)")
        #expect(abs(p.x - 0.5) <= 0.02 && abs(p.z - 0.5) <= 0.02, "\(p)")
    }

    @Test func vectorStrokeStaysAboveInteriorEffectsAndBelowTheStrokeEffect() {
        var d = DT.docWhite(40, 40)
        let vs = ShapeStroke(width: 4, paint: .solid(.rgb(0, 1, 0)), align: .inside)
        var l = Self.shape(10, 30, fill: .solid(.rgb(1, 0, 0)), stroke: vs)
        l.effects.items = [.colorOverlay(.init(common: FxCommon(.normal, 1), color: .rgb(0, 0, 1))), Self.stroke(1, .inside, .color(.rgb(1, 1, 0)))]
        d.layers.append(l)
        let r = DT.render(d)
        #expect(DT.close4(r.get(10, 20), DT.rgba(1, 1, 0)), "stroke effect on top: \(r.get(10, 20))")
        #expect(DT.close4(r.get(12, 20), DT.rgba(0, 1, 0)), "vector stroke over the overlay: \(r.get(12, 20))")
        #expect(DT.close4(r.get(20, 20), DT.rgba(0, 0, 1)), "overlay on the fill: \(r.get(20, 20))")
    }

    @Test func aStrokedShapesMaskAppliesToFillAndStrokeTogether() {
        var d = Document(name: "t", size: PixelSize(width: 40, height: 40), mode: .rgb, depth: .u8)
        let vs = ShapeStroke(width: 4, paint: .solid(.rgb(0, 1, 0)), align: .inside)
        var l = Self.shape(10, 30, fill: .solid(.rgb(1, 0, 0)), stroke: vs)
        l.mask = LayerMask(surface: Surface(format: PixelFormat(mode: .grayscale, sample: .u8, alpha: false), defaultPixel: [0.5]))
        var clip = DT.solidLayer("clip", DT.rect(0, 0, 40, 40), DT.rgba(0, 0, 1))
        clip.clipped = true
        d.layers = [l, clip]
        var p = DT.px(d, 12, 20)
        #expect(DT.close4(p, SIMD4(0, 1, 0, 0.5)), "\(p)")
        l.effects.items = [.colorOverlay(.init(common: FxCommon(.normal, 1), color: .rgb(1, 1, 1)))]
        d.layers = [l]
        p = DT.px(d, 12, 20)
        #expect(DT.close4(p, SIMD4(0, 1, 0, 0.5)), "without clipped layers: \(p)")
        d.layers = [l, clip]
        p = DT.px(d, 12, 20)
        #expect(DT.close4(p, SIMD4(0, 1, 0, 0.5)), "\(p)")
    }

    @Test func gradientStrokeSpansTheStrokesExtent() {
        var d = DT.docWhite(40, 40)
        var l = DT.solidLayer("sq", DT.rect(10, 10, 30, 30), DT.rgba(1, 0, 0))
        let g = StyleGradient(stops: [ColorStop(0, .black), ColorStop(1, .white)], style: .linear, angle: 90)
        l.effects.items = [Self.stroke(4, .outside, .gradient(g))]
        d.layers.append(l)
        func tIn(_ frame: PixelRect, _ x: Int32, _ y: Int32) -> Float {
            let (a, s, o) = GradientMath.layout(.linear, angle: 90, scale: 1, offset: .zero, frame: frame)
            return GradientMath.t(.linear, angle: a, scale: s, reverse: false, offset: o, bounds: frame, x: Float(x) + 0.5, y: Float(y) + 0.5)
        }
        let (strokeFrame, layerFrame) = (DT.rect(7, 7, 33, 33), DT.rect(10, 10, 30, 30))
        let r = DT.render(d)
        for y: Int32 in [7, 9, 31, 32] {
            #expect(abs(r.get(20, y).x - tIn(strokeFrame, 20, y)) <= 0.01, "row \(y): \(r.get(20, y))")
        }
        #expect(abs(tIn(strokeFrame, 20, 9) - tIn(layerFrame, 20, 9)) > 0.05)
    }

    @Test func severalStrokesStackTopInstanceFirst() {
        var d = DT.docWhite(60, 60)
        var l = DT.solidLayer("sq", DT.rect(20, 20, 40, 40), DT.rgba(1, 0, 0))
        l.effects.items = [Self.stroke(2, .outside, .color(.rgb(0, 1, 0))), Self.stroke(5, .outside, Self.blue), Self.stroke(2, .inside, .color(.rgb(1, 1, 0)))]
        d.layers.append(l)
        let r = DT.render(d)
        #expect(DT.close4(r.get(19, 30), DT.rgba(0, 1, 0)))
        #expect(DT.close4(r.get(16, 30), DT.rgba(0, 0, 1)))
        #expect(DT.close4(r.get(20, 30), DT.rgba(1, 1, 0)))
        #expect(DT.close4(r.get(14, 30), DT.white))
    }

    @Test func hairlineVectorStrokeKeepsTheFilesEdgePixelColour() {
        for (sample, edge, fill) in [(SampleType.u8, Float(0.86), Float(1)), (.u16, 0.86, 1), (.f32, 0.86, 1), (.f32, 2, 2)] {
            let fmt = PixelFormat(mode: .rgb, sample: sample, alpha: true)
            var d = DT.docWhite(40, 40, depth: sample)
            let vs = ShapeStroke(width: 0.25, paint: .solid(.rgb(0.48, 0.48, 0.48)))
            var cache = Surface(format: fmt)
            cache.fill(DT.rect(10, 10, 30, 30), with: [edge, edge, edge, 1])
            cache.fill(DT.rect(11, 11, 29, 29), with: [fill, fill, fill, 1])
            let sh = ShapeLayer(path: DT.polygon([(10.3, 10.3), (29.7, 10.3), (29.7, 29.7), (10.3, 29.7)]), fill: .solid(.rgb(fill, fill, fill)),
                                stroke: vs, cache: cache)
            var l = Layer(name: "shape", content: .shape(sh))
            l.effects.items = [.dropShadow(Shadow(common: FxCommon(.multiply, 0.75)))]
            d.layers.append(l)
            let r = DT.render(d)
            for (x, y) in [(Int32(10), Int32(20)), (29, 20), (20, 10), (20, 29)] {
                #expect(DT.close4(r.get(x, y), SIMD4(edge, edge, edge, 1)), "\(sample) edge pixel (\(x), \(y)): \(r.get(x, y))")
            }
            #expect(DT.close4(r.get(20, 20), SIMD4(fill, fill, fill, 1)), "\(sample) \(r.get(20, 20))")
        }
    }

    static func gradientShape(_ w: Double, _ h: Double) -> ShapeLayer {
        ShapeLayer(path: DT.polygon([(0, 0), (w, 0), (w, h), (0, h)]),
                   fill: .gradient(GradientFill(stops: [ColorStop(0, .black), ColorStop(1, .white)], angle: 0, scale: 1, style: .linear, reverse: false)),
                   stroke: ShapeStroke(width: 4))
    }

    @Test func splitStrokedGradientWithEffectKeepsDocumentPrecision() {
        for depth in [SampleType.u8, .u16, .f32] {
            var d = DT.docWhite(4000, 40, depth: depth)
            var sh = Self.gradientShape(4000, 40)
            sh.cache = DT.rasterizer.renderShape(sh, format: d.pixelFormat, clip: d.bounds)
            var layer = Layer(name: "gradient shape", content: .shape(sh))
            layer.effects.items = [Self.stroke(1, .outside, Self.blue)]
            d.layers.append(layer)
            let row = DT.render(d, DT.rect(0, 20, 4000, 21))
            let levels = Set(row.px.map { Int(($0.x * 65535).rounded()) })
            if depth == .u8 {
                #expect(levels.count <= 256, "8-bit control: \(levels.count) levels")
            } else {
                #expect(levels.count > 3000, "\(depth): split gradient has only \(levels.count) levels")
            }
        }
    }

    @Test func splitCacheKeepsSameShapeSeparateAtEachDocumentDepth() {
        let canvas = DT.rect(0, 0, 64, 8)
        var sh = Self.gradientShape(64, 8)
        sh.cache = DT.rasterizer.renderShape(sh, format: PixelFormat(mode: .rgb, sample: .f32, alpha: true), clip: canvas)
        var layer = Layer(name: "same shape", content: .shape(sh))
        layer.effects.items = [Self.stroke(1, .outside, Self.blue)]
        for depth in [SampleType.u8, .u16, .f32, .u8] {
            var d = DT.docWhite(64, 8, depth: depth)
            d.layers.append(layer)
            var fillOnly = sh
            fillOnly.stroke = nil; fillOnly.cache = nil
            let expected = DT.rasterizer.renderShape(fillOnly, format: PixelFormat(mode: .rgb, sample: depth, alpha: true), clip: canvas)!.pixel(x: 17, y: 4)[0]
            let actual = DT.px(d, 17, 4).x
            #expect(abs(actual - expected) < 1e-6, "\(depth): got \(actual), expected \(expected)")
        }
    }

    @Test func outlineShareTreatsStrokeAndShapeAsDisjointAreas() {
        #expect(EffectsCPU.outlineShare(0, 0) == 1)
        #expect(EffectsCPU.outlineShare(1, 0.3) == 0)
        let (cov, l): (Float, Float) = (0.6, 0.6)
        let s = EffectsCPU.outlineShare(cov, l)
        #expect(abs(s + l * (1 - s) - min(1 - cov + l, 1)) < 1e-6)
        #expect(abs(EffectsCPU.outlineShare(0.6, 0) - 0.4) < 1e-6)
        #expect(EffectsCPU.outlineShare(0.5, 1) == 1)
    }
}
