// Port of photocraft-engine (crates/engine/src/frame_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct FrameTests {
    /// An 80×60 document with a red layer A over (4,4)…(24,24) and a blue layer B over
    /// (30,20)…(50,40).
    func session() throws -> (Session, LayerId, LayerId) {
        let s = Session()
        try s.execute("file.new", ["width": 80, "height": 60])
        let (a, b) = try s.edit("setup") { doc, _ -> (LayerId, LayerId) in
            let fmt = doc.pixelFormat
            var sa = Surface(format: fmt)
            sa.fill(PixelRect(x0: 4, y0: 4, x1: 24, y1: 24), with: fmt.components(fromRGBA: SIMD4(1, 0, 0, 1)))
            var sb = Surface(format: fmt)
            sb.fill(PixelRect(x0: 30, y0: 20, x1: 50, y1: 40), with: fmt.components(fromRGBA: SIMD4(0, 0, 1, 1)))
            let la = Layer.raster("A", surface: sa), lb = Layer.raster("B", surface: sb)
            doc.layers.append(la)
            doc.layers.append(lb)
            return (la.id, lb.id)
        }
        return (s, a, b)
    }

    func children(_ l: Layer?) -> [LayerId]? {
        guard case .group(let g)? = l?.content else { return nil }
        return g.children.map(\.id)
    }

    @Test func framesSelectedLayersIntoAMaskedGroup() throws {
        let (s, a, b) = try session()
        try s.execute("layer.select", ["layer": .id(a), "mode": "replace"])
        try s.execute("layer.select", ["layer": .id(b), "mode": "add"])
        let r = try s.execute("layer.new.frameFromLayers", ["name": "Frame 1"])
        let gid = LayerId(try #require(r["layer"]?.uint64Value))
        // frame rect = union of the two layers' bounds (4,4)…(50,40).
        let frame = try #require(r["frame"]?.arrayValue)
        #expect(frame[2] == .int(50 - 4), "width")
        #expect(frame[3] == .int(40 - 4), "height")
        let st = try #require(s.active)
        let g = try #require(st.doc.layer(gid))
        #expect(g.isGroup, "it's a group")
        #expect(g.mask != nil, "the group has a clip mask")
        // Undoable (last step is the frame).
        #expect(st.history.entries.last == "Frame from Layers")
    }

    @Test func frameFromLayersIsOneHistoryStep() throws {
        // #496: grouping and framing undo together.
        let (s, a, b) = try session()
        let entries = try #require(s.active?.history.entries)
        func layers() -> [LayerId] { s.active?.doc.layers.map(\.id) ?? [] }
        let before = layers()
        try s.execute("layer.select", ["layer": .id(a), "mode": "replace"])
        try s.execute("layer.select", ["layer": .id(b), "mode": "add"])
        let gid = LayerId(try #require(try s.execute("layer.new.frameFromLayers")["layer"]?.uint64Value))
        #expect(s.active?.history.entries == entries + ["Frame from Layers"])
        #expect(s.undo())
        #expect(s.active?.history.entries == entries)
        #expect(layers() == before, "one undo leaves no group behind")
        #expect(s.redo())
        #expect(s.active?.doc.layer(gid)?.mask != nil, "redo brings back the framed group")
    }

    /// Frame tool: a rectangular frame is an empty group clipped to the drawn rect, undone in one
    /// step; an elliptical one hides the corners; drawn over a pixel layer, it holds that layer.
    @Test func newFrameClipsAGroupToTheDrawnShape() throws {
        let (s, a, _) = try session()
        func count() -> Int { s.active?.doc.layers.count ?? -1 }
        let before = count()
        var r = try s.execute("layer.new.frame", ["x": 10, "y": 10, "width": 40, "height": 30])
        var gid = LayerId(try #require(r["layer"]?.uint64Value))
        let st = try #require(s.active)
        var g = try #require(st.doc.layer(gid))
        #expect(children(g) == [], "an empty frame")
        var m = try #require(g.mask)
        #expect([m.value(x: 10, y: 10), m.value(x: 49, y: 39), m.value(x: 9, y: 10), m.value(x: 50, y: 39)] == [1, 1, 0, 0])
        #expect(g.name == "Frame 1" && st.activeLayer == gid)
        #expect(r["frame"] == [10, 10, 40, 30] && r["shape"] == "rectangle")
        #expect(s.undo())
        #expect(count() == before, "one undo removes the frame")

        r = try s.execute("layer.new.frame", ["x": 10, "y": 10, "width": 40, "height": 30, "shape": "ellipse", "layer": .id(a)])
        gid = LayerId(try #require(r["layer"]?.uint64Value))
        g = try #require(s.active?.doc.layer(gid))
        #expect(children(g) == [a], "the frame holds layer A")
        m = try #require(g.mask)
        #expect(m.value(x: 30, y: 25) == 1 && m.value(x: 10, y: 10) == 0, "centre shown, corner hidden")
        #expect(r["shape"] == "ellipse")
        let bad: [JSONValue] = [["x": 0, "y": 0, "width": 0, "height": 5], ["x": 0, "y": 0, "width": 5, "height": 5, "shape": "star"], ["x": 0]]
        for p in bad {
            #expect(throws: EngineError.self, "\(p)") { try s.execute("layer.new.frame", p) }
        }
    }

    @Test func needsASelectedLayer() {
        let s = Session()
        #expect(throws: EngineError.self) { try s.execute("layer.new.frameFromLayers") }
    }
}
