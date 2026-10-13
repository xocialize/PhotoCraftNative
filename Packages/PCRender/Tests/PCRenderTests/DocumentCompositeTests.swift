// Port of photocraft-compose (crates/compose/src/tests.rs: document compositing and layer effects), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Every document here is planned by `DocumentPlanner`, rendered by the CPU reference and by Metal
// (`DT.render` checks GPU vs CPU ≤ 1/255), and its pixels checked against photocraft's
// expectations.

import Foundation
import Testing
import PCDocument
import PCFoundation
@testable import PCRender

@Suite("Document compositing (compose tests.rs)")
struct DocumentCompositeTests {
    typealias R = PixelRect

    @Test func backgroundOnly() {
        let d = DT.docWhite(8, 8)
        #expect(DT.close4(DT.px(d, 3, 3), DT.white))
        // Outside the canvas the Background has no pixels.
        #expect(DT.close4(DT.render(d, DT.rect(20, 3, 21, 4)).px[0], DT.clear))
    }

    @Test func normalLayerOverBackground() {
        var d = DT.docWhite(8, 8)
        d.layers.append(DT.solidLayer("red", DT.rect(0, 0, 4, 8), DT.rgba(1, 0, 0)))
        let r = DT.render(d)
        #expect(DT.close4(r.get(1, 1), DT.rgba(1, 0, 0)))
        #expect(DT.close4(r.get(5, 1), DT.white))
    }

    @Test func opacityAndFillMultiply() {
        var d = DT.docWhite(4, 4)
        var l = DT.solidLayer("k", DT.rect(0, 0, 4, 4), DT.black)
        l.opacity = 0.5; l.fillOpacity = 0.5
        d.layers.append(l)
        #expect(abs(DT.px(d, 0, 0).x - 0.75) <= 2 / 255)
    }

    @Test func hiddenLayersSkipped() {
        var d = DT.docWhite(4, 4)
        var l = DT.solidLayer("k", DT.rect(0, 0, 4, 4), DT.black)
        l.visible = false
        d.layers.append(l)
        #expect(DT.close4(DT.px(d, 0, 0), DT.white))
    }

