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
}
