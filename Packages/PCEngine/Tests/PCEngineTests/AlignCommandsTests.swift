// Port of photocraft-engine (crates/engine/src/align_cmds.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Every photocraft test is ported; `registrationsMatchPhotocraftsCatalogue` checks the ids of
// align_cmds and photo_cmds (and the resampling ids finished in image/mode/analysis/edit-menu)
// against photocraft's catalogue.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct AlignCommandsTests {
    func doc(_ s: Session) -> Document { s.active!.doc }

    /// Deterministic texture written into a new layer at offset (dx, dy).
    func textureLayer(_ s: Session, _ name: String, _ dx: Int32, _ dy: Int32) throws -> LayerId {
        try s.execute("layer.new.layer", ["name": .string(name)])
        try s.edit("tex") { doc, active in
            var seed: UInt64 = 99
            func rnd() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 33) / Double(UInt64(1) << 31)
            }
            doc.withRaster(of: active!) { surf in
                surf.fill(PixelRect(x0: dx, y0: dy, x1: dx + 240, y1: dy + 180), with: [0.4, 0.4, 0.4, 1])
                for _ in 0..<120 {
                    let (x, y) = (Int32(rnd() * 220), Int32(rnd() * 160))
                    let (sw, sh) = (4 + Int32(rnd() * 14), 4 + Int32(rnd() * 10))
                    let v = Float(rnd())
                    surf.fill(PixelRect(x0: dx + x, y0: dy + y, x1: dx + x + sw, y1: dy + y + sh), with: [v, 1 - v, v * 0.5, 1])
                }
            }
        }
        return s.active!.activeLayer!
    }

    func select(_ s: Session, _ ids: [LayerId]) throws {
        try s.execute("layer.select", ["layer": .id(ids[0])])
        for id in ids.dropFirst() { try s.execute("layer.select", ["layer": .id(id), "mode": "add"]) }
    }

    func matrix(_ r: JSONValue) throws -> [Double] {
        try #require(r["aligned"]?[0]?["matrix"]?.arrayValue).map { $0.doubleValue ?? .nan }
    }

    @Test func autoAlignRepositionsAtAllDepths() throws {
        for depth in [8, 16, 32] {
            let s = Session()
            try s.execute("file.new", ["width": 300, "height": 240, "depth": .int(depth), "background": "transparent"])
            let a = try textureLayer(s, "A", 20, 20)
            let b = try textureLayer(s, "B", 31, 13)
            #expect(!s.isEnabled("edit.autoAlignLayers"), "one layer selected")
            try select(s, [a, b])
            #expect(s.isEnabled("edit.autoAlignLayers"))
            let r = try s.execute("edit.autoAlignLayers", ["projection": "reposition"])
            #expect(r["reference"] == .id(a))
            var bb = try #require(doc(s).layer(b)?.surface).contentBounds
            #expect(abs(bb.x0 - 20) <= 1 && abs(bb.y0 - 20) <= 1, "depth \(depth): \(bb) \(r.serialized())")
            #expect(s.undo())
            bb = try #require(doc(s).layer(b)?.surface).contentBounds
            #expect(bb.x0 == 31 && bb.y0 == 13)
        }
    }

    @Test func autoAlignAutoProjectionAndErrors() throws {
        let s = Session()
        try s.execute("file.new", ["width": 300, "height": 240, "background": "transparent"])
        let a = try textureLayer(s, "A", 20, 20)
        let b = try textureLayer(s, "B", 26, 25)
        try select(s, [a, b])
        let r = try s.execute("edit.autoAlignLayers")
        let m = try matrix(r)
        #expect(abs(m[2] + 6) < 1 && abs(m[5] + 5) < 1, "\(r.serialized())")
        #expect(throws: EngineError.self) { try s.execute("edit.autoAlignLayers", ["projection": "sideways"]) }
        #expect(throws: EngineError.self) { try s.execute("edit.autoAlignLayers", ["reference": 9999]) }
    }

    @Test func autoBlendPanoramaMasksAndSeamlessLayer() throws {
        for depth in [8, 16, 32] {
            let s = Session()
            try s.execute("file.new", ["width": 200, "height": 60, "depth": .int(depth), "background": "transparent"])
            try s.execute("layer.new.layer", ["name": "left"])
            try s.edit("l") { doc, active in doc.withRaster(of: active!) { $0.fill(PixelRect(x0: 0, y0: 0, x1: 130, y1: 60), with: [0.2, 0.3, 0.8, 1]) } }
            let left = s.active!.activeLayer!
            try s.execute("layer.new.layer", ["name": "right"])
            try s.edit("r") { doc, active in doc.withRaster(of: active!) { $0.fill(PixelRect(x0: 70, y0: 0, x1: 200, y1: 60), with: [0.9, 0.6, 0.2, 1]) } }
            let right = s.active!.activeLayer!
            try select(s, [left, right])
            let r = try s.execute("edit.autoBlendLayers", ["method": "panorama"])
            let d = doc(s)
            let ml = try #require(d.layer(left)?.mask), mr = try #require(d.layer(right)?.mask)
            #expect(ml.value(x: 10, y: 30) == 1 && mr.value(x: 10, y: 30) == 0, "depth \(depth)")
            #expect(ml.value(x: 190, y: 30) == 0 && mr.value(x: 190, y: 30) == 1)
            let blended = LayerId(try #require(r["blended"]?.uint64Value))
            let px = try #require(d.layer(blended)?.surface).pixel(x: 5, y: 30)
            #expect(abs(px[2] - 0.8) < 0.02, "\(px)")
            #expect(s.undo())
            #expect(doc(s).layer(left)?.mask == nil)
        }
    }

    @Test func autoBlendStackWithoutSeamless() throws {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 64, "background": "transparent"])
        try s.execute("layer.new.layer", ["name": "sharp"])
        try s.edit("checker") { doc, active in
            doc.withRaster(of: active!) { surf in
                for y in stride(from: Int32(0), to: 64, by: 2) {
                    for x in stride(from: Int32(0), to: 64, by: 2) {
                        let v: Float = (x / 2 + y / 2) % 2 == 0 ? 0.1 : 0.9
                        surf.fill(PixelRect(x0: x, y0: y, x1: x + 2, y1: y + 2), with: [v, v, v, 1])
                    }
                }
            }
        }
        let a = s.active!.activeLayer!
        try s.execute("layer.new.layer", ["name": "flat"])
        try s.edit("flat") { doc, active in doc.withRaster(of: active!) { $0.fill(PixelRect(x0: 0, y0: 0, x1: 64, y1: 64), with: [0.5, 0.5, 0.5, 1]) } }
        let flat = s.active!.activeLayer!
        try select(s, [a, flat])
        let r = try s.execute("edit.autoBlendLayers", ["method": "stack", "seamlessTones": false])
        #expect(r["blended"] == .null)
        let d = doc(s)
        // The detailed layer is sharper everywhere.
        let ma = try #require(d.layer(a)?.mask)
        #expect((Int32(0)..<64).filter { ma.value(x: $0, y: 32) > 0.5 }.count == 64)
        #expect(d.layer(flat)?.mask?.value(x: 10, y: 10) == 0)
        #expect(throws: EngineError.self) { try s.execute("edit.autoBlendLayers", ["method": "sideways"]) }
    }

    /// A smooth layer (soft blobs on a gradient) and the same picture a few pixels away.
    func smoothLayer(_ s: Session, _ name: String, _ dx: Int, _ dy: Int) throws -> LayerId {
        try s.execute("layer.new.layer", ["name": .string(name)])
        try s.edit("smooth") { doc, active in
            var px: [SIMD4<Float>] = []
            px.reserveCapacity(200 * 150)
            for y in 0..<150 {
                for x in 0..<200 {
                    let (u, v) = (Float(x - dx), Float(y - dy))
                    let blob = exp(-((u - 90) * (u - 90) + (v - 70) * (v - 70)) / (2 * 25 * 25))
                    let blob2 = exp(-((u - 150) * (u - 150) + (v - 40) * (v - 40)) / (2 * 15 * 15))
                    let g = 0.2 + 0.5 * blob + 0.25 * blob2 + 0.001 * u
                    px.append(SIMD4(g, g * 0.8, g * 0.6, 1))
                }
            }
            doc.withRaster(of: active!) { $0.writeRGBA(PixelRect(x0: 0, y0: 0, x1: 200, y1: 150), px) }
        }
        return s.active!.activeLayer!
    }

    /// The intensity registration finds the shift to a fraction of a pixel at every motion model.
    @Test func autoAlignRegistersASmoothBracketByIntensity() throws {
        for depth in [8, 16, 32] {
            let s = Session()
            try s.execute("file.new", ["width": 200, "height": 150, "depth": .int(depth), "background": "transparent"])
            let a = try smoothLayer(s, "A", 0, 0)
            let b = try smoothLayer(s, "B", 4, 3)
            try select(s, [a, b])
            #expect(throws: EngineError.self) { try s.execute("edit.autoAlignLayers", ["registration": "sideways"]) }
            #expect(throws: EngineError.self) { try s.execute("edit.autoAlignLayers", ["projection": "cylindrical", "registration": "intensity"]) }
            let runs: [(JSONValue, String)] = [
                (["projection": "reposition", "registration": "intensity"], "reposition"),
                (["registration": "intensity"], "collage"),
                (["projection": "perspective", "registration": "intensity"], "perspective"),
            ]
            for (params, model) in runs {
                let r = try s.execute("edit.autoAlignLayers", params)
                #expect(r["registration"] == "intensity", "depth \(depth): \(r.serialized())")
                #expect(r["aligned"]?[0]?["model"] == .string(model))
                let m = try matrix(r)
                #expect(abs(m[2] + 4) < 0.25 && abs(m[5] + 3) < 0.25, "depth \(depth) \(model): \(r.serialized())")
                // B now shows A's picture.
                let d = doc(s)
                let (pa, pb) = (try #require(d.layer(a)?.surface).pixel(x: 90, y: 70), try #require(d.layer(b)?.surface).pixel(x: 90, y: 70))
                #expect(abs(pa[0] - pb[0]) < 0.02, "depth \(depth) \(model): \(pa) vs \(pb)")
                #expect(s.undo())
            }
        }
    }

    /// Layers with nothing in common are no fit: the intensity registration says so instead of
    /// moving them by whatever pose its search box ends at.
    @Test func autoAlignRejectsUnrelatedLayersInsteadOfGuessingAPose() throws {
        let s = Session()
        try s.execute("file.new", ["width": 200, "height": 150, "depth": 8, "background": "transparent"])
        let a = try smoothLayer(s, "A", 0, 0)
        try s.execute("layer.new.layer", ["name": "stripes"])
        try s.edit("stripes") { doc, active in
            var px: [SIMD4<Float>] = []
            for y in 0..<150 { for x in 0..<200 { let g: Float = (x / 7 + y / 11) % 2 == 0 ? 0.9 : 0.1; px.append(SIMD4(g, g, g, 1)) } }
            doc.withRaster(of: active!) { $0.writeRGBA(PixelRect(x0: 0, y0: 0, x1: 200, y1: 150), px) }
        }
        let b = s.active!.activeLayer!
        try select(s, [a, b])
        for registration in ["intensity", "auto"] {
            do {
                try s.execute("edit.autoAlignLayers", ["registration": .string(registration)])
                Issue.record("\(registration): expected an error")
            } catch let e as EngineError {
                #expect(e == .other(PhotoCommands.noDetail), "\(registration): \(e)")
            }
        }
        // A layer that is mostly empty overlaps too little to be placed.
        let c = try smoothLayer(s, "C", 2, 1)
        try s.edit("hole") { doc, _ in doc.withRaster(of: c) { $0.fill(PixelRect(x0: 0, y0: 0, x1: 200, y1: 120), with: [0, 0, 0, 0]) } }
        try select(s, [a, c])
        #expect(throws: EngineError.other(PhotoCommands.noDetail)) { try s.execute("edit.autoAlignLayers", ["registration": "intensity"]) }
    }

    /// Two layers, each sharp on one half: the merged layer takes each half from the sharp layer.
    @Test func autoBlendStackFusesTheSharpHalves() throws {
        func checker(_ x: Int, _ y: Int) -> Float { (x / 3 + y / 3) % 2 == 0 ? 0.2 : 0.8 }
        for depth in [8, 16, 32] {
            let s = Session()
            try s.execute("file.new", ["width": 96, "height": 64, "depth": .int(depth), "background": "transparent"])
            var ids: [LayerId] = []
            for (name, sharpLeft) in [("left", true), ("right", false)] {
                try s.execute("layer.new.layer", ["name": .string(name)])
                try s.edit(name) { doc, active in
                    var px: [SIMD4<Float>] = []
                    for y in 0..<64 {
                        for x in 0..<96 {
                            // The sharp half is the checker, the other half its local mean (flat gray).
                            let v = (x < 48) == sharpLeft ? checker(x, y) : 0.5
                            px.append(SIMD4(v, v, v, 1))
                        }
                    }
                    doc.withRaster(of: active!) { $0.writeRGBA(PixelRect(x0: 0, y0: 0, x1: 96, y1: 64), px) }
                }
                ids.append(s.active!.activeLayer!)
            }
            try select(s, ids)
            for halo in [0.0, 2.0] {
                let r = try s.execute("edit.autoBlendLayers", ["method": "stack", "haloControl": .number(halo)])
                let d = doc(s)
                let blendedId = LayerId(try #require(r["blended"]?.uint64Value))
                let blended = try #require(d.layer(blendedId)?.surface)
                for (x, y) in [(10, 20), (20, 40), (76, 20), (85, 40)] {
                    let px = blended.pixel(x: Int32(x), y: Int32(y))
                    #expect(abs(px[0] - checker(x, y)) < 0.08, "depth \(depth) halo \(halo) (\(x),\(y)): \(px)")
                    #expect(abs(px[3] - 1) < 1e-3, "\(px)")
                }
                // The masks still pick per pixel.
                #expect(d.layer(ids[0])?.mask?.value(x: 10, y: 20) == 1)
                #expect(d.layer(ids[1])?.mask?.value(x: 85, y: 40) == 1)
                #expect(s.undo())
                #expect(doc(s).layer(ids[0])?.mask == nil)
            }
            for bad: JSONValue in [-1, 9, "hard"] {
                #expect(throws: EngineError.self, "\(bad)") { try s.execute("edit.autoBlendLayers", ["method": "stack", "haloControl": bad]) }
            }
        }
    }

    /// Every id of align_cmds and photo_cmds is registered, available, with photocraft's label,
    /// menu path, shortcut and params, under its photocraft module; so are the resampling commands
    /// finished in image_cmds, mode_cmds, analysis_cmds and edit_menu_cmds.
    @Test func registrationsMatchPhotocraftsCatalogue() throws {
        let modules: Set<String> = ["align_cmds", "photo_cmds"]
        let finished: Set<String> = ["image.imageSize", "image.crop", "image.rotation.arbitrary", "image.analysis.straightenLayer", "edit.contentAwareScale"]
        let r = CommandRegistry.standard()
        let expected = PhotocraftCatalog.commands.filter { modules.contains($0.module) || finished.contains($0.id) }
        #expect(expected.count == 10)
        for c in expected {
            let spec = try #require(r.spec(c.id), "\(c.id)")
            #expect(spec.module == c.module, "\(c.id)")
            #expect(spec.label == c.label, "\(c.id)")
            #expect(spec.menu == c.menu, "\(c.id)")
            #expect(spec.shortcut == c.shortcut, "\(c.id)")
            #expect(spec.params == c.params, "\(c.id)")
            #expect(spec.availability == .available, "\(c.id)")
        }
        for spec in r.specs where modules.contains(spec.module) {
            #expect(PhotocraftCatalog.byId[spec.id]?.module == spec.module, "\(spec.id) is not a photocraft command of its module")
        }
    }
}
