// Port of photocraft-algo (crates/algo/src/segment/tests.rs: max-flow, grid cut, Quick Selection; segment/maxflow/push_relabel/tests.rs; segment/edge_starts/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum QuickTest {
    /// photocraft `segment::Rng` (xorshift64) with Box–Muller normals.
    struct Rng {
        var s: UInt64
        init(_ seed: UInt64) { s = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
        mutating func nextU64() -> UInt64 { var x = s; x ^= x << 13; x ^= x >> 7; x ^= x << 17; s = x; return x }
        mutating func f32() -> Float { Float(nextU64() >> 40) / Float(1 << 24) }
        mutating func normal() -> Float {
            let u = max(f32(), 1e-7), v = f32()
            return (-2 * logf(u)).squareRoot() * cosf(PCAMath.tau * v)
        }
    }

    /// Reference max flow (Edmonds–Karp on a dense matrix; node 0 = s, n − 1 = t).
    static func edmondsKarp(_ cap: inout [[Double]]) -> Double {
        let n = cap.count
        var flow = 0.0
        while true {
            var prev = [Int](repeating: -1, count: n)
            prev[0] = 0
            var q = [0]
            var qi = 0
            while qi < q.count {
                let u = q[qi]; qi += 1
                for v in 0..<n where prev[v] == -1 && cap[u][v] > 1e-9 { prev[v] = u; q.append(v) }
            }
            if prev[n - 1] == -1 { return flow }
            var b = Double.greatestFiniteMagnitude
            var v = n - 1
            while v != 0 { b = min(b, cap[prev[v]][v]); v = prev[v] }
            v = n - 1
            while v != 0 { cap[prev[v]][v] -= b; cap[v][prev[v]] += b; v = prev[v] }
            flow += b
        }
    }

    /// The cut energy of a labelling of a graph (push/relabel tests).
    static func energy(_ g: SelectionKit.MaxFlowGraph, _ labels: [Bool]) -> Double {
        var sum = g.flow
        for (i, source) in labels.enumerated() {
            sum += Double(source ? Float.maximum(-g.trCap[i], 0) : Float.maximum(g.trCap[i], 0))
            var a = g.first[i]
            while a != SelectionKit.MaxFlowGraph.none {
                let ai = Int(a)
                if source && !labels[Int(g.head[ai])] { sum += Double(g.rCap[ai]) }
                a = g.next[ai]
            }
        }
        return sum
    }

    /// Left: textured warm region; right: cool region; strong vertical edge at x = 60.
    static func twoRegions(_ w: Int, _ h: Int) -> SegmentRGBImage {
        var rng = Rng(5)
        return SegmentRGBImage(w: w, h: h) { x, y in
            let n = 0.04 * rng.normal()
            let t = (sinf(Float(x) * 0.5) * cosf(Float(y) * 0.3)) * 0.05
            let c: SIMD3<Float> = x < 60 ? SIMD3(0.8 + t + n, 0.5 + n, 0.3 + t) : SIMD3(0.2 + n, 0.35 + t, 0.6 + n)
            return SIMD3(clampf(c.x, 0, 1), clampf(c.y, 0, 1), clampf(c.z, 0, 1))
        }
    }

    static func discScene(_ w: Int, _ h: Int, _ cx: Float, _ cy: Float, _ r: Float, _ seed: UInt64) -> (SegmentRGBImage, [Bool]) {
        var rng = Rng(seed)
        var img = SegmentRGBImage(w: w, h: h)
        var truth = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let dx = Float(x) + 0.5 - cx, dy = Float(y) + 0.5 - cy
                let inside = dx * dx + dy * dy <= r * r
                truth[y * w + x] = inside
                let n = 0.05 * rng.normal()
                let c: SIMD3<Float>
                if inside {
                    let t = clampf(sinf(Float(x + y) * 0.35) * 0.5 + 0.5, 0, 1)
                    c = SIMD3(0.85 + 0.05 * t + n, 0.2 + 0.3 * t + n, 0.15 + n)
                } else {
                    c = SIMD3(0.25 + n, 0.45 + n, 0.7 + n)
                }
                img.px[y * w + x] = SIMD3(clampf(c.x, 0, 1), clampf(c.y, 0, 1), clampf(c.z, 0, 1))
            }
        }
        return (img, truth)
    }

    static func iou(_ r: SelectionRegion, _ truth: [Bool], _ w: Int, _ h: Int) -> Float {
        var inter = 0, uni = 0
        for y in 0..<h {
            for x in 0..<w {
                let a = r.at(Int32(x), Int32(y)) >= 0.5, b = truth[y * w + x]
                if a && b { inter += 1 }
                if a || b { uni += 1 }
            }
        }
        return Float(inter) / Float(max(uni, 1))
    }

    static let red = SIMD3<Float>(200.0 / 255, 60.0 / 255, 60.0 / 255)
    static let blue = SIMD3<Float>(60.0 / 255, 60.0 / 255, 200.0 / 255)

    static func scene(_ w: Int, _ h: Int, _ bg: SIMD3<Float>, _ fg: SIMD3<Float>, _ rect: (Int, Int, Int, Int)) -> SegmentRGBImage {
        SegmentRGBImage(w: w, h: h) { x, y in x >= rect.0 && x < rect.2 && y >= rect.1 && y < rect.3 ? fg : bg }
    }

    static func square(_ w: Int, _ side: Int, _ fg: SIMD3<Float>, _ bg: SIMD3<Float>) -> SegmentRGBImage {
        let x0 = (w - side) / 2
        return scene(w, w, bg, fg, (x0, x0, x0 + side, x0 + side))
    }

    static func qs(_ img: SegmentRGBImage, _ pts: [SIMD2<Float>], _ size: Float) -> SelectionRegion {
        QuickSelection.quickSelect(ImageSegmentSampler(img), canvas: PixelRect(x: 0, y: 0, width: img.w, height: img.h), points: pts, size: size)!
    }

    static func count(_ r: SelectionRegion) -> Int { r.mask.filter { $0 >= 128 }.count }

    static func insideOutside(_ r: SelectionRegion, _ rect: (Int32, Int32, Int32, Int32)) -> (Int, Int) {
        var i = 0, o = 0
        for y in r.bbox.y0..<r.bbox.y1 {
            for x in r.bbox.x0..<r.bbox.x1 where r.at(x, y) >= 0.5 {
                if x >= rect.0 && x < rect.2 && y >= rect.1 && y < rect.3 { i += 1 } else { o += 1 }
            }
        }
        return (i, o)
    }
}

