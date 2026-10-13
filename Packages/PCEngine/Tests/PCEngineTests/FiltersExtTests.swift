// Port of photocraft-engine (crates/engine/src/filters_ext/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Every photocraft test is ported. `relight_rejects_bad_params`' `null` case runs the spec's body
// directly: this engine's dispatch reads `null` params as `{}` before any command sees them.
// `specsMatchThePhotocraftCatalogue` is not a photocraft test.

import Foundation
import PCAlgo
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct FiltersExtTests {
    static let ids = [
        "filter.pixelate.colorHalftone",
        "filter.pixelate.crystallize",
        "filter.pixelate.facet",
        "filter.pixelate.fragment",
        "filter.pixelate.mezzotint",
        "filter.pixelate.pointillize",
        "filter.stylize.diffuse",
        "filter.stylize.extrude",
        "filter.stylize.oilPaint",
        "filter.stylize.tiles",
        "filter.stylize.traceContour",
        "filter.stylize.wind",
        "filter.distort.shear",
        "filter.distort.zigZag",
        "filter.render.fibers",
        "filter.render.lensFlare",
        "filter.render.lightingEffects",
        "filter.render.relight",
        "filter.noise.reduceNoise",
        "filter.blur.smartBlur",
        "filter.blur.lensBlur",
        "filter.blur.shapeBlur",
        "filter.blurGallery.tiltShift",
        "filter.blurGallery.irisBlur",
        "filter.blurGallery.fieldBlur",
        "filter.blurGallery.spinBlur",
        "filter.blurGallery.pathBlur",
        "filter.other.custom",
        "filter.other.hsbHsl",
        "filter.video.deInterlace",
        "filter.video.ntscColors",
        "filter.stylize.wind",
        "filter.distort.zigZag",
        "filter.blur.smartBlur",
    ]

    static let full = PixelRect(x0: 0, y0: 0, x1: 48, y1: 32)

    func session() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 48, "height": 32])
        try s.execute("layer.new.layer", [:])
        try s.edit("pattern") { doc, active in
            guard let id = active else { throw EngineError.other("no active layer") }
            var px: [SIMD4<Float>] = []
            for y in 0..<32 {
                for x in 0..<48 {
                    let v = Float((x * 5 + y * 3) % 17) / 16
                    px.append(SIMD4(v, 1 - v, Float(x % 3) / 2, 1))
                }
            }
            _ = doc.withRaster(of: id) { surf in surf.writeRGBA(Self.full, px) }
        }
        return s
    }

    func pixels(_ s: Session, _ r: PixelRect = full) -> [Float] {
        guard let d = s.active, let id = d.activeLayer, let surf = d.doc.layer(id)?.surface else { return [] }
        return surf.readRegion(r)
    }

    func steps(_ s: Session) -> Int { s.active?.history.pastCount ?? -1 }

    func testParams(_ id: String) -> JSONValue {
        switch id {
        case "filter.distort.shear": ["amount": 40]
        case "filter.extrude": [:]
        case "filter.stylize.extrude": ["size": 6, "depth": 40]
        case "filter.stylize.tiles": ["count": 4, "maxOffset": 30]
        case "filter.blur.shapeBlur": ["radius": 5, "shape": "star"]
        case "filter.blur.lensBlur": ["radius": 4]
        case "filter.blurGallery.tiltShift": ["blur": 6]
        case "filter.blurGallery.irisBlur": ["blur": 6]
        case "filter.blurGallery.fieldBlur": ["blur": 4]
        case "filter.blurGallery.pathBlur": ["speed": 8]
        case "filter.other.custom": ["kernel": [0, 0, 0, 0, 0, 0, 0, -1, 0, 0, 0, -1, 5, -1, 0, 0, 0, -1, 0, 0, 0, 0, 0, 0, 0]]
        case "filter.blur.smartBlur": ["threshold": 60]
        default: [:]
        }
    }

    @Test func idsMatchTheMenuCatalogAndAreUnique() {
        let s = Session()
        for id in Self.ids {
            #expect(s.registry.contains(id), "\(id) not registered")
            #expect(s.registry.specs.filter { $0.id == id }.count == 1, "\(id) registered twice")
            #expect(FilterCommands.paramsFor(id, .null) != nil, "\(id) has no params mapping")
        }
        #expect(s.registry.contains("filter.distort.displace"))
    }

    @Test func everyNewFilterRunsChangesPixelsAndUndoesInOneStep() throws {
        for id in Self.ids {
            let s = try session()
            let before = pixels(s)
            let depth = steps(s)
            let r = try s.execute(id, testParams(id))
            #expect(r["filter"] != nil, "\(id)")
            #expect(pixels(s) != before, "\(id) changed nothing")
            #expect(steps(s) == depth + 1, "\(id) is one history step")
            try s.execute("edit.undo", [:])
            #expect(pixels(s) == before, "\(id) undo")
        }
    }

    @Test func newFiltersWorkAt16And32Bit() throws {
        for (depth, mode) in [(16, "rgb"), (32, "rgb"), (8, "cmyk"), (16, "lab"), (8, "gray")] {
            let s = Session()
            try s.execute("file.new", ["width": 24, "height": 16, "depth": .int(depth), "mode": .string(mode)])
            try s.execute("layer.new.layer", [:])
            _ = try? s.execute("edit.fill", ["color": "#3366cc"])
            for id in Self.ids {
                do { try s.execute(id, testParams(id)) } catch { Issue.record("\(id) at \(depth)-bit \(mode): \(error)") }
            }
        }
    }

    @Test func disabledWithoutPixelLayer() throws {
        let s = Session()
        for id in Self.ids { #expect(!s.isEnabled(id), "\(id)") }
        try s.execute("file.new", ["width": 8, "height": 8])
        try s.execute("layer.newAdjustmentLayer.invert", [:])
        #expect(!s.isEnabled("filter.stylize.oilPaint"))
    }

    @Test func selectionLimitsNewFilters() throws {
        let s = try session()
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 12, "height": 12])
        let before = pixels(s)
        try s.execute("filter.pixelate.crystallize", ["cellSize": 4])
        let after = pixels(s)
        let far = (28 * 48 + 40) * 4
        #expect(after[far..<(far + 4)] == before[far..<(far + 4)])
        #expect(after[..<(12 * 4)] != before[..<(12 * 4)])
    }

    @Test func lastFilterRepeatsNewFilters() throws {
        let s = try session()
        try s.execute("filter.stylize.diffuse", ["seed": 3])
        let once = pixels(s)
        #expect(s.isEnabled("filter.lastFilter"))
        try s.execute("filter.lastFilter", [:])
        #expect(pixels(s) != once)
    }

    @Test func colourFiltersUseAndRecordToolColours() throws {
        let s = try session()
        s.tools.foreground = SIMD4(1, 0, 0, 1)
        s.tools.background = SIMD4(0, 0, 1, 1)
        let r = try s.execute("filter.render.fibers", ["seed": 1])
        #expect(r["filter"]?["foreground"] == [1.0, 0.0, 0.0, 1.0])
        let px = pixels(s)
        for k in stride(from: 0, to: px.count, by: 4) {
            #expect(px[k + 1] < 1e-2 && abs(px[k] + px[k + 2] - 1) < 2e-2, "\(px[k..<(k + 4)])")
        }
    }

    @Test func displaceReadsAnotherDocument() throws {
        let s = try session()
        // Map document: a flat colour that shifts 3 px right at 25 % (see the algo test).
        try s.execute("file.new", ["width": 8, "height": 8, "depth": 32])
        let v: Float = 0.5 + 3.0 / 64.0
        try s.edit("map") { doc, _ in
            let bg = doc.layers[0].id
            _ = doc.withRaster(of: bg) { surf in surf.fill(PixelRect(x0: 0, y0: 0, x1: 8, y1: 8), with: [v, 0.5, 0.5, 1]) }
        }
        _ = s.setActive(0)
        let before = pixels(s)
        #expect(throws: (any Error).self, "needs a map") { try s.execute("filter.distort.displace", [:]) }
        try s.execute("filter.distort.displace", ["mapDocument": 1, "horizontal": 25, "vertical": 0, "fit": "tile", "undefinedAreas": "wrap"])
        let after = pixels(s)
        func at(_ v: [Float], _ x: Int, _ y: Int) -> Float { v[(y * 48 + x) * 4] }
        for x in 5..<40 {
            #expect(abs(at(after, x, 10) - at(before, x + 3, 10)) < 1e-2, "x=\(x)")
        }
    }

    @Test func lensBlurUsesTheLayerMaskAsDepth() throws {
        let s = try session()
        try s.execute("layer.layerMask.revealAll", [:])
        let before = pixels(s)
        // Reveal-all mask = depth 1 everywhere; focal distance 255 puts it all in focus.
        try s.execute("filter.blur.lensBlur", ["radius": 6, "depthMap": "layerMask", "focalDistance": 255])
        #expect(pixels(s) == before)
        try s.execute("filter.blur.lensBlur", ["radius": 6, "depthMap": "layerMask", "focalDistance": 0])
        #expect(pixels(s) != before)
    }

    @Test func paramsMapToAlgorithmUnits() throws {
        #expect(FilterCommands.paramsFor("filter.pixelate.crystallize", ["cellSize": 1])?.filter as? Crystallize == Crystallize(cellSize: 3, seed: 0))
        #expect(FilterCommands.paramsFor("filter.stylize.traceContour", ["level": 300, "edge": "upper"])?.filter as? TraceContour
            == TraceContour(level: 255, upper: true))
        let iris = try #require(FilterCommands.paramsFor("filter.blurGallery.irisBlur", ["pins": [["x": 0.2, "blur": 30], ["x": 0.8]]])?.filter as? IrisBlur)
        #expect(iris.pins.count == 2)
        #expect(iris.pins[0].blur == 30)
        #expect(iris.pins[1].blur == IrisPin().blur)
        let shear = try #require(FilterCommands.paramsFor("filter.distort.shear", ["points": [[0, 0.1], [1, -0.1]]])?.filter as? Shear)
        #expect(shear.points == [SIMD2(0, 0.1), SIMD2(1, -0.1)])
        #expect(FilterCommands.paramsFor("filter.nope", [:]) == nil)
        #expect(FilterCommands.paramsFor("filter.render.relight", [:])?.filter as? Relight
            == Relight(angle: 45, elevation: 40, intensity: 40, ambient: 55, warmth: 0, softness: 25))
    }

    func paintShadedDisc(_ s: Session, _ size: Int) throws {
        try s.edit("disc") { doc, active in
            guard let id = active else { throw EngineError.other("no active layer") }
            let cx = Float(size) / 2
            let rad = Float(size) * 0.42
            var px: [SIMD4<Float>] = []
            for y in 0..<size {
                for x in 0..<size {
                    let dx = Float(x) + 0.5 - cx
                    let dy = Float(y) + 0.5 - cx
                    let d2 = dx * dx + dy * dy
                    if d2 <= rad * rad {
                        let nz = max(rad * rad - d2, 0).squareRoot() / rad
                        let sh = 0.22 + 0.78 * nz
                        px.append(SIMD4(0.55 * sh, 0.55 * sh, 0.55 * sh, 1))
                    } else {
                        px.append(SIMD4(0.18, 0.18, 0.18, 1))
                    }
                }
            }
            _ = doc.withRaster(of: id) { surf in surf.writeRGBA(PixelRect(x0: 0, y0: 0, x1: Int32(size), y1: Int32(size)), px) }
        }
    }

    func relightSession(_ w: Int, _ h: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": .int(w), "height": .int(h)])
        try s.execute("layer.new.layer", [:])
        try paintShadedDisc(s, min(w, h))
        return s
    }

    @Test func relightCommandExistsAndTogglesWithDocument() throws {
        let spec = try #require(Session().registry.spec("filter.render.relight"), "registered")
        #expect(spec.menu == ["Filter", "Render"])
        #expect(spec.label == "Relight…")
        #expect(spec.journal)
        let s = Session()
        #expect(!s.isEnabled("filter.render.relight"))
        try s.execute("file.new", ["width": 32, "height": 32])
        try s.execute("layer.new.layer", [:])
        #expect(s.isEnabled("filter.render.relight"))
        try s.execute("type.create", ["x": 8, "y": 16, "text": "Hi", "size": 12])
        #expect(!s.isEnabled("filter.render.relight"))
    }

    @Test func relightIsDisabledOnAPixelLockedLayer() throws {
        let s = try relightSession(32, 32)
        #expect(s.isEnabled("filter.render.relight"))
        try s.execute("layer.setProps", ["locks": ["pixels": true]])
        #expect(!s.isEnabled("filter.render.relight"))
        #expect(throws: (any Error).self) { try s.execute("filter.render.relight", [:]) }
    }

    @Test func relightDefaultsChangeAShadedDiscAndUndo() throws {
        let s = try relightSession(48, 48)
        let r = PixelRect(x0: 0, y0: 0, x1: 48, y1: 48)
        let before = pixels(s, r)
        let depth = steps(s)
        try s.execute("filter.render.relight", [:])
        #expect(pixels(s, r) != before)
        #expect(steps(s) == depth + 1)
        try s.execute("edit.undo", [:])
        #expect(pixels(s, r) == before)
    }

    @Test func relightRecordsASmartFilterAndCanBeHidden() throws {
        let s = try relightSession(32, 32)
        let r = PixelRect(x0: 0, y0: 0, x1: 32, y1: 32)
        let before = pixels(s, r)
        try s.execute("filter.convertForSmartFilters")
        try s.execute("filter.render.relight", ["angle": 180, "intensity": 70])
        let d = try #require(s.active)
        let layer = try #require(d.activeLayer.flatMap { d.doc.layer($0) })
        guard case .smart(let sm) = layer.content else {
            Issue.record("expected a smart object")
            return
        }
        #expect(sm.smartFilters.contains { $0.command == "filter.render.relight" })
        #expect(pixels(s, r) != before)
        // Hiding it re-renders the object from its source.
        try s.execute("layer.smartFilter.setVisible", ["index": 0, "visible": false])
        #expect(pixels(s, r) == before)
    }

    @Test func relightRejectsBadParams() throws {
        let s = try relightSession(16, 16)
        #expect(throws: (any Error).self) { try s.execute("filter.render.relight", ["intensity": 999]) }
        #expect(throws: (any Error).self) { try s.execute("filter.render.relight", ["elevation": -3]) }
        #expect(throws: (any Error).self) { try s.execute("filter.render.relight", ["angle": "east"]) }
        #expect(throws: (any Error).self) { try s.execute("filter.render.relight", ["softness": 0]) }
        // This engine's dispatch reads null params as `{}`; the command itself refuses null.
        let spec = try #require(s.registry.spec("filter.render.relight"))
        #expect(throws: EngineError.bad("filter.render.relight", "params must be a JSON object")) { try spec.run(s, .null) }
        #expect(throws: EngineError.bad("filter.render.relight", #""softness" must be in 1..100"#)) {
            try s.execute("filter.render.relight", ["softness": 0])
        }
        #expect(throws: EngineError.bad("filter.render.relight", #""angle" must be a number"#)) {
            try s.execute("filter.render.relight", ["angle": "east"])
        }
    }

    @Test func relightHonoursTheSelection() throws {
        let s = try relightSession(48, 32)
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 12, "height": 12])
        let before = pixels(s)
        try s.execute("filter.render.relight", ["angle": 180, "intensity": 70])
        let after = pixels(s)
        let far = (28 * 48 + 40) * 4
        #expect(after[far..<(far + 4)] == before[far..<(far + 4)])
        #expect(after[..<(12 * 4)] != before[..<(12 * 4)])
    }

    /// Not a photocraft test: every filters_ext id is registered with photocraft's metadata.
    @Test func specsMatchThePhotocraftCatalogue() {
        var r = CommandRegistry()
        r.install(FiltersExtCommands.self)
        let mine = PhotocraftCatalog.commands.filter { $0.module == FiltersExtCommands.name }
        #expect(mine.count == 32)
        #expect(Set(r.specs.map(\.id)) == Set(mine.map(\.id)))
        for spec in r.specs {
            guard let c = PhotocraftCatalog.byId[spec.id] else {
                Issue.record("\(spec.id) is not a photocraft command")
                continue
            }
            #expect(spec.isAvailable, "\(spec.id)")
            #expect(spec.label == c.label && spec.menu == c.menu && spec.shortcut == c.shortcut && spec.module == c.module, "\(spec.id)")
            #expect(spec.params == c.params, "\(spec.id)")
            #expect(spec.journal, "\(spec.id)")
        }
    }

    /// Not a photocraft test: a flat image file is a displacement map (`mapPath`), so is a layered
    /// PSD (imported by PCIO; `mapLayer` picks one of its layers), and an unreadable or missing
    /// one is an error.
    @Test func displaceReadsAFlatMapFile() throws {
        let s = try session()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filtersext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let map = Session()
        try map.execute("file.new", ["width": 8, "height": 8])
        try map.execute("edit.fill", ["color": "#ffffff"])
        let png = try map.services.renderer.png(try #require(map.active).doc, maxSide: 0)
        let path = dir.appendingPathComponent("map.png").path
        try png.write(to: URL(fileURLWithPath: path))
        let before = pixels(s)
        try s.execute("filter.distort.displace", ["mapPath": .string(path), "horizontal": 10, "vertical": 0, "fit": "tile", "undefinedAreas": "wrap"])
        #expect(pixels(s) != before)
        let layered = dir.appendingPathComponent("layered.psd").path
        try map.execute("layer.new.layer", ["name": "black"])
        try map.execute("edit.fill", ["color": "#000000"])
        try map.saveDocument(to: layered)
        dropForOracle(URL(fileURLWithPath: layered), as: "filtersext-displace-map.psd")
        let blackLayer = try #require(map.active?.activeLayer)
        let before2 = pixels(s)
        try s.execute("filter.distort.displace", ["mapPath": .string(layered), "mapLayer": .id(blackLayer), "horizontal": 10, "vertical": 0,
                                                  "fit": "tile", "undefinedAreas": "wrap"])
        #expect(pixels(s) != before2, "the PSD's layer displaces")
        let psd = dir.appendingPathComponent("map.psd").path
        try Data("8BPS".utf8).write(to: URL(fileURLWithPath: psd))
        #expect(throws: (any Error).self) { try s.execute("filter.distort.displace", ["mapPath": .string(psd)]) }
        #expect(throws: (any Error).self) { try s.execute("filter.distort.displace", ["mapPath": .string(dir.appendingPathComponent("none.png").path)]) }
    }
}
