// Port of photocraft-engine (crates/engine/src/vector_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
@testable import PCEngine
import PCDocument
import PCFoundation
import PCPlatform
import Testing

fileprivate struct Failure: Error, CustomStringConvertible { var description: String }

fileprivate func session(_ w: Int, _ h: Int, _ depth: Int) throws -> Session {
    let s = Session()
    try s.execute("file.new", ["width": .int(w), "height": .int(h), "background": "white", "depth": .int(depth)])
    return s
}

fileprivate func doc(_ s: Session) throws -> Document { try #require(s.active?.doc) }

fileprivate func shape(_ s: Session, _ id: UInt64) throws -> ShapeLayer {
    let l = try #require(try doc(s).layer(LayerId(id)))
    guard case .shape(let sh) = l.content else { throw Failure(description: "not a shape: \(l.content.kindName)") }
    return sh
}

fileprivate func alphaSum(_ sh: ShapeLayer) -> Double {
    guard let c = sh.cache else { return 0 }
    return c.readRGBA(c.contentBounds).reduce(0) { $0 + Double($1.w) }
}

fileprivate func selectionMask(_ s: Session) throws -> [Float] {
    let d = try doc(s)
    return SelectionMath.mask(from: d.selection, d.bounds)
}

/// The flattened composite, straight RGBA row-major (photocraft `compose::flatten`).
fileprivate func flatten(_ s: Session) throws -> [SIMD4<Float>] {
    let d = try doc(s)
    return try s.services.renderer.compositeToSurface(d, rect: d.bounds, format: .rgba32f).readRGBA(d.bounds)
}

fileprivate func layerId(_ r: JSONValue) throws -> UInt64 { try #require(r["layer"]?.uint64Value) }

fileprivate func activeSurface(_ s: Session) throws -> Surface {
    let st = try #require(s.active)
    let id = try #require(st.activeLayer)
    return try #require(st.doc.layer(id)?.surface)
}

fileprivate func ellipsePath(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> VectorPath { LiveShape.ellipse(rect: SIMD4(x, y, w, h)).path }

@Suite struct VectorCommandsTests {
    @Test func strokeValidationRejectsHostileValuesWithoutEditingHistory() throws {
        let s = try session(100, 80, 8)
        let id = try layerId(s.execute("shape.create", ["rect": [20, 20, 50, 30], "stroke": ["width": 4]]))
        let before = try doc(s)
        let history = s.active?.history.pastCount
        let invalid: [JSONValue] = [
            true, [], ["width": -1], ["width": 1e100], ["opacity": 101], ["cap": "invalid"], ["cap": 2], ["join": "invalid"], ["align": "invalid"],
            ["miterLimit": 0], ["miterLimit": 501], ["dashes": [4, "x"]], ["dashes": [-1, 2]], ["dashes": [0, 0]],
            ["dashes": .array(Array(repeating: 1, count: 33))], ["dashOffset": 1e100], ["width": "4"], ["width": 0.00001, "dashes": [0.01, 0.01]],
        ]
        for stroke in invalid {
            #expect(throws: EngineError.self, "\(stroke)") { try s.execute("shape.edit", ["layer": .int(id), "stroke": stroke]) }
            #expect(try doc(s) == before)
            #expect(s.active?.history.pastCount == history)
            #expect(throws: EngineError.self, "\(stroke)") { try s.execute("shape.create", ["rect": [20, 20, 50, 30], "stroke": stroke]) }
        }
        #expect(throws: EngineError.self) { try s.execute("shape.edit", ["layer": .int(id), "rect": [1e100, 0, 20, 20]]) }
        #expect(try doc(s) == before)
    }

    @Test func completeStrokeEditsPreservePaintAndGeometryAndUndoAtEveryDepth() throws {
        for depth in [8, 16, 32] {
            let s = try session(100, 80, depth)
            let id = try layerId(s.execute("shape.create", ["kind": "polygon", "sides": 3, "rect": [20, 20, 50, 30], "stroke": ["width": 4, "color": "#1122dd"]]))
            let original = try shape(s, id)
            let history = try #require(s.active?.history.pastCount)
            let patch: JSONValue = ["align": "outside", "cap": "square", "join": "bevel", "miterLimit": 2, "opacity": 35, "dashes": [4, 2, 1, 3], "dashOffset": -0.5]
            try s.execute("shape.edit", ["layer": .int(id), "stroke": patch])
            let changed = try shape(s, id)
            #expect(changed.path == original.path)
            #expect(changed.stroke?.paint == original.stroke?.paint)
            #expect(changed.stroke?.dashes == [4, 2, 1, 3])
            #expect(changed.cache != original.cache)
            #expect(s.active?.history.pastCount == history + 1)
            try s.execute("edit.undo")
            #expect(try shape(s, id) == original)
            try s.execute("edit.redo")
            #expect(try shape(s, id) == changed)
        }
    }

    @Test func strokeEditsRespectShapeLocks() throws {
        let s = try session(80, 60, 8)
        let id = try layerId(s.execute("shape.create", ["rect": [10, 10, 40, 30], "stroke": ["width": 3]]))
        try s.execute("layer.lockLayers", ["all": true])
        let before = try doc(s)
        #expect(throws: EngineError.self) { try s.execute("shape.edit", ["layer": .int(id), "stroke": ["dashes": [4, 2]]]) }
        #expect(try doc(s) == before)
    }

    @Test func addingComponentsValidatesTheExistingStrokesCombinedWorkload() throws {
        let s = try session(80, 60, 8)
        let id = try layerId(s.execute("shape.create", ["rect": [0, 0, 1, 1], "stroke": ["width": 0.001, "dashes": [1, 1]]]))
        let before = try doc(s)
        let history = s.active?.history.pastCount
        #expect(throws: EngineError.self) { try s.execute("shape.create", ["addTo": .int(id), "rect": [20, 20, 100, 80]]) }
        #expect(try doc(s) == before)
        #expect(s.active?.history.pastCount == history)
    }

    @Test func shapeCreateEveryKindAndUndo() throws {
        for depth in [8, 16, 32] {
            let s = try session(200, 150, depth)
            let cases: [(JSONValue, Double)] = [
                (["kind": "rect", "rect": [10, 10, 50, 40]], 2000),
                (["kind": "roundedRect", "rect": [10, 10, 50, 40], "radii": 10], 2000 - (4 - Double.pi) * 100),
                (["kind": "ellipse", "rect": [20, 20, 100, 60]], Double.pi * 50 * 30),
                (["kind": "polygon", "rect": [0, 0, 100, 100], "sides": 6], 1.5 * 3.0.squareRoot() * 2500),
                (["kind": "star", "rect": [0, 0, 100, 100], "sides": 5, "starRatio": 0.5], 0),
                (["kind": "line", "from": [10, 100], "to": [110, 100], "weight": 4], 400),
                (["kind": "path", "path": ["subpaths": [["closed": true, "knots": [[0, 0], [60, 0], [0, 60]]]]]], 1800),
            ]
            let before = try doc(s).layerCount
            for (i, (p, area)) in cases.enumerated() {
                let r = try s.execute("shape.create", p)
                let id = try layerId(r)
                let sh = try shape(s, id)
                #expect(sh.cache?.format == (try doc(s)).pixelFormat)
                let a = alphaSum(sh)
                if area > 0 {
                    #expect(abs(a - area) / area < 0.01, "case \(i) depth \(depth): \(a) vs \(area)")
                } else {
                    #expect(a > 1000)
                }
                #expect(r["kind"] == p["kind"], "\(r)")
                #expect(s.active?.activeLayer == LayerId(id))
            }
            #expect(try doc(s).layerCount == before + cases.count)
            for _ in cases { #expect(s.undo()) }
            #expect(try doc(s).layerCount == before)
            #expect(s.redo())
            #expect(try doc(s).layerCount == before + 1)
        }
    }

    @Test func shapeCreateFillStrokeAndComposite() throws {
        let s = try session(100, 100, 8)
        let r = try s.execute("shape.create", ["kind": "rect", "rect": [20, 20, 60, 60], "fill": "#ff0000", "stroke": ["width": 4, "color": "#0000ff", "align": "outside"]])
        #expect(r["fill"] == "#ff0000")
        #expect(r["stroke"]?["align"] == "outside")
        #expect(r["bounds"] == [16, 16, 68, 68])
        let f = try flatten(s)
        func px(_ x: Int, _ y: Int) -> SIMD4<Float> { f[y * 100 + x] }
        #expect(px(50, 50).x > 0.99 && px(50, 50).z < 0.01)
        #expect(px(18, 50).z > 0.99 && px(18, 50).x < 0.01)
        #expect(px(10, 10).y > 0.99)
        // No fill: only the stroke.
        let r2 = try s.execute("shape.create", ["kind": "ellipse", "rect": [5, 5, 40, 40], "fill": nil, "stroke": ["width": 2]])
        let sh = try shape(s, try layerId(r2))
        #expect(sh.fill == nil)
        #expect(abs(alphaSum(sh) - Double.pi * 40 * 2) < 3, "\(alphaSum(sh))")
        #expect(throws: EngineError.self) { try s.execute("shape.create", ["kind": "rect"]) }
        #expect(throws: EngineError.self) { try s.execute("shape.create", ["kind": "blob", "rect": [0, 0, 1, 1]]) }
    }

    @Test func shapeEditLiveParamsAndUndo() throws {
        let s = try session(200, 200, 8)
        let id = try layerId(s.execute("shape.create", ["kind": "rect", "rect": [10, 10, 50, 50]]))
        var r = try s.execute("shape.edit", ["layer": .int(id), "rect": [10, 10, 100, 50]])
        #expect(r["bounds"] == [10, 10, 100, 50])
        #expect(abs(alphaSum(try shape(s, id)) - 5000) < 1)
        // Radii turn it into a rounded rectangle.
        r = try s.execute("shape.edit", ["layer": .int(id), "radii": [20, 0, 20, 0]])
        #expect(r["kind"] == "roundedRect")
        #expect(r["live"]?["radii"] == [20.0, 0.0, 20.0, 0.0])
        // Move keeps the live shape; a rotation drops it.
        r = try s.execute("shape.edit", ["layer": .int(id), "move": [5, 7]])
        #expect(r["live"]?["rect"] == [15.0, 17.0, 100.0, 50.0])
        r = try s.execute("shape.edit", ["layer": .int(id), "transform": [0.0, 1.0, -1.0, 0.0, 150.0, 0.0]])
        #expect(r["kind"] == "path")
        // Fill/stroke edits merge.
        try s.execute("shape.edit", ["layer": .int(id), "stroke": ["width": 3]])
        r = try s.execute("shape.edit", ["layer": .int(id), "stroke": ["cap": "round", "dashes": [2, 1]],
                                         "fill": ["gradient": ["stops": [[0, "#000000"], [1, "#ffffff"]], "angle": 0]]])
        #expect(r["stroke"]?["width"] == 3.0)
        #expect(r["stroke"]?["cap"] == "round")
        #expect(r["fill"]?["gradient"]?.objectValue != nil)
        try s.execute("shape.edit", ["layer": .int(id), "stroke": nil, "name": "Box"])
        #expect(try shape(s, id).stroke == nil)
        #expect(try doc(s).layer(LayerId(id))?.name == "Box")
        // Undo walks back one edit at a time.
        s.undo()
        #expect(try shape(s, id).stroke != nil)
        // Editing a non-shape layer fails.
        let bg = try doc(s).layers[0].id
        #expect(throws: EngineError.self) { try s.execute("shape.edit", ["layer": .id(bg), "fill": "#000000"]) }
    }

    @Test func reapplyingUnchangedLiveRectangleKeepsNonuniformlyScaledCorners() throws {
        for depth in [8, 16, 32] {
            let s = try session(128, 128, depth)
            let id = try layerId(s.execute("shape.create", ["kind": "roundedRect", "rect": [10, 10, 20, 20], "radius": 4]))
            try s.execute("shape.edit", ["layer": .int(id), "transform": [2, 0, 0, 1, 0, 0]])
            let scaled = try shape(s, id)
            guard case .rect(let rect, _)? = scaled.live else { throw Failure(description: "not a live rect: \(String(describing: scaled.live))") }
            #expect(rect == SIMD4(20, 10, 40, 20))
            let path = scaled.path
            try s.execute("shape.edit", ["layer": .int(id), "rect": [20, 10, 40, 20]])
            #expect(try shape(s, id).path == path, "depth \(depth): no-op rectangle edit must preserve all control points")
            try s.execute("shape.edit", ["layer": .int(id), "kind": "roundedRect", "rect": [20, 10, 40, 20], "radius": 4])
            #expect(try shape(s, id).path == path, "depth \(depth): explicitly unchanged radius preserves scaled outline")
            try s.execute("shape.edit", ["layer": .int(id), "radii": [6, 6, 6, 6]])
            #expect(try shape(s, id).path != path, "depth \(depth): changed radii must take effect")
            try s.execute("edit.undo")
            #expect(try shape(s, id).path == path)
        }
    }

    @Test func shapeAddToWithPathOps() throws {
        let s = try session(100, 100, 8)
        let id = try layerId(s.execute("shape.create", ["kind": "rect", "rect": [0, 0, 60, 60]]))
        let r = try s.execute("shape.create", ["kind": "rect", "rect": [30, 30, 60, 60], "addTo": .int(id), "op": "subtract"])
        #expect(r["path"]?["subpaths"]?[1]?["op"] == "subtract")
        #expect(abs(alphaSum(try shape(s, id)) - (3600 - 900)) < 1)
        try s.execute("layer.combineShapes.intersectShapeAreas", ["layer": .int(id)])
        #expect(abs(alphaSum(try shape(s, id)) - 900) < 1)
        try s.execute("layer.combineShapes.excludeOverlappingShapes", ["layer": .int(id)])
        #expect(abs(alphaSum(try shape(s, id)) - 5400) < 1)
        // Merge bakes the xor into plain outlines with the same area.
        let m = try s.execute("layer.combineShapes.mergeShapeComponents", ["layer": .int(id)])
        let merged = try shape(s, id)
        #expect(merged.path.subpaths.count >= 2, "\(m)")
        #expect(abs(alphaSum(merged) - 5400) < 20, "\(alphaSum(merged))")
    }

    @Test func shapeRasterizeKeepsPixels() throws {
        let s = try session(64, 64, 16)
        let id = try layerId(s.execute("shape.create", ["kind": "ellipse", "rect": [4, 4, 40, 30]]))
        let before = try #require(try shape(s, id).cache)
        let flat = try flatten(s)
        try s.execute("layer.rasterize.shape", ["layer": .int(id)])
        let l = try #require(try doc(s).layer(LayerId(id)))
        guard case .raster(let surf) = l.content else { throw Failure(description: "not rasterized") }
        #expect(surf == before)
        #expect(try flatten(s) == flat)
        #expect(throws: EngineError.self) { try s.execute("shape.rasterize", ["layer": .int(id)]) }
    }

    @Test func pathsSetRenameDeleteList() throws {
        let s = try session(100, 100, 8)
        let tri: JSONValue = ["subpaths": [["knots": [[10, 10], [90, 10], [50, 90]]]]]
        try s.execute("path.set", ["path": tri])
        #expect(try doc(s).workPath != nil)
        // Saving the work path (rename) moves it into the saved paths.
        try s.execute("path.rename", ["to": "Triangle"])
        #expect(try doc(s).workPath == nil)
        #expect(try doc(s).paths.first?.name == "Triangle")
        try s.execute("path.set", ["name": "Triangle", "op": "subtract", "path": ["subpaths": [["knots": [[40, 20], [60, 20], [60, 40], [40, 40]]]]]])
        #expect(try doc(s).paths[0].path.subpaths.count == 2)
        #expect(try doc(s).paths[0].path.subpaths[1].op == .subtract)
        let l = try s.execute("path.list")
        #expect(l["paths"]?[0]?["knots"] == 7)
        let info = try s.execute("path.info", ["name": "Triangle"])
        #expect(info["path"]?["subpaths"]?[1]?["op"] == "subtract")
        try s.execute("path.rename", ["name": "Triangle", "to": "Tri"])
        #expect(throws: EngineError.self) { try s.execute("path.delete", ["name": "Triangle"]) }
        try s.execute("path.delete", ["name": "Tri"])
        #expect(try doc(s).paths.isEmpty)
        s.undo()
        #expect(try doc(s).paths.first?.name == "Tri")
        #expect(throws: EngineError.self) { try s.execute("path.set", ["path": ["subpaths": [["knots": [[0, 0], [1]]]]]]) }
    }

    @Test func pathToSelectionMatchesAnalyticShape() throws {
        let s = try session(200, 200, 8)
        // Circle of radius 60 at (100, 100) as a work path.
        try s.execute("path.set", ["path": VectorCommands.pathJSON(ellipsePath(40, 40, 120, 120))])
        try s.execute("path.toSelection")
        let m = try selectionMask(s)
        let area = m.reduce(0) { $0 + Double($1) }
        let want = Double.pi * 3600
        #expect(abs(area - want) / want < 0.005, "\(area) vs \(want)")
        func at(_ x: Int, _ y: Int) -> Float { m[y * 200 + x] }
        #expect(at(100, 100) == 1)
        #expect(at(10, 10) == 0)
        for (x, y) in [(160, 100), (100, 40), (142, 142)] {
            let d = ((Double(x) + 0.5 - 100) * (Double(x) + 0.5 - 100) + (Double(y) + 0.5 - 100) * (Double(y) + 0.5 - 100)).squareRoot()
            let analytic = min(max(60 - d + 0.5, 0), 1)
            #expect(abs(Double(at(x, y)) - analytic) < 0.2, "(\(x),\(y)): \(at(x, y)) vs \(analytic)")
        }
        // Modes: subtract a square.
        try s.execute("path.set", ["name": "Sq", "path": ["subpaths": [["knots": [[100, 0], [200, 0], [200, 200], [100, 200]]]]]])
        try s.execute("path.toSelection", ["name": "Sq", "mode": "subtract"])
        let half = try selectionMask(s).reduce(0) { $0 + Double($1) }
        #expect(abs(half - want / 2) / want < 0.005)
        // Non-anti-aliased selections are binary; feather softens.
        try s.execute("path.toSelection", ["antiAlias": false])
        #expect(try selectionMask(s).allSatisfy { $0 == 0 || $0 == 1 })
        try s.execute("path.toSelection", ["feather": 8])
        let f = try selectionMask(s)
        #expect(f[100 * 200 + 160] > 0.2 && f[100 * 200 + 160] < 0.8)
    }

    @Test func selectionToWorkPathRoundtripIoU() throws {
        let s = try session(240, 180, 8)
        // An anti-aliased donut plus a rectangle, from a path, as the selection.
        var p = ellipsePath(20, 20, 140, 140)
        p.subpaths.append(ellipsePath(60, 60, 60, 60).subpaths[0].withOp(.subtract))
        p.subpaths.append(LiveShape.rect(rect: SIMD4(170, 30, 50, 120), radii: .zero).path.subpaths[0])
        try s.execute("path.set", ["name": "src", "path": VectorCommands.pathJSON(p)])
        try s.execute("path.toSelection", ["name": "src"])
        let before = try selectionMask(s)
        for tol in [1.0, 2.0] {
            let r = try s.execute("select.toWorkPath", ["tolerance": .number(tol)])
            #expect(r["subpaths"] == 3)
            try s.execute("path.toSelection")
            let after = try selectionMask(s)
            var i = 0.0, u = 0.0
            for (a, b) in zip(before, after) {
                i += Double(min(a, b))
                u += Double(max(a, b))
            }
            #expect(i / u > 0.98, "tolerance \(tol): IoU \(i / u)")
            try s.execute("path.toSelection", ["name": "src"])
        }
        // Selection → shape layer.
        let r = try s.execute("select.convertToShape", ["fill": "#00ff00"])
        #expect(r["fill"] == "#00ff00")
        #expect(r["path"]?["subpaths"]?.arrayValue?.count == 3)
    }

    @Test func fillAndStrokePathOnPixelLayer() throws {
        let s = try session(100, 100, 16)
        try s.execute("layer.new.layer")
        try s.execute("path.set", ["path": ["subpaths": [["knots": [[10, 10], [60, 10], [60, 60], [10, 60]]]]]])
        try s.execute("path.fill", ["color": "#ff0000", "opacity": 50])
        var surf = try activeSurface(s)
        let px = surf.rgba(x: 30, y: 30)
        #expect(abs(px.x - 1) < 1e-3 && abs(px.w - 0.5) < 0.01, "\(px)")
        #expect(surf.rgba(x: 80, y: 80).w == 0)
        // Stroke with a hard 4 px pencil along the square outline.
        try s.execute("path.stroke", ["tool": "pencil", "size": 4, "color": "#0000ff", "opacity": 100])
        surf = try activeSurface(s)
        #expect(surf.rgba(x: 10, y: 35).z > 0.9)
        #expect(surf.rgba(x: 60, y: 35).z > 0.9)
        #expect(surf.rgba(x: 35, y: 35).z < 0.1)
        #expect(throws: EngineError.self) { try s.execute("path.stroke", ["tool": "airbrush"]) }
        // Filling needs a pixel layer.
        try s.execute("shape.create", ["kind": "rect", "rect": [0, 0, 5, 5]])
        #expect(throws: EngineError.self) { try s.execute("path.fill") }
    }

    /// #2978: Simulate Pressure tapers the stroke at both ends.
    @Test func strokePathSimulatePressureTapersBothEnds() throws {
        func coverage(_ simulate: Bool, _ x: Int32) throws -> Int {
            let s = try session(200, 60, 8)
            try s.execute("layer.new.layer")
            try s.execute("path.set", ["path": ["subpaths": [["closed": false, "knots": [[20, 30], [180, 30]]]]]])
            try s.execute("path.stroke", ["tool": "brush", "size": 20, "hardness": 1.0, "color": "#000000", "opacity": 100, "simulatePressure": .bool(simulate)])
            let surf = try activeSurface(s)
            return (0..<60).filter { surf.rgba(x: x, y: Int32($0)).w > 0.5 }.count
        }
        let (end, middle) = (try coverage(true, 26), try coverage(true, 100))
        #expect(middle >= 18 && end * 3 < middle, "simulated: \(end) px near the start, \(middle) px in the middle")
        let (end2, middle2) = (try coverage(false, 26), try coverage(false, 100))
        #expect(middle2 >= 18 && end2 + 2 >= middle2, "plain: \(end2) px near the start, \(middle2) px in the middle")
    }

    /// The tools past the Eraser run their `paint.*` command in one compound step; when the command
    /// fails nothing changes and nothing is journalled (Rust `stroke_path_with_the_blur_tool_is_one_step`
    /// needs `paint.blur`, which another module ports).
    @Test func strokePathWithAnUnavailablePaintToolChangesNothing() throws {
        let s = try session(100, 60, 8)
        try s.execute("layer.new.layer")
        try s.execute("path.set", ["path": ["subpaths": [["closed": false, "knots": [[50, 5], [50, 28]]], ["closed": false, "knots": [[50, 28], [50, 55]]]]]])
        let before = try doc(s)
        let steps = s.active?.history.pastCount
        let journal = s.journal.count
        if s.registry.spec("paint.blur")?.isAvailable == true { return }
        #expect(throws: EngineError.self) { try s.execute("path.stroke", ["tool": "blur", "size": 10, "strength": 100]) }
        #expect(try doc(s) == before)
        #expect(s.active?.history.pastCount == steps)
        #expect(s.journal.count == journal)
        #expect(throws: EngineError.self) { try s.execute("path.stroke", ["tool": "blur", "simulatePressure": "yes"]) }
        #expect(throws: EngineError.self) { try s.execute("path.stroke", ["tool": "airbrush"]) }
    }

    @Test func fillPathStaysInsideTheSelection() throws {
        func alpha(_ s: Session, _ x: Int32, _ y: Int32) throws -> Float { try activeSurface(s).rgba(x: x, y: y).w }
        for depth in [8, 16, 32] {
            for extra: JSONValue in [[:], ["ellipse": true], ["feather": 4]] {
                let s = try session(100, 100, depth)
                try s.execute("layer.new.layer")
                let rect: JSONValue = (["x": 0, "y": 0, "width": 50, "height": 100] as JSONValue).merging(extra)
                try s.execute("select.rect", rect)
                try s.execute("path.set", ["path": ["subpaths": [["closed": true, "knots": [[10, 10], [90, 10], [90, 90], [10, 90]]]]]])
                try s.execute("path.fill", ["color": "#ff0000", "opacity": 100])
                let mask = try selectionMask(s)
                #expect(try alpha(s, 30, 50) > 0.99, "\(depth) \(extra): inside the selection")
                #expect(try alpha(s, 70, 50) == 0, "\(depth) \(extra): outside the selection")
                for (x, y) in [(46, 50), (49, 50), (51, 50), (25, 12), (12, 25)] {
                    let mv = mask[y * 100 + x]
                    #expect(try alpha(s, Int32(x), Int32(y)) <= mv + 0.01, "\(depth) \(extra) (\(x),\(y)): alpha > selection \(mv)")
                }
                try s.execute("edit.undo")
                #expect(try alpha(s, 30, 50) == 0, "\(depth) \(extra): undo restores")
            }
        }
        // Without a selection the whole path fills.
        let s = try session(100, 100, 8)
        try s.execute("layer.new.layer")
        try s.execute("path.set", ["path": ["subpaths": [["closed": true, "knots": [[10, 10], [90, 10], [90, 90], [10, 90]]]]]])
        try s.execute("path.fill", ["color": "#ff0000"])
        #expect(try alpha(s, 30, 50) > 0.99 && alpha(s, 70, 50) > 0.99)
    }

    @Test func clippingPathRequiresSavedPathAndTracksRenameDelete() throws {
        let s = try session(60, 60, 8)
        #expect(throws: EngineError.self) { try s.execute("path.clippingPath.set") }
        #expect(throws: EngineError.self) { try s.execute("path.clippingPath.set", ["name": "missing"]) }
        try s.execute("path.set", ["name": "Cutout", "path": ["subpaths": [["knots": [[1, 1], [20, 1], [20, 20]]]]]])
        #expect(throws: EngineError.self) { try s.execute("path.clippingPath.set", ["name": "Cutout", "flatness": -1]) }
        #expect(throws: EngineError.self) { try s.execute("path.clippingPath.set", ["name": "Cutout", "flatness": "bad"]) }
        try s.execute("path.clippingPath.set", ["name": "Cutout", "flatness": 2.5])
        #expect(try doc(s).clippingPath?.name == "Cutout")
        #expect(try doc(s).clippingPath?.flatness == 2.5)
        try s.execute("path.rename", ["name": "Cutout", "to": "Final"])
        #expect(try doc(s).clippingPath?.name == "Final")
        try s.execute("path.clippingPath.clear")
        #expect(try doc(s).clippingPath == nil)
        #expect(s.undo())
        #expect(try doc(s).clippingPath?.name == "Final")
        try s.execute("path.delete", ["name": "Final"])
        #expect(try doc(s).clippingPath == nil)
    }

    @Test func transformWorkSavedAndShapePaths() throws {
        let s = try session(100, 100, 8)
        let path: JSONValue = ["subpaths": [["knots": [[4, 5], [20, 5], [20, 20]]]]]
        try s.execute("path.set", ["path": path])
        #expect(throws: EngineError.self) { try s.execute("path.transform") }
        #expect(throws: EngineError.self) { try s.execute("path.transform", ["matrix": [1, 0, 0, 1, "bad", 0]]) }
        #expect(throws: EngineError.self) { try s.execute("path.transform", ["matrix": [1, 0, 0, 1, 1e30, 0]]) }
        try s.execute("path.transform", ["matrix": [1, 0, 0, 1, 10, 7]])
        #expect(try doc(s).workPath?.subpaths[0].knots[0].anchor == PCPoint(14, 12))
        try s.execute("path.set", ["name": "Saved", "path": path])
        try s.execute("path.transform", ["name": "Saved", "matrix": [2, 0, 0, 2, 0, 0]])
        #expect(try doc(s).paths[0].path.subpaths[0].knots[0].anchor == PCPoint(8, 10))
        try s.execute("path.transform", ["name": "Saved", "translateX": 3, "translateY": -2])
        #expect(try doc(s).paths[0].path.subpaths[0].knots[0].anchor == PCPoint(11, 8))
        let id = try layerId(s.execute("shape.create", ["kind": "rect", "rect": [10, 10, 20, 20]]))
        try s.execute("path.transform", ["name": "layer", "layer": .int(id), "matrix": [1, 0, 0, 1, 5, 0]])
        #expect(try shape(s, id).path.subpaths[0].knots[0].anchor.x == 15)
        #expect(try shape(s, id).cache != nil)
    }

    /// Distort / Perspective and Warp of a path (#3027).
    @Test func transformPathDistortAndWarp() throws {
        let s = try session(100, 100, 8)
        try s.execute("path.set", ["path": ["subpaths": [["closed": true, "knots": [[10, 10], [30, 10], [30, 20], [10, 20]]]]]])
        let steps = try #require(s.active?.history.pastCount)
        let bad: [JSONValue] = [
            ["quad": [[0, 0], [0, 0], [0, 0], [0, 0]]],
            ["quad": [[10, 10], [40, 5], [45, 30]]],
            ["quad": [[10, 10], [40, 5], [45, 30], [5, "x"]]],
            ["quad": [[10, 10], [40, 5], [45, 30], [5, 1e30]]],
            ["quad": [[10, 10], [40, 5], [45, 30], [5, 25]], "rect": [10, 10, 10, 20]],
            ["style": "nope"],
            ["style": "arc", "rect": [0, 0, 1e30, 1]],
        ]
        for b in bad { #expect(throws: EngineError.self, "\(b)") { try s.execute("path.transform", b) } }
        #expect(s.active?.history.pastCount == steps)
        let quad: [[Double]] = [[12, 8], [40, 5], [45, 30], [5, 25]]
        try s.execute("path.transform", ["quad": .array(quad.map { .doubles($0) })])
        #expect(s.active?.history.pastCount == steps + 1, "one step")
        let anchors = try #require(try doc(s).workPath?.subpaths[0].knots.map(\.anchor))
        #expect(anchors.count == 4)
        for (a, q) in zip(anchors, quad) { #expect(abs(a.x - q[0]) < 1e-9 && abs(a.y - q[1]) < 1e-9, "\(anchors)") }
        try s.execute("path.transform", ["style": "arc", "bend": 50])
        #expect(try doc(s).workPath?.subpaths[0].knots.count ?? 0 > 4, "the warp bends the edges")
    }

    @Test func copyAndPasteShapeFillAndStroke() throws {
        let s = try session(100, 100, 8)
        #expect(!s.isEnabled("path.style.copyFill"))
        #expect(!s.isEnabled("path.style.pasteFill"))
        #expect(throws: EngineError.self) { try s.execute("path.style.copyFill") }
        #expect(throws: EngineError.self) { try s.execute("path.style.pasteFill") }
        let source = try layerId(s.execute("shape.create", ["kind": "rect", "rect": [10, 10, 20, 20], "fill": "#ff0000", "stroke": ["width": 3, "color": "#0000ff"]]))
        #expect(s.isEnabled("path.style.copyFill"))
        #expect(s.isEnabled("path.style.copyStroke"))
        try s.execute("path.style.copyFill")
        try s.execute("path.style.copyStroke")
        let target = try layerId(s.execute("shape.create", ["kind": "rect", "rect": [40, 40, 20, 20], "fill": "#00ff00"]))
        #expect(s.isEnabled("path.style.pasteFill"))
        #expect(s.isEnabled("path.style.pasteStroke"))
        try s.execute("path.style.pasteFill")
        try s.execute("path.style.pasteStroke")
        #expect(try shape(s, source).fill == shape(s, target).fill)
        #expect(try shape(s, source).stroke == shape(s, target).stroke)
        #expect(s.undo())
        #expect(try shape(s, target).stroke == nil)
    }

    @Test func pathFillHandlesExtremeCoordinatesAndFeather() throws {
        let s = try session(48, 32, 8)
        try s.execute("layer.new.layer")
        try s.execute("path.set", ["name": "P", "path": ["subpaths": [["closed": true, "knots": [[0.0, 0.0], [3.0e9, 0.0], [3.0e9, 1.0e9]]]]]])
        try s.execute("path.fill", ["name": "P", "color": "#ff0000"])
        try s.execute("path.fill", ["name": "P", "color": "#ff0000", "feather": 1_073_741_824.0])
        #expect(try activeSurface(s).tileCount == 1)
    }

    /// #992: the vector mask's feather (and a pixel mask's feather or density) shape the rendered
    /// edge, so the rasterized pixel mask holds the mask the compositor showed.
    @Test func rasterizingAVectorMaskKeepsWhatTheMasksShow() throws {
        let cases: [(Double, Bool, (Float, Float)?)] = [
            (8, true, nil), (8, true, (0, 1)), (0, true, (4, 1)), (0, true, (0, 0.5)), (6, true, (3, 0.7)),
            (0, true, nil), (0, true, (0, 1)), (8, false, (4, 1)),
        ]
        for depth in [8, 16, 32] {
            for (vf, enabled, pm) in cases {
                let what = "\(depth)-bit, vector feather \(vf) enabled \(enabled), pixel mask \(String(describing: pm))"
                let s = try session(64, 64, depth)
                try s.execute("layer.new.layer")
                let id = try #require(s.active?.activeLayer)
                try s.execute("path.set", ["name": "all", "path": ["subpaths": [["knots": [[0, 0], [64, 0], [64, 64], [0, 64]]]]]])
                try s.execute("path.fill", ["name": "all", "color": "#000000"])
                if let pmv = pm {
                    let (feather, density) = pmv
                    try s.execute("select.rect", ["x": 0, "y": 0, "width": 40, "height": 64])
                    try s.execute("layer.layerMask.revealSelection")
                    try s.edit("mask settings") { doc, _ in
                        doc.updateLayer(id) { l in
                            l.mask?.feather = feather
                            l.mask?.density = density
                        }
                    }
                }
                try s.execute("path.set", ["path": ["subpaths": [["knots": [[16, 16], [48, 16], [48, 48], [16, 48]]]]]])
                try s.execute("layer.vectorMask.currentPath")
                try s.execute("layer.vectorMask.edit", ["feather": .number(vf), "enabled": .bool(enabled)])
                let before = try flatten(s)
                let steps = try #require(s.active?.history.pastCount)
                try s.execute("layer.rasterize.vectorMask")
                let l = try #require(try doc(s).layer(id))
                #expect(l.vectorMask == nil && l.mask != nil, "\(what)")
                // An integer mask stores the soft values rounded to its depth.
                let tol: Float = l.mask?.surface.format.sample == .u8 ? 1.5 / 255 : 1e-3
                #expect(s.active?.history.pastCount == steps + 1, "\(what): one history step")
                let after = try flatten(s)
                var worst: Float = 0
                for (a, b) in zip(before, after) { worst = max(worst, abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z), abs(a.w - b.w)) }
                #expect(worst <= tol, "\(what): the composite changed by \(worst)")
                s.undo()
                #expect(try doc(s).layer(id)?.vectorMask != nil, "\(what): undo brings the vector mask back")
            }
        }
    }

    @Test func vectorMaskCommandsAndCompositing() throws {
        let s = try session(100, 100, 8)
        try s.execute("layer.new.layer")
        let id = try #require(s.active?.activeLayer)
        func px(_ f: [SIMD4<Float>], _ x: Int, _ y: Int) -> SIMD4<Float> { f[y * 100 + x] }
        try s.execute("path.set", ["name": "all", "path": ["subpaths": [["knots": [[0, 0], [100, 0], [100, 100], [0, 100]]]]]])
        try s.execute("path.fill", ["name": "all", "color": "#000000"])
        // Reveal All: nothing hidden.
        try s.execute("layer.vectorMask.revealAll")
        #expect(px(try flatten(s), 80, 80).x < 0.01)
        // Current path → only the left half shows the black layer.
        try s.execute("path.set", ["path": ["subpaths": [["knots": [[0, 0], [50, 0], [50, 100], [0, 100]]]]]])
        try s.execute("layer.vectorMask.currentPath")
        var f = try flatten(s)
        #expect(px(f, 20, 50).x < 0.01 && px(f, 80, 50).x > 0.99)
        // Disable → all black again; toggling re-enables.
        try s.execute("layer.vectorMask.enabled")
        #expect(px(try flatten(s), 80, 50).x < 0.01)
        try s.execute("layer.vectorMask.enabled")
        // Density 50%: the hidden half shows half grey.
        let r = try s.execute("layer.vectorMask.edit", ["density": 50])
        #expect(r["density"] == 50.0)
        #expect(abs(px(try flatten(s), 80, 50).x - 0.5) < 0.01)
        try s.execute("layer.vectorMask.edit", ["density": 100])
        // Hide All.
        try s.execute("layer.vectorMask.hideAll")
        #expect(px(try flatten(s), 20, 50).x > 0.99)
        // Rasterize into the pixel mask: same composite, no vector mask left.
        try s.execute("layer.vectorMask.currentPath")
        let before = try flatten(s)
        try s.execute("layer.rasterize.vectorMask")
        let l = try #require(try doc(s).layer(id))
        #expect(l.vectorMask == nil && l.mask != nil)
        f = try flatten(s)
        #expect(f == before)
        // Delete / undo.
        s.undo()
        try s.execute("layer.vectorMask.delete")
        #expect(try doc(s).layer(id)?.vectorMask == nil)
        #expect(throws: EngineError.self) { try s.execute("layer.vectorMask.delete") }
        s.undo()
        #expect(try doc(s).layer(id)?.vectorMask != nil)
        // Shape layers cannot take a separate vector mask.
        try s.execute("shape.create", ["kind": "rect", "rect": [0, 0, 10, 10]])
        #expect(throws: EngineError.self) { try s.execute("layer.vectorMask.revealAll") }
    }

    @Test func translateVectorsMovesShapesAndMasks() throws {
        let s = try session(100, 100, 8)
        let id = try layerId(s.execute("shape.create", ["kind": "rect", "rect": [10, 10, 20, 20]]))
        try s.edit("Move") { d, _ in
            let snap = d
            d.updateLayer(LayerId(id)) { l in VectorCommands.translateVectors(snap, &l, 5, 0) }
        }
        let sh = try shape(s, id)
        #expect(sh.cache?.contentBounds == PixelRect(x0: 15, y0: 10, x1: 35, y1: 30))
        #expect(sh.live == .rect(rect: SIMD4(15, 10, 20, 20), radii: .zero))
    }

    @Test func allVectorCommandsAreRegistered() {
        let r = CommandRegistry.standard()
        for id in ["shape.create", "shape.edit", "shape.info", "shape.rasterize", "path.set", "path.delete", "path.rename", "path.list", "path.info",
                   "path.toSelection", "select.toWorkPath", "path.fill", "path.stroke", "layer.vectorMask.add", "layer.vectorMask.fromPath",
                   "layer.vectorMask.delete", "layer.vectorMask.edit", "layer.rasterize.vectorMask"] {
            #expect(r.spec(id)?.isAvailable == true, "\(id)")
            #expect(r.spec(id)?.module == "vector_cmds", "\(id)")
        }
        #expect(Set(r.ids).count == r.count, "duplicate command ids")
        #expect(r.specs.filter { $0.module == "vector_cmds" }.count == 38)
    }

    @Test func pathStrokeRejectsOversizedBrushBeforeRendering() throws {
        let s = try session(32, 32, 8)
        try s.execute("path.set", ["name": "work", "path": ["subpaths": [["closed": false, "knots": [[2, 2], [20, 20]]]]]])
        #expect(throws: EngineError.self) { try s.execute("path.stroke", ["size": 1e30]) }
    }

    /// #2537: an exact 600×600 ellipse reported width 601.
    @Test func shapeInfoBoundsOfCurvedShapesAreExact() throws {
        for depth in [8, 16, 32] {
            let s = try session(1920, 1080, depth)
            let cases: [(JSONValue, JSONValue)] = [
                (["kind": "ellipse", "rect": [0, 0, 100, 100], "fill": "#0000ff"], [0, 0, 100, 100]),
                (["kind": "ellipse", "rect": [660, 240, 600, 600], "fill": "#0000ff"], [660, 240, 600, 600]),
                (["kind": "ellipse", "rect": [10.5, 10, 100, 100], "fill": "#0000ff"], [10, 10, 101, 100]),
                (["kind": "rect", "rect": [0, 0, 100, 100], "fill": "#0000ff"], [0, 0, 100, 100]),
            ]
            for (params, want) in cases {
                let id = try layerId(s.execute("shape.create", params))
                let info = try s.execute("shape.info", ["layer": .int(id)])
                #expect(info["bounds"] == want, "\(params) at \(depth)-bit")
            }
        }
    }

    /// Two overlapping 40×40 rectangle shape layers ("Rectangle 1" black below, "Rectangle 2" grey
    /// above) with both selected (#2400).
    fileprivate func twoSelectedRects(_ depth: Int) throws -> (Session, UInt64, UInt64) {
        let s = try session(100, 100, depth)
        let a = try layerId(s.execute("shape.create", ["rect": [10, 10, 40, 40], "fill": "#000000"]))
        let b = try layerId(s.execute("shape.create", ["rect": [30, 30, 40, 40], "fill": "#808080"]))
        try s.execute("layer.select", ["layer": .int(a)])
        try s.execute("layer.select", ["layer": .int(b), "mode": "add"])
        #expect(s.active?.selectedLayers == [LayerId(a), LayerId(b)])
        return (s, a, b)
    }

    @Test func combineShapesMergesTheSelectedShapeLayersIntoTheTopOne() throws {
        for depth in [8, 16, 32] {
            for (cmd, area) in [("layer.combineShapes.unite", 2800.0), ("layer.combineShapes.subtractFrontShape", 1200),
                                ("layer.combineShapes.intersectShapeAreas", 400), ("layer.combineShapes.excludeOverlappingShapes", 2400),
                                ("layer.combineShapes.mergeShapeComponents", 2800)] {
                let (s, a, b) = try twoSelectedRects(depth)
                let before = try doc(s)
                let topFill = try shape(s, b).fill
                let history = try #require(s.active?.history.pastCount)
                let r = try s.execute(cmd)
                #expect(r["layer"]?.uint64Value == b, "\(cmd)")
                let d = try doc(s)
                #expect(d.layer(LayerId(a)) == nil, "\(cmd): the lower shape layer is merged away")
                #expect(d.walk().count == 2, "\(cmd): Background plus the merged shape")
                #expect(d.layer(LayerId(b))?.name == "Rectangle 2")
                let sh = try shape(s, b)
                #expect(abs(alphaSum(sh) - area) < 2, "\(cmd) at \(depth) bits: covers \(alphaSum(sh)) px, not \(area)")
                #expect(sh.fill == topFill, "\(cmd): the top layer's fill")
                #expect(s.active?.activeLayer == LayerId(b))
                #expect(s.active?.selectedLayers == [LayerId(b)])
                #expect(s.active?.history.pastCount == history + 1, "\(cmd): one history step")
                try s.execute("edit.undo")
                #expect(try doc(s) == before, "\(cmd): undo restores both layers")
            }
        }
    }

    @Test func combineShapesKeepsTheSingleLayerBehaviour() throws {
        let (s, a, b) = try twoSelectedRects(8)
        // An explicit layer narrows it to that layer's components.
        try s.execute("shape.create", ["addTo": .int(b), "rect": [50, 50, 10, 10]])
        try s.execute("layer.combineShapes.subtractFrontShape", ["layer": .int(b)])
        #expect(try doc(s).layer(LayerId(a)) != nil)
        #expect(try shape(s, b).path.subpaths[1].op == .subtract)
        #expect(abs(alphaSum(try shape(s, b)) - 1500) < 2)
        // One selected shape layer: the operation applies to its own components.
        try s.execute("layer.select", ["layer": .int(b)])
        try s.execute("layer.combineShapes.unite")
        #expect(try doc(s).layer(LayerId(a)) != nil)
        #expect(abs(alphaSum(try shape(s, b)) - 1600) < 2)
    }

    @Test func combineShapesIgnoresSelectedNonShapeLayers() throws {
        let (s, a, b) = try twoSelectedRects(8)
        let bg = try #require(try doc(s).walk().first?.layer.id)
        try s.execute("layer.select", ["layer": .id(bg), "mode": "add"])
        #expect(s.active?.selectedLayers.count == 3)
        try s.execute("layer.combineShapes.unite")
        let d = try doc(s)
        #expect(d.layer(bg) != nil, "the Background is left alone")
        #expect(d.layer(LayerId(a)) == nil)
        #expect(abs(alphaSum(try shape(s, b)) - 2800) < 2)
    }

    @Test func combineShapesFailsGracefully() throws {
        let (s, a, _) = try twoSelectedRects(8)
        var before = try doc(s)
        let history = s.active?.history.pastCount
        let badParams: [JSONValue] = [["layer": 999_999], ["layer": .int(a), "subpath": 99], ["subpath": 99], ["tolerance": "x", "layer": 999_999]]
        for cmd in ["layer.combineShapes.unite", "layer.combineShapes.subtractFrontShape", "layer.combineShapes.intersectShapeAreas",
                    "layer.combineShapes.excludeOverlappingShapes", "layer.combineShapes.mergeShapeComponents"] {
            for p in badParams {
                if cmd.hasSuffix("mergeShapeComponents") && p["subpath"] != nil { continue }
                #expect(throws: EngineError.self, "\(cmd) \(p)") { try s.execute(cmd, p) }
                #expect(try doc(s) == before, "\(cmd) \(p)")
            }
        }
        #expect(s.active?.history.pastCount == history)
        // Locked layers refuse the merge without touching the document.
        try s.execute("layer.lockLayers", ["all": true])
        #expect(try doc(s).effectiveLocks(LayerId(a)).all)
        before = try doc(s)
        #expect(throws: EngineError.self) { try s.execute("layer.combineShapes.unite") }
        #expect(try doc(s) == before)
    }

    // Swift-only checks of the ported geometry and JSON forms.

    @Test func parsePathAcceptsCompactAndSerdeForms() throws {
        let compact: JSONValue = ["subpaths": [["closed": false, "op": "xor", "knots": [[1, 2], ["anchor": ["x": 3, "y": 4], "inCtrl": [5, 6], "smooth": true]]]],
                                  "fillRule": "even-odd", "inverted": true]
        let p = try VectorCommands.parsePath(compact)
        #expect(p.subpaths[0].op == .exclude && !p.subpaths[0].closed && p.fillRule == .evenOdd && p.inverted)
        #expect(p.subpaths[0].knots[1] == Knot(anchor: PCPoint(3, 4), inCtrl: PCPoint(5, 6), outCtrl: PCPoint(3, 4), smooth: true))
        // PCDocument's Codable form is photocraft's serde form.
        let serde = JSONValue.encoded(p)
        #expect(try VectorCommands.parsePath(serde) == p)
        #expect(try VectorCommands.parsePath(VectorCommands.pathJSON(p)) == p)
        #expect(throws: VectorCommands.GeometryError.self) { try VectorCommands.parsePath(["subpaths": [["knots": [5]]]]) }
    }
}
