// Port of photocraft-compose (crates/compose/src/advanced_tests.rs; tests.rs Blend If, channel restrictions, PSD-fidelity effect semantics, adjustment depth rounding, Lab documents), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
import PCDocument
import PCFoundation
@testable import PCRender

@Suite("Advanced blending (compose advanced_tests.rs)")
struct DocumentAdvancedTests {
    static let depths: [SampleType] = [.u8, .u16, .f32]
    static let red = SIMD4<Float>(1, 0, 0, 1), green = SIMD4<Float>(0, 1, 0, 1), blue = SIMD4<Float>(0, 0, 1, 1), gray = SIMD4<Float>(0.5, 0.5, 0.5, 1)

    /// `check`: the pixel, rendered alone and as part of the whole canvas (both CPU-vs-GPU checked).
    static func check(_ d: Document, _ x: Int32, _ y: Int32, _ want: SIMD4<Float>, _ what: String,
                      sourceLocation: SourceLocation = #_sourceLocation) {
        let one = DT.render(d, DT.rect(x, y, x + 1, y + 1), name: what, sourceLocation: sourceLocation).px[0]
        #expect(DT.close4(one, want), "\(what) (\(d.depth)) at (\(x),\(y)): got \(one), want \(want)", sourceLocation: sourceLocation)
        let whole = DT.render(d, name: what, sourceLocation: sourceLocation)
        #expect(DT.close4(whole.get(x, y), one), "\(what): the 1-pixel plan differs from the whole canvas", sourceLocation: sourceLocation)
    }

    /// A 12×8 document with a white Background (or none).
    static func doc(_ depth: SampleType, _ background: Bool) -> Document {
        background ? DT.docWhite(12, 8, depth: depth) : Document(name: "t", size: PixelSize(width: 12, height: 8), mode: .rgb, depth: depth)
    }

    static func solid(_ d: Document, _ name: String, _ r: PixelRect, _ c: SIMD4<Float>) -> Layer {
        DT.solidLayer(name, r, c, format: d.pixelFormat)
    }

    static func knocker(_ d: Document, _ k: Knockout) -> Layer {
        var l = solid(d, "knock", DT.rect(0, 0, 6, 8), blue)
        l.advanced.knockout = k
        l.fillOpacity = 0
        return l
    }

    static func maskSurface(_ depth: SampleType, _ r: PixelRect) -> Surface {
        var m = Surface(format: PixelFormat(mode: .grayscale, sample: depth, alpha: false))
        m.fill(r, with: [1])
        return m
    }

    @Test func shallowKnockoutStopsAtTheBottomOfAnIsolatedGroup() {
        for depth in Self.depths {
            var d = Self.doc(depth, true)
            var g = Layer.group("g", [Self.solid(d, "red", d.bounds, Self.red), Self.knocker(d, .shallow)])
            g.blend = .normal
            d.layers += [Self.solid(d, "green", d.bounds, Self.green), g]
            Self.check(d, 2, 2, Self.green, "shallow, fill 0")
            Self.check(d, 9, 2, Self.red, "outside the shape")
            d.layers[2].withChildren { $0[1].fillOpacity = 0.5 }
            Self.check(d, 2, 2, SIMD4(0, 0.5, 0.5, 1), "shallow, fill 50 %")
            d.layers[2].withChildren { $0[1].advanced.knockout = .none }
            Self.check(d, 2, 2, SIMD4(0.5, 0, 0.5, 1), "no knockout")
        }
    }

    @Test func deepKnockoutReachesTheBackgroundThroughGroups() {
        for depth in Self.depths {
            var d = Self.doc(depth, true)
            let inner = Layer.group("inner", [Self.knocker(d, .deep)])
            let outer = Layer.group("outer", [Self.solid(d, "red", d.bounds, Self.red), inner])
            d.layers += [Self.solid(d, "green", d.bounds, Self.green), outer]
            Self.check(d, 2, 2, DT.white, "deep reveals the Background")
            Self.check(d, 9, 2, Self.red, "outside the shape")
            d.layers[2].blend = .normal
            Self.check(d, 2, 2, Self.green, "deep inside an isolated group")
            d.layers[2].blend = .passThrough
            d.layers[2].withChildren { $0[1].blend = .normal }
            Self.check(d, 2, 2, Self.red, "deep inside an isolated inner group")
        }
    }

    @Test func topLevelShallowKnockoutReachesTheBackgroundOrTransparency() {
        for depth in Self.depths {
            var d = Self.doc(depth, true)
            d.layers += [Self.solid(d, "green", d.bounds, Self.green), Self.knocker(d, .shallow)]
            Self.check(d, 2, 2, DT.white, "top-level shallow")
            d.layers[2].opacity = 0.5
            Self.check(d, 2, 2, SIMD4(0.5, 1, 0.5, 1), "half-strength knockout")
            var nobg = Self.doc(depth, false)
            nobg.layers += [Self.solid(nobg, "green", nobg.bounds, Self.green), Self.knocker(nobg, .deep)]
            Self.check(nobg, 2, 2, DT.clear, "deep without a Background")
            Self.check(nobg, 9, 2, Self.green, "outside the shape")
            d.layers[0].visible = false
            d.layers[2].opacity = 1
            Self.check(d, 2, 2, DT.clear, "hidden Background")
        }
    }

