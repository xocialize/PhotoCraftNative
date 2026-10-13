// Tests of the layer-style, fill and layer-content types (photocraft-doc crates/doc/src/effects.rs
// and lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors. photocraft has no
// tests for these; they pin the serde-compatible shapes and the helpers.

import Foundation
import PCFoundation
import simd
import Testing
@testable import PCDocument

@Suite struct EffectsTests {
    @Test func dropShadowDefaultsAndShape() throws {
        let e = Effect.defaultDropShadow()
        #expect(e.label == "Drop Shadow" && e.isEnabled)
        let j = try jsonValue(e)
        let shadow = try #require(j["DropShadow"])
        #expect(shadow["use_global_light"] == true && shadow["knocks_out"] == true && shadow["contour"] == "Linear")
        #expect(shadow["common"]?["opacity"] == 0.75)
        #expect(try roundTrip(e) == e)
    }

    @Test func everyEffectRoundTripsAndToggles() throws {
        let common = FxCommon(.normal, 1)
        let grad = StyleGradient()
        let all: [Effect] = [
            .defaultDropShadow(),
            .innerShadow(Shadow(common: FxCommon(.multiply, 0.5))),
            .outerGlow(Glow(common: FxCommon(.screen, 0.75), paint: .color(.rgb(1, 1, 0.75)))),
            .innerGlow(Glow(common: common, paint: .gradient(grad), source: .center)),
            .stroke(StrokeFx(common: common, size: 3, position: .outside, paint: .pattern(.init(name: "p", id: "i", scale: 1)))),
            .colorOverlay(.init(common: common, color: .rgb(1, 0, 0))),
            .gradientOverlay(.init(common: common, gradient: grad, dither: true)),
            .patternOverlay(.init(common: common, name: "Water", id: "abc")),
            .satin(Satin(common: FxCommon(.multiply, 0.5), color: .black, angle: 19, distance: 11, size: 14)),
            .bevelEmboss(Bevel(contour: BevelContour(), texture: BevelTexture(name: "t", id: "u"))),
        ]
        for var e in all {
            #expect(try roundTrip(e) == e, "\(e.label)")
            e.isEnabled = false
            #expect(!e.isEnabled, "\(e.label)")
            e.setEnabled(true)
            #expect(e.isEnabled)
        }
        #expect(Set(all.map(\.label)).count == 10)
    }

    @Test func serdeDefaultsOfOptionalFields() throws {
        let common = try encodeJSON(FxCommon(.normal, 1))
        let p = try decodeJSON(Effect.self, #"{"PatternOverlay":{"common":\#(common),"name":"n","id":"i","scale":1}}"#)
        guard case .patternOverlay(let po) = p else { Issue.record("not a pattern overlay"); return }
        #expect(po.angle == 0 && po.link && po.phase == .zero)
        let bevel = try jsonValue(Bevel())
        guard case .object(var obj) = bevel else { Issue.record("not an object"); return }
        obj["contour"] = nil
        obj["texture"] = nil
        let b = try JSONValue.object(obj).decode(as: Bevel.self)
        #expect(b.contour == nil && b.texture == nil)
    }

    @Test func contourCornersAreOmittedWhenEmpty() throws {
        let c = Contour.custom(.init(name: "Cone", points: [CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)]))
        #expect(try jsonValue(c)["Custom"]?["corners"] == nil)
        let k = Contour.custom(.init(name: "Cone", points: [CurvePoint(input: 0, output: 0)], corners: [true]))
        #expect(k.isCorner(0) && !k.isCorner(1) && !Contour.linear.isCorner(0))
        #expect(try roundTrip(k) == k)
    }

    @Test func effectColoursFollowTheDocumentMode() {
        let e = Effect.colorOverlay(.init(common: FxCommon(.normal, 1), color: .rgb(1, 0, 0))).inMode(.grayscale)
        guard case .colorOverlay(let o) = e else { Issue.record("kind changed"); return }
        #expect(o.color.mode == .grayscale)
        #expect(abs(o.color.c.x - 0.299) < 1e-4)
        let b = Effect.bevelEmboss(Bevel()).inMode(.cmyk)
        guard case .bevelEmboss(let bv) = b else { Issue.record("kind changed"); return }
        #expect(bv.highlightColor.mode == .cmyk && bv.shadowColor.mode == .cmyk)
    }

    @Test func effectsContainer() throws {
        var fx = Effects()
        #expect(!fx.enabled && !fx.hasVisibleEffects)
        fx.enabled = true
        fx.items = [.defaultDropShadow()]
        fx.reference = SIMD2(3, 4)
        #expect(fx.hasVisibleEffects)
        fx.items[0].isEnabled = false
        #expect(!fx.hasVisibleEffects)
        #expect(try roundTrip(fx) == fx)
        #expect(Layer(name: "l", content: .fill(.solid(.white))).effects.enabled, "new layers have effects switched on")
    }
}

