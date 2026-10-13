// Port of photocraft-paint (crates/paint/src/retouch.rs, mixer.rs, replace.rs, bg_erase.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
import PCFoundation
@testable import PCPaint

func toolStroke(_ points: [(Double, Double)], _ size: Float, _ hardness: Float) -> Stroke {
    Stroke(brush: with(BrushSettings()) { $0.size = size; $0.hardness = hardness; $0.spacing = 0.25; $0.pressureSize = false },
           points: points.map { StrokePoint($0.0, $0.1, 1) })
}

@Suite struct RetouchTests {
    @Test func coverageMatchesApplyStrokeBounds() {
        let (r, cov) = Retouch.strokeCoverage(toolStroke([(10, 10), (40, 12)], 8, 1))
        #expect(r.contains(x: 10, y: 10) && r.contains(x: 40, y: 12))
        let w = r.width
        #expect(abs(cov[Int(10 - r.y0) * w + Int(25 - r.x0)] - 1) < 1e-6)
        #expect(cov.allSatisfy { (0...1).contains($0) })
    }

    @Test func coverageCompositeCopiesExactlyAtFullHardness() {
        for fmt in [PixelFormat.rgba8, .rgba16, .rgba32f, .cmyka8, .graya8] {
            let n = fmt.channels
            var s = Surface(format: fmt)
            s.fillRect(PixelRect(x0: 0, y0: 0, x1: 64, y1: 64), (0..<n).map { $0 + 1 == n ? 1 : 0.2 })
            let (r, cov) = Retouch.strokeCoverage(toolStroke([(20, 20)], 10, 1))
            var paint = Region(rect: r, ch: n)
            for i in paint.data.indices { paint.data[i] = (fmt.alpha && i % n == n - 1) ? 1 : 0.8 }
            Retouch.applyCoverage(&s, rect: r, cov: cov, opacity: 1, selection: nil, lockTransparency: false, paint: paint, blend: .normal)
            let p = s.pixel(x: 20, y: 20)
            #expect(p[0..<(n - 1)].allSatisfy { abs($0 - 0.8) < 1e-2 } && p[n - 1] == 1, "\(fmt) \(p)")
            #expect(abs(s.pixel(x: 40, y: 40)[0] - 0.2) < 1e-2)
        }
    }

