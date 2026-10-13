// Port of photocraft-engine (crates/engine/src/stamp_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct StampTests {
    /// Fills `r` (default: the canvas) of layer `id` with `c`.
    func fill(_ s: Session, _ id: LayerId, _ c: SIMD4<Float>, _ r: PixelRect? = nil) throws {
        try s.edit("fill") { doc, _ in
            let r = r ?? doc.bounds
            doc.withRaster(of: id) { $0.writeRegion(r, PixelCodec.fromRGBA($0.format, rgba: [SIMD4<Float>](repeating: c, count: r.area))) }
        }
    }

    /// 64 × 64 at `depth`: a red Background, "Hidden" (green all over, hidden), and a blue square
    /// (16..48) on "Blue". The Blue layer is active.
    func session(_ depth: Int) throws -> (Session, LayerId, LayerId, LayerId) {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 64, "depth": .int(depth), "background": "#ff0000"])
        let bg = try #require(s.active?.doc.layers.first?.id)
        try s.execute("layer.new.layer", ["name": "Hidden"])
        let hidden = try #require(s.active?.activeLayer)
        try fill(s, hidden, SIMD4(0, 1, 0, 1))
        try s.execute("layer.setProps", ["layer": .id(hidden), "visible": false])
        try s.execute("layer.new.layer", ["name": "Blue"])
        let blue = try #require(s.active?.activeLayer)
        try fill(s, blue, SIMD4(0, 0, 1, 1), PixelRect(x0: 16, y0: 16, x1: 48, y1: 48))
        return (s, bg, hidden, blue)
    }

    func rgba(_ s: Session, _ id: LayerId, _ x: Int32, _ y: Int32) -> SIMD4<Float> { s.active?.doc.layer(id)?.surface?.rgba(x: x, y: y) ?? SIMD4(-1, -1, -1, -1) }
    func ids(_ s: Session) -> [LayerId] { s.active?.doc.walk().map(\.layer.id) ?? [] }
    func close(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool { (0..<4).allSatisfy { abs(a[$0] - b[$0]) < 1e-3 } }

    @Test func stampVisibleAddsTheCompositeAboveTheActiveLayer() throws {
        for depth in [8, 16, 32] {
            let (s, bg, hidden, blue) = try session(depth)
            let before = ids(s)
            let id = LayerId(try #require(try s.execute("layer.stampVisible", [:])["layer"]?.uint64Value))
            // The originals stay; the stamp sits right above the active layer and is selected.
            #expect(ids(s) == [bg, hidden, blue, id], "\(depth)-bit")
            let st = try #require(s.active)
            #expect(st.activeLayer == id)
            #expect(st.selectedLayerIds == [id])
            let l = try #require(st.doc.layer(id))
            #expect(l.visible && l.rasterSurface != nil)
            #expect(l.name.hasPrefix("Layer "), "\(l.name)")
            #expect(l.surface?.format.alpha == true)
            // The visible composite: blue square on red; the hidden green layer is left out.
            #expect(close(rgba(s, id, 30, 30), SIMD4(0, 0, 1, 1)), "\(depth): \(rgba(s, id, 30, 30))")
            #expect(close(rgba(s, id, 2, 2), SIMD4(1, 0, 0, 1)))
            #expect(close(rgba(s, blue, 2, 2), SIMD4(0, 0, 0, 0)), "Blue is untouched")
            // One undo step.
            s.undo()
            #expect(ids(s) == before)
        }
    }

    @Test func stampVisibleRespectsOpacityBlendAndGroups() throws {
        let (s, bg, _, blue) = try session(8)
        try s.execute("layer.setProps", ["layer": .id(blue), "opacity": 0.5])
        try s.execute("layer.groupLayers", ["name": "G"])
        // The active layer is in a group: the stamp goes into the group, above it.
        try s.execute("layer.select", ["layer": .id(blue)])
        let id = LayerId(try #require(try s.execute("layer.stampVisible", [:])["layer"]?.uint64Value))
        let doc = try #require(s.active?.doc)
        let path = try #require(doc.path(of: id))
        #expect(path.count == 2, "inside the group")
        #expect(doc.path(of: blue)?.last.map { $0 + 1 } == path.last)
        let p = rgba(s, id, 30, 30)
        #expect(abs(p.x - 0.5) < 0.02 && abs(p.z - 0.5) < 0.02 && p.w > 0.99, "50 % blue over red: \(p)")
        #expect(doc.layer(bg) != nil)
    }

    @Test func stampVisibleFailsGracefully() throws {
        let s = Session()
        #expect(throws: EngineError.self, "no document") { try s.execute("layer.stampVisible", [:]) }
        try s.execute("file.new", ["width": 8, "height": 8])
        let bg = try #require(s.active?.doc.layers.first?.id)
        try s.execute("layer.setProps", ["layer": .id(bg), "visible": false])
        let rev = s.active?.revision
        #expect(throws: EngineError.self, "nothing visible") { try s.execute("layer.stampVisible", [:]) }
        #expect(s.active?.revision == rev, "no change")
        try s.execute("layer.setProps", ["layer": .id(bg), "visible": true])
        for bad: JSONValue in [[1, 2], "x", 3] {
            #expect(throws: EngineError.self, "\(bad)") { try s.execute("layer.stampVisible", bad) }
            #expect(throws: EngineError.self, "\(bad)") { try s.execute("layer.stampDown", bad) }
        }
        try s.execute("layer.stampVisible", .null)
    }

    @Test func stampDownMergesACopyIntoTheLayerBelow() throws {
        let (s, bg, hidden, blue) = try session(16)
        try s.execute("layer.setProps", ["layer": .id(hidden), "visible": true])
        try s.execute("layer.stampDown", [:])
        #expect(ids(s) == [bg, hidden, blue], "no layer added or removed")
        #expect(close(rgba(s, hidden, 30, 30), SIMD4(0, 0, 1, 1)), "the blue square was stamped into Hidden")
        #expect(close(rgba(s, hidden, 2, 2), SIMD4(0, 1, 0, 1)))
        #expect(close(rgba(s, blue, 30, 30), SIMD4(0, 0, 1, 1)), "Blue stays")
        #expect(s.active?.activeLayer == blue)
        s.undo()
        #expect(close(rgba(s, hidden, 30, 30), SIMD4(0, 1, 0, 1)))
    }

    @Test func stampDownRefusesWhatItCannotDo() throws {
        let (s, bg, hidden, blue) = try session(8)
        let rev = try #require(s.active?.revision)
        // The bottom layer has nothing below.
        try s.execute("layer.select", ["layer": .id(bg)])
        #expect(throws: EngineError.self) { try s.execute("layer.stampDown", [:]) }
        // A locked layer below.
        try s.execute("layer.select", ["layer": .id(blue)])
        try s.execute("layer.setProps", ["layer": .id(hidden), "locks": ["pixels": true]])
        #expect(throws: EngineError.self) { try s.execute("layer.stampDown", [:]) }
        try s.execute("layer.setProps", ["layer": .id(hidden), "locks": ["pixels": false]])
        // A hidden active layer.
        try s.execute("layer.setProps", ["layer": .id(blue), "visible": false])
        #expect(throws: EngineError.self) { try s.execute("layer.stampDown", [:]) }
        try s.execute("layer.setProps", ["layer": .id(blue), "visible": true])
        // A fill layer below is not a pixel layer.
        try s.execute("layer.select", ["layer": .id(hidden)])
        try s.execute("layer.newFillLayer.solidColor", ["color": "#ffffff"])
        try s.execute("layer.select", ["layer": .id(blue)])
        #expect(throws: EngineError.self) { try s.execute("layer.stampDown", [:]) }
        #expect((s.active?.revision ?? 0) > rev)
        let empty = Session()
        #expect(throws: EngineError.self, "no document") { try empty.execute("layer.stampDown", [:]) }
    }

    @Test func stampWithSeveralLayersSelectedMakesANewLayer() throws {
        let (s, bg, hidden, blue) = try session(8)
        try s.execute("layer.setProps", ["layer": .id(hidden), "visible": true])
        try s.execute("layer.select", ["layer": .id(hidden)])
        try s.execute("layer.select", ["layer": .id(blue), "mode": "add"])
        let id = LayerId(try #require(try s.execute("layer.stampDown", [:])["layer"]?.uint64Value))
        #expect(ids(s) == [bg, hidden, blue, id])
        #expect(close(rgba(s, id, 30, 30), SIMD4(0, 0, 1, 1)))
        #expect(close(rgba(s, id, 2, 2), SIMD4(0, 1, 0, 1)), "only the selected layers, not the red Background")
        #expect(s.active?.doc.layer(id)?.name == "Blue (merged)")
    }

    @Test func shortcutsArePhotoshopsAndRebindable() throws {
        let s = Session()
        #expect(s.registry.spec("layer.stampVisible")?.shortcut == "Cmd+Alt+Shift+E")
        #expect(s.registry.spec("layer.stampDown")?.shortcut == "Cmd+Alt+E")
        #expect(StampCommands.altVariant("layer.mergeVisible") == "layer.stampVisible")
        #expect(StampCommands.altVariant("layer.mergeDown") == "layer.stampDown")
        #expect(StampCommands.altVariant("layer.flattenImage") == nil)
    }
}
