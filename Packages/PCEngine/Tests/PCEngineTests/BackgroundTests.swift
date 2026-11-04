// Port of photocraft-engine (crates/engine/src/background_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Layer from Background and the fills are done directly here (their commands belong to other
// modules).

import Foundation
import PCDocument
import PCEngine
import PCFoundation
import Testing

@Suite struct BackgroundTests {
    let cmd = "layer.new.backgroundFromLayer"

    func doc(_ s: Session) -> Document { s.active?.doc ?? Document(name: "", size: PixelSize(width: 1, height: 1), mode: .rgb, depth: .u8) }
    func order(_ s: Session) -> [LayerId] { doc(s).layers.map(\.id) }
    func pixel(_ s: Session, _ x: Int32, _ y: Int32) -> [Float] {
        doc(s).layers.first?.surface?.readRegion(PixelRect(x0: x, y0: y, x1: x + 1, y1: y + 1)) ?? []
    }

    func newLayer(_ s: Session, _ name: String) throws -> LayerId {
        LayerId(try #require(try s.execute("layer.new.layer", ["name": .string(name)])["layer"]?.uint64Value))
    }

    /// Layer › New › Layer from Background, done directly.
    func layerFromBackground(_ s: Session) throws {
        try s.edit("Layer From Background") { doc, _ in
            if let id = doc.background?.id { LayerOps.backgroundToLayer(&doc, id) }
        }
    }

    /// Bottom to top: Layer 0 (the old Background, now a normal layer), A, B. A has a 4×4 red
    /// square at (2, 2); the rest of it is transparent.
    func session(_ depth: Int) throws -> (Session, [LayerId]) {
        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 12, "depth": .int(depth)])
        try layerFromBackground(s)
        let l0 = try #require(doc(s).layers.first?.id)
        let a = try newLayer(s, "A")
        try s.edit("fill") { doc, _ in
            let r = PixelRect(x0: 2, y0: 2, x1: 6, y1: 6)
            doc.withRaster(of: a) { $0.writeRegion(r, PixelCodec.fromRGBA($0.format, rgba: [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 1), count: r.area))) }
        }
        let b = try newLayer(s, "B")
        return (s, [l0, a, b])
    }

    /// A Background (the white one `file.new` makes) with A and B above it.
    func withBackground() throws -> (Session, [LayerId]) {
        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 12])
        let bg = try #require(doc(s).layers.first?.id)
        let a = try newLayer(s, "A"), b = try newLayer(s, "B")
        return (s, [bg, a, b])
    }

    /// The steps take Photoshop 27.11's History names (AB-T-0432, by script): Layer from Background is "Make Layer" and
    /// Background from Layer "Convert to Background".
    @Test func stepsTakePhotoshopsHistoryNames() throws {
        let s = Session()
        try s.execute("file.new", ["width": 4, "height": 4])
        try s.execute("layer.new.layerFromBackground")
        #expect(doc(s).background == nil && doc(s).layers.first?.name == "Layer 0")
        #expect(s.active?.history.undoLabel == "Make Layer")
        try s.execute(cmd)
        #expect(doc(s).background != nil)
        #expect(s.active?.history.undoLabel == "Convert to Background")
    }

    @Test func makesTheLayerTheBackgroundAtTheBottom() throws {
        for depth in [8, 16, 32] {
            let (s, l) = try session(depth)
            let (l0, a, b) = (l[0], l[1], l[2])
            s.tools.background = SIMD4(0, 0, 1, 1)
            try s.execute("layer.select", ["layer": .id(a)])
            #expect(s.isEnabled(cmd), "\(depth)")
            #expect(try s.execute(cmd, [:])["layer"] == .id(a))
            #expect(order(s) == [a, l0, b], "\(depth): drops to the bottom")
            let bgLayer = try #require(doc(s).layers.first)
            #expect(doc(s).isBackground(bgLayer.id) && bgLayer.name == "Background", "\(depth)")
            #expect(s.active?.activeLayer == a)
            // Its pixels stay; transparency takes the background colour (blue).
            let red = pixel(s, 3, 3), blue = pixel(s, 10, 10)
            #expect(abs(red[0] - 1) < 1e-3 && abs(red[2]) < 1e-3 && abs(red[3] - 1) < 1e-3, "\(depth): \(red)")
            #expect(abs(blue[0]) < 1e-3 && abs(blue[2] - 1) < 1e-3 && abs(blue[3] - 1) < 1e-3, "\(depth): \(blue)")
            // Now there is a Background: the item greys.
            #expect(!s.isEnabled(cmd))
            #expect(throws: EngineError.self, "\(depth): one Background per document") { try s.execute(cmd, ["layer": .id(b)]) }
            // One step: undo restores the layer where it was, transparent.
            #expect(s.undo())
            #expect(order(s) == [l0, a, b], "\(depth)")
            let restored = try #require(doc(s).layer(a))
            #expect(!doc(s).isBackground(restored.id) && restored.name == "A")
            #expect(s.redo())
            #expect(order(s) == [a, l0, b], "\(depth)")
            #expect(doc(s).background != nil)
        }
    }

    @Test func aLayerInAGroupLeavesItAndKeepsItsLook() throws {
        let (s, l) = try session(8)
        let (l0, a, b) = (l[0], l[1], l[2])
        try s.execute("layer.select", ["layer": .id(b)])
        try s.execute("layer.groupLayers")
        try s.execute("layer.setProps", ["layer": .id(b), "opacity": 0.5, "visible": false])
        try s.execute("layer.select", ["layer": .id(b)])
        try s.execute(cmd)
        let d = doc(s)
        #expect(d.layers[0].id == b)
        #expect(d.layers.dropFirst().allSatisfy { $0.id != b })
        #expect(d.layers[1].id == l0)
        #expect(d.layers[2].id == a)
        #expect(d.isBackground(d.layers[0].id) && !d.layers[0].visible, "visibility is kept")
        #expect(d.layers[0].opacity == 1)
    }

    @Test func refusesGroupsAdjustmentsMissingLayersAndBadParams() throws {
        let none = Session()
        #expect(!none.isEnabled(cmd))
        #expect(throws: EngineError.self) { try none.execute(cmd, [:]) }
        // Already a Background: unavailable, for any layer.
        let (s1, l1) = try withBackground()
        #expect(!s1.isEnabled(cmd))
        #expect(throws: EngineError.self) { try s1.execute(cmd, ["layer": .id(l1[1])]) }
        #expect(throws: EngineError.self) { try s1.execute(cmd, ["layer": .id(l1[0])]) }
        // Bad params.
        let (s, l) = try session(8)
        let a = l[1]
        let bad: [JSONValue] = [["layer": "A"], ["layer": -1], ["layer": 1.5], ["layer": 99999], ["layer": [.id(a)]]]
        for p in bad {
            #expect(throws: EngineError.self, "\(p)") { try s.execute(cmd, p) }
        }
        #expect(doc(s).background == nil)
        // A group or an adjustment layer can't become the Background.
        try s.execute("layer.select", ["layer": .id(a)])
        try s.execute("layer.groupLayers")
        #expect(!s.isEnabled(cmd), "the group is active")
        #expect(throws: EngineError.self) { try s.execute(cmd, [:]) }
        try s.edit("New Invert Layer") { doc, active in
            active = doc.insertAbove(active, Layer(name: "Invert", content: .adjustment(.invert)))
        }
        #expect(!s.isEnabled(cmd))
        #expect(throws: EngineError.self) { try s.execute(cmd, [:]) }
        #expect(doc(s).background == nil)
    }

    /// The rule lives in `LayerOps.keepBackgroundAtBottom`, which the core's arrange and move
    /// commands apply.
    @Test func theBackgroundStaysAtTheBottom() throws {
        let (s, l) = try withBackground()
        let (bg, a, b) = (l[0], l[1], l[2])
        for c in ["layer.arrange.bringForward", "layer.arrange.bringToFront", "layer.arrange.sendBackward", "layer.arrange.sendToBack"] {
            #expect(throws: EngineError.self, "\(c)") { try s.execute(c, ["layer": .id(bg)]) }
            #expect(order(s) == [bg, a, b], "\(c)")
        }
        #expect(throws: EngineError.self) { try s.execute("layer.arrange.sendBackward", ["layer": .id(a)]) }
        try s.execute("layer.arrange.sendToBack", ["layer": .id(b)])
        #expect(order(s) == [bg, b, a], "Send to Back stops above the Background")
        #expect(throws: EngineError.self) { try s.execute("layer.moveTo", ["layer": .id(bg), "target": .id(a), "position": "above"]) }
        #expect(throws: EngineError.self) { try s.execute("layer.moveTo", ["layer": .id(a), "target": .id(bg), "position": "below"]) }
        #expect(throws: EngineError.self) { try s.execute("layer.moveTo", ["layer": .id(a), "target": .id(bg), "position": "below", "copy": true]) }
        #expect(throws: EngineError.self) { try s.execute("layer.moveTo", ["layers": [.id(bg), .id(a)], "target": .id(b), "position": "above"]) }
        #expect(order(s) == [bg, b, a])
        try s.execute("layer.moveTo", ["layer": .id(a), "target": .id(bg), "position": "above"])
        #expect(order(s) == [bg, a, b], "above the Background is fine")
        try s.execute("layer.select", ["layer": .id(bg)])
        try s.execute("layer.select", ["layer": .id(b), "mode": "add"])
        #expect(throws: EngineError.self) { try s.execute("layer.arrange.reverse") }
        #expect(order(s) == [bg, a, b])
        // As a normal layer it moves freely again.
        try layerFromBackground(s)
        try s.execute("layer.arrange.bringToFront", ["layer": .id(bg)])
        #expect(order(s) == [a, b, bg])
    }
}
