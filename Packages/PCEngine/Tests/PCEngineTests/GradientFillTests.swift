// Port of photocraft-engine (crates/engine/src/gradient_fill_cmds/tests.rs; photocraft-compose gradient_fill.rs `handles_round_trip`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Skipped: `live_gradient_renders_like_the_classic_gradient` and `classic_gradient_still_paints_pixels`
// (they paint with `paint.gradient`, paint_cmds').

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCRender
import Testing

@Suite struct GradientFillTests {
    typealias T = StyleTestSupport
    typealias G = GradientFillCommands
    static let styles = ["linear", "radial", "angle", "reflected", "diamond"]

    func session(_ depth: Int = 8, _ background: String = "white") throws -> Session {
        try T.session(48, 32, extra: ["depth": .int(depth), "background": .string(background)])
    }

    func activeFill(_ s: Session) throws -> GradientFill {
        guard let d = s.active, let id = d.activeLayer, case .fill(.gradient(let g))? = d.doc.layer(id)?.content else {
            throw EngineError.other("not a gradient fill layer")
        }
        return g
    }

    func layerCount(_ s: Session) -> Int { s.active?.doc.layers.count ?? 0 }
    func pastCount(_ s: Session) -> Int { s.active?.history.pastCount ?? -1 }

    @Test func handlesRoundTrip() {
        let frame = PixelRect(x0: 10, y0: -4, x1: 210, y1: 96)
        for style in GradientStyle.allCases {
            for (from, to) in [(SIMD2<Float>(30, 40), SIMD2<Float>(180, 10)), (SIMD2(100, 50), SIMD2(100, 90)), (SIMD2(5, 5), SIMD2(-40, 70))] {
                let (a, sc, o) = G.fromHandles(style, from, to, frame, 0)
                let (f2, t2) = G.handles(style, a, sc, o, frame)
                for (p, q) in [(from, f2), (to, t2)] {
                    #expect(abs(p.x - q.x) < 1e-2 && abs(p.y - q.y) < 1e-2, "\(style): \(p) vs \(q)")
                }
            }
        }
    }

