// Port of photocraft-engine (crates/engine/src/pick_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct PickTests {
    typealias K = PaintTestKit

    func pick(_ s: Session, _ x: Double, _ y: Double, _ extra: JSONValue = [:]) throws -> JSONValue {
        try s.execute("layer.pickAt", JSONValue.object(["x": .number(x), "y": .number(y)]).merging(extra))["layer"] ?? .null
    }

    func newFilledLayer(_ s: Session, _ name: String, _ r: PixelRect, _ c: SIMD4<Float>) throws -> LayerId {
        try s.execute("layer.new.layer", ["name": .string(name)])
        try K.fill(s, c, r)
        return try #require(s.active?.activeLayer)
    }

    @Test func picksTopmostLayerWithPixels() throws {
        let s = try K.session(40, 40, background: "white")
        let bg = try #require(s.active?.doc.layers.first?.id)
        let a = try newFilledLayer(s, "A", PixelRect(x: 0, y: 0, width: 10, height: 10), SIMD4(1, 0, 0, 1))
        try s.execute("layer.new.layer", ["name": "B"])
        // Empty B is skipped; A wins inside its square, the Background elsewhere.
        #expect(try pick(s, 5, 5) == .id(a))
        #expect(s.active?.activeLayer == a)
        #expect(try pick(s, 30, 30, ["select": false]) == .id(bg))
        let list = try s.execute("layer.pickAt", ["x": 5, "y": 5, "list": true])
        #expect(list["layers"]?.arrayValue?.count == 2)
        // Hidden layers are ignored.
        try s.execute("layer.setProps", ["layer": .id(a), "visible": false])
        #expect(try pick(s, 5, 5, ["select": false]) == .id(bg))
    }

    /// Two filled squares: A at (0..10), B at (20..30), both in their own layers.
    func twoSquares() throws -> (Session, LayerId, LayerId) {
        let s = try K.session(40, 40, background: "white")
        let a = try newFilledLayer(s, "A", PixelRect(x: 0, y: 0, width: 10, height: 10), SIMD4(0, 1, 0, 1))
        let b = try newFilledLayer(s, "B", PixelRect(x: 20, y: 20, width: 10, height: 10), SIMD4(0, 1, 0, 1))
        return (s, a, b)
    }

    @Test func groupTargetSelectsTheOutermostGroup() throws {
        let (s, a, _) = try twoSquares()
        try s.execute("layer.select", ["layer": .id(a)])
        let inner = try #require(try s.execute("layer.new.groupFromLayers", ["name": "Inner"])["layer"]?.uint64Value)
        let outer = try #require(try s.execute("layer.new.groupFromLayers", ["name": "Outer"])["layer"]?.uint64Value)
        #expect(inner != outer)
        #expect(try pick(s, 5, 5, ["target": "group"]) == .id(LayerId(outer)))
        #expect(s.active?.activeLayer == LayerId(outer))
        // Layer mode reaches through the groups to the pixels.
        #expect(try pick(s, 5, 5, ["target": "layer"]) == .id(a))
        // Hiding the outer group hides its layers from the pick.
        try s.execute("layer.setProps", ["layer": .id(LayerId(outer)), "visible": false])
        let bg = try #require(s.active?.doc.layers.first?.id)
        #expect(try pick(s, 5, 5, ["select": false]) == .id(bg))
    }

    @Test func aClickOnASelectedLayerKeepsTheMultiSelection() throws {
        let (s, a, b) = try twoSquares()
        try s.execute("layer.select", ["layer": .id(a)])
        try s.execute("layer.select", ["layer": .id(b), "mode": "add"])
        #expect(s.active?.selectedLayers.count == 2)
        // Clicking A (selected) keeps both so the drag moves both.
        _ = try pick(s, 5, 5)
        #expect(s.active?.isLayerSelected(a) == true && s.active?.isLayerSelected(b) == true)
        // Clicking the Background (not selected) replaces the selection.
        _ = try pick(s, 35, 5)
        #expect(s.active?.selectedLayers.count == 1)
        #expect(s.active?.isLayerSelected(a) == false)
        // Shift-click (add) builds a selection up again.
        _ = try pick(s, 5, 5)
        _ = try pick(s, 25, 25, ["mode": "add"])
        #expect(s.active?.isLayerSelected(a) == true && s.active?.isLayerSelected(b) == true)
    }

    @Test func aClickOnAnArtboardPicksTheBoardOrTheLayersOnIt() throws {
        // #1531: an empty spot on a board picked the Background under it.
        let s = try K.session(40, 40, background: "white")
        let bg = try #require(s.active?.doc.layers.first?.id)
        let a = try newFilledLayer(s, "A", PixelRect(x: 0, y: 0, width: 10, height: 10), SIMD4(1, 0, 0, 1))
        // An artboard (30×30) holding A (the artboard commands belong to another module).
        var board: LayerId?
        try s.edit("Artboard") { doc, active in
            guard let i = doc.layers.firstIndex(where: { $0.id == a }) else { return }
            let l = doc.layers.remove(at: i)
            var g = Layer.group("Artboard 1", [l])
            g.artboard = Artboard(rect: PixelRect(x: 0, y: 0, width: 30, height: 30))
            board = g.id
            doc.layers.insert(g, at: i)
            active = g.id
        }
        let boardId = try #require(board)
        // A's pixels past the board's edge are clipped away, so they can't be picked either.
        try s.edit("paint outside") { doc, _ in _ = doc.withRaster(of: a) { $0.fill(PixelRect(x0: 32, y0: 32, x1: 36, y1: 36), with: [1, 0, 0, 1]) } }
        #expect(try pick(s, 5, 5, ["target": "layer"]) == .id(a), "the layer on the board")
        #expect(try pick(s, 5, 5, ["target": "group"]) == .id(a), "Group mode stops inside the board")
        #expect(try pick(s, 20, 20, ["target": "layer"]) == .id(boardId), "an empty spot on the board picks the board")
        #expect(s.active?.activeLayer == boardId)
        #expect(try pick(s, 33, 33, ["target": "layer"]) == .id(bg), "off the board: the Background, not A's clipped pixels")
        let list = try s.execute("layer.pickAt", ["x": 5, "y": 5, "list": true])
        let ids = list["layers"]?.arrayValue?.compactMap { $0["layer"]?.uint64Value } ?? []
        #expect(ids == [a.rawValue, boardId.rawValue, bg.rawValue])
        // A hidden board is skipped with its layers.
        try s.execute("layer.setProps", ["layer": .id(boardId), "visible": false])
        #expect(try pick(s, 5, 5, ["target": "layer"]) == .id(bg))
    }

    @Test func aFullyLockedLayerIsClickedThrough() throws {
        // #1641: a locked layer on top was picked, so the drag couldn't reach the layer under it.
        let (s, a, _) = try twoSquares()
        let top = try newFilledLayer(s, "Top", PixelRect(x: 0, y: 0, width: 10, height: 10), SIMD4(0, 0, 1, 1))
        func lock(_ id: LayerId, _ locks: JSONValue) throws { try s.execute("layer.setProps", ["layer": .id(id), "locks": locks]) }
        #expect(try pick(s, 5, 5) == .id(top))
        // A position lock alone doesn't hide it from Auto-Select.
        try lock(top, ["position": true])
        #expect(try pick(s, 5, 5) == .id(top))
        try lock(top, ["all": true])
        #expect(try pick(s, 5, 5) == .id(a))
        #expect(s.active?.activeLayer == a)
        // The right-click layer list still names it.
        let list = try s.execute("layer.pickAt", ["x": 5, "y": 5, "list": true])
        #expect(list["layers"]?[0]?["layer"] == .id(top))
        // A locked group locks the layers inside it.
        try lock(top, ["all": false, "position": false])
        try s.execute("layer.select", ["layer": .id(top)])
        let g = try #require(try s.execute("layer.new.groupFromLayers", ["name": "G"])["layer"]?.uint64Value)
        #expect(try pick(s, 5, 5) == .id(top))
        try lock(LayerId(g), ["all": true])
        #expect(try pick(s, 5, 5) == .id(a))
        // Nothing unlocked under the point: no pick.
        try lock(a, ["all": true])
        let bg = try #require(s.active?.doc.layers.first?.id)
        #expect(try pick(s, 5, 5) == .id(bg))
        try lock(bg, ["all": true])
        #expect(try pick(s, 5, 5) == .null)
    }

    @Test func autoSelectHitsATypeLayerBetweenItsLetters() throws {
        // #2370: a click in the gap between two glyphs picked the layer under the type.
        let s = try K.session(40, 40, background: "white")
        let bg = try #require(s.active?.doc.layers.first?.id)
        var text: LayerId?
        try s.edit("type") { doc, _ in
            // Two "glyphs", (10..14)×(10..20) and (20..24)×(10..20), with a gap between them.
            var cache = Surface(format: doc.pixelFormat)
            for x: Int32 in [10, 20] { cache.fill(PixelRect(x0: x, y0: 10, x1: x + 4, y1: 20), with: [0, 0, 0, 1]) }
            var t = TextLayer()
            t.cache = cache
            let l = Layer(name: "T", content: .text(t))
            text = l.id
            doc.layers.append(l)
        }
        let t = try #require(text)
        #expect(try pick(s, 12, 15, ["select": false]) == .id(t), "on a glyph")
        #expect(try pick(s, 17, 15, ["select": false]) == .id(t), "between the glyphs: the type layer, not the one under it")
        #expect(try pick(s, 17, 20, ["select": false]) == .id(bg), "below the text bounds")
        // The right-click list still names only the layers with pixels under the pointer.
        let list = try s.execute("layer.pickAt", ["x": 17, "y": 15, "list": true])
        #expect(list["layers"]?.arrayValue?.count == 1)
    }

    @Test func aMarqueeSelectsTheLayersItTouches() throws {
        let (s, a, b) = try twoSquares()
        try s.execute("layer.new.layer", ["name": "Empty"])
        func sel(_ r: [Double], _ target: String, _ mode: String) throws -> ([UInt64], [UInt64]) {
            let p: JSONValue = ["x": .number(r[0]), "y": .number(r[1]), "width": .number(r[2]), "height": .number(r[3]), "target": .string(target), "mode": .string(mode)]
            let hit = try s.execute("layer.selectInRect", p)["layers"]?.arrayValue?.compactMap(\.uint64Value) ?? []
            let now = (s.active?.selectedLayers ?? []).map(\.rawValue).sorted()
            return (hit, now)
        }
        // Touching A's corner only (dragged up and left); never the empty layer or the Background.
        var r = try sel([-5, -5, 6, 6], "layer", "replace")
        #expect(r.0 == [a.rawValue] && r.1 == [a.rawValue])
        r = try sel([50, 50, -27, -27], "layer", "replace")
        #expect(r.0 == [b.rawValue] && r.1 == [b.rawValue])
        // ⇧ adds; a box over nothing leaves the selection alone.
        r = try sel([0, 0, 5, 5], "layer", "add")
        #expect(r.0 == [a.rawValue] && r.1 == [a.rawValue, b.rawValue].sorted())
        r = try sel([11, 11, 8, 8], "layer", "replace")
        #expect(r.0 == [] && r.1 == [a.rawValue, b.rawValue].sorted())
        r = try sel([-10, -10, 60, 60], "layer", "replace")
        #expect(r.0 == [b.rawValue, a.rawValue] && r.1 == [a.rawValue, b.rawValue].sorted())
        // Group mode selects the outermost group; a hidden or fully locked layer is skipped.
        try s.execute("layer.select", ["layer": .id(a)])
        let g = try #require(try s.execute("layer.new.groupFromLayers", ["name": "G"])["layer"]?.uint64Value)
        #expect(try sel([0, 0, 40, 40], "group", "replace").0 == [b.rawValue, g])
        try s.execute("layer.setProps", ["layer": .id(b), "locks": ["all": true]])
        try s.execute("layer.setProps", ["layer": .id(LayerId(g)), "visible": false])
        #expect(try sel([0, 0, 40, 40], "layer", "replace").0 == [])
        for bad: JSONValue in [[:], ["x": 0, "y": 0, "width": .number(.nan), "height": 1], ["x": 0, "y": 0, "width": 1, "height": 1, "mode": "x"]] {
            #expect(throws: EngineError.self, "\(bad)") { try s.execute("layer.selectInRect", bad) }
        }
        try s.execute("layer.selectInRect", ["x": -1e300, "y": 1e300, "width": 1e308, "height": -1e308])
    }

    @Test func hostileParamsAreErrorsOrMissesNotPanics() throws {
        let (s, _, _) = try twoSquares()
        #expect(throws: EngineError.self) { try s.execute("layer.pickAt", [:]) }
        #expect(throws: EngineError.self) { try s.execute("layer.pickAt", ["x": "5", "y": 5]) }
        for (x, y) in [(-1e12, 5.0), (1e12, 1e12), (-0.5, -0.5), (40, 40)] {
            #expect(try pick(s, x, y) == .null, "(\(x), \(y))")
        }
        #expect(throws: EngineError.self) { try Session().execute("layer.pickAt", ["x": 1, "y": 1]) }
    }
}
