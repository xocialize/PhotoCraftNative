// Port of photocraft-algo (crates/algo/src/liquify.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Liquify: a dense displacement field edited by brush strokes, then used to resample the
// layer once. The field stores, for every node of a regular grid (one node per `cell` document
// pixels), the offset `d` such that output pixel `p` shows the source at `p + d(p)` (an inverse
// map, so applying it never leaves holes). Strokes are plain data, applied in order; replaying the
// same strokes on the same bounds gives the same field bit for bit (a replayable command, a smart
// filter). Every tool is "where does the new output at `p` come from in the current output":
// `q = M(p)`, so the new field is `d'(p) = q + d(q) − p`, sampled bilinearly from the field as it
// was before the dab. Reconstruct scales `d` toward zero and Smooth relaxes it toward its local
// mean; Freeze/Thaw paint a mask that scales every tool's strength down.
//
// `Liquify.apply` upsamples the field with Catmull-Rom per pixel and samples the source
// (premultiplied Catmull-Rom, edge pixels repeated past the field bounds) per 256-px tile; tiles
// where the field is zero are copied untouched. The field editing is CPU work (tiny, sequential,
// replayed bit for bit); the resampling also runs as two Metal kernels. `Liquify.ProxyImage` is the
// cheap interactive preview (bilinear field and source on a downsampled RGBA copy).

import Foundation
import Metal
import PCFoundation

/// The Liquify tools (Photoshop's left tool strip, minus Hand/Zoom/Face) — photocraft `LiquifyTool`.
public enum LiquifyTool: String, Codable, Sendable, Hashable, CaseIterable {
    case forwardWarp
    case reconstruct
    case smooth
    case twirlCw
    case twirlCcw
    case pucker
    case bloat
    case pushLeft
    case freeze
    case thaw
    case lassoMask
    /// The Reconstruct… button: scales the whole (unfrozen) field toward zero by `amount` %.
    case reconstructAll
    /// Mask Options › Mask All / None / Invert All (whole-field freeze edits).
    case freezeAll
    case thawAll
    case invertFreeze

    /// photocraft `LiquifyTool::ALL`: the brush tools of the tool strip.
    public static let all: [LiquifyTool] = [.forwardWarp, .reconstruct, .smooth, .twirlCw, .twirlCcw, .pucker, .bloat, .pushLeft, .freeze, .thaw, .lassoMask]

    public var label: String {
        switch self {
        case .forwardWarp: "Forward Warp"
        case .reconstruct: "Reconstruct"
        case .smooth: "Smooth"
        case .twirlCw: "Twirl Clockwise"
        case .twirlCcw: "Twirl Counterclockwise"
        case .pucker: "Pucker"
        case .bloat: "Bloat"
        case .pushLeft: "Push Left"
        case .freeze: "Freeze Mask"
        case .thaw: "Thaw Mask"
        case .lassoMask: "Freeze Lasso"
        case .reconstructAll: "Reconstruct All"
        case .freezeAll: "Mask All"
        case .thawAll: "Mask None"
        case .invertFreeze: "Invert Mask"
        }
    }

    /// Whole-field operations (no brush, no points).
    public var isGlobal: Bool { self == .reconstructAll || self == .freezeAll || self == .thawAll || self == .invertFreeze }

    /// Tools that act while the brush is held still (each recorded point is a dab).
    public var isStationary: Bool { !(self == .forwardWarp || self == .pushLeft || self == .lassoMask) }
}

/// One brush stroke: the tool, its brush options and the points it passed through (`[x, y]` or
/// `[x, y, pressure 0…1]`, document pixels) — photocraft `LiquifyStroke` (same serde names and
/// defaults).
public struct LiquifyStroke: Hashable, Sendable, Codable {
    public var tool: LiquifyTool
    /// Brush diameter (px).
    public var size: Double
    /// How far the full effect reaches toward the brush edge, 0 (only the centre; feathered) …
    /// 100 (most of the brush). It always fades to nothing at the edge (`Liquify.falloff`).
    public var density: Double
    /// Overall strength, 0…100.
    public var pressure: Double
    /// Speed of the stationary tools, 0…100.
    public var rate: Double
    public var points: [[Double]]
    /// `reconstructAll` only: how much to restore, 0…100. `lassoMask`: 1 / none freezes the
    /// polygon, 0 thaws it.
    public var amount: Double?

    public init(tool: LiquifyTool = .forwardWarp, size: Double = 100, density: Double = 50, pressure: Double = 100, rate: Double = 80,
                points: [[Double]] = [], amount: Double? = nil) {
        self.tool = tool; self.size = size; self.density = density; self.pressure = pressure; self.rate = rate
        self.points = points; self.amount = amount
    }

    enum CodingKeys: String, CodingKey { case tool, size, density, pressure, rate, points, amount }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decodeIfPresent(LiquifyTool.self, forKey: .tool) ?? .forwardWarp
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 100
        density = try c.decodeIfPresent(Double.self, forKey: .density) ?? 50
        pressure = try c.decodeIfPresent(Double.self, forKey: .pressure) ?? 100
        rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? 80
        points = try c.decodeIfPresent([[Double]].self, forKey: .points) ?? []
        amount = try c.decodeIfPresent(Double.self, forKey: .amount)
    }

    /// Validates the stroke (brush size 1…15000, finite numbers, 2 or 3 per point).
    public func validate() throws {
        if !(size.isFinite && size >= 1 && size <= 15000) { throw FilterError.invalidInput("brush size \(size) out of range 1..15000") }
        for p in points where !(2...3).contains(p.count) || p.contains(where: { !$0.isFinite }) {
            throw FilterError.invalidInput("stroke points are [x, y] or [x, y, pressure]")
        }
    }
}

/// Rust `f64::clamp` (NaN stays NaN).
@inline(__always)
private func clampR(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v < lo ? lo : (v > hi ? hi : v) }

/// Rust's saturating `f64 as usize` (into Int).
@inline(__always)
private func toUsize(_ d: Double) -> Int {
    if d.isNaN || d <= 0 { return 0 }
    if d >= 9.2e18 { return Int.max }
    return Int(d)
}

/// Rust's saturating `f64 as isize`.
@inline(__always)
private func toIsize(_ d: Double) -> Int {
    if d.isNaN { return 0 }
    if d >= 9.2e18 { return Int.max }
    if d <= -9.2e18 { return Int.min }
    return Int(d)
}