@Suite struct SelectionQuickTests {
    // MARK: Max-flow

    @Test func maxflowTinyAndCLRS() {
        var g = SelectionKit.MaxFlowGraph(nodes: 2, edges: 1)
        g.addTWeights(0, 3, 2); g.addTWeights(1, 2, 3); g.addEdge(0, 1, 1, 0)
        #expect(g.maxflow() == 5)
        var c = SelectionKit.MaxFlowGraph(nodes: 4, edges: 5)
        c.addTWeights(0, 16, 0); c.addTWeights(1, 13, 0); c.addTWeights(2, 0, 20); c.addTWeights(3, 0, 4)
        c.addEdge(0, 1, 10, 4); c.addEdge(0, 2, 12, 0); c.addEdge(2, 1, 9, 0); c.addEdge(1, 3, 14, 0); c.addEdge(3, 2, 7, 0)
        #expect(c.maxflow() == 23)
        #expect(c.inSource(0) && c.inSource(1) && c.inSource(3) && !c.inSource(2))
        #expect(c.residualOutOfSourceSide() == 0)
    }

    /// photocraft `maxflow_can_be_cancelled_and_otherwise_cuts_the_same`.
    @Test func maxflowCanBeCancelled() {
        for (w, h) in [(120, 100), (20, 15)] {
            var g = SelectionKit.MaxFlowGraph(nodes: w * h, edges: w * h * 2)
            var z: UInt64 = 7
            func next() -> Float { z = z &* 6364136223846793005 &+ 1442695040888963407; return Float(z >> 40) / Float(1 << 24) }
            for i in 0..<(w * h) {
                g.addTWeights(i, next() * 2, next() * 2)
                if i % w + 1 < w { g.addEdge(i, i + 1, next(), next()) }
                if i + w < w * h { g.addEdge(i, i + w, next(), next()) }
            }
            var plain = g, asked = g
            let flow = plain.maxflow()
            #expect(asked.maxflow(cancel: { false }) == flow)
            #expect((0..<(w * h)).allSatisfy { plain.inSource($0) == asked.inSource($0) })
            if w * h > 4096 { #expect(g.maxflow(cancel: { true }) == nil) }
        }
    }

    /// photocraft `maxflow_matches_reference_on_random_graphs`.
    @Test func maxflowMatchesReferenceOnRandomGraphs() {
        var rng = QuickTest.Rng(7)
        for trial in 0..<60 {
            let n = 3 + trial % 12
            var g = SelectionKit.MaxFlowGraph(nodes: n, edges: n * 3)
            var cap = [[Double]](repeating: [Double](repeating: 0, count: n + 2), count: n + 2)
            var edges: [(Int, Int, Float, Float)] = []
            for i in 0..<n {
                var s = (rng.f32() * 10).rounded(), t = (rng.f32() * 10).rounded()
                if rng.f32() < 0.4 { s = 0 }
                if rng.f32() < 0.4 { t = 0 }
                g.addTWeights(i, s, t)
                cap[0][i + 1] += Double(s); cap[i + 1][n + 1] += Double(t)
            }
            for i in 0..<n {
                for j in (i + 1)..<max(n, i + 1) where rng.f32() < 0.35 {
                    let a = (rng.f32() * 8).rounded(), b = (rng.f32() * 8).rounded()
                    g.addEdge(i, j, a, b)
                    cap[i + 1][j + 1] += Double(a); cap[j + 1][i + 1] += Double(b)
                    edges.append((i, j, a, b))
                }
            }
            let orig = cap
            let reference = QuickTest.edmondsKarp(&cap)
            let f = g.maxflow()
            #expect(abs(f - reference) < 1e-3, "trial \(trial): \(f) vs \(reference)")
            var cut = 0.0
            for i in 0..<n { cut += g.inSource(i) ? orig[i + 1][n + 1] : orig[0][i + 1] }
            for (i, j, a, b) in edges {
                if g.inSource(i) && !g.inSource(j) { cut += Double(a) }
                if g.inSource(j) && !g.inSource(i) { cut += Double(b) }
            }
            #expect(abs(cut - reference) < 1e-3, "trial \(trial): cut \(cut) vs flow \(reference)")
        }
    }

    /// photocraft `preflow_matches_bk_on_integer_graphs_and_returns_unused_source`.
    @Test func preflowMatchesBKOnIntegerGraphs() {
        var rng: UInt32 = 7
        func next() -> UInt32 { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng }
        for n in 1..<40 {
            for _ in 0..<30 {
                var g = SelectionKit.MaxFlowGraph(nodes: n, edges: n * 4)
                for i in 0..<n { g.addTWeights(i, Float(next() % 10), Float(next() % 10)) }
                for i in 0..<n { for j in (i + 1)..<max(n, i + 1) where next() % 7 == 0 { g.addEdge(i, j, Float(next() % 8), Float(next() % 8)) } }
                var old = g
                #expect(g.maxflowPushRelabel() == old.maxflowBK())
                #expect((0..<n).map { g.inSource($0) } == (0..<n).map { old.inSource($0) })
                #expect(g.residualOutOfSourceSide() == 0)
                let flow = g.flow
                #expect(g.maxflowPushRelabel() == flow)
            }
        }
    }

    /// photocraft `fractional_flows_match_brute_force_minimum_cuts`.
    @Test func fractionalFlowsMatchBruteForceMinimumCuts() {
        var rng = QuickTest.Rng(911)
        for n in 1...10 {
            for _ in 0..<20 {
                var g = SelectionKit.MaxFlowGraph(nodes: n, edges: n * n)
                for i in 0..<n {
                    g.addTWeights(i, Float(rng.nextU64() % 31) / 32, Float(rng.nextU64() % 31) / 32)
                    for j in 0..<i where rng.nextU64() % 5 == 0 { g.addEdge(i, j, Float(rng.nextU64() % 31) / 32, Float(rng.nextU64() % 31) / 32) }
                }
                let input = g
                var optimum = Double.infinity
                var smallest = [Bool](repeating: true, count: n)
                for code in 0..<(1 << n) {
                    let labels = (0..<n).map { code & (1 << $0) != 0 }
                    let value = QuickTest.energy(input, labels)
                    if value < optimum { optimum = value; smallest = labels } else if value == optimum { for k in 0..<n { smallest[k] = smallest[k] && labels[k] } }
                }
                #expect(g.maxflowPushRelabel() == optimum, "n=\(n)")
                let labels = (0..<n).map { g.inSource($0) }
                #expect(QuickTest.energy(input, labels) == optimum)
                #expect(labels == smallest)
            }
        }
    }

    /// photocraft `float_capacity_graphs_match_bk`.
    @Test func floatCapacityGraphsMatchBK() {
        var rng = QuickTest.Rng(819)
        for n in [1, 2, 7, 16, 39, 64] {
            for c in 0..<100 {
                var g = SelectionKit.MaxFlowGraph(nodes: n, edges: n * 4)
                for i in 0..<n {
                    g.addTWeights(i, Float(rng.nextU64() % 1001) / 97, Float(rng.nextU64() % 1001) / 97)
                    for j in 0..<i where rng.nextU64() % 7 == 0 { g.addEdge(i, j, Float(rng.nextU64() % 1001) / 113, Float(rng.nextU64() % 1001) / 113) }
                }
                var old = g
                let a = g.maxflowPushRelabel(), b = old.maxflowBK()
                #expect(abs(a - b) < 0.001, "n=\(n) case=\(c): \(a) vs \(b)")
                #expect((0..<n).map { g.inSource($0) } == (0..<n).map { old.inSource($0) }, "n=\(n) case=\(c)")
            }
        }
    }

    /// photocraft `sparse_graph_keeps_exact_masks_and_avoids_irrelevant_weights`.
    @Test func sparseGraphKeepsExactMasksAndAvoidsIrrelevantWeights() {
        let (w, h) = (101, 93)
        let img = SegmentRGBImage(w: w, h: h) { x, y in SIMD3(repeating: Float((x * 13 + y * 7) % 257) / 256) }
        let cost = (0..<(w * h)).map { Float($0 % 11) * 0.01 }
        for kind in 0..<4 {
            let fixed: [UInt8] = (0..<(w * h)).map { i in
                if (kind == 0 && i % 503 == 0) || (kind == 1 && i % w >= 48 && i % w <= 52) || (kind == 2 && i / w == 0) || (kind == 3 && i % w == w - 1) {
                    return QuickSelection.free
                }
                return i % w < 50 ? QuickSelection.hardFG : QuickSelection.hardBG
            }
            var before = 0, after = 0
            let old = QuickSelection.gridCutWeighted(img, cost, cost, fixed, optimized: false) { before += 1; return 0.3 * expf(-2 * $0) }
            let new = QuickSelection.gridCutWeighted(img, cost, cost, fixed, optimized: true) { after += 1; return 0.3 * expf(-2 * $0) }
            #expect(new == old, "kind \(kind)")
            #expect(after * 5 < before, "kind \(kind): \(before) -> \(after)")
        }
    }

    /// photocraft `source_return_survives_long_disconnected_chains`.
    @Test func sourceReturnSurvivesLongChains() {
        let n = 5000
        var g = SelectionKit.MaxFlowGraph(nodes: n, edges: n)
        g.addTWeights(0, 200, 0); g.addTWeights(n - 1, 0, 100)
        for i in 1..<(n - 1) { g.addEdge(i - 1, i, 100, 100) }
        #expect(g.maxflowPushRelabel() == 0)
        #expect((0..<n).allSatisfy { g.inSource($0) == ($0 != n - 1) })
        #expect(g.maxflowPushRelabel() == 0)
        g.addEdge(n - 2, n - 1, 30, 30)
        #expect(g.maxflowPushRelabel() == 30)
        #expect(g.residualOutOfSourceSide() == 0)
    }

    /// photocraft `merged_starts_equal_all_live_edge_sources`.
    @Test func mergedStartsEqualAllLiveEdgeSources() {
        for (w, h) in [(1, 1), (1, 7), (7, 1), (2, 3), (4, 3)] {
            for bits in 0..<(1 << (w * h)) {
                let free = (0..<(w * h)).filter { bits & (1 << $0) != 0 }
                var expected: [Int] = []
                for y in 0..<h {
                    for x in 0..<w {
                        let i = y * w + x
                        let live = free.contains(i) || QuickSelection.nb.contains { dx, dy, _ in
                            let xx = x + dx, yy = y + dy
                            return xx >= 0 && xx < w && yy < h && free.contains(yy * w + xx)
                        }
                        if live { expected.append(i) }
                    }
                }
                var s = QuickSelection.EdgeStarts(free, w)
                var got: [Int] = []
                while let i = s.next() { got.append(i) }
                #expect(got == expected, "\(w)x\(h) bits \(bits)")
            }
        }
    }

    /// photocraft `every_small_constraint_mask_matches_the_previous_graph`.
    @Test func everySmallConstraintMaskMatchesThePreviousGraph() {
        for (w, h) in [(1, 1), (1, 6), (6, 1), (2, 3)] {
            let img = SegmentRGBImage(w: w, h: h) { x, y in SIMD3(Float(x % 3) / 2, Float(y % 4) / 3, Float((x + y) % 5) / 4) }
            var p3 = 1
            for _ in 0..<(w * h) { p3 *= 3 }
            for code in 0..<p3 {
                var state = code
                let fixed: [UInt8] = (0..<(w * h)).map { _ in let v = state % 3; state /= 3; return [QuickSelection.free, QuickSelection.hardFG, QuickSelection.hardBG][v] }
                let fg = (0..<(w * h)).map { Float($0 % 3) * 0.1 }, bg = (0..<(w * h)).map { Float($0 % 4) * 0.15 }
                for kind in 0..<3 {
                    let weight = { (d: Float) -> Float in kind == 0 ? 1 : (kind == 1 ? 0.3 * expf(-2 * d) : 0.02 + 1 / (1 + powf(d.squareRoot() / 0.05, 1.98))) }
                    #expect(QuickSelection.gridCutWeighted(img, fg, bg, fixed, optimized: true, weight) == QuickSelection.gridCutWeighted(img, fg, bg, fixed, optimized: false, weight),
                            "\(w)x\(h) code \(code) kind \(kind)")
                }
            }
        }
    }

