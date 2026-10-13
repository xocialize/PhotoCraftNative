// Port of photocraft-engine (crates/engine/src/symmetry_cmds.rs tests and symmetry_cmds/preset_tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCDocument
@testable import PCEngine
import PCFoundation
import PCPaint
import Testing

@Suite struct SymmetryTests {
    typealias K = PaintTestKit
    typealias LiveStroke = BrushCommands.LiveStroke

    /// What `path.set` (another module) does for these tests: a vertical work path at x = 40.
    func setWorkPath(_ s: Session) throws {
        try s.edit("Work Path") { doc, _ in doc.workPath = VectorPath([Subpath.polyline([(40, 0), (40, 60)])]) }
    }

    func pixel(_ s: Session, _ x: Int32, _ y: Int32) -> SIMD4<Float> { K.rgba(s, x, y) }

    func close(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ tol: Float = 0.02) -> Bool {
        let d = a - b
        return abs(d.x) < tol && abs(d.y) < tol && abs(d.z) < tol && abs(d.w) < tol
    }

    @Test func curvedAxisReflectsNearLocalSegment() throws {
        var sub = Subpath.polyline([(10, 0), (10, 20)])
        sub.knots[0].outCtrl = PCPoint(20, 0)
        sub.knots[1].inCtrl = PCPoint(20, 20)
        let axis = try SymmetryCommands.Axis.fromPath("work", VectorPath([sub]))
        #expect(axis.segments.count > 1)
        let reflected = axis.reflect(StrokePoint(20, 10, 1))
        #expect(reflected.x > 10 && reflected.x < 18, "curve at mid-height is near x=17.5: \(reflected)")
    }

    @Test func invalidAndEmptyPathFailGracefully() throws {
        let s = try K.session(32, 32, background: "white")
        #expect(throws: EngineError.self) { try s.execute("paint.symmetryFromPath", ["name": "missing"]) }
        #expect(throws: EngineError.self) { try s.execute("paint.symmetryFromPath", ["name": "work"]) }
        #expect(throws: EngineError.self) { try s.execute("paint.symmetryDisable") }
        let long = Subpath.polyline((0...(SymmetryCommands.maxSegments + 1)).map { (Double($0), 0) })
        #expect(throws: EngineError.self, "path complexity remains bounded") { try SymmetryCommands.Axis.fromPath("long", VectorPath([long])) }
    }

    @Test func symmetryPaintsMirroredPixelsAndDisableStopsIt() throws {
        let s = try K.session(80, 60, background: "white")
        try setWorkPath(s)
        try s.execute("paint.symmetryFromPath", ["name": "work"])
        let params: JSONValue = ["points": [[20, 20], [30, 30]], "size": 5, "hardness": 1.0, "color": "#ff0000", "smoothing": 0.0]
        var live = try LiveStroke.begin(s, ["points": [[20, 20]], "size": 5, "hardness": 1.0, "color": "#ff0000", "smoothing": 0.0])
        try live.push([StrokePoint(30, 30, 1)])
        try s.execute("paint.stroke", params)
        let id = try #require(s.active?.activeLayer)
        let surface = K.surface(s)
        #expect(surface.rgba(x: 20, y: 20).y < 0.2)
        #expect(surface.rgba(x: 60, y: 20).y < 0.2)
        let preview = try #require(live.doc.layer(id)?.surface)
        for (x, y): (Int32, Int32) in [(20, 20), (60, 20), (30, 30), (50, 30), (40, 20)] {
            #expect(close(surface.rgba(x: x, y: y), preview.rgba(x: x, y: y)), "preview/commit at (\(x),\(y))")
        }
        try s.execute("paint.symmetryDisable")
        try s.execute("paint.stroke", ["points": [[15, 35]], "size": 5, "hardness": 1.0, "color": "#0000ff"])
        #expect(K.rgba(s, 65, 35).x > 0.8, "white remains without a mirrored blue stroke")
    }

