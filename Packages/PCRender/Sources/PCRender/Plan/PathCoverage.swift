// Port of photocraft-vector (crates/vector/src/raster.rs, flatten.rs, lib.rs `fill_rasterizer` / `path_coverage`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Exact-area fill coverage of a vector path, built into PCRender so vector masks and filled-shape
// effect outlines render without a platform rasterizer (a `LayerRasterizer` that returns coverage
// still takes precedence). Each pixel row is cut into sub-bands at every edge endpoint and
// crossing, so inside a sub-band the active edges keep their order; walking them with one winding
// counter per path component gives the inside intervals of the combined shape (fill rule per
// component, folded with Photoshop's path operations), whose boundary edges are accumulated as
// signed trapezoid areas into a cell buffer. Its prefix sum is each pixel's exact covered area.

import Foundation
import PCDocument
import PCFoundation

public enum PathCoverage {
    /// Flattening tolerance (photocraft `DEFAULT_TOLERANCE`).
    public static let defaultTolerance = 0.01

    /// Fill coverage (0…1, row-major over `rect`) of `path`: one component per shape component,
    /// filled with the path's rule and folded with its operations; `inverted` inverts the result.
    public static func coverage(of path: VectorPath, in rect: PixelRect) -> [Float] {
        rasterizer(path).render(rect)
    }

    /// `fill_rasterizer`.
    static func rasterizer(_ path: VectorPath, tolerance: Double = defaultTolerance) -> PathRasterizer {
        var r = PathRasterizer(inverted: path.inverted)
        for c in path.components {
            let polys = path.subpaths[c].map { flatten($0, tolerance) }
            r.addComponent(polys, op: path.effectiveOp(c.lowerBound), rule: path.fillRule)
        }
        return r
    }

    // MARK: Flattening (flatten.rs)

    static func isLine(_ s: [PCPoint]) -> Bool {
        let (p0, c1, c2, p1) = (s[0], s[1], s[2], s[3])
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let len2 = dx * dx + dy * dy
        func onChord(_ c: PCPoint) -> Bool {
            let vx = c.x - p0.x, vy = c.y - p0.y
            if len2 < 1e-24 { return abs(vx) < 1e-9 && abs(vy) < 1e-9 }
            let t = (vx * dx + vy * dy) / len2
            let cross = abs(vx * dy - vy * dx) / len2.squareRoot()
            return cross < 1e-9 && t >= -1e-9 && t <= 1 + 1e-9
        }
        return onChord(c1) && onChord(c2)
    }

    static func pieces(_ s: [PCPoint], _ tol: Double) -> Int {
        let (p0, c1, c2, p1) = (s[0], s[1], s[2], s[3])
        let d1 = ((p0.x - 2 * c1.x + c2.x) * (p0.x - 2 * c1.x + c2.x) + (p0.y - 2 * c1.y + c2.y) * (p0.y - 2 * c1.y + c2.y)).squareRoot()
        let d2 = ((c1.x - 2 * c2.x + p1.x) * (c1.x - 2 * c2.x + p1.x) + (c1.y - 2 * c2.y + p1.y) * (c1.y - 2 * c2.y + p1.y)).squareRoot()
        let m = max(d1, d2)
        let size = hypot(c1.x - p0.x, c1.y - p0.y) + hypot(c2.x - c1.x, c2.y - c1.y) + hypot(p1.x - c2.x, p1.y - c2.y)
        let t = max(min(tol, size * 1e-3), 1e-4)
        let n = (0.75 * m / t).squareRoot().rounded(.up)
        return n.isFinite ? min(max(Int(n), 1), 1 << 16) : 1
    }

    static func eval(_ s: [PCPoint], _ t: Double) -> (Double, Double) {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return (a * s[0].x + b * s[1].x + c * s[2].x + d * s[3].x, a * s[0].y + b * s[1].y + c * s[2].y + d * s[3].y)
    }

    /// `flatten_subpath` (points only; closed subpaths don't repeat their first point).
    static func flatten(_ sp: Subpath, _ tol: Double) -> [(Double, Double)] {
        var pts: [(Double, Double)] = []
        func push(_ p: (Double, Double)) {
            if let l = pts.last, abs(l.0 - p.0) < 1e-12, abs(l.1 - p.1) < 1e-12 { return }
            pts.append(p)
        }
        if let k = sp.knots.first { push((k.anchor.x, k.anchor.y)) }
        for seg in sp.segments {
            if isLine(seg) { push((seg[3].x, seg[3].y)); continue }
            let n = pieces(seg, tol)
            for j in 1...n { push(eval(seg, Double(j) / Double(n))) }
        }
        if sp.closed && pts.count > 1, let a = pts.first, let b = pts.last, abs(a.0 - b.0) < 1e-12, abs(a.1 - b.1) < 1e-12 { pts.removeLast() }
        return pts
    }
}

