// Port of photocraft-algo (crates/algo/src/perspective.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Edit › Perspective Warp: planes (quads) drawn over the image in Layout mode, whose corners are
// then moved in Warp mode; the image follows a piecewise-homography map (resampled through
// `MeshWarp.warpMeshSurface` with `map`).
//
// Each plane maps its source quad onto its destination quad with `M_i = H_dst ∘ H_src⁻¹` (through
// the unit square, so `(u, v)` are the plane's projective coordinates). Two homographies that agree
// on an edge's endpoints generally space points along it differently, so for every edge shared by
// two planes the average of both planes' images of each edge point is the target, and the
// difference is faded linearly across the plane. The map is exactly continuous across shared edges,
// exactly the homography for a lone plane, and exactly the identity when nothing moved. Points
// outside every plane use the nearest plane, with `(u, v)` clamped for the corrections. Corners
// that coincide (within half a pixel) in the source are linked: they share one destination.

import Foundation

/// A prepared perspective warp (forward map, source → destination) — photocraft `PerspectiveMap`.
public struct PerspectiveMap: Sendable {
    /// One plane: source quad (Layout mode) and destination quad (Warp mode), corners clockwise
    /// from top-left, document pixels (photocraft `Plane`).
    public struct Plane: Hashable, Sendable, Codable {
        public var src: [SIMD2<Double>]
        public var dst: [SIMD2<Double>]
        public init(src: [SIMD2<Double>], dst: [SIMD2<Double>]) {
            precondition(src.count == 4 && dst.count == 4, "a plane has four corners")
            self.src = src; self.dst = dst
        }
        public static func identity(_ q: [SIMD2<Double>]) -> Plane { Plane(src: q, dst: q) }
    }

    /// Straighten modes (Photoshop's Warp-mode buttons).
    public enum Straighten: String, Codable, Sendable, Hashable, CaseIterable {
        case horizontal, vertical, auto

        /// photocraft `Straighten::parse` ("h"/"horizontal"/"level", "v"/"vertical", "auto"/"both").
        public init?(parsing s: String) {
            switch s.lowercased() {
            case "h", "horizontal", "level": self = .horizontal
            case "v", "vertical": self = .vertical
            case "auto", "both": self = .auto
            default: return nil
            }
        }
    }

    struct PlaneMap: Sendable {
        var src: Homography
        var srcInv: Homography
        var dst: Homography
        var quad: [SIMD2<Double>]
        /// For each edge: the neighbouring plane sharing it, if any.
        var shared: [Int?]
    }