@Suite struct FillTests {
    @Test func fillsUseSerdesShape() throws {
        let black = try encodeJSON(PCColor.black), white = try encodeJSON(PCColor.white)
        let g = try decodeJSON(Fill.self, #"{"Gradient":{"stops":[[0,\#(black)],[1,\#(white)]],"angle":90,"scale":1,"style":"Linear","reverse":false}}"#)
        guard case .gradient(let gf) = g else { Issue.record("not a gradient"); return }
        #expect(gf.align && !gf.dither && gf.offset == .zero && gf.opacityStops.isEmpty && gf.midpoint(0) == 0.5)
        #expect(gf.stops == [ColorStop(0, .black), ColorStop(1, .white)])
        let p = try decodeJSON(Fill.self, #"{"Pattern":{"name":"Water","scale":2}}"#)
        #expect(p == .pattern(PatternFill(name: "Water", scale: 2)))
        let s = Fill.solid(.rgb(0.5, 0.25, 1))
        #expect(try roundTrip(s) == s)
        #expect(try jsonValue(s)["Solid"] != nil)
        #expect(try roundTrip(g) == g)
    }

    @Test func fillColoursFollowTheDocumentMode() {
        let f = Fill.gradient(GradientFill(stops: [ColorStop(0, .rgb(1, 1, 1))], angle: 0, scale: 1, style: .radial, reverse: false)).inMode(.lab)
        guard case .gradient(let g) = f else { Issue.record("kind changed"); return }
        #expect(g.stops[0].color.mode == .lab)
        #expect(abs(g.stops[0].color.c.x - 1) < 1e-3)
        #expect(Fill.pattern(PatternFill(name: "x")).inMode(.cmyk) == .pattern(PatternFill(name: "x")))
    }
}

@Suite struct LayerContentTests {
    @Test func inPlaceContentHelpers() throws {
        var t = Layer(name: "T", content: .text(TextLayer(text: "hi")))
        let edited: Void? = t.withText { $0.text += "!" }
        let notShape = t.withShape { _ in 1 }
        #expect(edited != nil && notShape == nil)
        if case .text(let tl) = t.content { #expect(tl.text == "hi!") } else { Issue.record("content kind changed") }
        var s = Layer(name: "S", content: .shape(ShapeLayer(path: VectorPath([Subpath.polygon([(0, 0), (1, 0), (1, 1)])]), fill: .solid(.black))))
        s.withShape { $0.stroke = ShapeStroke() }
        if case .shape(let sl) = s.content { #expect(sl.stroke != nil) } else { Issue.record("content kind changed") }
        var so = Layer(name: "SO", content: .smart(SmartObject(source: .linked(path: "/a.psd"), transform: .identity, cache: nil)))
        so.withSmartObject { $0.smartFilters.append(SmartFilter(command: "filter.blur.gaussianBlur", params: ["radius": 2])) }
        if case .smart(let o) = so.content { #expect(o.smartFilters.count == 1 && o.filtersEnabled) } else { Issue.record("content kind changed") }
        #expect(Layer(name: "a", content: .adjustment(.invert)).adjustment == .invert)
        #expect(Layer(name: "f", content: .fill(.solid(.white))).fill == .solid(.white))
        #expect(try roundTrip(SmartFilter(command: "x", params: ["a": [1, true, "s", nil]])) == SmartFilter(command: "x", params: ["a": [1, true, "s", nil]]))
    }

    @Test func backgroundAndPropertiesHelpers() throws {
        var d = makeDoc()
        let name = d.updateBackground { $0.name }
        #expect(name == "Background")
        d.updateBackground { $0.locks.position = false }
        #expect(d.background == nil)
        let none = d.updateBackground { $0.name }
        #expect(none == nil)
        var l = Layer.raster("x", format: .rgba8)
        var p = l.properties
        p.name = "y"
        p.opacity = 0.25
        p.blendIf.set(1, BlendRangePair(.full, BlendRange(black: SIMD2(1, 2), white: SIMD2(250, 255))))
        p.vectorMask = VectorMask(path: VectorPath())
        let id = l.id
        l.properties = p
        #expect(l.properties == p && l.id == id && l.rasterSurface != nil)
    }

    @Test func smartObjectsKeepTheirIdentityAcrossDuplicates() {
        let so = SmartObject(source: .embedded(fileName: "a.png", bytes: [1, 2, 3]), transform: .scale(2), cache: nil)
        let l = Layer(name: "SO", content: .smart(so))
        let dup = l.duplicate()
        guard case .smart(let a) = l.content, case .smart(let b) = dup.content else { Issue.record("not smart"); return }
        #expect(a.contentsId == b.contentsId, "duplicates share the contents")
        #expect(SmartObject(source: .linked(path: "x"), transform: .identity, cache: nil).contentsId != a.contentsId)
        var p = so
        p.perspective = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        #expect(p.perspectiveMatrix == matrix_identity_double3x3)
    }

    @Test func guidesAndChannels() throws {
        var g = Guides(horizontal: [10, 20.5], vertical: [3])
        g.setColor(vertical: false, position: 20.5, rgb: SIMD3(255, 0, 0))
        g.setColor(vertical: true, position: 3, rgb: SIMD3(0, 0, 255))
        #expect(g.color(vertical: false, position: 20.5) == SIMD3(255, 0, 0))
        g.setColor(vertical: true, position: 3, rgb: nil)
        #expect(g.color(vertical: true, position: 3) == nil)
        g.horizontal = [10]
        g.pruneColors()
        #expect(g.colors.isEmpty)
        #expect(try encodeJSON(Guides(horizontal: [1], vertical: [])) == #"{"horizontal":[1],"vertical":[]}"#)
        var a = AlphaChannel(name: "Alpha 1", surface: Surface(format: .gray8))
        #expect(a.overlayCoverage(0.25) == 0.75)
        a.indicates = .selectedAreas
        #expect(a.overlayCoverage(0.25) == 0.25)
        #expect(try encodeJSON(ColorIndicates.maskedAreas) == #""maskedAreas""#)
        #expect(FileEncoding().isEmpty && !FileEncoding(jpegQuality: 80).isEmpty)
        #expect(try encodeJSON(FileEncoding(webpLossless: true)) == #"{"webpLossless":true}"#)
    }
}
