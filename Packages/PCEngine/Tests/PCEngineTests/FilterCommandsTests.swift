// Port of photocraft-engine (crates/engine/src/filters.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
@testable import PCEngine
import PCAlgo
import PCDocument
import PCFoundation
import Testing

@Suite struct FilterCommandsTests {
    /// A 48×32 document with a filled layer above the Background (photocraft `session`).
    func session() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 48, "height": 32])
        try s.execute("layer.new.layer")
        _ = try? s.execute("edit.fill", ["color": "#3366cc"])
        return s
    }

    func activePixels(_ s: Session) throws -> [Float] {
        let d = try #require(s.active)
        let id = try #require(d.activeLayer)
        let surf = try #require(d.doc.layer(id)?.surface)
        return surf.readRegion(PixelRect(x: 0, y: 0, width: 48, height: 32))
    }

    func paintPattern(_ s: Session) throws {
        try s.edit("pattern") { doc, active in
            _ = doc.withRaster(of: active!) { surf in
                for y: Int32 in 0..<32 {
                    for x: Int32 in 0..<48 {
                        let v = Float((x * 5 + y * 3) % 17) / 16
                        surf.setPixel(x: x, y: y, [v, 1 - v, Float(x % 3) / 2, 1])
                    }
                }
            }
        }
    }

    func maskSession(revealSelection: Bool) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 16, "background": "#ff0000"])
        if revealSelection {
            try s.execute("select.all")
            try s.execute("layer.layerMask.revealSelection")
        } else {
            try s.execute("layer.layerMask.revealAll")
        }
        return s
    }

    func activeLayer(_ s: Session) throws -> Layer {
        let d = try #require(s.active)
        let id = try #require(d.activeLayer)
        return try #require(d.doc.layer(id))
    }

    func maskPixels(_ s: Session) throws -> [Float] {
        let mask = try #require(try activeLayer(s).mask)
        return mask.surface.readRegion(try #require(s.active).doc.bounds)
    }

    func canvasPixels(_ s: Session) throws -> [Float] {
        let surf = try #require(try activeLayer(s).surface)
        return surf.readRegion(try #require(s.active).doc.bounds)
    }

    static let all = [
        "filter.blur.gaussianBlur", "filter.blur.boxBlur", "filter.blur.motionBlur", "filter.blur.radialBlur", "filter.blur.surfaceBlur",
        "filter.sharpen.unsharpMask", "filter.sharpen.smartSharpen", "filter.noise.addNoise", "filter.noise.median",
        "filter.noise.dustAndScratches", "filter.pixelate.mosaic", "filter.stylize.emboss", "filter.stylize.findEdges",
        "filter.stylize.solarize", "filter.distort.twirl", "filter.distort.pinch", "filter.distort.spherize", "filter.distort.wave",
        "filter.distort.ripple", "filter.distort.polarCoordinates", "filter.other.highPass", "filter.other.minimum",
        "filter.other.maximum", "filter.other.offset",
    ]

    @Test func everyFilterCommandRunsChangesPixelsAndUndoes() throws {
        for id in Self.all {
            let s = try session()
            try paintPattern(s)
            let before = try activePixels(s)
            let params: JSONValue = switch id {
            case "filter.other.offset": ["horizontal": 5, "vertical": 2]
            case "filter.noise.dustAndScratches": ["radius": 2, "threshold": 0]
            case "filter.noise.median": ["radius": 2]
            default: .object([:])
            }
            let r = try s.execute(id, params)
            #expect(r["filter"] != nil, "\(id)")
            #expect(try activePixels(s) != before, "\(id) changed nothing")
            try s.execute("edit.undo")
            #expect(try activePixels(s) == before, "\(id) undo")
        }
    }

    @Test func presetFiltersRecordTheirOwnName() throws {
        let specs = FilterCommands.specs()
        for (id, name) in [("filter.blur.blur", "Blur"), ("filter.blur.blurMore", "Blur More"), ("filter.sharpen.sharpen", "Sharpen"),
                           ("filter.sharpen.sharpenMore", "Sharpen More"), ("filter.sharpen.sharpenEdges", "Sharpen Edges"),
                           ("filter.noise.despeckle", "Despeckle"), ("filter.blur.gaussianBlur", "Gaussian Blur"),
                           ("filter.sharpen.unsharpMask", "Unsharp Mask"), ("filter.blur.surfaceBlur", "Surface Blur")] {
            let s = try session()
            let steps = try #require(s.active).history.pastCount
            try s.execute(id)
            let h = try #require(s.active).history
            #expect(h.pastCount == steps + 1 && h.undoLabel == name, "\(id): \(String(describing: h.undoLabel))")
            let label = try #require(specs.first { $0.id == id }).label
            #expect(label.replacingOccurrences(of: "…", with: "") == name, "\(id): the step is named like the command")
        }
    }

    @Test func specsAreCompleteAndDocumented() throws {
        let specs = FilterCommands.specs()
        for id in Self.all {
            let spec = try #require(specs.first { $0.id == id }, "missing \(id)")
            #expect(spec.params.hasPrefix("{"), "\(id)")
            #expect(!spec.menu.isEmpty, "\(id)")
        }
        // Every id is photocraft's, with photocraft's metadata.
        for spec in specs {
            let c = try #require(PhotocraftCatalog.byId[spec.id], "\(spec.id) is not a photocraft id")
            #expect(spec.label == c.label && spec.menu == c.menu && spec.shortcut == c.shortcut && spec.params == PhotocraftExtensions.expected(c), "\(spec.id)")
        }
    }

    @Test func disabledWithoutPixelLayer() throws {
        let s = Session()
        #expect(!s.isEnabled("filter.blur.gaussianBlur"))
        try s.execute("file.new", ["width": 8, "height": 8])
        try s.execute("layer.newAdjustmentLayer.invert")
        do {
            try s.execute("filter.blur.gaussianBlur")
            Issue.record("ran on an adjustment layer")
        } catch {
            if case .disabled? = error as? EngineError {} else { Issue.record("\(error)") }
        }
    }

    /// `"preserveTransparency": true` filters the colour alone: the layer keeps its alpha, as a transparency-locked
    /// layer does, without having the lock.
    @Test func preserveTransparencyKeepsTheLayersAlpha() throws {
        func blurred(_ params: JSONValue) throws -> (alphaBefore: [Float], after: [Float]) {
            let s = Session()
            try s.execute("file.new", ["width": 48, "height": 32])
            try s.execute("layer.new.layer")
            try s.edit("square") { doc, active in
                _ = doc.withRaster(of: active!) {
                    $0.fill(PixelRect(x0: 16, y0: 8, x1: 24, y1: 24), with: [1, 0, 0, 1])
                    $0.fill(PixelRect(x0: 24, y0: 8, x1: 32, y1: 24), with: [0, 0, 1, 1])
                }
            }
            let before = try activePixels(s)
            try s.execute("filter.blur.gaussianBlur", params)
            return (stride(from: 3, to: before.count, by: 4).map { before[$0] }, try activePixels(s))
        }
        let plain = try blurred(["radius": 4])
        let kept = try blurred(["radius": 4, "preserveTransparency": true])
        func alpha(_ px: [Float]) -> [Float] { stride(from: 3, to: px.count, by: 4).map { px[$0] } }
        #expect(alpha(plain.after) != plain.alphaBefore, "a plain blur spreads the alpha")
        #expect(alpha(kept.after) == kept.alphaBefore, "the alpha is as it was")
        // The colour did blur: at the seam between the red and blue halves (x 23, y 16) red is no longer 1.
        let seam = (16 * 48 + 23) * 4
        #expect(kept.after[seam] < 0.9 && kept.after[seam + 2] > 0.1, "\(kept.after[seam]) \(kept.after[seam + 2])")
        #expect(throws: (any Error).self) { _ = try blurred(["radius": 4, "preserveTransparency": "yes"]) }
    }

    /// AB-T-0690: a filter that keeps alpha (a transparency lock, or `"preserveTransparency": true`) leaves the layer's
    /// content bounds as they were. A blur used to leave colour under the clear pixels around the outline, so the
    /// bounds grew by its reach though nothing visible changed.
    @Test func keepingAlphaKeepsTheLayersBounds() throws {
        func bounds(radius: Double, lock: Bool) throws -> (before: PixelRect, after: PixelRect) {
            let s = Session()
            try s.execute("file.new", ["width": 80, "height": 60])
            try s.execute("layer.new.layer")
            let id = try #require(s.active?.activeLayer)
            try s.edit("square") { doc, _ in
                _ = doc.withRaster(of: id) {
                    $0.fill(PixelRect(x0: 20, y0: 15, x1: 40, y1: 45), with: [1, 0, 0, 1])
                    $0.fill(PixelRect(x0: 40, y0: 15, x1: 60, y1: 45), with: [0, 0, 1, 1])
                }
                if lock { doc.updateLayer(id) { $0.locks.transparency = true } }
            }
            let before = try #require(s.active?.doc.layer(id)?.surface?.contentBounds)
            try s.execute("filter.blur.gaussianBlur", lock ? ["radius": .number(radius)] : ["radius": .number(radius), "preserveTransparency": true])
            let surface = try #require(s.active?.doc.layer(id)?.surface)
            // The colour did blur across the seam.
            #expect(surface.pixel(x: 39, y: 30)[0] < 0.95)
            return (before, surface.contentBounds)
        }
        for radius in [0.5, 3, 12] {
            for lock in [false, true] {
                let b = try bounds(radius: radius, lock: lock)
                #expect(b.before == PixelRect(x0: 20, y0: 15, x1: 60, y1: 45) && b.after == b.before, "radius \(radius) lock \(lock): \(b.after)")
            }
        }
    }

    @Test func selectionLimitsTheFilter() throws {
        let s = try session()
        try paintPattern(s)
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 10, "height": 10])
        #expect(s.active?.doc.selection != nil)
        let before = try activePixels(s)
        try s.execute("filter.blur.gaussianBlur", ["radius": 3])
        let after = try activePixels(s)
        let i = (30 * 48 + 40) * 4, j = (5 * 48 + 5) * 4
        #expect(after[i..<(i + 4)] == before[i..<(i + 4)])
        #expect(after[j..<(j + 4)] != before[j..<(j + 4)])
    }

    @Test func solarizeAndAddNoiseProcessUntouchedRevealAllMasks() throws {
        let cases: [(String, JSONValue)] = [
            ("filter.stylize.solarize", ["target": "mask"]),
            ("filter.noise.addNoise", ["amount": 100, "seed": 1, "monochromatic": true, "target": "mask"]),
        ]
        for (id, params) in cases {
            let revealAll = try maskSession(revealSelection: false)
            let revealSelection = try maskSession(revealSelection: true)
            let allMask = try #require(try activeLayer(revealAll).mask)
            #expect(allMask.surface.contentBounds.isEmpty, "\(id): Reveal All stores its white canvas in the default pixel")
            let initialAll = try maskPixels(revealAll)
            #expect(initialAll == (try maskPixels(revealSelection)), "\(id): masks start with equal white values")
            #expect(initialAll == [Float](repeating: 1, count: 16 * 16), "\(id): the full canvas starts revealed")
            let pixelsBefore = try canvasPixels(revealAll)
            try revealAll.execute(id, params)
            try revealSelection.execute(id, params)
            let actual = try maskPixels(revealAll), expected = try maskPixels(revealSelection)
            #expect(actual == expected, "\(id): Reveal All differs from Reveal Selection")
            #expect(try canvasPixels(revealAll) == pixelsBefore, "\(id): the mask target must leave layer pixels unchanged")
            if id == "filter.stylize.solarize" {
                #expect(actual.allSatisfy { $0 == 0 }, "Solarize maps the white mask to black")
            } else {
                #expect(actual.contains { $0 != 1 }, "seeded Add Noise changes the Reveal All mask")
            }
        }
    }

    @Test func paramsMapToAlgorithmUnits() throws {
        let g = try #require(FilterCommands.paramsFor("filter.blur.gaussianBlur", ["radius": 4.5])?.filter as? GaussianBlur)
        #expect(g.radius == 4.5)
        let r = try #require(FilterCommands.paramsFor("filter.blur.radialBlur", ["quality": "best"])?.filter as? RadialBlur)
        #expect(r == RadialBlur(amount: 10, method: .spin, quality: .best, centerX: 0.5, centerY: 0.5))
        let n = try #require(FilterCommands.paramsFor("filter.noise.addNoise", ["amount": 10, "distribution": "gaussian", "monochromatic": true])?.filter as? AddNoise)
        #expect(n.amount == 10 && n.distribution == .gaussian && n.monochromatic && n.seed == 0)
        let clamped = try #require(FilterCommands.paramsFor("filter.blur.gaussianBlur", ["radius": -3])?.filter as? GaussianBlur)
        #expect(clamped.radius == 0.1)
        #expect(FilterCommands.paramsFor("filter.nope", .object([:])) == nil)
    }

    @Test func minimumMaximumPreserveRoundness() throws {
        for depth in [8, 16, 32] {
            let s = Session()
            try s.execute("file.new", ["width": 48, "height": 32, "depth": .int(depth)])
            try s.execute("layer.new.layer")
            // A white dot on black.
            try s.edit("dot") { doc, active in
                _ = doc.withRaster(of: active!) { surf in
                    surf.fill(PixelRect(x: 0, y: 0, width: 48, height: 32), with: [0, 0, 0, 1])
                    surf.setPixel(x: 24, y: 16, [1, 1, 1, 1])
                }
            }
            let before = try activePixels(s)
            func lit(_ x: Int, _ y: Int) throws -> Bool { try activePixels(s)[(y * 48 + x) * 4] > 0.5 }
            try s.execute("filter.other.maximum", ["radius": 4, "preserve": "roundness"])
            // Grown into a disc of radius 4: (4, 0) and (2, 3) are in, the square's corner isn't.
            #expect(try lit(28, 16) && lit(26, 19), "depth \(depth)")
            #expect(try !lit(28, 20) && !lit(27, 19), "depth \(depth)")
            try s.execute("edit.undo")
            #expect(try activePixels(s) == before)
            // The default is Squareness: the corner is taken.
            try s.execute("filter.other.maximum", ["radius": 4])
            #expect(try lit(28, 20), "depth \(depth)")
            // Minimum with roundness: only the centre of that 9×9 square holds a whole disc.
            try s.execute("filter.other.minimum", ["radius": 4, "preserve": "roundness"])
            #expect(try !lit(20, 12) && lit(24, 16), "depth \(depth)")
        }
        let mn = try #require(FilterCommands.paramsFor("filter.other.minimum", ["radius": 2, "preserve": "roundness"])?.filter as? Minimum)
        #expect(mn.radius == 2 && mn.preserve == .roundness)
        let mx = try #require(FilterCommands.paramsFor("filter.other.maximum", .object([:]))?.filter as? Maximum)
        #expect(mx.radius == 1 && mx.preserve == .squareness)
    }

    @Test func smartObjectRecordsSmartFilter() throws {
        let s = try session()
        try s.edit("smart") { doc, active in
            var cache = Surface(format: doc.pixelFormat)
            cache.fill(PixelRect(x: 0, y: 0, width: 10, height: 10), with: [1, 0, 0, 1])
            let l = Layer(name: "so", content: .smart(SmartObject(source: .linked(path: ""), transform: .identity, cache: cache)))
            active = doc.insertAbove(active, l)
        }
        try s.execute("filter.blur.gaussianBlur", ["radius": 2])
        guard case .smart(let sm) = try activeLayer(s).content else { Issue.record("not a smart object"); return }
        #expect(sm.smartFilters.count == 1)
        #expect(sm.smartFilters.first?.command == "filter.blur.gaussianBlur")
        #expect(sm.smartFilters.first?.params["radius"] == 2)
        #expect((sm.cache?.pixel(x: 10, y: 5)[3] ?? 0) > 0, "cache was blurred")
    }

    @Test func lastFilterRepeatsTheLatestFilterOnTheActiveLayer() throws {
        let s = try session()
        try paintPattern(s)
        #expect(s.disabledReason("filter.lastFilter") == "no filter applied yet")
        try s.execute("filter.blur.gaussianBlur", ["radius": 2])
        let once = try activePixels(s)
        try s.execute("filter.lastFilter")
        #expect(try activePixels(s) != once)
        #expect(s.active?.history.undoLabel == "Gaussian Blur")
    }

    @Test func aCancelledFilterJobLeavesTheDocument() throws {
        let s = try session()
        try paintPattern(s)
        let before = try activePixels(s)
        let started = try s.start("filter.blur.gaussianBlur", ["radius": 8])
        if case .job(let id) = started {
            _ = s.cancelJob(id)
            _ = try? s.waitJob(id)
            _ = s.pollJobs()
            #expect(try activePixels(s) == before)
        }
    }
}