/// The displacement field plus the freeze mask over `bounds` (document pixels) — photocraft
/// `LiquifyField`.
public struct LiquifyField: Sendable, Equatable, Codable {
    public var bounds: PixelRect
    /// Document pixels per field node.
    public var cell: Double
    public var w: Int
    public var h: Int
    /// Inverse displacement per node, row-major.
    public var d: [SIMD2<Float>]
    /// Freeze mask per node (0 free, 1 frozen).
    public var freeze: [Float]
    /// Where the brush stroke in progress stands, so dab spacing runs on across its segments.
    var cursor: StrokeCursor?

    /// The cursor is transient brush state, not serialised.
    enum CodingKeys: String, CodingKey { case bounds, cell, w, h, d, freeze }

    /// The brush stroke in progress: the point its last segment ended at, its last dab and how far
    /// the brush has travelled along the path since that dab.
    struct StrokeCursor: Sendable, Equatable {
        var end: SIMD2<Double>
        var lastDab: SIMD2<Double>
        var carry: Double
    }

    /// Two fields are equal when their displacement and freeze mask are: the stroke cursor is
    /// transient brush state, not part of the result.
    public static func == (a: LiquifyField, b: LiquifyField) -> Bool {
        a.bounds == b.bounds && a.cell == b.cell && a.w == b.w && a.h == b.h && a.d == b.d && a.freeze == b.freeze
    }

    public init(bounds: PixelRect, cell c: Double) {
        let cell = clampR(c, 1, 64)
        self.bounds = bounds
        self.cell = cell
        w = toUsize((Double(bounds.width) / cell).rounded(.up)) + 2
        h = toUsize((Double(bounds.height) / cell).rounded(.up)) + 2
        d = [SIMD2<Float>](repeating: .zero, count: w * h)
        freeze = [Float](repeating: 0, count: w * h)
    }

    /// Replays strokes on a fresh field.
    public static func fromStrokes(bounds: PixelRect, cell: Double, strokes: [LiquifyStroke]) -> LiquifyField {
        var f = LiquifyField(bounds: bounds, cell: cell)
        for s in strokes { f.applyStroke(s) }
        return f
    }

    /// Document position of node (i, j) (node 0 sits on the first pixel centre).
    @inline(__always)
    public func nodePos(_ i: Int, _ j: Int) -> SIMD2<Double> {
        SIMD2(Double(bounds.x0) + 0.5 + Double(i) * cell, Double(bounds.y0) + 0.5 + Double(j) * cell)
    }

    /// Field coordinates of a document point.
    @inline(__always)
    func toGrid(_ x: Double, _ y: Double) -> (Double, Double) {
        ((x - Double(bounds.x0) - 0.5) / cell, (y - Double(bounds.y0) - 0.5) / cell)
    }

    public var isIdentity: Bool { d.allSatisfy { $0.x == 0 && $0.y == 0 } }

    /// Largest displacement magnitude (px).
    public var maxDisplacement: Float { d.reduce(Float(0)) { fmaxf($0, hypotf($1.x, $1.y)) } }

    /// Bilinear displacement at a document point (zero outside the field).
    public func sample(_ x: Double, _ y: Double) -> SIMD2<Double> {
        let (gx, gy) = toGrid(x, y)
        return Liquify.bilinear(d, w, h, gx, gy)
    }

    /// Freeze value at a document point (bilinear).
    public func freezeAt(_ x: Double, _ y: Double) -> Float {
        var (gx, gy) = toGrid(x, y)
        gx = clampR(gx, 0, Double(w - 1)); gy = clampR(gy, 0, Double(h - 1))
        let i = min(toUsize(gx), w - 2), j = min(toUsize(gy), h - 2)
        let fx = Float(gx - Double(i)), fy = Float(gy - Double(j))
        func at(_ i: Int, _ j: Int) -> Float { freeze[j * w + i] }
        return (at(i, j) * (1 - fx) + at(i + 1, j) * fx) * (1 - fy) + (at(i, j + 1) * (1 - fx) + at(i + 1, j + 1) * fx) * fy
    }

    /// Applies one stroke; returns the document rectangle whose output changed.
    @discardableResult
    public mutating func applyStroke(_ s: LiquifyStroke) -> PixelRect {
        cursor = nil
        switch s.tool {
        case .lassoMask: return applyLasso(s)
        case .reconstructAll:
            let k = Float(clampR((s.amount ?? 100) / 100, 0, 1))
            for i in d.indices {
                let m = 1 - k * (1 - freeze[i])
                d[i].x *= m
                d[i].y *= m
            }
            return bounds
        case .freezeAll: for i in freeze.indices { freeze[i] = 1 }
        case .thawAll: for i in freeze.indices { freeze[i] = 0 }
        case .invertFreeze: for i in freeze.indices { freeze[i] = 1 - freeze[i] }
        default: break
        }
        if s.tool.isGlobal { return bounds }
        let pts: [SIMD3<Double>] = s.points.filter { $0.count >= 2 }.map { SIMD3($0[0], $0[1], $0.count > 2 ? $0[2] : 1) }
        guard let first = pts.first else { return .empty }
        var dirty = strokeBegin(s, first)
        for k in pts.indices.dropFirst() {
            dirty = dirty.union(strokeSegment(s, pts[k - 1], pts[k]))
        }
        return dirty
    }