    /// photocraft `grid_cut_separates_two_halves` and `malformed_grid_dimensions_and_short_inputs_return_empty`.
    @Test func gridCutSeparatesTwoHalvesAndRejectsMalformedInput() {
        let img = SegmentRGBImage(w: 20, h: 10) { x, _ in x < 10 ? SIMD3(0.9, 0.1, 0.1) : SIMD3(0.1, 0.1, 0.9) }
        var fixed = [UInt8](repeating: QuickSelection.free, count: 200)
        fixed[5 * 20 + 1] = QuickSelection.hardFG
        fixed[5 * 20 + 18] = QuickSelection.hardBG
        let zeros = [Float](repeating: 0, count: 200)
        let cut = QuickSelection.gridCut(img, costFG: zeros, costBG: zeros, fixed: fixed, gamma: 50, beta: QuickSelection.contrastBeta(img))
        for y in 0..<10 { for x in 0..<20 { #expect(cut[y * 20 + x] == (x < 10), "(\(x),\(y))") } }
        #expect(QuickSelection.gridCut(SegmentRGBImage(w: 2, h: 2, px: [SIMD3<Float>](repeating: .zero, count: 3)), costFG: [], costBG: [], fixed: [], gamma: 1, beta: 1).isEmpty)
        let small = SegmentRGBImage(w: 2, h: 2)
        let c4 = [Float](repeating: 0, count: 4), f4 = [UInt8](repeating: QuickSelection.free, count: 4)
        #expect(QuickSelection.gridCutWith(small, costFG: Array(c4[0..<3]), costBG: c4, fixed: f4) { _ in 1 }.isEmpty)
        #expect(QuickSelection.gridCutWith(small, costFG: c4, costBG: c4, fixed: Array(f4[0..<3])) { _ in 1 }.isEmpty)
    }

    // MARK: Quick Selection

    /// photocraft `quick_select_with_points_far_off_canvas_selects_nothing`.
    @Test func quickSelectWithPointsFarOffCanvasSelectsNothing() {
        let s = ImageSegmentSampler(QuickTest.twoRegions(140, 100))
        for p in [SIMD2<Float>(3e9, 0), SIMD2(0, 3e9), SIMD2(.greatestFiniteMagnitude, .greatestFiniteMagnitude)] {
            #expect(QuickSelection.quickSelect(s, canvas: PixelRect(x: 0, y: 0, width: 140, height: 100), points: [p], size: 8) == nil, "\(p)")
        }
    }

    /// photocraft `quick_select_grows_without_leaking`.
    @Test func quickSelectGrowsWithoutLeaking() {
        let s = ImageSegmentSampler(QuickTest.twoRegions(140, 100))
        let reg = QuickSelection.quickSelect(s, canvas: PixelRect(x: 0, y: 0, width: 140, height: 100), points: [SIMD2(20, 50), SIMD2(35, 50)], size: 8)!
        var inside = 0
        for y: Int32 in 0..<100 {
            for x: Int32 in 0..<140 {
                let v = reg.at(x, y)
                if x >= 62 && v >= 0.5 { Issue.record("leaked across the edge at (\(x),\(y)): \(v)"); return }
                if x < 58 && v >= 0.5 { inside += 1 }
            }
        }
        #expect(Float(inside) > 0.97 * 58 * 100, "only \(inside) pixels selected")
    }

    /// photocraft `quick_select_stops_at_thin_line`.
    @Test func quickSelectStopsAtThinLine() {
        var rng = QuickTest.Rng(9)
        let img = SegmentRGBImage(w: 120, h: 80) { x, _ in
            let n = 0.03 * rng.normal()
            return x == 60 || x == 61 ? SIMD3(0.05, 0.05, 0.05) : SIMD3(0.6 + n, 0.6 + n, 0.55 + n)
        }
        let reg = QuickSelection.quickSelect(ImageSegmentSampler(img), canvas: PixelRect(x: 0, y: 0, width: 120, height: 80), points: [SIMD2(30, 40)], size: 6)!
        #expect(reg.at(10, 10) >= 0.5 && reg.at(50, 70) >= 0.5)
        for y: Int32 in 0..<80 { for x: Int32 in 63..<120 where reg.at(x, y) >= 0.5 { Issue.record("crossed the line at (\(x),\(y))"); return } }
    }

    /// photocraft `quick_select_a_drag_selects_around_itself_not_a_big_object`.
    @Test func quickSelectADragSelectsAroundItselfNotABigObject() {
        let (img, truth) = QuickTest.discScene(600, 500, 300, 250, 180, 4)
        let reg = QuickSelection.quickSelect(ImageSegmentSampler(img), canvas: PixelRect(x: 0, y: 0, width: 600, height: 500), points: [SIMD2(260, 250), SIMD2(340, 250)], size: 30)!
        let n = QuickTest.count(reg)
        #expect((3000..<9000).contains(n), "\(n) px")
        #expect(reg.at(300, 250) >= 0.5 && reg.at(262, 250) >= 0.5)
        #expect(QuickTest.iou(reg, truth, 600, 500) < 0.2)
    }

    /// photocraft `quick_select_works_at_full_or_exactly_half_resolution`.
    @Test func quickSelectWorksAtFullOrExactlyHalfResolution() {
        #expect(QuickSelection.workingStep(512, 512) == 1 && QuickSelection.workingStep(513, 512) == 2 && QuickSelection.workingStep(520, 300) == 1)
        #expect(QuickSelection.workingStep(900, 300) == 2 && QuickSelection.workingStep(5000, 3500) == 2)
        let r = QuickTest.qs(QuickTest.square(640, 200, QuickTest.red, QuickTest.blue), [SIMD2(320, 320)], 30)
        let row = (216..<223).map { UInt8((r.at(Int32($0), 320) * 255).rounded()) }
        #expect(row == [0, 0, 0, 64, 191, 255, 255])
    }

    /// photocraft `quick_select_click_in_a_flat_area_selects_about_the_brush`.
    @Test func quickSelectClickInAFlatAreaSelectsAboutTheBrush() {
        let n = QuickTest.count(QuickTest.qs(QuickTest.scene(400, 400, QuickTest.red, QuickTest.red, (0, 0, 0, 0)), [SIMD2(200, 200)], 30))
        #expect((700..<1600).contains(n), "\(n) px")
    }

    /// photocraft `quick_select_click_takes_an_object_only_while_it_is_small_enough`.
    @Test func quickSelectClickTakesAnObjectOnlyWhileItIsSmallEnough() {
        let (i, o) = QuickTest.insideOutside(QuickTest.qs(QuickTest.square(500, 220, QuickTest.red, QuickTest.blue), [SIMD2(250, 250)], 30), (140, 140, 360, 360))
        #expect(i >= 220 * 220 - 10 && o == 0, "220: \(i) in, \(o) out")
        #expect(QuickTest.count(QuickTest.qs(QuickTest.square(500, 240, QuickTest.red, QuickTest.blue), [SIMD2(250, 250)], 30)) < 2000)
        let lo = SIMD3<Float>(125.0 / 255, 110.0 / 255, 110.0 / 255), hi = SIMD3<Float>(110.0 / 255, 110.0 / 255, 125.0 / 255)
        let (i2, o2) = QuickTest.insideOutside(QuickTest.qs(QuickTest.square(500, 94, lo, hi), [SIMD2(250, 250)], 30), (203, 203, 297, 297))
        #expect(i2 >= 94 * 94 - 10 && o2 == 0, "94: \(i2) in, \(o2) out")
        #expect(QuickTest.count(QuickTest.qs(QuickTest.square(500, 120, lo, hi), [SIMD2(250, 250)], 30)) < 2000)
    }

    /// photocraft `quick_select_takes_a_narrow_bar_end_to_end_but_only_the_end_near_it`.
    @Test func quickSelectTakesANarrowBar() {
        let img = QuickTest.scene(500, 500, QuickTest.blue, QuickTest.red, (100, 50, 180, 450))
        let (i, o) = QuickTest.insideOutside(QuickTest.qs(img, [SIMD2(140, 250)], 30), (100, 50, 180, 450))
        #expect(i >= 80 * 400 - 10 && o == 0, "middle: \(i) in, \(o) out")
        let (i2, o2) = QuickTest.insideOutside(QuickTest.qs(img, [SIMD2(140, 420)], 30), (100, 380, 180, 450))
        #expect(i2 > 2500 && o2 == 0, "near the end: \(i2) in, \(o2) elsewhere")
    }

    /// photocraft `quick_select_a_short_drag_takes_what_a_click_does_not`.
    @Test func quickSelectAShortDragTakesWhatAClickDoesNot() {
        let img = QuickTest.square(500, 300, QuickTest.red, QuickTest.blue)
        #expect(QuickTest.count(QuickTest.qs(img, [SIMD2(250, 250)], 30)) < 2000)
        let (i, o) = QuickTest.insideOutside(QuickTest.qs(img, [SIMD2(220, 250), SIMD2(280, 250)], 30), (100, 100, 400, 400))
        #expect(i >= 300 * 300 - 10 && o == 0, "\(i) in, \(o) out")
    }

    /// photocraft `quick_select_on_a_large_document_grows_its_window_to_the_object`.
    @Test func quickSelectOnALargeDocumentGrowsItsWindow() {
        let img = QuickTest.scene(1000, 600, QuickTest.blue, QuickTest.red, (20, 260, 980, 340))
        let (i, o) = QuickTest.insideOutside(QuickTest.qs(img, [SIMD2(500.5, 300.5)], 30), (20, 260, 980, 340))
        #expect(i >= 960 * 80 * 98 / 100 && o < 2000, "\(i) in, \(o) out")
    }
}
