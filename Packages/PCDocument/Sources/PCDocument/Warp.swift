// Warp geometry shared by Edit › Transform › Warp, smart-object warps and Warp Text.
// Port of photocraft-geom (crates/geom/src/warp.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Two kinds of warp, both forward maps from a source box to document space:
// - Styles (`WarpStyle`, Photoshop's fifteen presets plus bend and horizontal/vertical
//   distortion, the PSD `warp` descriptor's `warpStyle`/`warpValue`/`warpPerspective*`). Each is a
//   single bicubic Bezier patch whose control grid follows the bend: measured from Photoshop's
//   renders (see `presetGrid`), not taken from Adobe's code. Every style is the identity at bend 0
//   and continuous in the bend.
// - Custom meshes (`BezierMesh`): a grid of bicubic Bezier patches. The default is one patch (a
//   4×4 control grid); split warps add patch rows/columns by exact de Casteljau subdivision, so
//   splitting never changes the shape.
//
// Pure geometry: resampling lives in PCAlgo. Points are `SIMD2<Double>`; boxes are
// `SIMD4<Double>` = `[x0, y0, x1, y1]` (photocraft's `[f64; 4]`, encoded the same way).

import Foundation
import simd

/// Warp style: none, a custom mesh, or one of Photoshop's presets (menu order). JSON: camelCase
/// names (`"arcLower"`).
public enum WarpStyle: String, CaseIterable, Hashable, Sendable, Codable {
    case none, custom, arc, arcLower, arcUpper, arch, bulge, shellLower, shellUpper, flag, wave, fish, rise, fisheye, inflate, squeeze, twist

    /// The fifteen presets in Photoshop's menu order.
    public static let presets: [WarpStyle] = [
        .arc, .arcLower, .arcUpper, .arch, .bulge, .shellLower, .shellUpper, .flag, .wave, .fish, .rise, .fisheye, .inflate, .squeeze, .twist,
    ]

    /// Every style (none, custom, presets).
    public static var all: [WarpStyle] { allCases }

    /// PSD `warpStyle` enum value (`warpArc`, `warpCustom`, `warpNone`…).
    public var psdName: String { "warp" + rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Short id used by commands (`arc`, `arcLower`, `custom`, `none`).
    public var id: String { rawValue }

    /// Menu label (`Arc Lower`).
    public var label: String {
        switch self {
        case .none: "None"
        case .custom: "Custom"
        case .arc: "Arc"
        case .arcLower: "Arc Lower"
        case .arcUpper: "Arc Upper"
        case .arch: "Arch"
        case .bulge: "Bulge"
        case .shellLower: "Shell Lower"
        case .shellUpper: "Shell Upper"
        case .flag: "Flag"
        case .wave: "Wave"
        case .fish: "Fish"
        case .rise: "Rise"
        case .fisheye: "Fisheye"
        case .inflate: "Inflate"
        case .squeeze: "Squeeze"
        case .twist: "Twist"
        }
    }

    /// Parses a short id, a PSD name or a label (case-insensitive, spaces ignored).
    public static func parse(_ s: String) -> WarpStyle? {
        let k = String(s.filter { !$0.isWhitespace }).lowercased()
        return all.first { $0.id.lowercased() == k || $0.psdName.lowercased() == k }
    }

    public var isPreset: Bool { self != .none && self != .custom }
}

typealias GridRow = [SIMD2<Double>]
/// A single bicubic Bezier patch's control points, `[row][column]`, in box units.
typealias Grid = [GridRow]

/// Rust's `clamp(0.0, 1.0)`: NaN stays NaN.
@inline(__always) func clamp01(_ v: Double) -> Double { v < 0 ? 0 : (v > 1 ? 1 : v) }

/// A preset style prepared for one box: its control grid and the box it bends.
public struct StyleWarp: Sendable {
    /// The 4 × 4 Bezier control grid in box units (0..1, y down), row-major.
    let grid: Grid
    /// Box origin and size.
    let origin: SIMD2<Double>
    let size: SIMD2<Double>

    /// Prepares `style` with bend / distortions in percent (-100..100) for `[x0, y0, x1, y1]`.
    /// nil for non-presets, an all-zero warp or an empty box.
    public init?(style: WarpStyle, bend: Double, hDistort: Double, vDistort: Double, vertical: Bool, bounds: SIMD4<Double>) {
        guard style.isPreset else { return nil }
        let (hw, hh) = ((bounds.z - bounds.x) / 2, (bounds.w - bounds.y) / 2)
        guard hw > 0 && hh > 0 else { return nil }
        func pct(_ v: Double) -> Double { v.isFinite ? min(max(v / 100, -1), 1) : 0 }
        let (b, hd, vd) = (pct(bend), pct(hDistort), pct(vDistort))
        if b == 0 && hd == 0 && vd == 0 { return nil }
        grid = presetGrid(style, b, hd, vd, vertical, hh / hw)
        origin = SIMD2(bounds.x, bounds.y)
        size = SIMD2(2 * hw, 2 * hh)
    }

    /// Longest segment (px) worth sending through `apply` unsplit.
    public var maxSegment: Double { max(min(size.x, size.y) / 32, 0.5) }

    /// Maps a point.
    public func apply(_ x: Double, _ y: Double) -> SIMD2<Double> {
        let (u, v) = ((x - origin.x) / size.x, (y - origin.y) / size.y)
        let (bu, bv) = (bernstein(u), bernstein(v))
        var (px, py) = (0.0, 0.0)
        for (row, wv) in zip(grid, bv) {
            for (p, wu) in zip(row, bu) {
                px += wu * wv * p.x
                py += wu * wv * p.y
            }
        }
        return SIMD2(origin.x + px * size.x, origin.y + py * size.y)
    }

