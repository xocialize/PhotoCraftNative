// Filter adjustment layers (AB-T-0258): Grain, Add Noise, Gaussian Blur and Motion Blur over the
// composite beneath. New; no photocraft counterpart. The GPU against the CPU reference (exact but
// for Gaussian Add Noise's log and cos), any region or band against the same pixels of the whole
// canvas, the blurs' reach past the region, their coverage at the canvas edge and into clear pixels,
// their plans, and their lengths at a plan scale (levels of detail). Against Compositor's own
// renders: PCIO's CompCorpusTests.

import Foundation
import Testing
import PCDocument
import PCFoundation
@testable import PCRender

enum FilterFixtures {
    static let kinds: [(String, FilterAdjustment)] = [
        ("grain", .grain(.init(amount: 60, size: 2.5, roughness: 70, seed: 0x1234_5678))),
        ("grain-fine", .grain(.init(amount: 100, size: 0.5, roughness: 0, seed: 9))),
        ("noise-uniform", .addNoise(.init(amount: 40, gaussian: false, monochromatic: false, seed: 77))),
        ("noise-gaussian-mono", .addNoise(.init(amount: 120, gaussian: true, monochromatic: true, seed: 0xdead_beef))),
        ("noise-gaussian", .addNoise(.init(amount: 25, gaussian: true, monochromatic: false, seed: 5))),
        ("gaussian", .gaussianBlur(.init(radius: 3.5))),
        ("gaussian-thin", .gaussianBlur(.init(radius: 0.4))),
        ("motion-0", .motionBlur(.init(angle: 0, distance: 18))),
        ("motion-90", .motionBlur(.init(angle: 90, distance: 9))),
        ("motion-37", .motionBlur(.init(angle: 37, distance: 22))),
        ("motion--60", .motionBlur(.init(angle: -60, distance: 5))),
    ]

    /// A noisy opaque background, a translucent blob over part of it, a clear corner (top left).
    static func doc(_ depth: SampleType = .u8, mode: ColorMode = .rgb, w: Int = 300, h: Int = 180) -> Document {
        var d = Document(name: "filters", size: PixelSize(width: w, height: h), mode: mode, depth: depth)
        let fmt = d.pixelFormat
        var rng = Rng(42)
        let b = d.bounds
        let clear = PixelRect(x0: 0, y0: 0, x1: 40, y1: 30)
        var data: [Float] = []
        for y in b.y0..<b.y1 {
            for x in b.x0..<b.x1 {
                let stripe: Float = (x / 13 + y / 7) % 2 == 0 ? 0.85 : 0.15
                let (g, bl) = (rng.float(), rng.float())
                data += fmt.components(fromRGBA: clear.contains(x: x, y: y) ? .zero : SIMD4(stripe, g, 1 - stripe * bl, 1))
            }
        }
        var bg = Surface(format: fmt)
        bg.writeRegion(b, data)
        d.layers.append(Layer.raster("bg", surface: bg))
        let br = PixelRect(x0: 60, y0: 20, x1: 200, y1: 150)
        var blob = Surface(format: fmt)
        blob.writeRegion(br, TS.blob(br, seed: 3, cx: 130, cy: 85, r: 60, opaqueInside: false).readRGBA(br).flatMap { fmt.components(fromRGBA: $0) })
        var l = Layer.raster("blob", surface: blob)
        l.opacity = 0.8
        d.layers.append(l)
        return d
    }

    static func layer(_ f: FilterAdjustment, _ name: String = "filter") -> Layer { Layer(name: name, content: .adjustment(.filter(f))) }

    /// A mask hiding the left third, half-revealing the middle (8-bit).
    static func mask(_ d: Document) -> LayerMask {
        var s = Surface(format: PixelFormat(mode: .grayscale, sample: .u8, alpha: false))
        let b = d.bounds, w = Int32(b.width)
        var v: [Float] = []
        for _ in b.y0..<b.y1 { for x in b.x0..<b.x1 { v.append(x < w / 3 ? 0 : x < 2 * w / 3 ? 0.5 : 1) } }
        s.writeRegion(b, v)
        return LayerMask(surface: s, enabled: true, linked: true, density: 1, feather: 0)
    }

    /// Tight parity: everything but Gaussian Add Noise is the same arithmetic in the same order.
    /// Gaussian Add Noise takes libm's log and cos on the CPU and Metal's precise ones: an ulp apart,
    /// which the rounding to the document's levels after an adjustment layer turns into one level
    /// (8-bit) or one 16-bit step on the odd pixel that sits on a rounding edge.
    static func tolerance(_ f: FilterAdjustment) -> Float {
        if case .addNoise(let n) = f, n.gaussian { return 1.0 / 255 + 1e-6 }
        return 1e-6
    }

