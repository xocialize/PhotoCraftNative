// Port of photocraft-engine (crates/engine/src/rasterize_style_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The fixtures add effects and vector masks directly (the Layer Style and vector-mask commands
// photocraft's tests use belong to other modules).

import Foundation
import PCDocument
import PCEngine
import PCFoundation
import Testing

@Suite struct RasterizeStyleTests {
    let id = "layer.rasterize.layerStyle"

    func composite(_ s: Session) throws -> [SIMD4<Float>] {
        let d = try #require(s.active?.doc)
        return try s.services.renderer.render(d, region: d.bounds).px
    }

    func maxDiff(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
        zip(a, b).map { p, q in (0..<4).map { abs(p[$0] - q[$0]) }.max() ?? 0 }.max() ?? 0
    }

    /// The quantisation step of one stored sample: the baked layer is stored at the document's depth.
    func tolerance(_ depth: Int) -> Float {
        switch depth {
        case 8: 2.5 / 255
        case 16: 2.0 / 32768 + 1e-4
        default: 1e-4
        }
    }

    func layer(_ s: Session, _ id: LayerId) -> Layer? { s.active?.doc.layer(id) }

    func fill(_ s: Session, _ id: LayerId, _ r: PixelRect, _ c: SIMD4<Float>) throws {
        try s.edit("fill") { doc, _ in
            doc.withRaster(of: id) { $0.writeRegion(r, PixelCodec.fromRGBA($0.format, rgba: [SIMD4<Float>](repeating: c, count: r.area))) }
        }
    }

    func addEffects(_ s: Session, _ id: LayerId, _ fx: [Effect]) throws {
        try s.edit("Layer Style") { doc, _ in
            doc.updateLayer(id) { l in
                l.effects.items += fx
                l.effects.enabled = true
            }
        }
    }

    func addVectorMask(_ s: Session, _ id: LayerId, _ corners: [(Double, Double)]) throws {
        let path = VectorPath([Subpath(closed: true, knots: corners.map { Knot.corner($0.0, $0.1) })])
        try s.edit("Add Vector Mask") { doc, _ in doc.updateLayer(id) { $0.vectorMask = VectorMask(path: path) } }
    }

    static func color(_ hex: String) -> PCColor {
        let c = Params.parseHex(hex) ?? SIMD4(0, 0, 0, 1)
        return .rgb(c.x, c.y, c.z)
    }

    static let stroke = Effect.stroke(StrokeFx(common: FxCommon(.normal, 1), size: 2, position: .outside, paint: .color(color("#0000ff"))))