    /// The style as one Bezier patch over its box (every preset is one exactly).
    public var mesh: BezierMesh {
        let points = grid.flatMap { $0 }.map { SIMD2(origin.x + $0.x * size.x, origin.y + $0.y * size.y) }
        return BezierMesh(us: [0, 1], vs: [0, 1], points: points)
    }
}

/// The rest grid (no warp).
func restGrid() -> Grid {
    (0..<4).map { j in (0..<4).map { i in SIMD2(Double(i) / 3, Double(j) / 3) } }
}

/// A horizontal edge at height `y` (box units, 0..1 across) bent into a circular arc of `|b|·π`
/// that keeps its chord, bowing up when `up == (b > 0)`. `h` is the box's height over its width:
/// the arc is circular in pixels.
func edgeArc(_ y: Double, _ b: Double, _ up: Bool, _ h: Double) -> GridRow {
    if abs(b) < 1e-9 { return (0..<4).map { SIMD2(Double($0) / 3, y) } }
    let th = abs(b) * Double.pi
    let k = 4.0 / 3.0 * tan(th / 4) * 0.5 / sin(th / 2)
    let s: Double = (b > 0) == up ? -1 : 1
    let (c, n) = (cos(th / 2), sin(th / 2))
    let dy = s * k * n / h
    return [SIMD2(0, y), SIMD2(k * c, y + dy), SIMD2(1 - k * c, y + dy), SIMD2(1, y)]
}

/// Arc: every row is a circular arc of `|b|·π` around one centre; the edge on the inside of the
/// bend keeps its chord, and the rows' radii grow by the box height towards the other edge.
/// Worked in units of the box width (`h` = height / width) so the arcs are circular in pixels.
func arcGrid(_ b: Double, _ h: Double) -> Grid {
    if abs(b) < 1e-9 { return restGrid() }
    let up = b > 0
    let th = abs(b) * Double.pi
    let r = 0.5 / sin(th / 2)
    let k = 4.0 / 3.0 * tan(th / 4)
    let s: Double = up ? -1 : 1
    let cy = up ? h + r * cos(th / 2) : -r * cos(th / 2)
    return (0..<4).map { j in
        let v = Double(j) / 3
        let big = r + h * (up ? 1 - v : v)
        func at(_ a: Double) -> SIMD2<Double> { SIMD2(0.5 + big * sin(a), cy + s * big * cos(a)) }
        func tangent(_ a: Double) -> SIMD2<Double> { SIMD2(cos(a), -s * sin(a)) }
        let (p0, p3, t0, t1) = (at(-th / 2), at(th / 2), tangent(-th / 2), tangent(th / 2))
        let l = k * big
        let pts = [p0, SIMD2(p0.x + l * t0.x, p0.y + l * t0.y), SIMD2(p3.x - l * t1.x, p3.y - l * t1.y), p3]
        return pts.map { SIMD2($0.x, $0.y / h) }
    }
}

/// Rows blended from `top` to `bottom`.
func blendRows(_ top: GridRow, _ bottom: GridRow) -> Grid {
    (0..<4).map { j in
        let t = Double(j) / 3
        return (0..<4).map { i in SIMD2(top[i].x + (bottom[i].x - top[i].x) * t, top[i].y + (bottom[i].y - top[i].y) * t) }
    }
}

/// Photoshop's warp presets as Bezier control grids, measured on Photoshop 27.11: every preset at
/// bend ±50 and ±100, Arc and Bulge with ±50 horizontal and vertical distortion, and the vertical
/// orientation, each fitted from scripted renders of a coordinate-coded grid image (every preset
/// is a single bicubic patch, within 0.5 px). These grids put Photoshop's pixels back within 1 px
/// (median) on all 70 cases, and on 32 more on 256 × 96 and 96 × 256 boxes, vertical, and with
/// both distortions: the arc family stays circular in pixels, the other offsets scale with the box,
/// and a vertical warp is the horizontal one with the axes (and distortions) swapped.
/// `b`, `hd`, `vd` are -1..1; `aspect` is the box's height over its width.
func presetGrid(_ style: WarpStyle, _ b: Double, _ hd0: Double, _ vd0: Double, _ vertical: Bool, _ aspect: Double) -> Grid {
    // Height over width of the box the bend runs along (the transposed box when vertical); in that
    // frame the two distortions trade places too.
    let h = vertical ? 1 / aspect : aspect
    let (hd, vd) = vertical ? (vd0, hd0) : (hd0, vd0)
    var g = restGrid()
    switch style {
    case .arc: g = arcGrid(b, h)
    case .arch: g = (0..<4).map { edgeArc(Double($0) / 3, b, true, h) }
    case .bulge: g = blendRows(edgeArc(0, b, true, h), edgeArc(1, b, false, h))
    case .arcLower: g = blendRows(g[0], edgeArc(1, b, false, h))
    case .arcUpper: g = blendRows(edgeArc(0, b, true, h), g[3])
    // The bulging edge and the outer points of the row next to it come from Arc (bent the other
    // way for Shell Lower); the rest stays put.
    case .shellLower:
        let a = arcGrid(-b, h)
        g[3] = a[3]
        g[2][0] = a[2][0]
        g[2][3] = a[2][3]
    case .shellUpper:
        let a = arcGrid(b, h)
        g[0] = a[0]
        g[1][0] = a[1][0]
        g[1][3] = a[1][3]
    case .flag:
        for j in 0..<4 {
            g[j][1].y -= 2 * b
            g[j][2].y += 2 * b
        }
    case .wave:
        for j in 1..<3 {
            g[j][1].y += 4.0 / 3.0 * b
            g[j][2].y -= 4.0 / 3.0 * b
        }
    case .fish:
        for (j, f) in zip(0..<4, [-2.0, -2.0 / 3.0, 2.0 / 3.0, 2.0]) {
            g[j][1].y += f * b
            g[j][2].y -= f * b
        }
    case .rise:
        for j in 0..<4 {
            g[j][0].y += 2 * b
            g[j][1].y += 2 * b
        }
    case .fisheye:
        for (j, i, dx, dy) in [(1, 1, -1.0, -1.0), (1, 2, 1.0, -1.0), (2, 1, -1.0, 1.0), (2, 2, 1.0, 1.0)] {
            g[j][i].x += dx * 2.0 / 3.0 * b
            g[j][i].y += dy * 2.0 / 3.0 * b
        }
    // Edge midpoints move out (Inflate) or the sides in (Squeeze) by b/3, the inner points by b/9.
    case .inflate, .squeeze:
        let s: Double = style == .inflate ? 1 : -1
        for i in 1..<3 { g[0][i].y -= b / 3 }
        for i in 1..<3 { g[3][i].y += b / 3 }
        for j in 1..<3 {
            g[j][0].x -= s * b / 3
            g[j][3].x += s * b / 3
        }
        for (j, i, dx, dy) in [(1, 1, -1.0, -1.0), (1, 2, 1.0, -1.0), (2, 1, -1.0, 1.0), (2, 2, 1.0, 1.0)] {
            g[j][i].x += s * dx * b / 9
            g[j][i].y += dy * b / 9
        }
    // The inner points turn round the centre (the other way for a negative bend).
    case .twist:
        let a = abs(b)
        if b >= 0 {
            g[1][1].x += a
            g[1][2].y += a
            g[2][1].y -= a
            g[2][2].x -= a
        } else {
            g[1][1].y += a
            g[1][2].x -= a
            g[2][1].x += a
            g[2][2].y -= a
        }
    case .none, .custom: break
    }
    // Vertical distortion: the top and bottom rows scale about their end points' midpoint (by
    // 1 ∓ vd) and the middle rows follow by the blend of those two moves.
    if vd != 0 {
        func moved(_ row: GridRow, _ s: Double) -> GridRow {
            let m = SIMD2((row[0].x + row[3].x) / 2, (row[0].y + row[3].y) / 2)
            return (0..<4).map { i in SIMD2(m.x + (row[i].x - m.x) * s - row[i].x, m.y + (row[i].y - m.y) * s - row[i].y) }
        }
        let (d0, d3) = (moved(g[0], 1 - vd), moved(g[3], 1 + vd))
        for j in 0..<4 {
            let t = Double(j) / 3
            for i in 0..<4 {
                g[j][i].x += d0[i].x + (d3[i].x - d0[i].x) * t
                g[j][i].y += d0[i].y + (d3[i].y - d0[i].y) * t
            }
        }
    }
    // Horizontal distortion: each column scales about its end points' midpoint by 1 + hd·(2i/3 − 1).
    if hd != 0 {
        for i in 0..<4 {
            let s = 1 + hd * (2 * Double(i) / 3 - 1)
            let m = SIMD2((g[0][i].x + g[3][i].x) / 2, (g[0][i].y + g[3][i].y) / 2)
            for j in 0..<4 {
                g[j][i] = SIMD2(m.x + (g[j][i].x - m.x) * s, m.y + (g[j][i].y - m.y) * s)
            }
        }
    }
    // Vertical orientation: the same grid with the axes swapped.
    if vertical {
        let src = g
        g = (0..<4).map { j in (0..<4).map { i in SIMD2(src[i][j].y, src[i][j].x) } }
    }
    return g
}

@inline(__always) func bernstein(_ t: Double) -> [Double] {
    let s = 1 - t
    return [s * s * s, 3 * s * s * t, 3 * s * t * t, t * t * t]
}

@inline(__always) func lerp(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ t: Double) -> SIMD2<Double> {
    SIMD2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
}

/// De Casteljau split of a cubic at `t`: 7 points (left 0...3, right 3...6).
func splitCubic(_ p: [SIMD2<Double>], _ t: Double) -> [SIMD2<Double>] {
    let a = lerp(p[0], p[1], t)
    let b = lerp(p[1], p[2], t)
    let c = lerp(p[2], p[3], t)
    let d = lerp(a, b, t)
    let e = lerp(b, c, t)
    let f = lerp(d, e, t)
    return [p[0], a, d, f, e, c, p[3]]
}

/// Inverse of the Bernstein interpolation matrix at t = 0, 1/3, 2/3, 1 (rows: control point,
/// columns: sample). Exact rational values.
let bernsteinInverse: [[Double]] = [
    [1, 0, 0, 0], [-5.0 / 6.0, 3, -1.5, 1.0 / 3.0], [1.0 / 3.0, -1.5, 3, -5.0 / 6.0], [0, 0, 0, 1],
]

/// A grid of bicubic Bezier patches over the unit square of a source box.
///
/// `us`/`vs` are the patch boundaries in the box's normalised coordinates (`0...1`, increasing,
/// first 0 and last 1). Control points are a `(3·(us.count−1)+1) × (3·(vs.count−1)+1)` grid in
/// row-major order, in output (document) coordinates; neighbouring patches share their edge row.
public struct BezierMesh: Hashable, Sendable, Codable {
    public var us: [Double]
    public var vs: [Double]
    public var points: [SIMD2<Double>]