/// `raster.rs` `Rasterizer`: compiled polygons that render exact coverage for any rectangle.
struct PathRasterizer: Sendable {
    struct Edge: Sendable {
        var x0, y0, y1: Double
        var dir: Int32
        var comp: Int
        var dxdy: Double
        @inline(__always) func x(at y: Double) -> Double { x0 + (y - y0) * dxdy }
    }

    var edges: [Edge] = []
    var comps: [(op: PathOp, rule: FillRule)] = []
    var inverted: Bool
    var bounds: (Double, Double, Double, Double)?
    /// Every component combines: inside = any component inside.
    var unionOnly = true

    init(inverted: Bool) { self.inverted = inverted }

    mutating func addComponent(_ polys: [[(Double, Double)]], op: PathOp, rule: FillRule) {
        let comp = comps.count
        comps.append((op, rule))
        if op != .combine && comp != 0 { unionOnly = false }
        for poly in polys {
            let n = poly.count
            if n < 2 { continue }
            for i in 0..<n {
                let a = poly[i], b = poly[(i + 1) % n]
                if !(a.0.isFinite && a.1.isFinite && b.0.isFinite && b.1.isFinite) { continue }
                if let bb = bounds {
                    bounds = (min(bb.0, a.0, b.0), min(bb.1, a.1, b.1), max(bb.2, a.0, b.0), max(bb.3, a.1, b.1))
                } else {
                    bounds = (min(a.0, b.0), min(a.1, b.1), max(a.0, b.0), max(a.1, b.1))
                }
                if a.1 == b.1 { continue }
                let (p, q, dir): ((Double, Double), (Double, Double), Int32) = a.1 < b.1 ? (a, b, 1) : (b, a, -1)
                edges.append(Edge(x0: p.0, y0: p.1, y1: q.1, dir: dir, comp: comp, dxdy: (q.0 - p.0) / (q.1 - p.1)))
            }
        }
        edges.sort { $0.y0 < $1.y0 }
    }

    @inline(__always) func compInside(_ c: Int, _ w: Int32) -> Bool {
        comps[c].rule == .nonZero ? w != 0 : w & 1 != 0
    }

    func inside(_ wind: [Int32], _ unionCount: Int32) -> Bool {
        if unionOnly { return (unionCount > 0) != inverted }
        var acc = false
        for i in comps.indices {
            let v = compInside(i, wind[i])
            switch i == 0 ? PathOp.combine : comps[i].op {
            case .combine, .join: acc = acc || v
            case .subtract: acc = acc && !v
            case .intersect: acc = acc && v
            case .exclude: acc = acc != v
            }
        }
        return acc != inverted
    }

    /// Coverage of every pixel of `rect`, row-major (strips of rows in parallel).
    func render(_ rect: PixelRect) -> [Float] {
        let w = rect.width, h = rect.height
        var out = [Float](repeating: 0, count: w * h)
        if w == 0 || h == 0 { return out }
        let strip = 32
        let strips = (h + strip - 1) / strip
        out.withUnsafeMutableBufferPointer { op in
            let O = UnsafeSendable(op)
            let run: @Sendable (Int) -> Void = { i in
                let y0 = rect.y0 + Int32(i * strip)
                let rows = min(strip, h - i * strip)
                let sub = PixelRect(x0: rect.x0, y0: y0, x1: rect.x1, y1: y0 + Int32(rows))
                let base = O.value.baseAddress! + i * strip * w
                self.renderInto(sub, UnsafeMutableBufferPointer(start: base, count: rows * w))
            }
            if strips > 1 && w * h > 64 * 1024 {
                DispatchQueue.concurrentPerform(iterations: strips, execute: run)
            } else {
                for i in 0..<strips { run(i) }
            }
        }
        return out
    }

    struct RowState {
        var active: [Int] = []
        var cuts: [Double] = []
        var band: [(xa: Double, xb: Double, xm: Double, idx: Int)] = []
        var wind: [Int32]
        var acc: [Float]
    }