    @Test func strokeOnAxisIsNotPaintedTwiceAtHalfOpacity() throws {
        let plain = try K.session(80, 60, background: "white")
        let symmetric = try K.session(80, 60, background: "white")
        try setWorkPath(symmetric)
        try symmetric.execute("paint.symmetryFromPath", ["name": "work"])
        let params: JSONValue = ["points": [[40, 15], [40, 40]], "size": 8, "hardness": 1.0, "opacity": 0.5, "color": "#000000", "smoothing": 0.0]
        var preview = try LiveStroke.begin(symmetric, ["points": [[40, 15]], "size": 8, "hardness": 1.0, "opacity": 0.5, "color": "#000000", "smoothing": 0.0])
        try preview.push([StrokePoint(40, 40, 1)])
        try plain.execute("paint.stroke", params)
        try symmetric.execute("paint.stroke", params)
        let expected = pixel(plain, 40, 28), actual = pixel(symmetric, 40, 28)
        let id = try #require(symmetric.active?.activeLayer)
        let previewPixel = try #require(preview.doc.layer(id)?.surface).rgba(x: 40, y: 28)
        #expect(expected.x > 0.2 && expected.x < 0.8, "half opacity should produce a gray stroke: \(expected)")
        #expect(close(actual, expected), "symmetry must not darken on-axis paint: \(actual) vs \(expected)")
        #expect(close(previewPixel, actual), "preview must match commit: \(previewPixel) vs \(actual)")
    }

    @Test func mixedAxisAndOffAxisStrokeUnionsCoverageOnce() throws {
        let plain = try K.session(80, 60, background: "white")
        let symmetric = try K.session(80, 60, background: "white")
        try setWorkPath(symmetric)
        try symmetric.execute("paint.symmetryFromPath", ["name": "work"])
        let params: JSONValue = ["points": [[40, 10], [40, 25], [30, 40]], "size": 7, "hardness": 1.0, "opacity": 0.5, "color": "#000000", "smoothing": 0.0]
        let preview = try LiveStroke.begin(symmetric, params)
        try plain.execute("paint.stroke", params)
        try symmetric.execute("paint.stroke", params)
        #expect(close(pixel(plain, 40, 18), pixel(symmetric, 40, 18)), "shared axis must have one opacity ceiling")
        #expect(pixel(symmetric, 50, 40).x < 0.9, "the off-axis part must be mirrored")
        let id = try #require(symmetric.active?.activeLayer)
        let ps = try #require(preview.doc.layer(id)?.surface)
        for (x, y): (Int32, Int32) in [(40, 18), (30, 40), (50, 40)] {
            #expect(close(pixel(symmetric, x, y), ps.rgba(x: x, y: y)), "preview/commit at (\(x),\(y))")
        }
    }

    // preset_tests.rs

    func session(_ depth: Int, _ mode: String) throws -> Session { try K.session(81, 61, background: "white", depth: depth, mode: mode) }