    public init(us: [Double], vs: [Double], points: [SIMD2<Double>]) {
        self.us = us; self.vs = vs; self.points = points
    }

    /// The identity mesh over `bounds` with `cols × rows` patches (Photoshop's default is 1 × 1, a
    /// 4 × 4 control grid).
    public static func identity(bounds: SIMD4<Double>, cols: Int, rows: Int) -> BezierMesh {
        let (cols, rows) = (min(max(cols, 1), 64), min(max(rows, 1), 64))
        let us = (0...cols).map { Double($0) / Double(cols) }
        let vs = (0...rows).map { Double($0) / Double(rows) }
        return fit({ s, t in SIMD2(bounds.x + s * (bounds.z - bounds.x), bounds.y + t * (bounds.w - bounds.y)) }, us: us, vs: vs)
    }

    /// Fits a mesh with patch boundaries `us`/`vs` to the map `f` (normalised → output) by
    /// interpolating it at the patch's thirds. Exact for bicubic maps (affine maps included).
    public static func fit(_ f: (Double, Double) -> SIMD2<Double>, us: [Double], vs: [Double]) -> BezierMesh {
        guard us.count >= 2, vs.count >= 2 else { return BezierMesh(us: us, vs: vs, points: []) }
        let (pc, pr) = (us.count - 1, vs.count - 1)
        let (nx, ny) = (3 * pc + 1, 3 * pr + 1)
        var points = [SIMD2<Double>](repeating: .zero, count: nx * ny)
        for pj in 0..<pr {
            for pi in 0..<pc {
                var s = [[SIMD2<Double>]](repeating: [SIMD2<Double>](repeating: .zero, count: 4), count: 4) // s[row j][col i]
                for j in 0..<4 {
                    for i in 0..<4 {
                        let u = us[pi] + (us[pi + 1] - us[pi]) * Double(i) / 3
                        let t = vs[pj] + (vs[pj + 1] - vs[pj]) * Double(j) / 3
                        s[j][i] = f(u, t)
                    }
                }
                for j in 0..<4 {
                    for i in 0..<4 {
                        var acc = SIMD2<Double>.zero
                        for (a, wa) in bernsteinInverse[j].enumerated() {
                            for (b, wb) in bernsteinInverse[i].enumerated() {
                                let k = wa * wb
                                acc.x += k * s[a][b].x
                                acc.y += k * s[a][b].y
                            }
                        }
                        points[(3 * pj + j) * nx + 3 * pi + i] = acc
                    }
                }
            }
        }
        return BezierMesh(us: us, vs: vs, points: points)
    }

