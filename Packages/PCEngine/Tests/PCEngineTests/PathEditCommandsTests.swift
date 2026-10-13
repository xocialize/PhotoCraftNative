// Port of photocraft-engine (crates/engine/src/path_edit_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
@testable import PCEngine
import PCDocument
import PCFoundation
import Testing

fileprivate func session() throws -> Session {
    let s = Session()
    try s.execute("file.new", ["width": 120, "height": 100, "background": "white"])
    return s
}

fileprivate let square: JSONValue = ["subpaths": [["closed": true, "knots": [[10, 10], [60, 10], [60, 60], [10, 60]]]]]

fileprivate let curve: JSONValue = ["subpaths": [["closed": false, "knots": [
    ["anchor": [10, 80], "in": [10, 80], "out": [10, 20]],
    ["anchor": [60, 50], "in": [40, 20], "out": [80, 80], "smooth": true],
    ["anchor": [110, 80], "in": [110, 20], "out": [110, 80]],
]]]]

fileprivate func anchor(_ v: JSONValue, _ k: Int) -> [Double] {
    v["path"]?["subpaths"]?[0]?["knots"]?[k]?["anchor"]?.arrayValue?.compactMap(\.doubleValue) ?? []
}

fileprivate func work(_ s: Session) throws -> VectorPath { try #require(s.active?.doc.workPath) }

fileprivate func knots(_ s: Session) throws -> Int { try work(s).subpaths.reduce(0) { $0 + $1.knots.count } }

fileprivate func shapeOf(_ s: Session, _ id: UInt64) throws -> ShapeLayer {
    let l = try #require(s.active?.doc.layer(LayerId(id)))
    guard case .shape(let sh) = l.content else { throw EngineError.other("not a shape") }
    return sh
}

@Suite struct PathEditCommandsTests {
    @Test func anchorsMoveInOneUndoableStep() throws {
        let s = try session()
        try s.execute("path.set", ["path": square])
        let before = try work(s)
        let r = try s.execute("path.moveAnchors", ["anchors": [[0, 1], [0, 2]], "move": [5, -3]])
        #expect(anchor(r, 1) == [65, 7] && anchor(r, 2) == [65, 57] && anchor(r, 0) == [10, 10])
        #expect(s.active?.history.undoLabel == "Drag Anchor Points")
        #expect(s.undo())
        #expect(try work(s) == before)
    }

    @Test func aCoalescedDragIsOneHistoryStep() throws {
        let s = try session()
        try s.execute("path.set", ["path": square])
        let steps = try #require(s.active?.history.entries.count)
        for _ in 0..<3 { try s.execute("path.moveAnchors", ["anchors": [[0, 0]], "move": [1, 0], "coalesce": "drag-1"]) }
        #expect(s.active?.history.entries.count == steps + 1)
        #expect(try work(s).subpaths[0].knots[0].anchor.x == 13)
    }

    @Test func handlesSegmentsAndConvertPoint() throws {
        let s = try session()
        try s.execute("path.set", ["path": square])
        // Pull smooth handles out of the corner at (60, 10), then turn one: the other follows.
        try s.execute("path.convertPoint", ["subpath": 0, "knot": 1, "out": [70, 10]])
        var r = try s.execute("path.moveHandle", ["subpath": 0, "knot": 1, "handle": "out", "to": [60, 20]])
        var k = r["path"]?["subpaths"]?[0]?["knots"]?[1]
        #expect(k?["in"] == [60.0, 0.0] && k?["smooth"] == true)
        r = try s.execute("path.moveHandle", ["subpath": 0, "knot": 1, "handle": "in", "to": [50, 0], "independent": true])
        k = r["path"]?["subpaths"]?[0]?["knots"]?[1]
        #expect(k?["out"] == [60.0, 20.0] && k?["smooth"] == false)
        // The straight bottom edge (2 → 3) drags with its anchors.
        r = try s.execute("path.bendSegment", ["subpath": 0, "knot": 2, "move": [0, 8]])
        #expect(anchor(r, 2) == [60, 68] && anchor(r, 3) == [10, 68])
        r = try s.execute("path.convertPoint", ["subpath": 0, "knot": 1])
        #expect(r["path"]?["subpaths"]?[0]?["knots"]?[1]?["out"] == [60.0, 10.0])
    }

    @Test func shapePathsAndVectorMasksAreEditedAndRerendered() throws {
        for depth in [8, 16, 32] {
            let s = Session()
            try s.execute("file.new", ["width": 120, "height": 100, "depth": .int(depth)])
            let id = try #require(try s.execute("shape.create", ["kind": "rect", "rect": [10, 10, 40, 40], "fill": "#ff0000"])["layer"]?.uint64Value)
            let r = try s.execute("path.moveAnchors", ["name": "layer", "layer": .int(id), "anchors": [[0, 1], [0, 2]], "move": [30, 0]])
            #expect(anchor(r, 1) == [80, 10])
            let sh = try shapeOf(s, id)
            #expect(sh.live == nil, "an edited rectangle is a plain path now")
            #expect(sh.cache?.contentBounds.x1 == 80, "depth \(depth): re-rendered")
        }
        let s = try session()
        let id = try #require(s.active?.activeLayer)
        try s.execute("layer.vectorMask.add", ["layer": .id(id), "path": square])
        try s.execute("path.moveAnchors", ["name": "layer", "layer": .id(id), "anchors": [[0, 0]], "move": [-5, -5]])
        let vm = try #require(s.active?.doc.layer(id)?.vectorMask)
        #expect(vm.path.subpaths[0].knots[0].anchor == PCPoint(5, 5))
    }

    @Test func anchorsAreAddedAndDeletedInOneUndoableStepEach() throws {
        let s = try session()
        try s.execute("path.set", ["path": curve])
        let before = try work(s)
        let steps = try #require(s.active?.history.entries.count)
        var r = try s.execute("path.addAnchor", ["subpath": 0, "knot": 0, "t": 0.5])
        #expect(r["anchor"] == ["subpath": 0, "knot": 1])
        #expect(try knots(s) == 4 && s.active?.history.entries.count == steps + 1)
        #expect(s.active?.history.undoLabel == "Add Anchor Point")
        #expect(try work(s).subpaths[0].knots[1].smooth)
        let added = try work(s)
        #expect(s.undo())
        #expect(try work(s) == before, "one undo restores the path exactly")
        #expect(s.redo())
        #expect(try work(s) == added)
        r = try s.execute("path.deleteAnchor", ["subpath": 0, "knot": 1])
        #expect(r["subpathRemoved"] == false)
        #expect(s.active?.history.undoLabel == "Delete Anchor Point")
        #expect(try knots(s) == 3)
        // Deleting the middle anchor of the original curve joins the ends with their own handles.
        try s.execute("path.set", ["path": curve])
        try s.execute("path.deleteAnchor", ["subpath": 0, "knot": 1])
        let k = try work(s).subpaths[0].knots
        #expect(k.count == 2 && k[0].outCtrl == before.subpaths[0].knots[0].outCtrl && k[1].inCtrl == before.subpaths[0].knots[2].inCtrl)
    }

    @Test func anchorToolsEditSavedPathsShapesAndVectorMasks() throws {
        let s = try session()
        try s.execute("path.set", ["name": "Outline", "path": square])
        let r = try s.execute("path.deleteAnchor", ["name": "Outline", "subpath": 0, "knot": 0])
        #expect(r["path"]?["subpaths"]?[0]?["knots"]?.arrayValue?.count == 3 && r["path"]?["subpaths"]?[0]?["closed"] == true)
        for depth in [8, 16, 32] {
            let t = Session()
            try t.execute("file.new", ["width": 120, "height": 100, "depth": .int(depth)])
            let id = try #require(try t.execute("shape.create", ["kind": "rect", "rect": [10, 10, 40, 40], "fill": "#ff0000"])["layer"]?.uint64Value)
            // Top edge, then pull the new midpoint up: the layer re-renders from the edited path.
            let a = try t.execute("path.addAnchor", ["name": "layer", "layer": .int(id), "subpath": 0, "knot": 0, "t": 0.5])
            #expect(anchor(a, 1) == [30, 10])
            try t.execute("path.moveAnchors", ["name": "layer", "layer": .int(id), "anchors": [[0, 1]], "move": [0, -8]])
            var sh = try shapeOf(t, id)
            #expect(sh.live == nil)
            #expect(sh.cache?.contentBounds.y0 == 2, "depth \(depth): re-rendered")
            try t.execute("path.deleteAnchor", ["name": "layer", "layer": .int(id), "subpath": 0, "knot": 1])
            sh = try shapeOf(t, id)
            #expect(sh.path.subpaths[0].knots.count == 4 && sh.cache?.contentBounds.y0 == 10, "depth \(depth)")
        }
        let id = try #require(s.active?.activeLayer)
        try s.execute("layer.vectorMask.add", ["layer": .id(id), "path": square])
        try s.execute("path.addAnchor", ["name": "layer", "layer": .id(id), "subpath": 0, "knot": 3, "t": 0.5])
        let vm = try #require(s.active?.doc.layer(id)?.vectorMask)
        #expect(vm.path.subpaths[0].knots[4].anchor == PCPoint(10, 35), "the closing segment's midpoint")
    }

    @Test func theLastAnchorOfAShapeIsRefused() throws {
        let s = try session()
        let one: JSONValue = ["subpaths": [["closed": false, "knots": [[10, 10], [50, 10]]]]]
        let id = try #require(try s.execute("shape.create", ["kind": "path", "path": one, "fill": "#ff0000"])["layer"]?.uint64Value)
        try s.execute("path.deleteAnchor", ["name": "layer", "layer": .int(id), "subpath": 0, "knot": 0])
        let steps = s.active?.history.entries.count
        do {
            try s.execute("path.deleteAnchor", ["name": "layer", "layer": .int(id), "subpath": 0, "knot": 0])
            Issue.record("deleting the only anchor succeeded")
        } catch {
            #expect("\(error)".contains("only anchor"), "\(error)")
        }
        #expect(s.active?.history.entries.count == steps)
    }

    @Test func badParamsFailWithoutAnEdit() throws {
        let s = try session()
        #expect(throws: EngineError.self, "no work path") { try s.execute("path.moveAnchors", ["anchors": [[0, 0]], "move": [1, 1]]) }
        try s.execute("path.set", ["path": square])
        let steps = s.active?.history.entries.count
        let cases: [(String, JSONValue)] = [
            ("path.moveAnchors", ["anchors": [[0, 9]], "move": [1, 1]]),
            ("path.moveAnchors", ["anchors": [], "move": [1, 1]]),
            ("path.moveAnchors", ["anchors": [[0]], "move": [1, 1]]),
            ("path.moveAnchors", ["anchors": [[0, 0]], "move": [1e300, 1]]),
            ("path.moveAnchors", ["anchors": [[0, 0]]]),
            ("path.moveHandle", ["subpath": 0, "knot": 0, "handle": "up", "to": [1, 1]]),
            ("path.moveHandle", ["subpath": 0, "knot": 0, "handle": "in"]),
            ("path.moveHandle", ["subpath": -1, "knot": 0, "handle": "in", "to": [1, 1]]),
            ("path.bendSegment", ["subpath": 0, "knot": 0, "t": 2, "move": [1, 1]]),
            ("path.bendSegment", ["subpath": 5, "knot": 0, "move": [1, 1]]),
            ("path.convertPoint", ["subpath": 0, "knot": 4]),
            ("path.convertPoint", ["subpath": 0, "knot": 0, "out": "x"]),
            ("path.convertPoint", ["name": "nope", "subpath": 0, "knot": 0]),
            ("path.convertPoint", ["name": "layer", "subpath": 0, "knot": 0]),
            ("path.addAnchor", ["subpath": 0, "knot": 0, "t": 0]),
            ("path.addAnchor", ["subpath": 0, "knot": 0, "t": 1]),
            ("path.addAnchor", ["subpath": 0, "knot": 0, "t": -0.5]),
            ("path.addAnchor", ["subpath": 0, "knot": 0, "t": "half"]),
            ("path.addAnchor", ["subpath": 0, "knot": 4]),
            ("path.addAnchor", ["subpath": 1, "knot": 0]),
            ("path.addAnchor", ["knot": 0]),
            ("path.addAnchor", ["name": "nope", "subpath": 0, "knot": 0]),
            ("path.deleteAnchor", ["subpath": 0, "knot": 4]),
            ("path.deleteAnchor", ["subpath": 0, "knot": -1]),
            ("path.deleteAnchor", ["subpath": 0]),
            ("path.deleteAnchor", ["name": "layer", "subpath": 0, "knot": 0]),
        ]
        for (id, p) in cases { #expect(throws: EngineError.self, "\(id) \(p)") { try s.execute(id, p) } }
        #expect(s.active?.history.entries.count == steps)
    }
}
