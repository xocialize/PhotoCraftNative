// Filter adjustment layers baked to pixels (AB-D-0143, `FilterBake`). New; no photocraft
// counterpart. Composited as pixel layers with the adjustment's own mask, opacity, blend mode and
// clipping, the baked pixels draw the live composite: exactly for every kind and place, except a
// Normal blur where it thins coverage (a pixel layer only adds coverage). The GPU bake against the
// CPU's, regions against the whole, and Lab and CMYK documents. In a PSD: PCIO's
// FilterAdjustmentPSDTests.

import Foundation
import Testing
import PCDocument
import PCFoundation
@testable import PCRender

@Suite struct FilterBakeTests {
    static let size = PixelSize(width: 72, height: 48)
    static let hole = PixelRect(x0: 0, y0: 0, x1: 16, y1: 12)
    static let card = PixelRect(x0: 20, y0: 14, x1: 52, y1: 38)

    /// An opaque, busy background with a clear hole (top left), and the card's layer: every
    /// coverage edge is hard, so a backdrop is opaque or clear.
    static func doc(_ depth: SampleType = .u16, mode: ColorMode = .rgb) -> (Document, card: Layer) {
        var d = Document(name: "bake", size: size, mode: mode, depth: depth)
        let fmt = d.pixelFormat
        var rng = Rng(7)
        var data: [Float] = []
        for y in d.bounds.y0..<d.bounds.y1 {
            for x in d.bounds.x0..<d.bounds.x1 {
                let stripe: Float = (x / 5 + y / 3) % 2 == 0 ? 0.8 : 0.2
                data += fmt.components(fromRGBA: hole.contains(x: x, y: y) ? .zero : SIMD4(stripe, rng.float(), 1 - stripe * rng.float(), 1))
            }
        }
        var bg = Surface(format: fmt)
        bg.writeRegion(d.bounds, data)
        d.layers.append(Layer.raster("bg", surface: bg))
        var c = Surface(format: fmt)
        c.writeRegion(card, (0..<card.area).flatMap { i in fmt.components(fromRGBA: SIMD4(Float(i % 7) / 7, 0.9 - Float(i % 11) / 20, 0.3, 1)) })
        return (d, Layer.raster("card", surface: c))
    }

    static func filter(_ f: FilterAdjustment, _ blend: BlendMode = .normal) -> Layer {
        var l = FilterFixtures.layer(f)
        l.blend = blend
        return l
    }

    /// `d` with every filter layer baked by `c`, bottom to top over the ones beneath (as PSD export
    /// does).
    static func baked(_ d: Document, _ c: DocumentCompositor = DT.cpu) throws -> Document {
        var w = d
        var ids: [LayerId] = []
        d.forEachLayer { _, _, l in if case .adjustment(let a) = l.content, a.asFilter != nil { ids.append(l.id) } }
        for id in ids {
            let s = try #require(try c.bakeFilterLayer(w, layer: id))
            w.updateLayer(id) { $0.content = .raster(s) }
        }
        return w
    }

    /// The places of `f`: masked at an opacity, in blend modes, inside an isolated group and a
    /// pass-through one (with an opacity and a mask), clipped, and stacked between two blurs.
    static func places(_ f: FilterAdjustment) -> [(String, Document)] {
        var out: [(String, Document)] = []
        let (base, card) = doc()
        var d = base
        var l = filter(f)
        l.mask = FilterFixtures.mask(d)
        l.opacity = 0.7
        d.layers.append(l)
        out.append(("masked", d))
        for mode in [BlendMode.multiply, .screen, .difference, .luminosity, .overlay] {
            d = base
            d.layers.append(filter(f, mode))
            out.append(("\(mode)", d))
        }
        for mode in [BlendMode.normal, .screen] {
            d = base
            var g = Layer.group("isolated", [card, filter(f, mode)])
            g.blend = .normal
            g.opacity = 0.8
            d.layers.append(g)
            out.append(("isolated \(mode)", d))
        }
        d = base
        var pg = Layer.group("pass", [card, filter(f)])
        pg.opacity = 0.6
        pg.mask = FilterFixtures.mask(d)
        d.layers.append(pg)
        out.append(("pass-through", d))
        for mode in [BlendMode.normal, .multiply] {
            d = base
            d.layers.append(card)
            var c = filter(f, mode)
            c.clipped = true
            d.layers.append(c)
            out.append(("clipped \(mode)", d))
        }
        d = base
        d.layers.append(filter(.gaussianBlur(.init(radius: 1.5)), .screen))
        d.layers.append(filter(f))
        d.layers.append(filter(.motionBlur(.init(angle: 20, distance: 6)), .softLight))
        out.append(("stacked", d))
        return out
    }