    @Test func dabStrokeRunsSequentiallyAndRespectsSelection() {
        var s = Surface(format: .gray8)
        var sel = Surface(format: .gray8)
        sel.fillRect(PixelRect(x0: 0, y0: 0, x1: 30, y1: 100), [1])
        var seen: [Int] = []
        Retouch.applyDabStroke(&s, toolStroke([(10, 10), (50, 10)], 6, 1), selection: sel, lockTransparency: false, halo: 2) { work, fp in
            seen.append(fp.index)
            for y in fp.rect.y0..<fp.rect.y1 {
                for x in fp.rect.x0..<fp.rect.x1 where fp.at(x, y) > 0.5 { work.withPixel(x, y) { $0[0] += 0.1 } }
            }
        }
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $1 == $0 + 1 })
        #expect(s.pixel(x: 20, y: 10)[0] > 0.1, "dabs accumulate")
        #expect(s.pixel(x: 40, y: 10)[0] == 0, "outside the selection untouched")
    }

    @Test func smudgeDragsColourAlongTheStroke() {
        for fmt in [PixelFormat.rgba8, .rgba16, .rgba32f] {
            var s = Surface(format: fmt)
            s.fillRect(PixelRect(x0: 0, y0: 0, x1: 100, y1: 40), [1, 1, 1, 1])
            s.fillRect(PixelRect(x0: 0, y0: 0, x1: 30, y1: 40), [1, 0, 0, 1])
            let st = toolStroke([(20, 20), (70, 20)], 12, 1)
            var sm = Smudge(strength: 0.8, finger: nil, maxBrushSize: 12)
            Retouch.applyDabStroke(&s, st, selection: nil, lockTransparency: false, halo: 0) { w, fp in sm.dab(&w, fp) }
            func g(_ x: Int32) -> Float { s.pixel(x: x, y: 20)[1] }
            #expect(g(35) < 0.5, "\(fmt) \(g(35))")
            #expect(g(35) < g(60), "\(fmt)")
            #expect(s.pixel(x: 35, y: 35)[1] == 1, "off-stroke untouched")
            var s2 = Surface(format: fmt)
            s2.fillRect(PixelRect(x0: 0, y0: 0, x1: 100, y1: 40), [1, 1, 1, 1])
            var fg = Smudge(strength: 0.8, finger: [0, 0, 1, 1], maxBrushSize: 12)
            Retouch.applyDabStroke(&s2, st, selection: nil, lockTransparency: false, halo: 0) { w, fp in fg.dab(&w, fp) }
            #expect(s2.pixel(x: 22, y: 20)[0] < 0.5)
        }
    }

    @Test func smudgeIntoTransparencyLeavesNoDarkFringe() {
        // #207: straight mixing dragged the black of transparent pixels into the colour.
        for fmt in [PixelFormat.rgba8, .rgba16, .rgba32f] {
            var s = Surface(format: fmt)
            s.fillRect(PixelRect(x0: 0, y0: 0, x1: 30, y1: 40), [1, 0.8, 0, 1])
            let st = toolStroke([(20, 20), (70, 20)], 12, 0.5)
            var sm = Smudge(strength: 0.8, finger: nil, maxBrushSize: 12).withAlpha(3)
            Retouch.applyDabStroke(&s, st, selection: nil, lockTransparency: false, halo: 0) { w, fp in sm.dab(&w, fp) }
            var smudged = 0
            for x: Int32 in 30..<80 {
                for y: Int32 in 14..<27 {
                    let p = s.rgba(x, y)
                    if p.w > 0.02 {
                        smudged += 1
                        #expect(p.x > 0.97 && abs(p.y - 0.8) < 0.03, "\(fmt) (\(x),\(y)): \(p) darkened")
                    }
                }
            }
            #expect(smudged > 50, "\(fmt): colour was dragged into the transparent area")
            var s3 = Surface(format: fmt)
            s3.fillRect(PixelRect(x0: 0, y0: 0, x1: 30, y1: 40), [1, 0.8, 0, 1])
            var st2 = st
            st2.brush.opacity = 0.5
            var sm2 = Smudge(strength: 0.8, finger: nil, maxBrushSize: 12).withAlpha(3)
            Retouch.applyDabStroke(&s3, st2, selection: nil, lockTransparency: false, halo: 0) { w, fp in sm2.dab(&w, fp) }
            let p = s3.rgba(34, 20)
            #expect(p.w > 0.02 && p.x > 0.97, "\(fmt): \(p)")
        }
    }

    @Test func premultipliedMixIgnoresColourOfTransparentPixels() {
        var d: [Float] = [0, 0, 0, 0]
        Retouch.mixPremultiplied(&d, [1, 0.5, 0, 1], 3, 0.25)
        #expect(d == [1, 0.5, 0, 0.25])
        d = [0.2, 0.2, 0.2, 1]
        Retouch.mixPremultiplied(&d, [0, 0, 0, 0], 3, 1)
        #expect(d[3] == 0)
        d = [0.5, 0.5]
        Retouch.mixPremultiplied(&d, [1, 1], 7, 0.5)
        #expect(d == [0.5, 0.5])
    }

    @Test func footprintStaysInsideTheFullSizeRing() {
        let radius: Float = 10.5
        for hardness: Float in [1, 0.5, 0] {
            let dab = Dab.round(PaintPoint(32, 32), radius, 1)
            let fp = Retouch.footprint(dab, index: 0, hardness: hardness)
            var painted = 0
            var farthest = 0.0
            for y in fp.rect.y0..<fp.rect.y1 {
                for x in fp.rect.x0..<fp.rect.x1 where fp.at(x, y) > 0 {
                    let dist = ((Double(x) + 0.5 - dab.center.x) * (Double(x) + 0.5 - dab.center.x)
                        + (Double(y) + 0.5 - dab.center.y) * (Double(y) + 0.5 - dab.center.y)).squareRoot()
                    painted += 1
                    farthest = max(farthest, dist)
                    #expect(dist < Double(radius) + 0.5, "hardness \(hardness): (\(x), \(y)) at \(dist) px is past the ring")
                }
            }
            #expect(painted > 0, "hardness \(hardness): nothing painted")
            if hardness == 1 { #expect(farthest > Double(radius), "a hard tip painted only \(farthest) px out") }
        }
    }
}

