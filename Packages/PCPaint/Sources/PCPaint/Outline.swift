// Port of photocraft-paint (crates/paint/src/outline.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Brush tip outlines for the painting cursor: closed rings in units of the brush radius (1 = size
// / 2), screen-oriented (x right, y down), ready for the UI to scale by the radius. `tipOutlinePath`
// turns them into a CGPath for an overlay (the cursor-shape-as-a-path the canvas draws).

import CoreGraphics
import Foundation

public enum BrushOutline {
    /// Segments in the outline of a computed round tip.
    static let ellipseSegments = 64
    /// Budget for all traced ring vertices; the smallest rings are dropped first.
    static let maxPoints = 512
    /// A traced ring smaller than this many bitmap pixels squared is noise.
    static let minArea: Float = 0.9
    /// "Full size" outlines everything above 1/255; the normal cursor outlines the 50 % contour.
    static let fullThreshold: Float = 1.0 / 255.0
    static let halfThreshold: Float = 0.5

    /// The tip outline as closed rings, or nil when the tip has no usable shape. `full` outlines the
    /// whole tip; otherwise the 50 % contour (the Photoshop normal brush tip cursor).
    public static func tipOutline(_ b: BrushSettings, full: Bool) -> [[SIMD2<Float>]]? {
        if !b.size.isFinite || b.size <= 0 || !b.angle.isFinite || !b.roundness.isFinite { return nil }
        let ro = minR(maxR(clampR(b.roundness, 0, 1), 0.5 / (b.size / 2)), 1)
        let rad = toRadians(b.angle)
        let sn = sinf(rad), cs = cosf(rad)
        let fx: Float = b.flipX ? -1 : 1, fy: Float = b.flipY ? -1 : 1
        switch b.tip {
        case .round:
            // The normal cursor is the 50 % contour: the soft tip falls off as (1 − t²)⁴.
            let f: Float = full ? 1 : halfCoverageRadius(1, b.hardness)
            let ring = (0..<ellipseSegments).map { i -> SIMD2<Float> in
                let t = 2 * Float.pi * Float(i) / Float(ellipseSegments)
                // Tip-local (y up), rotated CCW by the angle, then flipped to screen y down.
                let lx = cosf(t) * f, ly = sinf(t) * f * ro
                return SIMD2(lx * cs - ly * sn, -(lx * sn + ly * cs))
            }
            return [ring]
        case .sampled, .stored:
            guard let t = b.tip.bitmap, t.isValid else { return nil }
            return trace(t, full ? fullThreshold : halfThreshold, sn, cs, fx, fy, ro)
        }
    }

    /// The outline as a CGPath in document units around `center`, scaled by the brush radius
    /// (`size / 2`), for a canvas overlay. Nil when the tip has no usable shape.
    public static func tipOutlinePath(_ b: BrushSettings, full: Bool, center: CGPoint = .zero, radius: CGFloat? = nil) -> CGPath? {
        guard let rings = tipOutline(b, full: full) else { return nil }
        let r = radius ?? CGFloat(b.size / 2)
        let path = CGMutablePath()
        for ring in rings where ring.count >= 3 {
            path.move(to: CGPoint(x: center.x + CGFloat(ring[0].x) * r, y: center.y + CGFloat(ring[0].y) * r))
            for p in ring.dropFirst() { path.addLine(to: CGPoint(x: center.x + CGFloat(p.x) * r, y: center.y + CGFloat(p.y) * r)) }
            path.closeSubpath()
        }
        return path
    }

