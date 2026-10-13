// Port of photocraft-engine (crates/engine/src/eraser_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct EraserTests {
    typealias K = PaintTestKit
    static let modes = ["rgb", "cmyk", "gray"]
    static let depths = [8, 16, 32]
    let black = SIMD4<Float>(0, 0, 0, 1)

    /// White document with a black 20×20 square at (10, 10) on its Background layer.
    func session(_ mode: String, _ depth: Int) throws -> Session {
        let s = try K.session(64, 48, background: "white", depth: depth, mode: mode)
        try K.fill(s, black, PixelRect(x: 10, y: 10, width: 20, height: 20))
        return s
    }

    func layer(_ s: Session) -> Layer? { s.active.flatMap { d in d.activeLayer.flatMap { d.doc.layer($0) } } }
    func alpha(_ s: Session, _ x: Int32, _ y: Int32) -> Float { K.rgba(s, x, y).w }
    func historyLen(_ s: Session) -> Int { s.active?.history.pastCount ?? -1 }

    @Test func magicEraserTurnsTheBackgroundIntoALayerAtEveryDepthAndMode() throws {
        for mode in Self.modes {
            for depth in Self.depths {
                let s = try session(mode, depth)
                let before = K.surface(s)
                let h = historyLen(s)
                let r = try s.execute("paint.magicEraser", ["x": 2, "y": 2, "antiAlias": false])
                #expect(r["erased"] == true)
                #expect(historyLen(s) == h + 1, "one undo step \(mode) \(depth)")
                let l = try #require(layer(s))
                #expect(l.name == "Layer 0", "\(mode) \(depth)")
                #expect(!l.locks.transparency && !l.locks.position)
                #expect(alpha(s, 2, 2) == 0, "white erased \(mode) \(depth)")
                #expect(alpha(s, 60, 40) == 0, "contiguous white erased \(mode) \(depth)")
                #expect(alpha(s, 20, 20) == 1, "black square kept \(mode) \(depth)")
                // The square's colour is untouched in the document's own channels.
                #expect(K.surface(s).pixel(x: 20, y: 20) == before.pixel(x: 20, y: 20))
                try s.execute("edit.undo")
                #expect(layer(s)?.name == "Background")
                #expect(K.surface(s) == before)
            }
        }
    }

    @Test func magicEraserOptions() throws {
        // Non-contiguous: a second, separate black square goes too.
        let a = try session("rgb", 8)
        try K.fill(a, black, PixelRect(x: 40, y: 10, width: 10, height: 10))
        try a.execute("paint.magicEraser", ["x": 20, "y": 20, "contiguous": true, "antiAlias": false])
        #expect(alpha(a, 20, 20) == 0)
        #expect(alpha(a, 45, 15) == 1, "contiguous keeps the other square")
        try a.execute("edit.undo")
        try a.execute("paint.magicEraser", ["x": 20, "y": 20, "contiguous": false, "antiAlias": false])
        #expect(alpha(a, 45, 15) == 0, "non-contiguous erases every match")
        #expect(alpha(a, 2, 2) == 1)

        // Opacity 50: half erased.
        let s = try session("rgb", 16)
        try s.execute("paint.magicEraser", ["x": 2, "y": 2, "opacity": 50, "antiAlias": false])
        #expect(abs(alpha(s, 2, 2) - 0.5) < 0.01)

        // Tolerance: a near-white grey is erased only within tolerance.
        for (tol, gone) in [(0.0, false), (40.0, true)] {
            let s = try session("rgb", 8)
            try K.fill(s, SIMD4(Float(0xe6) / 255, Float(0xe6) / 255, Float(0xe6) / 255, 1), PixelRect(x: 0, y: 40, width: 64, height: 8))
            try s.execute("paint.magicEraser", ["x": 2, "y": 2, "tolerance": .number(tol), "antiAlias": false])
            #expect((alpha(s, 5, 44) == 0) == gone, "tolerance \(tol)")
        }

        // The selection limits the erased area.
        let t = try session("rgb", 8)
        try t.execute("select.rect", ["x": 0, "y": 0, "width": 32, "height": 48, "antiAlias": false])
        try t.execute("paint.magicEraser", ["x": 2, "y": 2, "antiAlias": false])
        #expect(alpha(t, 2, 2) == 0)
        #expect(alpha(t, 50, 2) == 1, "outside the selection kept")
    }

    @Test func magicEraserSamplesAllLayersAndPaintsBackgroundUnderATransparencyLock() throws {
        // A half-opaque red band over the Background: the composite band is split by the black
        // square, the layer's own band isn't.
        func band(_ s: Session) throws {
            try s.execute("layer.new.layer")
            try K.fill(s, SIMD4(1, 0, 0, 1), PixelRect(x: 0, y: 14, width: 64, height: 4))
            let id = try #require(s.active?.activeLayer)
            try s.edit("opacity") { doc, _ in _ = doc.updateLayer(id) { $0.opacity = 0.5 } }
        }
        let s = try session("rgb", 8)
        try band(s)
        try s.execute("paint.magicEraser", ["x": 2, "y": 15, "tolerance": 0, "sampleAllLayers": true, "antiAlias": false])
        #expect(alpha(s, 2, 15) == 0)
        #expect(alpha(s, 50, 15) == 1, "the composite band is split by the black square")
        let t = try session("rgb", 8)
        try band(t)
        try t.execute("paint.magicEraser", ["x": 2, "y": 15, "tolerance": 0, "antiAlias": false])
        #expect(alpha(t, 50, 15) == 0, "the layer's own band is one region")

        // A normal layer with locked transparency gets the background colour instead.
        let u = try session("rgb", 8)
        try u.execute("layer.new.layer")
        try K.fill(u, SIMD4(1, 0, 0, 1))
        try u.execute("tools.setColors", ["background": "#00ff00"])
        let id = try #require(u.active?.activeLayer)
        try u.edit("lock") { doc, _ in _ = doc.updateLayer(id) { $0.locks.transparency = true } }
        try u.execute("paint.magicEraser", ["x": 2, "y": 2, "antiAlias": false])
        #expect(K.rgba(u, 2, 2) == SIMD4(0, 1, 0, 1))
    }

    @Test func magicEraserFailsGracefully() throws {
        let s = try session("rgb", 8)
        for p: JSONValue in [[:], ["x": 1], ["x": "a", "y": 1], ["x": 1, "y": 1, "tolerance": "high"], ["x": 1e300, "y": 1]] {
            #expect(throws: EngineError.self, "\(p)") { try s.execute("paint.magicEraser", p) }
        }
        // Off the canvas: nothing erased, no history step.
        let h = historyLen(s)
        let r = try s.execute("paint.magicEraser", ["x": -5, "y": 400])
        #expect(r["erased"] == false)
        #expect(historyLen(s) == h)
        // Out-of-range numbers clamp.
        try s.execute("paint.magicEraser", ["x": 2, "y": 2, "tolerance": 9999, "opacity": -3])
        // Locked pixels and non-pixel layers are refused.
        let id = try #require(s.active?.activeLayer)
        try s.edit("lock") { doc, _ in _ = doc.updateLayer(id) { $0.locks.pixels = true } }
        #expect(throws: EngineError.self) { try s.execute("paint.magicEraser", ["x": 2, "y": 2]) }
        #expect(throws: EngineError.self, "no document") { try Session().execute("paint.magicEraser", ["x": 2, "y": 2]) }
    }

    @Test func backgroundEraserErasesTheSampledColourAtEveryDepthAndMode() throws {
        for mode in Self.modes {
            for depth in Self.depths {
                let s = try session(mode, depth)
                let h = historyLen(s)
                // Start on white, drag across the black square: only white goes.
                try s.execute("paint.backgroundEraser", ["points": [[4, 20], [40, 20]], "size": 16, "hardness": 1, "sampling": "once",
                                                         "limits": "discontiguous", "tolerance": 10])
                #expect(historyLen(s) == h + 1)
                #expect(layer(s)?.name == "Layer 0", "\(mode) \(depth)")
                #expect(alpha(s, 6, 20) == 0, "white under the brush erased \(mode) \(depth)")
                #expect(alpha(s, 20, 20) == 1, "black kept \(mode) \(depth)")
                #expect(alpha(s, 36, 20) == 0, "white past the square erased \(mode) \(depth)")
                #expect(alpha(s, 6, 40) == 1, "outside the brush kept \(mode) \(depth)")
            }
        }
    }

    @Test func backgroundEraserOptions() throws {
        // Continuous sampling erases the black square once the hotspot is over it.
        let s = try session("rgb", 8)
        try s.execute("paint.backgroundEraser", ["points": [[4, 20], [40, 20]], "size": 16, "hardness": 1, "sampling": "continuous",
                                                 "limits": "discontiguous", "tolerance": 10])
        #expect(alpha(s, 20, 20) == 0)
        // Protect Foreground Color (black) keeps the square even under continuous sampling.
        let t = try session("rgb", 8)
        try t.execute("tools.setColors", ["foreground": "#000000"])
        try t.execute("paint.backgroundEraser", ["points": [[4, 20], [40, 20]], "size": 16, "hardness": 1, "limits": "discontiguous", "tolerance": 10,
                                                 "protectForegroundColor": true])
        #expect(alpha(t, 20, 20) == 1)
        #expect(alpha(t, 6, 20) == 0)
        // Background swatch: with a black swatch only the square goes.
        let u = try session("rgb", 8)
        try u.execute("tools.setColors", ["background": "#000000"])
        try u.execute("paint.backgroundEraser", ["points": [[4, 20], [40, 20]], "size": 16, "hardness": 1, "sampling": "backgroundSwatch",
                                                 "limits": "discontiguous", "tolerance": 10])
        #expect(alpha(u, 20, 20) == 0)
        #expect(alpha(u, 6, 20) == 1)
    }

    @Test func backgroundEraserFailsGracefully() throws {
        let s = try session("rgb", 8)
        for p: JSONValue in [
            [:], ["points": []], ["points": "x"], ["points": [[1, 1]], "sampling": "sometimes"], ["points": [[1, 1]], "limits": 3],
            ["points": [[1, 1]], "tolerance": "lots"], ["points": [[1, 1]], "size": 1e9], ["points": [[1e300, 1]]],
        ] {
            #expect(throws: EngineError.self, "\(p)") { try s.execute("paint.backgroundEraser", p) }
        }
        // A normal layer with locked transparency is refused.
        try s.execute("layer.new.layer")
        let id = try #require(s.active?.activeLayer)
        try s.edit("lock") { doc, _ in _ = doc.updateLayer(id) { $0.locks.transparency = true } }
        #expect(throws: EngineError.self) { try s.execute("paint.backgroundEraser", ["points": [[4, 4]]]) }
    }
}