@Suite struct MixerTests {
    func stroke(_ y: Double) -> Stroke { toolStroke([(4, y), (196, y)], 8, 1) }

    @Test func lowLoadRunsDryAndFullLoadDoesNot() {
        for (load, expectDry) in [(Float(0), true), (1, false)] {
            var s = Surface(format: .rgba8)
            var st = MixerState()
            st.load(SIMD4(1, 0, 0, 1))
            MixerBrush.apply(&s, sample: nil, stroke: stroke(10), settings: MixerSettings(wet: 0, load: load, mix: 0, flow: 1), state: &st,
                             selection: nil, lockTransparency: false)
            let start = s.rgba(10, 10).w, end = s.rgba(190, 10).w
            #expect(start > 0.95, "\(start)")
            if expectDry {
                #expect(end < start * 0.6, "load \(load): \(start) → \(end)")
                #expect(st.amount < 0.2)
            } else {
                #expect(end > 0.95, "\(end)")
                #expect(abs(st.amount - 1) < 1e-6)
            }
        }
    }

    @Test func wetBrushPicksUpAndSmearsCanvasColour() {
        var s = Surface(format: .rgba8)
        s.fillRect(PixelRect(x0: 0, y0: 0, x1: 100, y1: 20), [0, 0, 1, 1])
        s.fillRect(PixelRect(x0: 100, y0: 0, x1: 200, y1: 20), [1, 1, 1, 1])
        var st = MixerState()
        st.load(SIMD4(1, 0, 0, 1))
        MixerBrush.apply(&s, sample: nil, stroke: stroke(10), settings: MixerSettings(wet: 1, load: 0.3, mix: 0.9, flow: 1), state: &st,
                         selection: nil, lockTransparency: false)
        let c = s.rgba(115, 10)
        #expect(c.z > c.y + 0.05 && c.y < 0.95, "\(c)")
        #expect(st.pickup!.z > 0.2, "\(st.pickup!)")
        st.clean()
        #expect(st.pickup == nil)
    }

    @Test func dryEmptyBrushPaintsNothing() {
        var s = Surface(format: .rgba8)
        var st = MixerState()
        let dmg = MixerBrush.apply(&s, sample: nil, stroke: stroke(10), settings: MixerSettings(wet: 0), state: &st, selection: nil, lockTransparency: false)
        #expect(!dmg.isEmpty)
        #expect(s.rgba(50, 10).w == 0)
    }

    @Test func transferWetnessControlScalesPickupPerDab() {
        func run(_ pressure: Float) -> SIMD4<Float>? {
            var s = Surface(format: .rgba8)
            s.fillRect(PixelRect(x0: 0, y0: 0, x1: 200, y1: 20), [0, 0, 1, 1])
            var st = MixerState()
            st.load(SIMD4(1, 0, 0, 1))
            var k = stroke(10)
            k.brush.transfer = Transfer(enabled: true, wetness: .controlled(.penPressure))
            for i in k.points.indices { k.points[i].pressure = pressure }
            MixerBrush.apply(&s, sample: nil, stroke: k, settings: MixerSettings(wet: 1, load: 1, mix: 1, flow: 1), state: &st,
                             selection: nil, lockTransparency: false)
            return st.pickup
        }
        #expect(run(0) == nil)
        #expect((run(1)?.z ?? 0) > 0.2)
    }
}