    @Test func shallowKnockoutInAPassThroughGroupRevealsWhatIsBeneathIt() {
        for depth in Self.depths {
            var d = Self.doc(depth, true)
            let g = Layer.group("pt", [Self.solid(d, "red", d.bounds, Self.red), Self.knocker(d, .shallow)])
            #expect(g.blend == .passThrough)
            d.layers += [Self.solid(d, "green", d.bounds, Self.green), g]
            Self.check(d, 2, 2, Self.green, "pass-through shallow")
            d.layers[2].withChildren { $0[1].advanced.knockout = .deep }
            Self.check(d, 2, 2, DT.white, "pass-through deep")
        }
    }

    @Test func knockoutOnAGroupUsesItsCompositeShapeAndFill() {
        for depth in Self.depths {
            var d = Self.doc(depth, true)
            var g = Layer.group("g", [Self.solid(d, "blue", DT.rect(0, 0, 6, 8), Self.blue)])
            g.blend = .normal
            g.fillOpacity = 0.5
            g.advanced.knockout = .deep
            d.layers += [Self.solid(d, "green", d.bounds, Self.green), g]
            Self.check(d, 2, 2, SIMD4(0.5, 0.5, 1, 1), "blue at 50 % over the Background")
            Self.check(d, 9, 2, Self.green, "outside the group's pixels")
        }
    }

    @Test func knockoutFollowsMasksAndTransparencyShapes() {
        for depth in Self.depths {
            var d = Self.doc(depth, true)
            d.layers.append(Self.solid(d, "green", d.bounds, Self.green))
            var k = Self.knocker(d, .deep)
            k.mask = LayerMask(surface: Self.maskSurface(depth, DT.rect(0, 0, 3, 8)))
            d.layers.append(k)
            Self.check(d, 1, 2, DT.white, "inside the mask")
            Self.check(d, 4, 2, Self.green, "masked out")
            d.layers[2].mask = nil
            d.layers[2].advanced.transparencyShapes = false
            Self.check(d, 9, 2, DT.white, "beyond the pixels, tsly off")
        }
    }

    @Test func clippedLayerShallowKnockoutStopsAtTheBase() {
        for depth in Self.depths {
            var d = Self.doc(depth, true)
            var mid = Self.solid(d, "mid", d.bounds, Self.green)
            mid.clipped = true
            var k = Self.knocker(d, .shallow)
            k.clipped = true
            d.layers += [Self.solid(d, "base", d.bounds, Self.red), mid, k]
            Self.check(d, 2, 2, Self.red, "the base shows through the clipped layer above it")
            Self.check(d, 9, 2, Self.green, "outside")
            d.layers[3].advanced.knockout = .deep
            Self.check(d, 2, 2, Self.red, "clipped deep stops at the base too")
        }
    }

    @Test func blendClippedLayersIndividually() {
        for depth in Self.depths {
            var d = Self.doc(depth, false)
            var base = Self.solid(d, "base", DT.rect(0, 0, 6, 8), Self.red)
            base.blend = .screen
            var clip = Self.solid(d, "clip", d.bounds, Self.blue)
            clip.clipped = true
            clip.blend = .multiply
            d.layers += [Self.solid(d, "gray", d.bounds, Self.gray), base, clip]
            Self.check(d, 2, 2, Self.gray, "as group")
            d.layers[1].advanced.blendClipped = false
            Self.check(d, 2, 2, SIMD4(0, 0, 0.5, 1), "individually")
            Self.check(d, 9, 2, Self.gray, "outside the base")
            d.layers[1].opacity = 0.5
            Self.check(d, 2, 2, SIMD4(0.375, 0.25, 0.5, 1), "half-opacity base")
        }
    }

    static func overlay(_ c: SIMD3<Float>) -> Effect { .colorOverlay(.init(common: FxCommon(.normal, 1), color: .rgb(c.x, c.y, c.z))) }

    @Test func blendInteriorEffectsAsGroupPutsOverlaysUnderFillOpacity() {
        for depth in Self.depths {
            var d = Self.doc(depth, true)
            var l = Self.solid(d, "l", DT.rect(0, 0, 6, 8), Self.blue)
            l.effects.items = [Self.overlay(SIMD3(1, 0, 0))]
            l.fillOpacity = 0
            d.layers.append(l)
            Self.check(d, 2, 2, Self.red, "default: overlays ignore fill")
            d.layers[1].advanced.blendInterior = true
            Self.check(d, 2, 2, DT.white, "as group at fill 0")
            d.layers[1].fillOpacity = 0.5
            Self.check(d, 2, 2, SIMD4(1, 0.5, 0.5, 1), "as group at fill 50 %")
            d.layers[1].advanced.blendInterior = false
            Self.check(d, 2, 2, Self.red, "default at fill 50 %")
        }
    }

