// Port of photocraft-engine (crates/engine/src/render_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct RenderTests {
    func session(_ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 160, "height": 120, "depth": .int(depth)])
        let want: SampleType = depth == 8 ? .u8 : depth == 16 ? .u16 : .f32
        #expect(s.active?.doc.depth == want)
        try s.execute("layer.new.layer", [:])
        return s
    }

    func pixels(_ s: Session) -> [Float] {
        guard let d = s.active, let id = d.activeLayer, let surf = d.doc.layer(id)?.surface else { return [] }
        return surf.readRegion(PixelRect(x0: 0, y0: 0, x1: 160, y1: 120))
    }

    func opaque(_ s: Session) -> Int {
        let px = pixels(s)
        return stride(from: 3, to: px.count, by: 4).filter { px[$0] > 0.05 }.count
    }

    @Test func eachRendererDrawsUndoesAndIsSeededAtEveryDepth() throws {
        for depth in [8, 16, 32] {
            for (id, p) in [("filter.render.flame", JSONValue.object([:])), ("filter.render.tree", ["baseTreeType": 7]),
                            ("filter.render.pictureFrame", ["frame": "roses"])] {
                let s = try session(depth)
                let r = try s.execute(id, p)
                #expect((r["primitives"]?.intValue ?? 0) > 0, "\(id)")
                #expect(r["bounds"]?.arrayValue != nil, "\(id)@\(depth): \(r)")
                let n = opaque(s)
                #expect(n > 50, "\(id)@\(depth) drew \(n) px")
                let first = pixels(s)
                try s.execute("edit.undo", [:])
                #expect(opaque(s) == 0, "\(id) undo")
                try s.execute(id, p)
                #expect(pixels(s) == first, "\(id) deterministic")
                try s.execute("edit.undo", [:])
                try s.execute(id, p.setting("seed", 5))
                #expect(pixels(s) != first, "\(id) seed changes the result")
            }
        }
    }

    @Test func flameFollowsTheWorkPath() throws {
        let s = try session(8)
        let r = try s.execute("filter.render.flame", [:])
        #expect(r["usedPath"] == false)
        try s.execute("edit.undo", [:])
        // A vertical line path on the left edge: the flame stays near it.
        try s.edit("path") { doc, _ in
            doc.workPath = VectorPath([Subpath(knots: [Knot.corner(20, 110), Knot.corner(20, 20)])])
        }
        let r2 = try s.execute("filter.render.flame", ["width": 16, "length": 60])
        #expect(r2["usedPath"] == true)
        let b = (r2["bounds"]?.arrayValue ?? []).compactMap(\.intValue)
        #expect(b.count == 4 && b[0] < 20 && b[2] < 60, "flame bounds \(b) hug the path at x=20")
    }

    @Test func selectionLimitsAndNewLayer() throws {
        let s = try session(8)
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 80, "height": 120])
        let r = try s.execute("filter.render.tree", ["newLayer": true, "baseTreeType": 1, "leavesAmount": 100])
        #expect(r["newLayer"] == true)
        let px = pixels(s)
        var right = 0
        for i in 0..<(px.count / 4) where i % 160 >= 81 && px[i * 4 + 3] > 0 { right += 1 }
        #expect(right == 0, "nothing drawn outside the selection")
        #expect(opaque(s) > 50)
    }

    @Test func worksInCmykAndGray() throws {
        for mode in ["cmyk", "grayscale", "lab"] {
            let s = Session()
            try s.execute("file.new", ["width": 96, "height": 96, "mode": .string(mode)])
            let r = try s.execute("filter.render.pictureFrame", ["frame": 13, "newLayer": true])
            #expect(r["bounds"]?.arrayValue != nil, "\(mode)")
        }
    }

    /// photocraft #2501: the Tree and Picture Frame dialogs send every number as a JSON float.
    /// Whole floats draw exactly what the integers draw, fractional ones round, and hostile values
    /// fail.
    @Test func integerParamsAcceptWholeFloatsAndRoundFractions() throws {
        let tree: JSONValue = ["baseTreeType": 1.0, "lightDirection": 3.0, "leavesAmount": 50.0, "leavesSize": 100.0, "branchesHeight": 100.0,
                               "branchesThickness": 100.0, "defaultLeaves": true, "customBranchColor": false, "flatShading": false, "seed": 0,
                               "x": 0.5, "y": 0.95, "size": 0.8]
        let frame: JSONValue = ["frame": "vineWithFlowers", "margin": 4.0, "size": 50.0, "arrangement": 50.0, "lines": 1.0, "thickness": 30.0,
                                "fade": 0.0, "seed": 0]
        let cases: [(String, JSONValue, JSONValue)] = [
            ("filter.render.tree", tree, ["baseTreeType": 1, "lightDirection": 3]),
            ("filter.render.tree", ["baseTreeType": 7.4, "lightDirection": 2.6, "seed": 3.0], ["baseTreeType": 7, "lightDirection": 3, "seed": 3]),
            ("filter.render.pictureFrame", frame, ["frame": 1, "lines": 1]),
            ("filter.render.pictureFrame", ["frame": 13.0, "lines": 3.0, "seed": 2.0], ["frame": 13, "lines": 3, "seed": 2]),
            ("filter.render.flame", ["seed": 4.0], ["seed": 4]),
        ]
        for (id, floats, ints) in cases {
            let s = try session(8)
            let a = try s.execute(id, floats)
            let drawn = pixels(s)
            try s.execute("edit.undo", [:])
            let b = try s.execute(id, ints)
            #expect(a == b, "\(id): \(floats) reports what \(ints) does")
            #expect(pixels(s) == drawn, "\(id): \(floats) draws what \(ints) draws")
        }
        // Negative, too large or non-numeric integer fields are refused, never a trap.
        let s = try session(8)
        let hostile: [(String, JSONValue)] = [
            ("filter.render.tree", ["baseTreeType": -1.0]),
            ("filter.render.tree", ["lightDirection": 1e300]),
            ("filter.render.tree", ["seed": -0.6]),
            ("filter.render.pictureFrame", ["lines": -3.5]),
            ("filter.render.pictureFrame", ["seed": 5e9]),
            ("filter.render.pictureFrame", ["lines": "two"]),
            ("filter.render.flame", ["seed": .number(Double.greatestFiniteMagnitude)]),
        ]
        for (id, p) in hostile {
            do {
                try s.execute(id, p)
                Issue.record("\(id) \(p) was accepted")
            } catch {
                #expect("\(error)".contains("invalid parameters"), "\(id) \(p): \(error)")
            }
        }
    }
}