    /// Trace the contour(s) above `thr` (resampled ~2×, capped at 160 px a side) and map them with
    /// the same tip transform as `BrushContext.rasterize`.
    static func trace(_ t: GrayTile, _ thr: Float, _ sn: Float, _ cs: Float, _ fx: Float, _ fy: Float, _ ro: Float) -> [[SIMD2<Float>]]? {
        let tw = Float(t.width), th = Float(t.height)
        let big = maxR(tw, th)
        let f: Float = big <= 160 ? 2 : 160 / big
        let gw = max(asUsize((tw * f).rounded(.up)), 1), gh = max(asUsize((th * f).rounded(.up)), 1)
        var vals = [Float](repeating: 0, count: gw * gh)
        for gy in 0..<gh {
            for gx in 0..<gw {
                let px = (Float(gx) + 0.5) / f - 0.5, py = (Float(gy) + 0.5) / f - 0.5
                vals[gy * gw + gx] = sample(t, px, py)
            }
        }
        var rings = march(vals, gw, gh, thr).filter { area($0) >= minArea * f * f }
        if rings.isEmpty { return nil }
        rings.sort { area($0) > area($1) }
        var tol: Float = 0.5
        var thin: [[SIMD2<Float>]]
        while true {
            thin = rings.map { simplify($0, tol) }
            if thin.reduce(0, { $0 + $1.count }) <= maxPoints || tol >= 8 { break }
            tol *= 1.5
        }
        var budget = maxPoints
        thin = thin.filter { r in
            let keep = r.count >= 3 && r.count <= budget
            if keep { budget -= r.count }
            return keep
        }
        if thin.isEmpty { return nil }
        let s = 2 / big
        func map(_ g: SIMD2<Float>) -> SIMD2<Float> {
            let px = (g.x + 0.5) / f - 0.5, py = (g.y + 0.5) / f - 0.5
            let u = (px - tw / 2) * s * fx, v = -(py - th / 2) * s * ro * fy
            let ux = u * cs - v * sn, uy = u * sn + v * cs
            return SIMD2(ux, -uy)
        }
        let out = thin.map { $0.map(map) }
        return out.allSatisfy({ $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) ? out : nil
    }

    /// Bilinear sample with zero outside (tips fade to nothing at their edges).
    static func sample(_ t: GrayTile, _ x: Float, _ y: Float) -> Float {
        let x0f = x.rounded(.down), y0f = y.rounded(.down)
        let tx = x - x0f, ty = y - y0f
        let x0 = asI64(x0f), y0 = asI64(y0f)
        func get(_ x: Int64, _ y: Int64) -> Float {
            (x < 0 || y < 0 || x >= Int64(t.width) || y >= Int64(t.height)) ? 0 : t.get(UInt32(x), UInt32(y))
        }
        let a = get(x0, y0) + (get(x0 + 1, y0) - get(x0, y0)) * tx
        let b = get(x0, y0 + 1) + (get(x0 + 1, y0 + 1) - get(x0, y0 + 1)) * tx
        return a + (b - a) * ty
    }

    /// Shoelace area of a ring.
    static func area(_ r: [SIMD2<Float>]) -> Float {
        if r.count < 3 { return 0 }
        var s: Float = 0
        for i in 0..<r.count {
            let a = r[i], b = r[(i + 1) % r.count]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s * 0.5)
    }

    struct EndKey: Hashable { var x: Int64; var y: Int64 }

    /// Link segments end-to-end into closed rings (quantised endpoint keys absorb float noise).
    static func stitch(_ segs: [(SIMD2<Float>, SIMD2<Float>)]) -> [[SIMD2<Float>]] {
        func key(_ p: SIMD2<Float>) -> EndKey { EndKey(x: asI64((p.x * 4096).rounded()), y: asI64((p.y * 4096).rounded())) }
        var ends: [EndKey: [Int]] = [:]
        for (i, s) in segs.enumerated() {
            ends[key(s.0), default: []].append(i)
            ends[key(s.1), default: []].append(i)
        }
        var used = [Bool](repeating: false, count: segs.count)
        var rings: [[SIMD2<Float>]] = []
        for s in segs.indices {
            if used[s] { continue }
            used[s] = true
            var ring = [segs[s].0, segs[s].1]
            while let tail = ring.last {
                guard let next = ends[key(tail)]?.first(where: { !used[$0] }) else { break }
                used[next] = true
                let (a, b) = segs[next]
                let p = key(a) == key(tail) ? b : a
                if key(p) == key(ring[0]) { break }
                ring.append(p)
            }
            if ring.count >= 3 { rings.append(ring) }
        }
        return rings
    }

    /// Marching squares over `v` (w × h samples at lattice nodes), outside treated as 0 so every
    /// contour closes; returns rings in node coordinates.
    static func march(_ v: [Float], _ w: Int, _ h: Int, _ thr: Float) -> [[SIMD2<Float>]] {
        func val(_ x: Int, _ y: Int) -> Float { (x < 0 || y < 0 || x >= w || y >= h) ? 0 : v[y * w + x] }
        func lerp(_ v0: Float, _ v1: Float, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
            let t: Float = abs(v1 - v0) < 1e-9 ? 0.5 : clampR((thr - v0) / (v1 - v0), 0, 1)
            return a + (b - a) * t
        }
        var segs: [(SIMD2<Float>, SIMD2<Float>)] = []
        for y in -1..<h {
            for x in -1..<w {
                let va = val(x, y), vb = val(x + 1, y), vc = val(x + 1, y + 1), vd = val(x, y + 1)
                let idx = (va >= thr ? 1 : 0) | (vb >= thr ? 2 : 0) | (vc >= thr ? 4 : 0) | (vd >= thr ? 8 : 0)
                if idx == 0 || idx == 15 { continue }
                let fx = Float(x), fy = Float(y)
                let top = lerp(va, vb, SIMD2(fx, fy), SIMD2(fx + 1, fy))
                let right = lerp(vb, vc, SIMD2(fx + 1, fy), SIMD2(fx + 1, fy + 1))
                let bottom = lerp(vd, vc, SIMD2(fx, fy + 1), SIMD2(fx + 1, fy + 1))
                let left = lerp(va, vd, SIMD2(fx, fy), SIMD2(fx, fy + 1))
                let mid = (va + vb + vc + vd) * 0.25 >= thr
                switch idx {
                case 1, 14: segs.append((top, left))
                case 2, 13: segs.append((top, right))
                case 3, 12: segs.append((right, left))
                case 4, 11: segs.append((right, bottom))
                case 6, 9: segs.append((top, bottom))
                case 7, 8: segs.append((left, bottom))
                case 5, 10:
                    let opposite = (idx == 5) != mid
                    if opposite {
                        segs.append((top, right)); segs.append((left, bottom))
                    } else {
                        segs.append((top, left)); segs.append((right, bottom))
                    }
                default: break
                }
            }
        }
        return stitch(segs)
    }

    /// Douglas–Peucker on a closed ring (split at the point farthest from the first).
    static func simplify(_ ring: [SIMD2<Float>], _ tol: Float) -> [SIMD2<Float>] {
        if ring.count <= 4 { return ring }
        var far = 0
        var best: Float = 0
        for i in 1..<ring.count {
            let p = ring[i]
            let d = (p.x - ring[0].x) * (p.x - ring[0].x) + (p.y - ring[0].y) * (p.y - ring[0].y)
            if d > best { best = d; far = i }
        }
        var open = Array(ring[far...])
        open.append(ring[0])
        var out: [SIMD2<Float>] = []
        dp(Array(ring[0...far]), tol, &out)
        _ = out.popLast()
        dp(open, tol, &out)
        _ = out.popLast()
        return out
    }

    /// Iterative Douglas–Peucker: keep the points of `pts` farther than `tol` from the chord.
    static func dp(_ pts: [SIMD2<Float>], _ tol: Float, _ out: inout [SIMD2<Float>]) {
        let n = pts.count
        if n == 0 { return }
        if n < 3 { out.append(contentsOf: pts); return }
        var keep = [Bool](repeating: false, count: n)
        keep[0] = true
        keep[n - 1] = true
        var stack = [(0, n - 1)]
        while let (i, j) = stack.popLast() {
            if j <= i + 1 { continue }
            var dmax: Float = 0, k = i
            for m in (i + 1)..<j {
                let d = segDist2(pts[m], pts[i], pts[j])
                if d > dmax { dmax = d; k = m }
            }
            if dmax > tol * tol {
                keep[k] = true
                stack.append((i, k))
                stack.append((k, j))
            }
        }
        for (i, p) in pts.enumerated() where keep[i] { out.append(p) }
    }

    /// Squared distance from `p` to the segment `a`–`b`.
    static func segDist2(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let abx = b.x - a.x, aby = b.y - a.y
        let t = clampR(((p.x - a.x) * abx + (p.y - a.y) * aby) / maxR(abx * abx + aby * aby, 1e-12), 0, 1)
        let ex = p.x - a.x - abx * t, ey = p.y - a.y - aby * t
        return ex * ex + ey * ey
    }
}
