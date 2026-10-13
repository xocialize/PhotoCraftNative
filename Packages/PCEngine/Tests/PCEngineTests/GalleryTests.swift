// Port of photocraft-engine (crates/engine/src/gallery_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCAlgo
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct GalleryTests {
    static let w: Int32 = 40
    static let h: Int32 = 32
    static let rect = PixelRect(x0: 0, y0: 0, x1: w, y1: h)

    func session(_ depth: Int, _ mode: String) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": .int(Int(Self.w)), "height": .int(Int(Self.h)), "depth": .int(depth), "mode": .string(mode)])
        try s.execute("layer.new.layer", [:])
        try s.edit("pattern") { doc, active in
            guard let id = active else { return }
            _ = doc.withRaster(of: id) { surf in
                let n = surf.format.channels
                for y in 0..<Self.h {
                    for x in 0..<Self.w {
                        let v = Float((x * 7 + y * 3) % 23) / 22
                        var px = [Float](repeating: 1, count: n)
                        for c in 0..<(n - 1) { px[c] = (x / 10 + y / 8) % 2 == 0 ? v : 1 - v * (Float(c) + 1) / 4 }
                        surf.setPixel(x: x, y: y, px)
                    }
                }
            }
        }
        return s
    }

    func pixels(_ s: Session) -> [Float] {
        guard let d = s.active, let id = d.activeLayer, let surf = d.doc.layer(id)?.surface else { return [] }
        return surf.readRegion(Self.rect)
    }

    /// Converts the active pixel layer to a smart object (photocraft's tests run
    /// `layer.smartObjects.convertToSmartObject`).
    static func makeSmartObject(_ s: Session) throws {
        try s.execute("layer.smartObjects.convertToSmartObject")
    }

    func isBadParams(_ e: any Error) -> Bool {
        if case .badParams? = e as? EngineError { return true }
        return false
    }

    @Test func everyGalleryFilterRunsAtEveryDepthAndUndoes() throws {
        for depth in [8, 16, 32] {
            for f in GalleryFilter.allCases {
                let s = try session(depth, "rgb")
                let before = pixels(s)
                let r = try s.execute(f.commandID, [:])
                #expect(r["filter"] != nil, "\(f.key)")
                let after = pixels(s)
                #expect(after != before, "\(f.key) @\(depth) changed nothing")
                #expect(after.allSatisfy { $0.isFinite && $0 >= -1e-4 && $0 <= 1.0001 }, "\(f.key) @\(depth) out of range")
                try s.execute("edit.undo", [:])
                #expect(pixels(s) == before, "\(f.key) undo")
            }
        }
    }

    @Test func galleryFiltersRunInOtherColourModels() throws {
        for mode in ["gray", "cmyk", "lab"] {
            for f in [GalleryFilter.cutout, .graphicPen, .texturizer, .stainedGlass] {
                let s = try session(16, mode)
                let before = pixels(s)
                try s.execute(f.commandID, [:])
                #expect(pixels(s) != before, "\(f.key) \(mode)")
            }
        }
    }

    @Test func resultsDoNotDependOnTiling() throws {
        let s = try session(32, "rgb")
        let d = try #require(s.active)
        let active = try #require(d.activeLayer)
        let surf = try #require(d.doc.layer(active)?.surface)
        let b = Self.rect
        func tiled<F: Filter>(_ f: F, _ tile: Int) throws -> [Float] {
            var out = surf
            try FilterEngine.apply(f, to: &out, area: b, bounds: b, selection: nil, extent: b, tile: tile)
            return out.readRegion(b)
        }
        for f in GalleryFilter.allCases {
            let fp = try #require(GalleryCommands.paramsFor(f.commandID, .object([:])))
            let a = try tiled(fp.filter, 256), c = try tiled(fp.filter, 16)
            let worst = zip(a, c).map { abs($0 - $1) }.max() ?? 0
            #expect(worst < 1e-3, "\(f.key) differs across tilings by \(worst)")
        }
    }

    @Test func stackAppliesInOrderAndSkipsHiddenLayers() throws {
        func run(_ effects: JSONValue) throws -> [Float] {
            let s = try session(8, "rgb")
            try s.execute("filter.filterGallery", ["effects": effects])
            return pixels(s)
        }
        let one = try run([["filter": "cutout", "params": ["numberOfLevels": 3]]])
        let single = try session(8, "rgb")
        try single.execute("filter.gallery.cutout", ["numberOfLevels": 3])
        #expect(one == pixels(single), "one-layer gallery = the filter's own command")
        let ab = try run([["filter": "cutout"], ["filter": "glowingEdges"]])
        let ba = try run([["filter": "glowingEdges"], ["filter": "cutout"]])
        #expect(ab != ba, "order matters")
        let hidden = try run([["filter": "cutout"], ["filter": "glowingEdges", "visible": false]])
        #expect(hidden == (try run([["filter": "cutout"]])))
    }

    @Test func galleryValidatesAndLists() throws {
        let s = try session(8, "rgb")
        #expect(throws: (any Error).self) { try s.execute("filter.filterGallery", [:]) }
        #expect(throws: (any Error).self) { try s.execute("filter.filterGallery", ["effects": [["filter": "nope"]]]) }
        let tooMany = JSONValue.array((0..<33).map { _ in ["filter": "coloredPencil"] })
        #expect(throws: (any Error).self) { try s.execute("filter.filterGallery", ["effects": tooMany]) }
        let list = try s.execute("filter.filterGallery", ["list": true])
        #expect(list["filters"]?.arrayValue?.count == 47)
        #expect(list["categories"]?.arrayValue?.count == 6)
        // Param values clamp to Photoshop's ranges; choices accept names.
        let e = GalleryCommands.effectFromJSON(.graphicPen, ["strokeLength": 99, "strokeDirection": "vertical"], .null)
        #expect(e.get("strokeLength") == 15)
        #expect(e.choice("strokeDirection") == "vertical")
    }

    @Test func sketchFiltersRecordAndUseTheCurrentColours() throws {
        let s = try session(8, "rgb")
        s.tools.foreground = SIMD4(1, 0, 0, 1)
        s.tools.background = SIMD4(0, 0, 1, 1)
        let r = try s.execute("filter.gallery.stamp", [:])
        #expect(r["filter"]?["effects"]?.arrayValue?.first?["foreground"] == [1, 0, 0, 1])
        // Stamp is two-tone: every pixel is (close to) red or blue.
        let px = pixels(s)
        let quads = stride(from: 0, to: px.count, by: 4).map { Array(px[$0..<$0 + 4]) }
        #expect(quads.allSatisfy { $0[1] < 0.05 }, "no green in a red/blue stamp")
        #expect(quads.contains { $0[0] > 0.9 } && quads.contains { $0[2] > 0.9 })
    }

    @Test func galleryIsASmartFilterOnSmartObjects() throws {
        let s = try session(8, "rgb")
        try Self.makeSmartObject(s)
        try s.execute("filter.filterGallery", ["effects": [["filter": "texturizer", "params": ["relief": 20]]]])
        let d = try #require(s.active)
        guard case .smart(let sm)? = d.doc.layer(try #require(d.activeLayer))?.content else {
            Issue.record("not smart")
            return
        }
        #expect(sm.smartFilters.count == 1)
        #expect(sm.smartFilters.first?.command == "filter.filterGallery")
        #expect(sm.smartFilters.first?.params["effects"]?.arrayValue?.first?["filter"] == "texturizer")
    }

    @Test func unknownChoiceNamesAreBadParamsWithoutEditing() throws {
        let s = try session(8, "rgb")
        let before = pixels(s)
        let history = s.active?.history.pastCount
        var checked = 0
        for f in GalleryFilter.allCases {
            for prm in f.params {
                guard case .choice(let names) = prm.kind else { continue }
                let id = f.commandID
                for v: JSONValue in ["zzbogus", true, [0]] {
                    do {
                        try s.execute(id, .object([prm.key: v]))
                        Issue.record("\(id).\(prm.key) accepted \(v)")
                    } catch {
                        #expect(isBadParams(error), "\(id).\(prm.key): \(error)")
                        #expect("\(error)".contains(prm.key), "\(error)")
                    }
                    let stack: JSONValue = ["effects": [["filter": .string(f.key), "params": .object([prm.key: v])]]]
                    do {
                        try s.execute("filter.filterGallery", stack)
                        Issue.record("stack \(id).\(prm.key) accepted \(v)")
                    } catch {
                        #expect(isBadParams(error), "\(id).\(prm.key)")
                    }
                }
                #expect(pixels(s) == before)
                #expect(s.active?.history.pastCount == history)
                // Every listed name (any case) and an index still run.
                for v in names.map({ JSONValue.string($0.uppercased()) }) + [.int(names.count - 1)] {
                    try s.execute(id, .object([prm.key: v]))
                    _ = s.undo()
                }
                checked += 1
            }
        }
        #expect(checked >= 16, "\(checked)")
    }

    /// Not a photocraft test: every id these modules register matches photocraft's catalogue
    /// (label, menu, shortcut, params, module), and every catalogued id of theirs is registered.
    @Test func specsMatchThePhotocraftCatalogue() {
        let modules: [any CommandModule.Type] = [GalleryCommands.self, ColorToAlphaCommands.self, LensCommands.self, RenderCommands.self,
                                                 VanishingPointCommands.self]
        var ids = Set<String>()
        for module in modules {
            var r = CommandRegistry()
            r.install(module)
            for spec in r.specs {
                ids.insert(spec.id)
                guard let c = PhotocraftCatalog.byId[spec.id] else {
                    Issue.record("\(spec.id) is not a photocraft command")
                    continue
                }
                #expect(spec.label == c.label, "\(spec.id) label")
                #expect(spec.menu == c.menu, "\(spec.id) menu")
                #expect(spec.shortcut == c.shortcut, "\(spec.id) shortcut")
                #expect(spec.params == c.params, "\(spec.id) params")
                #expect(spec.module == c.module, "\(spec.id) module")
                #expect(spec.isAvailable, "\(spec.id) is registered unavailable")
            }
        }
        let names = Set(modules.map { $0.name })
        let expected = Set(PhotocraftCatalog.commands.filter { names.contains($0.module) }.map(\.id))
        #expect(ids == expected, "missing \(expected.subtracting(ids)), extra \(ids.subtracting(expected))")
        #expect(ids.count == 48 + 1 + 4 + 3 + 1)
    }
}
