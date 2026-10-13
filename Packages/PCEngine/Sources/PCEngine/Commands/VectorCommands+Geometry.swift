// Port of photocraft-engine (crates/engine/src/vector_cmds.rs) helpers: photocraft-vector's flatten.rs (`validate_shape`, `flatten_path`), map.rs (`map_points`, `map_path`), trace.rs (`trace_mask`) and edit.rs (point-level edits), photocraft-algo's `transform::Homography` and the reference `selection_blur::feather`, and warp_cmds.rs `warp_from_params`, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The pure path geometry the vector commands need that PCPlatform's CoreGraphics engine doesn't
// provide, ported as CPU references inside the module (PCAlgo may replace the feather and the
// homography later through the same signatures). Everything is bounds-checked: bad indices are
// errors, never traps.

import Foundation
import PCDocument
import PCFoundation
import simd

extension VectorCommands {
    /// A geometry failure (photocraft's `Err(String)`), turned into a bad-params error by callers.
    struct GeometryError: Error, Sendable { var message: String }

    /// photocraft-vector `DEFAULT_TOLERANCE`.
    static let defaultTolerance = 0.01

    // MARK: - flatten.rs

    /// A flattened subpath (photocraft-vector `Polyline`).
    struct Polyline: Sendable, Equatable {
        var pts: [SIMD2<Double>] = []
        /// Points that are knots of the source path.
        var knot: [Bool] = []
        var closed = false

        mutating func push(_ p: SIMD2<Double>, _ isKnot: Bool) {
            if let last = pts.last, abs(last.x - p.x) < 1e-12, abs(last.y - p.y) < 1e-12 {
                if isKnot, !knot.isEmpty { knot[knot.count - 1] = true }
                return
            }
            pts.append(p)
            knot.append(isKnot)
        }
    }