    /// Lasso: sets the freeze mask to `amount` (1 when none; 0 thaws) at every node inside the
    /// closed polygon in `s.points` (even-odd rule, non-finite points skipped), one scanline per
    /// node row. Returns the document rectangle the mask changed in.
    mutating func applyLasso(_ s: LiquifyStroke) -> PixelRect {
        let poly: [SIMD2<Double>] = s.points.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }.filter { $0.x.isFinite && $0.y.isFinite }
        if poly.count < 3 || w == 0 || h == 0 { return .empty }
        var (px0, py0, px1, py1) = (Double.infinity, Double.infinity, -Double.infinity, -Double.infinity)
        for p in poly { px0 = fmin(px0, p.x); py0 = fmin(py0, p.y); px1 = fmax(px1, p.x); py1 = fmax(py1, p.y) }
        let gy0 = toGrid(px0, py0).1, gy1 = toGrid(px1, py1).1
        let lastRow = Double(max(h - 1, 0)), lastCol = Double(max(w - 1, 0))
        let j0 = fmax(gy0.rounded(.up), 0), j1 = fmin(gy1.rounded(.down), lastRow)
        if j1 < j0 { return .empty }
        let v: Float = (s.amount ?? 1) > 0.5 ? 1 : 0
        var xs: [Double] = []
        for j in toUsize(j0)...toUsize(j1) {
            let y = nodePos(0, j).y
            xs.removeAll(keepingCapacity: true)
            var prev = poly[poly.count - 1]
            for a in poly {
                if (a.y > y) != (prev.y > y) { xs.append(a.x + (y - a.y) * (prev.x - a.x) / (prev.y - a.y)) }
                prev = a
            }
            xs.sort()
            // Even-odd: nodes with xs[2k] <= x < xs[2k + 1] are inside.
            var k = 0
            while k + 1 < xs.count {
                let ga = toGrid(xs[k], y).0, gb = toGrid(xs[k + 1], y).0
                let i0 = fmax(ga.rounded(.up), 0), i1 = fmin(gb.rounded(.up) - 1, lastCol)
                k += 2
                if i1 < i0 { continue }
                let row = j * w
                for i in toUsize(i0)...toUsize(i1) { freeze[row + i] = v }
            }
        }
        return PixelRect(x0: ResampleKit.i32(px0.rounded(.down)), y0: ResampleKit.i32(py0.rounded(.down)),
                         x1: ResampleKit.i32(px1.rounded(.up)), y1: ResampleKit.i32(py1.rounded(.up))).intersect(bounds)
    }

    /// Starts a stroke at `p` (`[x, y, pressure]`): stationary tools dab once there. Interactive
    /// callers use this plus `strokeSegment` per new point, which is what `applyStroke` does.
    @discardableResult
    public mutating func strokeBegin(_ s: LiquifyStroke, _ p: SIMD3<Double>) -> PixelRect {
        cursor = StrokeCursor(end: SIMD2(p.x, p.y), lastDab: SIMD2(p.x, p.y), carry: 0)
        if s.tool.isStationary && !s.tool.isGlobal { return dab(s, SIMD2(p.x, p.y), .zero, clampR(p.z, 0, 1), 1) }
        return .empty
    }

    /// Continues a stroke from `a` to `b`. Dabs fall every `dabSpacing` of distance travelled
    /// along the whole stroke, carried from one segment to the next, so a fast and a slow mouse
    /// give one warp. A stationary tool held still dabs once at `b`; when `a` is not where the
    /// previous segment ended, the stroke starts afresh at `a`.
    @discardableResult
    public mutating func strokeSegment(_ s: LiquifyStroke, _ a: SIMD3<Double>, _ b: SIMD3<Double>) -> PixelRect {
        walkSegment(s, a, b, skip: true)
    }

    /// `strokeSegment`; `skip` leaves out the dabs that cannot reach a field node.
    mutating func walkSegment(_ s: LiquifyStroke, _ a: SIMD3<Double>, _ b: SIMD3<Double>, skip: Bool) -> PixelRect {
        var dirty = PixelRect.empty
        let pa = clampR(a.z, 0, 1), pb = clampR(b.z, 0, 1)
        let stationary = s.tool.isStationary
        let cur: StrokeCursor
        if let c = cursor, c.end.x == a.x && c.end.y == a.y { cur = c } else { cur = StrokeCursor(end: SIMD2(a.x, a.y), lastDab: SIMD2(a.x, a.y), carry: 0) }
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        if len == 0 {
            cursor = cur
            return stationary ? dab(s, SIMD2(b.x, b.y), .zero, pb, 1) : dirty
        }
        // NaN or a length that overflowed: nothing sensible to walk; the next segment restarts.
        if !len.isFinite {
            cursor = nil
            return dirty
        }
        let r = fmax(s.size / 2, 0.5)
        let spacing = Liquify.dabSpacing(r)
        let weight = stationary ? Liquify.movingWeight(r) : 1
        // Distance along this segment of its first dab, then one every `spacing`.
        let first = clampR(spacing - cur.carry, 0, spacing)
        // Slack: a dab that rounding puts a hair past the segment's end still falls on it.
        let slack = spacing * 1e-6
        if first > len + slack {
            cursor = StrokeCursor(end: SIMD2(b.x, b.y), lastDab: cur.lastDab, carry: cur.carry + len)
            return dirty
        }
        let lastK = fmax(((len - first + slack) / spacing).rounded(.down), 0)
        func at(_ dist: Double) -> SIMD2<Double> { SIMD2(a.x + dx * dist / len, a.y + dy * dist / len) }
        var k0 = 0.0, k1 = lastK
        if skip {
            if let (d0, d1) = reachableSpan(a, SIMD2(dx, dy), len, r) {
                // A dragging dab is centred one spacing behind its position: pad by that and a step.
                k0 = fmax(k0, ((d0 - spacing - first) / spacing).rounded(.down) - 1)
                k1 = fmin(k1, ((d1 + spacing - first) / spacing).rounded(.up) + 1)
            } else {
                k1 = -1
            }
        }
        if k0 <= k1 {
            var prev = k0 > 0 ? at(first + (k0 - 1) * spacing) : cur.lastDab
            let kLo = UInt64(toUsize(k0)), kHi = UInt64(toUsize(k1))
            var k = kLo
            while k <= kHi {
                let dist = fmin(first + Double(k) * spacing, len)
                let c = at(dist)
                let delta = c - prev
                // Forward Warp centres the dab where the brush was (it drags what is under it).
                let centre = stationary ? c : prev
                dirty = dirty.union(dab(s, centre, delta, pa + (pb - pa) * dist / len, weight))
                prev = c
                if k == UInt64.max { break }
                k += 1
            }
        }
        let last = fmin(first + lastK * spacing, len)
        cursor = StrokeCursor(end: SIMD2(b.x, b.y), lastDab: at(last), carry: clampR(len - last, 0, spacing))
        return dirty
    }

    /// The distances along a segment from `a` (direction `dir`, length `len`) whose points lie
    /// within a dab radius `r` plus two nodes of the node grid, or nil when none do (photocraft
    /// #937: a segment to a far-off point has trillions of dabs that touch nothing).
    func reachableSpan(_ a: SIMD3<Double>, _ dir: SIMD2<Double>, _ len: Double, _ r: Double) -> (Double, Double)? {
        if w == 0 || h == 0 { return nil }
        let pad = r + 2 * cell
        let lo = SIMD2(Double(bounds.x0) + 0.5 - pad, Double(bounds.y0) + 0.5 - pad)
        let hi = SIMD2(lo.x + Double(w - 1) * cell + 2 * pad, lo.y + Double(h - 1) * cell + 2 * pad)
        var u0 = 0.0, u1 = 1.0
        for ax in 0..<2 {
            let dd = dir[ax], av = a[ax]
            if dd == 0 {
                if av.isNaN || av < lo[ax] || av > hi[ax] { return nil }
                continue
            }
            let v0 = (lo[ax] - av) / dd, v1 = (hi[ax] - av) / dd
            u0 = fmax(u0, fmin(v0, v1))
            u1 = fmin(u1, fmax(v0, v1))
        }
        if u0.isNaN || u1.isNaN || u0 > u1 { return nil }
        return (u0 * len, u1 * len)
    }

    /// One dab at `c` with brush motion `delta`, its strength scaled by `weight`. Returns the
    /// document rectangle it affected.
    mutating func dab(_ s: LiquifyStroke, _ c: SIMD2<Double>, _ delta: SIMD2<Double>, _ pointPressure: Double, _ weight: Double) -> PixelRect {
        if s.tool == .lassoMask { return .empty } // the lasso is polygon-only; never a brush dab
        let r = fmax(s.size / 2, 0.5)
        let strength = clampR(s.pressure / 100, 0, 1) * pointPressure * weight
        let rate = clampR(s.rate / 100, 0, 1)
        let density = clampR(s.density / 100, 0, 1)
        if strength <= 0 { return .empty }
        let (gx0, gy0) = toGrid(c.x - r, c.y - r)
        let (gx1, gy1) = toGrid(c.x + r, c.y + r)
        let i0 = toUsize(fmax(gx0.rounded(.down), 0)), j0 = toUsize(fmax(gy0.rounded(.down), 0))
        let i1 = min(toIsize(fmax(gx1.rounded(.up), -1)), w - 1), j1 = min(toIsize(fmax(gy1.rounded(.up), -1)), h - 1)
        if i1 < i0 || j1 < j0 { return .empty }
        // Snapshot of the affected nodes plus a margin (sampling reads around them).
        let m = toUsize(((fmax(abs(delta.x), abs(delta.y)) + r * 0.2) / cell).rounded(.up)) + 2
        let si0 = max(i0 - m, 0), sj0 = max(j0 - m, 0)
        let si1 = min(i1 + m, w - 1), sj1 = min(j1 + m, h - 1)
        let sw = si1 - si0 + 1, sh = sj1 - sj0 + 1
        var snap: [SIMD2<Float>] = []
        snap.reserveCapacity(sw * sh)
        for j in sj0...sj1 { snap.append(contentsOf: d[(j * w + si0)...(j * w + si1)]) }
        let live = d
        func old(_ gx: Double, _ gy: Double) -> SIMD2<Double> {
            let lx = gx - Double(si0), ly = gy - Double(sj0)
            if lx >= 0 && ly >= 0 && lx <= Double(sw - 1) && ly <= Double(sh - 1) {
                return Liquify.bilinear(snap, sw, sh, lx, ly)
            }
            // Outside the snapshot nothing changed: read the live field.
            return Liquify.bilinear(live, w, h, gx, gy)
        }
        var writes: [(Int, SIMD2<Float>, Float)] = []
        writes.reserveCapacity((i1 - i0 + 1) * (j1 - j0 + 1))
        let invCell = 1 / cell
        for j in j0...j1 {
            for i in i0...i1 {
                let p = nodePos(i, j)
                let dx = p.x - c.x, dy = p.y - c.y
                let t2 = (dx * dx + dy * dy) / (r * r)
                if t2 >= 1 { continue }
                let fall = Liquify.falloff(t2, density)
                let idx = j * w + i
                let kRaw = strength * fall
                if s.tool == .freeze || s.tool == .thaw {
                    let f = freeze[idx]
                    let v = s.tool == .freeze ? fmin(Double(f) + kRaw, 1) : fmax(Double(f) - kRaw, 0)
                    writes.append((idx, d[idx], Float(v)))
                    continue
                }
                let k = kRaw * (1 - Double(freeze[idx]))
                if k <= 0 { continue }
                let cur = d[idx]
                let new: SIMD2<Float>
                switch s.tool {
                case .reconstruct:
                    let a = Float(1 - k * (0.1 + 0.4 * rate))
                    new = SIMD2(cur.x * a, cur.y * a)
                case .smooth:
                    let gx = i - si0, gy = j - sj0
                    func at(_ x: Int, _ y: Int) -> SIMD2<Float> { snap[min(max(y, 0), sh - 1) * sw + min(max(x, 0), sw - 1)] }
                    var mean = SIMD2<Float>(0, 0)
                    for (ox, oy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)] {
                        let v = at(gx + ox, gy + oy)
                        mean.x += v.x / 8
                        mean.y += v.y / 8
                    }
                    let a = Float(k * (0.1 + 0.4 * rate))
                    new = SIMD2(cur.x + (mean.x - cur.x) * a, cur.y + (mean.y - cur.y) * a)
                default:
                    let q: SIMD2<Double>
                    switch s.tool {
                    case .forwardWarp: q = SIMD2(p.x - k * delta.x, p.y - k * delta.y)
                    // Left of the stroke direction (y down): (dx, dy) → (dy, −dx).
                    case .pushLeft: q = SIMD2(p.x - k * delta.y, p.y + k * delta.x)
                    case .twirlCw, .twirlCcw:
                        let th = k * rate * 0.12 * (s.tool == .twirlCw ? 1 : -1)
                        // Content turns by +th, so sample at the point turned by −th.
                        let sn = sin(-th), cs = cos(-th)
                        q = SIMD2(c.x + dx * cs - dy * sn, c.y + dx * sn + dy * cs)
                    case .pucker:
                        let a = 1 + k * rate * 0.06
                        q = SIMD2(c.x + dx * a, c.y + dy * a)
                    default:
                        let a = 1 - k * rate * 0.06
                        q = SIMD2(c.x + dx * a, c.y + dy * a)
                    }
                    let qx = (q.x - p.x) * invCell + Double(i), qy = (q.y - p.y) * invCell + Double(j)
                    let dq = old(qx, qy)
                    new = SIMD2(Float(q.x + dq.x - p.x), Float(q.y + dq.y - p.y))
                }
                writes.append((idx, new, freeze[idx]))
            }
        }
        for (idx, dv, f) in writes {
            d[idx] = dv
            freeze[idx] = f
        }
        let pad = ResampleKit.i32(r.rounded(.up)) &+ 2
        return PixelRect(x0: ResampleKit.i32(c.x.rounded(.down)) &- pad, y0: ResampleKit.i32(c.y.rounded(.down)) &- pad,
                         x1: ResampleKit.i32(c.x.rounded(.up)) &+ pad, y1: ResampleKit.i32(c.y.rounded(.up)) &+ pad).intersect(bounds)
    }

    /// Catmull-Rom displacement at grid coordinates (nodes clamped to the grid).
    func sampleCubic(_ gx: Double, _ gy: Double, _ wx: (Double, Double, Double, Double), _ wy: (Double, Double, Double, Double)) -> SIMD2<Double> {
        let ix = toIsize(gx.rounded(.down)), iy = toIsize(gy.rounded(.down))
        let wxs = [wx.0, wx.1, wx.2, wx.3], wys = [wy.0, wy.1, wy.2, wy.3]
        var acc = SIMD2<Double>(0, 0)
        for jj in 0..<4 {
            let y = min(max(iy &- 1 &+ jj, 0), h - 1)
            for ii in 0..<4 {
                let x = min(max(ix &- 1 &+ ii, 0), w - 1)
                let k = wxs[ii] * wys[jj]
                let v = d[y * w + x]
                acc.x += Double(v.x) * k
                acc.y += Double(v.y) * k
            }
        }
        return acc
    }

    /// Whether any node influencing document rect `r` is displaced.
    func touches(_ r: PixelRect) -> Bool {
        let (gx0, gy0) = toGrid(Double(r.x0), Double(r.y0))
        let (gx1, gy1) = toGrid(Double(r.x1), Double(r.y1))
        let i0 = min(max(toIsize(gx0.rounded(.down)) &- 2, 0), w - 1), j0 = min(max(toIsize(gy0.rounded(.down)) &- 2, 0), h - 1)
        let i1 = min(max(toIsize(gx1.rounded(.up)) &+ 2, 0), w - 1), j1 = min(max(toIsize(gy1.rounded(.up)) &+ 2, 0), h - 1)
        if j1 < j0 || i1 < i0 { return false }
        for j in j0...j1 { for i in i0...i1 where d[j * w + i].x != 0 || d[j * w + i].y != 0 { return true } }
        return false
    }
}