    @Test func transparencyShapesOffSpreadsEffectsOverTheWholeLayer() {
        for depth in Self.depths {
            var d = Self.doc(depth, true)
            var l = Self.solid(d, "l", DT.rect(0, 0, 6, 8), Self.blue)
            l.effects.items = [Self.overlay(SIMD3(1, 0, 0))]
            d.layers.append(l)
            Self.check(d, 9, 2, DT.white, "default: the overlay follows the pixels")
            d.layers[1].advanced.transparencyShapes = false
            Self.check(d, 9, 2, Self.red, "tsly off: the overlay covers the layer")
            Self.check(d, 2, 2, Self.red, "inside")
            d.layers[1].fillOpacity = 0
            Self.check(d, 9, 2, Self.red, "tsly off, fill 0")
        }
    }

    static func insideStroke() -> Effect { .stroke(StrokeFx(common: FxCommon(.normal, 1), size: 2, position: .inside, paint: .color(.rgb(1, 0, 0)))) }

    @Test func shapelessStrokeTileSkipsMatchFullRegionAcrossBlendingSettings() throws {
        for depth in Self.depths {
            for position in [StrokePosition.outside, .inside, .center] {
                for (blend, fill, blendIf) in [(BlendMode.normal, Float(0), false), (.multiply, 0.5, true), (.screen, 1, false), (.difference, 0.5, false)] {
                    var d = DT.docWhite(80, 768, depth: depth)
                    var l = Self.solid(d, "stroke", DT.rect(28, 318, 52, 342), Self.blue)
                    l.effects.items = [.stroke(StrokeFx(common: FxCommon(.normal, 1), size: 6, position: position, paint: .color(.rgb(1, 0, 0))))]
                    l.blend = blend
                    l.fillOpacity = fill
                    l.advanced.transparencyShapes = false
                    if blendIf { l.blendIf.set(0, BlendRangePair(.full, DT.range(SIMD2(128, 128), SIMD2(255, 255)))) }
                    d.layers.append(l)
                    let whole = DT.render(d)
                    var banded: [SIMD4<Float>] = []
                    try DT.cpu.renderBands(d, rect: d.bounds, bandRows: 256) { banded += $0.px }
                    #expect(banded == whole.px, "banded: \(depth) \(position) \(blend) fill \(fill) blendIf \(blendIf)")
                    let p = DT.cpu.plan(d, region: d.bounds)
                    #expect(try CPUCompositor(tileSize: 64).render(p.plan, region: d.bounds, source: p.source).px == whole.px)
                }
            }
        }
    }

    @Test func shapelessStrokeSkipRejectsAdvancedBlendingAndMasks() {
        let d = Self.doc(.u8, true)
        var l = Self.solid(d, "stroke", DT.rect(2, 2, 8, 8), Self.blue)
        l.effects.items = [.stroke(StrokeFx(common: FxCommon(.normal, 1), size: 6, position: .outside, paint: .color(.rgb(1, 0, 0))))]
        l.advanced.transparencyShapes = false
        #expect(LayerGeometry.shapelessStrokeBounds(l) != nil)
        l.advanced.knockout = .deep
        #expect(LayerGeometry.shapelessStrokeBounds(l) == nil)
        l.advanced.knockout = .none
        l.advanced.blendInterior = true
        #expect(LayerGeometry.shapelessStrokeBounds(l) == nil)
        l.advanced.blendInterior = false
        l.blendIf.set(0, BlendRangePair(.full, DT.range(SIMD2(128, 128), SIMD2(255, 255))))
        #expect(LayerGeometry.shapelessStrokeBounds(l) == nil)
        l.blendIf = BlendIf()
        l.mask = .hideAll()
        #expect(LayerGeometry.shapelessStrokeBounds(l) == nil)
        l.mask = nil
        l.vectorMask = VectorMask(path: DT.polygon([(0, 0), (10, 0), (10, 10), (0, 10)]))
        #expect(LayerGeometry.shapelessStrokeBounds(l) == nil)
    }

    @Test func layerMaskHidesEffects() {
        for depth in Self.depths {
            var d = Self.doc(depth, true)
            var l = Self.solid(d, "l", d.bounds, Self.blue)
            l.effects.items = [Self.insideStroke()]
            l.mask = LayerMask(surface: Self.maskSurface(depth, DT.rect(0, 0, 8, 8)))
            d.layers.append(l)
            Self.check(d, 7, 4, Self.red, "stroke along the mask edge")
            Self.check(d, 9, 4, DT.white, "masked out")
            Self.check(d, 4, 4, Self.blue, "interior")
            d.layers[1].advanced.layerMaskHidesEffects = true
            Self.check(d, 7, 4, Self.blue, "no stroke at the mask edge")
            Self.check(d, 4, 0, Self.red, "the canvas-edge stroke stays")
            Self.check(d, 9, 4, DT.white, "still masked out")
            Self.check(d, 11, 0, DT.white, "the stroke beyond the mask is hidden")
            d.layers[1].advanced.layerMaskHidesEffects = false
            d.layers[1].advanced.vectorMaskHidesEffects = true
            Self.check(d, 7, 4, Self.red, "vmgm without a vector mask")
        }
    }

