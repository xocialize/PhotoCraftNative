// AB-T-0300: Scale Effects and Create Layer act on the layer `"layer"` names, whichever is active — their enabled
// checks read it too, in `execute` and in `isEnabled` — and Scale Effects takes a layer whose effects are all
// hidden. Also what PixelAgencyEditor's AB-T-0271 relies on: Image Size scales every layer's effects itself
// (shown or hidden, in groups, by the mean of the two factors). MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct LayerStyleTargetTests {
    static func shadow(_ enabled: Bool, distance: Float = 10, size: Float = 4) -> Effect {
        .dropShadow(Shadow(common: FxCommon(enabled: enabled, blend: .multiply, opacity: 0.75), distance: distance, size: size))
    }

    /// 40 × 30: layer `a` with a square and `fx` (nil: no effects), then `b`, active, with a square and `bFx`.
    func session(_ fx: [Effect]?, _ bFx: [Effect] = []) throws -> (Session, a: LayerId, b: LayerId) {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 30, "background": "transparent"])
        func layer(_ fx: [Effect]) throws -> LayerId {
            try s.execute("layer.new.layer")
            let id = s.active!.activeLayer!
            try s.edit("setup") { doc, _ in
                doc.updateLayer(id) { l in
                    l.withRaster { $0.fill(PixelRect(x0: 10, y0: 8, x1: 30, y1: 22), with: [0.2, 0.5, 0.9, 1]) }
                    l.effects.items = fx
                }
            }
            return id
        }
        let a = try layer(fx ?? [])
        let b = try layer(bFx)
        return (s, a, b)
    }

    func shadowOf(_ s: Session, _ id: LayerId) -> Shadow? {
        guard case .dropShadow(let sh)? = s.active!.doc.layer(id)!.effects.items.first else { return nil }
        return sh
    }

    @Test func scaleEffectsScalesTheNamedLayerWhicheverIsActive() throws {
        let (s, a, b) = try session([Self.shadow(true)])
        #expect(s.active!.activeLayer == b)
        // b, the active layer, has no effects: the menu item (no params) is off; for a it's on.
        #expect(!s.isEnabled("layer.layerStyle.scaleEffects"))
        #expect(s.isEnabled("layer.layerStyle.scaleEffects", ["layer": .id(a)]))
        try s.execute("layer.layerStyle.scaleEffects", ["layer": .id(a), "scale": 50])
        #expect(shadowOf(s, a)?.distance == 5 && shadowOf(s, a)?.size == 2)
        #expect(s.active!.activeLayer == b && s.active!.doc.layer(b)!.effects.items.isEmpty)
        // A named layer without effects is refused even while the active one has some.
        let (t, c, _) = try session(nil, [Self.shadow(true)])
        #expect(t.isEnabled("layer.layerStyle.scaleEffects"))
        #expect(!t.isEnabled("layer.layerStyle.scaleEffects", ["layer": .id(c)]))
        #expect(throws: EngineError.self) { try t.execute("layer.layerStyle.scaleEffects", ["layer": .id(c), "scale": 50]) }
    }

    @Test func scaleEffectsScalesALayerWhoseEffectsAreAllHidden() throws {
        let (s, a, b) = try session([Self.shadow(false)], [Self.shadow(true, distance: 6, size: 6)])
        try s.execute("layer.layerStyle.scaleEffects", ["layer": .id(a), "scale": 200])
        #expect(shadowOf(s, a)?.distance == 20 && shadowOf(s, a)?.size == 8 && shadowOf(s, a)?.common.enabled == false)
        #expect(shadowOf(s, b)?.distance == 6, "the active layer is untouched")
        // Active, with only hidden effects: the menu item is on too.
        try s.selectLayer(a)
        #expect(s.isEnabled("layer.layerStyle.scaleEffects"))
        try s.execute("layer.layerStyle.scaleEffects", ["scale": 50])
        #expect(shadowOf(s, a)?.distance == 10)
    }

    @Test func createLayerUsesTheNamedLayer() throws {
        let (s, a, b) = try session([Self.shadow(true)])
        #expect(!s.isEnabled("layer.layerStyle.createLayer"))
        #expect(s.isEnabled("layer.layerStyle.createLayer", ["layer": .id(a)]))
        let n0 = s.active!.doc.layers.count
        let r = try s.execute("layer.layerStyle.createLayer", ["layer": .id(a)])
        #expect(r["layers"] == 1 && s.active!.doc.layers.count == n0 + 1)
        #expect(s.active!.doc.layer(a)!.effects.items.isEmpty)
        _ = b
        // It makes layers from the effects showing: with all of them hidden, or the layer's effects off, it is off.
        let (t, c, _) = try session([Self.shadow(false)], [Self.shadow(true)])
        #expect(!t.isEnabled("layer.layerStyle.createLayer", ["layer": .id(c)]))
        let (u, d, _) = try session([Self.shadow(true)])
        try u.edit("off") { doc, _ in doc.updateLayer(d) { $0.effects.enabled = false } }
        #expect(!u.isEnabled("layer.layerStyle.createLayer", ["layer": .id(d)]))
    }

    /// Image Size is Photoshop's Image Size with Scale Styles on: it scales every layer's effects itself, shown or
    /// hidden, active or not, inside groups, in its one step, by the mean of the two factors ((sx + sy) / 2). A host
    /// running it must not scale them again. "none" (resolution only) leaves them.
    @Test func imageSizeScalesEveryLayersEffectsItself() throws {
        let (s, a, b) = try session([Self.shadow(false)], [Self.shadow(true, distance: 6, size: 6)])
        try s.execute("layer.groupLayers", ["layer": .id(a)])
        try s.selectLayer(b)
        let past = s.active!.history.pastCount
        try s.execute("image.imageSize", ["width": 80, "height": 60])
        #expect(shadowOf(s, a)?.distance == 20 && shadowOf(s, a)?.common.enabled == false, "hidden, grouped, not active")
        #expect(shadowOf(s, b)?.distance == 12 && shadowOf(s, b)?.size == 12)
        #expect(s.active!.history.pastCount == past + 1)
        // Stretched: ×2 across, ×1 down scales by 1.5.
        try s.execute("image.imageSize", ["width": 160, "height": 60])
        #expect(shadowOf(s, b)?.distance == 18)
        try s.execute("image.imageSize", ["resolution": 300, "resample": "none"])
        #expect(shadowOf(s, b)?.distance == 18)
    }
}