@Suite struct ColorReplacementTests {
    func setup(_ fmt: PixelFormat) -> Surface {
        var s = Surface(format: fmt)
        s.fillRect(PixelRect(x0: 0, y0: 0, x1: 40, y1: 40), fromRGBA(fmt, SIMD4(0.2, 0.6, 0.2, 1)))
        s.fillRect(PixelRect(x0: 40, y0: 0, x1: 80, y1: 40), fromRGBA(fmt, SIMD4(0.1, 0.1, 0.5, 1)))
        return s
    }

    func stroke() -> Stroke { toolStroke([(20, 20), (60, 20)], 30, 1) }

    @Test func modesFollowTheNonseparableDefinitions() {
        let fg = SIMD4<Float>(1, 0, 0, 1)
        let green = SIMD3<Float>(0.2, 0.6, 0.2)
        for mode in ReplaceMode.allCases {
            var s = setup(.rgba32f)
            ColorReplacement.apply(&s, stroke(), ReplaceSettings(mode: mode, sampling: .once, limits: .discontiguous, tolerance: 0.1, color: fg),
                                   selection: nil, lockTransparency: false)
            let c = s.rgba(20, 20)
            let rgb = SIMD3(c.x, c.y, c.z)
            switch mode {
            case .hue, .color:
                #expect(abs(Blend.lum(rgb) - Blend.lum(green)) < 1e-3, "\(mode) \(c)")
                #expect(c.x > c.y, "\(mode) turned red-ish \(c)")
            case .saturation:
                #expect(abs(Blend.lum(rgb) - Blend.lum(green)) < 1e-3 && c.y > c.x, "\(c)")
            case .luminosity:
                #expect(abs(Blend.lum(rgb) - Blend.lum(SIMD3(1, 0, 0))) < 1e-3, "\(c)")
            }
            let b = s.rgba(60, 20)
            #expect(abs(b.z - 0.5) < 1e-3 && abs(b.x - 0.1) < 1e-3, "\(mode) \(b)")
        }
    }

    @Test func continuousSamplingFollowsTheCursorAndSwatchLimits() {
        var s = setup(.rgba8)
        let rs = ReplaceSettings(mode: .color, sampling: .continuous, limits: .contiguous, tolerance: 0.1, color: SIMD4(1, 0, 0, 1))
        ColorReplacement.apply(&s, stroke(), rs, selection: nil, lockTransparency: false)
        #expect(s.rgba(20, 20).x > 0.3 && s.rgba(70, 20).x > s.rgba(70, 20).y, "both halves recoloured")
        var s2 = setup(.rgba8)
        var rs2 = rs
        rs2.sampling = .backgroundSwatch
        rs2.background = SIMD4(1, 1, 1, 1)
        ColorReplacement.apply(&s2, stroke(), rs2, selection: nil, lockTransparency: false)
        #expect(s2.rgba(20, 20) == setup(.rgba8).rgba(20, 20))
    }

    @Test func contiguousStopsAtDisconnectedMatches() {
        var s = Surface(format: .rgba32f)
        s.fillRect(PixelRect(x0: 0, y0: 0, x1: 60, y1: 40), [0.2, 0.6, 0.2, 1])
        s.fillRect(PixelRect(x0: 30, y0: 0, x1: 34, y1: 40), [0, 0, 1, 1])
        var st = stroke()
        st.points = [StrokePoint(20, 20, 1)]
        for (limits, islandChanged) in [(Limits.contiguous, false), (.discontiguous, true)] {
            var t = s
            ColorReplacement.apply(&t, st, ReplaceSettings(mode: .color, sampling: .once, limits: limits, tolerance: 0.05, color: SIMD4(1, 0, 0, 1)),
                                   selection: nil, lockTransparency: false)
            #expect((abs(t.rgba(34, 20).x - 0.2) > 0.05) == islandChanged, "\(limits)")
            #expect(t.rgba(20, 20).x > 0.3)
        }
    }
}