    @Test func vectorMaskHidesEffects() {
        for depth in Self.depths {
            var d = Self.doc(depth, true)
            var l = Self.solid(d, "l", d.bounds, Self.blue)
            l.effects.items = [Self.insideStroke()]
            l.vectorMask = VectorMask(path: DT.polygon([(-4, -4), (8, -4), (8, 12), (-4, 12)]))
            d.layers.append(l)
            Self.check(d, 7, 4, Self.red, "stroke along the vector mask")
            d.layers[1].advanced.vectorMaskHidesEffects = true
            Self.check(d, 7, 4, Self.blue, "vector mask hides the stroke")
            Self.check(d, 9, 4, DT.white, "masked out")
        }
    }

    @Test func aKnockoutBackgroundDoesNotRecurse() {
        var d = Self.doc(.u8, true)
        d.layers[0].advanced.knockout = .deep
        d.layers[0].fillOpacity = 0
        #expect(DT.render(d, DT.rect(0, 0, 1, 1)).px[0].w <= 1)
    }

    @Test func deepKnockoutRevealsALocalizedBackground() {
        for depth in Self.depths {
            for name in ["Hintergrund", "背景", "Arrière-plan"] {
                var d = Self.doc(depth, true)
                d.layers[0].name = name
                d.layers += [Self.solid(d, "green", d.bounds, Self.green), Self.knocker(d, .deep)]
                Self.check(d, 2, 2, DT.white, name)
            }
            var d = Self.doc(depth, true)
            d.layers[0].locks = Locks()
            d.layers += [Self.solid(d, "green", d.bounds, Self.green), Self.knocker(d, .deep)]
            Self.check(d, 2, 2, DT.clear, "an unlocked layer named Background")
        }
    }
}

@Suite("Blend If, channels and effect semantics (compose tests.rs)")
struct DocumentBlendingTests {
    @Test func channelRestrictionsKeepTheBackdrop() {
        var d = DT.docWhite(8, 8)
        var l = DT.solidLayer("dark", DT.rect(0, 0, 8, 8), DT.rgba(0.2, 0.3, 0.4))
        l.excludedChannels = 0b100
        d.layers.append(l)
        #expect(DT.close4(DT.px(d, 1, 1), DT.rgba(0.2, 0.3, 1)))
        var inv = DT.adjustment(.invert)
        inv.excludedChannels = 0b001
        d.layers.append(inv)
        #expect(DT.close4(DT.px(d, 1, 1), DT.rgba(0.2, 0.7, 0)))
        #expect(LayerGeometry.channelWeights(d.layers[1], mode: .cmyk) == nil)
        #expect(LayerGeometry.channelWeights(d.layers[1], mode: .rgb) == SIMD3(1, 1, 0))
    }

    @Test func blendIfThisLayerHidesByTheLayersOwnValue() {
        var d = DT.docWhite(8, 8)
        d.layers.append(DT.solidLayer("grey", DT.rect(0, 0, 8, 8), DT.rgba(0.5, 0.5, 0.5)))
        var l = DT.solidLayer("bw", DT.rect(0, 0, 4, 8), DT.black)
        l.withRaster { $0.fill(DT.rect(4, 0, 8, 8), with: [1, 1, 1, 1]) }
        l.blendIf.set(0, BlendRangePair(DT.range(SIMD2(50, 50), SIMD2(255, 255)), .full))
        d.layers.append(l)
        var r = DT.render(d)
        #expect(DT.close4(r.get(1, 1), DT.rgba(0.5, 0.5, 0.5)), "\(r.get(1, 1))")
        #expect(DT.close4(r.get(6, 1), DT.white))
        d.layers[2].blendIf.set(0, BlendRangePair(DT.range(SIMD2(50, 50), SIMD2(200, 200)), .full))
        #expect(DT.close4(DT.px(d, 6, 1), DT.rgba(0.5, 0.5, 0.5)))
        d.layers[2].blendIf.set(0, .full)
        #expect(d.layers[2].blendIf.isDefault)
        r = DT.render(d)
        #expect(DT.close4(r.get(1, 1), DT.black))
    }

    @Test func blendIfUnderlyingLayerHidesByTheBackdropValue() {
        var d = DT.docWhite(8, 8)
        d.layers.append(DT.solidLayer("black", DT.rect(0, 0, 4, 8), DT.black))
        var l = DT.solidLayer("red", DT.rect(0, 0, 8, 8), DT.rgba(1, 0, 0))
        l.blendIf.set(0, BlendRangePair(.full, DT.range(SIMD2(0, 0), SIMD2(128, 128))))
        d.layers.append(l)
        let r = DT.render(d)
        #expect(DT.close4(r.get(1, 1), DT.rgba(1, 0, 0)))
        #expect(DT.close4(r.get(6, 1), DT.white))
    }

