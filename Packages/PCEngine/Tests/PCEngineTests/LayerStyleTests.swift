// Port of photocraft-engine (crates/engine/src/layer_style.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// `edit.fill` (edit_cmds) is not in this package yet: the tests that filled a layer write the
// colour straight into the layer (`StyleTestSupport.fill`).

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCRender
import Testing

enum StyleTestSupport {
    static func session(_ w: Int = 32, _ h: Int = 32, extra: JSONValue = [:]) throws -> Session {
        let s = Session()
        try s.execute("file.new", JSONValue.object(["width": .int(w), "height": .int(h)]).merging(extra))
        return s
    }

    /// Edit › Fill with a colour on the active pixel layer over `rect` (else the canvas).
    static func fill(_ s: Session, _ rect: PixelRect? = nil, _ rgba: SIMD4<Float>) throws {
        let id = try #require(s.active?.activeLayer)
        try s.edit("Fill") { doc, _ in
            let r = rect ?? doc.bounds
            doc.withRaster(of: id) { surf in surf.fill(r, with: surf.format.components(fromRGBA: rgba)) }
        }
    }

    static func pixel(_ s: Session, _ x: Int, _ y: Int) throws -> [Float] {
        let v = try s.execute("document.pixel", ["x": .int(x), "y": .int(y)])
        return (v.arrayValue ?? []).map { Float($0.doubleValue ?? 0) }
    }

    static func effects(_ s: Session) -> [Effect] {
        guard let d = s.active, let id = d.activeLayer else { return [] }
        return d.doc.layer(id)?.effects.items ?? []
    }

    static func snapshot(_ fx: Effect) -> JSONValue { .encoded(fx) }
}

@Suite struct LayerStyleTests {
    typealias T = StyleTestSupport
    typealias LS = LayerStyleCommands

    func session() throws -> Session {
        let s = try T.session()
        try s.execute("layer.new.layer")
        return s
    }