    @Test func everyBlendModeMatchesReferenceOnOpaquePixels() {
        let backdrop = SIMD4<Float>(0.6, 0.3, 0.2, 1), source = SIMD4<Float>(0.2, 0.7, 0.5, 1)
        let f32 = PixelFormat(mode: .rgb, sample: .f32, alpha: true)
        for mode in BlendMode.layerModes where mode != .dissolve {
            var d = Document(name: "b", size: PixelSize(width: 2, height: 2), mode: .rgb, depth: .f32)
            var top = DT.solidLayer("t", DT.rect(0, 0, 2, 2), source, format: f32)
            top.blend = mode
            d.layers = [DT.solidLayer("b", DT.rect(0, 0, 2, 2), backdrop, format: f32), top]
            let got = DT.px(d, 0, 0)
            let want = PSBlend.blendRGB(mode, SIMD3(0.6, 0.3, 0.2), SIMD3(0.2, 0.7, 0.5), hdr: true)
            for i in 0..<3 { #expect(abs(got[i] - want[i]) < 1e-5, "\(mode): \(got) vs \(want)") }
            #expect(abs(got.w - 1) < 1e-6)
        }
    }

    @Test func layerMaskHidesPixels() {
        var d = DT.docWhite(4, 4)
        var l = DT.solidLayer("k", DT.rect(0, 0, 4, 4), DT.black)
        var m = LayerMask.revealAll()
        m.surface.fill(DT.rect(0, 0, 2, 4), with: [0])
        l.mask = m
        d.layers.append(l)
        let r = DT.render(d)
        #expect(DT.close4(r.get(0, 0), DT.white))
        #expect(DT.close4(r.get(3, 0), DT.black))
    }

    @Test func disabledMaskIsIgnored() {
        var d = DT.docWhite(2, 2)
        var l = DT.solidLayer("k", DT.rect(0, 0, 2, 2), DT.black)
        var m = LayerMask.hideAll()
        m.enabled = false
        l.mask = m
        d.layers.append(l)
        #expect(DT.close4(DT.px(d, 0, 0), DT.black))
    }

    @Test func clippingMaskRestrictsToBaseAlpha() {
        var d = DT.docWhite(8, 8)
        d.layers.append(DT.solidLayer("base", DT.rect(0, 0, 4, 8), DT.rgba(0, 0, 1)))
        var clip = DT.solidLayer("clip", DT.rect(0, 0, 8, 8), DT.rgba(1, 0, 0))
        clip.clipped = true
        d.layers.append(clip)
        let r = DT.render(d)
        #expect(DT.close4(r.get(1, 1), DT.rgba(1, 0, 0)), "inside base: clipped layer visible")
        #expect(DT.close4(r.get(6, 1), DT.white), "outside base: clipped layer hidden")
    }

    @Test func hiddenBaseHidesClippingGroup() {
        var d = DT.docWhite(4, 4)
        var base = DT.solidLayer("base", DT.rect(0, 0, 4, 4), DT.rgba(0, 0, 1))
        base.visible = false
        d.layers.append(base)
        var clip = DT.solidLayer("clip", DT.rect(0, 0, 4, 4), DT.rgba(1, 0, 0))
        clip.clipped = true
        d.layers.append(clip)
        #expect(DT.close4(DT.px(d, 1, 1), DT.white))
    }

    @Test func isolatedGroupDiffersFromPassThrough() {
        func make(_ blend: BlendMode) -> SIMD4<Float> {
            var d = DT.docWhite(2, 2)
            d.layers[0].withRaster { $0.fill(DT.rect(0, 0, 2, 2), with: [0.5, 0.5, 0.5, 1]) }
            var m = DT.solidLayer("m", DT.rect(0, 0, 2, 2), DT.rgba(0.5, 0.5, 0.5))
            m.blend = .multiply
            var g = Layer.group("g", [m])
            g.blend = blend
            d.layers.append(g)
            return DT.px(d, 0, 0)
        }
        #expect(abs(make(.passThrough).x - 0.25) <= 2 / 255)
        #expect(abs(make(.normal).x - 0.5) <= 2 / 255)
    }

    @Test func passThroughGroupBelowFullFillIsIsolated() {
        func make(_ fill: Float) -> SIMD4<Float> {
            var d = DT.docWhite(2, 2)
            var g = Layer.group("g", [DT.adjustment(.invert)])
            g.fillOpacity = fill
            d.layers.append(g)
            return DT.px(d, 0, 0)
        }
        #expect(DT.close4(make(1), DT.black), "full fill: the invert reaches the background")
        #expect(DT.close4(make(0.4), DT.white), "isolated: nothing beneath to invert")
    }

    @Test func maskFeatherBlursTheEdge() {
        var d = DT.docWhite(64, 8)
        var l = DT.solidLayer("k", DT.rect(0, 0, 64, 8), DT.black)
        var m = LayerMask.hideAll()
        m.surface.fill(DT.rect(0, 0, 32, 8), with: [1])
        l.mask = m
        d.layers.append(l)
        var r = DT.render(d)
        #expect(r.get(31, 4).x < 0.01 && r.get(32, 4).x > 0.99, "sharp without feather")
        d.layers[1].mask!.feather = 8
        r = DT.render(d)
        let (a, b) = (r.get(31, 4).x, r.get(32, 4).x)
        #expect(a > 0.3 && a < 0.5 && b > 0.5 && b < 0.7, "soft edge around 50%: \(a) \(b)")
        #expect(r.get(4, 4).x < 0.01 && r.get(60, 4).x > 0.99, "far from the edge unchanged")
    }

    @Test func groupOpacityAppliesOnce() {
        var d = DT.docWhite(2, 2)
        var g = Layer.group("g", [DT.solidLayer("a", DT.rect(0, 0, 2, 2), DT.black), DT.solidLayer("b", DT.rect(0, 0, 2, 2), DT.black)])
        g.blend = .normal
        g.opacity = 0.5
        d.layers.append(g)
        #expect(abs(DT.px(d, 0, 0).x - 0.5) <= 2 / 255)
    }

    @Test func passThroughGroupOpacityMixes() {
        var d = DT.docWhite(2, 2)
        var g = Layer.group("g", [DT.solidLayer("a", DT.rect(0, 0, 2, 2), DT.black)])
        g.opacity = 0.25
        d.layers.append(g)
        #expect(abs(DT.px(d, 0, 0).x - 0.75) <= 2 / 255)
        // Over transparency: coverage mixes premultiplied (HDR red keeps its value).
        var t = Document(name: "coverage", size: PixelSize(width: 2, height: 2), mode: .rgb, depth: .f32)
        var red = Layer.raster("HDR red", format: t.pixelFormat)
        red.withRaster { $0.fill(t.bounds, with: [2, 0, 0, 1]) }
        var group = Layer.group("half", [red])
        group.opacity = 0.5
        t.layers.append(group)
        #expect(DT.close4(DT.px(t, 0, 0), SIMD4(2, 0, 0, 0.5)))
    }

    @Test func invertAdjustmentLayer() {
        var d = DT.docWhite(2, 2)
        d.layers[0].withRaster { $0.fill(DT.rect(0, 0, 2, 2), with: [0.2, 0.4, 0.6, 1]) }
        d.layers.append(DT.adjustment(.invert))
        #expect(DT.close4(DT.px(d, 0, 0), DT.rgba(0.8, 0.6, 0.4)))
    }

    @Test func adjustmentOpacityAndMask() {
        var d = DT.docWhite(4, 1)
        d.layers[0].withRaster { $0.fill(DT.rect(0, 0, 4, 1), with: [0, 0, 0, 1]) }
        var adj = DT.adjustment(.invert)
        adj.opacity = 0.5
        var m = LayerMask.revealAll()
        m.surface.fill(DT.rect(2, 0, 4, 1), with: [0])
        adj.mask = m
        d.layers.append(adj)
        let r = DT.render(d)
        #expect(abs(r.get(0, 0).x - 0.5) <= 2 / 255)
        #expect(abs(r.get(3, 0).x) <= 2 / 255)
    }

    @Test func clippedAdjustmentOnlyAffectsBase() {
        var d = DT.docWhite(4, 1)
        d.layers.append(DT.solidLayer("base", DT.rect(0, 0, 2, 1), DT.black))
        var adj = DT.adjustment(.invert)
        adj.clipped = true
        d.layers.append(adj)
        let r = DT.render(d)
        #expect(DT.close4(r.get(0, 0), DT.white), "base inverted to white")
        #expect(DT.close4(r.get(3, 0), DT.white), "background untouched")
    }

    @Test func solidAndGradientFillLayers() {
        var d = DT.docWhite(10, 1)
        d.layers.append(Layer(name: "fill", content: .fill(.solid(.rgb(0, 0, 1)))))
        #expect(DT.close4(DT.px(d, 5, 0), DT.rgba(0, 0, 1)))
        d.layers[1].content = .fill(.gradient(GradientFill(stops: [ColorStop(0, .black), ColorStop(1, .white)], angle: 0, scale: 1, style: .linear, reverse: false)))
        let full = DT.render(d)
        // Tile independence: a 1 px render of the right edge equals the full render.
        let one = DT.render(d, DT.rect(9, 0, 10, 1))
        #expect(one.px[0] == full.get(9, 0))
        #expect(full.get(0, 0).x < full.get(9, 0).x, "left dark, right light")
    }

    @Test func ditheredGradientFillsUnderColorDodgeKeepBlackChannels() {
        var d = DT.docWhite(128, 32)
        let bottom = GradientFill(stops: [ColorStop(0, .rgb(1, 0, 0)), ColorStop(1, .rgb(0, 0, 1))], angle: 0, scale: 1, style: .linear, reverse: false, dither: true)
        d.layers.append(Layer(name: "bottom", content: .fill(.gradient(bottom))))
        let top = GradientFill(stops: [ColorStop(0, .rgb(0.88, 0.88, 0.88)), ColorStop(1, .rgb(0.97, 0.97, 0.97))], angle: 90, scale: 1, style: .linear,
                               reverse: false, dither: true)
        var l = Layer(name: "top", content: .fill(.gradient(top)))
        l.blend = .colorDodge
        d.layers.append(l)
        let r = DT.render(d)
        #expect(r.px.allSatisfy { $0.y == 0 }, "green stays at 0")
    }

    @Test func dissolveCoverageMatchesOpacity() {
        var d = Document(name: "d", size: PixelSize(width: 64, height: 64), mode: .rgb, depth: .u8)
        var l = DT.solidLayer("k", DT.rect(0, 0, 64, 64), DT.black)
        l.blend = .dissolve
        l.opacity = 0.3
        d.layers.append(l)
        let b = DT.render(d)
        let covered = Float(b.px.filter { $0.w > 0.5 }.count) / Float(b.px.count)
        #expect(abs(covered - 0.3) < 0.05, "\(covered)")
        #expect(DT.render(d).px == b.px, "deterministic")
    }

    @Test func renderIsTileIndependent() {
        var d = DT.docWhite(300, 300)
        var l = DT.solidLayer("a", DT.rect(20, 20, 280, 280), SIMD4(0.1, 0.5, 0.9, 0.7))
        l.blend = .overlay
        d.layers.append(l)
        let full = DT.render(d)
        let sub = DT.render(d, DT.rect(250, 250, 270, 262))
        for y in Int32(250)..<262 { for x in Int32(250)..<270 { #expect(full.get(x, y) == sub.get(x, y)) } }
    }

    @Test func cmykDocumentRendersViaRGB() {
        var d = Document(name: "c", size: PixelSize(width: 2, height: 2), mode: .cmyk, depth: .u8)
        var l = Layer.raster("k", format: d.pixelFormat)
        l.withRaster { $0.fill(DT.rect(0, 0, 2, 2), with: [0, 0, 0, 1, 1]) }
        d.layers.append(l)
        let p = DT.px(d, 0, 0)
        #expect(p.x < 0.3 && abs(p.x - p.y) < 0.05 && abs(p.y - p.z) < 0.05 && p.w == 1, "\(p)")
    }

    @Test func flattenToSurfaceLeavesTransparentPixelsEmptyInEveryMode() throws {
        let modes: [(ColorMode, [SampleType])] = [(.rgb, [.u8, .u16, .f32]), (.grayscale, [.u8, .u16, .f32]), (.cmyk, [.u8, .u16]), (.lab, [.u8, .u16])]
        for (mode, samples) in modes {
            for sample in samples {
                var d = Document(name: "t", size: PixelSize(width: 300, height: 200), mode: mode, depth: sample)
                let fmt = PixelFormat(mode: mode, sample: sample, alpha: true)
                var l = Layer.raster("dot", format: fmt)
                l.withRaster { $0.fill(DT.rect(120, 80, 140, 90), with: fmt.components(fromRGBA: SIMD4(0.9, 0.4, 0.1, 1))) }
                d.layers.append(l)
                let s = try DT.cpu.compositeToSurface(d, format: fmt)
                #expect(s.contentBounds == DT.rect(120, 80, 140, 90), "\(mode) \(sample)")
                let opaque = try DT.cpu.compositeToSurface(d, format: PixelFormat(mode: mode, sample: sample, alpha: false), background: SIMD3(1, 1, 1))
                #expect(opaque.rgba(x: 5, y: 5).w == 1, "\(mode) \(sample): background stays opaque")
            }
        }
    }

    @Test func sixteenBitAndFloatLayersComposite() {
        for sample in [SampleType.u16, .f32] {
            let fmt = PixelFormat(mode: .rgb, sample: sample, alpha: true)
            var d = Document(name: "x", size: PixelSize(width: 2, height: 2), mode: .rgb, depth: sample)
            d.layers.append(DT.solidLayer("a", DT.rect(0, 0, 2, 2), SIMD4(0.25, 0.5, 0.75, 1), format: fmt))
            #expect(DT.close4(DT.px(d, 1, 1), SIMD4(0.25, 0.5, 0.75, 1)), "\(sample)")
        }
    }

    /// `two_solid_layers`.
    static func twoSolid(_ depth: SampleType, _ mode: BlendMode, _ bg: SIMD3<Float>, _ top: SIMD3<Float>) -> Document {
        var d = Document(name: "hdr", size: PixelSize(width: 4, height: 4), mode: .rgb, depth: depth)
        let fmt = d.pixelFormat
        var t = DT.solidLayer("top", DT.rect(0, 0, 4, 4), SIMD4(top, 1), format: fmt)
        t.blend = mode
        d.layers = [DT.solidLayer("bg", DT.rect(0, 0, 4, 4), SIMD4(bg, 1), format: fmt), t]
        return d
    }

    @Test func floatDocumentsAddAndDividePastWhite() throws {
        let (bg, top) = (SIMD3<Float>(2, 0.5, 4), SIMD3<Float>(0.5, 0.25, 0.5))
        for (mode, want) in [(BlendMode.linearDodge, SIMD3<Float>(2.5, 0.75, 4.5)), (.divide, SIMD3(4, 2, 8)), (.multiply, SIMD3(1, 0.125, 2))] {
            let d = Self.twoSolid(.f32, mode, bg, top)
            let p = DT.render(d)
            let pl = DT.cpu.plan(d, region: d.bounds)
            let tiled: RGBABuffer = try CPUCompositor(tileSize: 16).render(pl.plan, region: d.bounds, source: pl.source)
            for q in p.px + tiled.px { #expect(DT.close4(q, SIMD4(want, 1)), "\(mode): \(q)") }
        }
        let d = Self.twoSolid(.u16, .linearDodge, SIMD3(0.8, 0.5, 0.6), top)
        #expect(DT.close4(DT.render(d).px[0], SIMD4(1, 0.75, 1, 1)))
    }

    @Test func integerDocumentsClipAddAndDivideAtWhite() {
        let (bg, top) = (SIMD3<Float>(0.8, 0.5, 0.6), SIMD3<Float>(0.5, 0.25, 0.5))
        for depth in [SampleType.u8, .u16, .f32] {
            for (mode, clipped, hdr) in [(BlendMode.linearDodge, SIMD3<Float>(1, 0.75, 1), SIMD3<Float>(1.3, 0.75, 1.1)), (.divide, SIMD3(1, 1, 1), SIMD3(1.6, 2, 1.2))] {
                let want = depth == .f32 ? hdr : clipped
                let p = DT.render(Self.twoSolid(depth, mode, bg, top)).px[5]
                #expect(DT.close4(p, SIMD4(want, 1)), "\(mode) \(depth): \(p)")
            }
        }
    }

    @Test func thumbnailDimensions() throws {
        let d = DT.docWhite(400, 200)
        let t = try DT.cpu.thumbnail(d, maxSide: 100)
        #expect(t.rect == DT.rect(0, 0, 100, 50))
        #expect(DT.close4(t.px[0], DT.white))
        let small = try DT.cpu.thumbnail(DT.docWhite(10, 5), maxSide: 100)
        #expect(small.rect == DT.rect(0, 0, 10, 5))
    }

    // MARK: Layer effects

    @Test func outsideStrokeWidth() {
        let r = DT.render(DT.fxDoc([DT.stroke(3, .outside)]))
        #expect(DT.close4(r.get(8, 20), DT.rgba(0, 0, 1)))
        #expect(DT.close4(r.get(7, 20), DT.rgba(0, 0, 1)))
        #expect(DT.close4(r.get(5, 20), DT.white), "\(r.get(5, 20))")
        #expect(DT.close4(r.get(20, 20), DT.rgba(1, 0, 0)), "interior untouched")
    }

    @Test func outsideStrokeAtZeroFillLeavesTheInteriorClear() {
        for depth in [SampleType.u8, .u16, .f32] {
            let fmt = PixelFormat(mode: .rgb, sample: depth, alpha: true)
            var d = DT.docWhite(40, 40, depth: depth)
            var l = DT.solidLayer("sq", DT.rect(10, 10, 30, 30), DT.rgba(1, 0, 0), format: fmt)
            l.effects.items = [DT.stroke(3, .outside)]
            l.fillOpacity = 0
            d.layers.append(l)
            var r = DT.render(d)
            #expect(DT.close4(r.get(20, 20), DT.white), "\(depth): interior shows the white backdrop: \(r.get(20, 20))")
            #expect(DT.close4(r.get(11, 20), DT.white), "\(depth): just inside the edge too")
            #expect(DT.close4(r.get(8, 20), DT.rgba(0, 0, 1)), "\(depth): the stroke itself stays")
            d.layers[1].fillOpacity = 0.5
            r = DT.render(d)
            #expect(DT.close4(r.get(20, 20), DT.rgba(1, 0.5, 0.5)), "\(depth): \(r.get(20, 20))")
            d.layers[1].fillOpacity = 1
            #expect(DT.close4(DT.px(d, 20, 20), DT.rgba(1, 0, 0)))
        }
    }

    @Test func insideAndCenterStrokes() {
        var r = DT.render(DT.fxDoc([DT.stroke(2, .inside)]))
        #expect(DT.close4(r.get(10, 20), DT.rgba(0, 0, 1)))
        #expect(DT.close4(r.get(11, 20), DT.rgba(0, 0, 1)))
        #expect(DT.close4(r.get(13, 20), DT.rgba(1, 0, 0)))
        #expect(DT.close4(r.get(9, 20), DT.white))
        r = DT.render(DT.fxDoc([DT.stroke(4, .center)]))
        #expect(DT.close4(r.get(8, 20), DT.rgba(0, 0, 1)))
        #expect(DT.close4(r.get(11, 20), DT.rgba(0, 0, 1)))
        #expect(DT.close4(r.get(13, 20), DT.rgba(1, 0, 0)))
    }

    @Test func masterSwitchAndPerEffectEnable() {
        var d = DT.fxDoc([DT.stroke(3, .outside)])
        d.layers[1].effects.enabled = false
        #expect(DT.close4(DT.px(d, 8, 20), DT.white))
        d = DT.fxDoc([DT.stroke(3, .outside)])
        d.layers[1].effects.items[0].isEnabled = false
        #expect(DT.close4(DT.px(d, 8, 20), DT.white))
    }

    @Test func colorOverlayIgnoresFillOpacityButNotOpacity() {
        var d = DT.fxDoc([.colorOverlay(.init(common: FxCommon(.normal, 1), color: .rgb(0, 1, 0)))])
        d.layers[1].fillOpacity = 0
        #expect(DT.close4(DT.px(d, 20, 20), DT.rgba(0, 1, 0)), "overlay shows at fill 0")
        d.layers[1].opacity = 0.5
        #expect(DT.close4(DT.px(d, 20, 20), DT.rgba(0.5, 1, 0.5)))
    }

    @Test func dropShadowFallsAwayFromLight() {
        var r = DT.render(DT.fxDoc([.dropShadow(DT.shadow(5, 90))]))
        #expect(DT.close4(r.get(20, 32), DT.black), "\(r.get(20, 32))")
        #expect(DT.close4(r.get(20, 8), DT.white))
        r = DT.render(DT.fxDoc([.dropShadow(DT.shadow(5, 0))]))
        #expect(DT.close4(r.get(8, 20), DT.black))
        #expect(DT.close4(r.get(32, 20), DT.white))
    }

    @Test func groupEffectsReachPastChildrenEffects() {
        var d = DT.docWhite(48, 48)
        var sq = DT.solidLayer("sq", DT.rect(14, 14, 34, 34), DT.rgba(1, 0, 0))
        sq.effects.items = [DT.stroke(6, .outside)]
        var g = Layer.group("g", [sq])
        g.effects.items = [.dropShadow(DT.shadow(2, 90))]
        d.layers.append(g)
        let r = DT.render(d)
        #expect(DT.close4(r.get(9, 24), DT.rgba(0, 0, 1)), "stroke left of the pixels: \(r.get(9, 24))")
        #expect(DT.close4(r.get(24, 38), DT.rgba(0, 0, 1)), "stroke below the pixels")
        #expect(DT.close4(r.get(24, 41), DT.black), "shadow below the stroke: \(r.get(24, 41))")
        #expect(DT.close4(r.get(24, 43), DT.white), "nothing past the shadow")
    }

    @Test func dropShadowUsesGlobalLightAndKnockout() {
        var d = DT.fxDoc([.dropShadow(DT.shadow(5, 0, global: true))])
        d.globalLight.angle = 90
        #expect(DT.close4(DT.px(d, 20, 32), DT.black))
        d.layers[1].fillOpacity = 0
        #expect(DT.close4(DT.px(d, 20, 28), DT.white), "knock-out at fill 0")
        if case .dropShadow(var s) = d.layers[1].effects.items[0] { s.knocksOut = false; d.layers[1].effects.items[0] = .dropShadow(s) }
        #expect(DT.close4(DT.px(d, 20, 28), DT.black))
    }

    @Test func softShadowIsBlurredAndBounded() {
        let r = DT.render(DT.fxDoc([.dropShadow(DT.shadow(0, 90, spread: 0, size: 6))]))
        let edge = r.get(30, 20), far = r.get(39, 20)
        #expect(edge.x < 0.8 && edge.x > 0.2, "\(edge)")
        #expect(far.x > 0.99, "\(far)")
    }

    @Test func innerShadowOnlyInside() {
        let r = DT.render(DT.fxDoc([.innerShadow(DT.shadow(4, 90, knocksOut: false))]))
        #expect(DT.close4(r.get(20, 11), DT.black), "\(r.get(20, 11))")
        #expect(DT.close4(r.get(20, 25), DT.rgba(1, 0, 0)))
        #expect(DT.close4(r.get(20, 5), DT.white))
    }

    @Test func outerAndInnerGlowRegions() {
        var r = DT.render(DT.fxDoc([.outerGlow(DT.glow(.precise, .edge))]))
        let near = r.get(9, 20)
        #expect(near.y > 0.7 && near.x < 0.3, "\(near)")
        #expect(DT.close4(r.get(3, 20), DT.white))
        #expect(DT.close4(r.get(20, 20), DT.rgba(1, 0, 0)))
        r = DT.render(DT.fxDoc([.innerGlow(DT.glow(.softer, .edge))]))
        #expect(r.get(10, 20).y > 0.3, "\(r.get(10, 20))")
        #expect(DT.close4(r.get(20, 20), DT.rgba(1, 0, 0)))
        #expect(DT.close4(r.get(5, 20), DT.white))
    }

    @Test func preciseInnerGlowFromCenterPaintsTheMiddle() {
        let r = DT.render(DT.fxDoc([.innerGlow(DT.glow(.precise, .center))]))
        let (center, edge) = (r.get(20, 20), r.get(10, 20))
        #expect(center.y > 0.9 && center.x < 0.1, "green in the middle: \(center)")
        #expect(edge.x > center.x && edge.y < center.y, "fades towards the edge: \(edge) vs \(center)")
        #expect(DT.close4(r.get(5, 20), DT.white))
    }

    @Test func glowGradientFollowsTheShape() {
        let redToBlue = StyleGradient(stops: [ColorStop(0, .rgb(1, 0, 0)), ColorStop(1, .rgb(0, 0, 1))])
        let g = DT.glow(.softer, .edge, paint: .gradient(redToBlue), size: 8)
        var r = DT.render(DT.fxDoc([.outerGlow(g)]))
        let near = r.get(9, 20)
        for p in [r.get(30, 20), r.get(20, 9), r.get(20, 30)] {
            #expect((0..<4).allSatisfy { abs(p[$0] - near[$0]) < 1.0 / 255 }, "\(p) vs \(near)")
        }
        #expect(near.x > 0.8 && near.z < 0.2 && near.y < 0.1, "red at the edge: \(near)")
        let out = r.get(5, 20)
        #expect(out.z > out.x && out.y < 0.9, "bluer and fading further out: \(out)")
        r = DT.render(DT.fxDoc([.innerGlow(g)]))
        let (edge, top) = (r.get(10, 20), r.get(20, 10))
        #expect((0..<4).allSatisfy { abs(edge[$0] - top[$0]) < 1.0 / 255 }, "\(edge) vs \(top)")
        #expect(edge.x > 0.8 && edge.z < 0.2, "\(edge)")
    }

    @Test func gradientOverlayFollowsAngleAndReverse() {
        let g = StyleGradient(stops: [ColorStop(0, .black), ColorStop(1, .white)], style: .linear, angle: 0)
        var r = DT.render(DT.fxDoc([.gradientOverlay(.init(common: FxCommon(.normal, 1), gradient: g))]))
        #expect(r.get(10, 20).x < 0.1 && r.get(29, 20).x > 0.9, "\(r.get(10, 20)) \(r.get(29, 20))")
        var rev = g
        rev.reverse = true
        r = DT.render(DT.fxDoc([.gradientOverlay(.init(common: FxCommon(.normal, 1), gradient: rev))]))
        #expect(r.get(10, 20).x > 0.9)
    }

    @Test func satinAndBevelStayInsideShape() {
        let satin = Effect.satin(Satin(common: FxCommon(.multiply, 1), color: .black, angle: 19, distance: 4, size: 4, contour: .linear, antiAlias: true, invert: false))
        let bevel = Effect.bevelEmboss(Bevel(style: .innerBevel, technique: .smooth, depth: 1, up: true, size: 4, soften: 0, angle: 90, altitude: 30,
                                             useGlobalLight: false))
        let r = DT.render(DT.fxDoc([satin, bevel]))
        for (x, y) in [(Int32(5), Int32(5)), (35, 20), (20, 35)] { #expect(DT.close4(r.get(x, y), DT.white), "(\(x),\(y)) \(r.get(x, y))") }
        #expect(r.get(20, 11).y > r.get(20, 28).y, "light from the top: \(r.get(20, 11)) \(r.get(20, 28))")
    }

    @Test func clippedLayerEffectsAreClippedToBase() {
        var d = DT.docWhite(40, 40)
        d.layers.append(DT.solidLayer("base", DT.rect(10, 10, 30, 30), DT.rgba(1, 0, 0)))
        var c = DT.solidLayer("clip", DT.rect(20, 10, 40, 30), DT.rgba(0, 1, 0))
        c.clipped = true
        c.effects.items = [DT.stroke(3, .outside)]
        d.layers.append(c)
        let r = DT.render(d)
        #expect(DT.close4(r.get(18, 20), DT.rgba(0, 0, 1)), "stroke inside base")
        #expect(DT.close4(r.get(20, 8), DT.white), "stroke clipped outside base")
    }

    @Test func groupEffectsApplyToGroupShape() {
        var d = DT.docWhite(40, 40)
        var g = Layer.group("g", [DT.solidLayer("a", DT.rect(10, 10, 20, 30), DT.rgba(1, 0, 0)), DT.solidLayer("b", DT.rect(20, 10, 30, 30), DT.rgba(1, 0, 0))])
        g.effects.items = [DT.stroke(2, .outside)]
        d.layers.append(g)
        let r = DT.render(d)
        #expect(DT.close4(r.get(9, 20), DT.rgba(0, 0, 1)))
        #expect(DT.close4(r.get(20, 20), DT.rgba(1, 0, 0)), "no stroke at the seam between children")
    }

    @Test func effectsRenderIdenticallyInTiles() throws {
        for depth in [SampleType.u8, .u16, .f32] {
            let fmt = PixelFormat(mode: .rgb, sample: depth, alpha: true)
            var d = DT.docWhite(40, 40, depth: depth)
            var l = DT.solidLayer("sq", DT.rect(10, 10, 30, 30), DT.rgba(1, 0, 0), format: fmt)
            l.effects.items = [.dropShadow(DT.shadow(4, 120, spread: 0, size: 5)), DT.stroke(2, .outside)]
            d.layers.append(l)
            let full = DT.render(d)
            let p = DT.cpu.plan(d, region: d.bounds)
            for tile in [16, 33] {
                #expect(try CPUCompositor(tileSize: tile).render(p.plan, region: d.bounds, source: p.source).px == full.px, "\(depth), tile \(tile)")
            }
            // Sub-regions (each a separate plan) agree with the whole render.
            for r in [DT.rect(0, 0, 7, 40), DT.rect(5, 25, 40, 33)] {
                let part = DT.render(d, r)
                for y in r.y0..<r.y1 { for x in r.x0..<r.x1 { #expect(part.get(x, y) == full.get(x, y), "\(depth) \(r) at \(x),\(y)") } }
            }
        }
    }

    @Test func parallelTilesMatchSinglePass() throws {
        var d = DT.docWhite(97, 61)
        var a = DT.solidLayer("a", DT.rect(5, 5, 70, 50), SIMD4(1, 0.2, 0.1, 0.8))
        var m = LayerMask.revealAll()
        m.surface.fill(DT.rect(0, 0, 40, 61), with: [0.25])
        m.density = 0.8
        a.mask = m
        a.effects.items = [DT.stroke(3, .outside)]
        d.layers.append(a)
        var clip = DT.solidLayer("clip", DT.rect(30, 0, 97, 61), DT.rgba(0, 1, 0))
        clip.clipped = true
        clip.blend = .multiply
        d.layers.append(clip)
        var g = Layer.group("g", [DT.solidLayer("in", DT.rect(50, 20, 90, 60), DT.rgba(0.2, 0.3, 0.9))])
        g.opacity = 0.6
        d.layers.append(g)
        d.layers.append(DT.adjustment(.invert))
        var f = Layer(name: "fill", content: .fill(.solid(.rgb(0.5, 0.5, 0))))
        f.opacity = 0.3
        d.layers.append(f)
        let p = DT.cpu.plan(d, region: d.bounds)
        let whole = try CPUCompositor(tileSize: 10_000).render(p.plan, region: d.bounds, source: p.source)
        for tile in [16, 33] { #expect(try CPUCompositor(tileSize: tile).render(p.plan, region: d.bounds, source: p.source).px == whole.px, "tile \(tile)") }
        #expect(DT.render(d).px == whole.px)
    }

    @Test func vectorMaskCombinesWithPixelMask() {
        var d = DT.docWhite(8, 8)
        var l = DT.solidLayer("k", DT.rect(0, 0, 8, 8), DT.black)
        l.vectorMask = VectorMask(path: DT.polygon([(0, 0), (4.5, 0), (4.5, 8), (0, 8)]))
        var m = LayerMask.revealAll()
        m.surface.fill(DT.rect(0, 0, 8, 2), with: [0])
        l.mask = m
        d.layers.append(l)
        var r = DT.render(d)
        #expect(DT.close4(r.get(1, 4), DT.black))
        #expect(DT.close4(r.get(6, 4), DT.white))
        #expect(DT.close4(r.get(4, 4), DT.rgba(0.5, 0.5, 0.5)), "\(r.get(4, 4))")
        #expect(DT.close4(r.get(1, 1), DT.white))
        d.layers[1].vectorMask!.density = 0.5
        #expect(DT.close4(DT.px(d, 6, 4), DT.rgba(0.5, 0.5, 0.5)))
        d.layers[1].vectorMask!.enabled = false
        #expect(DT.close4(DT.px(d, 6, 4), DT.black))
        d.layers[1].mask = nil
        d.layers[1].vectorMask!.enabled = true
        d.layers[1].vectorMask!.density = 1
        r = DT.render(d)
        #expect(DT.close4(r.get(1, 1), DT.black))
        #expect(DT.close4(r.get(6, 1), DT.white))
        // A feathered vector mask blurs its edge (canvas-wide combined mask).
        d.layers[1].vectorMask!.feather = 2
        r = DT.render(d)
        #expect(r.get(3, 4).x > 0.05 && r.get(3, 4).x < 0.5 && r.get(6, 4).x < 0.99, "\(r.get(3, 4)) \(r.get(6, 4))")
    }

    @Test func effectMapsAreInvalidatedByPixelChanges() {
        var doc = DT.docWhite(64, 64)
        var l = DT.solidLayer("fx", DT.rect(16, 16, 48, 48), DT.rgba(1, 0, 0))
        l.effects.items = [.dropShadow(Shadow(common: FxCommon(.multiply, 0.75)))]
        doc.layers.append(l)
        let first = DT.render(doc)
        #expect(DT.render(doc).px == first.px, "cached maps give the same pixels")
        doc.layers[1].withRaster { $0.fill(DT.rect(8, 8, 20, 20), with: [0, 0, 1, 1]) }
        let again = DT.render(doc)
        #expect(again.px != first.px, "pixel edit invalidates")
        // Tileless masks differ only in their defaults: reusing their maps would leave a ghost.
        var masked = DT.fxDoc([.dropShadow(DT.shadow(5, 90))])
        masked.layers[1].mask = .revealAll()
        #expect(DT.close4(DT.px(masked, 20, 32), DT.black))
        masked.layers[1].mask = .hideAll()
        #expect(DT.close4(DT.px(masked, 20, 32), DT.white))
    }
}