/// Liquify resampling and helpers (photocraft `liquify.rs` free functions).
public enum Liquify {
    /// Distance between dabs along a stroke for brush radius `r`: a twentieth of the radius.
    static func dabSpacing(_ r: Double) -> Double { fmax(r * 0.05, 0.5) }

    /// Per-dab strength of a stationary tool while it moves: scaled to the spacing so its effect
    /// per distance travelled stays what it was with dabs a fifth of the radius apart.
    static func movingWeight(_ r: Double) -> Double { dabSpacing(r) / fmax(r * 0.2, 0.5) }

    /// The default field resolution for `bounds`: 2 px per node up to 4.2 MP, 4 px beyond.
    public static func autoCell(_ bounds: PixelRect) -> Double { bounds.area <= 4_200_000 ? 2 : 4 }

    /// A dab's strength at squared distance `t2` (in brush radii, 0…1) for Density `density`
    /// (0…1): 1 at the centre, 0 with a flat slope at the rim at every density; Density sets how
    /// far the full effect reaches toward the edge (photocraft #2606).
    public static func falloff(_ t2In: Double, _ densityIn: Double) -> Double {
        let t2 = clampR(t2In, 0, 1)
        let density = densityIn.isNaN ? 0.5 : clampR(densityIn, 0, 1)
        // Feathered: (1 − t²)³. Dense: (1 − t⁴)², flat in the middle.
        let u = 1 - t2, v = 1 - t2 * t2
        let feathered = u * u * u
        let dense = v * v
        return feathered + (dense - feathered) * density
    }