@Suite struct BackgroundEraserTests {
    let green = SIMD4<Float>(0.2, 0.6, 0.2, 1)
    let blue = SIMD4<Float>(0.1, 0.1, 0.5, 1)

    func setup(_ fmt: PixelFormat) -> Surface {
        var s = Surface(format: fmt)
        s.fillRect(PixelRect(x0: 0, y0: 0, x1: 40, y1: 40), fromRGBA(fmt, green))
        s.fillRect(PixelRect(x0: 40, y0: 0, x1: 80, y1: 40), fromRGBA(fmt, blue))
        return s
    }

    func stroke(_ pts: [(Double, Double)]) -> Stroke { toolStroke(pts, 30, 1) }
    func alpha(_ s: Surface, _ x: Int32, _ y: Int32) -> Float { s.rgba(x, y).w }

    @Test func onceErasesOnlyTheSampledColourInEveryFormat() {
        for mode in [ColorMode.rgb, .cmyk, .grayscale] {
            for sample in [SampleType.u8, .u16, .f32] {
                let fmt = PixelFormat.make(mode, sample, true)
                var s = setup(fmt)
                let d = BackgroundEraser.apply(&s, stroke([(20, 20), (60, 20)]), BgEraseSettings(sampling: .once, limits: .discontiguous, tolerance: 0.05),
                                               selection: nil)
                #expect(!d.isEmpty)
                #expect(alpha(s, 20, 20) == 0, "\(fmt) green under the hotspot erased")
                #expect(alpha(s, 45, 20) == 1, "\(fmt) blue kept")
                #expect(alpha(s, 20, 39) == 1, "\(fmt) outside the brush kept")
            }
        }
    }

    @Test func continuousFollowsTheHotspotAndSwatchMatchesBackground() {
        var s = setup(.rgba8)
        let bs = BgEraseSettings(sampling: .continuous, limits: .discontiguous, tolerance: 0.05)
        BackgroundEraser.apply(&s, stroke([(20, 20), (60, 20)]), bs, selection: nil)
        #expect(alpha(s, 20, 20) == 0)
        #expect(alpha(s, 60, 20) == 0, "blue erased once the hotspot reached it")
        var t = setup(.rgba8)
        var bs2 = bs
        bs2.sampling = .backgroundSwatch
        bs2.background = blue
        BackgroundEraser.apply(&t, stroke([(30, 20), (50, 20)]), bs2, selection: nil)
        #expect(alpha(t, 30, 20) == 1)
        #expect(alpha(t, 50, 20) == 0)
    }

    @Test func contiguousAndProtectForeground() {
        var s = Surface(format: .rgba32f)
        s.fillRect(PixelRect(x0: 0, y0: 0, x1: 60, y1: 40), [0.2, 0.6, 0.2, 1])
        s.fillRect(PixelRect(x0: 26, y0: 0, x1: 30, y1: 40), [0.1, 0.1, 0.5, 1])
        for (limits, islandErased) in [(Limits.contiguous, false), (.findEdges, false), (.discontiguous, true)] {
            var t = s
            BackgroundEraser.apply(&t, stroke([(20, 20)]), BgEraseSettings(sampling: .once, limits: limits, tolerance: 0.05), selection: nil)
            #expect((alpha(t, 31, 20) == 0) == islandErased, "\(limits)")
            #expect(alpha(t, 20, 20) == 0)
        }
        var t = s
        BackgroundEraser.apply(&t, stroke([(20, 20)]), BgEraseSettings(sampling: .once, tolerance: 0.05, protectForeground: true, foreground: green),
                               selection: nil)
        #expect(t == s)
    }

