// Port of photocraft-engine (crates/engine/src/tests.rs: the painting tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct PaintingTests {
    func sessionWithDoc() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 48])
        return s
    }

    func px(_ s: Session, _ x: Int, _ y: Int) throws -> [Float] {
        (try s.execute("document.pixel", ["x": .int(x), "y": .int(y)]).arrayValue ?? []).compactMap { $0.floatValue }
    }

    @Test func paintStrokeAndSelection() throws {
        let s = try sessionWithDoc()
        try s.execute("layer.new.layer")
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 32, "height": 48])
        let r = try s.execute("paint.stroke", ["points": [[4, 20], [60, 20]], "size": 6, "color": "#0000ff"])
        #expect((r["damage"]?[2]?.intValue ?? 0) > 0)
        #expect(try px(s, 10, 20) == [0, 0, 1, 1])
        #expect(try px(s, 50, 20) == [1, 1, 1, 1], "outside selection stays white")
        try s.execute("select.deselect")
        try s.execute("paint.stroke", ["points": [[4, 30], [60, 30]], "size": 6, "erase": false])
        #expect(try px(s, 50, 30) == [0, 0, 0, 1], "foreground is black")
    }

    @Test func aNewAdjustmentMaskCanBePaintedImmediately() throws {
        for depth in [8, 16, 32] {
            let s = Session()
            try s.execute("file.new", ["width": 64, "height": 48, "depth": .int(depth)])
            try s.execute("layer.newAdjustmentLayer.invert")
            #expect(try px(s, 20, 20) == [0, 0, 0, 1])
            try s.execute("paint.stroke", ["points": [[20, 20]], "size": 10, "hardness": 1.0, "color": "#000000", "target": "mask"])
            #expect(try px(s, 20, 20) == [1, 1, 1, 1])
            #expect(try px(s, 2, 2) == [0, 0, 0, 1])
            try s.execute("edit.undo")
            #expect(try px(s, 20, 20) == [0, 0, 0, 1])
            try s.execute("edit.redo")
            #expect(try px(s, 20, 20) == [1, 1, 1, 1])
        }
    }

    @Test func damageIsReportedForStrokesOnly() throws {
        let s = try sessionWithDoc()
        try s.execute("layer.new.layer")
        // A new empty layer changes no pixels (#1771).
        #expect(s.active?.lastDamage == .empty)
        try s.execute("paint.stroke", ["points": [[10, 10], [20, 10]], "size": 4])
        let d = try #require(s.active?.lastDamage)
        #expect(d.contains(x: 15, y: 10) && d.width < 30)
        // Undo reports the same bounded area back, not a whole-canvas recomposite.
        try s.execute("edit.undo")
        let u = try #require(s.active?.lastDamage)
        #expect(u.contains(x: 15, y: 10) && u.width < 30, "\(u) after the stroke's \(d)")
    }

    @Test func paintingCanTargetTheLayerMask() throws {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 40])
        try s.execute("layer.newAdjustmentLayer.invert")
        let id = try #require(s.active?.activeLayer)
        try s.edit("mask") { doc, _ in _ = doc.updateLayer(id) { $0.mask = .revealAll() } }
        // Adjustment layers are paintable through their mask only.
        #expect(throws: EngineError.self) { try s.execute("paint.stroke", ["points": [[20, 20]], "size": 10, "hardness": 1.0, "color": "#000000"]) }
        try s.execute("paint.stroke", ["points": [[20, 20]], "size": 10, "hardness": 1.0, "color": "#000000", "target": "mask"])
        func m(_ x: Int32, _ y: Int32) -> Float { s.active?.doc.layer(id)?.mask?.surface.pixel(x: x, y: y).first ?? -1 }
        #expect(m(20, 20) < 0.01, "painted black")
        #expect(m(2, 2) > 0.99, "rest still revealed")
        // Eraser on a mask paints the background colour (white).
        try s.execute("paint.stroke", ["points": [[20, 20]], "size": 10, "hardness": 1.0, "erase": true, "target": "mask"])
        #expect(m(20, 20) > 0.99)
        // Gradient into the mask.
        try s.execute("paint.gradient", ["from": [0, 0], "to": [40, 0], "colors": ["#000000", "#ffffff"], "target": "mask"])
        #expect(m(2, 20) < 0.1 && m(38, 20) > 0.9)
    }

    /// (photocraft's `edit.transform` check belongs to the transform module.)
    @Test func layerLocksAreSetAndEnforced() throws {
        let s = Session()
        try s.execute("file.new", ["width": 20, "height": 20])
        try s.execute("layer.new.layer")
        try s.execute("layer.setProps", ["locks": ["pixels": true]])
        #expect(throws: EngineError.self, "pixel lock blocks painting") { try s.execute("paint.stroke", ["points": [[5, 5]], "size": 4]) }
        try s.execute("layer.setProps", ["locks": ["pixels": false, "position": true]])
        try s.execute("paint.stroke", ["points": [[5, 5]], "size": 4])
        #expect(throws: EngineError.self) { try s.execute("layer.setProps", ["locks": ["bogus": true]]) }
        let l = try #require(s.active.flatMap { d in d.activeLayer.flatMap { d.doc.layer($0) } })
        #expect(l.locks.position && !l.locks.pixels)
    }

    @Test func allLockBlocksPaintingAMaskButPixelsLockDoesNot() throws {
        let s = Session()
        try s.execute("file.new", ["width": 20, "height": 20])
        try s.execute("layer.new.layer")
        let id = try #require(s.active?.activeLayer)
        try s.edit("mask") { doc, _ in _ = doc.updateLayer(id) { $0.mask = .revealAll() } }
        try s.execute("layer.setProps", ["locks": ["all": true]])
        let steps = s.active?.history.entries.count
        do {
            try s.execute("paint.stroke", ["points": [[5, 5]], "size": 4, "hardness": 1.0, "color": "#000000", "target": "mask"])
            Issue.record("expected a lock error")
        } catch {
            #expect("\(error)" == "Could not complete your request because the layer \"Layer 1\" is locked")
        }
        func mask() -> Float { s.active?.doc.layer(id)?.mask?.surface.pixel(x: 5, y: 5).first ?? -1 }
        #expect(mask() > 0.99, "rejected stroke leaves the mask reveal-all")
        #expect(s.active?.history.entries.count == steps, "rejected stroke adds no Brush Tool history step")
        try s.execute("layer.setProps", ["locks": ["all": false, "pixels": true]])
        try s.execute("paint.stroke", ["points": [[5, 5]], "size": 4, "hardness": 1.0, "color": "#000000", "target": "mask"])
        #expect(mask() < 0.01, "pixels-only lock permits mask painting")
        try s.execute("edit.undo")
        #expect(mask() > 0.99, "undo restores the mask")
    }

    /// `paint.stroke` on an alpha channel and on the Quick Mask: one history step each, layer
    /// pixels untouched, and the eraser paints the background colour there (Photoshop).
    @Test func strokeTargetsAlphaChannelsAndTheQuickMask() throws {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 40, "background": "white"])
        try s.edit("Channels") { doc, _ in
            let f = Channels.channelFormat(doc)
            doc.channels.append(AlphaChannel(name: "Alpha 1", surface: Surface(format: f, defaultPixel: [0])))
            doc.quickMask = AlphaChannel(name: "Quick Mask", surface: Surface(format: f, defaultPixel: [0]))
        }
        let layerBefore = s.active?.doc.layers
        for target: JSONValue in [["channel": 0], "quickMask"] {
            let past = s.active?.history.pastCount ?? 0
            try s.execute("paint.stroke", ["points": [[20, 20]], "size": 10, "hardness": 1.0, "color": "#ffffff", "target": target])
            let d = try #require(s.active)
            #expect(d.history.pastCount == past + 1, "\(target): one step")
            let surf = try Channels.readTargetSurface(d.doc, layer: d.activeLayer, ["target": target])
            #expect(surf.sampleChannel(x: 20, y: 20, 0) == 1 && surf.sampleChannel(x: 2, y: 2, 0) == 0, "\(target)")
            try s.execute("tools.setColors", ["background": "#000000"])
            try s.execute("paint.stroke", ["points": [[20, 20]], "size": 4, "hardness": 1.0, "erase": true, "target": target])
            let e = try Channels.readTargetSurface(try #require(s.active).doc, layer: nil, ["target": target])
            #expect(e.sampleChannel(x: 20, y: 20, 0) == 0 && e.sampleChannel(x: 23, y: 20, 0) == 1, "\(target): erased to the background colour")
            try s.execute("tools.setColors", ["background": "#ffffff"])
        }
        #expect(s.active?.doc.layers == layerBefore, "layer pixels untouched")
        #expect(throws: EngineError.self) { try s.execute("paint.stroke", ["points": [[20, 20]], "target": ["channel": 5]]) }
    }

    @Test func maskAndPixelsKeepTheirOwnColourPair() throws {
        let red = SIMD4<Float>(1, 0, 0, 1), green = SIMD4<Float>(0, 1, 0, 1), blue = SIMD4<Float>(0, 0, 1, 1)
        let (white, black) = ToolState.maskColors
        let s = try sessionWithDoc()
        try s.execute("tools.setColors", ["foreground": "#ff0000", "background": "#0000ff"])
        func pair() -> [SIMD4<Float>] { [s.tools.foreground, s.tools.background] }
        var changed = s.tools.targetMask(false)
        #expect(!changed, "already on the pixels: nothing changes")
        #expect(pair() == [red, blue])
        changed = s.tools.targetMask(true)
        #expect(changed)
        #expect(pair() == [white, black], "a mask starts at white/black")
        changed = s.tools.targetMask(true)
        #expect(!changed, "targeting it again changes nothing")
        #expect(pair() == [white, black])
        s.tools.targetMask(false)
        #expect(pair() == [red, blue], "the pixels get their colours back")
        try s.execute("tools.setColors", ["foreground": "#00ff00"])
        s.tools.targetMask(true)
        #expect(pair() == [white, black])
        s.tools.targetMask(false)
        #expect(pair() == [green, blue], "a colour picked on the pixels is remembered")
        // A colour picked while the mask is targeted is remembered for masks.
        s.tools.targetMask(true)
        try s.execute("tools.setColors", ["foreground": "#808080"])
        let maskFg = s.tools.foreground
        #expect(abs(maskFg.x - 0.5) < 0.01)
        s.tools.targetMask(false)
        #expect(pair() == [green, blue])
        s.tools.targetMask(true)
        #expect(pair() == [maskFg, black])
    }
}