    static let linkEps = 0.5
    /// Unit square corners in plane order.
    static let unit: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]

    var planes: [PlaneMap]

    static func unitToQuad(_ q: [SIMD2<Double>]) -> Homography? { Homography.rectToQuad([0, 0, 1, 1], q) }

    /// Groups of linked corners: `(plane, corner)` pairs that coincide in the source.
    public static func linkedCorners(_ planes: [Plane]) -> [[(plane: Int, corner: Int)]] {
        var groups: [[(plane: Int, corner: Int)]] = []
        for (pi, p) in planes.enumerated() {
            for (ci, c) in p.src.enumerated() {
                if let g = groups.firstIndex(where: { g in
                    let o = planes[g[0].plane].src[g[0].corner]
                    return abs(o.x - c.x) <= linkEps && abs(o.y - c.y) <= linkEps
                }) {
                    groups[g].append((pi, ci))
                } else {
                    groups.append([(pi, ci)])
                }
            }
        }
        return groups
    }

    /// Snaps linked corners to one source and one destination position (their means).
    public static func unify(_ planes: inout [Plane]) {
        for g in linkedCorners(planes) where g.count >= 2 {
            let n = Double(g.count)
            var s = SIMD2<Double>(0, 0), d = SIMD2<Double>(0, 0)
            for (p, c) in g {
                s = SIMD2(s.x + planes[p].src[c].x / n, s.y + planes[p].src[c].y / n)
                d = SIMD2(d.x + planes[p].dst[c].x / n, d.y + planes[p].dst[c].y / n)
            }
            for (p, c) in g {
                planes[p].src[c] = s
                planes[p].dst[c] = d
            }
        }
    }

    /// Edge `k` of a plane runs from corner `k` to corner `k + 1`: (point on the edge in plane
    /// coordinates, weight of that edge's correction).
    static func edgeUV(_ k: Int, _ u: Double, _ v: Double) -> (SIMD2<Double>, Double) {
        switch k {
        case 0: return (SIMD2(u, 0), 1 - v)
        case 1: return (SIMD2(1, v), u)
        case 2: return (SIMD2(u, 1), v)
        default: return (SIMD2(0, v), 1 - u)
        }
    }

    /// Makes the destination edges that are near-horizontal exactly horizontal and/or near-vertical
    /// exactly vertical (within 45°), moving linked corners together.
    public static func straighten(_ planes: inout [Plane], mode: Straighten) {
        unify(&planes)
        let groups = linkedCorners(planes)
        func groupOf(_ p: Int, _ c: Int) -> Int {
            groups.firstIndex { g in g.contains { $0.plane == p && $0.corner == c } } ?? 0
        }
        var pos = groups.map { planes[$0[0].plane].dst[$0[0].corner] }
        var edges: [(Int, Int)] = []
        for p in 0..<planes.count { for k in 0..<4 { edges.append((groupOf(p, k), groupOf(p, (k + 1) % 4))) } }
        for (a, b) in edges {
            let pa = pos[a], pb = pos[b]
            let dx = abs(pb.x - pa.x), dy = abs(pb.y - pa.y)
            if dy <= dx && (mode == .horizontal || mode == .auto) {
                let y = (pa.y + pb.y) / 2
                pos[a].y = y; pos[b].y = y
            } else if dx < dy && (mode == .vertical || mode == .auto) {
                let x = (pa.x + pb.x) / 2
                pos[a].x = x; pos[b].x = x
            }
        }
        for (g, p) in zip(groups, pos) { for (pi, ci) in g { planes[pi].dst[ci] = p } }
    }

    /// Prepares the map; nil if a quad is degenerate (or there are no planes).
    public init?(planes input: [Plane]) {
        if input.isEmpty { return nil }
        var planes = input
        PerspectiveMap.unify(&planes)
        func near(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
            abs(a.x - b.x) <= PerspectiveMap.linkEps && abs(a.y - b.y) <= PerspectiveMap.linkEps
        }
        var maps: [PlaneMap] = []
        for (i, p) in planes.enumerated() {
            guard let src = PerspectiveMap.unitToQuad(p.src), let srcInv = src.inverse(), let dst = PerspectiveMap.unitToQuad(p.dst) else { return nil }
            var shared: [Int?] = [nil, nil, nil, nil]
            for k in 0..<4 {
                let a = p.src[k], b = p.src[(k + 1) % 4]
                shared[k] = planes.enumerated().first { j, o in
                    j != i && (0..<4).contains { m in
                        let c = o.src[m], d = o.src[(m + 1) % 4]
                        return (near(a, c) && near(b, d)) || (near(a, d) && near(b, c))
                    }
                }?.offset
            }
            maps.append(PlaneMap(src: src, srcInv: srcInv, dst: dst, quad: p.src, shared: shared))
        }
        self.planes = maps
    }

    /// The plane containing `p` (or the nearest one) and `p`'s plane coordinates.
    func locate(_ x: Double, _ y: Double) -> (Int, Double, Double) {
        var best = (0, Double.greatestFiniteMagnitude, 0.0, 0.0)
        for (i, pm) in planes.enumerated() {
            let (u, v) = pm.srcInv.apply(x, y)
            if u >= -1e-9 && u <= 1 + 1e-9 && v >= -1e-9 && v <= 1 + 1e-9 { return (i, u, v) }
            let d = PerspectiveMap.distToQuad(pm.quad, SIMD2(x, y))
            if d < best.1 { best = (i, d, u, v) }
        }
        return (best.0, best.2, best.3)
    }

    /// Maps a source point to the destination.
    public func map(_ x: Double, _ y: Double) -> (Double, Double) {
        let (i, u, v) = locate(x, y)
        let pm = planes[i]
        var (ox, oy) = pm.dst.apply(u, v)
        if !ox.isFinite || !oy.isFinite { return (x, y) }
        let cu = min(max(u, 0), 1), cv = min(max(v, 0), 1)
        for (k, sh) in pm.shared.enumerated() {
            guard let j = sh else { continue }
            let (e, w) = PerspectiveMap.edgeUV(k, cu, cv)
            if w <= 0 { continue }
            let mine = pm.dst.apply(e.x, e.y)
            let (qx, qy) = pm.src.apply(e.x, e.y)
            let other = planes[j]
            let (ou, ov) = other.srcInv.apply(qx, qy)
            let theirs = other.dst.apply(ou, ov)
            let target = ((mine.0 + theirs.0) / 2, (mine.1 + theirs.1) / 2)
            ox += w * (target.0 - mine.0)
            oy += w * (target.1 - mine.1)
        }
        return (ox, oy)
    }

    /// Whether every plane maps onto itself (identity).
    public static func isIdentity(_ planes: [Plane]) -> Bool {
        planes.allSatisfy { p in zip(p.src, p.dst).allSatisfy { abs($0.x - $1.x) < 1e-9 && abs($0.y - $1.y) < 1e-9 } }
    }

    static func distToQuad(_ q: [SIMD2<Double>], _ p: SIMD2<Double>) -> Double {
        var best = Double.greatestFiniteMagnitude
        for k in 0..<4 {
            let a = q[k], b = q[(k + 1) % 4]
            let dx = b.x - a.x, dy = b.y - a.y
            let l2 = dx * dx + dy * dy
            let t = l2 > 0 ? min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / l2, 0), 1) : 0
            let ex = a.x + t * dx - p.x, ey = a.y + t * dy - p.y
            best = min(best, (ex * ex + ey * ey).squareRoot())
        }
        return best
    }

    /// Corners of the unit square in plane order (for callers drawing plane grids).
    public static func unitCorners() -> [SIMD2<Double>] { unit }

    /// A point of plane `p` at plane coordinates `(u, v)`, in source (or, with `dst`, destination)
    /// space.
    public static func planePoint(_ p: Plane, u: Double, v: Double, dst: Bool) -> SIMD2<Double> {
        let q = dst ? p.dst : p.src
        guard let h = unitToQuad(q) else { return q[0] }
        let (x, y) = h.apply(u, v)
        return SIMD2(x, y)
    }
}
