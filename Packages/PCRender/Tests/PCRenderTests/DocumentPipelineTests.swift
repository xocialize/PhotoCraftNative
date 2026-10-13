// Port of photocraft-compose (crates/compose/src/tests.rs: bands, reductions, tiling; multichannel.rs; Transparency Shapes Layer bands) plus planner-specific end-to-end cases, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
import PCDocument
import PCFoundation
import simd
@testable import PCRender

@Suite("Document pipeline: bands, reductions, leaves, planner")
struct DocumentPipelineTests {
    /// `tall_doc`: soft content, a translucent region and an Invert adjustment.
    static func tallDoc(_ w: Int, _ h: Int) -> Document {
        var d = DT.docWhite(w, h)
        var l = Layer.raster("grad", format: DT.rgba8)
        l.withRaster { s in
            for y in 0..<Int32(h) { s.fill(DT.rect(0, y, Int32(w / 2), y + 1), with: [Float(y) / Float(h), 0.3, 1 - Float(y) / Float(h), 1]) }
            s.fill(DT.rect(Int32(w / 2), 0, Int32(w), Int32(h / 3)), with: [0.9, 0.1, 0.1, 0.4])
        }
        d.layers += [l, DT.adjustment(.invert)]
        return d
    }

    @Test func renderTiledMatchesOneTileWithManyBands() throws {
        let d = Self.tallDoc(37, 900)
        let p = DT.cpu.plan(d, region: d.bounds)
        let whole = try CPUCompositor(tileSize: 10_000).render(p.plan, region: d.bounds, source: p.source)
        for tile in [16, 64, 300] { #expect(try CPUCompositor(tileSize: tile).render(p.plan, region: d.bounds, source: p.source).px == whole.px, "tile \(tile)") }
        #expect(DT.render(d).px == whole.px)
        let r = DT.rect(3, 17, 30, 811)
        #expect(DT.render(d, r).px == whole.cropped(to: r).px)
    }

    @Test func renderBandsCoverTheRectInOrder() throws {
        let d = Self.tallDoc(20, 700)
        let r = DT.rect(2, 10, 18, 690)
        var rows: [(Int32, Int32)] = []
        var px: [SIMD4<Float>] = []
        try DT.cpu.renderBands(d, rect: r, bandRows: 100) { b in
            #expect(b.rect.x0 == r.x0 && b.rect.x1 == r.x1)
            rows.append((b.rect.y0, b.rect.y1))
            px += b.px
        }
        #expect(rows.map { [$0.0, $0.1] } == [[10, 266], [266, 522], [522, 690]], "100 rows round up to one 256-row tile band")
        #expect(px == DT.render(d, r).px)
        struct Stop: Error {}
        var n = 0
        #expect(throws: Stop.self) { try DT.cpu.renderBands(d, rect: r, bandRows: 1) { _ in n += 1; throw Stop() } }
        #expect(n == 1)
        #expect(DocumentCompositor.bandRows(width: 14_000, requested: 0) % 256 == 0)
        #expect(DocumentCompositor.bandRows(width: 1, requested: 0) > 0 && DocumentCompositor.bandRows(width: 0, requested: -5) > 0)
    }

    /// The previous thumbnail: flatten, then area-average (premultiplied).
    static func referenceReduce(_ d: Document, _ w: Int, _ h: Int) throws -> [SIMD4<Float>] {
        let full = try DT.cpu.flatten(d)
        let (fw, fh) = (full.rect.width, full.rect.height)
        var out: [SIMD4<Float>] = []
        for ty in 0..<h {
            let (y0, y1) = (ty * fh / h, min(max((ty + 1) * fh / h, ty * fh / h + 1), fh))
            for tx in 0..<w {
                let (x0, x1) = (tx * fw / w, min(max((tx + 1) * fw / w, tx * fw / w + 1), fw))
                var acc = SIMD4<Float>.zero
                for y in y0..<y1 { for x in x0..<x1 {
                    let p = full.px[y * fw + x]
                    acc += SIMD4(p.x * p.w, p.y * p.w, p.z * p.w, p.w)
                } }
                let n = Float(max((y1 - y0) * (x1 - x0), 1))
                out.append(acc.w > 0 ? SIMD4(acc.x / acc.w, acc.y / acc.w, acc.z / acc.w, acc.w / n) : .zero)
            }
        }
        return out
    }

    @Test func reducedRenderMatchesTheFullCompositeAveraged() throws {
        let d = Self.tallDoc(53, 1000)
        for (w, h, band) in [(10, 190, Int32(0)), (7, 33, 256), (53, 999, 512), (1, 1, 256)] {
            let got = try DT.cpu.renderReduced(d, width: w, height: h, bandRows: band)
            #expect(got.rect == PixelRect(x: 0, y: 0, width: w, height: h))
            let want = try Self.referenceReduce(d, w, h)
            let worst = zip(got.px, want).map { simd_reduce_max(simd_abs($0 - $1)) }.max() ?? 0
            #expect(worst < 1e-5, "\(w)x\(h) band \(band): \(worst)")
        }
        #expect(try DT.cpu.renderReduced(d, width: 53, height: 1000).px == DT.cpu.flatten(d).px)
        let empty = Document(name: "e", size: PixelSize(width: 0, height: 0), mode: .rgb, depth: .u8)
        #expect(try DT.cpu.renderReduced(empty, width: 4, height: 4).px == [.zero])
    }

    @Test func reducedDamageMatchesTheWholeReduction() throws {
        let d = Self.tallDoc(53, 1000)
        for (w, h, band) in [(10, 190, Int32(0)), (7, 33, 256), (53, 999, 64), (53, 1000, 0), (1, 1, 256)] {
            let all = try DT.cpu.renderReduced(d, width: w, height: h, bandRows: band)
            for dmg in [DT.rect(0, 0, 1, 1), DT.rect(5, 17, 6, 18), DT.rect(12, 300, 40, 701), DT.rect(-9, 990, 80, 2000), DT.rect(0, 0, 53, 1000)] {
                let part = try DT.cpu.renderReduced(d, width: w, height: h, damage: dmg, bandRows: band)
                let r = part.rect
                #expect(!r.isEmpty && r.x0 >= 0 && r.y0 >= 0 && Int(r.x1) <= w && Int(r.y1) <= h, "\(w)x\(h) \(dmg) -> \(r)")
                for y in r.y0..<r.y1 { for x in r.x0..<r.x1 {
                    #expect(abs(simd_reduce_max(simd_abs(part.get(x, y) - all.get(x, y)))) < 1e-6, "\(w)x\(h) band \(band) \(dmg) at \(x),\(y)")
                } }
                func span(_ t: Int, _ f: Int, _ n: Int) -> (Int, Int) { (t * f / n, min(max((t + 1) * f / n, t * f / n + 1), f)) }
                let dd = dmg.intersect(DT.rect(0, 0, 53, 1000))
                for y in 0..<h { for x in 0..<w {
                    let (x0, x1) = span(x, 53, w), (y0, y1) = span(y, 1000, h)
                    let meets = !PixelRect(x0: Int32(x0), y0: Int32(y0), x1: Int32(x1), y1: Int32(y1)).intersect(dd).isEmpty
                    #expect(r.contains(x: Int32(x), y: Int32(y)) == meets, "\(w)x\(h) \(dmg) at \(x),\(y)")
                } }
            }
            #expect(try DT.cpu.renderReduced(d, width: w, height: h, damage: DT.rect(60, 0, 70, 10), bandRows: band).rect.isEmpty)
        }
    }

    @Test func reducedRenderOfAnAreaPastTheCanvas() throws {
        func paint(_ d: inout Document, _ dx: Int32, _ dy: Int32) {
            var l = Layer.raster("big", format: DT.rgba8)
            l.withRaster { s in
                for y in Int32(-10)..<40 { for x in Int32(-20)..<60 {
                    let a: Float = x < 0 || y >= 30 ? 0.6 : 1
                    s.fill(DT.rect(x + dx, y + dy, x + dx + 1, y + dy + 1), with: [Float(x + 20) / 80, Float(y + 10) / 50, 0.5, a])
                } }
            }
            d.layers += [l, DT.adjustment(.invert)]
        }
        var d = Document(name: "d", size: PixelSize(width: 40, height: 30), mode: .rgb, depth: .u8)
        paint(&d, 0, 0)
        var whole = Document(name: "w", size: PixelSize(width: 80, height: 50), mode: .rgb, depth: .u8)
        paint(&whole, 20, 10)
        let area = DT.rect(-20, -10, 60, 40)
        for (w, h) in [(80, 50), (8, 5), (27, 13), (1, 1)] {
            let got = try DT.cpu.renderReduced(d, rect: area, width: w, height: h)
            #expect(got.rect == PixelRect(x: 0, y: 0, width: w, height: h))
            let want = try DT.cpu.renderReduced(whole, width: w, height: h)
            #expect(zip(got.px, want.px).allSatisfy { simd_reduce_max(simd_abs($0 - $1)) < 1e-6 }, "\(w)x\(h)")
        }
        #expect(try DT.cpu.renderReduced(d, rect: DT.rect(100, 100, 120, 110), width: 20, height: 10).px.allSatisfy { $0.w == 0 })
        // The GPU renders past the canvas too.
        _ = DT.render(d, area)
    }

    // MARK: Transparency Shapes Layer off, in bands and parts (#1909)

    static func shapelessFxDoc(_ depth: SampleType) -> Document {
        var d = DT.docWhite(48, 640, depth: depth)
        let fmt = d.pixelFormat
        func bevel(_ style: BevelStyle, _ soften: Float) -> Effect {
            .bevelEmboss(Bevel(style: style, technique: .smooth, depth: 1, up: true, size: 5, soften: soften, angle: 120, altitude: 30, useGlobalLight: false))
        }
        let satin = Effect.satin(Satin(common: FxCommon(.multiply, 1), color: .black, angle: 19, distance: 4, size: 5, contour: .linear, antiAlias: true, invert: false))
        var dropNoisy = DT.shadow(5, 120, spread: 0.3, size: 6); dropNoisy.noise = 0.2
        var glowNoisy = DT.glow(.softer, .edge, size: 6); glowNoisy.spread = 0.2; glowNoisy.noise = 0.1
        let stacks: [[Effect]] = [
            [DT.stroke(3, .outside)],
            [DT.stroke(2, .inside), .dropShadow(dropNoisy)],
            [DT.stroke(4, .center)],
            [.innerShadow(DT.shadow(3, 30, spread: 0, size: 4))],
            [.outerGlow(glowNoisy)],
            [.innerGlow(DT.glow(.softer, .center)), satin],
            [bevel(.emboss, 2)],
            [bevel(.pillowEmboss, 0), bevel(.outerBevel, 1)],
            [DT.stroke(3, .outside), .innerGlow(DT.glow(.softer, .edge))],
        ]
        let maskFmt = PixelFormat(mode: .grayscale, sample: depth, alpha: false)
        for (i, fx) in stacks.enumerated() {
            let y = Int32(24 + i * 66)
            let c = SIMD4<Float>(0.2 + 0.08 * Float(i), 0.5, 1 - 0.1 * Float(i), 1)
            var l = DT.solidLayer("fx\(i)", DT.rect(10, y, 38, y + 18), c, format: fmt)
            l.effects.items = fx
            l.advanced.transparencyShapes = false
            l.opacity = 0.8
            if i < 8 {
                var m = Surface(format: maskFmt)
                m.fill(DT.rect(4 + Int32(i), y - 12, 44, y + 30), with: [1])
                m.fill(DT.rect(4 + Int32(i), y + 30, 30, y + 34), with: [0.5])
                l.mask = LayerMask(surface: m)
            }
            d.layers.append(l)
        }
        var inner = DT.solidLayer("inner", DT.rect(12, 300, 30, 310), DT.rgba(0.1, 0.9, 0.3), format: fmt)
        inner.effects.items = [DT.stroke(3, .outside)]
        inner.advanced.transparencyShapes = false
        var m = Surface(format: maskFmt)
        m.fill(DT.rect(8, 240, 36, 380), with: [1])
        inner.mask = LayerMask(surface: m)
        var g = Layer.group("g", [inner])
        g.effects.items = [.dropShadow(DT.shadow(90, 70, spread: 0.1, size: 40)), DT.stroke(120, .outside)]
        g.opacity = 0.6
        d.layers.append(g)
        var base = DT.solidLayer("base", DT.rect(6, 420, 42, 470), DT.rgba(0.9, 0.9, 0.2), format: fmt)
        base.effects.items = [.outerGlow(DT.glow(.softer, .edge, size: 150))]
        var clip = DT.solidLayer("clip", DT.rect(14, 430, 34, 450), DT.rgba(0.6, 0.1, 0.6), format: fmt)
        clip.effects.items = [DT.stroke(2, .center), .innerShadow(DT.shadow(2, 45, spread: 0, size: 3))]
        clip.advanced.transparencyShapes = false
        clip.clipped = true
        d.layers += [base, clip]
        return d
    }

    @Test func shapelessEffectsRenderTheSameInBandsAndParts() throws {
        for depth in [SampleType.u8, .u16, .f32] {
            let d = Self.shapelessFxDoc(depth)
            DT.cpu.cpu.purge()
            var banded: [SIMD4<Float>] = []
            try DT.cpu.renderBands(d, rect: d.bounds, bandRows: 64) { banded += $0.px }
            DT.cpu.cpu.purge()
            let parts = [DT.rect(3, 290, 41, 333), DT.rect(0, 0, 48, 20), DT.rect(20, 600, 48, 640), DT.rect(0, 296, 20, 312), DT.rect(10, 425, 40, 445)]
                .map { (r: PixelRect) in (r, DT.render(d, r)) }
            let whole = DT.render(d)
            #expect(banded == whole.px, "\(depth): band render differs")
            for (r, p) in parts { #expect(p.px == whole.cropped(to: r).px, "\(depth): part \(r) differs") }
            let pl = DT.cpu.plan(d, region: d.bounds)
            #expect(try CPUCompositor(tileSize: 16).render(pl.plan, region: d.bounds, source: pl.source).px == whole.px, "\(depth): tiled render differs")
        }
    }

    // MARK: Leaves, rasterizer, planner

    @Test func uncachedLayersGoThroughTheRasterizer() throws {
        var d = DT.docWhite(40, 20)
        var t = TextLayer(text: "abc", sizePt: 8, color: .rgb(1, 0, 0))
        t.transform = PCAffine(a: 1, b: 0, c: 0, d: 1, e: 4, f: 6)
        d.layers.append(Layer(name: "type", content: .text(t)))
        // The test rasterizer renders a box: 3 glyphs × 6 px wide, 8 px tall at (4, 6).
        let r = DT.render(d)
        #expect(DT.close4(r.get(5, 7), DT.rgba(1, 0, 0)) && DT.close4(r.get(30, 7), DT.white))
        // The placeholder renders nothing and records the miss; vector masks fall back to
        // PCRender's own path coverage (no miss).
        let placeholder = PlaceholderRasterizer()
        let c = DocumentCompositor(rasterizer: placeholder, backend: .cpu, metal: nil)
        d.layers[0].vectorMask = VectorMask(path: DT.polygon([(0, 0), (40, 0), (40, 20)]))
        let p = c.plan(d, region: d.bounds)
        let out = try c.run(p)
        #expect(DT.close4(out.get(20, 3), DT.white), "the type layer draws as empty; inside the vector mask")
        #expect(DT.close4(out.get(5, 15), DT.clear), "outside the vector mask")
        #expect(Set(p.misses.map(\.kind)) == [.layerPixels], "\(p.misses)")
        #expect(placeholder.misses.count >= 1 && placeholder.requestCount >= 1)
    }

    @Test func layerCompsApplyVisibilityAndAppearance() throws {
        var d = DT.docWhite(4, 4)
        var a = DT.solidLayer("a", DT.rect(0, 0, 4, 4), DT.rgba(1, 0, 0))
        a.visible = false
        var b = DT.solidLayer("b", DT.rect(0, 0, 4, 4), DT.rgba(0, 0, 1))
        b.opacity = 0.5
        d.layers += [a, b]
        let comp = LayerComp(id: 1, name: "c", states: [CompLayerState(layer: a.id, visible: true),
                                                       CompLayerState(layer: b.id, visible: true, appearance: CompAppearance(blend: .normal, opacity: 1, fillOpacity: 1, effects: Effects(enabled: true)))])
        var opts = PlanOptions()
        opts.comp = comp
        let c = DocumentCompositor(rasterizer: DT.rasterizer, backend: .cpu, metal: nil, options: opts)
        #expect(DT.close4(try c.flatten(d).get(1, 1), DT.rgba(0, 0, 1)), "b at full opacity over a now visible")
        #expect(DT.close4(DT.px(d, 1, 1), DT.rgba(0.5, 0.5, 1)), "without the comp: b at 50 % over white")
    }

    @Test func artboardsClipTheirContentAndPaintTheirBackground() {
        var d = Document(name: "a", size: PixelSize(width: 20, height: 10), mode: .rgb, depth: .u8)
        var g = Layer.group("board", [DT.solidLayer("x", DT.rect(0, 0, 20, 10), SIMD4(1, 0, 0, 0.5))])
        g.artboard = Artboard(rect: DT.rect(2, 2, 10, 8), background: .white)
        g.blend = .normal
        d.layers.append(g)
        let r = DT.render(d)
        #expect(DT.close4(r.get(5, 5), DT.rgba(1, 0.5, 0.5)), "red at 50 % over the board's white: \(r.get(5, 5))")
        #expect(DT.close4(r.get(15, 5), DT.clear), "outside the board: nothing")
    }

    @Test func multichannelInksPrintOverPaper() {
        var d = Document(name: "m", size: PixelSize(width: 4, height: 1), mode: .multichannel, depth: .u8)
        let fmt = PixelFormat(mode: .grayscale, sample: .u8, alpha: false)
        var a = Surface(format: fmt); a.writeRegion(DT.rect(0, 0, 4, 1), [0, 1, 1, 0])
        var b = Surface(format: fmt); b.writeRegion(DT.rect(0, 0, 4, 1), [0, 0, 1, 1])
        var ca = AlphaChannel(name: "Cyan", surface: a); ca.spot = SpotInk(color: .rgb(0, 1, 1), solidity: 0)
        var cb = AlphaChannel(name: "Magenta", surface: b); cb.spot = SpotInk(color: .rgb(1, 0, 1), solidity: 0)
        d.channels = [ca, cb]
        let r = DT.render(d)
        #expect(r.px == [SIMD4(1, 1, 1, 1), SIMD4(0, 1, 1, 1), SIMD4(0, 0, 1, 1), SIMD4(1, 0, 1, 1)])
    }

    @Test func cmykFillLayersRenderInInkValues() {
        var d = Document(name: "c", size: PixelSize(width: 64, height: 4), mode: .cmyk, depth: .u8)
        let stops = [ColorStop(0, PCColor(mode: .cmyk, c: SIMD4(1, 0, 0, 0))), ColorStop(1, PCColor(mode: .cmyk, c: SIMD4(0, 0, 0, 1)))]
        d.layers.append(Layer(name: "g", content: .fill(.gradient(GradientFill(stops: stops, angle: 0, scale: 1, style: .linear, reverse: false)))))
        let r = DT.render(d)
        // Halfway the inks are (0.5, 0, 0, 0.5) read through the CMYK conversion, not the mix of the
        // two RGB end colours.
        let mid = r.get(32, 1)
        let want = ColorConvert.cmykToRGB(SIMD4(Float(128) / 255, 0, 0, Float(128) / 255))
        #expect(abs(mid.x - want.x) < 0.03 && abs(mid.y - want.y) < 0.03 && abs(mid.z - want.z) < 0.03, "\(mid) vs \(want)")
    }

    @Test func occludedLayersArePrunedAtTheRoot() throws {
        var d = DT.docWhite(16, 16)
        d.layers.append(DT.solidLayer("hidden by the fill", DT.rect(0, 0, 16, 16), DT.rgba(1, 0, 0)))
        d.layers.append(Layer(name: "opaque fill", content: .fill(.solid(.rgb(0, 0, 1)))))
        var top = DT.solidLayer("top", DT.rect(4, 4, 8, 8), DT.rgba(0, 1, 0))
        top.blend = .multiply
        d.layers.append(top)
        let p = DocumentPlanner.plan(document: d, region: d.bounds)
        #expect(p.filter { if case .drawTiles = $0 { return true } else { return false } }.count == 1, "only the top layer's pixels are drawn: \(p)")
        var opts = PlanOptions(); opts.pruneOccluded = false
        let c = DocumentCompositor(rasterizer: DT.rasterizer, backend: .cpu, metal: nil, options: opts)
        #expect(try c.flatten(d).px == DT.render(d).px)
    }

    @Test func layersClippedToAPassThroughGroup() {
        var d = DT.docWhite(8, 8)
        d.layers[0].withRaster { $0.fill(DT.rect(0, 0, 8, 8), with: [0.5, 0.5, 0.5, 1]) }
        var inner = DT.solidLayer("in", DT.rect(0, 0, 4, 8), DT.rgba(0.2, 0.4, 0.9))
        inner.blend = .normal
        var g = Layer.group("pt", [inner, DT.adjustment(.invert)])
        g.opacity = 0.8
        var clip = DT.solidLayer("clip", DT.rect(0, 0, 8, 8), DT.rgba(1, 0, 0))
        clip.clipped = true
        d.layers += [g, clip]
        let r = DT.render(d)
        // Inside the group's pixels the red clipped layer shows; elsewhere the invert still applies.
        #expect(r.get(1, 1).x > 0.8 && r.get(1, 1).y < 0.3, "\(r.get(1, 1))")
        #expect(abs(r.get(6, 1).x - 0.5) < 0.02, "\(r.get(6, 1))")
    }

    @Test func patternFillLayersPaintInTheDocumentMode() {
        var tile = Surface(format: DT.rgba8)
        tile.fill(DT.rect(0, 0, 1, 1), with: [1, 0, 0, 1])
        tile.fill(DT.rect(1, 0, 2, 1), with: [0, 0, 1, 1])
        let pat = Pattern(name: "rb", surface: tile, width: 2, height: 1)
        var d = Document.withBackground(name: "g", size: PixelSize(width: 8, height: 2), mode: .grayscale, depth: .u8, fill: .white)
        d.patterns = [pat]
        d.layers.append(Layer(name: "p", content: .fill(.pattern(PatternFill(name: "rb", id: pat.id)))))
        let r = DT.render(d)
        let p = r.get(0, 0), q = r.get(1, 0)
        #expect(abs(p.x - p.z) < 1e-5 && abs(q.x - q.z) < 1e-5 && abs(p.x - q.x) > 0.05, "grey paint: \(p) \(q)")
    }

    @Test func fillCachesAreUsedWhileTheyMatch() {
        var d = DT.docWhite(8, 8)
        let f = Fill.solid(.rgb(0, 0, 1))
        var cache = Surface(format: DT.rgba8)
        cache.fill(DT.rect(0, 0, 4, 8), with: [0, 1, 0, 1])
        var l = Layer(name: "fill", content: .fill(f))
        l.fillCache = FillCache(fill: f, surface: cache)
        d.layers.append(l)
        var r = DT.render(d)
        #expect(DT.close4(r.get(1, 1), DT.rgba(0, 1, 0)) && DT.close4(r.get(6, 1), DT.white), "Photoshop's pixels")
        d.layers[1].content = .fill(.solid(.rgb(1, 0, 0)))
        r = DT.render(d)
        #expect(DT.close4(r.get(6, 1), DT.rgba(1, 0, 0)), "a changed fill renders itself")
    }

    @Test func everyPlanValidatesAndBalancesFloors() throws {
        for d in [Self.shapelessFxDoc(.u8), BenchmarkDocuments.realistic20(size: 256), BenchmarkDocuments.effects4(size: 256)] {
            for region in [d.bounds, DT.rect(10, 10, 60, 200), DT.rect(-30, -30, 5, 5)] {
                try DocumentPlanner.build(document: d, region: region, rasterizer: DT.rasterizer).plan.validate()
            }
        }
    }

    // MARK: Benchmark scenes at test size (every feature, CPU vs Metal)

    @Test func benchmarkScenesMatchOnCPUAndGPU() {
        for d in [BenchmarkDocuments.effects4(size: 384), BenchmarkDocuments.realistic20(size: 384)] {
            #expect(BenchmarkDocuments.layerCount(d) >= 4)
            // Five adjustment layers round to whole levels in turn: an ulp-level difference before
            // one of them can flip a level (measured ≤ 1.0 level).
            _ = DT.render(d, tol: 1.5 / 255, name: d.name)
            _ = DT.render(d, DT.rect(100, 37, 300, 301), tol: 1.5 / 255, name: d.name + " part")
        }
        #expect(BenchmarkDocuments.layerCount(BenchmarkDocuments.realistic20(size: 64)) == 20)
    }

    // MARK: PSD composite oracle hook

    /// Runs when a loader is installed (`PSDOracleHook`) and `PCRENDER_PSD_CORPUS` names a
    /// directory of .psd / .psb files: each file's composite, CPU and Metal, against Photoshop's
    /// merged image. Reports per file; fails only past the thresholds below.
    @Test(.enabled(if: PSDOracleHook.active != nil && CompositeOracle.corpusDirectory != nil))
    func psdCompositeOracle() throws {
        let dir = try #require(CompositeOracle.corpusDirectory)
        let loader = try #require(PSDOracleHook.active)
        let maxMeanLevels = Float(ProcessInfo.processInfo.environment["PCRENDER_ORACLE_MEAN"] ?? "") ?? 1.0
        let maxFractionOff = Double(ProcessInfo.processInfo.environment["PCRENDER_ORACLE_OFF"] ?? "") ?? 0.02
        for url in CompositeOracle.corpusFiles(dir) {
            guard let c = try loader(url) else { continue }
            for backend in [DocumentCompositor.Backend.cpu, .metal] where backend == .cpu || DT.gpu != nil {
                let comp = backend == .cpu ? DT.cpu : DT.gpu!
                let r = try CompositeOracle.compare(c, compositor: comp, backend: backend)
                print("oracle: \(r)")
                #expect(r.meanLevels <= maxMeanLevels && r.fractionOff <= maxFractionOff, "\(r)")
            }
        }
    }

    @Test func oracleComparisonOfAnExactReference() throws {
        let d = Self.tallDoc(20, 30)
        let reference = try DT.cpu.flatten(d)
        let r = try CompositeOracle.compare(OracleCase(name: "self", document: d, reference: reference), compositor: DT.cpu)
        #expect(r.maxLevels == 0 && r.pixelsOff == 0 && r.pixels == 600)
    }
}