    @Test func presetsValidateAtomicallyAndLeaveDocumentPathsAndHistoryUntouched() throws {
        let s = try session(8, "rgb")
        try s.edit("Work Path") { doc, _ in doc.workPath = VectorPath([Subpath.polyline([(2, 3), (9, 15)])]) }
        let before = try #require(s.active?.doc)
        let history = s.active?.history.pastCount
        let revision = s.active?.revision
        for mode in SymmetryMode.allCases {
            try s.execute("paint.setSymmetry", ["mode": .string(mode.id)])
            let p = try #require(s.active?.view[SymmetryCommands.Key.self]?.preset)
            #expect(p.center == SIMD2(40.5, 30.5))
            #expect(p.rotation == 0)
            let st = try #require(s.active)
            #expect(Inspect.document(st, registry: s.registry)["symmetry"]?["mode"] == .string(mode.id))
            #expect(st.doc == before)
            #expect(st.history.pastCount == history && st.revision == revision)
        }
        try s.execute("paint.setSymmetry", ["mode": "dual", "center": [17, 29], "rotation": 45])
        let original = s.active?.view[SymmetryCommands.Key.self]
        let bads: [JSONValue] = [
            .null, [:], ["mode": "radial"], ["mode": 7], ["mode": "dual", "center": [1]], ["mode": "dual", "center": [1, 2, 3]],
            ["mode": "dual", "center": nil], ["mode": "dual", "center": ["x", 2]], ["mode": "dual", "center": [1e8, 0]],
            ["mode": "dual", "rotation": "x"], ["mode": "dual", "rotation": nil],
        ]
        for bad in bads {
            #expect(throws: EngineError.self, "\(bad)") { try s.execute("paint.setSymmetry", bad) }
            #expect(s.active?.view[SymmetryCommands.Key.self] == original)
            #expect(s.active?.doc == before)
        }
        #expect(throws: EngineError.self) { try s.execute("paint.setSymmetry", []) }
        try s.execute("paint.setSymmetry", ["mode": "dual"])
        #expect(s.active?.view[SymmetryCommands.Key.self]?.preset?.center == SIMD2(40.5, 30.5))
        try s.execute("paint.symmetryFromPath", ["name": "work"])
        #expect(s.active?.view[SymmetryCommands.Key.self]?.pathSource == "work")
        try s.execute("paint.symmetryDisable")
        let st = try #require(s.active)
        #expect(Inspect.document(st, registry: s.registry)["symmetry"] == .null)
        try s.execute("paint.setSymmetry", ["mode": "vertical"])
        try s.execute("file.new", ["width": 10, "height": 20])
        #expect(s.active?.view[SymmetryCommands.Key.self] == nil)
        #expect(s.setActive(0))
        #expect(s.active?.view[SymmetryCommands.Key.self] != nil)
        let empty = Session()
        #expect(!empty.isEnabled("paint.setSymmetry"))
        #expect(throws: EngineError.self) { try empty.execute("paint.setSymmetry", ["mode": "vertical"]) }
    }

    @Test func everyPresetLivePreviewMatchesCommittedPixelsAndUndoAtEveryDepth() throws {
        let all = PixelRect(x: 0, y: 0, width: 81, height: 61)
        for depth in [8, 16, 32] {
            for mode in ["rgb", "gray"] {
                for preset in SymmetryMode.allCases {
                    for command in ["paint.stroke", "paint.pencil"] {
                        let s = try session(depth, mode)
                        try s.execute("paint.setSymmetry", ["mode": .string(preset.id), "center": [40, 30]])
                        let before = try #require(s.active?.doc)
                        let params: JSONValue = ["points": [[20, 10], [24, 14]], "size": 5, "hardness": 1.0, "color": "#000000", "opacity": 0.5,
                                                 "smoothing": 0.0, "seed": 7]
                        let live = try LiveStroke.beginWith(s, command, params)
                        let past = s.active?.history.pastCount ?? 0
                        try s.execute(command, params)
                        let st = try #require(s.active)
                        #expect(st.history.pastCount == past + 1)
                        let id = try #require(st.activeLayer)
                        let actual = try #require(st.doc.layer(id)?.surface)
                        let preview = try #require(live.doc.layer(id)?.surface)
                        let original = StrokePoint(20, 10, 1)
                        let p = try #require(st.view[SymmetryCommands.Key.self]?.preset)
                        let positions = [original] + p.reflectedPasses([original]).map { $0[0] }
                        for q in positions {
                            #expect(actual.rgba(x: Int32(q.x.rounded()), y: Int32(q.y.rounded())).x < 0.9, "\(depth) \(mode) \(preset)")
                        }
                        let (a, b) = (actual.readRGBA(all), preview.readRGBA(all))
                        #expect(zip(a, b).allSatisfy { close($0, $1) }, "\(depth) \(mode) \(preset) \(command): preview differs")
                        let after = st.doc
                        #expect(s.undo())
                        #expect(s.active?.doc == before)
                        #expect(s.redo())
                        #expect(s.active?.doc == after)
                    }
                }
            }
        }
    }

