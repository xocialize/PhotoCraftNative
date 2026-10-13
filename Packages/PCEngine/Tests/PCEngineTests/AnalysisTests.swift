// Port of photocraft-engine (crates/engine/src/analysis_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// `straighten_layer_and_image`: the layer half runs `edit.transform` (transform_cmds) and is checked
// once that command is available; the Background half (rotate + crop) always runs. The scale-marker
// tests run without the label unless `type.create` is available (type_cmds), checked in
// `scaleMarkerWithText`.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct AnalysisTests {
    typealias A = AnalysisCommands

    func session(_ w: Int, _ h: Int, _ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": .int(w), "height": .int(h), "depth": .int(depth), "background": "white"])
        return s
    }

    func d(_ s: Session) -> Document { s.active!.doc }
    func log(_ s: Session) -> [A.LogRow] { s.state[A.Key.self].log }

    @Test func recordMeasurementsRefusesAnAreaTooLargeToMeasure() throws {
        // #933: a legal 65536×65536 document overflowed a u32 pixel count.
        let s = Session()
        try s.execute("file.new", ["width": 65536, "height": 65536, "background": "transparent"])
        do {
            try s.execute("image.analysis.recordMeasurements", ["source": "selection"])
            Issue.record("should fail")
        } catch {
            #expect("\(error)".contains("too large to measure"), "\(error)")
        }
        #expect(log(s).isEmpty)
        // A failed measurement does not use up a label: the next one is still "Measurement 1".
        try s.execute("file.new", ["width": 20, "height": 20, "background": "white"])
        let r = try s.execute("image.analysis.recordMeasurements", ["source": "selection"])
        #expect(r["rows"]?[0]?["values"]?["label"] == "Measurement 1")
        #expect(r["rows"]?[0]?["values"]?["area"] == 400.0)
    }

    @Test func measurementScaleSetQueryDefaultAndUndo() throws {
        let s = try session(50, 40, 8)
        #expect(try s.execute("image.analysis.setMeasurementScale", .object([:]))["default"] == true)
        let r = try s.execute("image.analysis.setMeasurementScale", ["pixelLength": 100, "logicalLength": 2.5, "units": "cm"])
        #expect(r["factor"] == 0.025)
        #expect(r["text"] == "100 pixels = 2.5000 cm")
        #expect(d(s).measurement.scale.units == "cm")
        #expect(throws: EngineError.self) { try s.execute("image.analysis.setMeasurementScale", ["pixelLength": 0]) }
        #expect(throws: EngineError.self) { try s.execute("image.analysis.setMeasurementScale", ["units": " "]) }
        #expect(throws: EngineError.self) { try s.execute("image.analysis.setMeasurementScale", ["preset": "bogus"]) }
        try s.execute("image.analysis.setMeasurementScale", ["preset": "default"])
        #expect(d(s).measurement.scale.isDefault)
        #expect(s.undo())
        #expect(d(s).measurement.scale.units == "cm")
    }

    @Test func featuresAreaPerimeterCircularity() {
        // A 10×10 square and a 1-pixel diagonal line of 5 pixels (one 8-connected feature).
        var (w, h) = (30, 20)
        var mask = [Bool](repeating: false, count: w * h)
        for y in 2..<12 { for x in 2..<12 { mask[y * w + x] = true } }
        for i in 0..<5 { mask[(5 + i) * w + 20 + i] = true }
        let gray: [Float] = (0..<(w * h)).map { $0 % 2 == 0 ? 0 : 1 }
        var f = A.measureFeatures(mask, gray, w, h, origin: (100, 200), range: 255)
        #expect(f.count == 2)
        #expect(f[0].area == 100)
        #expect(f[0].bounds == PixelRect(x0: 102, y0: 202, x1: 112, y1: 212))
        // Straight edges exact, corners cut by √½: 4·9 + 4·√½.
        #expect(abs(f[0].perimeter - (36 + 4 * 0.5.squareRoot())) < 1e-9, "\(f[0].perimeter)")
        #expect(f[0].circularity > 0.75 && f[0].circularity < 0.9)
        #expect(f[0].grayMin == 0)
        #expect(f[0].grayMax == 255)
        #expect(abs(f[0].grayMean - 127.5) < 3)
        #expect(f[0].histogram.reduce(0, +) == 100)
        #expect(f[1].area == 5)
        // A disc's circularity approaches 1.
        (w, h) = (101, 101)
        mask = (0..<(w * h)).map { hypot(Double($0 % w) - 50, Double($0 / w) - 50) <= 40 }
        f = A.measureFeatures(mask, [Float](repeating: 0.5, count: w * h), w, h, origin: (0, 0), range: 1)
        #expect(f.count == 1)
        // Digital discs read ≈0.89 (the 8-direction contour is ~5 % long), as in ImageJ.
        #expect(f[0].circularity > 0.85, "\(f[0].circularity)")
        #expect(abs(f[0].perimeter / (2 * Double.pi * 40) - 1) < 0.08, "\(f[0].perimeter)")
        #expect(abs(f[0].grayMedian - 0.5) < 1e-4)
    }

    @Test func recordSelectionRowsRespectScaleAndDataPoints() throws {
        for depth in [8, 16, 32] {
            let s = try session(64, 48, depth)
            // Two separate rectangles.
            try s.execute("select.rect", ["x": 4, "y": 4, "width": 10, "height": 10])
            try s.execute("select.rect", ["x": 30, "y": 20, "width": 20, "height": 5, "mode": "add"])
            try s.execute("image.analysis.setMeasurementScale", ["pixelLength": 2, "logicalLength": 1, "units": "mm"])
            let r = try s.execute("image.analysis.recordMeasurements", ["dateTime": "2026-10-01T00:00:00Z"])
            #expect(r["source"] == "selection")
            let rows = try #require(r["rows"]?.arrayValue)
            #expect(rows.count == 3, "summary + 2 features")
            let sum = try #require(rows[0]["values"])
            #expect(sum["count"] == 2)
            #expect(sum["area"] == .number((100.0 + 100.0) * 0.25))
            #expect(sum["scaleUnits"] == "mm")
            #expect(sum["source"] == "Selection")
            // White background: gray max reads as white in the depth's range.
            let white: Double = depth == 8 ? 255 : (depth == 16 ? 32768 : 1)
            #expect(abs((sum["grayMean"]?.doubleValue ?? 0) - white) < white * 0.01, "\(depth): \(sum.serialized())")
            #expect(rows[1]["values"]?["label"] == "Feature 1")
            #expect(rows[2]["values"]?["width"] == 10.0)
            #expect(rows[2]["values"]?["height"] == 2.5)
        }
        // Data points filter the columns.
        let s = try session(20, 20, 8)
        try s.execute("image.analysis.selectDataPoints", ["selection": ["label", "area"]])
        let r = try s.execute("image.analysis.recordMeasurements", ["source": "selection"])
        let v = try #require(r["rows"]?[0]?["values"]?.objectValue)
        #expect(v.keys.sorted() == ["area", "label"])
        #expect(v["area"] == 400.0, "no selection: the whole image")
        let r2 = try s.execute("image.analysis.selectDataPoints", ["selection": ["perimeter": true, "label": false]])
        #expect(r2["dataPoints"]?["selection"] == ["area", "perimeter"])
        #expect(throws: EngineError.self) { try s.execute("image.analysis.selectDataPoints", ["ruler": ["area"]]) }
        try s.execute("image.analysis.selectDataPoints", ["reset": true])
        #expect(s.state[A.Key.self].dataPoints == A.DataPoints())
    }

    @Test func rulerProtractorAndRecord() throws {
        let s = try session(100, 100, 8)
        let r = try s.execute("image.analysis.rulerTool", ["start": [10, 50], "end": [40, 10]])
        let i = try #require(r["info"])
        #expect(i["l1"] == 50.0)
        #expect(i["w"] == 30.0)
        #expect(i["h"] == -40.0)
        #expect(abs((i["angle"]?.doubleValue ?? 0) - 53.1301) < 1e-3)
        // The ruler doesn't add history and doesn't dirty the document.
        #expect(s.active!.history.pastCount == 0)
        #expect(!s.active!.isDirty)
        // Protractor: a second arm straight down from the vertex.
        let r2 = try s.execute("image.analysis.rulerTool", ["protractor": [10, 90]])
        #expect(abs((r2["info"]?["angle"]?.doubleValue ?? 0) - (180 - 36.8699)) < 1e-3, "\(r2.serialized())")
        #expect(r2["info"]?["l2"] == 40.0)
        try s.execute("image.analysis.setMeasurementScale", ["pixelLength": 10, "logicalLength": 1, "units": "cm"])
        let r3 = try s.execute("image.analysis.recordMeasurements", .object([:]))
        #expect(r3["source"] == "ruler")
        #expect(r3["rows"]?[0]?["values"]?["length"] == 5.0)
        #expect(throws: EngineError.self) { try s.execute("image.analysis.rulerTool", ["start": [1, 1]]) }
        try s.execute("image.analysis.rulerTool", ["clear": true])
        #expect(d(s).measurement.ruler == nil)
        #expect(!s.isEnabled("image.analysis.straightenLayer"))
    }

    @Test func straightenLayerAndImage() throws {
        // A layer: rotated about the canvas centre, canvas unchanged (Free Transform, transform_cmds).
        if Session().registry.spec("edit.transform")?.availability.reason == nil {
            let s = try session(80, 60, 8)
            try s.execute("layer.new.layer")
            try s.execute("select.rect", ["x": 10, "y": 28, "width": 60, "height": 4])
            _ = try? s.execute("edit.fill", ["color": "#000000"])
            try s.execute("select.deselect")
            try s.execute("image.analysis.rulerTool", ["start": [10, 30], "end": [70, 25]])
            let before = s.active!.history.pastCount
            let r = try s.execute("image.analysis.straightenLayer")
            #expect(r["cropped"] == false)
            #expect(abs((r["angle"]?.doubleValue ?? 0) - 4.7636) < 1e-3, "\(r.serialized())")
            #expect(s.active!.history.pastCount == before + 1, "one history step")
            #expect(d(s).size.width == 80)
            #expect(d(s).measurement.ruler == nil)
        }
        // The Background: rotate the canvas and crop to the image.
        let s = try session(80, 60, 16)
        try s.execute("image.analysis.rulerTool", ["start": [0, 0], "end": [40, 40]])
        let before = s.active!.history.pastCount
        let r = try s.execute("image.analysis.straightenLayer")
        #expect(r["cropped"] == true)
        #expect(abs(r["angle"]?.doubleValue ?? 0) == 45)
        let nd = d(s)
        #expect(nd.size.width < 80 && nd.size.height < 60)
        #expect(nd.measurement.ruler == nil)
        #expect(s.active!.history.pastCount == before + 1, "one history step")
        #expect(s.undo())
        #expect(d(s).size.width == 80)
    }

    @Test func inscribedRect() {
        var (w, h) = A.inscribed(100, 50, 0)
        #expect(abs(w - 100) < 1e-9 && abs(h - 50) < 1e-9)
        (w, h) = A.inscribed(100, 100, Double.pi / 4)
        #expect(abs(w - 70.710678) < 1e-4 && abs(h - 70.710678) < 1e-4)
        #expect(abs(A.straightenAngle(Ruler(start: SIMD2(10, 30), end: SIMD2(70, 25))) - 4.7636) < 1e-3)
        #expect(abs(abs(A.straightenAngle(Ruler(start: SIMD2(0, 0), end: SIMD2(40, 40)))) - 45) < 1e-9)
    }

    @Test func countGroupsMarkersAndUndo() throws {
        let s = try session(100, 100, 8)
        #expect(try s.execute("image.analysis.countTool", .object([:]))["total"] == 0)
        let r = try s.execute("count.add", ["x": 10, "y": 10])
        #expect(r["number"] == 1)
        #expect(r["groups"]?[0]?["name"] == "Count Group 1")
        try s.execute("count.add", ["x": 20, "y": 20])
        try s.execute("count.newGroup", ["name": "Cells", "color": "#00ff00"])
        let r2 = try s.execute("count.add", ["x": 50, "y": 50])
        #expect(r2["activeGroup"] == 1)
        #expect(r2["groups"]?[1]?["count"] == 1)
        #expect(r2["total"] == 3)
        // Remove by position, move by index.
        try s.execute("count.remove", ["x": 21, "y": 19])
        #expect(d(s).measurement.countGroups[0].points == [SIMD2(10, 10)])
        try s.execute("count.move", ["group": 0, "index": 0, "to": [12, 13]])
        #expect(d(s).measurement.countGroups[0].points[0] == SIMD2(12, 13))
        #expect(throws: EngineError.self) { try s.execute("count.remove", ["x": 90, "y": 90]) }
        try s.execute("count.setGroup", ["group": 0, "markerSize": 50, "labelSize": 20, "visible": false, "name": "Spots"])
        let g = d(s).measurement.countGroups[0]
        #expect(g.markerSize == 10 && g.labelSize == 20 && !g.visible && g.name == "Spots")
        // Record counts.
        #expect(try s.execute("image.analysis.recordMeasurements", ["source": "count"])["rows"]?[0]?["values"]?["count"] == 2)
        try s.execute("count.clear", .object([:]))
        #expect(d(s).measurement.countTotal == 1, "clears the active group only")
        try s.execute("count.clear", ["group": "all"])
        #expect(d(s).measurement.countTotal == 0)
        #expect(s.undo())
        #expect(d(s).measurement.countTotal == 1)
        try s.execute("count.deleteGroup", ["group": 1])
        #expect(d(s).measurement.countGroups.count == 1)
        #expect(d(s).measurement.activeCountGroup == 0)
        try s.execute("count.setGroup", ["group": 0])
        #expect(throws: EngineError.self) { try s.execute("count.setGroup", ["group": 7]) }
        #expect(throws: EngineError.self) { try s.execute("count.add", ["x": 1]) }
    }

    @Test func logDeleteAndCsvExport() throws {
        let s = try session(10, 10, 8)
        #expect(!s.isEnabled("measurementLog.delete"))
        try s.execute("image.analysis.recordMeasurements", ["dateTime": "t"])
        try s.execute("image.analysis.rulerTool", ["start": [0, 0], "end": [3, 4]])
        try s.execute("image.analysis.recordMeasurements", ["source": "ruler", "dateTime": "t"])
        #expect(try s.execute("measurementLog.list", .object([:]))["rows"]?.arrayValue?.count == 2)
        let csv = try #require(try s.execute("measurementLog.export", .object([:]))["csv"]?.stringValue)
        let lines = csv.split(separator: "\n")
        try #require(lines.count == 3)
        let header = lines[0]
        #expect(header.hasPrefix("Label,Date and Time,Document,Source,Scale"))
        #expect(header.contains("Length") && header.contains("Gray Value (Mean)"))
        #expect(lines[1].hasPrefix("Measurement 1,t,"))
        #expect(lines[2].contains(",5.0,"), "\(csv)")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pc-log-\(ProcessInfo.processInfo.processIdentifier).csv").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try s.execute("measurementLog.export", ["path": .string(path), "rows": [2]])["rows"] == 1)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        try s.execute("measurementLog.delete", ["rows": [1]])
        #expect(log(s).count == 1)
        #expect(throws: EngineError.self) { try s.execute("measurementLog.delete", .object([:])) }
        try s.execute("measurementLog.delete", ["all": true])
        #expect(log(s).isEmpty)
        #expect(A.csvField(#"a,"b""#) == #""a,""b""""#)
    }

    func hasTypeCreate(_ s: Session) -> Bool { s.registry.spec("type.create")?.isAvailable == true }

    @Test func placeScaleMarkerBuildsOneGroupInOneStep() throws {
        let s = try session(400, 300, 8)
        let text = hasTypeCreate(s)
        try s.execute("image.analysis.setMeasurementScale", ["pixelLength": 50, "logicalLength": 1, "units": "cm"])
        let before = s.active!.history.pastCount
        let r = try s.execute("image.analysis.placeScaleMarker", ["color": "black", "displayText": .bool(text)])
        #expect(s.active!.history.pastCount == before + 1)
        // Nice length near width/5 = 80 px = 1.6 cm → 1 cm = 50 px.
        #expect(r["label"] == "1 cm")
        #expect(r["pixels"] == 50.0)
        let g = try #require(d(s).layers.last)
        #expect(g.name == "Measurement Scale Marker")
        let kids = try #require(g.children)
        #expect(kids.count == (text ? 2 : 1), "bar (+ text)")
        let bar = try #require(kids.first { $0.name == "Scale Bar" })
        let b = try #require(bar.surface?.contentBounds)
        #expect(b.width == 50)
        #expect(b.y1 < 300)
        // Without text, white, on top.
        let r2 = try s.execute("image.analysis.placeScaleMarker", ["length": 2, "displayText": false, "color": "white", "textPosition": "top"])
        #expect(r2["pixels"] == 100.0)
        #expect(r2["text"] == .null)
        #expect(throws: EngineError.self, "wider than the image") { try s.execute("image.analysis.placeScaleMarker", ["length": 100]) }
        #expect(throws: EngineError.self) { try s.execute("image.analysis.placeScaleMarker", ["color": "red"]) }
        #expect(s.undo())
        #expect(s.undo())
        #expect(d(s).layers.allSatisfy { $0.name != "Measurement Scale Marker" })
    }

    @Test func scaleMarkerWithText() throws {
        let s = try session(400, 300, 8)
        if hasTypeCreate(s) {
            let r = try s.execute("image.analysis.placeScaleMarker", .object([:]))
            #expect(r["text"] != .null)
            #expect(d(s).layers.last?.children?.count == 2)
        } else {
            // Without type.create the whole marker is taken back: no group, no step, no journal.
            let (past, journal) = (s.active!.history.pastCount, s.journal.count)
            #expect(throws: EngineError.self) { try s.execute("image.analysis.placeScaleMarker", .object([:])) }
            #expect(s.active!.history.pastCount == past)
            #expect(s.journal.count == journal)
            #expect(d(s).layers.allSatisfy { $0.name != "Measurement Scale Marker" })
            #expect(s.active!.activeLayer.flatMap { d(s).layer($0) } != nil)
        }
    }

    @Test func placeScaleMarkerOnAShortDocumentErrorsWithoutTrapping() throws {
        // A document under 8 px tall inverted the bar-height clamp and panicked (#932).
        let cases: [(Int, Int, JSONValue)] = [
            (100, 4, [:]), (100, 1, [:]), (100, 7, ["displayText": false, "textPosition": "top"]), (300_000, 3, ["fontSize": 1000]),
            (2, 7, ["length": 1]), (7, 7, ["length": 7, "fontSize": 1]),
        ]
        for (w, h0, p) in cases {
            for h in [h0, 1, 2, 3, 5, 6] {
                let s = try session(w, h, 8)
                let before = s.active!.history.pastCount
                do {
                    try s.execute("image.analysis.placeScaleMarker", p)
                    Issue.record("\(w)x\(h) should fail")
                } catch {
                    #expect("\(error)".contains("tall"), "\(w)x\(h): \(error)")
                }
                #expect(s.active!.history.pastCount == before, "\(w)x\(h): nothing added")
                #expect(d(s).layers.allSatisfy { $0.name != "Measurement Scale Marker" })
            }
        }
        // Control: 8 px is the shortest that fits, and tall, narrow or roomy documents still get a
        // marker that lies on the canvas.
        let ok: [(Int, Int, JSONValue)] = [(100, 8, [:]), (100, 100, [:]), (20, 4000, [:]), (2, 8, ["length": 2])]
        for (w, h, p0) in ok {
            let s = try session(w, h, 8)
            let p = hasTypeCreate(s) ? p0 : p0.setting("displayText", false)
            let r = try s.execute("image.analysis.placeScaleMarker", p)
            let b = try #require(r["barRect"]?.arrayValue).compactMap(\.intValue)
            #expect(0 <= b[0] && b[0] < b[2] && b[2] <= w, "\(w)x\(h): bar on the canvas: \(r.serialized())")
            #expect(0 <= b[1] && b[1] < b[3] && b[3] <= h, "\(w)x\(h): bar on the canvas: \(r.serialized())")
            #expect(s.active!.history.pastCount == 1)
            let bar = try #require(d(s).layers.last?.children?.first { $0.name == "Scale Bar" })
            #expect(Double(bar.surface?.contentBounds.width ?? -1) == r["pixels"]?.doubleValue, "\(w)x\(h)")
        }
    }

    @Test func analysisInfoAndCmykDocument() throws {
        let s = Session()
        try s.execute("file.new", ["width": 30, "height": 20, "mode": "cmyk", "background": "white"])
        #expect(d(s).mode == .cmyk)
        try s.execute("count.add", ["x": 3, "y": 4])
        #expect(try s.execute("image.analysis.recordMeasurements", ["source": "selection"])["rows"]?[0]?["values"]?["area"] == 600.0)
        let r = try s.execute("image.analysis.info", .object([:]))
        #expect(r["count"]?["total"] == 1)
        #expect(r["logRows"] == 1)
    }

    @Test func nowIsoShape() {
        let t = A.nowISO(Date())
        #expect(t.count == 20, "\(t)")
        #expect(t.hasSuffix("Z") && Array(t)[4] == "-")
        #expect(A.nowISO(Date(timeIntervalSince1970: 1_790_000_000)) == "2026-09-21T14:13:20Z")
        #expect(A.nowISO(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
    }
}
