// Tests for fixes taken from photocraft after this port's base (184c226a), ported from the tests
// photocraft added with them (crates/algo/src/segment/maxflow/push_relabel/tests.rs, other.rs,
// crates/algo/tests/warp_clipped.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct UpstreamFixTests {
    /// photocraft #4869 `stranded_excess_terminates_and_matches_bk`: source capacities far beyond
    /// Float precision (ulp 32 at 3e8) next to small links strand excess on nodes a global relabel
    /// finds reachable from neither terminal. Those nodes used to count as admissible for each
    /// other and passed the excess back and forth forever.
    @Test func strandedExcessTerminatesAndMatchesBK() {
        var g = SelectionKit.MaxFlowGraph(nodes: 6, edges: 7)
        let t: [(Float, Float)] = [(33123824.0, 0), (347622050.0, 0), (0, 5539047.5), (76592.22, 0), (3514.0022, 0), (0, 13670.268)]
        for (i, w) in t.enumerated() { g.addTWeights(i, w.0, w.1) }
        let e: [(Int, Int, Float)] = [(0, 1, 0), (0, 3, 0.0007301044), (1, 2, 2.803e-42), (1, 4, 8.160078), (2, 5, 3.1224866e-7), (3, 4, 28.512966), (4, 5, 4.099367)]
        for (i, j, c) in e { g.addEdge(i, j, c, c) }
        var bk = g
        var checks = 0
        let flow = g.pushRelabel { checks += 1; return checks > 1000 }
        let bkFlow = bk.maxflowBK()
        guard let flow else { Issue.record("push/relabel did not terminate"); return }
        #expect(abs(flow - bkFlow) <= 1e-6 * bkFlow)
        #expect((0..<6).map { g.inSource($0) } == (0..<6).map { bk.inSource($0) })
    }

    /// photocraft #4738 `offset_limits_match_equivalent_small_offsets_for_every_edge_policy`: an
    /// offset at the Int32 limits moves samples exactly as the equivalent small offset does.
    @Test func offsetLimitsMatchEquivalentSmallOffsets() {
        for b in [PixelRect(x0: 0, y0: 0, x1: 3, y1: 5), PixelRect(x0: -7, y0: 11, x1: -4, y1: 16)] {
            let img = FloatImage(rect: b, channels: 4, data: (0..<(3 * 5 * 4)).map { Float($0) * 0.125 - 2 })
            let ctx = FilterContext(bounds: b, mode: .rgb, alpha: true)
            for policy in UndefinedAreas.allCases {
                for dx in [Int32.min, Int32.max, -8, 0, 7] {
                    for dy in [Int32.min, Int32.max, -9, 0, 6] {
                        func reduce(_ d: Int32, _ size: Int32) -> Int32 {
                            policy == .wrap ? Int32(((Int64(d) % Int64(size)) + Int64(size)) % Int64(size)) : min(max(d, -100), 100)
                        }
                        let (rx, ry) = (reduce(dx, 3), reduce(dy, 5))
                        var expected: [Float] = []
                        for y in b.y0..<b.y1 {
                            for x in b.x0..<b.x1 {
                                for c in 0..<4 { expected.append(img.getEdge(x - rx, y - ry, c, policy.edge, b)) }
                            }
                        }
                        #expect(Offset(horizontal: dx, vertical: dy, undefined: policy).cpu(img, out: b, ctx: ctx).data == expected, "\(b) \(policy) \(dx) \(dy)")
                        // The offsets handed to the shader give the same picture and keep `x − dx` in 32 bits.
                        let (gx, gy) = (Offset.reduced(dx, b.width, policy), Offset.reduced(dy, b.height, policy))
                        #expect(Offset(horizontal: gx, vertical: gy, undefined: policy).cpu(img, out: b, ctx: ctx).data == expected)
                        #expect(abs(Int(gx)) <= b.width && abs(Int(gy)) <= b.height)
                    }
                }
            }
        }
    }

    /// photocraft #4738 `offset_wrap_handles_bounds_at_signed_coordinate_limits`.
    @Test func offsetWrapHandlesBoundsAtCoordinateLimits() {
        for start in [Int32.min, Int32.max - 3] {
            let b = PixelRect(x0: start, y0: start, x1: start + 3, y1: start + 3)
            let img = FloatImage(rect: b, channels: 1, data: (0..<9).map(Float.init))
            let out = Offset(horizontal: .min, vertical: .min, undefined: .wrap).cpu(img, out: b, ctx: FilterContext(bounds: b, mode: .grayscale, alpha: false))
            #expect(out.data == [8, 6, 7, 2, 0, 1, 5, 3, 4])
        }
    }

    /// photocraft #5451: the source-centre fallback of a far-origin source rect is summed without
    /// overflowing Int32.
    @Test func prefilterCentreOfAFarSourceRectDoesNotOverflow() {
        let far = PixelRect(x0: 1_500_000_000, y0: 1_500_000_000, x1: 1_500_000_032, y1: 1_500_000_032)
        #expect(TransformKit.prefilter(srcRect: far, h: .identity, interp: .bilinear, clip: nil) == nil)
    }

    /// A sprite whose edge pixels are half transparent (photocraft #6203).
    static func softEdgedSprite() -> Surface {
        var s = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: true))
        s.fill(PixelRect(x0: 10, y0: 10, x1: 30, y1: 30), with: [0.8, 0.6, 0.4, 0.5])
        s.fill(PixelRect(x0: 11, y0: 11, x1: 29, y1: 29), with: [0.8, 0.6, 0.4, 1])
        return s
    }

    static func worstColourOffset(_ out: Surface) -> Float {
        var worst: Float = 0
        let b = out.contentBounds
        for y in b.y0..<b.y1 {
            for x in b.x0..<b.x1 {
                let p = out.pixel(x: x, y: y)
                if p[3] > 0 { for i in 0..<3 { worst = max(worst, abs(p[i] - [0.8, 0.6, 0.4][i])) } }
            }
        }
        return worst
    }

    /// photocraft #6203 `rotation_keeps_the_colour_of_a_soft_edged_sprite`: a bicubic rotation
    /// overshoots the alpha past 1 next to partly transparent pixels; the colour must stay the
    /// sprite's and not grow with the overshoot into a light border.
    @Test(arguments: [Backend.cpu, .auto])
    func rotationKeepsTheColourOfASoftEdgedSprite(_ backend: Backend) throws {
        let s = Self.softEdgedSprite()
        let c = 20.0, k = 0.5.squareRoot() * 10
        let h = try #require(Homography.rectToQuad([10, 10, 30, 30], [SIMD2(c, c - 2 * k), SIMD2(c + 2 * k, c), SIMD2(c, c + 2 * k), SIMD2(c - 2 * k, c)]))
        for interp in [Interp.bicubic, .bilinear] {
            let out = Transform.warpSurface(s, srcRect: s.contentBounds, h: h, interp: interp, on: backend)
            #expect(Self.worstColourOffset(out) <= 1.0 / 255.0, "\(interp)")
        }
    }

    /// photocraft #6203 `a_rotated_soft_edged_sprite_keeps_its_colour` (mesh warp).
    @Test(arguments: [Backend.cpu, .auto])
    func meshRotationKeepsTheColourOfASoftEdgedSprite(_ backend: Backend) {
        let s = Self.softEdgedSprite()
        let k = 0.5.squareRoot()
        let out = MeshWarp.warpMeshSurface(s, srcRect: s.contentBounds, map: { x, y in
            (20 + (x - 20) * k - (y - 20) * k, 20 + (x - 20) * k + (y - 20) * k)
        }, interp: .bicubic, on: backend)
        #expect(Self.worstColourOffset(out) <= 1.0 / 255.0)
    }

    /// photocraft #3415: an edge tangent is an axis, so a link along an edge costs the same
    /// whichever way the gradient that defined the tangent points.
    @Test func magneticLassoDirectionCostIgnoresGradientPolarity() {
        let t = SIMD2<Float>(1, 0), r = SIMD2<Float>(-1, 0)
        let along = MagneticLasso.directionCost(t, t, 1, 0, 1)
        #expect(abs(along) < 1e-6)
        #expect(abs(MagneticLasso.directionCost(t, r, 1, 0, 1) - along) < 1e-6)
        #expect(abs(MagneticLasso.directionCost(r, t, 1, 0, 1) - along) < 1e-6)
        #expect(MagneticLasso.directionCost(t, t, 0, 1, 1) > 0.6)
    }

    /// photocraft #8544 `small_gaussian_radii_blur_smoothly`: below 1 the kernel's variance is the
    /// radius squared and grows smoothly; from 1 up the kernel is unchanged.
    @Test func smallGaussianRadiiBlurSmoothly() {
        func spread(_ k: [Float]) -> Float {
            let r = Float(k.count / 2)
            return k.enumerated().reduce(0) { $0 + $1.element * (Float($1.offset) - r) * (Float($1.offset) - r) }
        }
        var last: Float = 0
        for step in 1...20 {
            let radius = Float(step) * 0.05
            let k = BlurCore.gaussianBlurKernel(radius)
            #expect(abs(k.reduce(0, +) - 1) < 1e-5, "normalised at \(radius)")
            if radius < 1 { #expect(abs(spread(k) - radius * radius) < 1e-4, "variance at \(radius): \(spread(k))") }
            #expect(spread(k) > last, "grows at \(radius)")
            last = spread(k)
        }
        for radius: Float in [1, 1.5, 2.7, 4] { #expect(BlurCore.gaussianBlurKernel(radius) == BlurCore.gaussianKernel(radius)) }
    }

    /// photocraft #9959: the clouds' tails are compressed, not clipped onto the two colours, and
    /// the mid-tones keep their slope.
    @Test func cloudsDoNotClipToTheColours() {
        let b = PixelRect(x0: 0, y0: 0, x1: 256, y1: 256)
        let f = Clouds(seed: 7, difference: false, foreground: SIMD4(0, 0, 0, 1), background: SIMD4(1, 1, 1, 1))
        let src = FloatImage(rect: b, channels: 4)
        let out = f.cpu(src, out: b, ctx: FilterContext(bounds: b, mode: .rgb, alpha: true))
        var lo: Float = 1, hi: Float = 0, sum: Float = 0
        for i in stride(from: 0, to: out.data.count, by: 4) { lo = min(lo, out.data[i]); hi = max(hi, out.data[i]); sum += out.data[i] }
        let mean = sum / Float(out.data.count / 4)
        #expect(lo > 0 && hi < 1, "\(lo)…\(hi)")
        #expect(hi - lo > 0.6, "\(lo)…\(hi)")
        #expect(abs(mean - 0.5) < 0.1, "\(mean)")
    }

    /// photocraft #5745 `an_image_wholly_inside_the_composite_still_gets_its_side`: the first
    /// image covers the whole grid, the second only its right part, all of it overlap. It used to
    /// be skipped, so the first image kept everything.
    @Test func anImageWhollyInsideTheCompositeStillGetsItsSide() {
        let (w, h) = (120, 40)
        let luma = [[Float]](repeating: [Float](repeating: 0.5, count: w * h), count: 2)
        let cover = [[Bool](repeating: true, count: w * h), (0..<(w * h)).map { $0 % w >= 70 }]
        let labels = Panorama.seamLabels(width: w, height: h, luma: luma, cover: cover, order: [0, 1])
        for y in 0..<h {
            #expect(labels[y * w + 5] == 0 && labels[y * w + w - 1] == 1, "row \(y)")
            let row = Array(labels[(y * w)..<((y + 1) * w)])
            let first = row.firstIndex(of: 1) ?? 0
            #expect(first >= 70 && row[first...].allSatisfy { $0 == 1 }, "row \(y)")
        }
        // An image centred on the composite has no side: the first image keeps the overlap.
        let centred = [[Bool](repeating: true, count: w * h), (0..<(w * h)).map { (20..<100).contains($0 % w) }]
        #expect(Panorama.seamLabels(width: w, height: h, luma: luma, cover: centred, order: [0, 1]).allSatisfy { $0 == 0 })
        let same = [[Bool]](repeating: [Bool](repeating: true, count: w * h), count: 2)
        #expect(Panorama.seamLabels(width: w, height: h, luma: luma, cover: same, order: [0, 1]).allSatisfy { $0 == 0 })
    }

    // MARK: CMYK samples are ink

    /// A CMYK image without alpha: four inks per pixel, values in 0…1.
    static func cmyk(_ b: PixelRect, _ px: (Int32, Int32) -> [Float]) -> FloatImage {
        var data: [Float] = []
        for y in b.y0..<b.y1 { for x in b.x0..<b.x1 { data += px(x, y) } }
        return FloatImage(rect: b, channels: 4, data: data)
    }

    static func cmykCtx(_ b: PixelRect) -> FilterContext { FilterContext(bounds: b, mode: .cmyk, alpha: false) }

    /// photocraft #4222: Find Edges writes the edge strength as ink in CMYK, so a flat area is
    /// paper white (no ink), not 100 % ink; Solarize inverts the channels below 50 % ink.
    @Test func findEdgesAndSolarizeTreatCMYKAsInk() throws {
        let b = PixelRect(x0: 0, y0: 0, x1: 12, y1: 12)
        let flat = Self.cmyk(b) { _, _ in [0.3, 0.3, 0.3, 0.3] }
        let inner = PixelRect(x0: 2, y0: 2, x1: 10, y1: 10)
        let edges = try FilterEngine.apply(FindEdges(), to: flat, output: inner, context: Self.cmykCtx(b), on: .cpu)
        #expect(edges.data.allSatisfy { $0 == 0 }, "flat CMYK is no ink")
        let rgb = try FilterEngine.apply(FindEdges(), to: flat, output: inner, context: FilterContext(bounds: b, mode: .rgb, alpha: true), on: .cpu)
        #expect(rgb.data.enumerated().allSatisfy { $0.offset % 4 == 3 || $0.element == 1 }, "flat RGB is white")

        let sol = Solarize().cpu(Self.cmyk(b) { _, _ in [0.2, 0.8, 0.5, 0.4] }, out: b, ctx: Self.cmykCtx(b))
        #expect(Array(sol.data[0..<4]).enumerated().allSatisfy { abs($0.element - [0.8, 0.8, 0.5, 0.6][$0.offset]) < 1e-6 })

        let noisy = Self.cmyk(b) { x, y in [Float((x * 7 + y * 3) % 11) / 10, Float((x + y * 5) % 7) / 6, Float(x % 3) / 2, Float(y % 4) / 3] }
        try Parity.check(FindEdges(), src: noisy, out: inner, ctx: Self.cmykCtx(b))
        try Parity.check(Solarize(), src: noisy, ctx: Self.cmykCtx(b))
    }

    /// photocraft #7076: in CMYK the Custom filter runs on 1 − ink, so a positive offset brightens.
    @Test func customOffsetBrightensInCMYK() throws {
        let b = PixelRect(x0: 0, y0: 0, x1: 10, y1: 10)
        let src = Self.cmyk(b) { _, _ in [0.5, 0.5, 0.5, 0.5] }
        var k = [Float](repeating: 0, count: 25)
        k[12] = 1
        let f = CustomKernel(kernel: k, scale: 1, offset: 51)
        let inner = PixelRect(x0: 2, y0: 2, x1: 8, y1: 8)
        let out = try FilterEngine.apply(f, to: src, output: inner, context: Self.cmykCtx(b), on: .cpu)
        #expect(out.data.allSatisfy { abs($0 - 0.3) < 1e-5 }, "less ink: \(out.data[0])")
        let rgb = try FilterEngine.apply(f, to: src, output: inner, context: FilterContext(bounds: b, mode: .rgb, alpha: true), on: .cpu)
        #expect(abs(rgb.data[0] - 0.7) < 1e-5)
        try Parity.check(f, src: src, out: inner, ctx: Self.cmykCtx(b))
    }
}