    /// Straight segment: both control points on the chord (within 1e-9 px) between its ends.
    static func isLine(_ seg: [PCPoint]) -> Bool {
        guard seg.count == 4 else { return true }
        let (p0, c1, c2, p1) = (seg[0], seg[1], seg[2], seg[3])
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

    /// Uniform pieces so that the chord deviation of the cubic is at most `tol`.
    static func pieces(_ seg: [PCPoint], _ tol: Double) -> Int {
        guard seg.count == 4 else { return 1 }
        let (p0, c1, c2, p1) = (seg[0], seg[1], seg[2], seg[3])
        let d1 = ((p0.x - 2 * c1.x + c2.x) * (p0.x - 2 * c1.x + c2.x) + (p0.y - 2 * c1.y + c2.y) * (p0.y - 2 * c1.y + c2.y)).squareRoot()
        let d2 = ((c1.x - 2 * c2.x + p1.x) * (c1.x - 2 * c2.x + p1.x) + (c1.y - 2 * c2.y + p1.y) * (c1.y - 2 * c2.y + p1.y)).squareRoot()
        let m = max(d1, d2)
        let size = hypot(c1.x - p0.x, c1.y - p0.y) + hypot(c2.x - c1.x, c2.y - c1.y) + hypot(p1.x - c2.x, p1.y - c2.y)
        let t = max(min(tol, size * 1e-3), 1e-4)
        let n = (0.75 * m / t).squareRoot().rounded(.up)
        guard n.isFinite else { return 1 }
        return Int(min(max(n, 1), 65536))
    }

    static func evalCubic(_ seg: [PCPoint], _ t: Double) -> SIMD2<Double> {
        let mt = 1 - t
        let a = mt * mt * mt, b = 3 * mt * mt * t, c = 3 * mt * t * t, d = t * t * t
        return SIMD2(a * seg[0].x + b * seg[1].x + c * seg[2].x + d * seg[3].x, a * seg[0].y + b * seg[1].y + c * seg[2].y + d * seg[3].y)
    }

    /// photocraft-vector `validate_shape`: finite coordinates and a bounded tessellation and dash
    /// workload, checked before rendering. nil when the shape is fine, else why not.
    static func validateShape(_ path: VectorPath, _ stroke: ShapeStroke?) -> String? {
        let knots = path.subpaths.reduce(0) { $0 + $1.knots.count }
        if knots > 4096 || path.subpaths.count > 4096 { return "shape path exceeds 4096 knots/subpaths" }
        var points = 0
        var length = 0.0
        for sub in path.subpaths {
            for k in sub.knots {
                for p in [k.anchor, k.inCtrl, k.outCtrl] where !p.x.isFinite || !p.y.isFinite || abs(p.x) > 1_000_000 || abs(p.y) > 1_000_000 {
                    return "shape coordinates must be finite and within ±1000000 px"
                }
            }
            points += 1
            for seg in sub.segments {
                points += isLine(seg) ? 1 : pieces(seg, defaultTolerance)
                for i in 1..<seg.count { length += hypot(seg[i].x - seg[i - 1].x, seg[i].y - seg[i - 1].y) }
            }
        }
        if points > 100_000 { return "shape tessellation exceeds 100000 points" }
        if let s = stroke {
            if case .failure(let e) = Result(catching: { () throws(DocumentError) in try s.validate() }) { return e.message }
            if s.width > 0 && !s.dashes.isEmpty {
                let period = s.dashes.reduce(0.0) { $0 + Double($1) } * Double(s.width)
                let transitions = (length / period + 2) * Double(s.dashes.count) + Double(points)
                if !transitions.isFinite || transitions > 100_000 { return "dash pattern is too dense for this path (100000 step budget)" }
            }
        }
        return nil
    }

    /// Flattens one subpath; closed subpaths don't repeat the first point at the end.
    static func flattenSubpath(_ s: Subpath, _ tol: Double) -> Polyline {
        var out = Polyline(closed: s.closed)
        if let k = s.knots.first { out.push(k.anchor.simd, true) }
        for seg in s.segments {
            if isLine(seg) {
                out.push(seg[3].simd, true)
                continue
            }
            let n = pieces(seg, tol)
            for j in 1...n { out.push(evalCubic(seg, Double(j) / Double(n)), j == n) }
        }
        if s.closed, out.pts.count > 1, let a = out.pts.first, let b = out.pts.last, abs(a.x - b.x) < 1e-12, abs(a.y - b.y) < 1e-12 {
            out.pts.removeLast()
            out.knot.removeLast()
            out.knot[0] = true
        }
        return out
    }

    static func flattenPath(_ p: VectorPath, _ tol: Double) -> [Polyline] { p.subpaths.map { flattenSubpath($0, tol) } }

    // MARK: - Far coordinates

    /// Coordinates CoreGraphics rasterizes reliably (its fixed-point rasterizer drops geometry
    /// near ±1e9; photocraft's exact-area rasterizer has no such limit).
    static let safeRasterCoordinate = 1e7

    /// `path` ready for CoreGraphics over `rect`: unchanged when its points are within
    /// `safeRasterCoordinate`, else each subpath flattened and clipped to `rect` (plus a margin) —
    /// Sutherland–Hodgman keeps every winding number inside the window, so the fill there is the
    /// same.
    static func rasterSafe(_ path: VectorPath, within rect: PixelRect) -> VectorPath {
        let far = path.subpaths.contains { $0.knots.contains { k in
            [k.anchor, k.inCtrl, k.outCtrl].contains { !(abs($0.x) <= safeRasterCoordinate && abs($0.y) <= safeRasterCoordinate) }
        } }
        if !far { return path }
        let m = 1024.0
        let (x0, y0, x1, y1) = (Double(rect.x0) - m, Double(rect.y0) - m, Double(rect.x1) + m, Double(rect.y1) + m)
        func clip(_ poly: [SIMD2<Double>], _ inside: (SIMD2<Double>) -> Bool, _ cross: (SIMD2<Double>, SIMD2<Double>) -> SIMD2<Double>) -> [SIMD2<Double>] {
            guard let last = poly.last else { return [] }
            var out: [SIMD2<Double>] = []
            var prev = last
            for cur in poly {
                if inside(cur) {
                    if !inside(prev) { out.append(cross(prev, cur)) }
                    out.append(cur)
                } else if inside(prev) {
                    out.append(cross(prev, cur))
                }
                prev = cur
            }
            return out
        }
        func atX(_ x: Double) -> (SIMD2<Double>, SIMD2<Double>) -> SIMD2<Double> {
            { a, b in SIMD2(x, a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)) }
        }
        func atY(_ y: Double) -> (SIMD2<Double>, SIMD2<Double>) -> SIMD2<Double> {
            { a, b in SIMD2(a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y), y) }
        }
        var out = path
        out.subpaths = path.subpaths.map { sp in
            var poly = flattenSubpath(sp, defaultTolerance).pts.filter { $0.x.isFinite && $0.y.isFinite }
            poly = clip(poly, { $0.x >= x0 }, atX(x0))
            poly = clip(poly, { $0.x <= x1 }, atX(x1))
            poly = clip(poly, { $0.y >= y0 }, atY(y0))
            poly = clip(poly, { $0.y <= y1 }, atY(y1))
            return Subpath(closed: true, knots: poly.map { Knot.corner($0.x, $0.y) }, op: sp.op)
        }
        return out
    }

    // MARK: - map.rs

    /// Every anchor and control point of `path` through `f` (no subdivision).
    static func mapPoints(_ path: VectorPath, _ f: (PCPoint) -> PCPoint) -> VectorPath {
        var out = path
        for s in out.subpaths.indices {
            for k in out.subpaths[s].knots.indices {
                let kn = out.subpaths[s].knots[k]
                out.subpaths[s].knots[k] = Knot(anchor: f(kn.anchor), inCtrl: f(kn.inCtrl), outCtrl: f(kn.outCtrl), smooth: kn.smooth)
            }
        }
        return out
    }

    static let maxMapPieces = 1 << 20
    static let maxMapDepth = 6
    static let mapProbes: [Double] = [0.25, 0.5, 0.75]

    /// `path` through a smooth, possibly non-linear map: each segment is split in halves until its
    /// mapped control points follow the mapped curve within `tol` px (at most 64 pieces a segment).
    static func mapPath(_ path: VectorPath, _ f: (PCPoint) -> PCPoint, tol t0: Double) -> VectorPath {
        let tol = t0.isFinite && t0 > 0 ? t0 : 0.1
        let segments = path.subpaths.reduce(0) { $0 + $1.knots.count }
        var depth = maxMapDepth
        while depth > 0 && segments > (maxMapPieces >> depth) { depth -= 1 }
        var out = path
        out.subpaths = path.subpaths.map { mapSubpath($0, f, tol, depth) }
        return out
    }

    static func mapSubpath(_ s: Subpath, _ f: (PCPoint) -> PCPoint, _ tol: Double, _ depth: Int) -> Subpath {
        let n = s.knots.count
        let segs = s.segments
        if segs.isEmpty { return mapPoints(VectorPath([s]), f).subpaths.first ?? Subpath() }
        let pieces = segs.map { mapSegment($0, f, tol, depth) }
        var knots: [Knot] = []
        for (i, k) in s.knots.enumerated() {
            let incoming: [[PCPoint]]? = i > 0 ? (i - 1 < pieces.count ? pieces[i - 1] : nil) : (s.closed && n - 1 < pieces.count ? pieces[n - 1] : nil)
            let inCtrl = incoming?.last.map { $0[2] } ?? f(k.inCtrl)
            let outgoing: [[PCPoint]]? = i < pieces.count ? pieces[i] : nil
            let outCtrl = outgoing?.first.map { $0[1] } ?? f(k.outCtrl)
            knots.append(Knot(anchor: f(k.anchor), inCtrl: inCtrl, outCtrl: outCtrl, smooth: k.smooth))
            if let p = outgoing, p.count > 1 {
                for w in 1..<p.count { knots.append(Knot(anchor: p[w][0], inCtrl: p[w - 1][2], outCtrl: p[w][1], smooth: true)) }
            }
        }
        return Subpath(closed: s.closed, knots: knots, op: s.op)
    }

    static func lerp(_ a: PCPoint, _ b: PCPoint, _ t: Double) -> PCPoint { PCPoint(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t) }
    static func dist(_ a: PCPoint, _ b: PCPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    static func deCasteljau(_ s: [PCPoint], _ t: Double) -> PCPoint {
        let ab = lerp(s[0], s[1], t), bc = lerp(s[1], s[2], t), cd = lerp(s[2], s[3], t)
        return lerp(lerp(ab, bc, t), lerp(bc, cd, t), t)
    }

    static func halves(_ s: [PCPoint]) -> ([PCPoint], [PCPoint]) {
        let ab = lerp(s[0], s[1], 0.5), bc = lerp(s[1], s[2], 0.5), cd = lerp(s[2], s[3], 0.5)
        let abc = lerp(ab, bc, 0.5), bcd = lerp(bc, cd, 0.5)
        let m = lerp(abc, bcd, 0.5)
        return ([s[0], ab, abc, m], [m, bcd, cd, s[3]])
    }

    static func offLine(_ p: PCPoint, _ a: PCPoint, _ b: PCPoint) -> Double {
        let l = dist(a, b)
        return l < 1e-12 ? dist(p, a) : abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / l
    }

    static func mapSegment(_ seg: [PCPoint], _ f: (PCPoint) -> PCPoint, _ tol: Double, _ depth: Int) -> [[PCPoint]] {
        if seg[1] == seg[0] && seg[2] == seg[3] {
            let a = f(seg[0]), b = f(seg[3])
            if mapProbes.allSatisfy({ offLine(f(lerp(seg[0], seg[3], $0)), a, b) <= tol }) { return [[a, a, b, b]] }
            let line = [seg[0], lerp(seg[0], seg[3], 1.0 / 3), lerp(seg[0], seg[3], 2.0 / 3), seg[3]]
            var out: [[PCPoint]] = []
            splitMapped(line, f, tol, depth, &out)
            return out
        }
        var out: [[PCPoint]] = []
        splitMapped(seg, f, tol, depth, &out)
        return out
    }

    static func splitMapped(_ seg: [PCPoint], _ f: (PCPoint) -> PCPoint, _ tol: Double, _ depth: Int, _ out: inout [[PCPoint]]) {
        let mapped = seg.map(f)
        let fits = mapProbes.allSatisfy { dist(f(deCasteljau(seg, $0)), deCasteljau(mapped, $0)) <= tol }
        if fits || depth == 0 {
            out.append(mapped)
            return
        }
        let (a, b) = halves(seg)
        splitMapped(a, f, tol, depth - 1, &out)
        splitMapped(b, f, tol, depth - 1, &out)
    }

    // MARK: - photocraft-algo transform::Homography

    /// A projective map, row-major 3×3 (photocraft-algo `Homography`).
    struct Homography: Sendable, Equatable {
        var m: [Double]

        func apply(_ x: Double, _ y: Double) -> SIMD2<Double> {
            let w = m[6] * x + m[7] * y + m[8]
            return SIMD2((m[0] * x + m[1] * y + m[2]) / w, (m[3] * x + m[4] * y + m[5]) / w)
        }

        func mul(_ o: Homography) -> Homography {
            var r = [Double](repeating: 0, count: 9)
            for i in 0..<3 { for j in 0..<3 { r[i * 3 + j] = (0..<3).reduce(0) { $0 + m[i * 3 + $1] * o.m[$1 * 3 + j] } } }
            return Homography(m: r)
        }

        var inverse: Homography? {
            let c = [
                m[4] * m[8] - m[5] * m[7], m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
                m[5] * m[6] - m[3] * m[8], m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
                m[3] * m[7] - m[4] * m[6], m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3],
            ]
            let det = m[0] * c[0] + m[1] * c[3] + m[2] * c[6]
            if abs(det) < 1e-12 { return nil }
            return Homography(m: c.map { $0 / det })
        }

        /// Unit square → quad (corners (0,0), (1,0), (1,1), (0,1)).
        static func squareToQuad(_ q: [SIMD2<Double>]) -> Homography? {
            let (x0, y0, x1, y1, x2, y2, x3, y3) = (q[0].x, q[0].y, q[1].x, q[1].y, q[2].x, q[2].y, q[3].x, q[3].y)
            let sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3
            if abs(sx) < 1e-12 && abs(sy) < 1e-12 {
                return Homography(m: [x1 - x0, x3 - x0, x0, y1 - y0, y3 - y0, y0, 0, 0, 1])
            }
            let dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2
            let den = dx1 * dy2 - dx2 * dy1
            if abs(den) < 1e-12 { return nil }
            let g = (sx * dy2 - dx2 * sy) / den
            let h = (dx1 * sy - sx * dy1) / den
            return Homography(m: [x1 - x0 + g * x1, x3 - x0 + h * x3, x0, y1 - y0 + g * y1, y3 - y0 + h * y3, y0, g, h, 1])
        }

        /// Rectangle `r` (x0, y0, x1, y1) onto `quad` (clockwise from top-left); nil when degenerate.
        static func rectToQuad(_ r: [Double], _ quad: [SIMD2<Double>]) -> Homography? {
            let w = r[2] - r[0], h = r[3] - r[1]
            if w <= 0 || h <= 0 { return nil }
            let toUnit = Homography(m: [1 / w, 0, -r[0] / w, 0, 1 / h, -r[1] / h, 0, 0, 1])
            return squareToQuad(quad)?.mul(toUnit)
        }
    }

    // MARK: - warp_cmds.rs warp_from_params

    /// photocraft `warp_cmds::warp_from_params`: `warp` (a serialized `Warp`), or `style` + `bend`,
    /// `hDistort`, `vDistort`, `vertical`, or a custom `mesh` / `grid`, framed by `rect`.
    static func warpFromParams(_ cmd: String, _ p: JSONValue, _ rect: SIMD4<Double>) throws -> Warp {
        if let wv = p["warp"] {
            let w: Warp
            do { w = try wv.decode(as: Warp.self) } catch { throw EngineError.bad(cmd, "bad `warp`: \(error)") }
            if let m = w.mesh, !m.isValid { throw EngineError.bad(cmd, "malformed warp mesh") }
            return w
        }
        func num(_ k: String, _ d: Double) -> Double { p[k]?.doubleValue ?? d }
        let style: WarpStyle
        if let st = p["style"]?.stringValue {
            guard let w = WarpStyle.parse(st) else { throw EngineError.bad(cmd, "unknown warp style \"\(st)\"") }
            style = w
        } else if p["mesh"] != nil || p["grid"] != nil {
            style = .custom
        } else {
            throw EngineError.bad(cmd, "pass `style` (arc, flag, …, custom), `mesh` or `warp`")
        }
        var w = Warp.preset(style, bend: num("bend", 50), bounds: rect)
        w.hDistort = num("hDistort", 0)
        w.vDistort = num("vDistort", 0)
        w.vertical = p["vertical"]?.boolValue ?? false
        if style == .custom {
            let mesh: BezierMesh
            if let mv = p["mesh"] {
                let m: BezierMesh
                do { m = try mv.decode(as: BezierMesh.self) } catch { throw EngineError.bad(cmd, "bad `mesh`: \(error)") }
                if !m.isValid { throw EngineError.bad(cmd, "malformed mesh (need (3·cols+1)×(3·rows+1) points and knots 0..1)") }
                mesh = m
            } else {
                let g = p["grid"]?.arrayValue
                func at(_ i: Int) -> Int {
                    guard let g, i < g.count, let v = g[i].uint64Value else { return 1 }
                    return Int(min(v, 1 << 20))
                }
                mesh = BezierMesh.identity(bounds: rect, cols: at(0), rows: at(1))
            }
            w.mesh = mesh
        }
        return w
    }

    // MARK: - photocraft-algo selection_blur::feather (reference)

    /// photocraft-algo `MAX_SIGMA`.
    static let maxFeatherSigma: Float = 100_000

    /// Select › Modify › Feather: Gaussian blur of the mask with σ = radius, the kernel truncated at
    /// ⌈3σ⌉ and normalized, zero beyond the canvas (photocraft-algo `selection_blur::feather`).
    /// Only the taps that land on the canvas are summed (the normalization still covers the whole
    /// kernel), so huge radii stay bounded.
    static func feather(_ m: [Float], _ w: Int, _ h: Int, _ radius: Float) -> [Float] {
        let n = w * h
        let sigma0: Float = radius.isFinite ? max(radius, 0) : (radius > 0 ? maxFeatherSigma : 0)
        if sigma0 < 0.1 || m.count != n || n == 0 { return m }
        let sigma = Double(min(sigma0, maxFeatherSigma))
        let r = Int((sigma * 3).rounded(.up))
        // Nonzero bounds.
        var nx0 = w, ny0 = h, nx1 = 0, ny1 = 0
        for y in 0..<h {
            for x in 0..<w where m[y * w + x] != 0 {
                nx0 = min(nx0, x); nx1 = max(nx1, x + 1); ny0 = min(ny0, y); ny1 = max(ny1, y + 1)
            }
        }
        if nx1 <= nx0 || ny1 <= ny0 { return m }
        let (bx0, by0, bx1, by1) = (nx0, ny0, nx1, ny1)
        let wx0 = max(bx0 - r, 0), wx1 = min(bx1 + r, w), wy0 = max(by0 - r, 0), wy1 = min(by1 + r, h)
        let gw = wx1 - wx0, bh = by1 - by0
        // Normalization over the whole truncated kernel; weights only for reachable offsets.
        var sum = 0.0
        for i in -r...r { sum += exp(-Double(i * i) / (2 * sigma * sigma)) }
        let reach = min(r, max(w, h))
        let kernel = (0...reach).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma)) / sum) }
        var tmp = [Float](repeating: 0, count: bh * gw)
        tmp.withUnsafeMutableBufferPointer { tp in
            let t = SendableBuffer(tp)
            DispatchQueue.concurrentPerform(iterations: bh) { row in
                let y = by0 + row
                for x in wx0..<wx1 {
                    var acc: Float = 0
                    let lo = max(bx0, x - r), hi = min(bx1 - 1, x + r)
                    if lo <= hi { for xx in lo...hi { acc += m[y * w + xx] * kernel[abs(xx - x)] } }
                    t[row * gw + (x - wx0)] = acc
                }
            }
        }
        var out = [Float](repeating: 0, count: n)
        out.withUnsafeMutableBufferPointer { op in
            let o = SendableBuffer(op)
            let src = tmp
            DispatchQueue.concurrentPerform(iterations: gw) { col in
                for y in wy0..<wy1 {
                    var acc: Float = 0
                    let lo = max(by0, y - r), hi = min(by1 - 1, y + r)
                    if lo <= hi { for yy in lo...hi { acc += src[(yy - by0) * gw + col] * kernel[abs(yy - y)] } }
                    o[y * w + wx0 + col] = abs(acc) < 1e-7 ? 0 : acc
                }
            }
        }
        return out
    }

    // MARK: - trace.rs (coverage mask → path)

    private struct EdgeKey: Hashable, Comparable {
        var x: Int, y: Int, d: UInt8
        static func < (a: EdgeKey, b: EdgeKey) -> Bool { (a.y, a.x, a.d) < (b.y, b.x, b.d) }
    }

    /// Traces the 0.5 iso-contours of `values` (row-major over `rect`, `outside` beyond it) and
    /// fits curves within `tolerance` px: the first contour combines, the rest exclude.
    static func traceMask(_ values: [Float], _ rect: PixelRect, outside: Float, tolerance: Double) -> VectorPath {
        let loops = contours(values, rect, outside: outside)
        var subpaths: [Subpath] = []
        for (i, lp) in loops.enumerated() where lp.count >= 3 {
            var s = fitClosed(lp, max(tolerance * 0.5, 0.05), 1.5)
            s.op = i == 0 ? .combine : .exclude
            subpaths.append(s)
        }
        return VectorPath(subpaths)
    }

    /// Closed iso-contours at 0.5 through pixel centres (marching squares, inside on the left).
    static func contours(_ values: [Float], _ rect: PixelRect, outside: Float) -> [[SIMD2<Double>]] {
        let w = rect.width, h = rect.height
        guard values.count == w * h else { return [] }
        func get(_ x: Int, _ y: Int) -> Float { x < 0 || y < 0 || x >= w || y >= h ? outside : values[y * w + x] }
        let lvl: Float = 0.5
        func point(_ a: (Int, Int), _ b: (Int, Int)) -> SIMD2<Double> {
            let va = get(a.0, a.1), vb = get(b.0, b.1)
            let t = abs(vb - va) > 1e-9 ? min(max(Double((lvl - va) / (vb - va)), 0), 1) : 0.5
            let ax = Double(a.0) + 0.5, ay = Double(a.1) + 0.5, bx = Double(b.0) + 0.5, by = Double(b.1) + 0.5
            return SIMD2(Double(rect.x0) + ax + (bx - ax) * t, Double(rect.y0) + ay + (by - ay) * t)
        }
        var next: [EdgeKey: EdgeKey] = [:]
        if w > 0 && h > 0 {
            for cy in -1..<h {
                for cx in -1..<w {
                    let tl = get(cx, cy) >= lvl, tr = get(cx + 1, cy) >= lvl, br = get(cx + 1, cy + 1) >= lvl, bl = get(cx, cy + 1) >= lvl
                    let idx = (tl ? 1 : 0) | (tr ? 2 : 0) | (br ? 4 : 0) | (bl ? 8 : 0)
                    if idx == 0 || idx == 15 { continue }
                    let top = EdgeKey(x: cx, y: cy, d: 0), bottom = EdgeKey(x: cx, y: cy + 1, d: 0)
                    let left = EdgeKey(x: cx, y: cy, d: 1), right = EdgeKey(x: cx + 1, y: cy, d: 1)
                    func seg(_ a: EdgeKey, _ b: EdgeKey) { next[a] = b }
                    func centre() -> Float { (get(cx, cy) + get(cx + 1, cy) + get(cx + 1, cy + 1) + get(cx, cy + 1)) / 4 }
                    switch idx {
                    case 1: seg(left, top)
                    case 2: seg(top, right)
                    case 3: seg(left, right)
                    case 4: seg(right, bottom)
                    case 5:
                        if centre() >= lvl { seg(left, bottom); seg(right, top) } else { seg(left, top); seg(right, bottom) }
                    case 6: seg(top, bottom)
                    case 7: seg(left, bottom)
                    case 8: seg(bottom, left)
                    case 9: seg(bottom, top)
                    case 10:
                        if centre() >= lvl { seg(top, left); seg(bottom, right) } else { seg(top, right); seg(bottom, left) }
                    case 11: seg(bottom, right)
                    case 12: seg(right, left)
                    case 13: seg(right, top)
                    case 14: seg(top, left)
                    default: break
                    }
                }
            }
        }
        func edgePoint(_ e: EdgeKey) -> SIMD2<Double> { e.d == 0 ? point((e.x, e.y), (e.x + 1, e.y)) : point((e.x, e.y), (e.x, e.y + 1)) }
        var out: [[SIMD2<Double>]] = []
        for start in next.keys.sorted() {
            if next[start] == nil { continue }
            var lp: [SIMD2<Double>] = []
            var cur = start
            while let n = next.removeValue(forKey: cur) {
                lp.append(edgePoint(cur))
                cur = n
                if cur == start { break }
            }
            var dedup: [SIMD2<Double>] = []
            for p in lp {
                if let l = dedup.last, abs(l.x - p.x) < 1e-9, abs(l.y - p.y) < 1e-9 { continue }
                dedup.append(p)
            }
            if dedup.count >= 3 { out.append(dedup) }
        }
        return out
    }

    private typealias P = SIMD2<Double>

    private static func len(_ a: P) -> Double { (a.x * a.x + a.y * a.y).squareRoot() }
    private static func norm(_ a: P) -> P {
        let l = len(a)
        return l > 1e-12 ? a / l : .zero
    }

    /// The point `window` px of arc length from `i` along a closed loop (or an open polyline, where
    /// the walk stops at the ends).
    private static func walk(_ lp: [P], _ i: Int, _ window: Double, _ fwd: Bool, _ closed: Bool) -> P {
        let n = lp.count
        var acc = 0.0
        var cur = i
        for _ in 0..<n {
            if !closed && (fwd ? cur + 1 >= n : cur == 0) { break }
            let nx = fwd ? (cur + 1) % n : (cur + n - 1) % n
            let d = len(lp[nx] - lp[cur])
            if acc + d >= window {
                let t = (window - acc) / max(d, 1e-12)
                return lp[cur] + (lp[nx] - lp[cur]) * t
            }
            acc += d
            cur = nx
        }
        return lp[cur]
    }

    /// Corner indices: where the direction over ±`window` px turns by more than 60°.
    private static func corners(_ lp: [P], _ window: Double, _ closed: Bool) -> [Int] {
        let n = lp.count
        let cosThresh = cos(60.0 * .pi / 180)
        let turn: [Double] = (0..<n).map { i in
            if !closed && (i == 0 || i + 1 == n) { return 1 }
            let a = norm(lp[i] - walk(lp, i, window, false, closed))
            let b = norm(walk(lp, i, window, true, closed) - lp[i])
            return simd_dot(a, b)
        }
        var out: [Int] = []
        for i in 0..<n where turn[i] < cosThresh {
            var isMin = true
            var acc = 0.0
            var j = i
            while acc < window {
                if !closed && j + 1 >= n { break }
                let nx = (j + 1) % n
                acc += len(lp[nx] - lp[j])
                j = nx
                if j == i { break }
                if turn[j] < turn[i] { isMin = false; break }
            }
            acc = 0
            j = i
            while isMin && acc < window {
                if !closed && j == 0 { break }
                let pv = (j + n - 1) % n
                acc += len(lp[j] - lp[pv])
                j = pv
                if j == i { break }
                if turn[j] <= turn[i] { isMin = false }
            }
            if isMin { out.append(i) }
        }
        return out
    }

    /// Fits a closed loop with cubic Béziers; `window` is the corner detection window.
    private static func fitClosed(_ lp: [P], _ tol: Double, _ window: Double) -> Subpath {
        let n = lp.count
        let cs = corners(lp, window, true)
        var segs: [[P]] = []
        var cornerAtStart: [Bool] = []
        if cs.isEmpty {
            var pts = lp
            pts.append(lp[0])
            let t = norm(lp[1 % n] - lp[n - 1])
            let before = segs.count
            fitCubic(pts[...], t, -t, tol * tol, &segs, 0)
            cornerAtStart.append(contentsOf: repeatElement(false, count: segs.count - before))
        } else {
            for (k, c) in cs.enumerated() {
                let end = cs[(k + 1) % cs.count]
                var pts = [lp[c]]
                var j = c
                repeat {
                    j = (j + 1) % n
                    pts.append(lp[j])
                } while j != end
                let m = pts.count
                let t1 = norm(pts[min(1, m - 1)] - pts[0])
                let t2 = norm(pts[max(m - 2, 0)] - pts[m - 1])
                let before = segs.count
                fitCubic(pts[...], t1, t2, tol * tol, &segs, 0)
                for q in 0..<(segs.count - before) { cornerAtStart.append(q == 0) }
            }
        }
        let m = segs.count
        var knots: [Knot] = segs.enumerated().map { i, s in
            Knot(anchor: PCPoint(s[0]), inCtrl: PCPoint(s[0]), outCtrl: PCPoint(s[1]), smooth: !cornerAtStart[i])
        }
        for i in 0..<m { knots[(i + 1) % m].inCtrl = PCPoint(segs[i][2]) }
        return Subpath(closed: true, knots: knots, op: .combine)
    }

    private static func bezier(_ b: [P], _ t: Double) -> P {
        let mt = 1 - t
        return b[0] * (mt * mt * mt) + b[1] * (3 * mt * mt * t) + b[2] * (3 * mt * t * t) + b[3] * (t * t * t)
    }

    private static func bezierD1(_ b: [P], _ t: Double) -> P {
        let mt = 1 - t
        let q0 = (b[1] - b[0]) * 3, q1 = (b[2] - b[1]) * 3, q2 = (b[3] - b[2]) * 3
        return q0 * (mt * mt) + q1 * (2 * mt * t) + q2 * (t * t)
    }

    private static func bezierD2(_ b: [P], _ t: Double) -> P {
        let r0 = (b[2] - b[1] * 2 + b[0]) * 6, r1 = (b[3] - b[2] * 2 + b[1]) * 6
        return r0 * (1 - t) + r1 * t
    }

    private static func chordParams(_ pts: ArraySlice<P>) -> [Double] {
        let a = Array(pts)
        var u = [Double](repeating: 0, count: a.count)
        for i in 1..<max(a.count, 1) { u[i] = u[i - 1] + len(a[i] - a[i - 1]) }
        if let total = u.last, total > 0 { for i in u.indices { u[i] /= total } }
        return u
    }

    /// Least-squares control points with fixed end tangents.
    private static func generate(_ pts: [P], _ u: [Double], _ t1: P, _ t2: P) -> [P] {
        let p0 = pts[0], p3 = pts[pts.count - 1]
        var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0
        for (i, t) in u.enumerated() {
            let mt = 1 - t
            let b1 = 3 * mt * mt * t, b2 = 3 * mt * t * t
            let a1 = t1 * b1, a2 = t2 * b2
            c00 += simd_dot(a1, a1); c01 += simd_dot(a1, a2); c11 += simd_dot(a2, a2)
            let b0 = mt * mt * mt, b3 = t * t * t
            let tmp = pts[i] - (p0 * (b0 + b1) + p3 * (b2 + b3))
            x0 += simd_dot(a1, tmp); x1 += simd_dot(a2, tmp)
        }
        let c10 = c01
        let det = c00 * c11 - c10 * c01
        let det0 = c00 * x1 - c10 * x0
        let det1 = x0 * c11 - x1 * c01
        var (al, ar) = abs(det) > 1e-12 ? (det1 / det, det0 / det) : (0.0, 0.0)
        let seg = len(p3 - p0)
        let eps = 1e-6 * seg
        if al < eps || ar < eps { al = seg / 3; ar = seg / 3 }
        return [p0, p0 + t1 * al, p3 + t2 * ar, p3]
    }

    private static func maxError(_ pts: [P], _ b: [P], _ u: [Double]) -> (Double, Int) {
        var best = (0.0, pts.count / 2)
        if pts.count > 2 {
            for i in 1..<(pts.count - 1) {
                let d = bezier(b, u[i]) - pts[i]
                let e = simd_dot(d, d)
                if e >= best.0 { best = (e, i) }
            }
        }
        return best
    }

    private static func reparam(_ pts: [P], _ u: [Double], _ b: [P]) -> [Double] {
        zip(pts, u).map { p, t in
            let q = bezier(b, t), d1 = bezierD1(b, t), d2 = bezierD2(b, t)
            let num = simd_dot(q - p, d1)
            let den = simd_dot(d1, d1) + simd_dot(q - p, d2)
            return abs(den) < 1e-12 ? t : min(max(t - num / den, 0), 1)
        }
    }

    private static func fitCubic(_ slice: ArraySlice<P>, _ t1: P, _ t2: P, _ err2: Double, _ out: inout [[P]], _ depth: Int) {
        let pts = Array(slice)
        let n = pts.count
        guard n >= 2 else { return }
        if n == 2 || depth > 40 {
            let d = len(pts[n - 1] - pts[0]) / 3
            out.append([pts[0], pts[0] + t1 * d, pts[n - 1] + t2 * d, pts[n - 1]])
            return
        }
        var u = chordParams(slice)
        var b = generate(pts, u, t1, t2)
        var (e, split) = maxError(pts, b, u)
        if e < err2 {
            out.append(b)
            return
        }
        if e < err2 * 16 {
            for _ in 0..<6 {
                let u2 = reparam(pts, u, b)
                let b2 = generate(pts, u2, t1, t2)
                let (e2, s2) = maxError(pts, b2, u2)
                u = u2; b = b2; e = e2; split = s2
                if e < err2 {
                    out.append(b)
                    return
                }
            }
        }
        let sp = min(max(split, 1), n - 2)
        var tc = norm(pts[sp - 1] - pts[sp + 1])
        if len(tc) < 0.5 { tc = norm(pts[sp - 1] - pts[sp]) }
        fitCubic(pts[...sp], t1, tc, err2, &out, depth + 1)
        fitCubic(pts[sp...], -tc, t2, err2, &out, depth + 1)
    }

    // MARK: - edit.rs (point-level edits)

    /// One of a knot's two direction handles.
    enum Handle: String, Sendable {
        case `in`, out
        static func parse(_ s: String) -> Handle? { Handle(rawValue: s) }
        var other: Handle { self == .in ? .out : .in }
    }

    private static func knotIndex(_ path: VectorPath, _ s: Int, _ k: Int) throws(GeometryError) {
        guard s >= 0, s < path.subpaths.count, k >= 0, k < path.subpaths[s].knots.count else {
            throw GeometryError(message: "no knot \(k) in subpath \(s)")
        }
    }

    /// The knot ending the segment that leaves `[s, k]` (wrapping on closed subpaths).
    private static func segmentEnd(_ path: VectorPath, _ s: Int, _ k: Int) throws(GeometryError) -> (Int, Int) {
        guard s >= 0, s < path.subpaths.count else { throw GeometryError(message: "no subpath \(s)") }
        let sp = path.subpaths[s]
        let n = sp.knots.count
        if k >= 0 && k < n && k + 1 < n { return (s, k + 1) }
        if k >= 0 && k < n && sp.closed && n > 1 { return (s, 0) }
        throw GeometryError(message: "no segment leaves knot \(k) of subpath \(s)")
    }

    private static func handle(_ k: Knot, _ h: Handle) -> PCPoint { h == .in ? k.inCtrl : k.outCtrl }

    private static func setHandle(_ k: inout Knot, _ h: Handle, _ p: PCPoint) {
        if h == .in { k.inCtrl = p } else { k.outCtrl = p }
    }

    /// A smooth knot keeps its handles collinear: the opposite of `h` points away from it at its
    /// own length (a retracted handle stays retracted).
    private static func keepSmooth(_ k: inout Knot, _ h: Handle) {
        if !k.smooth { return }
        let a = k.anchor, moved = handle(k, h), opp = handle(k, h.other)
        let l = dist(opp, a), d = dist(moved, a)
        if l > 1e-9 && d > 1e-9 {
            setHandle(&k, h.other, PCPoint(a.x - (moved.x - a.x) / d * l, a.y - (moved.y - a.y) / d * l))
        }
    }

    private static func moved(_ p: PCPoint, _ d: SIMD2<Double>) -> PCPoint { PCPoint(p.x + d.x, p.y + d.y) }

    /// Moves anchors (with their handles) by `d`; each knot moves once.
    static func moveAnchors(_ path: inout VectorPath, _ anchors: [(Int, Int)], _ d: SIMD2<Double>) throws(GeometryError) {
        var seen = Set<[Int]>()
        var list: [(Int, Int)] = []
        for a in anchors.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) where seen.insert([a.0, a.1]).inserted { list.append(a) }
        for (s, k) in list { try knotIndex(path, s, k) }
        for (s, k) in list {
            let kn = path.subpaths[s].knots[k]
            path.subpaths[s].knots[k] = Knot(anchor: moved(kn.anchor, d), inCtrl: moved(kn.inCtrl, d), outCtrl: moved(kn.outCtrl, d), smooth: kn.smooth)
        }
    }

    /// Puts handle `h` at `to`; a smooth knot turns its other handle unless `independent`.
    static func moveHandle(_ path: inout VectorPath, _ s: Int, _ k: Int, _ h: Handle, _ to: PCPoint, independent: Bool) throws(GeometryError) {
        try knotIndex(path, s, k)
        var kn = path.subpaths[s].knots[k]
        setHandle(&kn, h, to)
        if independent { kn.smooth = false }
        keepSmooth(&kn, h)
        path.subpaths[s].knots[k] = kn
    }

    /// Convert Point: a corner with retracted handles, or a smooth knot with `out` and its mirror.
    static func convertPoint(_ path: inout VectorPath, _ s: Int, _ k: Int, _ out: PCPoint?) throws(GeometryError) {
        try knotIndex(path, s, k)
        let a = path.subpaths[s].knots[k].anchor
        if let o = out {
            path.subpaths[s].knots[k] = .smooth(anchor: a, inCtrl: PCPoint(2 * a.x - o.x, 2 * a.y - o.y), outCtrl: o)
        } else {
            path.subpaths[s].knots[k] = .corner(a.x, a.y)
        }
    }

    private static func retracted(_ k: Knot, _ h: Handle) -> Bool { dist(handle(k, h), k.anchor) < 1e-9 }

    /// Drags the segment leaving `[s, k]` at parameter `t` by `d`: a straight segment moves with its
    /// anchors; a curve reshapes so the point at `t` follows exactly.
    static func bendSegment(_ path: inout VectorPath, _ s: Int, _ k: Int, _ t0: Double, _ d: SIMD2<Double>) throws(GeometryError) {
        let end = try segmentEnd(path, s, k)
        try knotIndex(path, s, k)
        let a = path.subpaths[s].knots[k], b = path.subpaths[end.0].knots[end.1]
        if retracted(a, .out) && retracted(b, .in) {
            try moveAnchors(&path, [(s, k), end], d)
            return
        }
        let t = t0.isFinite ? min(max(t0, 0.05), 0.95) : 0.5
        let u = 1 - t
        let sc = 1 / (3 * t * u * (u * u + t * t))
        let w1 = u * sc, w2 = t * sc
        var ka = path.subpaths[s].knots[k]
        ka.outCtrl = moved(ka.outCtrl, d * w1)
        keepSmooth(&ka, .out)
        path.subpaths[s].knots[k] = ka
        var kb = path.subpaths[end.0].knots[end.1]
        kb.inCtrl = moved(kb.inCtrl, d * w2)
        keepSmooth(&kb, .in)
        path.subpaths[end.0].knots[end.1] = kb
    }

    /// Add Anchor Point: inserts an anchor into the segment leaving `[s, k]` at `t` (0 < t < 1);
    /// returns the new knot's index.
    static func addAnchor(_ path: inout VectorPath, _ s: Int, _ k: Int, _ t: Double) throws(GeometryError) -> (Int, Int) {
        if !(t.isFinite && t > 0 && t < 1) { throw GeometryError(message: "`t` must be strictly between 0 and 1") }
        let end = try segmentEnd(path, s, k)
        let a = path.subpaths[s].knots[k], b = path.subpaths[end.0].knots[end.1]
        let new: Knot
        if retracted(a, .out) && retracted(b, .in) {
            let p = evalCubic([a.anchor, a.outCtrl, b.inCtrl, b.anchor], t)
            new = .corner(p.x, p.y)
        } else {
            let p01 = lerp(a.anchor, a.outCtrl, t), p12 = lerp(a.outCtrl, b.inCtrl, t), p23 = lerp(b.inCtrl, b.anchor, t)
            let p012 = lerp(p01, p12, t), p123 = lerp(p12, p23, t)
            path.subpaths[s].knots[k].outCtrl = p01
            path.subpaths[end.0].knots[end.1].inCtrl = p23
            new = .smooth(anchor: lerp(p012, p123, t), inCtrl: p012, outCtrl: p123)
        }
        let at = k + 1
        path.subpaths[s].knots.insert(new, at: min(at, path.subpaths[s].knots.count))
        return (s, at)
    }

    /// Delete Anchor Point: removes a knot (its neighbours are joined); a subpath's last anchor
    /// removes the subpath; the path's only anchor is refused. Returns whether the subpath went.
    static func deleteAnchor(_ path: inout VectorPath, _ s: Int, _ k: Int) throws(GeometryError) -> Bool {
        try knotIndex(path, s, k)
        let total = path.subpaths.reduce(0) { $0 + $1.knots.count }
        if total <= 1 { throw GeometryError(message: "can't delete the path's only anchor point; delete the path instead") }
        if path.subpaths[s].knots.count <= 1 {
            path.subpaths.remove(at: s)
            return true
        }
        path.subpaths[s].knots.remove(at: k)
        return false
    }
}