    /// A Lab document composites in Lab, and Grain and Add Noise go through display RGB and back:
    /// PCRender's CPU and GPU Lab conversions (cbrt and pow against Metal's pow) differ, by up to
    /// 3.8 levels for Hue/Saturation on this same document (measured when this was written), and
    /// 2.6 here. The blurs work on the Lab channels and keep the tight bound.
    static func labTolerance(_ f: FilterAdjustment) -> Float { f.samplesNeighbours ? tolerance(f) : 3.0 / 255 }
}

@Suite struct FilterAdjustmentTests {
    // MARK: GPU against the CPU reference

    @Test(arguments: FilterFixtures.kinds.map(\.0))
    func gpuMatchesCPU(_ name: String) throws {
        let f = try #require(FilterFixtures.kinds.first { $0.0 == name }?.1)
        for depth in [SampleType.u8, .u16, .f32] {
            var d = FilterFixtures.doc(depth)
            d.layers.append(FilterFixtures.layer(f))
            _ = DT.render(d, tol: FilterFixtures.tolerance(f), name: "\(name) \(depth)")
        }
    }

    /// Mask, opacity, blend modes, an isolated and a pass-through group, a clipped one, two blurs
    /// stacked, in a Lab document too.
    @Test(arguments: FilterFixtures.kinds.map(\.0))
    func gpuMatchesCPUInEveryPlace(_ name: String) throws {
        let f = try #require(FilterFixtures.kinds.first { $0.0 == name }?.1)
        let tol = FilterFixtures.tolerance(f)
        var masked = FilterFixtures.doc()
        var l = FilterFixtures.layer(f)
        l.mask = FilterFixtures.mask(masked)
        l.opacity = 0.7
        masked.layers.append(l)
        _ = DT.render(masked, tol: tol, name: "\(name) masked")
        for mode in [BlendMode.multiply, .screen, .luminosity, .difference] {
            var d = FilterFixtures.doc()
            var m = FilterFixtures.layer(f)
            m.blend = mode
            d.layers.append(m)
            _ = DT.render(d, tol: tol, name: "\(name) \(mode)")
        }
        // Inside an isolated group: the backdrop is the group's own layers.
        var isolated = FilterFixtures.doc()
        var g = Layer.group("g", [isolated.layers[1], FilterFixtures.layer(f)])
        g.blend = .normal
        isolated.layers[1] = g
        _ = DT.render(isolated, tol: tol, name: "\(name) isolated")
        // Inside a pass-through group with opacity and a mask: the whole backdrop, with the group's
        // buffers beneath it (the program then ends with removes).
        var pass = FilterFixtures.doc()
        var pg = Layer.group("pass", [pass.layers[1], FilterFixtures.layer(f)])
        pg.opacity = 0.6
        pg.mask = FilterFixtures.mask(pass)
        pass.layers[1] = pg
        _ = DT.render(pass, tol: tol, name: "\(name) pass-through")
        // Clipped to the blob: the blob's content filtered, its coverage kept.
        var clipped = FilterFixtures.doc()
        var c = FilterFixtures.layer(f)
        c.clipped = true
        clipped.layers.append(c)
        _ = DT.render(clipped, tol: tol, name: "\(name) clipped")
        // Two blurs over it, the lower one inside the upper one's backdrop program.
        var stacked = FilterFixtures.doc()
        stacked.layers.append(FilterFixtures.layer(.gaussianBlur(.init(radius: 2))))
        stacked.layers.append(FilterFixtures.layer(f))
        stacked.layers.append(FilterFixtures.layer(.motionBlur(.init(angle: 20, distance: 6))))
        _ = DT.render(stacked, tol: max(tol, 1e-6), name: "\(name) stacked")
        // A Lab document composites in Lab: Grain and Add Noise through display RGB, blurs on L, a, b.
        var lab = FilterFixtures.doc(.u8, mode: .lab)
        lab.layers.append(FilterFixtures.layer(f))
        _ = DT.render(lab, tol: FilterFixtures.labTolerance(f), name: "\(name) lab")
    }

    // MARK: Regions, tiles, cells and bands

