// Port of photocraft-engine (crates/engine/src/slice_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCRender
import Testing

@Suite struct SliceTests {
    func session(_ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 120, "height": 90, "depth": .int(depth), "name": "site"])
        return s
    }

    func doc(_ s: Session) -> Document { s.active!.doc }
    func past(_ s: Session) -> Int { s.active!.history.pastCount }

    @discardableResult
    func addSquare(_ s: Session, _ r: PixelRect) throws -> LayerId {
        try s.edit("sq") { doc, active -> LayerId in
            let fmt = doc.pixelFormat
            var l = Layer.raster(doc.nextLayerName("Layer"), format: fmt)
            l.withRaster { $0.fill(r, with: fmt.components(fromRGBA: SIMD4(1, 0, 0, 1))) }
            let id = doc.insertAbove(nil, l)
            active = id
            return id
        }
    }

    func sliceId(_ v: JSONValue) throws -> UInt32 { UInt32(try #require(v["slice"]?.uint64Value)) }

    @Test func userSlicesAndOptions() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let r = try s.execute("slice.new", ["rect": [20, 10, 40, 20], "name": "logo", "url": "https://example.org", "alt": "Logo"])
            let id = try sliceId(r)
            #expect(r["number"] == 3, "top band, left cell, then the slice")
            let all = try #require(try s.execute("slice.list", .object([:]))["slices"]?.arrayValue)
            #expect(all.count == 5)
            let me = try #require(all.first { $0["id"] == .int(id) })
            #expect(me["name"] == "logo")
            #expect(me["rect"] == [20, 10, 40, 20])
            #expect(me["origin"] == "user")
            #expect(all.filter { $0["origin"] == "auto" }.count == 4)
            // Slice Options by number; then undo.
            try s.execute("slice.set", ["number": 3, "kind": "noImage", "cellText": "hi", "background": "#ff0000"])
            let sl = try #require(doc(s).slices.get(id))
            #expect(sl.kind == .noImage)
            #expect(sl.background == SIMD4(255, 255, 0, 0))
            #expect(s.undo())
            #expect(doc(s).slices.get(id)?.kind == .image)
            #expect(throws: EngineError.self) { try s.execute("slice.set", ["slice": .int(id), "kind": "bogus"]) }
            #expect(throws: EngineError.self, "outside the canvas") { try s.execute("slice.new", ["rect": [500, 500, 10, 10]]) }
        }
    }

    @Test func rectParamRejectsCornerOverflow() throws {
        let maxI = Double(Int32.max)
        #expect(SliceCommands.rectParam(["rect": [1, 2, 3, 4]]) == PixelRect(x0: 1, y0: 2, x1: 4, y1: 6))
        #expect(SliceCommands.rectParam(["x": 1, "y": 2, "width": 3, "height": 4]) == PixelRect(x0: 1, y0: 2, x1: 4, y1: 6))
        #expect(SliceCommands.rectParam(["rect": [.number(maxI), 0, 1, 1]]) == nil)
        #expect(SliceCommands.rectParam(["x": 0, "y": .number(maxI), "width": 1, "height": 1]) == nil)
        let s = try session(8)
        #expect(throws: EngineError.self) { try s.execute("slice.new", ["rect": [.number(maxI), 0, 1, 1]]) }
        let id = try sliceId(try s.execute("slice.new", ["rect": [1, 1, 8, 8]]))
        #expect(throws: EngineError.self) { try s.execute("slice.set", ["slice": .int(id), "rect": [0, .number(maxI), 1, 1]]) }
    }

    @Test func promoteAutoSliceAndDivide() throws {
        let s = try session(8)
        try s.execute("slice.new", ["rect": [0, 0, 60, 45]])
        // An auto slice promoted through Slice Options keeps one history step.
        let before = past(s)
        let r = try s.execute("slice.set", ["number": 2, "name": "right"])
        #expect(r["origin"] == "user")
        #expect(r["name"] == "right")
        #expect(past(s) == before + 1)
        #expect(doc(s).slices.list.count == 2)
        let id = doc(s).slices.list[0].id
        let r2 = try s.execute("slice.divide", ["slice": .int(id), "horizontal": 3, "vertical": 2])
        #expect(r2["count"] == 6)
        #expect(doc(s).slices.list.count == 7)
        let total = doc(s).slices.list.prefix(6).reduce(0) { $0 + $1.rect.width * $1.rect.height }
        #expect(total == 60 * 45)
        #expect(throws: EngineError.self) { try s.execute("slice.divide", ["slice": .int(id)]) }
    }

    @Test func divideWideSlicePreservesExactEdgesAndHistory() throws {
        for depth in [8, 16, 32] {
            for rect in [PixelRect(x0: -2_000_000_000, y0: -1_000_000_000, x1: 2_000_000_000, y1: 1_000_000_000),
                         PixelRect(x0: -1_000_000_000, y0: -1_000_000_000, x1: 1_000_000_000, y1: 1_000_000_000)] {
                let s = try session(depth)
                try s.edit("loaded wide slice") { doc, _ in doc.slices.list.append(Slice(id: 1, rect: rect, name: "wide")) }
                let before = doc(s).slices
                let p0 = past(s)
                let result = try s.execute("slice.divide", ["slice": 1, "horizontal": 3, "vertical": 3])
                #expect(result["count"] == 9)
                #expect(past(s) == p0 + 1)
                let parts = doc(s).slices.list
                #expect(parts.count == 9)
                #expect(parts[0].name == "wide")
                for row in stride(from: 0, to: 9, by: 3).map({ Array(parts[$0..<($0 + 3)]) }) {
                    #expect(row[0].rect.x0 == rect.x0)
                    #expect(row[2].rect.x1 == rect.x1)
                    #expect(row.reduce(0) { $0 + $1.rect.width } == rect.width)
                    for k in 0..<2 {
                        #expect(row[k].rect.x1 == row[k + 1].rect.x0)
                        #expect(row[k].rect.y0 == row[k + 1].rect.y0)
                        #expect(row[k].rect.y1 == row[k + 1].rect.y1)
                    }
                }
                #expect(parts[0].rect.y0 == rect.y0)
                #expect(parts[8].rect.y1 == rect.y1)
                for i in 0..<6 { #expect(parts[i].rect.y1 == parts[i + 3].rect.y0) }
                let divided = doc(s).slices
                #expect(s.undo())
                #expect(doc(s).slices == before)
                #expect(s.redo())
                #expect(doc(s).slices == divided)
            }
        }
    }

    @Test func slicesFromGuidesAndClear() throws {
        let s = try session(8)
        try s.edit("guides") { d, _ in
            d.guides.vertical = [40, 80]
            d.guides.horizontal = [30]
        }
        #expect(try s.execute("slice.fromGuides", .object([:]))["slices"] == 6)
        #expect(doc(s).slices.list.map(\.rect).contains(PixelRect(x0: 40, y0: 30, x1: 80, y1: 90)))
        #expect(s.isEnabled("view.clearSlices"))
        #expect(try s.execute("view.clearSlices", .object([:]))["cleared"] == 6)
        #expect(doc(s).slices.isEmpty)
        #expect(!s.isEnabled("view.clearSlices"))
    }

    @Test func lockSlicesBlocksEditing() throws {
        let s = try session(8)
        try s.execute("slice.new", ["rect": [0, 0, 10, 10]])
        #expect(try s.execute("view.lockSlices", .object([:]))["locked"] == true)
        #expect(!s.isEnabled("slice.new"))
        #expect(!s.isEnabled("view.clearSlices"))
        #expect(throws: EngineError.self) { try s.execute("slice.new", ["rect": [0, 0, 10, 10]]) }
        try s.execute("view.lockSlices", ["on": false])
        #expect(s.isEnabled("slice.new"))
    }

    @Test func layerBasedSliceFollowsTheLayerAndItsEffects() throws {
        for depth in [8, 16] {
            let s = try session(depth)
            #expect(!s.isEnabled("layer.newLayerBasedSlice"), "Background layer")
            let id = try addSquare(s, PixelRect(x0: 10, y0: 10, x1: 30, y1: 20))
            let r = try s.execute("layer.newLayerBasedSlice", .object([:]))
            #expect(r["rect"] == [10, 10, 20, 10])
            #expect(!s.isEnabled("layer.newLayerBasedSlice"), "one per layer")
            let sid = try sliceId(r)
            // Moving the layer moves the slice.
            try s.execute("layer.translate", ["layer": .id(id), "dx": 5, "dy": 7])
            #expect(doc(s).slices.get(sid)?.rect == PixelRect(x0: 15, y0: 17, x1: 35, y1: 27))
            // A drop shadow grows it.
            try s.edit("fx") { d, _ in
                d.updateLayer(id) { l in
                    l.effects.enabled = true
                    l.effects.items.append(Effect.defaultDropShadow())
                }
            }
            try s.execute("slice.list", .object([:]))
            let grown = try #require(doc(s).slices.get(sid)?.rect)
            let moved = PixelRect(x0: 15, y0: 17, x1: 35, y1: 27)
            #expect(grown.contains(moved) && grown != moved, "\(grown)")
            // Deleting the layer deletes its slice.
            try s.execute("layer.delete", ["layer": .id(id)])
            #expect(doc(s).slices.get(sid) == nil)
        }
    }

    @Test func layerSliceOutsetsSaturateWhenALayerMovesNearCoordinateLimits() throws {
        for offset in [Int32.min + 100, Int32.max - 100] {
            let s = try session(8)
            let layer = try addSquare(s, PixelRect(x0: 10, y0: 10, x1: 30, y1: 20))
            let slice = try sliceId(try s.execute("layer.newLayerBasedSlice", .object([:])))
            try s.execute("slice.set", ["slice": .int(slice), "outsets": [10_000, 10_000, 10_000, 10_000]])
            let before = doc(s).slices
            try s.execute("layer.translate", ["layer": .id(layer), "dx": .int(offset), "dy": .int(offset)])
            let moved = try #require(doc(s).slices.get(slice)?.rect)
            let content = SliceCommands.layerBounds(try #require(doc(s).layer(layer)))
            #expect(moved == content.outset(by: 10_000))
            #expect(moved.contains(content))
            try s.execute("slice.list", .object([:]))
            #expect(doc(s).slices.get(slice)?.rect == moved)
            #expect(s.undo())
            #expect(doc(s).slices == before)
            #expect(s.redo())
            try s.execute("slice.list", .object([:]))
            #expect(doc(s).slices.get(slice)?.rect == moved)
        }
    }

    @Test func exhaustedSliceIdsFailWithoutMutatingDocumentOrHistory() throws {
        let s = try session(8)
        try s.edit("loaded max slice") { doc, _ in
            doc.slices.list.append(Slice(id: 1, rect: PixelRect(x0: 10, y0: 10, x1: 20, y1: 20)))
            doc.slices.list.append(Slice(id: .max, rect: PixelRect(x0: 10, y0: 10, x1: 20, y1: 20)))
        }
        let (p0, revision) = (past(s), s.active!.revision)
        let cases: [(String, JSONValue)] = [
            ("slice.new", ["rect": [30, 30, 10, 10]]), ("slice.divide", ["slice": 1, "horizontal": 1, "vertical": 2]), ("slice.promote", ["number": 1]),
        ]
        for (command, params) in cases {
            do {
                try s.execute(command, params)
                Issue.record("\(command) should fail")
            } catch {
                #expect("\(error)".contains("slice id space exhausted"), "\(command): \(error)")
            }
            #expect(doc(s).slices.list.count == 2, "\(command)")
            #expect(doc(s).slices.get(.max) != nil, "\(command)")
            #expect(past(s) == p0, "\(command)")
            #expect(s.active!.revision == revision, "\(command)")
        }
    }

    @Test func rejectedSliceOptionsChangeNothing() throws {
        // #910: an invalid option on an auto slice used to promote it before failing.
        let s = try session(8)
        var p0 = past(s)
        #expect(throws: EngineError.self) { try s.execute("slice.set", ["number": 1, "kind": "bogus"]) }
        #expect(doc(s).slices.isEmpty)
        #expect(past(s) == p0)
        // A user slice moved off the canvas is rejected without committing the move.
        let id = try sliceId(try s.execute("slice.new", ["rect": [0, 0, 10, 10]]))
        p0 = past(s)
        #expect(throws: EngineError.self) { try s.execute("slice.set", ["slice": .int(id), "rect": [500, 500, 10, 10]]) }
        #expect(doc(s).slices.get(id)?.rect == PixelRect(x0: 0, y0: 0, x1: 10, y1: 10))
        #expect(past(s) == p0)
    }

    @Test func dividingAnAutoSliceIsOneStep() throws {
        // #911: one undo restores the original auto slice.
        let s = try session(8)
        let p0 = past(s)
        #expect(try s.execute("slice.divide", ["number": 1, "vertical": 2])["count"] == 2)
        #expect(doc(s).slices.list.count == 2)
        #expect(past(s) == p0 + 1)
        #expect(s.undo())
        #expect(doc(s).slices.isEmpty)
        // A rejected division doesn't promote either.
        #expect(throws: EngineError.self) { try s.execute("slice.divide", ["number": 1, "vertical": 1000]) }
        #expect(doc(s).slices.isEmpty)
        #expect(past(s) == p0)
    }

    @Test func sliceOptionsAfterAnExplicitPromoteIsItsOwnStep() throws {
        // #912: Slice Options used to fold into an earlier, separate Promote.
        let s = try session(8)
        try s.execute("slice.promote", ["number": 1])
        try s.execute("slice.set", ["number": 1, "name": "renamed"])
        #expect(s.undo())
        #expect(doc(s).slices.list.count == 1, "the promotion survives undoing the rename")
        #expect(doc(s).slices.list.first?.name == "")
        #expect(s.undo())
        #expect(doc(s).slices.isEmpty)
    }

    @Test func outOfRangeSliceIdsAreRejectedNotWrapped() throws {
        // #914: 2^32 + 1 used to wrap to slice 1 and delete it.
        let s = try session(8)
        #expect(try sliceId(try s.execute("slice.new", ["rect": [0, 0, 10, 10]])) == 1)
        let wrapped = JSONValue.number(4_294_967_297)
        #expect(throws: EngineError.self) { try s.execute("slice.delete", ["slice": wrapped]) }
        #expect(throws: EngineError.self) { try s.execute("slice.delete", ["slices": [wrapped]]) }
        #expect(throws: EngineError.self) { try s.execute("slice.set", ["slice": wrapped, "name": "x"]) }
        #expect(throws: EngineError.self) { try s.execute("slice.delete", ["slice": -1]) }
        #expect(doc(s).slices.list.count == 1)
        #expect(doc(s).slices.list.first?.name == "")
    }

    @Test func divideRefusesMorePartsThanOneDivisionMakes() throws {
        // #1020: 1000 x 1000 was accepted (a million slices).
        let s = Session()
        try s.execute("file.new", ["width": 1000, "height": 1000])
        try s.execute("slice.new", ["rect": [0, 0, 1000, 1000]])
        let id = doc(s).slices.list[0].id
        for (h, v) in [(101, 100), (100, 101), (1000, 1000)] {
            let (before, p0) = (doc(s).slices, past(s))
            do {
                try s.execute("slice.divide", ["slice": .int(id), "horizontal": .int(h), "vertical": .int(v)])
                Issue.record("\(h) x \(v) should fail")
            } catch {
                #expect("\(error)".contains("10000"), "\(h) x \(v): \(error)")
            }
            #expect(doc(s).slices == before && past(s) == p0, "\(h) x \(v): nothing changed")
        }
        // At the limit it divides, and the list resolves.
        #expect(try s.execute("slice.divide", ["slice": .int(id), "horizontal": 100, "vertical": 100])["count"] == 10_000)
        #expect(doc(s).slices.list.count == 10_000)
        #expect(throws: Never.self) { try s.execute("slice.list", .object([:])) }
    }

    @Test func slicesRoundTripThroughPsdAndPcraft() throws {
        let s = try session(8)
        _ = try addSquare(s, PixelRect(x0: 50, y0: 40, x1: 70, y1: 60))
        try s.execute("layer.newLayerBasedSlice")
        try s.execute("slice.new", ["rect": [5, 5, 30, 20], "name": "hero", "url": "https://example.org", "alt": "Hero", "target": "_blank"])
        let d = doc(s)
        for ext in ["psd", "pcraft"] {
            let bytes = try EngineIO.export(d, as: "x.\(ext)", services: s.services).bytes
            let back = try EngineIO.importFile(name: "x.\(ext)", bytes: bytes, services: s.services).document
            #expect(back.slices.list.count == 2, "\(ext)")
            let hero = try #require(back.slices.list.first { $0.name == "hero" })
            #expect(hero.url == "https://example.org" && hero.alt == "Hero" && hero.target == "_blank", "\(ext)")
            #expect(hero.rect == PixelRect(x0: 5, y0: 5, x1: 35, y1: 25), "\(ext)")
            let ls = try #require(back.slices.list.first { $0.origin == .layer })
            let lid = try #require(ls.layer)
            let layer = try #require(back.layer(lid))
            #expect(layer.name == "Layer 1", "\(ext): the slice still names its layer")
            #expect(ls.rect == PixelRect(x0: 50, y0: 40, x1: 70, y1: 60), "\(ext)")
        }
    }
}