    @Test func createMakesACanvasAlignedFillLayerWithTheDragAsHandles() throws {
        let s = try session()
        let r = try s.execute(G.create, ["from": [14, 16], "to": [34, 8], "style": "radial", "stops": [[0, "#ff0000"], [1, "#0000ff"]], "opacity": 50,
                                         "mode": "multiply"])
        #expect(layerCount(s) == 2)
        let d = try #require(s.active)
        let lid = LayerId(try #require(r["layer"]?.uint64Value))
        let l = try #require(d.doc.layer(lid))
        #expect(d.activeLayer == l.id)
        #expect(l.mask == nil, "no selection, no mask")
        #expect(l.opacity == 0.5 && l.blend == .multiply)
        let g = try activeFill(s)
        #expect(g.style == .radial && !g.align && g.dither)
        let info = try s.execute(G.get)
        let vals = (info["from"]?.arrayValue ?? []) + (info["to"]?.arrayValue ?? [])
        for (v, want) in zip(vals, [14.0, 16, 34, 8]) { #expect(abs((v.doubleValue ?? 0) - want) < 1e-3, "\(info)") }
        // One undo step removes the layer.
        try s.execute("edit.undo")
        #expect(layerCount(s) == 1)
    }

    @Test func createMasksTheLayerWithTheSelection() throws {
        let s = try session()
        try s.execute("select.rect", ["x": 4, "y": 4, "width": 10, "height": 8])
        try s.execute(G.create, ["from": [0, 0], "to": [48, 0]])
        let d = try #require(s.active)
        let aid = try #require(d.activeLayer)
        let l = try #require(d.doc.layer(aid))
        let m = try #require(l.mask, "selection becomes the mask")
        #expect(m.value(x: 5, y: 5) == 1)
        #expect(m.value(x: 30, y: 20) == 0)
        // Still laid out on the canvas, not the mask's bounds.
        #expect(LayerGeometry.fillFrame(l, canvas: d.doc.bounds) == d.doc.bounds)
        // The composite outside the selection is the white background.
        #expect(try T.pixel(s, 30, 20) == [1, 1, 1, 1])
    }

    /// Issue #465: explicit `transparency` stops replace those of a preset or the current gradient.
    @Test func createHonoursExplicitTransparencyStops() throws {
        for extra: JSONValue in [["gradient": "Foreground to Transparent"], ["gradient": "black, white"], [:]] {
            let s = try session(8, "transparent")
            try s.execute(G.create, JSONValue.object(["from": [0, 0], "to": [48, 0], "transparency": [[1, 0], [0, 65]]]).merging(extra))
            #expect(try activeFill(s).opacityStops == [OpacityStop(0, 0.65), OpacityStop(1, 0)], "\(extra)")
        }
    }

    @Test func setMovesHandlesAndRestylesInOneUndoStep() throws {
        let s = try session()
        try s.execute(G.create, ["from": [4, 4], "to": [40, 4]])
        let before = try activeFill(s)
        let h0 = pastCount(s)
        var g = try s.execute(G.set, ["to": [20, 22]])
        #expect(abs((g["to"]?[0]?.doubleValue ?? 0) - 20) < 1e-3 && abs((g["from"]?[0]?.doubleValue ?? 0) - 4) < 1e-3, "\(g)")
        #expect(pastCount(s) == h0 + 1)
        // Changing the style alone keeps the handles where they are.
        g = try s.execute(G.set, ["style": "angle"])
        #expect(g["style"] == "angle")
        #expect(abs((g["to"]?[1]?.doubleValue ?? 0) - 22) < 1e-3, "\(g)")
        g = try s.execute(G.set, ["angle": 45, "scale": 80, "offset": [10, -5], "reverse": true, "dither": false, "midpoints": [0.3]])
        #expect(g["angle"] == 45.0)
        #expect(abs((g["scale"]?.doubleValue ?? 0) - 80) < 1e-3)
        #expect(g["reverse"] == true)
        // Each edit is one step: three undos restore the original.
        for _ in 0..<3 { try s.execute("edit.undo") }
        #expect(try activeFill(s) == before)
        // A no-op set adds no history.
        let h = pastCount(s)
        try s.execute(G.set)
        #expect(pastCount(s) == h)
    }

    @Test func lockedGradientFillRejectsContentEditsWithoutHistory() throws {
        let s = try session()
        try s.execute(G.create, ["from": [0, 0], "to": [16, 0], "stops": [[0, "#000000"], [1, "#ffffff"]], "dither": false])
        try s.execute("layer.lockLayers", ["all": true])
        let original = try activeFill(s)
        let locked = pastCount(s)
        let edits: [(String, JSONValue)] = [(G.set, ["reverse": true]), (G.stop, ["action": "color", "index": 0, "color": "#ff0000"])]
        for (command, params) in edits {
            do {
                try s.execute(command, params)
                Issue.record("\(command) should fail")
            } catch let e as EngineError {
                if case .other(let msg) = e { #expect(msg.contains("locked")) } else { Issue.record("\(command): \(e)") }
            }
            #expect(try activeFill(s) == original, "\(command) changed the fill")
            #expect(pastCount(s) == locked, "\(command) added history")
        }
        try s.execute("layer.lockLayers", ["all": false])
        for (command, params) in edits {
            let h = pastCount(s)
            try s.execute(command, params)
            #expect(pastCount(s) == h + 1, "\(command) records one step")
            try s.execute("edit.undo")
            #expect(try activeFill(s) == original, "undo restores the fill after \(command)")
            #expect(pastCount(s) == h)
        }
    }

    @Test func stopsAddMoveRecolourDeleteAndMidpoints() throws {
        let s = try session()
        try s.execute(G.create, ["from": [0, 0], "to": [48, 0], "stops": [[0, "#000000"], [1, "#ffffff"]], "dither": false])
        // Add: the new stop takes the colour the gradient has there.
        let g = try s.execute(G.stop, ["action": "add", "location": 0.5])
        #expect(g["stops"]?.arrayValue?.count == 3)
        #expect(abs(try activeFill(s).stops[1].color.c.x - 0.5) < 1e-3)
        try s.execute(G.stop, ["action": "color", "index": 1, "color": "#ff0000"])
        #expect(try activeFill(s).stops[1].color.rgb == SIMD3(1, 0, 0))
        try s.execute(G.stop, ["action": "midpoint", "index": 0, "location": 0.25])
        #expect(try activeFill(s).midpoints == [0.25, 0.5])
        // Moving a stop past another re-sorts them (the midpoint travels with its stop).
        try s.execute(G.stop, ["action": "move", "index": 0, "location": 0.75])
        #expect(try activeFill(s).stops.map(\.location) == [0.5, 0.75, 1])
        #expect(try activeFill(s).midpoints == [0.5, 0.25])
        try s.execute(G.stop, ["action": "delete", "index": 2])
        #expect(try activeFill(s).stops.count == 2)
        #expect(throws: EngineError.self, "keeps 2 stops") { try s.execute(G.stop, ["action": "delete", "index": 0]) }
        // Opacity stops start from an opaque pair.
        try s.execute(G.stop, ["action": "opacity", "kind": "opacity", "index": 1, "opacity": 25])
        #expect(try activeFill(s).opacityStops == [OpacityStop(0, 1), OpacityStop(1, 0.25)])
        try s.execute(G.stop, ["action": "add", "kind": "opacity", "location": 0.5])
        #expect(abs(try activeFill(s).opacityStops[1].opacity - 0.625) < 1e-4)
        // Each edit is one undo step.
        let n = pastCount(s)
        try s.execute("edit.undo")
        #expect(pastCount(s) + 1 == n)
        #expect(try activeFill(s).opacityStops.count == 2)
    }

    @Test func previewEqualsTheCommittedEdit() throws {
        let s = try session()
        try s.execute(G.create, ["from": [4, 4], "to": [40, 20], "style": "diamond"])
        let d = try #require(s.active)
        let aid = try #require(d.activeLayer)
        let l = try #require(d.doc.layer(aid))
        let f = try activeFill(s)
        let p: JSONValue = ["from": [10, 12], "to": [30, 2]]
        let preview = try G.applySet(l, f, d.doc.bounds, p, .zero, SIMD4(repeating: 1))
        try s.execute(G.set, p)
        #expect(try activeFill(s) == preview)
    }

    @Test func commandsFailGracefully() throws {
        let empty = Session()
        for id in [G.create, G.set, G.stop, G.get] {
            #expect(throws: EngineError.self, "\(id) without a document") { try empty.execute(id, ["from": [0, 0], "to": [1, 1]]) }
        }
        let s = try session()
        // Not a gradient fill layer.
        for id in [G.set, G.stop, G.get] { #expect(throws: EngineError.self, "\(id) on a pixel layer") { try s.execute(id) } }
        let badCreate: [JSONValue] = [
            [:], ["from": [0, 0]], ["from": [0], "to": [1, 1]], ["from": [.number(Double.greatestFiniteMagnitude), 0], "to": [1, 1]], ["from": ["a", 0], "to": [1, 1]],
            ["from": [0, 0], "to": [1, 1], "style": "spiral"], ["from": [0, 0], "to": [1, 1], "style": 3],
            ["from": [0, 0], "to": [1, 1], "gradient": "No Such Preset"], ["from": [0, 0], "to": [1, 1], "stops": []],
            ["from": [0, 0], "to": [1, 1], "mode": "nonsense"],
        ]
        for p in badCreate { #expect(throws: EngineError.self, "create \(p)") { try s.execute(G.create, p) } }
        // A zero-length drag still makes a valid gradient.
        try s.execute(G.create, ["from": [3, 3], "to": [3, 3]])
        let badSet: [JSONValue] = [
            ["layer": 999_999], ["from": [0]], ["to": [1e30, 0]], ["angle": "x"], ["scale": 0], ["scale": -5], ["offset": [1]], ["offset": ["a", "b"]],
            ["reverse": 1], ["stops": [[0, "#000000"]]], ["stops": [[0, "#zzzzzz"], [1, "#ffffff"]]], ["stops": [[0, [1, 2]], [1, "#ffffff"]]],
            ["stops": "x"], ["transparency": [[0]]], ["midpoints": [0.5, 0.5, 0.5]], ["midpoints": ["x"]], ["style": "spiral"], ["align": "no"],
        ]
        for p in badSet { #expect(throws: EngineError.self, "set \(p)") { try s.execute(G.set, p) } }
        let badStop: [JSONValue] = [
            [:], ["action": "explode"], ["action": "add"], ["action": "move", "index": 99, "location": 0.5], ["action": "delete", "index": 99],
            ["action": "color", "index": 0], ["action": "color", "index": 0, "color": 7], ["action": "midpoint", "index": 1, "location": 0.5],
            ["action": "midpoint", "index": 0], ["action": "add", "kind": "sparkle", "location": 0.5], ["action": "color", "kind": "opacity", "index": 0],
            ["action": "opacity", "kind": "opacity", "index": 7, "opacity": 3], ["action": "delete", "kind": "opacity", "index": 0],
            ["action": "move", "index": -1, "location": 0.5],
        ]
        for p in badStop { #expect(throws: EngineError.self, "stop \(p)") { try s.execute(G.stop, p) } }
        // Huge-but-finite values clamp instead of failing.
        try s.execute(G.set, ["scale": 1e30, "angle": 1e9, "offset": [1e4, -1e4]])
        var g = try s.execute(G.get)
        #expect((g["scale"]?.doubleValue ?? .nan).isFinite && (g["from"]?[0]?.doubleValue ?? .nan).isFinite)
        // Scale stays within Photoshop's 10–150 %, also for a handle dragged far away.
        #expect(abs((g["scale"]?.doubleValue ?? 0) - 150) < 1e-3, "\(g)")
        g = try s.execute(G.set, ["from": [0, 0], "to": [1e6, 0]])
        #expect(abs((g["scale"]?.doubleValue ?? 0) - 150) < 1e-3, "\(g)")
        g = try s.execute(G.set, ["scale": 1])
        #expect(abs((g["scale"]?.doubleValue ?? 0) - 10) < 1e-3, "\(g)")
    }

    /// Dragging one handle past the scale range stops it; the other handle stays put (#1243).
    @Test func aClampedHandleDragLeavesTheOtherHandleAlone() throws {
        func pt(_ g: JSONValue, _ k: String) -> SIMD2<Double> { SIMD2(g[k]?[0]?.doubleValue ?? .nan, g[k]?[1]?.doubleValue ?? .nan) }
        func close(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool { abs(a.x - b.x) < 1e-2 && abs(a.y - b.y) < 1e-2 }
        let cases: [(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)] = [
            (SIMD2(14, 16), SIMD2(34, 16), SIMD2(15, 16), SIMD2(33, 16)), (SIMD2(24, 6), SIMD2(24, 26), SIMD2(24, 7), SIMD2(24, 25)),
        ]
        func json(_ p: SIMD2<Double>) -> JSONValue { [.number(p.x), .number(p.y)] }
        for style in Self.styles {
            for (from, to, short, shortStart) in cases {
                var s = try session()
                try s.execute(G.create, ["from": json(from), "to": json(to), "style": .string(style)])
                // End dragged almost onto the start: far below 10 %.
                var g = try s.execute(G.set, ["to": json(short)])
                #expect(abs((g["scale"]?.doubleValue ?? 0) - 10) < 1e-3, "\(style): \(g)")
                #expect(close(pt(g, "from"), from), "\(style): start moved to \(pt(g, "from"))")
                // The end stops on the line towards the pointer.
                let e = pt(g, "to")
                #expect((e.x - from.x) * (short.x - from.x) >= 0 && (e.y - from.y) * (short.y - from.y) >= 0, "\(style): \(e)")
                // And the same for the start handle.
                s = try session()
                try s.execute(G.create, ["from": json(from), "to": json(to), "style": .string(style)])
                g = try s.execute(G.set, ["from": json(shortStart)])
                #expect(close(pt(g, "to"), to), "\(style): end moved: \(g)")
            }
        }
    }

    /// Issue #958: a stop or segment index far past the end is a bad-params error for every action
    /// and kind, and leaves the gradient and the history as they were.
    @Test func stopRejectsHugeIndicesWithoutPanicking() throws {
        let s = try session()
        try s.execute(G.create, ["from": [0, 0], "to": [8, 8], "stops": [[0, "#000000"], [1, "#ffffff"]]])
        let before = try activeFill(s)
        let h = pastCount(s)
        for index: Double in [Double(UInt64.max), Double(Int64.max), 4_294_967_296, 2] {
            let ps: [JSONValue] = [
                ["action": "midpoint", "index": .number(index), "location": 0.5], ["action": "move", "index": .number(index), "location": 0.5],
                ["action": "delete", "index": .number(index)], ["action": "color", "index": .number(index), "color": "#ff0000"],
                ["action": "move", "kind": "opacity", "index": .number(index), "location": 0.5], ["action": "delete", "kind": "opacity", "index": .number(index)],
                ["action": "opacity", "kind": "opacity", "index": .number(index), "opacity": 50],
            ]
            for p in ps {
                do {
                    try s.execute(G.stop, p)
                    Issue.record("\(p) should fail")
                } catch let e as EngineError {
                    if case .badParams = e {} else { Issue.record("\(p): \(e)") }
                }
                #expect(try activeFill(s) == before, "\(p) changed the gradient")
                #expect(pastCount(s) == h, "\(p) added a history step")
            }
        }
        // The last segment of a two-stop gradient is 0; segment 1 does not exist.
        #expect(throws: EngineError.bad(G.stop, "no segment 1 (there are 1)")) { try s.execute(G.stop, ["action": "midpoint", "index": 1, "location": 0.5]) }
        // Control: a valid midpoint edit still applies as one undo step.
        try s.execute(G.stop, ["action": "midpoint", "index": 0, "location": 0.25])
        #expect(try activeFill(s).midpoints == [0.25])
        #expect(pastCount(s) == h + 1)
    }
}