    @Test func dualCentreOverlapHasOneOpacityCeilingAndEraserUsesTheSameCopies() throws {
        for depth in [8, 16, 32] {
            let plain = try session(depth, "rgb")
            let symmetric = try session(depth, "rgb")
            try symmetric.execute("paint.setSymmetry", ["mode": "dual", "center": [40, 30]])
            let params: JSONValue = ["points": [[40, 30]], "size": 9, "hardness": 1.0, "opacity": 0.5, "color": "#000000", "smoothing": 0.0]
            try plain.execute("paint.stroke", params)
            try symmetric.execute("paint.stroke", params)
            #expect(close(pixel(plain, 40, 30), pixel(symmetric, 40, 30)))
            try symmetric.execute("layer.new.layer")
            try K.fill(symmetric, SIMD4(0, 0, 0, 1))
            let erase: JSONValue = ["points": [[20, 10], [25, 15]], "size": 7, "hardness": 1.0, "erase": true, "smoothing": 0.0]
            var live = try LiveStroke.begin(symmetric, ["points": [[20, 10]], "size": 7, "hardness": 1.0, "erase": true, "smoothing": 0.0])
            try live.push([StrokePoint(25, 15, 1)])
            try symmetric.execute("paint.stroke", erase)
            let id = try #require(symmetric.active?.activeLayer)
            let ls = try #require(live.doc.layer(id)?.surface)
            for (x, y): (Int32, Int32) in [(20, 10), (60, 10), (20, 50), (60, 50)] {
                let a = pixel(symmetric, x, y)
                #expect(a.w < 0.2)
                #expect(close(a, ls.rgba(x: x, y: y)))
            }
        }
    }

    @Test func selectionTransparencyLockAndMaskTargetsApplyToAllPasses() throws {
        let s = try session(8, "rgb")
        try s.execute("paint.setSymmetry", ["mode": "dual", "center": [40, 30]])
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 40, "height": 30])
        try s.execute("paint.stroke", ["points": [[20, 10]], "size": 5, "hardness": 1.0, "color": "#000000"])
        #expect(pixel(s, 20, 10).x < 0.2)
        #expect(pixel(s, 60, 10).x > 0.9)
        try s.execute("select.deselect")
        try s.edit("Mask fixture") { doc, active in
            var layer = Layer.raster("Mask", format: doc.pixelFormat)
            layer.mask = LayerMask.revealAll()
            layer.locks.transparency = true
            active = layer.id
            doc.layers.append(layer)
        }
        try s.execute("paint.stroke", ["points": [[20, 10]], "size": 5, "color": "#000000", "target": "mask"])
        let st = try #require(s.active)
        let l = try #require(st.activeLayer.flatMap { st.doc.layer($0) })
        let mask = try #require(l.mask)
        for (x, y): (Int32, Int32) in [(20, 10), (60, 10), (20, 50), (60, 50)] {
            #expect(mask.surface.rgba(x: x, y: y).x < 0.8)
        }
        #expect(l.surface?.contentBounds.isEmpty == true)
        try s.execute("paint.stroke", ["points": [[20, 10]], "size": 5, "color": "#ff0000"])
        #expect(K.surface(s).contentBounds.isEmpty)
    }

    @Test func streamingAcrossDualAxesKeepsOneOpacityAndMatchesCommit() throws {
        let points: [[Double]] = [[40, 30], [40, 20], [35, 20], [45, 40]]
        let all = PixelRect(x: 0, y: 0, width: 81, height: 61)
        for depth in [8, 16, 32] {
            let s = try session(depth, "rgb")
            try s.execute("paint.setSymmetry", ["mode": "dual", "center": [40, 30]])
            let params: JSONValue = ["points": K.points([points[0]]), "size": 9, "hardness": 1.0, "opacity": 0.5, "color": "#000000", "smoothing": 0.0]
            var live = try LiveStroke.begin(s, params)
            for q in points.dropFirst() { try live.push([StrokePoint(q[0], q[1], 1)]) }
            try s.execute("paint.stroke", params.setting("points", K.points(points)))
            let id = try #require(s.active?.activeLayer)
            let a = K.surface(s).readRGBA(all)
            let b = try #require(live.doc.layer(id)?.surface).readRGBA(all)
            #expect(a.allSatisfy { $0.x >= 0.49 }, "opacity applied more than once")
            #expect(zip(a, b).allSatisfy { close($0, $1) }, "preview differs")
        }
    }
}