    static func bilinear(_ d: [SIMD2<Float>], _ w: Int, _ h: Int, _ gx0: Double, _ gy0: Double) -> SIMD2<Double> {
        if !(gx0 > -1 && gy0 > -1 && gx0 < Double(w) && gy0 < Double(h)) { return .zero }
        let gx = clampR(gx0, 0, Double(w - 1)), gy = clampR(gy0, 0, Double(h - 1))
        let i = min(toUsize(gx), max(w - 2, 0)), j = min(toUsize(gy), max(h - 2, 0))
        let fx = gx - Double(i), fy = gy - Double(j)
        let i1 = min(i + 1, w - 1), j1 = min(j + 1, h - 1)
        let a = d[j * w + i], b = d[j * w + i1], c = d[j1 * w + i], e = d[j1 * w + i1]
        func l(_ k: Int) -> Double {
            (Double(a[k]) * (1 - fx) + Double(b[k]) * fx) * (1 - fy) + (Double(c[k]) * (1 - fx) + Double(e[k]) * fx) * fy
        }
        return SIMD2(l(0), l(1))
    }

    /// Resamples `src` through the field: inside `field.bounds` each pixel shows the source at
    /// `p + d(p)` (Catmull-Rom field and premultiplied Catmull-Rom source, edge pixels repeated past
    /// the field bounds); everything outside the bounds is kept. Same format as `src` (photocraft
    /// `apply_liquify`). `.auto`/`.gpu` run the Metal kernels when the layer fits one GPU pass.
    public static func apply(_ src: Surface, field: LiquifyField, on backend: Backend = .auto) -> Surface {
        var out = src
        let b = field.bounds
        if field.isIdentity || b.isEmpty { return out }
        let fmt = src.format
        let ctx = FilterContext(bounds: b, format: fmt)
        if backend != .cpu, AlgoGPU.isAvailable {
            // Pixels the field may read or write: the bounds (sources are clamped to them).
            let m = FilterEngine.maxGPUSize
            if b.width <= m && b.height <= m && b.area <= 1 << 26 {
                let img = FloatImage(surface: src, rect: b)
                if let r = try? FilterEngine.apply(LiquifyKit.LiquifyFilter(field: field), to: img, output: b, context: ctx, on: .gpu) {
                    // Only the tiles the field touches can change.
                    for t in LiquifyKit.tiles(field) { ResampleKit.write(&out, t, r.crop(t).data) }
                    if fmt.alpha { ResampleKit.prune(&out) }
                    return out
                }
            }
        }
        let n = fmt.channels
        let tiles = LiquifyKit.tiles(field)
        var done = [(PixelRect, [Float])?](repeating: nil, count: tiles.count)
        done.withUnsafeMutableBufferPointer { db in
            let dd = UnsafeSendable(db)
            parallelFor(tiles.count) { i in
                dd.value[i] = LiquifyKit.renderTile(field, tiles[i], n: n, alpha: fmt.alpha) { foot in src.readRegion(foot) }
            }
        }
        for case let (r, v)? in done { ResampleKit.write(&out, r, v) }
        if fmt.alpha { ResampleKit.prune(&out) }
        return out
    }

    /// `apply` on a dense image (0 outside it); the result covers `img.rect`.
    public static func apply(_ img: FloatImage, field: LiquifyField, context: FilterContext? = nil, on backend: Backend = .auto) throws -> FloatImage {
        let ctx = context ?? FilterContext.inferred(channels: img.channels, bounds: img.rect)
        if field.isIdentity || field.bounds.isEmpty || img.rect.isEmpty { return img }
        let m = FilterEngine.maxGPUSize
        let b = field.bounds
        let fits = max(img.width, img.height, b.width, b.height) <= m && b.area <= 1 << 26
        let useGPU: Bool
        switch backend {
        case .cpu: useGPU = false
        case .gpu:
            guard fits else { throw FilterError.gpuUnsupported("Liquify larger than \(m) px") }
            useGPU = true
        case .auto: useGPU = fits && AlgoGPU.isAvailable
        }
        return try FilterEngine.apply(LiquifyKit.LiquifyFilter(field: field), to: img, output: img.rect, context: ctx, on: useGPU ? .gpu : .cpu)
    }
}