    /// How far from a coverage edge (the canvas's, the hole's, the card's) a pixel layer may differ:
    /// the reach of the document's blurs when one of them, in Normal and unclipped, thins coverage.
    static func band(_ d: Document) -> Int32 {
        var thins = false, reach: Int32 = 0
        d.forEachLayer { _, _, l in
            guard case .adjustment(let a) = l.content, let f = a.asFilter, f.samplesNeighbours else { return }
            reach += FilterMath.reach(FilterSpec(f))
            if l.blend == .normal && !l.clipped { thins = true }
        }
        return thins ? reach + 1 : 0
    }

    static func nearEdge(_ x: Int32, _ y: Int32, _ r: Int32) -> Bool {
        if r == 0 { return false }
        func near(_ e: PixelRect) -> Bool { e.outset(by: r).contains(x: x, y: y) && !e.inset(by: r).contains(x: x, y: y) }
        return !PixelRect(size: size).inset(by: r).contains(x: x, y: y) || near(hole) || near(card)
    }

    /// The largest premultiplied difference away from the band (`inside`: within it).
    static func diff(_ a: RGBABuffer, _ b: RGBABuffer, band r: Int32, inside: Bool = false) -> Float {
        var m: Float = 0
        for (i, (p, q)) in zip(a.px, b.px).enumerated() {
            let x = a.rect.x0 + Int32(i % a.rect.width), y = a.rect.y0 + Int32(i / a.rect.width)
            if nearEdge(x, y, r) != inside { continue }
            for c in 0..<4 { m = max(m, abs((c < 3 ? p[c] * p.w : p[c]) - (c < 3 ? q[c] * q.w : q[c]))) }
        }
        return m
    }

    // MARK: The baked layers draw the live composite

    @Test(arguments: FilterFixtures.kinds.map(\.0))
    func bakedLayersDrawTheLiveComposite(_ name: String) throws {
        let f = try #require(FilterFixtures.kinds.first { $0.0 == name }?.1)
        for (place, d) in Self.places(f) {
            let live = try DT.cpu.render(d, region: d.bounds), layers = try DT.cpu.render(try Self.baked(d), region: d.bounds)
            let r = Self.band(d)
            // 16-bit stamps: a few 16-bit steps, through the steepest blend.
            let m = Self.diff(live, layers, band: r)
            #expect(m <= 2e-4, "\(name) \(place): \(m * 255) levels")
            if r > 0 && place != "stacked" {
                #expect(Self.diff(live, layers, band: r, inside: true) > 2.0 / 255, "\(name) \(place): no thinning to show")
            }
        }
    }

    /// Clipped, the bake has full coverage wherever its base has any, and none elsewhere.
    @Test func clippedBakesCoverTheBase() throws {
        var (d, card) = Self.doc()
        d.layers.append(card)
        var c = Self.filter(.gaussianBlur(.init(radius: 3)))
        c.clipped = true
        d.layers.append(c)
        let s = try #require(try DT.cpu.bakeFilterLayer(d, layer: c.id))
        #expect(ContentBounds.of(s) == Self.card)
        #expect(s.readRGBA(Self.card).allSatisfy { $0.w == 1 })
    }

    /// Only the canvas within the layer's masks is rendered; a hidden layer is baked as if shown.
    @Test func boundsFollowTheMasks() throws {
        var (d, _) = Self.doc()
        var l = Self.filter(.addNoise(.init(amount: 40, seed: 3)))
        let window = PixelRect(x0: 30, y0: 10, x1: 60, y1: 30)
        var m = Surface(format: PixelFormat(mode: .grayscale, sample: .u8, alpha: false))
        m.writeRegion(window, [Float](repeating: 1, count: window.area))
        l.mask = LayerMask(surface: m, feather: 2)
        l.visible = false
        d.layers.append(l)
        #expect(FilterBake.bounds(l, canvas: d.bounds) == window.outset(by: FilterBake.featherReach(2)))
        let s = try #require(try DT.cpu.bakeFilterLayer(d, layer: l.id))
        #expect(ContentBounds.of(s) == window.outset(by: FilterBake.featherReach(2)))
        l.mask?.enabled = false
        #expect(FilterBake.bounds(l, canvas: d.bounds) == d.bounds)
        #expect(try DT.cpu.bakeFilterLayer(d, layer: d.layers[0].id) == nil, "not a filter layer")
    }

