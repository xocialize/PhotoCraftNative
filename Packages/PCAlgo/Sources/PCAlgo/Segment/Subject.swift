// Port of photocraft-algo (crates/algo/src/segment/subject.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Select Subject (classical, heuristic): SLIC superpixels on a working copy; per-superpixel
// saliency from boundary connectivity over geodesic colour distances and background-weighted
// contrast, combined by a least-squares smoothness optimisation (Zhu, Liang, Wei & Sun, CVPR
// 2014); blended with frequency-tuned saliency (Achanta et al., CVPR 2009); Otsu's threshold seeds
// a GrabCut trimap; the result is cleaned and re-cut at full resolution. Works for a distinct
// object on a comparatively plain background; not a semantic segmenter. CPU (graph searches,
// Gauss–Seidel and min cuts are sequential).

import Foundation
import PCFoundation

/// Select Subject (photocraft `segment::subject`).
public enum SelectSubject {
    /// Working-resolution budget (pixels).
    public static let workPx = 110_000
    static let sigmaClr: Float = 10
    static let sigmaSpa: Float = 0.25

    /// Selects the most salient object on the canvas.
    public static func select(_ sampler: any SegmentSampler, canvas: PixelRect) -> SelectionRegion? {
        if canvas.width < 4 || canvas.height < 4 { return nil }
        let step = Segment.scaleFor(canvas, maxPx: workPx)
        let img = sampler.rgbScaled(canvas, step: step)
        let w = img.w, h = img.h
        let sal = saliency(img)
        let t = clampf(otsu(sal), 0.15, 0.85)
        var trimap = [UInt8](repeating: GrabCut.prBG, count: w * h)
        var anyFG = false
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let border = x == 0 || y == 0 || x + 1 == w || y + 1 == h
                if sal[i] >= t { anyFG = true; trimap[i] = GrabCut.prFG } else if border || sal[i] < 0.4 * t { trimap[i] = GrabCut.bg } else { trimap[i] = GrabCut.prBG }
            }
        }
        if !anyFG { return nil }
        guard let (fg, bg) = GrabCut.grabcut(img, trimap: &trimap, iters: 6) else { return nil }
        let low = Segment.cleanMask(trimap.map { $0 == GrabCut.prFG || $0 == GrabCut.fg }, w: w, h: h, frac: 0.2, holeFrac: 0.05)
        if !low.contains(true) { return nil }
        return Segment.finishRegion(sampler, window: canvas, step: step, low: low, lw: w, lh: h, models: (fg, bg))
    }

    /// Per-pixel saliency in 0…1 (see the file header).
    public static func saliency(_ img: SegmentRGBImage) -> [Float] {
        let w = img.w, h = img.h
        let lab = img.px.map(SLIC.rgbToLab)
        let target = min(max((w * h) / 150, 16), 400)
        let sp = (try? SLIC.slicLab(lab, w: w, h: h, target: target, compactness: 10, iters: 8)) ?? Superpixels(w: w, h: h, labels: [], count: 0, step: 1)
        let n = sp.count
        // Region statistics.
        var meanD = [SIMD3<Double>](repeating: .zero, count: n)
        var posD = [SIMD2<Double>](repeating: .zero, count: n)
        var cnt = [Double](repeating: 0, count: n)
        var onBorder = [Bool](repeating: false, count: n)
        for y in 0..<h {
            for x in 0..<w {
                let l = Int(sp.labels[y * w + x])
                let c = lab[y * w + x]
                meanD[l].x += Double(c.x); meanD[l].y += Double(c.y); meanD[l].z += Double(c.z)
                posD[l].x += Double(x) / Double(w)
                posD[l].y += Double(y) / Double(h)
                cnt[l] += 1
                if x == 0 || y == 0 || x + 1 == w || y + 1 == h { onBorder[l] = true }
            }
        }
        let mean: [SIMD3<Float>] = (0..<n).map { l in
            let c = Double.maximum(cnt[l], 1)
            return SIMD3(Float(meanD[l].x / c), Float(meanD[l].y / c), Float(meanD[l].z / c))
        }
        let pos: [SIMD2<Float>] = (0..<n).map { l in
            let c = Double.maximum(cnt[l], 1)
            return SIMD2(Float(posD[l].x / c), Float(posD[l].y / c))
        }
        func dapp(_ a: Int, _ b: Int) -> Float { QuickSelection.d2(mean[a], mean[b]).squareRoot() }
        // Adjacency.
        var adj = [[Int]](repeating: [], count: n)
        func link(_ a: Int, _ b: Int) {
            if a != b && !adj[a].contains(b) { adj[a].append(b); adj[b].append(a) }
        }
        for y in 0..<h {
            for x in 0..<w {
                let l = Int(sp.labels[y * w + x])
                if x + 1 < w { link(l, Int(sp.labels[y * w + x + 1])) }
                if y + 1 < h { link(l, Int(sp.labels[(y + 1) * w + x])) }
            }
        }
        // Boundary connectivity from all-pairs geodesic distances (Dijkstra per region).
        var wbg = [Float](repeating: 0, count: n)
        var geo = [Float](repeating: .infinity, count: n)
        for p in 0..<n {
            SegmentKit.dijkstra(p, adj, dapp, &geo)
            var area: Float = 0, len: Float = 0
            for q in 0..<n {
                let s = expf(-geo[q] * geo[q] / (2 * sigmaClr * sigmaClr))
                area += s
                if onBorder[q] { len += s }
            }
            let bnd = len / Float.maximum(area, 1e-6).squareRoot()
            wbg[p] = 1 - expf(-bnd * bnd / 2)
        }
        // Background-weighted contrast.
        var wctr = [Float](repeating: 0, count: n)
        for p in 0..<n {
            var s: Float = 0
            for q in 0..<n {
                let dx = pos[p].x - pos[q].x, dy = pos[p].y - pos[q].y
                let wspa = expf(-(dx * dx + dy * dy) / (2 * sigmaSpa * sigmaSpa))
                s += dapp(p, q) * wspa * wbg[q]
            }
            wctr[p] = s
        }
        let mx = Float.maximum(wctr.reduce(0) { Float.maximum($0, $1) }, 1e-6)
        let wfg = wctr.map { $0 / mx }
        // Saliency optimisation: min Σ wbg s² + Σ wfg (s−1)² + Σ_{i~j} w_ij (s_i − s_j)² (Gauss–Seidel).
        let wij: [[Float]] = (0..<n).map { p in adj[p].map { q in let d = dapp(p, q); return expf(-(d * d) / (2 * sigmaClr * sigmaClr)) + 0.1 } }
        var s = wfg
        for _ in 0..<200 {
            for p in 0..<n {
                var num = wfg[p], den = wbg[p] + wfg[p]
                for (q, wq) in zip(adj[p], wij[p]) { num += wq * s[q]; den += wq }
                s[p] = num / Float.maximum(den, 1e-6)
            }
        }
        // Frequency-tuned saliency.
        var meanAll = SIMD3<Double>.zero
        for c in lab { meanAll.x += Double(c.x); meanAll.y += Double(c.y); meanAll.z += Double(c.z) }
        let cntAll = Double(lab.count)
        let ma = SIMD3(Float(meanAll.x / cntAll), Float(meanAll.y / cntAll), Float(meanAll.z / cntAll))
        let blurred = blurLab(SegmentRGBImage(w: w, h: h, px: lab))
        let ft = blurred.px.map { QuickSelection.d2($0, ma).squareRoot() }
        let ftmax = Float.maximum(ft.reduce(0) { Float.maximum($0, $1) }, 1e-6)
        let smin = s.reduce(Float.greatestFiniteMagnitude) { Float.minimum($0, $1) }
        let smax = s.reduce(-Float.greatestFiniteMagnitude) { Float.maximum($0, $1) }
        let srange = Float.maximum(smax - smin, 1e-6)
        var out = zip(sp.labels, ft).map { l, f in 0.75 * (s[Int(l)] - smin) / srange + 0.25 * f / ftmax }
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for v in out { lo = Float.minimum(lo, v); hi = Float.maximum(hi, v) }
        let r = Float.maximum(hi - lo, 1e-6)
        for i in 0..<out.count { out[i] = (out[i] - lo) / r }
        return out
    }

    /// Two passes of the [1 2 1]/4 kernel each way, edges clamped (photocraft `blur_lab`).
    static func blurLab(_ img: SegmentRGBImage) -> SegmentRGBImage {
        let w = img.w, h = img.h
        var cur = img
        for _ in 0..<2 {
            var tmp = cur
            for y in 0..<h {
                for x in 0..<w {
                    let l = cur.at(x > 0 ? x - 1 : 0, y), c = cur.at(x, y), r = cur.at(min(x + 1, w - 1), y)
                    tmp.px[y * w + x] = SIMD3((l.x + 2 * c.x + r.x) / 4, (l.y + 2 * c.y + r.y) / 4, (l.z + 2 * c.z + r.z) / 4)
                }
            }
            for y in 0..<h {
                for x in 0..<w {
                    let u = tmp.at(x, y > 0 ? y - 1 : 0), c = tmp.at(x, y), d = tmp.at(x, min(y + 1, h - 1))
                    cur.px[y * w + x] = SIMD3((u.x + 2 * c.x + d.x) / 4, (u.y + 2 * c.y + d.y) / 4, (u.z + 2 * c.z + d.z) / 4)
                }
            }
        }
        return cur
    }

    /// Otsu's threshold of values in 0…1 (256 bins).
    public static func otsu(_ v: [Float]) -> Float {
        var hist = [UInt64](repeating: 0, count: 256)
        for x in v { hist[SelectionKit.usizeCast((clampf(x, 0, 1) * 255).rounded())] += 1 }
        let total = Double(v.count)
        var sum = 0.0
        for (i, c) in hist.enumerated() { sum += Double(i) * Double(c) }
        var wb = 0.0, sb = 0.0, best = -1.0, bt = 0
        for (t, c) in hist.enumerated() {
            wb += Double(c)
            if wb == 0 { continue }
            let wf = total - wb
            if wf == 0 { break }
            sb += Double(t) * Double(c)
            let mb = sb / wb, mf = (sum - sb) / wf
            let between = wb * wf * (mb - mf) * (mb - mf)
            if between > best { best = between; bt = t }
        }
        return (Float(bt) + 0.5) / 255
    }
}

