// Port of photocraft-engine (crates/engine/src/filters/validation.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Every photocraft test is ported. Deviations: this engine's JSON numbers are doubles, so a
// whole-valued float (`1.0`) passes as an unsigned seed/layer id where serde's `as_u64` refuses it
// (only `0.5`-style fractions are rejected), and "the document didn't change" compares the
// document value and revision instead of photocraft's `Arc` identity.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct FilterValidationTests {
    func session(_ depth: Int) throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 12, "depth": .int(depth)])
        try s.execute("layer.new.layer", [:])
        try s.edit("pattern") { doc, active in
            guard let id = active else { throw EngineError.other("no active layer") }
            _ = doc.withRaster(of: id) { surf in
                surf.writeRGBA(PixelRect(x0: 0, y0: 0, x1: 8, y1: 12), Array(repeating: SIMD4(0.2, 0.6, 0.8, 1), count: 8 * 12))
            }
        }
        return s
    }

    func rejected(_ s: Session, _ id: String, _ key: String, _ value: JSONValue, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let st = s.active else {
            Issue.record("no document", sourceLocation: sourceLocation)
            return
        }
        let doc = st.doc, revision = st.revision, history = st.history.entries, journal = s.journal, active = st.activeLayer
        do {
            try s.execute(id, .object([key: value]))
            Issue.record("\(id): \(key)=\(value) was accepted", sourceLocation: sourceLocation)
        } catch let e as EngineError {
            guard case .badParams = e else {
                Issue.record("\(id): \(e)", sourceLocation: sourceLocation)
                return
            }
            #expect(e.description.contains(id) && e.description.contains(key), "\(e)", sourceLocation: sourceLocation)
        } catch {
            Issue.record("\(id): \(error)", sourceLocation: sourceLocation)
        }
        #expect(s.active?.doc == doc && s.active?.revision == revision, "\(id): \(key)", sourceLocation: sourceLocation)
        #expect(s.active?.history.entries == history, sourceLocation: sourceLocation)
        #expect(s.active?.activeLayer == active, sourceLocation: sourceLocation)
        #expect(s.journal == journal, sourceLocation: sourceLocation)
        #expect(s.runningJobs.isEmpty, sourceLocation: sourceLocation)
    }

    @Test func everyCoreFilterRejectsUnknownKeysWithoutEditing() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            for spec in FilterCommands.specs() where spec.id != "filter.lastFilter" {
                rejected(s, spec.id, "radus", 3)
            }
        }
    }

    @Test func coreFilterNumbersRejectWrongTypesAndDocumentedRangeViolations() throws {
        // Each numeric field in the core registry, independently of the validation table.
        let cases: [(String, String, Double, Double)] = [
            ("blur.gaussianBlur", "radius", 0.1, 1000),
            ("blur.boxBlur", "radius", 1, 2000),
            ("blur.motionBlur", "angle", -360, 360),
            ("blur.motionBlur", "distance", 1, 2000),
            ("blur.radialBlur", "amount", 1, 100),
            ("blur.radialBlur", "centerX", 0, 1),
            ("blur.radialBlur", "centerY", 0, 1),
            ("blur.surfaceBlur", "radius", 1, 100),
            ("blur.surfaceBlur", "threshold", 2, 255),
            ("sharpen.unsharpMask", "amount", 1, 500),
            ("sharpen.unsharpMask", "radius", 0.1, 1000),
            ("sharpen.unsharpMask", "threshold", 0, 255),
            ("sharpen.smartSharpen", "amount", 1, 500),
            ("sharpen.smartSharpen", "radius", 0.1, 64),
            ("sharpen.smartSharpen", "reduceNoise", 0, 100),
            ("noise.addNoise", "amount", 0.1, 400),
            ("noise.median", "radius", 1, 500),
            ("noise.dustAndScratches", "radius", 1, 500),
            ("noise.dustAndScratches", "threshold", 0, 255),
            ("pixelate.mosaic", "cellSize", 2, 200),
            ("stylize.emboss", "angle", -180, 180),
            ("stylize.emboss", "height", 1, 100),
            ("stylize.emboss", "amount", 1, 500),
            ("distort.twirl", "angle", -999, 999),
            ("distort.pinch", "amount", -100, 100),
            ("distort.spherize", "amount", -100, 100),
            ("distort.wave", "generators", 1, 999),
            ("distort.wave", "wavelengthMin", 1, 998),
            ("distort.wave", "wavelengthMax", 2, 999),
            ("distort.wave", "amplitudeMin", 1, 998),
            ("distort.wave", "amplitudeMax", 1, 999),
            ("distort.ripple", "amount", -999, 999),
            ("other.highPass", "radius", 0.1, 1000),
            ("other.minimum", "radius", 0.2, 500),
            ("other.maximum", "radius", 0.2, 500),
        ]
        for depth in [8, 16, 32] {
            let s = try session(depth)
            for (suffix, key, lo, hi) in cases {
                let id = "filter.\(suffix)"
                for value: JSONValue in ["big", true, .null, [], [:], .number(lo - 0.01), .number(hi + 0.01)] {
                    rejected(s, id, key, value)
                }
                // Large limits are validated without allocating a large blur kernel.
                for value in [lo, hi] {
                    #expect(throws: Never.self) { try FilterValidation.validateParams(id, .object([key: .number(value)])) }
                }
            }
            for key in ["horizontal", "vertical"] {
                rejected(s, "filter.other.offset", key, "4")
            }
        }
    }

    @Test func coreFilterChoicesBooleansSeedsAndSharedFieldsAreValidated() throws {
        let s = try session(8)
        for (suffix, key, choices) in [
            ("blur.radialBlur", "method", "spin|zoom"),
            ("blur.radialBlur", "quality", "draft|good|best"),
            ("noise.addNoise", "distribution", "uniform|gaussian"),
            ("distort.spherize", "mode", "normal|horizontalOnly|verticalOnly"),
            ("distort.wave", "type", "sine|triangle|square"),
            ("distort.wave", "undefinedAreas", "wrap|repeat"),
            ("distort.ripple", "size", "small|medium|large"),
            ("distort.polarCoordinates", "mode", "rectangularToPolar|polarToRectangular"),
            ("other.minimum", "preserve", "squareness|roundness"),
            ("other.maximum", "preserve", "squareness|roundness"),
            ("other.offset", "undefinedAreas", "wrap|repeat|transparent"),
        ] {
            let id = "filter.\(suffix)"
            for value: JSONValue in ["typo", false, 1, .null] {
                rejected(s, id, key, value)
            }
            for value in choices.split(separator: "|") {
                #expect(throws: Never.self) { try FilterValidation.validateParams(id, .object([key: .string(String(value))])) }
            }
        }
        for value: JSONValue in ["true", 0, .null] {
            rejected(s, "filter.noise.addNoise", "monochromatic", value)
        }
        for id in ["filter.noise.addNoise", "filter.distort.wave"] {
            for value: JSONValue in [-1, 4_294_967_296, 0.5, "12"] {
                rejected(s, id, "seed", value)
            }
            // A valid u32 seed must not be saturated through an i32 helper.
            let result = try s.execute(id, ["seed": .int(UInt32.max)])
            #expect(result["filter"]?["seed"] == .int(UInt32.max))
        }
        for (key, value): (String, JSONValue) in [("layer", "2"), ("target", "typo"), ("target", ["channel": -1]), ("coalesce", false)] {
            rejected(s, "filter.blur.gaussianBlur", key, value)
        }
    }

    @Test func extendedFilterChoicesMatchTheirSpecsAndRejectUnlistedValues() throws {
        let s = try session(8)
        let specs = FiltersExtCommands.specs()
        let ids = [
            "filter.pixelate.mezzotint",
            "filter.stylize.diffuse",
            "filter.stylize.extrude",
            "filter.stylize.tiles",
            "filter.stylize.traceContour",
            "filter.stylize.wind",
            "filter.distort.displace",
            "filter.distort.shear",
            "filter.distort.zigZag",
            "filter.render.lensFlare",
            "filter.render.lightingEffects",
            "filter.blur.smartBlur",
            "filter.blur.lensBlur",
            "filter.blur.shapeBlur",
            "filter.other.hsbHsl",
            "filter.video.deInterlace",
        ]
        for id in ids {
            let doc = try #require(specs.first { $0.id == id }).params
            for (key, allowed) in try #require(FilterValidation.choices(id)) {
                // The table repeats the registry's params doc, so the two cannot drift apart.
                #expect(doc.contains("\"\(key)\":\"\(allowed)\""), "\(id).\(key)")
                for value: JSONValue in ["zzbogus", false, 1, .null] {
                    rejected(s, id, key, value)
                }
                for value in allowed.split(separator: "|") {
                    #expect(throws: Never.self) { try FilterValidation.validateParams(id, .object([key: .string(String(value))])) }
                }
            }
        }
        // Keys `prepare` injects, and undocumented ones, stay accepted as before.
        try s.execute("filter.stylize.tiles", ["count": 4, "foreground": [1, 0, 0, 1]])
        try s.execute("filter.stylize.wind", ["direction": "fromLeft"])
    }

    @Test func invalidFiltersLeaveFloatingSelectionAndBackgroundJobsAlone() throws {
        let s = try session(16)
        try s.execute("select.rect", ["x": 0, "y": 0, "width": 4, "height": 4])
        try s.execute("select.float", ["dx": 8])
        let st = try #require(s.active)
        let doc = st.doc, revision = st.revision, history = st.history.entries
        let spec = try #require(s.registry.spec("filter.blur.gaussianBlur"))
        for params: JSONValue in [["radius": "big"], ["radus": 3], ["radius": 5000], ["radius": -4]] {
            #expect(throws: (any Error).self) { try s.start("filter.blur.gaussianBlur", params) }
            #expect(throws: (any Error).self) { try spec.run(s, params) }
            #expect(FloatCommands.floating(try #require(s.active)) != nil)
            #expect(s.active?.doc == doc && s.active?.revision == revision)
            #expect(s.active?.history.entries == history)
            #expect(s.runningJobs.isEmpty)
        }
    }

    @Test func validFiltersKeepDefaultsExplicitTargetsAndUndoRedo() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let layer = try #require(s.active?.activeLayer)
            let r = PixelRect(x0: 0, y0: 0, x1: 16, y1: 12)
            func pixels() -> [Float] { s.active?.doc.layer(layer)?.surface?.readRegion(r) ?? [] }
            let before = pixels()
            for params: JSONValue in [.null, [:]] {
                let result = try s.execute("filter.blur.gaussianBlur", params)
                #expect(result["filter"]?["radius"] == 1.0)
                #expect(pixels() != before)
                _ = s.undo()
                #expect(pixels() == before)
            }
            try s.execute("layer.new.layer", [:])
            let other = try #require(s.active?.activeLayer)
            let result = try s.execute("filter.blur.gaussianBlur", ["radius": 3, "layer": .id(layer), "target": "pixels", "coalesce": "blur"])
            #expect(result["filter"]?["radius"] == 3.0)
            let after = pixels()
            #expect(after != before)
            #expect(s.active?.doc.layer(other)?.surface?.tileCount == 0)
            _ = s.undo()
            #expect(pixels() == before)
            _ = s.redo()
            #expect(pixels() == after)
        }
    }

    @Test func injectedChannelTargetsAndExtendedFilterColoursKeepWorking() throws {
        let s = try session(8)
        try s.execute("channel.new", ["fill": "white"])
        let layers = try #require(s.active).doc.layers
        try s.execute("filter.noise.addNoise", ["amount": 40, "seed": 2])
        #expect(s.active?.doc.layers == layers)
        let channel = try #require(s.active?.doc.channels.first)
        #expect(channel.surface.readRegion(PixelRect(x0: 0, y0: 0, x1: 16, y1: 12)).contains { $0 < 0.99 })
        try s.execute("channel.target", ["channel": "composite"])
        s.tools.foreground = SIMD4(0, 0, 1, 1)
        s.tools.background = SIMD4(1, 0, 0, 1)
        let params = FiltersExtCommands.prepare(s, "filter.render.fibers", [:])
        #expect(params["foreground"] == .rgba(s.tools.foreground))
        #expect(params["background"] == .rgba(s.tools.background))
        try s.execute("filter.render.fibers", params)
    }

    /// Not a photocraft test: the messages are photocraft's, and keys are checked in order.
    @Test func messagesArePhotocrafts() {
        func message(_ id: String, _ p: JSONValue) -> String? {
            do { try FilterValidation.validateParams(id, p) } catch { return "\(error)" }
            return nil
        }
        #expect(message("filter.blur.gaussianBlur", ["radius": 0]) == "invalid parameters for `filter.blur.gaussianBlur`: `radius` must be a number in 0.1..1000")
        #expect(message("filter.noise.addNoise", ["seed": -1]) == "invalid parameters for `filter.noise.addNoise`: `seed` must be an integer in 0..4294967295")
        #expect(message("filter.other.offset", ["horizontal": "4"]) == "invalid parameters for `filter.other.offset`: `horizontal` must be a finite number")
        #expect(message("filter.blur.gaussianBlur", ["zeta": 1, "alpha": 2]) == "invalid parameters for `filter.blur.gaussianBlur`: unknown parameter `alpha`")
        #expect(message("filter.blur.gaussianBlur", [1]) == "invalid parameters for `filter.blur.gaussianBlur`: params must be a JSON object")
        #expect(message("filter.stylize.wind", ["method": "gust"]) == "invalid parameters for `filter.stylize.wind`: `method` must be one of wind|blast|stagger")
        #expect(message("filter.blur.gaussianBlur", ["target": 3])
            == #"invalid parameters for `filter.blur.gaussianBlur`: `target` must be pixels, mask, quickMask or {"channel":index}"#)
        #expect(message("filter.blur.gaussianBlur", .null) == nil)
        #expect(message("filter.gallery.unknown", ["anything": 1]) == nil)
    }
}