    /// A white Background and a red rectangle (partly off the right edge of the canvas) with a
    /// Normal-mode drop shadow, outer glow, inner shadow, outside stroke and a half colour overlay.
    func scene(_ depth: Int) throws -> (Session, LayerId) {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 48, "depth": .int(depth)])
        let id = LayerId(try #require(try s.execute("layer.new.layer", ["name": "a"])["layer"]?.uint64Value))
        try fill(s, id, PixelRect(x0: 14, y0: 10, x1: 70, y1: 30), SIMD4(0xe0 / 255, 0x20 / 255, 0x10 / 255, 1))
        try addEffects(s, id, [
            .dropShadow(Shadow(common: FxCommon(.normal, 0.75), color: Self.color("#102040"), distance: 6, size: 4)),
            .outerGlow(Glow(common: FxCommon(.normal, 0.75), paint: .color(Self.color("#20c040")), size: 5)),
            .innerShadow(Shadow(common: FxCommon(.normal, 0.75), distance: 3, size: 3)),
            Self.stroke,
            .colorOverlay(Effect.ColorOverlay(common: FxCommon(.normal, 0.5), color: Self.color("#ffff00"))),
        ])
        return (s, id)
    }

    func bakeAndCheck(_ s: Session, _ id: LayerId, _ depth: Int) throws {
        let before = try composite(s)
        let steps = try #require(s.active?.history.pastCount)
        let r = try s.execute(self.id, [:])
        #expect(r["layers"] == .ids([id]))
        #expect(s.active?.history.pastCount == steps + 1, "one history step")
        let l = try #require(layer(s, id))
        #expect(l.effects.items.isEmpty, "effects baked")
        #expect(l.rasterSurface != nil)
        #expect(l.mask == nil && l.vectorMask == nil, "masks applied")
        #expect(l.fillOpacity == 1)
        let d = maxDiff(before, try composite(s))
        #expect(d <= tolerance(depth), "depth \(depth): composite changed by \(d)")
        try s.execute("edit.undo")
        #expect(layer(s, id)?.effects.items.count == 5, "undo restores the effects")
        #expect(maxDiff(before, try composite(s)) == 0, "undo restores the picture")
    }

    @Test func bakesEffectsWithoutChangingTheComposite() throws {
        for depth in [8, 16, 32] {
            let (s, id) = try scene(depth)
            try bakeAndCheck(s, id, depth)
        }
    }

    @Test func fillOpacityMasksAndLayerOpacitySurviveTheBake() throws {
        for depth in [8, 16, 32] {
            let (s, id) = try scene(depth)
            try s.execute("layer.setProps", ["layer": .id(id), "fill": 0.4, "opacity": 0.7])
            try s.execute("select.rect", ["x": 0, "y": 0, "width": 34, "height": 48])
            try s.execute("layer.layerMask.revealSelection")
            try addVectorMask(s, id, [(4, 4), (60, 4), (60, 26), (4, 26)])
            try bakeAndCheck(s, id, depth)
            try s.execute("edit.redo")
            #expect(layer(s, id)?.opacity == 0.7, "the layer's own opacity stays a property")
        }
    }

    @Test func keepsThePixelsPastTheCanvas() throws {
        let (s, id) = try scene(8)
        try s.execute(self.id, ["layer": .id(id)])
        let px = try #require(layer(s, id)?.rasterSurface)
        // The rectangle runs to x = 70 and its stroke and glow further, past the 64 px canvas.
        #expect(px.contentBounds.x1 > 70, "\(px.contentBounds)")
    }

    @Test func rasterizesFillContentFirst() throws {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 30])
        try s.execute("layer.newFillLayer.solidColor", ["color": "#3366cc"])
        let id = try #require(s.active?.activeLayer)
        try addVectorMask(s, id, [(8, 8), (28, 8), (28, 20), (8, 20)])
        try addEffects(s, id, [.stroke(StrokeFx(common: FxCommon(.normal, 1), size: 3, position: .outside, paint: .color(Self.color("#ff0000"))))])
        let before = try composite(s)
        let steps = try #require(s.active?.history.pastCount)
        try s.execute(self.id, [:])
        #expect(s.active?.history.pastCount == steps + 1, "rasterize and bake are one step")
        #expect(layer(s, id)?.rasterSurface != nil)
        #expect(layer(s, id)?.effects.items.isEmpty == true)
        #expect(maxDiff(before, try composite(s)) <= tolerance(8))
    }

    @Test func severalSelectedLayersBakeInOneStep() throws {
        let (s, a) = try scene(8)
        let b = LayerId(try #require(try s.execute("layer.new.layer", ["name": "b"])["layer"]?.uint64Value))
        try fill(s, b, PixelRect(x0: 2, y0: 34, x1: 12, y1: 42), SIMD4(0, 1, 0, 1))
        try addEffects(s, b, [Self.stroke])
        let plain = LayerId(try #require(try s.execute("layer.new.layer", ["name": "plain"])["layer"]?.uint64Value))
        try s.updateActive { $0.selectedLayerIds = [a, b, plain] }
        let steps = try #require(s.active?.history.pastCount)
        let r = try s.execute(id, [:])
        #expect(r["layers"] == .ids([a, b]))
        #expect(s.active?.history.pastCount == steps + 1)
        #expect(layer(s, a)?.effects.items.isEmpty == true && layer(s, b)?.effects.items.isEmpty == true)
    }

    @Test func disabledAndBadParamsFailGracefully() throws {
        let empty = Session()
        #expect(throws: EngineError.self, "no document") { try empty.execute(id, [:]) }
        let (s, a) = try scene(8)
        let bg = try #require(s.active?.doc.layers.first?.id)
        #expect(throws: EngineError.self, "the Background has no effects") { try s.execute(id, ["layer": .id(bg)]) }
        #expect(throws: EngineError.self, "no such layer") { try s.execute(id, ["layer": 9999]) }
        // photocraft passes u64::MAX; JSON numbers are doubles here, where 2^64 isn't an id (and,
        // as in photocraft's `layer_param`, a value that isn't an id means the active layer).
        #expect(throws: EngineError.self, "no such layer") { try s.execute(id, ["layer": 1e18]) }
        #expect(layer(s, a)?.effects.items.count == 5, "a bad call changes nothing")
        try s.edit("Hide All Effects") { doc, _ in doc.updateLayer(a) { $0.effects.enabled = false } }
        #expect(throws: EngineError.self, "hidden effects: nothing to bake") { try s.execute(id, ["layer": .id(a)]) }
        try s.edit("Show All Effects") { doc, _ in doc.updateLayer(a) { $0.effects.enabled = true } }
        let g = LayerId(try #require(try s.execute("layer.new.group", [:])["layer"]?.uint64Value))
        try addEffects(s, g, [Self.stroke])
        #expect(throws: EngineError.self, "group styles are not baked") { try s.execute(id, ["layer": .id(g)]) }
    }
}