    /// Control points per row.
    public var nx: Int { us.count >= 2 ? 3 * (us.count - 1) + 1 : 0 }
    /// Control point rows.
    public var ny: Int { vs.count >= 2 ? 3 * (vs.count - 1) + 1 : 0 }

    public func point(_ i: Int, _ j: Int) -> SIMD2<Double> { points[j * nx + i] }

    /// Cheap structural check (knot counts and point count); `isValid` also checks values.
    public var isWellFormed: Bool { us.count >= 2 && vs.count >= 2 && points.count == nx * ny }

    /// Checks the invariants (knots and point count); malformed data from files is rejected.
    public var isValid: Bool {
        func knotsOK(_ k: [Double]) -> Bool {
            k.count >= 2 && k[0] == 0 && k[k.count - 1] == 1 && zip(k, k.dropFirst()).allSatisfy { $1 > $0 }
        }
        return knotsOK(us) && knotsOK(vs) && points.count == nx * ny && points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }

    static func locate(_ knots: [Double], _ s0: Double) -> (Int, Double) {
        let n = knots.count - 1
        guard n >= 1 else { return (0, 0) }
        let s = clamp01(s0)
        var i = 0
        while i + 1 < n && s > knots[i + 1] { i += 1 }
        let w = knots[i + 1] - knots[i]
        return (i, w > 0 ? (s - knots[i]) / w : 0)
    }

    /// Evaluates the surface at normalised `(s, t)` (zero for a malformed mesh).
    public func eval(_ s: Double, _ t: Double) -> SIMD2<Double> {
        guard isWellFormed else { return .zero }
        let (pi, a) = BezierMesh.locate(us, s)
        let (pj, b) = BezierMesh.locate(vs, t)
        let (ba, bb) = (bernstein(a), bernstein(b))
        let nx = self.nx
        var out = SIMD2<Double>.zero
        for (j, wb) in bb.enumerated() {
            for (i, wa) in ba.enumerated() {
                let p = points[(3 * pj + j) * nx + 3 * pi + i]
                let k = wa * wb
                out.x += p.x * k
                out.y += p.y * k
            }
        }
        return out
    }

    /// Splits the patch column containing `s` at `s` (a vertical split line). Exact: the surface
    /// is unchanged. Returns false when `s` is on or too close to an existing boundary.
    @discardableResult
    public mutating func splitU(_ s: Double) -> Bool {
        guard isWellFormed else { return false }
        let (pi, a) = BezierMesh.locate(us, s)
        guard (0.01...0.99).contains(a) else { return false }
        let (nx, ny) = (self.nx, self.ny)
        var pts: [SIMD2<Double>] = []
        pts.reserveCapacity((nx + 3) * ny)
        for j in 0..<ny {
            let row = Array(points[(j * nx)..<((j + 1) * nx)])
            pts += row[..<(3 * pi)]
            pts += splitCubic([row[3 * pi], row[3 * pi + 1], row[3 * pi + 2], row[3 * pi + 3]], a)
            pts += row[(3 * pi + 4)...]
        }
        points = pts
        us.insert(clamp01(s), at: pi + 1)
        return true
    }

    /// Splits the patch row containing `t` at `t` (a horizontal split line). Exact.
    @discardableResult
    public mutating func splitV(_ t: Double) -> Bool {
        transpose()
        let ok = splitU(t)
        transpose()
        return ok
    }