    /// Any region, and a banded render, has exactly the pixels of the whole canvas's render: the
    /// patterns are fixed in the document, and a blur reads its backdrop past the region.
    @Test(arguments: FilterFixtures.kinds.map(\.0))
    func regionsMatchTheWholeCanvas(_ name: String) throws {
        let f = try #require(FilterFixtures.kinds.first { $0.0 == name }?.1)
        var d = FilterFixtures.doc()
        d.layers.append(FilterFixtures.layer(f))
        let whole = try DT.cpu.render(d, region: d.bounds)
        let gw = try DT.gpu?.render(d, region: d.bounds)
        for r in [PixelRect(x0: 37, y0: 50, x1: 201, y1: 150), PixelRect(x0: 0, y0: 0, x1: 70, y1: 40), PixelRect(x0: 255, y0: 120, x1: 300, y1: 180),
                  PixelRect(x0: -20, y0: 170, x1: 30, y1: 200)] {
            // Past the canvas a blur spreads into what the whole canvas's render doesn't hold.
            let inside = r.intersect(d.bounds)
            let part = try DT.cpu.render(d, region: r)
            #expect(part.cropped(to: inside) == whole.cropped(to: inside), "\(name) CPU \(r)")
            if let gpu = DT.gpu, let gw {
                let g = try gpu.render(d, region: r)
                #expect(DT.maxDiff(g.cropped(to: inside), gw.cropped(to: inside)).d <= 1e-6, "\(name) GPU \(r)")
            }
        }
    }

    /// A layer outside the region but within a blur's reach still reaches into it.
    @Test func blursReachPastTheRegion() throws {
        var d = Document(name: "reach", size: PixelSize(width: 200, height: 60), mode: .rgb, depth: .u8)
        d.layers.append(DT.solidLayer("white", d.bounds, DT.white))
        d.layers.append(DT.solidLayer("red", PixelRect(x0: 150, y0: 20, x1: 160, y1: 40), DT.rgba(1, 0, 0)))
        d.layers.append(FilterFixtures.layer(.gaussianBlur(.init(radius: 5))))
        let region = PixelRect(x0: 0, y0: 0, x1: 141, y1: 60)
        let part = DT.render(d, region)
        let edge = part.get(140, 30)
        #expect(edge.y < 1 - 1e-3, "red reaches x = 140: \(edge)")
        #expect(part == DT.render(d).cropped(to: region))
    }

    // MARK: Semantics

    /// Compositor's rule: past the canvas the backdrop is clear, so an opaque picture blurred thins
    /// at the canvas edge (and the interior stays opaque); blurs spread into clear pixels.
    @Test func blursThinAtTheCanvasEdgeAndSpreadIntoClearPixels() {
        var d = DT.docWhite(80, 60)
        d.layers.append(FilterFixtures.layer(.gaussianBlur(.init(radius: 3))))
        let out = DT.render(d)
        #expect(abs(out.get(0, 30).w - 0.5664) < 0.01, "edge \(out.get(0, 30))")
        #expect(out.get(40, 30).w > 0.9999)
        #expect(DT.close4(out.get(40, 30), DT.white, 1e-5))
        var clear = Document(name: "clear", size: PixelSize(width: 80, height: 60), mode: .rgb, depth: .u8)
        clear.layers.append(DT.solidLayer("sq", PixelRect(x0: 30, y0: 20, x1: 50, y1: 40), DT.rgba(0, 0, 1)))
        clear.layers.append(FilterFixtures.layer(.motionBlur(.init(angle: 0, distance: 30))))
        let spread = DT.render(clear)
        #expect(spread.get(25, 30).w > 0.1 && spread.get(30, 10).w == 0, "\(spread.get(25, 30)) \(spread.get(30, 10))")
        #expect(DT.close4(spread.get(25, 30), SIMD4(0, 0, 1, spread.get(25, 30).w), 1e-5))
    }

    /// Normal at opacity mixes premultiplied colour and coverage; another mode keeps the
    /// backdrop's coverage.
    @Test func blurCoverageMixes() {
        var d = Document(name: "mix", size: PixelSize(width: 60, height: 20), mode: .rgb, depth: .f32)
        d.layers.append(DT.solidLayer("sq", PixelRect(x0: 20, y0: 0, x1: 40, y1: 20), DT.rgba(1, 0.5, 0)))
        var blur = FilterFixtures.layer(.gaussianBlur(.init(radius: 4)))
        blur.opacity = 0.5
        d.layers.append(blur)
        let out = DT.render(d)
        // At x = 17 the square is clear and the blur has coverage a: half of it shows.
        var solo = d
        solo.layers[1].opacity = 1
        let full = DT.render(solo)
        #expect(abs(out.get(17, 10).w - full.get(17, 10).w / 2) < 1e-5)
        var multiply = d
        multiply.layers[1].blend = .multiply
        #expect(DT.render(multiply).get(17, 10).w == 0)
    }