    /// A split black point (50, 150) at value 100 shows like opacity (100 − 50 + 1) / (150 − 50 + 1):
    /// Photoshop's ramp spans hi − lo + 1 levels (ps-corpus blendif-gray; photocraft's linear
    /// (v − lo) / (hi − lo) gave exactly one half here).
    @Test func blendIfSplitPointFadesLikeOpacity() {
        let v: Float = 100.0 / 255
        var d = DT.docWhite(4, 4)
        d.layers[0].withRaster { $0.fill(DT.rect(0, 0, 4, 4), with: [0, 0.2, 1, 0.5]) }
        var l = DT.solidLayer("v", DT.rect(0, 0, 4, 4), DT.rgba(v, v, v))
        l.blend = .multiply
        var half = l
        half.opacity = 51.0 / 101
        l.blendIf.set(0, BlendRangePair(DT.range(SIMD2(50, 150), SIMD2(255, 255)), .full))
        var d2 = d
        d.layers.append(l)
        d2.layers.append(half)
        let (a, b) = (DT.px(d, 1, 1), DT.px(d2, 1, 1))
        #expect((0..<4).allSatisfy { abs(a[$0] - b[$0]) < 1e-4 }, "\(a) vs \(b)")
    }

    @Test func blendIfPerChannelRanges() {
        var d = DT.docWhite(8, 8)
        var l = DT.solidLayer("c", DT.rect(0, 0, 4, 8), DT.rgba(1, 0, 0))
        l.withRaster { $0.fill(DT.rect(4, 0, 8, 8), with: [0, 0, 1, 1]) }
        l.blendIf.set(3, BlendRangePair(DT.range(SIMD2(0, 0), SIMD2(100, 100)), .full))
        d.layers.append(l)
        let r = DT.render(d)
        #expect(DT.close4(r.get(1, 1), DT.rgba(1, 0, 0)))
        #expect(DT.close4(r.get(6, 1), DT.white))
        d.layers[1].blendIf = BlendIf()
        d.layers[1].blendIf.set(1, BlendRangePair(.full, DT.range(SIMD2(0, 0), SIMD2(254, 254))))
        #expect(DT.close4(DT.px(d, 1, 1), DT.white))
    }

    @Test func blendIfOnAdjustmentAndClippedLayers() {
        var d = DT.docWhite(8, 8)
        d.layers.append(DT.solidLayer("dark", DT.rect(0, 0, 4, 8), DT.rgba(0.1, 0.1, 0.1)))
        var inv = DT.adjustment(.invert)
        inv.blendIf.set(0, BlendRangePair(.full, DT.range(SIMD2(0, 0), SIMD2(128, 128))))
        d.layers.append(inv)
        var r = DT.render(d)
        #expect(DT.close4(r.get(1, 1), DT.rgba(0.9, 0.9, 0.9)))
        #expect(DT.close4(r.get(6, 1), DT.white))
        var e = DT.docWhite(8, 8)
        var base = DT.solidLayer("base", DT.rect(0, 0, 8, 8), DT.black)
        base.withRaster { $0.fill(DT.rect(4, 0, 8, 8), with: [0.9, 0.9, 0.9, 1]) }
        var clip = DT.solidLayer("clip", DT.rect(0, 0, 8, 8), DT.rgba(0, 1, 0))
        clip.clipped = true
        clip.blendIf.set(0, BlendRangePair(.full, DT.range(SIMD2(128, 128), SIMD2(255, 255))))
        e.layers += [base, clip]
        r = DT.render(e)
        #expect(DT.close4(r.get(1, 1), DT.black))
        #expect(DT.close4(r.get(6, 1), DT.rgba(0, 1, 0)))
    }

    @Test func blendIfModes() {
        var d = Document.withBackground(name: "g", size: PixelSize(width: 4, height: 4), mode: .grayscale, depth: .u8, fill: .white)
        var l = Layer.raster("k", format: d.pixelFormat)
        l.withRaster { $0.fill(DT.rect(0, 0, 4, 4), with: [0, 1]) }
        l.blendIf.set(1, BlendRangePair(DT.range(SIMD2(10, 10), SIMD2(255, 255)), .full))
        d.layers.append(l)
        #expect(DT.close4(DT.px(d, 1, 1), DT.white))
        #expect(LayerGeometry.blendIfActive(d.layers[1], mode: .rgb))
        #expect(LayerGeometry.blendIfActive(d.layers[1], mode: .grayscale))
        #expect(!LayerGeometry.blendIfActive(d.layers[1], mode: .cmyk))
        #expect(!LayerGeometry.blendIfActive(d.layers[1], mode: .lab))
        #expect(!LayerGeometry.blendIfActive(d.layers[0], mode: .rgb))
    }

    @Test func strokeCornersFollowThe5x5ChamferMetric() {
        let r = DT.render(DT.fxDoc([DT.stroke(3, .outside)]))
        #expect(abs(1 - r.get(9, 7).x - 0.764) < 0.01, "\(r.get(9, 7))")
        #expect(abs(1 - r.get(8, 8).x - 1) < 0.01)
    }