    /// Removes interior vertical boundary `k` (1..<us.count−1), merging its two patch columns.
    /// Exact when the patches came from an unedited split; otherwise the outer control points are
    /// kept and the inner handles extrapolated.
    @discardableResult
    public mutating func removeSplitU(_ k: Int) -> Bool {
        guard k > 0, k + 1 < us.count, isWellFormed else { return false }
        let a = (us[k] - us[k - 1]) / (us[k + 1] - us[k - 1])
        let (nx, ny) = (self.nx, self.ny)
        var pts: [SIMD2<Double>] = []
        pts.reserveCapacity((nx - 3) * ny)
        let c0 = 3 * (k - 1)
        for j in 0..<ny {
            let row = Array(points[(j * nx)..<((j + 1) * nx)])
            let (p0, q1, r2, p3) = (row[c0], row[c0 + 1], row[c0 + 5], row[c0 + 6])
            // De Casteljau inverse: q1 = lerp(p0, p1, a), r2 = lerp(p2, p3, a).
            let p1 = SIMD2((q1.x - (1 - a) * p0.x) / a, (q1.y - (1 - a) * p0.y) / a)
            let p2 = SIMD2((r2.x - a * p3.x) / (1 - a), (r2.y - a * p3.y) / (1 - a))
            pts += row[..<c0]
            pts += [p0, p1, p2, p3]
            pts += row[(c0 + 7)...]
        }
        points = pts
        us.remove(at: k)
        return true
    }

    /// Removes interior horizontal boundary `k`.
    @discardableResult
    public mutating func removeSplitV(_ k: Int) -> Bool {
        transpose()
        let ok = removeSplitU(k)
        transpose()
        return ok
    }

    mutating func transpose() {
        guard isWellFormed else { swap(&us, &vs); return }
        let (nx, ny) = (self.nx, self.ny)
        var pts = [SIMD2<Double>](repeating: .zero, count: nx * ny)
        for j in 0..<ny {
            for i in 0..<nx { pts[i * ny + j] = points[j * nx + i] }
        }
        points = pts
        swap(&us, &vs)
    }

    /// Applies `f` to every control point (exact for affine maps).
    public func mapPoints(_ f: (SIMD2<Double>) -> SIMD2<Double>) -> BezierMesh {
        BezierMesh(us: us, vs: vs, points: points.map(f))
    }

    /// Normalised `(s, t)` whose surface point is nearest `p` (coarse search, then Newton steps on
    /// the patch). Used to place split lines where the user clicks.
    public func paramAt(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let n = 48
        var best = (0.5, 0.5, Double.greatestFiniteMagnitude)
        for j in 0...n {
            for i in 0...n {
                let (s, t) = (Double(i) / Double(n), Double(j) / Double(n))
                let q = eval(s, t)
                let (dx, dy) = (q.x - p.x, q.y - p.y)
                let d = dx * dx + dy * dy
                if d < best.2 { best = (s, t, d) }
            }
        }
        var (s, t) = (best.0, best.1)
        for _ in 0..<12 {
            let h = 1e-5
            let q = eval(s, t)
            let (qs, qt) = (eval(s + h, t), eval(s, t + h))
            let (a, b, c, d) = ((qs.x - q.x) / h, (qt.x - q.x) / h, (qs.y - q.y) / h, (qt.y - q.y) / h)
            let det = a * d - b * c
            if abs(det) < 1e-12 { break }
            let (ex, ey) = (p.x - q.x, p.y - q.y)
            s = clamp01(s + (d * ex - b * ey) / det)
            t = clamp01(t + (a * ey - c * ex) / det)
        }
        return SIMD2(s, t)
    }