    /// Every id of the ported modules is registered with photocraft's label, menu, shortcut and
    /// params, under its module.
    @Test func registeredSpecsMatchPhotocraftsCatalog() {
        let modules: Set<String> = ["layer_style", "gradient_fill_cmds", "solid_fill_cmds", "pattern_fill_cmds", "pattern_cmds", "presets"]
        let r = CommandRegistry.standard()
        for c in PhotocraftCatalog.commands where modules.contains(c.module) && !c.id.hasPrefix("cloneSource.") {
            guard let spec = r.spec(c.id) else { Issue.record("\(c.id) not registered"); continue }
            #expect(spec.label == c.label && spec.menu == c.menu && spec.shortcut == c.shortcut, "\(c.id)")
            // The catalogue couldn't expand photocraft's `format!`-built notations; those are checked by hand.
            if !c.params.hasSuffix("(see photocraft source)") { #expect(spec.params == c.params, "\(c.id) params") }
            #expect(spec.module == c.module, "\(c.id) module")
            #expect(spec.isAvailable || ["pattern.import", "pattern.export"].contains(c.id), "\(c.id) is \(spec.availability)")
        }
    }

    @Test func bevelCommandSetsTechniqueContourAndTexture() throws {
        let s = try session()
        try s.execute("layer.layerStyle.bevelEmboss", ["style": "pillow", "technique": "chiselHard", "contour": true, "contourRange": 70, "texture": "Bubbles",
                                                       "textureDepth": -200, "textureInvert": true])
        guard case .bevelEmboss(let b)? = T.effects(s).first else { Issue.record("no bevel"); return }
        #expect(b.style == .pillowEmboss && b.technique == .chiselHard)
        #expect(abs((b.contour?.range ?? 0) - 0.7) < 1e-6)
        let t = try #require(b.texture)
        #expect(t.name == "Bubbles" && t.depth == -2 && t.invert)
    }

    @Test func everyStyleCommandAddsItsEffect() throws {
        for kind in ["dropShadow", "innerShadow", "outerGlow", "innerGlow", "stroke", "colorOverlay", "gradientOverlay", "bevelEmboss", "satin"] {
            let s = try session()
            try s.execute("layer.layerStyle.\(kind)")
            let fx = T.effects(s)
            #expect(fx.count == 1, "\(kind)")
            #expect(fx.first?.isEnabled == true)
        }
    }

    /// #1543: a Satin or Bevel & Emboss size or softness far past Photoshop's range must still render.
    @Test func oversizedSatinAndBevelSizesRender() throws {
        let cases: [(String, JSONValue)] = [
            ("satin", ["size": 1e308]), ("satin", ["size": 1_000_000]), ("bevelEmboss", ["size": 1e308]), ("bevelEmboss", ["soften": 1e308]),
            ("bevelEmboss", ["size": 1_000_000, "soften": 1_000_000]),
        ]
        for (cmd, p) in cases {
            let s = try session()
            try T.fill(s, nil, SIMD4(1, 0, 0, 1))
            try s.execute("layer.layerStyle.\(cmd)", p)
            let start = Date()
            _ = try T.pixel(s, 0, 0)
            #expect(Date().timeIntervalSince(start) < 20, "\(cmd) \(p)")
        }
    }

    @Test func paramsAreAppliedAndReplaceOrAdd() throws {
        let s = try session()
        try s.execute("layer.layerStyle.stroke", ["size": 7, "position": "inside", "color": "#00ff00", "opacity": 50])
        guard case .stroke(let st)? = T.effects(s).first else { Issue.record("no stroke"); return }
        #expect(st.size == 7 && st.position == .inside && st.common.opacity == 0.5)
        #expect(st.paint == .color(.rgb(0, 1, 0)))
        try s.execute("layer.layerStyle.stroke", ["size": 2])
        #expect(T.effects(s).count == 1, "replaces")
        try s.execute("layer.layerStyle.stroke", ["size": 4, "add": true])
        #expect(T.effects(s).count == 2, "adds a second instance")
        try s.execute("layer.layerStyle.dropShadow", ["blend": "normal", "distance": 12])
        guard case .dropShadow(let sh)? = T.effects(s).last else { Issue.record("no shadow"); return }
        #expect(sh.common.blend == .normal && sh.distance == 12)
    }

    @Test func clearAndUndo() throws {
        let s = try session()
        try s.execute("layer.layerStyle.colorOverlay", ["color": "#ff0000"])
        try s.execute("layer.layerStyle.clear")
        #expect(T.effects(s).isEmpty)
        try s.execute("edit.undo")
        #expect(T.effects(s).count == 1)
    }

    /// #3102: an effect row dropped on the Delete button deletes only that effect, in one step.
    @Test func clearOneEffectByIndex() throws {
        let s = try session()
        try s.execute("layer.layerStyle.dropShadow")
        try s.execute("layer.layerStyle.colorOverlay", ["color": "#ff0000"])
        let layer = try #require(s.active?.activeLayer)
        try s.execute("layer.layerStyle.clear", ["layer": .id(layer), "effect": 0])
        let fx = T.effects(s)
        #expect(fx.count == 1)
        if case .colorOverlay? = fx.first {} else { Issue.record("expected the colour overlay to remain") }
        for bad: JSONValue in [["effect": 5], ["effect": -1], ["effect": "x"], ["effect": 0, "layer": 999_999]] {
            #expect(throws: EngineError.self) { try s.execute("layer.layerStyle.clear", bad) }
        }
        #expect(T.effects(s).count == 1, "bad params change nothing")
        try s.execute("edit.undo")
        #expect(T.effects(s).count == 2)
    }

    @Test func colorOverlayRenders() throws {
        let s = try T.session(8, 8)
        try s.execute("layer.layerStyle.colorOverlay", ["color": "#ff0000"])
        let px = try T.pixel(s, 3, 3)
        #expect(px[0] > 0.99 && px[1] < 0.01, "\(px)")
    }

    @Test func gradientStylesParse() {
        #expect(LS.gradientStyle("Radial") == .radial)
        #expect(LS.gradientStyle("diamond") == .diamond)
        #expect(LS.gradientStyle("?") == .linear)
    }

    @Test func everyKindHasFactoryDefaults() {
        for kind in ["dropShadow", "innerShadow", "outerGlow", "innerGlow", "stroke", "colorOverlay", "gradientOverlay", "patternOverlay", "satin", "bevelEmboss"] {
            #expect(!(LS.effectDefaults(kind).objectValue ?? [:]).isEmpty, "\(kind)")
            #expect(LS.effectFromParams(kind, [:]) != nil, "\(kind)")
        }
        #expect(LS.effectFromParams("nope", [:]) == nil)
    }

    @Test func replaceBuildsEditsAndPreservesInstances() throws {
        let s = try session()
        // Two strokes: the first edits a snapshot (params overlay), the second is fresh.
        let first = Effect.stroke(StrokeFx(common: FxCommon(.normal, 1), size: 7, position: .outside,
                                           paint: .gradient(StyleGradient(stops: [ColorStop(0, .rgb(0, 0, 1)), ColorStop(1, .white)]))))
        let r = try s.execute("layer.layerStyle.replace", ["effects": [
            ["kind": "stroke", "fx": T.snapshot(first), "params": ["opacity": 50]],
            ["kind": "stroke", "params": ["size": 2, "color": "#ffffff"]],
        ]])
        #expect(r["effects"] == 2)
        let fx = T.effects(s)
        #expect(fx.count == 2, "order preserved")
        guard fx.count == 2, case .stroke(let a) = fx[0], case .stroke(let b) = fx[1] else { Issue.record("\(fx)"); return }
        #expect(a.common.opacity == 0.5)
        // The overlay must not clobber the gradient paint it doesn't model.
        if case .gradient(let g) = a.paint {
            #expect(g.stops.count == 2 && g.stops[0].color == .rgb(0, 0, 1))
        } else {
            Issue.record("gradient paint lost")
        }
        #expect(b.size == 2 && b.paint == .color(.rgb(1, 1, 1)))
        // Replacing with an empty list clears the layer.
        try s.execute("layer.layerStyle.replace", ["effects": []])
        #expect(T.effects(s).isEmpty)
    }

    @Test func replaceRejectsBadEntriesGracefully() throws {
        let s = try session()
        let stroke = Effect.stroke(StrokeFx(common: FxCommon(.normal, 1), size: 3, position: .outside, paint: .color(.black)))
        let bad: [JSONValue] = [
            [:], ["effects": "nope"], ["effects": [["params": [:]]]], ["effects": [["kind": "nope"]]],
            ["effects": [["kind": "stroke", "fx": ["Bogus": [:]]]]], ["effects": [["kind": "stroke", "fx": 3]]],
            ["effects": [["kind": "dropShadow", "fx": T.snapshot(stroke)]]], ["effects": [["kind": "stroke", "fx": T.snapshot(stroke), "params": "nope"]]],
        ]
        for p in bad { #expect(throws: EngineError.self) { try s.execute("layer.layerStyle.replace", p) } }
        // A long list is refused, not run.
        let many = JSONValue.array((0..<257).map { _ in ["kind": "stroke"] })
        #expect(throws: EngineError.self) { try s.execute("layer.layerStyle.replace", ["effects": many]) }
        #expect(T.effects(s).isEmpty, "nothing was applied")
    }

    @Test func contourAndNoiseParamsEditExistingEffects() throws {
        let s = try session()
        try s.execute("layer.layerStyle.dropShadow")
        let before = T.effects(s)
        let fx0 = T.snapshot(before[0])
        try s.execute("layer.layerStyle.replace", ["effects": [["kind": "dropShadow", "fx": fx0, "params": ["contour": "Cone", "noise": 30]]]])
        guard case .dropShadow(let sh)? = T.effects(s).first else { Issue.record("no shadow"); return }
        #expect(sh.contour == LS.builtinContour("Cone"), "known preset applies")
        #expect(abs(sh.noise - 0.3) < 1e-6, "noise in percent")
        // An imported contour with an unknown name survives the same round trip.
        let imported = Contour.custom(.init(name: "Photoshop contour", points: [CurvePoint(input: 0, output: 1), CurvePoint(input: 1, output: 0)]))
        var carried = before[0]
        if case .dropShadow(var c) = carried {
            c.contour = imported
            carried = .dropShadow(c)
        }
        LS.overlayEffect(&carried, ["contour": "Photoshop contour"])
        if case .dropShadow(let after) = carried { #expect(after.contour == imported) }
        // Linear applies by name.
        LS.overlayEffect(&carried, ["contour": "Linear"])
        if case .dropShadow(let lin) = carried { #expect(lin.contour == .linear) }
    }

    @Test func contourPresetsMatchPhotoshop() throws {
        // Photoshop 27.11, measured through Satin: Cone and Cone − Inverted Satins are identical,
        // and Gaussian reads 0.36 at 0.5 through Satin but 0.64 as the preset curve (glows, gloss).
        func lut(_ name: String) throws -> [Float] {
            guard case .custom(let c)? = LS.builtinContour(name) else { throw EngineError.other(name) }
            return AdjustMath.contourCurveLUT(c.points, corners: c.corners)
        }
        func satin(_ name: String) throws -> [Float] {
            let c = try #require(LS.builtinContour(name))
            return try #require(EffectMath.satinLUT(c))
        }
        func at(_ l: [Float], _ x: Float) -> Float { l[Int((x * Float(l.count - 1)).rounded())] }
        // Settled against Photoshop 27.11 (PCRender phase 4, M1 raw Satin maps): a satin pixel is
        // |C(a) − C(b)| of the two blurred offset copies, so mirror-image contours (Cone and
        // Cone − Inverted, C and 1 − C) give identical satins (Photoshop's two maps: ≤ 2 levels
        // apart), and where one copy is fully inside (b = 1) a Gaussian satin reads
        // |G(0.5) − G(1)| = 0.36 at a = 0.5. `satinLUT` is the contour itself, applied per copy.
        let (cone, inverted) = (try satin("Cone"), try satin("Cone - Inverted"))
        let gaussianSatin = try satin("Gaussian")
        for x: Float in [0.1, 0.25, 0.5, 0.8] {
            #expect(abs(at(cone, x) + at(inverted, x) - 1) < 0.03, "\(x): \(at(cone, x)) + \(at(inverted, x))")
        }
        #expect(abs(abs(at(gaussianSatin, 0.5) - at(gaussianSatin, 1)) - 0.36) < 0.04)
        #expect(abs(at(try lut("Gaussian"), 0.5) - 0.64) < 0.03)
        #expect(abs(at(try lut("Cove - Deep"), 0) - 0.26) < 0.02, "Cove - Deep starts above zero")
    }

    @Test func contourPresetsAndCustomCurvesApplyInOneUndoStep() throws {
        let s = try session()
        // Picking Cone: the preset's own curve, in one undo step. Photoshop's Cone is smooth (no
        // corner points; re-measured from its Outer Glow renders, PCRender phase 5).
        try s.execute("layer.layerStyle.dropShadow", ["contour": "Cone", "antiAlias": true])
        guard case .dropShadow(let sh)? = T.effects(s).first, case .custom(let cc) = sh.contour else { Issue.record("no Cone"); return }
        #expect(sh.contour == LS.builtinContour("Cone"))
        #expect(!sh.contour.isCorner(1) && sh.antiAlias)
        let lut = AdjustMath.contourCurveLUT(cc.points, corners: cc.corners)
        func at(_ x: Float) -> Float { lut[Int((x * Float(lut.count - 1)).rounded())] }
        // Photoshop's measured Cone: 0 at both ends, a 0.99 peak at 0.5, symmetric.
        #expect(abs(at(0)) < 1e-3 && abs(at(1)) < 1e-3 && at(0.5) > 0.98, "a Λ: \(at(0)) \(at(0.5)) \(at(1))")
        #expect(abs(at(0.25) - at(0.75)) < 0.03)
        #expect(LS.contourParam(sh.contour) == "Cone")
        try s.execute("edit.undo")
        #expect(T.effects(s).isEmpty, "one undo removes it")

        // An edited curve (the Contour Editor's param) round trips exactly, in every effect.
        let curve: JSONValue = ["name": "Mine", "points": [[0.0, 0.2], [0.4, 0.9], [1.0, 0.1]], "corners": [false, true, false]]
        func contour(_ fx: Effect) -> Contour? {
            switch fx {
            case .dropShadow(let s), .innerShadow(let s): s.contour
            case .outerGlow(let g), .innerGlow(let g): g.contour
            case .satin(let s): s.contour
            default: nil
            }
        }
        for kind in ["dropShadow", "innerShadow", "outerGlow", "innerGlow", "satin"] {
            var fx = try #require(LS.freshEffect(kind))
            LS.overlayEffect(&fx, ["contour": curve])
            #expect(contour(fx).map(LS.contourParam) == curve, "\(kind)")
        }
        var bevel = try #require(LS.freshEffect("bevelEmboss"))
        LS.overlayEffect(&bevel, ["contour": true, "contourName": curve, "glossContour": "Ring"])
        guard case .bevelEmboss(let b) = bevel else { Issue.record("not a bevel"); return }
        #expect(b.contour.map { LS.contourParam($0.contour) } == curve)
        #expect(b.glossContour == LS.builtinContour("Ring"))
        // Malformed curves leave the contour alone.
        for bad: JSONValue in [["points": [[0.5, 0.5]]], ["points": [[0.0, "x"], [1.0, 1.0]]], ["points": "no"], 7] {
            var fx = try #require(LS.freshEffect("dropShadow"))
            LS.overlayEffect(&fx, ["contour": bad])
            #expect(contour(fx).map(LS.contourParam) == "Linear")
        }

        // `.shc` round trip of a curve with a corner.
        let mine = try #require(LS.contourFromParam(curve))
        let shc = try LS.contoursFromShc(try LS.contourToShc(mine))
        guard case .custom(let back)? = LS.contourFromParam(try #require(shc.first)) else { Issue.record("no custom contour"); return }
        #expect(back.corners == [false, true, false])
        #expect(abs(back.points[1].input - 0.4) < 0.003 && abs(back.points[1].output - 0.9) < 0.003, "\(back.points)")
    }

    @Test func makeDefaultThenResetRestoresIt() throws {
        let s = try session()
        // Factory default first: Reset without a saved default gives the factory set.
        var r = try s.execute("layer.layerStyle.defaultFor", ["kind": "stroke"])
        #expect(r["user"] == false)
        #expect(r["params"]?["size"] == 3)
        try s.execute("layer.layerStyle.makeDefault",
                      ["kind": "stroke", "params": ["size": 9, "position": "inside", "blend": "Normal", "opacity": 100, "color": "#000000"]])
        r = try s.execute("layer.layerStyle.defaultFor", ["kind": "stroke"])
        #expect(r["user"] == true)
        #expect(r["params"]?["size"] == 9)
        // Bad kinds and params are graceful errors.
        #expect(throws: EngineError.self) { try s.execute("layer.layerStyle.makeDefault", ["kind": "nope", "params": [:]]) }
        #expect(throws: EngineError.self) { try s.execute("layer.layerStyle.makeDefault", ["kind": "stroke", "params": "x"]) }
        #expect(throws: EngineError.self) { try s.execute("layer.layerStyle.defaultFor", ["kind": "nope"]) }
    }

    @Test func layerStyleDefaultsPersistWithPresets() throws {
        let s = try session()
        try s.execute("layer.layerStyle.makeDefault", ["kind": "stroke", "params": ["size": 9]])
        let blob = PresetCommands.persistedJSON(s)
        let t = Session()
        PresetCommands.loadPersisted(t, blob)
        let r = try t.execute("layer.layerStyle.defaultFor", ["kind": "stroke"])
        #expect(r["user"] == true)
        #expect(r["params"]?["size"] == 9)
    }

    @Test func doubleStrokeBandsRenderAndSurviveAnEdit() throws {
        // The manga/typesetting case (#157): a 7 px white stroke under a 3 px black one.
        let s = try T.session(48, 48)
        try s.execute("layer.new.layer")
        try T.fill(s, PixelRect(x: 16, y: 16, width: 16, height: 16), SIMD4(0, 0, 0, 1))
        try s.execute("layer.layerStyle.stroke", ["size": 3, "color": "#000000", "position": "outside"])
        try s.execute("layer.layerStyle.stroke", ["size": 7, "color": "#ffffff", "position": "outside", "add": true])
        // Bands from the square edge outward: 0..3 px black (the first stroke renders on top),
        // 3..7 px white, then the white background.
        #expect(try T.pixel(s, 24, 24)[0] < 0.1, "the square is black")
        #expect(try T.pixel(s, 24, 14)[0] < 0.1, "the first stroke covers the wider one")
        #expect(try T.pixel(s, 24, 11)[0] > 0.9, "the second stroke shows outside it")
        #expect(try T.pixel(s, 24, 5)[0] > 0.9, "background beyond both")
        // A dialog round trip (replace with the same snapshots) keeps both bands.
        let before = try T.pixel(s, 24, 14)
        let id = try #require(s.active?.activeLayer)
        let entries = JSONValue.array(T.effects(s).map { ["kind": "stroke", "fx": T.snapshot($0), "params": [:]] })
        try s.execute("layer.layerStyle.replace", ["layer": .id(id), "effects": entries])
        #expect(try T.pixel(s, 24, 14) == before, "both strokes render identically after the round trip")
    }
}
