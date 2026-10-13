// Port of photocraft-engine (crates/engine/src/magnetic_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCEngine
import PCFoundation
import Testing

@Suite struct MagneticCommandsTests {
    /// A black 40×40 square at (40, 30) on a white 120×100 background.
    func session() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 120, "height": 100])
        try s.edit("paint") { doc, _ in
            doc.withRaster(of: doc.layers[0].id) { bg in
                bg.fill(PixelRect(x0: 0, y0: 0, x1: 120, y1: 100), with: bg.format.components(fromRGBA: SIMD4(1, 1, 1, 1)))
                bg.fill(PixelRect(x0: 40, y0: 30, x1: 80, y1: 70), with: bg.format.components(fromRGBA: SIMD4(0, 0, 0, 1)))
            }
        }
        return s
    }

    func coverage(_ s: Session, _ x: Int32, _ y: Int32) -> Float { s.active?.doc.selection?.sampleChannel(x: x, y: y, 0) ?? 0 }

    func selectedArea(_ s: Session) -> Float {
        var sum: Float = 0
        for y in 0..<100 { for x in 0..<120 { sum += coverage(s, Int32(x), Int32(y)) } }
        return sum
    }

    /// Rough points near the square's corners, some inside and some outside it.
    static let rough: JSONValue = [[43.0, 33.0], [77.0, 27.0], [83.0, 72.0], [37.0, 66.0]]

    @Test func roughPointsSelectTheShapeAlongItsEdges() throws {
        let s = try session()
        let r = try s.execute("select.magneticLasso", ["points": Self.rough])
        #expect(r["selected"] == true)
        #expect((r["points"]?.uint64Value ?? 0) >= 4, "\(r.serialized())")
        let area = selectedArea(s)
        #expect(abs(area - 1600) < 40, "the square's area, not the rough quadrilateral's: \(area)")
        for (x, y) in [(Int32(60), Int32(50)), (41, 31), (78, 68), (41, 68), (78, 31)] {
            #expect(coverage(s, x, y) > 0.99, "(\(x), \(y)) inside")
        }
        for (x, y) in [(Int32(38), Int32(50)), (81, 50), (60, 28), (60, 71), (36, 66), (82, 71)] {
            #expect(coverage(s, x, y) < 0.01, "(\(x), \(y)) outside")
        }
        #expect(s.active?.history.entries.last == "Magnetic Lasso")
        // One step: Undo takes it all back.
        try s.execute("edit.undo")
        #expect(s.active?.doc.selection == nil)
    }

    @Test func modesAndAGivenOutline() throws {
        let s = try session()
        // `trace: false` selects the outline as given, like the tool's own commit.
        try s.execute("select.magneticLasso", ["points": [[0, 0], [20, 0], [0, 20]], "trace": false])
        #expect([coverage(s, 2, 2), coverage(s, 18, 18)] == [1, 0])
        try s.execute("select.magneticLasso", ["points": Self.rough, "mode": "add"])
        #expect([coverage(s, 2, 2), coverage(s, 60, 50)] == [1, 1])
        try s.execute("select.magneticLasso", ["points": Self.rough, "mode": "subtract", "close": "straight", "width": 20, "contrast": 50])
        #expect([coverage(s, 2, 2), coverage(s, 60, 50)] == [1, 0])
        try s.execute("select.magneticLasso", ["points": Self.rough, "feather": 4])
        let edge = coverage(s, 40, 50)
        #expect(edge > 0.2 && edge < 0.8, "feathered: \(edge)")
    }

    @Test func edgesComeFromTheActivePixelLayer() throws {
        let s = try session()
        try s.execute("layer.new.layer")
        // An empty layer has no edges: the point stays where it is.
        let settings = MagneticCommands.Settings.default
        var src = try #require(MagneticCommands.EdgeSource(s))
        #expect(src.snap(SIMD2(44, 50), settings) == SIMD2(44, 50))
        let bg = s.active!.doc.layers[0].id
        try s.execute("layer.select", ["layer": .id(bg)])
        #expect(!src.isCurrent(s), "another layer")
        src = try #require(MagneticCommands.EdgeSource(s))
        #expect(src.isCurrent(s))
        let p = try #require(src.snap(SIMD2(44, 50), settings))
        #expect(abs(p.x - 40) < 0.01 && abs(p.y - 50) <= 1, "on the square's edge: \(p)")
        // A layer without pixels of its own (an Invert adjustment): the composite.
        try s.execute("layer.newAdjustmentLayer.invert")
        let st = s.active!
        #expect(st.activeLayer.flatMap { st.doc.layer($0) }.map { $0.surface == nil } == true)
        src = try #require(MagneticCommands.EdgeSource(s))
        let q = try #require(src.snap(SIMD2(44, 50), settings))
        #expect(abs(q.x - 40) < 0.01, "\(q)")
    }

    @Test func readsOnlyAroundTheBorderOfALargeImage() throws {
        let s = Session()
        try s.execute("file.new", ["width": 6000, "height": 4000, "background": "transparent"])
        try s.edit("paint") { doc, _ in
            doc.withRaster(of: doc.layers[0].id) { $0.fill(PixelRect(x0: 2000, y0: 1500, x1: 2200, y1: 1700), with: $0.format.components(fromRGBA: SIMD4(1, 0, 0, 1))) }
        }
        let src = try #require(MagneticCommands.EdgeSource(s))
        let border = try MagneticCommands.traceBorder(src, [SIMD2(2003, 1497), SIMD2(2198, 1504), SIMD2(2203, 1702), SIMD2(1998, 1695)],
                                                      .default, straight: false)
        #expect(border.allSatisfy { (1999...2201).contains($0.x) && (1499...1701).contains($0.y) }, "\(border)")
        let read = src.tracer.cachedPixels
        #expect(read < 40 * 128 * 128, "read \(read) of 24M px")
    }

    @Test func badParamsAreRefused() throws {
        let s = try session()
        let tooMany = JSONValue.array([JSONValue](repeating: [1, 1], count: MagneticCommands.maxPoints + 1))
        for p: JSONValue in [
            [:],
            ["points": "here"],
            ["points": [[0, 0], [10, 0]]],
            ["points": [[0, 0], [10, 0], ["a", 3]]],
            ["points": [[0, 0], [10, 0], [3]]],
            ["points": [[0, 0], [10, 0], [3, 4, 5]]],
            ["points": Self.rough, "width": 0],
            ["points": Self.rough, "width": 300],
            ["points": Self.rough, "width": "wide"],
            ["points": Self.rough, "contrast": 0],
            ["points": Self.rough, "contrast": 101],
            ["points": Self.rough, "close": "zigzag"],
            ["points": Self.rough, "close": 1],
            ["points": Self.rough, "trace": "yes"],
            ["points": Self.rough, "feather": -1],
            ["points": Self.rough, "feather": 5000],
            ["points": tooMany],
        ] {
            #expect(throws: EngineError.self, "\(p.serialized().prefix(80))") { try s.execute("select.magneticLasso", p) }
        }
        #expect(s.active?.doc.selection == nil)
        // Far outside the canvas is kept on it; a border far too long is refused.
        try s.execute("select.magneticLasso", ["points": [[-1e9, -1e9], [1e9, -1e9], [1e9, 1e9]]])
        let big = Session()
        try big.execute("file.new", ["width": 30000, "height": 30000, "background": "transparent"])
        let zigzag = JSONValue.array((0..<20).map { i in [.number(Double(i % 2) * 30000), .number(Double(i) * 1500)] })
        #expect(throws: EngineError.self) { try big.execute("select.magneticLasso", ["points": zigzag]) }
        let none = Session()
        #expect(throws: EngineError.self) { try none.execute("select.magneticLasso", ["points": Self.rough]) }
    }
}