    // MARK: GPU, regions, other modes

    @Test(arguments: FilterFixtures.kinds.map(\.0))
    func gpuBakesMatchCPU(_ name: String) throws {
        guard let gpu = DT.gpu else { return }
        let f = try #require(FilterFixtures.kinds.first { $0.0 == name }?.1)
        for (place, d) in Self.places(f) {
            var ids: [LayerId] = []
            d.forEachLayer { _, _, l in if case .adjustment(let a) = l.content, a.asFilter != nil { ids.append(l.id) } }
            for id in ids {
                let a = try #require(try DT.cpu.bakeFilterLayer(d, layer: id)), b = try #require(try gpu.bakeFilterLayer(d, layer: id))
                let (x, y) = (a.readRegion(d.bounds), b.readRegion(d.bounds))
                let m = zip(x, y).map { abs($0 - $1) }.max() ?? 0
                #expect(m <= FilterFixtures.tolerance(f) + 2e-5, "\(name) \(place): \(m * 255) levels")
            }
        }
    }

    /// Any region of a bake is the same pixels as the whole (the patterns are fixed in the
    /// document; a blur reads its backdrop past the region).
    @Test(arguments: FilterFixtures.kinds.map(\.0))
    func regionsMatchTheWhole(_ name: String) throws {
        let f = try #require(FilterFixtures.kinds.first { $0.0 == name }?.1)
        let (_, d) = try #require(Self.places(f).first { $0.0 == "stacked" })
        let id = d.layers[2].id
        func bake(_ r: PixelRect) throws -> RGBABuffer {
            let c = DT.cpu
            let (p, _) = try #require(DocumentPlanner.buildFilterBake(document: d, layer: id, region: r, rasterizer: c.rasterizer, cache: c.cache,
                                                                      subRenderer: c.cpu, options: c.options))
            return try c.display(try c.runNative(p, backend: .cpu), p)
        }
        let whole = try bake(d.bounds)
        for r in [PixelRect(x0: 0, y0: 0, x1: 72, y1: 17), PixelRect(x0: 0, y0: 17, x1: 72, y1: 48), PixelRect(x0: 23, y0: 5, x1: 41, y1: 33)] {
            #expect(try bake(r).px == whole.cropped(to: r).px, "\(name) \(r)")
        }
    }

    /// Lab, CMYK and Gray documents bake in the space their live composite is made in, written in
    /// their own model, and compared there:
    /// - Lab composites in Lab, the bake too: ≤ 0.015 levels.
    /// - A CMYK document with a filter layer composites in display RGB (filters don't run per ink
    ///   plane), and the bake is made there: ≤ 0.03 levels so composited. Without its filter layers
    ///   the baked document composites in CMYK, as Photoshop does: 30–95 levels on this fixture.
    /// - Gray composites in display RGB: colour Add Noise (not monochromatic) leaves colour a gray
    ///   layer can't hold, 7.9 levels; the rest ≤ 0.006.
    @Test(arguments: [ColorMode.lab, .cmyk, .grayscale])
    func otherModes(_ mode: ColorMode) throws {
        let rgb = DocumentCompositor(rasterizer: DT.rasterizer, backend: .cpu, metal: nil)
        rgb.options.nativeCompositing = false
        for (name, f) in FilterFixtures.kinds where ["grain", "noise-uniform", "gaussian", "motion-37"].contains(name) {
            var (d, card) = Self.doc(.u16, mode: mode)
            d.layers.append(card)
            var l = Self.filter(f, mode == .lab ? .multiply : .screen)
            l.clipped = true
            d.layers.append(l)
            d.layers.append(Self.filter(f, .multiply))
            let b = try Self.baked(d)
            let c = mode == .cmyk ? rgb : DT.cpu
            let live = try c.render(d, region: d.bounds), layers = try c.render(b, region: d.bounds)
            var m: Float = 0
            let fmt = d.pixelFormat
            for (p, q) in zip(live.px, layers.px) where p.w > 0 || q.w > 0 {
                for (u, v) in zip(fmt.components(fromRGBA: p), fmt.components(fromRGBA: q)) { m = max(m, abs(u - v)) }
            }
            let colourNoise = mode == .grayscale && name == "noise-uniform"
            #expect(m * 255 <= (colourNoise ? 8 : 0.05), "\(mode) \(name): \(m * 255) levels")
        }
    }
}