    @Test func selectionLimitsAndDegenerateInputs() {
        var s = setup(.rgba8)
        var sel = Surface(format: .gray8)
        sel.fillRect(PixelRect(x0: 0, y0: 0, x1: 20, y1: 40), [1])
        let bs = BgEraseSettings(sampling: .once, limits: .discontiguous, tolerance: 0.05)
        BackgroundEraser.apply(&s, stroke([(20, 20)]), bs, selection: sel)
        #expect(alpha(s, 15, 20) == 0)
        #expect(alpha(s, 25, 20) == 1, "outside the selection kept")
        var t = Surface(format: .rgba8)
        #expect(BackgroundEraser.apply(&t, stroke([(5, 5)]), bs, selection: nil).width > 0)
        #expect(t.contentBounds == .empty)
        var u = setup(.rgba8)
        var nan = bs
        nan.tolerance = .nan
        BackgroundEraser.apply(&u, stroke([(20, 20)]), nan, selection: nil)
        #expect(alpha(u, 20, 20) == 0, "exact match still erased at tolerance 0")
        var g = Surface(format: .gray8)
        #expect(BackgroundEraser.apply(&g, stroke([(5, 5)]), bs, selection: nil).isEmpty)
    }
}

/// Strokes convert their colour into a CMYK surface through the scoped converter
/// (`ColorConvert.withCMYK`, photocraft `with_cmyk_space`): two documents with different CMYK
/// profiles stroking in parallel tasks each get their own ink.
@Suite struct CMYKSpaceTests {
    /// A "profile" that maps every colour to one ink, so the result names the converter that ran.
    struct OneInk: CMYKConverter {
        let ink: SIMD4<Float>
        func cmykToRGB(_ c: SIMD4<Float>) -> SIMD3<Float> { SIMD3(repeating: 1 - ink.w) }
        func rgbToCMYK(_ rgb: SIMD3<Float>) -> SIMD4<Float> { ink }
    }

    static func stroke(_ y: Double) -> Stroke {
        Stroke(brush: with(BrushSettings()) { $0.size = 8; $0.hardness = 1; $0.color = SIMD4(0.2, 0.6, 0.4, 1) },
               points: [StrokePoint(4, y, 1), StrokePoint(60, y, 1)])
    }

    @Test func parallelStrokesUseTheirTasksConverter() async {
        let inks: [SIMD4<Float>] = [SIMD4(0.8, 0.1, 0, 0), SIMD4(0, 0, 0.6, 0.2), SIMD4(0.8, 0.1, 0, 0), SIMD4(0, 0, 0.6, 0.2)]
        await withTaskGroup(of: Bool.self) { group in
            for ink in inks {
                group.addTask {
                    await ColorConvert.withCMYK(OneInk(ink: ink)) {
                        var ok = true
                        for i in 0..<8 {
                            var s = Surface(format: .cmyka8)
                            let y = 10 + Double(i) * 6
                            _ = renderStroke(&s, CMYKSpaceTests.stroke(y).brush, CMYKSpaceTests.stroke(y).points)
                            let p = s.pixel(x: 30, y: Int32(y))
                            ok = ok && zip(p.prefix(4), [ink.x, ink.y, ink.z, ink.w]).allSatisfy { abs($0 - $1) <= 0.5 / 255 + 1e-6 } && p[4] == 1
                            await Task.yield()
                        }
                        return ok
                    }
                }
            }
            for await ok in group { #expect(ok) }
        }
        // Outside any scope: the process-wide converter (or the naive formulas).
        var s = Surface(format: .cmyka8)
        _ = renderStroke(&s, Self.stroke(10).brush, Self.stroke(10).points)
        let want = ColorConvert.rgbToCMYK(SIMD3(0.2, 0.6, 0.4))
        #expect(abs(s.pixel(x: 30, y: 10)[0] - want.x) <= 0.5 / 255 + 1e-6)
    }
}