    /// Grain and Add Noise draw the same pattern for the same seed, another for another; transparent
    /// pixels stay untouched.
    @Test func patternsFollowTheSeed() {
        func px(_ f: FilterAdjustment) -> RGBABuffer {
            var d = FilterFixtures.doc()
            d.layers.append(FilterFixtures.layer(f))
            return DT.render(d)
        }
        let a = px(.addNoise(.init(amount: 50, seed: 1))), b = px(.addNoise(.init(amount: 50, seed: 1))), c = px(.addNoise(.init(amount: 50, seed: 2)))
        #expect(a == b && a != c)
        #expect(a.get(5, 5) == SIMD4<Float>.zero)
        let g1 = px(.grain(.init(seed: 1))), g2 = px(.grain(.init(seed: 2)))
        #expect(g1 != g2)
    }

    /// The Gaussian of an impulse is the normalised kernel; Motion Blur at 0° is the 1-D kernel
    /// along the row.
    @Test func blurKernels() {
        let sigma: Float = 1.5
        let w = FilterMath.gaussianWeights(sigma: sigma)
        #expect(w.count == 2 * 5 + 1 && abs(w.reduce(0, +) - 1) < 1e-6)
        let area = PixelRect(x0: 0, y0: 0, x1: 21, y1: 21)
        var impulse = RGBABuffer(transparent: area)
        impulse.px[10 * 21 + 10] = SIMD4(1, 1, 1, 1)
        let g = FilterCPU.blur(FilterSpec(.gaussianBlur(.init(radius: sigma))), backdrop: impulse, canvas: area, over: area)
        #expect(abs(g.get(10, 10).w - w[5] * w[5]) < 1e-7 && abs(g.get(12, 9).w - w[7] * w[4]) < 1e-7)
        let m = FilterCPU.blur(FilterSpec(.motionBlur(.init(angle: 0, distance: 12))), backdrop: impulse, canvas: area, over: area)
        let mw = FilterMath.gaussianWeights(sigma: 12 / Float(12).squareRoot())
        let r = (mw.count - 1) / 2
        #expect(abs(m.get(10, 10).w - mw[r]) < 1e-7 && abs(m.get(8, 10).w - mw[r + 2]) < 1e-7 && m.get(10, 9).w == 0)
    }

    // MARK: Plans and scale

    /// A blur on the root stack replaces the ops below it with its program; inside a group it
    /// follows them, its program ending with the group's buffers removed.
    @Test func backdropPrograms() throws {
        var d = FilterFixtures.doc()
        d.layers.append(FilterFixtures.layer(.gaussianBlur(.init(radius: 2))))
        let p = DT.cpu.plan(d, region: d.bounds).plan
        try p.validate()
        guard case .backdropFilter(let b) = p.ops.first else { Issue.record("\(p.ops.first.map { "\($0)" } ?? "")"); return }
        #expect(b.pushesBackdrop)
        try RenderPlan(context: p.context, ops: b.program).validate()
        var g = FilterFixtures.doc()
        var group = Layer.group("pass", [g.layers[1], FilterFixtures.layer(.motionBlur(.init()))])
        group.opacity = 0.5
        g.layers[1] = group
        let q = DT.cpu.plan(g, region: g.bounds).plan
        try q.validate()
        let inner = q.ops.compactMap { op -> BackdropFilter? in if case .backdropFilter(let b) = op { b } else { nil } }
        #expect(inner.count == 1 && inner.first?.pushesBackdrop == false)
        if let b = inner.first {
            try RenderPlan(context: q.context, ops: b.program).validate()
            #expect(b.program.last == .remove(1))
        }
        // Grain and Add Noise are pointwise ops.
        var n = FilterFixtures.doc()
        n.layers.append(FilterFixtures.layer(.addNoise(.init())))
        #expect(DT.cpu.plan(n, region: n.bounds).plan.ops.contains { if case .filter = $0 { true } else { false } })
    }