    func renderInto(_ rect: PixelRect, _ out: UnsafeMutableBufferPointer<Float>) {
        let w = rect.width
        var st = RowState(wind: [Int32](repeating: 0, count: max(comps.count, 1)), acc: [Float](repeating: 0, count: w + 1))
        let top = Double(rect.y0)
        var next = edges.firstIndex { $0.y0 >= top } ?? edges.count
        st.active = (0..<next).filter { edges[$0].y1 > top }
        for (row, y) in (rect.y0..<rect.y1).enumerated() {
            let ya = Double(y), yb = Double(y) + 1
            st.active.removeAll { edges[$0].y1 <= ya }
            while next < edges.count && edges[next].y0 < yb {
                if edges[next].y1 > ya { st.active.append(next) }
                next += 1
            }
            for i in st.acc.indices { st.acc[i] = 0 }
            if st.active.isEmpty {
                let v: Float = inverted ? 1 : 0
                for i in 0..<w { out[row * w + i] = v }
                continue
            }
            st.cuts.removeAll(keepingCapacity: true)
            st.cuts.append(ya); st.cuts.append(yb)
            for i in st.active {
                let e = edges[i]
                if e.y0 > ya && e.y0 < yb { st.cuts.append(e.y0) }
                if e.y1 > ya && e.y1 < yb { st.cuts.append(e.y1) }
            }
            st.cuts.sort()
            var cuts: [Double] = []
            for c in st.cuts where cuts.last != c { cuts.append(c) }
            for k in 0..<(cuts.count - 1) { band(cuts[k], cuts[k + 1], rect.x0, &st, 0) }
            var sum: Float = 0
            for i in 0..<w {
                sum += st.acc[i]
                // Opposite boundaries leave ~1e-7 past a right edge (and NaN): snap to 0.
                out[row * w + i] = sum >= 1e-6 ? min(sum, 1) : 0
            }
        }
    }

    func band(_ a: Double, _ b: Double, _ x0: Int32, _ st: inout RowState, _ depth: Int) {
        if b - a <= 1e-12 { return }
        st.band.removeAll(keepingCapacity: true)
        let mid = 0.5 * (a + b)
        for i in st.active {
            let e = edges[i]
            if e.y0 <= mid && e.y1 >= mid {
                let xa = e.x(at: a), xb = e.x(at: b)
                st.band.append((xa, xb, 0.5 * (xa + xb), i))
            }
        }
        if st.band.isEmpty {
            if inverted { st.acc[0] += Float(b - a) }
            return
        }
        st.band.sort { $0.xm < $1.xm }
        if depth < 24 {
            for k in 1..<st.band.count {
                let p = st.band[k - 1], q = st.band[k]
                let topD = p.xa - q.xa, botD = p.xb - q.xb
                if topD > 1e-9 || botD > 1e-9 {
                    let t = abs(topD - botD) > 1e-15 ? topD / (topD - botD) : 0.5
                    var y = a + (b - a) * min(max(t, 0), 1)
                    if y <= a + 1e-9 || y >= b - 1e-9 { y = mid }
                    band(a, y, x0, &st, depth + 1)
                    band(y, b, x0, &st, depth + 1)
                    return
                }
            }
        }
        for i in st.wind.indices { st.wind[i] = 0 }
        var unionCount: Int32 = 0
        var isInside = inverted
        if isInside { st.acc[0] += Float(b - a) }
        for be in st.band {
            let e = edges[be.idx]
            let c = e.comp
            if unionOnly {
                let was = compInside(c, st.wind[c])
                st.wind[c] += e.dir
                let now = compInside(c, st.wind[c])
                unionCount += (now ? 1 : 0) - (was ? 1 : 0)
            } else {
                st.wind[c] += e.dir
            }
            let now = inside(st.wind, unionCount)
            if now != isInside {
                PathRasterizer.draw(&st.acc, x0, be.xa, a, be.xb, b, now ? 1 : -1)
                isInside = now
            }
        }
    }

    /// Adds `w` × the area right of the segment (xa, ya) → (xb, yb) (inside one row) to the cells.
    static func draw(_ acc: inout [Float], _ x0: Int32, _ xa: Double, _ ya: Double, _ xb: Double, _ yb: Double, _ w: Double) {
        let width = Double(acc.count - 1)
        let left = Double(x0)
        var ua = xa - left, ub = xb - left
        let dy = yb - ya
        if dy <= 0 { return }
        if ua > ub { swap(&ua, &ub) }
        let dx = ub - ua
        func hOf(_ u0: Double, _ u1: Double) -> Double { dx > 1e-12 ? dy * (u1 - u0) / dx : dy }
        if ua < 0 {
            let cut = min(ub, 0)
            acc[0] += Float(w * hOf(ua, cut))
            if ub <= 0 { return }
            ua = 0
        }
        if ua >= width { return }
        let end = min(ub, width)
        if dx <= 1e-12 {
            let c = ua.rounded(.down)
            let f = ua - c
            let ci = Int(c)
            acc[ci] += Float(w * dy * (1 - f))
            acc[ci + 1] += Float(w * dy * f)
            return
        }
        var u = ua
        while u < end {
            let c = u.rounded(.down)
            let v = min(c + 1, end)
            let h = hOf(u, v)
            let m = 0.5 * (u + v) - c
            let ci = Int(c)
            acc[ci] += Float(w * h * (1 - m))
            acc[ci + 1] += Float(w * h * m)
            if v <= u { break }
            u = v
        }
    }
}