    /// Pulls the surface point at normalised `(s, t)` by `d`, as dragging the grid anywhere inside
    /// a patch does in other editors. `base` is the control grid at the start of the drag.
    ///
    /// Two parts. The surrounding grid follows loosely: every interior anchor within about two
    /// cells moves by a share of `d` that fades with distance. The picture's outer border stays
    /// pinned (the picture keeps filling its frame) unless the grab is within a few percent of it,
    /// and then it follows more and more. Each anchor takes its whole 3 × 3 block of control points
    /// along, so every grid line stays smooth through its anchors and the neighbouring cells and
    /// dividers bend with the pull. Then the four inner control points of the grabbed patch make up
    /// the rest, so the grabbed point lands exactly at its start + `d`. Grabbing near an anchor
    /// moves that anchor more, and the inner points less.
    public mutating func pull(base: [SIMD2<Double>], s: Double, t: Double, d: SIMD2<Double>) {
        /// Within this distance of the mesh border (in 0..1 box units) a grab starts to drag the
        /// border with it; further in, the border stays exactly where it is.
        let borderZone = 0.12
        /// Falloff radius, in the grabbed patch's size.
        let reachFactor = 1.8
        guard base.count == points.count, d.x.isFinite, d.y.isFinite, isWellFormed else { return }
        points = base
        let (cols, rows) = (us.count - 1, vs.count - 1)
        let (pi, a) = BezierMesh.locate(us, s)
        let (pj, b) = BezierMesh.locate(vs, t)
        let (ba, bb) = (bernstein(a), bernstein(b))
        let (nx, ny) = (self.nx, self.ny)
        func anchor(_ ai: Int, _ aj: Int) -> SIMD2<Double> {
            let k = 3 * aj * nx + 3 * ai
            return k < base.count ? base[k] : .zero
        }
        let at0 = eval(s, t)
        let target = SIMD2(at0.x + d.x, at0.y + d.y)
        // The grabbed patch's size and its "interior-ness": 1 in the middle, 0 on its edges.
        var size = 1.0
        for k in 0..<2 {
            let vals = [anchor(pi, pj)[k], anchor(pi + 1, pj)[k], anchor(pi, pj + 1)[k], anchor(pi + 1, pj + 1)[k]]
            let (lo, hi) = vals.reduce((Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)) { (fmin($0.0, $1), fmax($0.1, $1)) }
            size = fmax(size, hi - lo)
        }
        let radius = reachFactor * size
        let innerW = (ba[1] + ba[2]) * (bb[1] + bb[2])
        let interior = clamp01(innerW / 0.5625)
        let toBorder = fmin(fmin(s, 1 - s), fmin(t, 1 - t))
        let nearBorder = clamp01(1 - toBorder / borderZone)
        // How much of the pull each corner of the grabbed patch is responsible for. A corner on the
        // picture's border only takes part once the grab is near that border. The picture's four
        // corners never move in a pull (a grab near the border bends the border through its
        // handles instead).
        func meshCorner(_ ai: Int, _ aj: Int) -> Bool { (ai == 0 || ai == cols) && (aj == 0 || aj == rows) }
        func reach(_ ai: Int, _ aj: Int, _ wa: Double, _ wb: Double) -> Double {
            let border = ai == 0 || ai == cols || aj == 0 || aj == rows
            return meshCorner(ai, aj) ? 0 : wa * wb * (border ? nearBorder : 1)
        }
        let corner: [(Int, Int, Double)] = [
            (pi, pj, reach(pi, pj, ba[0] + ba[1], bb[0] + bb[1])),
            (pi + 1, pj, reach(pi + 1, pj, ba[2] + ba[3], bb[0] + bb[1])),
            (pi, pj + 1, reach(pi, pj + 1, ba[0] + ba[1], bb[2] + bb[3])),
            (pi + 1, pj + 1, reach(pi + 1, pj + 1, ba[2] + ba[3], bb[2] + bb[3])),
        ]
        // Share of `d` for each anchor.
        var share = [Double](repeating: 0, count: (cols + 1) * (rows + 1))
        for aj in 0...rows {
            for ai in 0...cols {
                let p = anchor(ai, aj)
                let x = clamp01(hypot(p.x - at0.x, p.y - at0.y) / radius)
                let fall = 0.5 * (1 + cos(Double.pi * x))
                let border = ai == 0 || ai == cols || aj == 0 || aj == rows
                let edge: Double = meshCorner(ai, aj) ? 0 : (border ? nearBorder : 1)
                share[aj * (cols + 1) + ai] = fall * edge
            }
        }
        // The grabbed patch's own corners: near one, that corner follows the pointer.
        for (ai, aj, w) in corner {
            let idx = aj * (cols + 1) + ai
            share[idx] = fmax(share[idx], (1 - interior) * w)
        }
        var pts = points
        // Every control point moves with the anchor it is closest to.
        for j in 0..<ny {
            for i in 0..<nx {
                let (ai, aj) = (min((i + 1) / 3, cols), min((j + 1) / 3, rows))
                let k = share[aj * (cols + 1) + ai]
                pts[j * nx + i].x += d.x * k
                pts[j * nx + i].y += d.y * k
            }
        }
        points = pts
        // Close the gap exactly, with three groups of control points that share the work:
        // - the four inner points of the grabbed patch (all of it in the middle of the patch,
        //   little near a grid line, where they barely reach the surface);
        // - the corner blocks (an anchor with its handles, moving as a whole so lines stay smooth);
        // - when the grab is near the picture's border, that border's own handles: the border
        //   bends into a curve and its corners stay put.
        // Closing nudges the tangents across the grid lines, so they are evened out again and the
        // gap re-closed.
        var norm = 0.0
        for j in [1, 2] { for i in [1, 2] { let w = ba[i] * bb[j]; norm += w * w } }
        let cornerNorm = corner.reduce(0.0) { $0 + $1.2 * $1.2 }
        // With no free corner to help (a one-patch grid, grabbed away from its border) the four
        // inner points do all of it.
        let innerPart = cornerNorm > 1e-12 ? min(innerW / 0.15, 1) : 1
        // Handles along the sides of the grabbed patch that lie on the picture's border.
        var edge: [(Int, Double)] = []
        for k in [1, 2] {
            if pi == 0 { edge.append(((3 * pj + k) * nx + 3 * pi, ba[0] * bb[k])) }
            if pi + 1 == cols { edge.append(((3 * pj + k) * nx + 3 * pi + 3, ba[3] * bb[k])) }
            if pj == 0 { edge.append((3 * pj * nx + 3 * pi + k, ba[k] * bb[0])) }
            if pj + 1 == rows { edge.append(((3 * pj + 3) * nx + 3 * pi + k, ba[k] * bb[3])) }
        }
        let edgeNorm = edge.reduce(0.0) { $0 + $1.1 * $1.1 }
        let edgePart = edgeNorm > 1e-12 ? nearBorder : 0
        let (innerShare, cornerShare) = ((1 - edgePart) * innerPart, (1 - edgePart) * (1 - innerPart))
        for _ in 0..<60 {
            let now = eval(s, t)
            let rem = SIMD2(target.x - now.x, target.y - now.y)
            if hypot(rem.x, rem.y) < 1e-9 { break }
            if innerShare > 0 && norm > 0 {
                for j in [1, 2] {
                    for i in [1, 2] {
                        let k = ba[i] * bb[j] / norm * innerShare
                        let idx = (3 * pj + j) * nx + 3 * pi + i
                        points[idx].x += rem.x * k
                        points[idx].y += rem.y * k
                    }
                }
            }
            if edgePart > 0 {
                for (idx, w) in edge where idx < points.count {
                    let k = w / edgeNorm * edgePart
                    points[idx].x += rem.x * k
                    points[idx].y += rem.y * k
                }
            }
            if cornerShare > 0 && cornerNorm > 0 {
                for (ai, aj, w) in corner {
                    let k = w / cornerNorm * cornerShare
                    for dj in -1...1 {
                        for di in -1...1 {
                            let (i, j) = (3 * ai + di, 3 * aj + dj)
                            if i >= 0 && j >= 0 && i < nx && j < ny {
                                points[j * nx + i].x += rem.x * k
                                points[j * nx + i].y += rem.y * k
                            }
                        }
                    }
                }
            }
            for _ in 0..<3 {
                smoothLines(max(3 * pi - 3, 0), 3 * pi + 7, max(3 * pj - 3, 0), 3 * pj + 7)
            }
        }
    }