    /// At a plan scale (a level of detail) lengths shrink: a blur of radius 8 at scale ½ is the
    /// blur of radius 4, and its reach halves.
    @Test func lengthsScaleWithThePlan() {
        let area = PixelRect(x0: 0, y0: 0, x1: 40, y1: 30)
        var rng = Rng(7)
        let src = RGBABuffer(rect: area, px: (0..<area.area).map { _ in SIMD4(rng.float(), rng.float(), rng.float(), rng.float(0.5, 1)) })
        for (big, small) in [(FilterAdjustment.gaussianBlur(.init(radius: 8)), FilterAdjustment.gaussianBlur(.init(radius: 4))),
                             (.motionBlur(.init(angle: 30, distance: 20)), .motionBlur(.init(angle: 30, distance: 10)))] {
            let half = FilterSpec(big, scale: 0.5)
            #expect(FilterMath.reach(half) == FilterMath.reach(FilterSpec(small)))
            #expect(FilterCPU.blur(half, backdrop: src, canvas: area, over: area) == FilterCPU.blur(FilterSpec(small), backdrop: src, canvas: area, over: area))
        }
        // Grain reads its field in document units: at scale ½, level pixel (x, y) is document pixel
        // (2x + ½, 2y + ½)'s centre … the field at the same document point.
        let g = FilterMath.Grain(.init(seed: 3), scale: 0.5)
        #expect(g.unitsPerPixel == 2)
        // Add Noise at a level: a pattern of its own, its spread scaled.
        let n = FilterMath.Noise(.init(amount: 40, seed: 3), scale: 0.25), n1 = FilterMath.Noise(.init(amount: 40, seed: 3), scale: 1)
        #expect(n.seed != n1.seed && abs(n.spread - n1.spread / 4) < 1e-6)
    }

    /// The document's blurs widen the planner's pruning area by their reaches added up.
    @Test func filterReachAddsUp() {
        var d = FilterFixtures.doc()
        d.layers.append(FilterFixtures.layer(.gaussianBlur(.init(radius: 2))))
        d.layers.append(Layer.group("g", [FilterFixtures.layer(.motionBlur(.init(angle: 0, distance: 12)))]))
        var hidden = FilterFixtures.layer(.gaussianBlur(.init(radius: 50)))
        hidden.visible = false
        d.layers.append(hidden)
        let a = FilterMath.reach(FilterSpec(.gaussianBlur(.init(radius: 2)))), b = FilterMath.reach(FilterSpec(.motionBlur(.init(angle: 0, distance: 12))))
        #expect(LayerGeometry.filterReach(d.layers, nested: true) == a + b)
        #expect(LayerGeometry.filterReach(d.layers) == a)
    }

    /// Timing receipt for PORT-NOTES (`PCRENDER_FILTER_BENCH=1`, release): a 4096² two-layer
    /// document with and without each filter on top, warm, the best of five GPU renders into a
    /// texture (no read-back), and the CPU reference over 1024².
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PCRENDER_FILTER_BENCH"] != nil))
    func bench() throws {
        let gpu = try #require(DT.gpu)
        let base = FilterFixtures.doc(w: 4096, h: 4096)
        func best(_ n: Int, _ body: () throws -> Void) rethrows -> Double {
            var m = Double.infinity
            for _ in 0..<n {
                let t = DispatchTime.now().uptimeNanoseconds
                try body()
                m = min(m, Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
            }
            return m
        }
        let part = PixelRect(x0: 0, y0: 0, x1: 1024, y1: 1024)
        _ = try gpu.renderMetal(base, region: base.bounds)
        let g0 = try best(5) { _ = try gpu.renderMetal(base, region: base.bounds) }
        let c0 = try best(2) { _ = try DT.cpu.render(base, region: part) }
        print(String(format: "FILTER-BENCH none: GPU 4096² %.1f ms, CPU 1024² %.0f ms", g0, c0))
        for (name, f) in [("grain", FilterAdjustment.grain(.init())), ("noise-gaussian", .addNoise(.init(gaussian: true))),
                          ("gaussian-10", .gaussianBlur(.init(radius: 10))), ("gaussian-50", .gaussianBlur(.init(radius: 50))),
                          ("motion-45-40", .motionBlur(.init(angle: 45, distance: 40)))] {
            var d = base
            d.layers.append(FilterFixtures.layer(f))
            _ = try gpu.renderMetal(d, region: d.bounds)
            let g = try best(5) { _ = try gpu.renderMetal(d, region: d.bounds) }
            let c = try best(2) { _ = try DT.cpu.render(d, region: part) }
            print(String(format: "FILTER-BENCH %@: GPU 4096² %.1f ms (+%.1f), CPU 1024² %.0f ms (+%.0f)", name, g, g - g0, c, c - c0))
            // PSD export's bake of the layer (AB-D-0143): the whole canvas into an 8-bit surface.
            let id = d.layers[2].id
            _ = try gpu.bakeFilterLayer(d, layer: id)
            let b = try best(3) { _ = try gpu.bakeFilterLayer(d, layer: id) }
            print(String(format: "FILTER-BENCH %@ bake: 4096² %.0f ms", name, b))
        }
    }
}