    @Test func insideStrokeRespectsPartialEdgeCoverage() {
        var d = DT.docWhite(40, 40)
        var l = DT.solidLayer("sq", DT.rect(10, 10, 30, 30), DT.rgba(1, 0, 0))
        l.withRaster { $0.fill(DT.rect(10, 10, 11, 30), with: [1, 0, 0, 0.25]) }
        l.effects.items = [DT.stroke(3, .inside)]
        d.layers.append(l)
        let r = DT.render(d)
        #expect(DT.close4(r.get(10, 20), DT.rgba(0.75, 0.75, 1)), "\(r.get(10, 20))")
        let p = r.get(13, 20)
        #expect(abs(p.z - 0.75) < 0.02 && abs(p.x - 0.25) < 0.02, "\(p)")
    }

    @Test func embossShadesTheCompositedLayer() {
        let emboss = Effect.bevelEmboss(Bevel(style: .emboss, technique: .smooth, depth: 1, up: true, size: 6, soften: 0, angle: 90, altitude: 30,
                                              useGlobalLight: false, highlight: FxCommon(.normal, 1), shadow: FxCommon(.multiply, 0)))
        func make(_ text: Bool, _ fx: Bool) -> SIMD4<Float> {
            var d = DT.docWhite(40, 40)
            var l = DT.solidLayer("sq", DT.rect(10, 10, 30, 30), DT.rgba(0.2, 0.1, 0.6))
            l.withRaster { $0.fill(DT.rect(10, 10, 30, 11), with: [0.2, 0.1, 0.6, 0.5]) }
            if text {
                var t = TextLayer()
                t.cache = l.surface
                l = Layer(name: "t", content: .text(t))
            }
            if fx { l.effects.items = [emboss] }
            d.layers.append(l)
            return DT.px(d, 20, 10)
        }
        let (ct, cr, rt, rr) = (make(true, false), make(false, false), make(true, true), make(false, true))
        #expect(rr.y > cr.y + 0.05, "the top edge is lit: \(rr) vs \(cr)")
        #expect(abs(ct.y - cr.y) > 0.02, "text gamma changes the edge: \(ct) \(cr)")
        for c in 0..<3 {
            let want = (1 - ct[c]) / (1 - cr[c])
            #expect(abs((1 - rt[c]) / (1 - rr[c]) - want) < 2e-3, "channel \(c): \(rt) \(rr) \(ct) \(cr)")
        }
    }

    @Test func interiorEffectsKeepTheLayerAlpha() {
        var d = Document(name: "t", size: PixelSize(width: 40, height: 40), mode: .rgb, depth: .u8)
        var l = DT.solidLayer("sq", DT.rect(10, 10, 30, 30), SIMD4(1, 0, 0, 0.5))
        l.effects.items = [.colorOverlay(.init(common: FxCommon(.normal, 1), color: .rgb(0, 1, 0)))]
        d.layers.append(l)
        #expect(DT.close4(DT.px(d, 20, 20), SIMD4(0, 1, 0, 0.5)))
    }

    @Test func upperStrokeBlendsWithTheBackdropNotTheLowerStroke() {
        let yellow = Effect.stroke(StrokeFx(common: FxCommon(.multiply, 1), size: 3, position: .outside, paint: .color(.rgb(1, 1, 0))))
        let r = DT.render(DT.fxDoc([yellow, DT.stroke(8, .outside)]))
        #expect(DT.close4(r.get(8, 20), DT.rgba(1, 1, 0)), "\(r.get(8, 20))")
        #expect(DT.close4(r.get(4, 20), DT.rgba(0, 0, 1)), "\(r.get(4, 20))")
    }

    @Test func shadowKnockoutNeedsSeeThroughFill() {
        var base = Document(name: "t", size: PixelSize(width: 40, height: 40), mode: .rgb, depth: .u8)
        base.layers.append(DT.solidLayer("bg", DT.rect(0, 0, 40, 40), DT.white))
        var l = DT.solidLayer("sq", DT.rect(10, 10, 30, 30), DT.rgba(1, 0, 0))
        l.withRaster { $0.fill(DT.rect(10, 10, 11, 30), with: [1, 0, 0, 0.5]) }
        l.effects.items = [.dropShadow(DT.shadow(0, 0, spread: 1, size: 4))]
        base.layers.append(l)
        let on = DT.px(base, 10, 20)
        if case .dropShadow(var s) = base.layers[1].effects.items[0] { s.knocksOut = false; base.layers[1].effects.items[0] = .dropShadow(s) }
        #expect(DT.close4(on, DT.px(base, 10, 20)), "\(on)")
    }

    @Test func linkedPatternOverlayAnchorsAtTheEffectsReferencePoint() {
        var tile = Surface(format: DT.rgba8)
        tile.fill(DT.rect(0, 0, 1, 1), with: [1, 0, 0, 1])
        tile.fill(DT.rect(1, 0, 2, 1), with: [0, 0, 1, 1])
        let pat = Pattern(name: "rb", surface: tile, width: 2, height: 1)
        let overlay = Effect.patternOverlay(.init(common: FxCommon(.normal, 1), name: "rb", id: pat.id, scale: 1, angle: 0, link: true, phase: .zero))
        var d = DT.fxDoc([overlay])
        d.patterns.append(pat)
        #expect(DT.close4(DT.px(d, 10, 20), DT.rgba(1, 0, 0)), "the layer's top-left anchors the tiling")
        d.layers[1].effects.reference = SIMD2(11, 0)
        let r = DT.render(d)
        #expect(DT.close4(r.get(11, 20), DT.rgba(1, 0, 0)), "\(r.get(11, 20))")
        #expect(DT.close4(r.get(12, 20), DT.rgba(0, 0, 1)), "\(r.get(12, 20))")
    }