    /// Makes the tangent equal on both sides of every interior grid line, for the control points in
    /// columns `i0..<i1` and rows `j0..<j1` (clamped to the grid): each pair of handles takes the
    /// average of the two tangents it had.
    mutating func smoothLines(_ i0: Int, _ i1In: Int, _ j0: Int, _ j1In: Int) {
        let nx = self.nx
        let (i1, j1) = (min(i1In, nx), min(j1In, ny))
        guard i0 < i1, j0 < j1 else { return }
        // (left, centre, right, span left, span right)
        var triples: [(Int, Int, Int, Double, Double)] = []
        if us.count > 2 {
            for a in 1..<(us.count - 1) where 3 * a >= i0 && 3 * a < i1 {
                for j in j0..<j1 {
                    triples.append((j * nx + 3 * a - 1, j * nx + 3 * a, j * nx + 3 * a + 1, us[a] - us[a - 1], us[a + 1] - us[a]))
                }
            }
        }
        if vs.count > 2 {
            for b in 1..<(vs.count - 1) where 3 * b >= j0 && 3 * b < j1 {
                for i in i0..<i1 {
                    triples.append(((3 * b - 1) * nx + i, 3 * b * nx + i, (3 * b + 1) * nx + i, vs[b] - vs[b - 1], vs[b + 1] - vs[b]))
                }
            }
        }
        for (l, c, r, hl, hr) in triples {
            let (pl, pc, pr) = (points[l], points[c], points[r])
            let tan = SIMD2(((pc.x - pl.x) / hl + (pr.x - pc.x) / hr) / 2, ((pc.y - pl.y) / hl + (pr.y - pc.y) / hr) / 2)
            points[l] = SIMD2(pc.x - tan.x * hl, pc.y - tan.y * hl)
            points[r] = SIMD2(pc.x + tan.x * hr, pc.y + tan.y * hr)
        }
    }

    /// Drags control point `index` by `d` from the grid `base` it had when the drag began, keeping
    /// the surface smooth across the grid lines:
    /// - an anchor moves with the eight points around it, as one block;
    /// - a handle moves with the two points beside it across its line, and the handle opposite it
    ///   on the same anchor turns the other way (with its two neighbours), so the line keeps
    ///   passing straight through the anchor instead of creasing there.
    public mutating func dragPoint(base: [SIMD2<Double>], index: Int, d: SIMD2<Double>) {
        guard base.count == points.count, index >= 0, index < base.count, d.x.isFinite, d.y.isFinite, isWellFormed else { return }
        var pts = base
        let (nx, ny) = (self.nx, self.ny)
        let (i, j) = (index % nx, index / nx)
        func shift(_ i: Int, _ j: Int, _ d: SIMD2<Double>) {
            if i >= 0 && j >= 0 && i < nx && j < ny {
                pts[j * nx + i].x += d.x
                pts[j * nx + i].y += d.y
            }
        }
        // Spans either side of interior knot `k`.
        func span(_ knots: [Double], _ k: Int) -> (Double, Double)? {
            (k > 0 && k + 1 < knots.count) ? (knots[k] - knots[k - 1], knots[k + 1] - knots[k]) : nil
        }
        switch (i % 3, j % 3) {
        case (0, 0):
            for dj in -1...1 { for di in -1...1 { shift(i + di, j + dj, d) } }
        // A handle along a vertical line: it takes the two points beside it across the line.
        case (0, let r):
            for di in -1...1 { shift(i + di, j, d) }
            // The opposite handle of the same anchor turns the other way.
            if let (hl, hr) = span(vs, j / 3 + (r == 2 ? 1 : 0)) {
                let (other, k) = r == 1 ? (j - 2, hl / hr) : (j + 2, hr / hl)
                for di in -1...1 { shift(i + di, other, SIMD2(-d.x * k, -d.y * k)) }
            }
        // A handle along a horizontal line, likewise.
        case (let r, 0):
            for dj in -1...1 { shift(i, j + dj, d) }
            if let (hl, hr) = span(us, i / 3 + (r == 2 ? 1 : 0)) {
                let (other, k) = r == 1 ? (i - 2, hl / hr) : (i + 2, hr / hl)
                for dj in -1...1 { shift(other, j + dj, SIMD2(-d.x * k, -d.y * k)) }
            }
        // An inner point of a patch has no handle of its own.
        default:
            shift(i, j, d)
        }
        points = pts
    }

    /// Bounding box `[x0, y0, x1, y1]` of the control points (the surface lies inside it).
    public var controlBounds: SIMD4<Double> {
        points.reduce(SIMD4(Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)) { b, p in
            SIMD4(fmin(b.x, p.x), fmin(b.y, p.y), fmax(b.z, p.x), fmax(b.w, p.y))
        }
    }
}

/// A complete warp: what Photoshop's `warp` descriptor stores, plus the custom mesh.
/// JSON keys are camelCase, as photocraft writes them.
public struct Warp: Hashable, Sendable, Codable {
    public var style: WarpStyle
    /// Bend in percent (-100..100), presets only.
    public var bend: Double
    public var hDistort: Double
    public var vDistort: Double
    /// Warp along the vertical axis.
    public var vertical: Bool
    /// The source box `[x0, y0, x1, y1]` the warp is defined over.
    public var bounds: SIMD4<Double>
    /// Control mesh for `WarpStyle.custom` (output coordinates).
    public var mesh: BezierMesh?