enum LiquifyKit {
    /// The tiles of the field bounds whose output may change (256-px grid, clipped).
    static func tiles(_ field: LiquifyField) -> [PixelRect] {
        TransformKit.tiles(field.bounds).filter { field.touches($0) }
    }

    /// One tile of `apply_liquify`: nil when nothing moved in it. `read` returns the source over a
    /// rectangle (interleaved).
    static func renderTile(_ field: LiquifyField, _ t: PixelRect, n: Int, alpha: Bool, read: (PixelRect) -> [Float]) -> (PixelRect, [Float])? {
        let b = field.bounds
        let maxd = ResampleKit.i32(Double(field.maxDisplacement).rounded(.up)) &+ 3
        let w = t.width, h = t.height
        // Field per pixel (Catmull-Rom); rows share their y weights.
        var disp = [SIMD2<Double>](repeating: .zero, count: w * h)
        var (fx0, fy0, fx1, fy1) = (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
        var moved = false
        for y in 0..<h {
            let py = Double(t.y0) + Double(y) + 0.5
            let gy = (py - Double(b.y0) - 0.5) / field.cell
            let wy = TransformKit.catmullRom(gy - gy.rounded(.down))
            for x in 0..<w {
                let px = Double(t.x0) + Double(x) + 0.5
                let gx = (px - Double(b.x0) - 0.5) / field.cell
                let wx = TransformKit.catmullRom(gx - gx.rounded(.down))
                let d = field.sampleCubic(gx, gy, wx, wy)
                if d.x != 0 || d.y != 0 { moved = true }
                disp[y * w + x] = d
                let sx = px + d.x, sy = py + d.y
                fx0 = fmin(fx0, sx); fy0 = fmin(fy0, sy); fx1 = fmax(fx1, sx); fy1 = fmax(fy1, sy)
            }
        }
        if !moved { return nil }
        let foot = PixelRect(x0: ResampleKit.i32(fx0.rounded(.down)) &- 3, y0: ResampleKit.i32(fy0.rounded(.down)) &- 3,
                             x1: ResampleKit.i32(fx1.rounded(.up)) &+ 3, y1: ResampleKit.i32(fy1.rounded(.up)) &+ 3)
            .intersect(t.outset(by: maxd)).intersect(b)
        if foot.isEmpty { return nil }
        var px = read(foot)
        premultiply(&px, n, alpha)
        let fw = foot.width
        @inline(__always) func at(_ x: Int32, _ y: Int32) -> Int {
            let cx = min(max(x, foot.x0), foot.x1 - 1), cy = min(max(y, foot.y0), foot.y1 - 1)
            return (Int(cy - foot.y0) * fw + Int(cx - foot.x0)) * n
        }
        func snap(_ v: Double) -> Double { abs(v - v.rounded()) < 1e-7 ? v.rounded() : v }
        var outp = [Float](repeating: 0, count: w * h * n)
        var acc = [Double](repeating: 0, count: n)
        for y in 0..<h {
            for x in 0..<w {
                let d = disp[y * w + x]
                let u = snap(Double(t.x0) + Double(x) + d.x), v = snap(Double(t.y0) + Double(y) + d.y)
                let ix = ResampleKit.i32(u.rounded(.down)), iy = ResampleKit.i32(v.rounded(.down))
                let cx = TransformKit.catmullRom(u - Double(ix)), cy = TransformKit.catmullRom(v - Double(iy))
                let wx = [cx.0, cx.1, cx.2, cx.3], wy = [cy.0, cy.1, cy.2, cy.3]
                for c in 0..<n { acc[c] = 0 }
                for j in 0..<4 {
                    for i in 0..<4 {
                        let k = wx[i] * wy[j]
                        if k == 0 { continue }
                        let o = at(ix &- 1 &+ Int32(i), iy &- 1 &+ Int32(j))
                        for c in 0..<n { acc[c] += Double(px[o + c]) * k }
                    }
                }
                let o = (y * w + x) * n
                if alpha {
                    let al = clampR(acc[n - 1], 0, 1)
                    outp[o + n - 1] = Float(al)
                    for c in 0..<(n - 1) { outp[o + c] = al > 0 ? Float(clampR(acc[c] / al, 0, 1)) : 0 }
                } else {
                    for c in 0..<n { outp[o + c] = Float(clampR(acc[c], 0, 1)) }
                }
            }
        }
        return (t, outp)
    }

    /// MSL `pca_rs_liquify_params`.
    struct Params: BitwiseCopyable {
        var bOrigin: SIMD2<Int32>
        var bSize: SIMD2<Int32>
        var grid: SIMD2<Int32>
        /// Tile grid origin (document) and tile columns.
        var tileOrigin: SIMD2<Int32>
        var tilesX: Int32
        var maxd: Int32
        var cell: Float
        var pad0: Int32 = 0
    }

    /// Liquify as a filter over the image rectangle: CPU `renderTile` per touched tile; Metal: the
    /// field upsampled per pixel of the bounds (marking the tiles where it moves), then the
    /// premultiplied Catmull-Rom source sampling.
    struct LiquifyFilter: Filter {
        var field: LiquifyField
        var label: String { "Liquify" }
        func halo(bounds: PixelRect) -> Halo { .bounds }

        func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
            var res = src.crop(out)
            let n = src.channels
            let tiles = LiquifyKit.tiles(field).filter { !$0.intersect(out).isEmpty }
            var done = [(PixelRect, [Float])?](repeating: nil, count: tiles.count)
            done.withUnsafeMutableBufferPointer { db in
                let dd = UnsafeSendable(db)
                parallelFor(tiles.count) { i in
                    dd.value[i] = LiquifyKit.renderTile(field, tiles[i], n: n, alpha: ctx.alpha) { src.crop($0).data }
                }
            }
            for case let (t, v)? in done {
                let inner = t.intersect(out)
                for y in inner.y0..<inner.y1 {
                    let si = (Int(y - t.y0) * t.width + Int(inner.x0 - t.x0)) * n
                    let di = res.index(x: inner.x0, y: y)
                    for i in 0..<(inner.width * n) { res.data[di + i] = v[si + i] }
                }
            }
            return res
        }

        func encodeGPU(_ pass: GPUPass) throws {
            let b = field.bounds
            let ts = tileSize
            let tx0 = ResampleKit.floorDiv(b.x0, ts), ty0 = ResampleKit.floorDiv(b.y0, ts)
            let tilesX = Int(ResampleKit.floorDiv(b.x1 - 1, ts) - tx0) + 1, tilesY = Int(ResampleKit.floorDiv(b.y1 - 1, ts) - ty0) + 1
            var touched = [UInt32](repeating: 0, count: tilesX * tilesY)
            for t in LiquifyKit.tiles(field) {
                touched[Int(ResampleKit.floorDiv(t.y0, ts) - ty0) * tilesX + Int(ResampleKit.floorDiv(t.x0, ts) - tx0)] = 1
            }
            let p = Params(bOrigin: SIMD2(b.x0, b.y0), bSize: SIMD2(Int32(b.width), Int32(b.height)), grid: SIMD2(Int32(field.w), Int32(field.h)),
                           tileOrigin: SIMD2(tx0 * ts, ty0 * ts), tilesX: Int32(tilesX),
                           maxd: ResampleKit.i32(Double(field.maxDisplacement).rounded(.up)) &+ 3, cell: Float(field.cell))
            let nodes = try pass.buffer(field.d)
            let touchedB = try pass.buffer(touched)
            let moved = try pass.buffer([UInt32](repeating: 0, count: tilesX * tilesY))
            let disp = try pass.texture(b)
            try pass.dispatch("pca_rs_liquify_field", params: p, textures: [disp], buffers: [nodes, touchedB, moved], width: b.width, height: b.height)
            try pass.dispatchOut("pca_rs_liquify", params: p, textures: [pass.src, disp, pass.dst], buffers: [nodes, touchedB, moved])
        }
    }
}

