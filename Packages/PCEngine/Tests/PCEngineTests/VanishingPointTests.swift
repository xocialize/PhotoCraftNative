// Port of photocraft-engine (crates/engine/src/vp_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCAlgo
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct VanishingPointTests {
    static let vp = VanishingPointCommands.vp

    func surface(_ s: Session, _ id: LayerId) -> Surface? { s.active?.doc.layer(id)?.surface }

    func fill(_ s: Session, _ id: LayerId, _ r: PixelRect, _ px: [Float]) throws {
        try s.edit("fill") { doc, _ in _ = doc.withRaster(of: id) { $0.fill(r, with: px) } }
    }

    @Test func planesPasteAndClone() throws {
        let s = Session()
        try s.execute("file.new", ["width": 400, "height": 300])
        try s.execute("layer.new.layer", ["name": "floor"])
        try s.execute("edit.fill", ["color": "#404040"])
        let floor = try #require(s.active?.activeLayer)
        // A trapezoid "floor" receding to the top.
        let planes: JSONValue = [["corners": [[120, 120], [280, 120], [360, 280], [40, 280]]], ["from": 0, "edge": "top", "angle": 90]]
        try s.execute("layer.new.layer", ["name": "sticker"])
        let sticker = try #require(s.active?.activeLayer)
        try fill(s, sticker, PixelRect(x0: 0, y0: 0, x1: 40, y1: 20), [1, 0, 0, 1])
        try s.execute("layer.select", ["layer": .id(floor)])
        let r = try s.execute(Self.vp, ["planes": planes, "paste": [["plane": 0, "layer": .id(sticker), "at": [0.3, 0.4], "width": 0.4]]])
        #expect(r["planes"]?.arrayValue?.count == 2)
        #expect((r["focal"]?.doubleValue ?? 0) > 50, "\(r)")
        let l = try #require(surface(s, floor))
        // The paste covers the plane's middle and not its far corner.
        let h = try #require(VpPlane(corners: [SIMD2(120, 120), SIMD2(280, 120), SIMD2(360, 280), SIMD2(40, 280)]).homography())
        let (x, y) = h.apply(0.5, 0.41)
        #expect(l.rgba(x: Int32(x), y: Int32(y)).x > 0.9, "\(l.rgba(x: Int32(x), y: Int32(y)))")
        #expect(l.rgba(x: 130, y: 125).x < 0.5)
        _ = s.undo()
        // Clone: copy the bright stripe painted near the bottom to the top of the floor.
        try fill(s, floor, PixelRect(x0: 180, y0: 250, x1: 220, y1: 265), [0, 1, 0, 1])
        try s.execute("layer.select", ["layer": .id(floor)])
        let r2 = try s.execute(Self.vp, ["planes": planes, "clone": [["source": [200, 257], "points": [[200, 160], [205, 160]], "size": 12, "hardness": 80]]])
        #expect((r2["dabs"]?.intValue ?? 0) >= 1, "\(r2)")
        let l2 = try #require(surface(s, floor))
        #expect(l2.rgba(x: 200, y: 160).y > 0.8, "\(l2.rgba(x: 200, y: 160))")
        #expect(throws: (any Error).self) { try s.execute(Self.vp, [:]) }
        #expect(throws: (any Error).self) { try s.execute(Self.vp, ["planes": [["corners": [[0, 0], [1, 1]]]]]) }
        let r3 = try s.execute(Self.vp, ["planes": planes, "newLayer": true])
        #expect(r3["layer"]?.uint64Value != floor.rawValue)
    }

    @Test func rejectsPlanesThatAreNotConvex() throws {
        let s = Session()
        try s.execute("file.new", ["width": 200, "height": 200, "depth": 16])
        try s.execute("layer.new.layer", [:])
        let bowtie: JSONValue = [[20, 20], [180, 180], [180, 20], [20, 180]]
        let dent: JSONValue = [[20, 20], [180, 20], [60, 60], [20, 180]]
        let square: JSONValue = [[20, 20], [180, 20], [180, 180], [20, 180]]
        for planes: JSONValue in [[["corners": bowtie]], [["corners": square], ["corners": dent]]] {
            do {
                try s.execute(Self.vp, ["planes": planes])
                Issue.record("accepted \(planes)")
            } catch {
                #expect("\(error)".contains("convex"), "\(error)")
            }
        }
        try s.execute(Self.vp, ["planes": [["corners": square]]])
    }
}