    @Test func outerGlowDoesNotPaintThroughAZeroFillLayer() {
        let background = SIMD4<Float>(0.18, 0.42, 0.85, 1)
        for technique in [GlowTechnique.softer, .precise] {
            var d = DT.docWhite(96, 96)
            d.layers[0].withRaster { $0.fill(DT.rect(0, 0, 96, 96), with: [0.18, 0.42, 0.85, 1]) }
            var layer = DT.solidLayer("glow", DT.rect(24, 24, 72, 72), DT.rgba(1, 0.92, 0.25))
            layer.fillOpacity = 0
            layer.effects.items = [.outerGlow(Glow(common: FxCommon(.normal, 1), paint: .color(.rgb(1, 0.94, 0.28)), technique: technique, spread: 0.5,
                                                   size: 12, contour: .linear, antiAlias: false, range: 0.5, jitter: 0, noise: 0, source: .edge))]
            d.layers.append(layer)
            var r = DT.render(d)
            #expect(DT.close4(r.get(48, 48), background), "\(technique): glow leaked into the transparent fill: \(r.get(48, 48))")
            #expect(DT.close4(r.get(5, 5), background))
            #expect(r.get(22, 48).x > background.x + 0.1, "\(technique): the exterior halo")
            d.layers[1].fillOpacity = 1
            r = DT.render(d)
            #expect(r.get(48, 48).x > 0.9 && r.get(48, 48).y > 0.8)
        }
    }

    @Test func clippedBrightnessAndDesaturationWhitenALighterColorLogo() {
        let yellow = SIMD4<Float>(251.0 / 255, 201.0 / 255, 0, 1)
        var d = DT.docWhite(2, 1)
        d.layers[0].withRaster { $0.fill(DT.rect(0, 0, 2, 1), with: [yellow.x, yellow.y, yellow.z, 1]) }
        var logo = DT.solidLayer("logo", DT.rect(0, 0, 1, 1), yellow)
        logo.blend = .lighterColor
        d.layers.append(logo)
        for adj in [Adjustment.brightnessContrast(brightness: 150, contrast: 0, legacy: false), .vibrance(vibrance: 0, saturation: -100)] {
            var l = DT.adjustment(adj)
            l.clipped = true
            d.layers.append(l)
        }
        let r = DT.render(d)
        #expect([r.get(0, 0).x, r.get(0, 0).y, r.get(0, 0).z].allSatisfy { $0 * 255 >= 252 }, "logo whitened: \(r.get(0, 0))")
        #expect(DT.close4(r.get(1, 0), yellow), "the yellow beside it is untouched")
    }

    // MARK: Adjustments in documents

    @Test func adjustmentResultsAreRoundedToTheDocumentDepth() {
        for (depth, q) in [(SampleType.u8, Float?(255)), (.u16, 32768), (.f32, nil)] {
            var d = Document.withBackground(name: "q", size: PixelSize(width: 4, height: 4), mode: .rgb, depth: depth, fill: .rgb(0.3, 0.6, 0.9))
            d.layers.append(DT.adjustment(.exposure(exposure: 0.37, offset: 0, gamma: 1)))
            // Plans with adjustment layers composite in float on the GPU (in half, a result within
            // a half-float ulp of a level boundary rounded to the neighbouring level: 1.02 levels).
            let p = DT.render(d).get(1, 1)
            if let q {
                #expect((0..<4).allSatisfy { abs((p[$0] * q).rounded() - p[$0] * q) < 1e-3 }, "\(depth) \(p)")
            } else {
                #expect((0..<3).contains { abs((p[$0] * 255).rounded() - p[$0] * 255) > 1e-3 }, "\(p)")
            }
        }
    }

    @Test func exposureScales32BitSamplesAsStored() {
        for (depth, want) in [(SampleType.f32, Float(0.4)), (.u8, 0.2744)] {
            var d = Document(name: "e", size: PixelSize(width: 1, height: 1), mode: .rgb, depth: depth)
            d.layers = [DT.solidLayer("px", DT.rect(0, 0, 1, 1), DT.rgba(0.2, 0.2, 0.2), format: d.pixelFormat),
                        DT.adjustment(.exposure(exposure: 1, offset: 0, gamma: 1))]
            let got = DT.px(d, 0, 0).x
            #expect(abs(got - want) < 2e-3, "\(depth): \(got)")
        }
    }