// MARK: - Preview

extension Liquify {
    /// A downsampled, premultiplied RGBA copy of a layer for the interactive preview (photocraft
    /// `ProxyImage`).
    public struct ProxyImage: Sendable {
        /// Document region the proxy covers (the field bounds).
        public var bounds: PixelRect
        /// Document pixels per proxy pixel.
        public var scale: Double
        public var w: Int
        public var h: Int
        /// Premultiplied RGBA, row-major.
        public var px: [SIMD4<Float>]

        static let maxFullResSourcePixels = 8 * 1024 * 1024

        /// Box-downsamples `src` over `bounds` so the longer side is at most `maxSide`.
        public init(_ src: Surface, bounds: PixelRect, maxSide: Int) {
            let side = Double(max(bounds.width, bounds.height, 1))
            let scale = fmax(side / Double(max(maxSide, 1)), 1).rounded(.up)
            let w = max(toUsize((Double(bounds.width) / scale).rounded(.up)), 1)
            let h = max(toUsize((Double(bounds.height) / scale).rounded(.up)), 1)
            let k = Int32(scale)
            var px = [SIMD4<Float>](repeating: .zero, count: w * h)
            let alpha = src.format.alpha
            px.withUnsafeMutableBufferPointer { pb in
                let pp = UnsafeSendable(pb)
                parallelFor(h) { y in
                    let r = PixelRect(x0: bounds.x0, y0: bounds.y0 + Int32(y) * k, x1: bounds.x0 + Int32(w) * k,
                                      y1: min(bounds.y0 + (Int32(y) + 1) * k, bounds.y1))
                    if r.isEmpty { return }
                    let buf = src.readRGBA(r)
                    let rw = r.width
                    for x in 0..<w {
                        var acc = SIMD4<Float>(repeating: 0)
                        var cnt: Float = 0
                        for yy in 0..<r.height {
                            var xx = x * Int(k)
                            while xx < min((x + 1) * Int(k), rw) {
                                let p = buf[yy * rw + xx]
                                let a: Float = alpha ? p[3] : 1
                                acc[0] += p[0] * a; acc[1] += p[1] * a; acc[2] += p[2] * a; acc[3] += a
                                cnt += 1
                                xx += 1
                            }
                        }
                        if cnt > 0 { pp.value[y * w + x] = SIMD4(acc[0] / cnt, acc[1] / cnt, acc[2] / cnt, acc[3] / cnt) }
                    }
                }
            }
            self.bounds = bounds; self.scale = scale; self.w = w; self.h = h; self.px = px
        }

        /// Renders proxy pixels `r` (`[x0, y0, x1, y1]`, proxy coordinates) through the field into
        /// `out` (premultiplied RGBA8, `w × h`): bilinear field, bilinear source.
        public func render(_ field: LiquifyField, _ r: [Int], into out: inout [SIMD4<UInt8>]) {
            let x0 = min(r[0], w), y0 = min(r[1], h), x1 = min(r[2], w), y1 = min(r[3], h)
            if x0 >= x1 || y0 >= y1 { return }
            let s = scale, bx = Double(bounds.x0), by = Double(bounds.y0)
            let (pw, ph, pxs) = (w, h, px)
            out.withUnsafeMutableBufferPointer { ob in
                let o = UnsafeSendable(ob)
                let row = { (y: Int) in
                    let py = by + (Double(y) + 0.5) * s
                    for x in x0..<x1 {
                        let pxd = bx + (Double(x) + 0.5) * s
                        let d = field.sample(pxd, py)
                        let u = (pxd + d.x - bx) / s - 0.5, v = (py + d.y - by) / s - 0.5
                        let iu = u.rounded(.down), iv = v.rounded(.down)
                        let fu = Float(u - iu), fv = Float(v - iv)
                        func at(_ x: Double, _ y: Double) -> SIMD4<Float> {
                            pxs[toUsize(clampR(y, 0, Double(ph - 1))) * pw + toUsize(clampR(x, 0, Double(pw - 1)))]
                        }
                        let a = at(iu, iv), b = at(iu + 1, iv), c = at(iu, iv + 1), e = at(iu + 1, iv + 1)
                        var q = SIMD4<UInt8>(repeating: 0)
                        for k in 0..<4 {
                            let val = (a[k] * (1 - fu) + b[k] * fu) * (1 - fv) + (c[k] * (1 - fu) + e[k] * fu) * fv
                            q[k] = UInt8(min(max(val, 0), 1) * 255 + 0.5)
                        }
                        o.value[y * pw + x] = q
                    }
                }
                // A dab's few thousand pixels are faster on this thread than waking the pool.
                if (x1 - x0) * (y1 - y0) > 150_000 { parallelFor(y1 - y0) { row(y0 + $0) } } else { for y in y0..<y1 { row(y) } }
            }
        }