extension SegmentKit {
    /// A binary min-heap of (distance, node) with Rust `BinaryHeap<Item>` order (smallest distance
    /// first by `total_cmp`; ties in heap order).
    struct MinHeap {
        var items: [(Float, Int)] = []
        @inline(__always) func less(_ a: (Float, Int), _ b: (Float, Int)) -> Bool { SelectionKit.totalLess(a.0, b.0) }
        mutating func push(_ e: (Float, Int)) {
            items.append(e)
            var i = items.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                if !less(items[i], items[p]) { break }
                items.swapAt(i, p)
                i = p
            }
        }
        mutating func pop() -> (Float, Int)? {
            guard !items.isEmpty else { return nil }
            items.swapAt(0, items.count - 1)
            let top = items.removeLast()
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && less(items[l], items[m]) { m = l }
                if r < items.count && less(items[r], items[m]) { m = r }
                if m == i { break }
                items.swapAt(i, m)
                i = m
            }
            return top
        }
    }

    /// Single-source shortest paths over the region graph (photocraft `dijkstra`).
    static func dijkstra(_ src: Int, _ adj: [[Int]], _ wt: (Int, Int) -> Float, _ dist: inout [Float]) {
        for i in 0..<dist.count { dist[i] = .infinity }
        dist[src] = 0
        var heap = MinHeap()
        heap.push((0, src))
        while let (d, u) = heap.pop() {
            if d > dist[u] { continue }
            for v in adj[u] {
                let nd = d + wt(u, v)
                if nd < dist[v] { dist[v] = nd; heap.push((nd, v)) }
            }
        }
    }
}
