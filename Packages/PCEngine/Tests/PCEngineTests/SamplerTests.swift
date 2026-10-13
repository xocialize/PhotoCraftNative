// Port of photocraft-engine (crates/engine/src/sampler_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct SamplerTests {
    /// A 100×80 white document.
    func session() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 100, "height": 80, "background": "white"])
        return s
    }

    func list(_ s: Session) throws -> JSONValue { try s.execute("view.colorSamplers.list") }
    func points(_ s: Session) throws -> [JSONValue] { try list(s)["samplers"]?.arrayValue ?? [] }

    /// A crop-like canvas change the tests can make without the crop module: the canvas becomes
    /// `size` and the points move by `map` (as `image.crop` declares through `SamplerMap`).
    func canvasChange(_ s: Session, _ size: PixelSize, _ map: PCAffine?) throws {
        if let map { SamplerMap.set(s, map) }
        try s.edit("Crop") { doc, _ in doc.size = size }
    }

    @Test func addReadsTheCompositePixelAndListsIt() throws {
        let s = try session()
        let r = try s.execute("view.colorSamplers.add", ["x": 5, "y": 6])
        #expect(r["index"] == 0)
        #expect(r["count"] == 1)
        #expect(r["point"]?["number"] == 1)
        #expect(r["point"]?["position"] == [5.0, 6.0])
        #expect(r["point"]?["rgb"] == [255, 255, 255])
        #expect(r["point"]?["cmyk"] == [0, 0, 0, 0])
        let l = try list(s)
        #expect(l["max"] == 10)
        #expect(l["samplers"]?.arrayValue?.count == 1)
        #expect(l["samplers"]?[0]?["position"] == [5.0, 6.0])
    }

    @Test func fractionalClicksFloorToThePixel() throws {
        let s = try session()
        let r = try s.execute("view.colorSamplers.add", ["x": 5.9, "y": 6.1])
        #expect(r["point"]?["position"] == [5.0, 6.0])
    }

    @Test func addReadsAnActualPaintedPixel() throws {
        let s = try session()
        func paint(_ c: SIMD4<Float>) throws {
            try s.edit("paint") { doc, _ in
                _ = doc.withRaster(of: doc.layers[0].id) { $0.fill(PixelRect(x0: 3, y0: 3, x1: 4, y1: 4), with: $0.format.components(fromRGBA: c)) }
            }
        }
        try paint(SIMD4(0, 0, 0, 1))
        let r = try s.execute("view.colorSamplers.add", ["x": 3, "y": 3])
        #expect(r["point"]?["rgb"] == [0, 0, 0])
        #expect(r["point"]?["cmyk"] == [0, 0, 0, 100])
        // Painting over the point changes its readout (the list is computed live).
        try paint(SIMD4(1, 0, 0, 1))
        #expect(try points(s)[0]["rgb"] == [255, 0, 0])
    }

    @Test func tenPointsThenTheLimit() throws {
        let s = try session()
        for i in 0..<10 { try s.execute("view.colorSamplers.add", ["x": .int(i), "y": 0]) }
        #expect(try points(s).count == 10)
        do {
            try s.execute("view.colorSamplers.add", ["x": 20, "y": 0])
            Issue.record("expected the limit")
        } catch {
            #expect("\(error)".contains("limit"), "\(error)")
        }
        #expect(try points(s).count == 10)
    }

    @Test func moveDeleteAndClear() throws {
        let s = try session()
        try s.execute("view.colorSamplers.add", ["x": 5, "y": 5])
        try s.execute("view.colorSamplers.add", ["x": 50, "y": 50])
        let r = try s.execute("view.colorSamplers.move", ["index": 0, "x": 10, "y": 20])
        #expect(r["point"]?["position"] == [10.0, 20.0])
        #expect(try points(s)[0]["position"] == [10.0, 20.0])
        try s.execute("view.colorSamplers.delete", ["index": 1])
        #expect(try points(s).count == 1)
        #expect(try points(s)[0]["position"] == [10.0, 20.0])
        let c = try s.execute("view.colorSamplers.clear")
        #expect(c["deleted"] == 1)
        #expect(try points(s).isEmpty)
    }

    @Test func placingAndMovingAddNoHistoryAndChangeNoPixels() throws {
        let s = try session()
        let before = s.active?.doc.layers[0].surface?.pixel(x: 5, y: 5)
        let past = s.active?.history.pastCount
        try s.execute("view.colorSamplers.add", ["x": 5, "y": 5])
        try s.execute("view.colorSamplers.move", ["index": 0, "x": 9, "y": 9])
        try s.execute("view.colorSamplers.delete", ["index": 0])
        #expect(s.active?.history.pastCount == past, "no history steps")
        #expect(s.active?.doc.layers[0].surface?.pixel(x: 5, y: 5) == before, "no pixels changed")
        #expect(s.active?.isDirty == false, "a clean document stays clean")
    }

    @Test func pointsBelongToTheirDocument() throws {
        let s = try session()
        try s.execute("view.colorSamplers.add", ["x": 5, "y": 5])
        try s.execute("file.new", ["width": 40, "height": 40, "background": "white"])
        #expect(try points(s).isEmpty, "the new document has no points")
        try s.execute("document.activate", ["document": 0])
        #expect(try points(s).count == 1, "the first document kept its point")
        try s.execute("file.close", ["document": 1])
        #expect(try points(s).count == 1)
        try s.execute("file.close", ["document": 0])
        #expect(throws: EngineError.self, "no document open") { try s.execute("view.colorSamplers.list") }
    }

    @Test func aCropDropsPointsOutsideTheNewCanvas() throws {
        let s = try session()
        try s.execute("view.colorSamplers.add", ["x": 5, "y": 5])
        try s.execute("view.colorSamplers.add", ["x": 50, "y": 50])
        try canvasChange(s, PixelSize(width: 10, height: 10), .identity)
        let p = try points(s)
        #expect(p.count == 1, "the outside point was removed")
        #expect(p.first?["position"] == [5.0, 5.0])
        #expect(SamplerCommands.takeRemoved(s) == 1, "one removed point reported")
        #expect(SamplerCommands.takeRemoved(s) == 0, "reported once")
    }

    @Test func aCropMovesPointsWithTheirPixels() throws {
        let s = try session()
        try s.execute("view.colorSamplers.add", ["x": 50, "y": 40])
        try canvasChange(s, PixelSize(width: 20, height: 20), .translate(-40, -30))
        let p = try points(s)
        #expect(p.count == 1)
        #expect(p.first?["position"] == [10.0, 10.0], "moved by (-40, -30)")
        #expect(SamplerCommands.takeRemoved(s) == 0, "nothing removed")
    }

    @Test func aSizeChangeWithoutAMapDropsWhatIsOutside() throws {
        let s = try session()
        try s.execute("view.colorSamplers.add", ["x": 5, "y": 5])
        try s.execute("view.colorSamplers.add", ["x": 90, "y": 5])
        try canvasChange(s, PixelSize(width: 50, height: 80), nil)
        #expect(try points(s).map { $0["position"] } == [[5.0, 5.0]])
    }

    @Test func aRightAngleRotationMovesPoints() throws {
        // 90° clockwise about the centre: the doc centre stays put.
        let s = try session()
        try s.execute("view.colorSamplers.add", ["x": 50, "y": 40])
        try s.execute("image.imageRotation.90cw")
        let p = try points(s)
        #expect(p.count == 1)
        let pos = p.first?["position"]?.arrayValue?.compactMap(\.doubleValue) ?? []
        // The new canvas is 80×100, so the centre is (40, 50).
        #expect(pos.count == 2 && abs(pos[0] - 40) < 1e-6 && abs(pos[1] - 50) < 1e-6, "\(pos)")
    }

    @Test func aStaleMapFromAFailedCanvasEditIsNotApplied() throws {
        let s = try session()
        try s.execute("view.colorSamplers.add", ["x": 50, "y": 40])
        SamplerMap.set(s, .translate(-40, -30))
        // The next command (an edit that changes no canvas) must not move the points.
        try s.execute("layer.new.layer")
        #expect(try points(s).first?["position"] == [50.0, 40.0])
    }

    @Test func badParamsAndNoDocumentAreErrorsNotPanics() throws {
        let e = Session()
        for id in ["view.colorSamplers.add", "view.colorSamplers.move", "view.colorSamplers.delete", "view.colorSamplers.clear", "view.colorSamplers.list"] {
            #expect(throws: EngineError.self, "\(id) without a document") { try e.execute(id, [:]) }
        }
        let s = try session()
        let cases: [(String, JSONValue)] = [
            ("view.colorSamplers.add", [:]),
            ("view.colorSamplers.add", ["x": "a", "y": 1]),
            ("view.colorSamplers.add", ["x": 1e300, "y": 1]),
            ("view.colorSamplers.add", ["x": 5, "y": .number(.nan)]),
            ("view.colorSamplers.add", ["x": -1, "y": 5]),
            ("view.colorSamplers.add", ["x": 5, "y": 1000]),
            ("view.colorSamplers.move", ["index": 0, "x": 1, "y": 1]),
            ("view.colorSamplers.delete", ["index": 0]),
            ("view.colorSamplers.delete", [:]),
            ("view.colorSamplers.move", ["index": 4_294_967_296, "x": 1, "y": 1]),
        ]
        for (id, p) in cases {
            #expect(throws: EngineError.self, "\(id) \(p)") { try s.execute(id, p) }
        }
        // An off-canvas point is refused and places nothing.
        #expect(try points(s).isEmpty)
    }

    @Test func deviceCMYKMatchesTheInfoPanelFormula() {
        #expect(SamplerCommands.deviceCMYK(1, 1, 1) == [0, 0, 0, 0])
        #expect(SamplerCommands.deviceCMYK(0, 0, 0) == [0, 0, 0, 100])
        #expect(SamplerCommands.deviceCMYK(1, 0, 0) == [0, 100, 100, 0])
        #expect(SamplerCommands.deviceCMYK(0.5, 0.5, 0.5) == [0, 0, 0, 50])
    }

    @Test func pointsWorkAtEveryDepthAndMode() throws {
        for (mode, depth) in [("rgb", 8), ("rgb", 16), ("rgb", 32), ("grayscale", 8), ("cmyk", 8), ("lab", 8)] {
            let s = Session()
            try s.execute("file.new", ["width": 20, "height": 20, "mode": .string(mode), "depth": .int(depth), "background": "white"])
            let r = try s.execute("view.colorSamplers.add", ["x": 10, "y": 10])
            let rgb = r["point"]?["rgb"]?.arrayValue ?? []
            #expect(rgb.count == 3)
            #expect(rgb.allSatisfy { ($0.intValue ?? -1) >= 0 && ($0.intValue ?? 256) <= 255 }, "\(mode) \(depth): \(rgb)")
        }
    }

    @Test func documentHelpersAreNotDisturbed() {
        var d = Document(name: "t", size: PixelSize(width: 4, height: 4), mode: .rgb, depth: .u8)
        d.layers.append(Layer.raster("Background", format: d.pixelFormat))
        #expect(SamplerCommands.pixel(d, 0, 0) == SIMD2(0, 0))
        #expect(SamplerCommands.pixel(d, 3.9, 3.9) == SIMD2(3, 3))
        #expect(SamplerCommands.pixel(d, 4, 0) == nil)
    }
}