        /// Renders a document-pixel-resolution preview of `region` into the corresponding part of
        /// `out` (which covers `bounds`). Source reads are limited to the region plus the
        /// displacement range that can affect it; `sourceScratch` is reused between updates.
        public static func renderFullResolution(_ src: Surface, field: LiquifyField, bounds b0: PixelRect, region r0: PixelRect,
                                                out: inout [SIMD4<UInt8>], sourceScratch: inout [SIMD4<Float>]) -> Bool {
            let bounds = b0.intersect(field.bounds)
            let region = r0.intersect(bounds)
            let width = bounds.width, height = bounds.height
            if region.isEmpty || out.count != width * height || width == 0 || height == 0 { return false }
            // Bilinear field interpolation is a convex combination of its surrounding nodes, whose
            // extrema bound every source sample in this output rectangle.
            var (minDx, minDy, maxDx, maxDy) = (Float.infinity, Float.infinity, -Float.infinity, -Float.infinity)
            let (gx0, gy0) = field.toGrid(Double(region.x0) + 0.5, Double(region.y0) + 0.5)
            let (gx1, gy1) = field.toGrid(Double(region.x1) - 0.5, Double(region.y1) - 0.5)
            let i0 = toUsize(fmax(gx0.rounded(.down), 0)), j0 = toUsize(fmax(gy0.rounded(.down), 0))
            let i1 = toUsize(fmax(gx1.rounded(.up), 0)), j1 = toUsize(fmax(gy1.rounded(.up), 0))
            if j0 <= min(j1, max(field.h - 1, 0)) && i0 <= min(i1, max(field.w - 1, 0)) {
                for j in j0...min(j1, max(field.h - 1, 0)) {
                    for i in i0...min(i1, max(field.w - 1, 0)) {
                        let idx = j * field.w + i
                        if idx >= field.d.count { continue }
                        let v = field.d[idx]
                        minDx = fminf(minDx, v.x); minDy = fminf(minDy, v.y); maxDx = fmaxf(maxDx, v.x); maxDy = fmaxf(maxDy, v.y)
                    }
                }
            }
            if !minDx.isFinite || !minDy.isFinite || !maxDx.isFinite || !maxDy.isFinite { return false }
            // Source coordinates are pixel centres: one sample on each side for bilinear, clamped to
            // the document as the proxy renderer does.
            let x0 = (Double(region.x0) + Double(minDx)).rounded(.down) - 1
            let y0 = (Double(region.y0) + Double(minDy)).rounded(.down) - 1
            let x1 = (Double(region.x1 - 1) + Double(maxDx)).rounded(.up) + 2
            let y1 = (Double(region.y1 - 1) + Double(maxDy)).rounded(.up) + 2
            let canvas = field.bounds
            func cl(_ v: Double, _ lo: Int32, _ hi: Int32) -> Int32 { ResampleKit.i32(fmin(fmax(v, Double(lo)), Double(hi))) }
            let srcRect = PixelRect(x0: cl(x0, canvas.x0, canvas.x1), y0: cl(y0, canvas.y0, canvas.y1), x1: cl(x1, canvas.x0, canvas.x1), y1: cl(y1, canvas.y0, canvas.y1))
            if srcRect.isEmpty { return false }
            let sw = srcRect.width, sh = srcRect.height
            if sw * sh > maxFullResSourcePixels { return false }
            sourceScratch = src.readRGBA(srcRect)
            if !src.format.alpha { for i in sourceScratch.indices { sourceScratch[i][3] = 1 } }
            for i in sourceScratch.indices {
                let a = sourceScratch[i][3]
                sourceScratch[i][0] *= a; sourceScratch[i][1] *= a; sourceScratch[i][2] *= a
            }
            let ox0 = Int(region.x0 - bounds.x0), ox1 = Int(region.x1 - bounds.x0)
            let oy0 = Int(region.y0 - bounds.y0), oy1 = Int(region.y1 - bounds.y0)
            let scratch = sourceScratch
            func sourceAt(_ x: Double, _ y: Double) -> SIMD4<Float> {
                let fx = clampR(x - 0.5, Double(canvas.x0), Double(canvas.x1 - 1))
                let fy = clampR(y - 0.5, Double(canvas.y0), Double(canvas.y1 - 1))
                let ix = fx.rounded(.down), iy = fy.rounded(.down)
                let tx = Float(fx - ix), ty = Float(fy - iy)
                let sx0 = min(max(ResampleKit.i32(ix), srcRect.x0), srcRect.x1 - 1)
                let sy0 = min(max(ResampleKit.i32(iy), srcRect.y0), srcRect.y1 - 1)
                let sx1 = min(sx0 + 1, srcRect.x1 - 1), sy1 = min(sy0 + 1, srcRect.y1 - 1)
                func at(_ sx: Int32, _ sy: Int32) -> SIMD4<Float> {
                    let i = Int(sy - srcRect.y0) * sw + Int(sx - srcRect.x0)
                    return i < scratch.count ? scratch[i] : .zero
                }
                let a = at(sx0, sy0), b = at(sx1, sy0), c = at(sx0, sy1), d = at(sx1, sy1)
                var r = SIMD4<Float>(repeating: 0)
                for k in 0..<4 { r[k] = (a[k] * (1 - tx) + b[k] * tx) * (1 - ty) + (c[k] * (1 - tx) + d[k] * tx) * ty }
                return r
            }
            out.withUnsafeMutableBufferPointer { ob in
                let o = UnsafeSendable(ob)
                let renderRow = { (yy: Int) in
                    let y = bounds.y0 + Int32(yy)
                    for xx in ox0..<ox1 {
                        let x = bounds.x0 + Int32(xx)
                        let p = SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                        let d = field.sample(p.x, p.y)
                        let rgba = sourceAt(p.x + d.x, p.y + d.y)
                        var q = SIMD4<UInt8>(repeating: 0)
                        for k in 0..<4 { q[k] = UInt8(min(max(rgba[k], 0), 1) * 255 + 0.5) }
                        o.value[yy * width + xx] = q
                    }
                }
                if (ox1 - ox0) * (oy1 - oy0) > 150_000 { parallelFor(oy1 - oy0) { renderRow(oy0 + $0) } } else { for y in oy0..<oy1 { renderRow(y) } }
            }
            _ = sh
            return true
        }

        /// The proxy pixel rectangle covering document rect `r`.
        public func proxyRect(_ r: PixelRect) -> [Int] {
            let s = scale
            func f(_ v: Int32, _ o: Int32) -> Double { fmax(Double(v - o) / s, 0) }
            return [toUsize(f(r.x0, bounds.x0).rounded(.down)), toUsize(f(r.y0, bounds.y0).rounded(.down)),
                    min(toUsize(f(r.x1, bounds.x0).rounded(.up)) + 1, w), min(toUsize(f(r.y1, bounds.y0).rounded(.up)) + 1, h)]
        }
    }
}