    @Test func floatAdjustmentsPreserveHDRRange() {
        let identity = [CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)]
        let lv = LevelsChannel(inBlack: 0.25, inWhite: 0.75, gamma: 2, outBlack: -0.1, outWhite: 1.5)
        let base: [Float] = [4, 2, 0.5]
        let cases: [(Adjustment, [Float])] = [
            (.exposure(exposure: 0, offset: 0, gamma: 1), base),
            (.exposure(exposure: 1, offset: 0, gamma: 1), [8, 4, 1]),
            (.levels(.init()), base),
            (.levels(master: lv, perChannel: [.identity, .identity, .identity], space: .rgb, black: .identity),
             base.map { -0.1 + (($0 - 0.25) / 0.5).squareRoot() * 1.6 }),
            (.curves(master: identity, perChannel: [identity, identity, identity], space: .rgb, black: [], pencil: false), base),
            (.curves(master: [], perChannel: [[], [], []], space: .rgb, black: [], pencil: false), base),
        ]
        for (adj, want) in cases {
            var d = Document(name: "HDR", size: PixelSize(width: 1, height: 1), mode: .rgb, depth: .f32)
            d.layers = [DT.solidLayer("pixels", DT.rect(0, 0, 1, 1), SIMD4(4, 2, 0.5, 0.75), format: d.pixelFormat), DT.adjustment(adj)]
            let got = DT.px(d, 0, 0)
            for i in 0..<3 { #expect(abs(got[i] - want[i]) < 1e-5, "\(adj): \(got) vs \(want)") }
            #expect(got.w == 0.75)
        }
    }

    @Test func smallGradientFillMatchesPhotoshopAtAllDepths() {
        for depth in [SampleType.u8, .u16, .f32] {
            var d = Document(name: "g", size: PixelSize(width: 4, height: 4), mode: .rgb, depth: depth)
            d.layers.append(Layer(name: "g", content: .fill(.gradient(GradientFill(stops: [ColorStop(0, .black), ColorStop(1, .white)], angle: 30, scale: 1,
                                                                                    style: .reflected, reverse: false)))))
            let out = DT.render(d)
            for y in 0..<4 { for x in 0..<4 {
                let want = abs(Float(x) - Float(y)) / 4
                #expect(abs(out.px[y * 4 + x].x - want) < 1.0 / 255, "\(depth) (\(x),\(y))")
            } }
        }
    }

    // MARK: Lab documents

    static func labAdjusted(_ rgb: SIMD3<Float>, _ adj: Adjustment, _ depth: SampleType) -> SIMD3<Float> {
        var d = Document.withBackground(name: "lab", size: PixelSize(width: 4, height: 4), mode: .lab, depth: depth, fill: .rgb(rgb.x, rgb.y, rgb.z))
        d.layers.append(DT.adjustment(adj))
        let p = DT.px(d, 1, 1)
        return ColorConvert.srgbToLab(SIMD3(p.x, p.y, p.z))
    }

    static func near3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float) -> Bool { (0..<3).allSatisfy { abs(a[$0] - b[$0]) <= tol } }

    @Test func labDocumentsEvaluateInvertThresholdAndGradientMapOnLab() {
        let c = ColorConvert.labToSRGB(SIMD3(30, 12, -18))
        for depth in [SampleType.u8, .u16, .f32] {
            let inv = Self.labAdjusted(c, .invert, depth)
            #expect(Self.near3(inv, SIMD3(70, -13, 17), 1), "\(depth): \(inv)")
            let th = Self.labAdjusted(c, .threshold(level: 0.25), depth)
            #expect(Self.near3(th, SIMD3(100, 0, 0), 0.5), "\(depth): \(th)")
            let gm = Self.labAdjusted(c, .gradientMap(stops: [GradientMapStop(0, SIMD3(0, 0, 0)), GradientMapStop(1, SIMD3(1, 1, 1))], reverse: false, dither: false), depth)
            #expect(Self.near3(gm, ColorConvert.srgbToLab(SIMD3(repeating: 0.3)), 1), "\(depth): \(gm)")
        }
    }

    @Test func labDocumentsBrightnessContrastMovesLightnessOnly() {
        let muted = SIMD3<Float>(0.40, 0.42, 0.60)
        let lab = ColorConvert.srgbToLab(muted)
        for depth in [SampleType.u8, .u16, .f32] {
            for legacy in [true, false] {
                let got = Self.labAdjusted(muted, .brightnessContrast(brightness: 40, contrast: 20, legacy: legacy), depth)
                #expect(got.x > lab.x + 5, "\(depth) legacy \(legacy): \(got)")
                #expect(Self.near3(SIMD3(lab.x, got.y, got.z), lab, 0.75))
            }
        }
    }

    @Test func labDocumentsThresholdOnLightnessWithANeutralResult() {
        for depth in [SampleType.u8, .u16, .f32] {
            #expect(Self.near3(Self.labAdjusted(SIMD3(1, 1, 0), .threshold(level: 0.5), depth), SIMD3(100, 0, 0), 0.5))
            #expect(Self.near3(Self.labAdjusted(SIMD3(0, 0, 1), .threshold(level: 0.5), depth), SIMD3(0, 0, 0), 0.5))
            #expect(Self.near3(Self.labAdjusted(SIMD3(repeating: 0.5), .threshold(level: 0.52), depth), SIMD3(100, 0, 0), 0.5))
        }
    }
}
