// Port of photocraft-io (crates/io/tests/effects_multi.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Multiple instances of an effect (Photoshop CC's several strokes / shadows / overlays) and
// multi-subpath shape components survive a PSD round trip and render the same. The `lfx2`
// layout of several instances is checked at block level in PCIOMapsTests' EffectsMapTests;
// here the whole document goes through export and import and is composited by PCRender (with the
// CoreGraphics stand-in for photocraft-vector's shape rendering).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIO

@Suite struct EffectsMultiTests {
    init() { ExportSweep.install() }
    static func stroke(_ size: Float, _ position: StrokePosition, _ paint: FxPaint, _ opacity: Float) -> Effect {
        .stroke(StrokeFx(common: FxCommon(.normal, opacity), size: size, position: position, paint: paint))
    }

    /// Max premultiplied difference of the two composites (photocraft's local `max_diff`).
    static func maxDiff(_ a: Document, _ b: Document) throws -> Float {
        let (x, y) = (try MapsKit.flatten(a).px, try MapsKit.flatten(b).px)
        #expect(x.count == y.count)
        var m: Float = 0
        for (p, q) in zip(x, y) { for c in 0 ..< 4 { m = max(m, abs(p[c] * p.w - q[c] * q.w)) } }
        return m
    }

    @Test(arguments: [false, true]) func severalStrokesAndShadowsRoundtrip(_ photoshop: Bool) throws {
        var d = Document.withBackground(name: "t", size: PixelSize(width: 64, height: 48), mode: .rgb, depth: .u8, fill: .white)
        var l = Layer.raster("blob", format: .rgba8)
        l.withRaster { $0.fill(rect(20, 14, 44, 34), with: [0.8, 0.2, 0.1, 1]) }
        let grad = StyleGradient(stops: [ColorStop(0, .rgb(0, 0, 1)), ColorStop(1, .rgb(1, 1, 0))], angle: 30)
        guard case let .dropShadow(base) = Effect.defaultDropShadow() else {
            Issue.record("the default drop shadow is a drop shadow")
            return
        }
        var moved = base
        moved.distance = 9
        moved.angle = 45
        moved.useGlobalLight = false
        let shadow = Effect.dropShadow(moved)
        l.effects.items = [
            Self.stroke(2, .outside, .color(.rgb(1, 1, 1)), 1),
            Self.stroke(5, .outside, .gradient(grad), 0.8),
            Self.stroke(3, .inside, .color(.rgb(0, 0.5, 0)), 1),
            Self.stroke(4, .center, .color(.rgb(0, 0, 0)), 0.5),
            Effect.defaultDropShadow(),
            shadow,
        ]
        d.layers.append(l)
        let back = try MapsKit.roundtrip(d, options: MapsKit.options(photoshop: photoshop))
        let fx = back.layers[1].effects.items
        let strokes: [StrokeFx] = fx.compactMap { if case let .stroke(s) = $0 { s } else { nil } }
        #expect(strokes.count == 4)
        #expect(strokes.map(\.size) == [2, 5, 3, 4])
        #expect(strokes.map(\.position) == [.outside, .outside, .inside, .center])
        if strokes.count == 4 {
            if case .gradient = strokes[1].paint {} else { Issue.record("second stroke lost its gradient") }
            #expect(abs(strokes[3].common.opacity - 0.5) < 1e-3)
        }
        #expect(fx.filter { if case .dropShadow = $0 { true } else { false } }.count == 2)
        let m = try Self.maxDiff(d, back)
        #expect(m <= 1.0 / 255 + 1e-5, "render changed by \(m)")
    }

    @Test(arguments: [false, true]) func joinedShapeComponentsRoundtrip(_ photoshop: Bool) throws {
        var d = Document.withBackground(name: "t", size: PixelSize(width: 40, height: 40), mode: .rgb, depth: .u8, fill: .white)
        let outer = Subpath.polygon([(5, 5), (35, 5), (35, 35), (5, 35)])
        let hole = Subpath.polygon([(12, 12), (12, 28), (28, 28), (28, 12)]).withOp(.join)
        let sh = ShapeLayer(path: VectorPath([outer, hole]), fill: .solid(.rgb(0.2, 0.4, 0.9)))
        var l = MapsKit.shapeLayer("ring", sh, canvas: d.bounds)
        l.effects.items = [Self.stroke(2, .outside, .color(.rgb(1, 0, 0)), 1)]
        d.layers.append(l)
        // The hole is stroked too (the outline is the joined component).
        #expect(try MapsKit.pixel(d, 20, 20).y > 0.9, "hole shows the background")
        let inHole = try MapsKit.pixel(d, 20, 13)
        #expect(inHole.x > 0.9 && inHole.y < 0.1, "stroke inside the hole: \(inHole)")
        let back = try MapsKit.roundtrip(d, options: MapsKit.options(photoshop: photoshop))
        guard case let .shape(bsh) = back.layers[1].content else {
            Issue.record("shape layer: \(back.layers[1].content.kindName)")
            return
        }
        #expect(bsh.path.subpaths.map(\.op) == [.combine, .join])
        let m = try Self.maxDiff(d, back)
        #expect(m <= 1.0 / 255 + 1e-5, "render changed by \(m)")
    }
}