    public init(style: WarpStyle, bend: Double = 0, hDistort: Double = 0, vDistort: Double = 0, vertical: Bool = false,
                bounds: SIMD4<Double>, mesh: BezierMesh? = nil) {
        self.style = style; self.bend = bend; self.hDistort = hDistort; self.vDistort = vDistort
        self.vertical = vertical; self.bounds = bounds; self.mesh = mesh
    }

    enum CodingKeys: String, CodingKey { case style, bend, hDistort, vDistort, vertical, bounds, mesh }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decode(WarpStyle.self, forKey: .style)
        bend = try c.decode(.bend, or: 0)
        hDistort = try c.decode(.hDistort, or: 0)
        vDistort = try c.decode(.vDistort, or: 0)
        vertical = try c.decode(.vertical, or: false)
        bounds = try c.decode(SIMD4<Double>.self, forKey: .bounds)
        mesh = try c.decodeIfPresent(BezierMesh.self, forKey: .mesh)
    }

    /// No warp over `bounds`.
    public static func none(_ bounds: SIMD4<Double>) -> Warp { Warp(style: .none, bounds: bounds) }

    /// A preset style.
    public static func preset(_ style: WarpStyle, bend: Double, bounds: SIMD4<Double>) -> Warp {
        Warp(style: style, bend: bend, bounds: bounds)
    }

    /// A custom warp from a mesh.
    public static func custom(_ mesh: BezierMesh, bounds: SIMD4<Double>) -> Warp {
        Warp(style: .custom, bounds: bounds, mesh: mesh)
    }

    /// The preset prepared for this box (nil for none/custom or an all-zero warp). Resamplers
    /// should take it once rather than calling `map` per pixel.
    public var styleWarp: StyleWarp? {
        StyleWarp(style: style, bend: bend, hDistort: hDistort, vDistort: vDistort, vertical: vertical, bounds: bounds)
    }

    /// Whether the warp maps every point of its box onto itself (within 1e-9 px).
    public var isIdentity: Bool {
        switch style {
        case .none: return true
        case .custom:
            guard let m = mesh else { return true }
            let id = BezierMesh.fit({ s, t in boxPoint(s, t) }, us: m.us, vs: m.vs)
            return zip(m.points, id.points).allSatisfy { abs($0.x - $1.x) < 1e-9 && abs($0.y - $1.y) < 1e-9 }
        default:
            return styleWarp == nil
        }
    }

    func boxPoint(_ s: Double, _ t: Double) -> SIMD2<Double> {
        SIMD2(bounds.x + s * (bounds.z - bounds.x), bounds.y + t * (bounds.w - bounds.y))
    }

    /// Maps a source point (inside the box) to output space.
    public func map(_ x: Double, _ y: Double) -> SIMD2<Double> {
        switch style {
        case .none: return SIMD2(x, y)
        case .custom:
            guard let m = mesh else { return SIMD2(x, y) }
            let (w, h) = (bounds.z - bounds.x, bounds.w - bounds.y)
            if w <= 0 || h <= 0 { return SIMD2(x, y) }
            return m.eval((x - bounds.x) / w, (y - bounds.y) / h)
        default:
            return styleWarp?.apply(x, y) ?? SIMD2(x, y)
        }
    }

    /// The warp as a control mesh (a preset is its own Bezier patch split into `cols × rows`;
    /// custom warps return their own mesh).
    public func toMesh(cols: Int, rows: Int) -> BezierMesh {
        if style == .custom, let m = mesh { return m }
        let (cols, rows) = (min(max(cols, 1), 64), min(max(rows, 1), 64))
        // A preset is one Bezier patch: split it exactly.
        if let sw = styleWarp {
            var m = sw.mesh
            for i in stride(from: 1, to: cols, by: 1) { m.splitU(Double(i) / Double(cols)) }
            for j in stride(from: 1, to: rows, by: 1) { m.splitV(Double(j) / Double(rows)) }
            return m
        }
        let us = (0...cols).map { Double($0) / Double(cols) }
        let vs = (0...rows).map { Double($0) / Double(rows) }
        return BezierMesh.fit({ s, t in
            let p = boxPoint(s, t)
            return map(p.x, p.y)
        }, us: us, vs: vs)
    }

    /// The same warp followed by the affine map `m` (`x' = a·x + c·y + e`, `y' = b·x + d·y + f`),
    /// as a custom mesh (exact for custom warps).
    public func thenAffine(_ m: PCAffine) -> Warp {
        let mesh = toMesh(cols: 4, rows: 4).mapPoints { m.apply($0) }
        return Warp.custom(mesh, bounds: bounds)
    }

    /// Approximate output bounds `[x0, y0, x1, y1]` (sampled; includes the control mesh for custom
    /// warps).
    public var outputBounds: SIMD4<Double> {
        let n = 32
        var b = SIMD4(Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
        let sw = style.isPreset ? styleWarp : nil
        for j in 0...n {
            for i in 0...n {
                let p = boxPoint(Double(i) / Double(n), Double(j) / Double(n))
                let q = style.isPreset ? (sw?.apply(p.x, p.y) ?? p) : map(p.x, p.y)
                b = SIMD4(fmin(b.x, q.x), fmin(b.y, q.y), fmax(b.z, q.x), fmax(b.w, q.y))
            }
        }
        return b
    }
}
