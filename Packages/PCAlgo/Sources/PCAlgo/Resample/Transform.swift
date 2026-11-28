// Port of photocraft-algo (crates/algo/src/transform.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Free Transform: projective warps. A transform is where the four corners of a source rectangle
// land (a quad); scale, rotate, skew and flips are affine special cases, Distort and Perspective
// the full homography. Warping is an inverse mapping with premultiplied sampling (nearest,
// bilinear or Catmull-Rom bicubic) per 256-px destination tile; reductions below ½ are first
// pre-filtered with a Bicubic Image Size so shrinking doesn't alias. The CPU maps in f64 as
// photocraft does; the Metal kernel maps each pixel in emulated IEEE binary64 (integer maths), so
// even exact ties floor to the same pixel.

import Foundation
import Metal
import PCFoundation

/// 3×3 projective matrix, row-major: `[x', y', w'] = H · [x, y, 1]` (photocraft `Homography`).
public struct Homography: Hashable, Sendable, Codable {
    /// The nine entries, row-major.
    public var m: [Double]

    public init(_ m: [Double]) {
        precondition(m.count == 9, "Homography needs 9 entries")
        self.m = m
    }

    public static let identity = Homography([1, 0, 0, 0, 1, 0, 0, 0, 1])

    public var isIdentity: Bool {
        if abs(m[8]) < 1e-12 { return false }
        let w = m[8]
        return abs(m[0] / w - 1) < 1e-9 && abs(m[4] / w - 1) < 1e-9 && abs(m[1] / w) < 1e-9 && abs(m[2] / w) < 1e-9
            && abs(m[3] / w) < 1e-9 && abs(m[5] / w) < 1e-9 && abs(m[6] / w) < 1e-9 && abs(m[7] / w) < 1e-9
    }

    @inline(__always)
    public func apply(_ x: Double, _ y: Double) -> (Double, Double) {
        let w = m[6] * x + m[7] * y + m[8]
        return ((m[0] * x + m[1] * y + m[2]) / w, (m[3] * x + m[4] * y + m[5]) / w)
    }

    /// `self · o`.
    public func mul(_ o: Homography) -> Homography {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                var s = 0.0
                for k in 0..<3 { s += m[i * 3 + k] * o.m[k * 3 + j] }
                r[i * 3 + j] = s
            }
        }
        return Homography(r)
    }

    public func inverse() -> Homography? {
        let c = [
            m[4] * m[8] - m[5] * m[7],
            m[2] * m[7] - m[1] * m[8],
            m[1] * m[5] - m[2] * m[4],
            m[5] * m[6] - m[3] * m[8],
            m[0] * m[8] - m[2] * m[6],
            m[2] * m[3] - m[0] * m[5],
            m[3] * m[7] - m[4] * m[6],
            m[1] * m[6] - m[0] * m[7],
            m[0] * m[4] - m[1] * m[3],
        ]
        let det = m[0] * c[0] + m[1] * c[3] + m[2] * c[6]
        if abs(det) < 1e-12 { return nil }
        return Homography(c.map { $0 / det })
    }

    /// Unit square → quad (corners in order: (0,0), (1,0), (1,1), (0,1)).
    static func squareToQuad(_ q: [SIMD2<Double>]) -> Homography? {
        let (x0, y0, x1, y1, x2, y2, x3, y3) = (q[0].x, q[0].y, q[1].x, q[1].y, q[2].x, q[2].y, q[3].x, q[3].y)
        let sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3
        if abs(sx) < 1e-12 && abs(sy) < 1e-12 {
            // Affine.
            return Homography([x1 - x0, x3 - x0, x0, y1 - y0, y3 - y0, y0, 0, 0, 1])
        }
        let dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2
        let den = dx1 * dy2 - dx2 * dy1
        if abs(den) < 1e-12 { return nil }
        let g = (sx * dy2 - dx2 * sy) / den
        let h = (dx1 * sy - sx * dy1) / den
        return Homography([x1 - x0 + g * x1, x3 - x0 + h * x3, x0, y1 - y0 + g * y1, y3 - y0 + h * y3, y0, g, h, 1])
    }

    /// The transform taking rectangle `r` (x0, y0, x1, y1) onto `quad` (corners clockwise from
    /// top-left). nil for degenerate quads (photocraft `rect_to_quad`).
    public static func rectToQuad(_ r: [Double], _ quad: [SIMD2<Double>]) -> Homography? {
        precondition(r.count == 4 && quad.count == 4)
        let w = r[2] - r[0], h = r[3] - r[1]
        if w <= 0 || h <= 0 { return nil }
        let toUnit = Homography([1 / w, 0, -r[0] / w, 0, 1 / h, -r[1] / h, 0, 0, 1])
        return squareToQuad(quad)?.mul(toUnit)
    }

    /// Approximate linear scale of the mapping near `(x, y)` (sqrt of the Jacobian determinant).
    public func localScale(_ x: Double, _ y: Double) -> Double {
        let e = 0.5
        let a = apply(x - e, y), b = apply(x + e, y)
        let c = apply(x, y - e), d = apply(x, y + e)
        let jx = (b.0 - a.0, b.1 - a.1), jy = (d.0 - c.0, d.1 - c.1)
        return abs(jx.0 * jy.1 - jx.1 * jy.0).squareRoot()
    }
}

/// Resampling used by transforms (Photoshop's interpolation menu) — photocraft `Interp`.
public enum Interp: String, Codable, Sendable, Hashable, CaseIterable {
    case nearest
    case bilinear
    /// Catmull-Rom. photocraft's default.
    case bicubic

    public static let `default` = Interp.bicubic

    /// photocraft `Interp::parse`: "nearest"/"nearestNeighbor", "bilinear", anything else bicubic.
    public init(parsing s: String) {
        switch s {
        case "nearest", "nearestNeighbor": self = .nearest
        case "bilinear": self = .bilinear
        default: self = .bicubic
        }
    }

    var code: Int32 {
        switch self { case .nearest: 0; case .bilinear: 1; case .bicubic: 2 }
    }
}

/// Free Transform / Perspective Crop warps (photocraft `transform.rs` functions).
public enum Transform {
    /// Warps `src` (its content inside `srcRect`) by `h` (source → destination document space).
    /// The result has `src`'s format with alpha added if it had none; pixels outside the warped
    /// quad are transparent (photocraft `warp_surface`). `.auto`/`.gpu` run the Metal kernel when
    /// the destination fits one GPU pass; the surface-level call never fails (CPU fallback).
    public static func warpSurface(_ src: Surface, srcRect: PixelRect, h: Homography, interp: Interp = .bicubic,
                                   on backend: Backend = .auto) -> Surface {
        TransformKit.warpSurface(src, srcRect: srcRect, h: h, interp: interp, clip: nil, backend: backend)
    }

    /// `warpSurface` keeping only the destination pixels inside `clip`: the work is bounded by
    /// `clip` even when part of the source lies at or beyond the map's horizon (photocraft
    /// `warp_surface_clipped`).
    public static func warpSurfaceClipped(_ src: Surface, srcRect: PixelRect, h: Homography, interp: Interp = .bicubic, clip: PixelRect,
                                          on backend: Backend = .auto) -> Surface {
        TransformKit.warpSurface(src, srcRect: srcRect, h: h, interp: interp, clip: clip, backend: backend)
    }

    /// Warps a dense image (0 outside it) by `h`, sampling only inside `srcRect` (default: the
    /// image). The result covers the warped quad's bounds (plus a pixel), clipped to `clip`, with
    /// alpha appended when `context` has none; empty when nothing lands. Same pixels as
    /// `warpSurface` over that rectangle.
    public static func warp(_ src: FloatImage, srcRect: PixelRect? = nil, h: Homography, interp: Interp = .bicubic, clip: PixelRect? = nil,
                            context: FilterContext? = nil, on backend: Backend = .auto) throws -> FloatImage {
        let ctx = context ?? FilterContext.inferred(channels: src.channels, bounds: src.rect)
        let (img, actx) = TransformKit.withAlpha(src, ctx)
        return try TransformKit.warpImage(img, srcRect: srcRect ?? src.rect, h: h, interp: interp, clip: clip, ctx: actx, backend: backend)
            ?? FloatImage(rect: .empty, channels: img.channels)
    }

    /// Whether `q` (TL, TR, BR, BL) is a usable Perspective Crop quad: finite, strictly convex with
    /// every corner angle above ~0.06°, wound clockwise on screen (y down) and at least 1 px² in area
    /// (photocraft `convex_quad`).
    public static func convexQuad(_ q: [SIMD2<Double>]) -> Bool {
        if q.count != 4 || q.contains(where: { !$0.x.isFinite || !$0.y.isFinite }) { return false }
        var area2 = 0.0
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4]
            let e1 = b - a, e2 = c - b
            let cross = e1.x * e2.y - e1.y * e2.x
            // sin(turn) = cross / (|e1| |e2|): positive (clockwise on screen) and not a straight angle.
            if cross.isNaN || cross <= 1e-3 * hypot(e1.x, e1.y) * hypot(e2.x, e2.y) { return false }
            area2 += a.x * b.y - b.x * a.y
        }
        return area2.isFinite && area2 >= 2
    }

    /// The output size a Perspective Crop of `q` (TL, TR, BR, BL) takes when none is given: the mean
    /// length of the top and bottom edges by the mean length of the left and right edges.
    public static func quadSize(_ q: [SIMD2<Double>]) -> (width: Double, height: Double) {
        func len(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { hypot(b.x - a.x, b.y - a.y) }
        let (tl, tr, br, bl) = (q[0], q[1], q[2], q[3])
        return ((len(tl, tr) + len(bl, br)) / 2, (len(tl, bl) + len(tr, br)) / 2)
    }

    /// The homography taking the quad `q` (TL, TR, BR, BL) onto the rectangle (0, 0)–(`w`, `h`),
    /// corner to corner (Heckbert 1989, §2.2.3); nil when `q` isn't a `convexQuad` or the size
    /// isn't positive (photocraft `quad_to_rect`).
    public static func quadToRect(_ q: [SIMD2<Double>], width w: Double, height h: Double) -> Homography? {
        guard convexQuad(q), w.isFinite, h.isFinite, w > 0, h > 0 else { return nil }
        return Homography.rectToQuad([0, 0, w, h], q)?.inverse()
    }
}

enum TransformKit {
    /// photocraft `catmull_rom`.
    @inline(__always)
    static func catmullRom(_ t: Double) -> (Double, Double, Double, Double) {
        let t2 = t * t, t3 = t2 * t
        return (-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1.0, -1.5 * t3 + 2.0 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2)
    }

    /// `img` with an alpha channel (1 everywhere) appended when `ctx` has none (photocraft's
    /// conversion to the format with alpha).
    static func withAlpha(_ img: FloatImage, _ ctx: FilterContext) -> (FloatImage, FilterContext) {
        if ctx.alpha { return (img, ctx) }
        let n = img.channels
        var out = FloatImage(rect: img.rect, channels: n + 1)
        for i in 0..<img.rect.area {
            for c in 0..<n { out.data[i * (n + 1) + c] = img.data[i * n + c] }
            out.data[i * (n + 1) + n] = 1
        }
        var c = ctx
        c.alpha = true
        return (out, c)
    }

    /// The warp after pre-reduction: inverse map, destination, and the horizon data per tile.
    struct Setup: Hashable, Sendable, Codable {
        var inv: Homography
        var srcRect: PixelRect
        var dst: PixelRect
        /// The sign of the forward w over the source (plus the sampler's margin), if one-signed.
        var side: Double?
        var wLo: Double
    }

    /// The pre-reduction factor for a large downscale (bicubic alone aliases below ~50 %), if any.
    /// With a clip, the scale that matters is the one at the source point landing in the clip's
    /// centre.
    static func prefilter(srcRect: PixelRect, h: Homography, interp: Interp, clip: PixelRect?) -> Double? {
        let cx: Double, cy: Double
        if let c = clip, let inv = h.inverse() {
            (cx, cy) = inv.apply((Double(c.x0) + Double(c.x1)) / 2, (Double(c.y0) + Double(c.y1)) / 2)
        } else {
            // Summed as doubles: a source rect near ±1.5e9 overflows the Int32 sum (photocraft #5451).
            (cx, cy) = ((Double(srcRect.x0) + Double(srcRect.x1)) / 2, (Double(srcRect.y0) + Double(srcRect.y1)) / 2)
        }
        let scale = h.localScale(cx, cy)
        if interp != .nearest && scale < 0.5 && scale > 0 {
            return min(pow(2.0, log2(scale).rounded(.up)), 1) // remaining scale lands in [0.5, 1)
        }
        return nil
    }

    /// photocraft `warp` after the pre-reduction: the destination and horizon data, nil when
    /// nothing is drawn.
    static func setup(srcRect: PixelRect, h: Homography, clip: PixelRect?) -> Setup? {
        guard let inv = h.inverse() else { return nil }
        // Destination bounds: the warped corners (plus a pixel for filter support).
        let corners = [(srcRect.x0, srcRect.y0), (srcRect.x1, srcRect.y0), (srcRect.x1, srcRect.y1), (srcRect.x0, srcRect.y1)]
            .map { h.apply(Double($0.0), Double($0.1)) }
        // A sampled pixel's inverse w is 1 / (forward w at its source point). While the forward w
        // keeps one sign over the source (plus the margin the sampler reads), every sampled pixel lies
        // at least `wLo` from the inverse horizon, so clipping a tile there keeps its footprint exact
        // and bounded even when a steep Distort brings that horizon into the tile (photocraft #2271).
        let (sx0, sy0, sx1, sy1) = (Double(srcRect.x0) - 1, Double(srcRect.y0) - 1, Double(srcRect.x1) + 1, Double(srcRect.y1) + 1)
        let fwdW = [(sx0, sy0), (sx1, sy0), (sx1, sy1), (sx0, sy1)].map { h.m[6] * $0.0 + h.m[7] * $0.1 + h.m[8] }
        let side = [1.0, -1.0].first { s in fwdW.allSatisfy { s * $0 > 0 } }
        let wLo = 1 / fwdW.reduce(0.0) { max($0, abs($1)) }
        let finite = corners.allSatisfy { $0.0.isFinite && $0.1.isFinite }
        let lim = Double(1 << 20)
        func bounds() -> PixelRect {
            let xs = corners.map(\.0), ys = corners.map(\.1)
            let bx0 = ResampleKit.i32(max(xs.reduce(Double.greatestFiniteMagnitude, min).rounded(.down), -lim)) - 1
            let by0 = ResampleKit.i32(max(ys.reduce(Double.greatestFiniteMagnitude, min).rounded(.down), -lim)) - 1
            let bx1 = ResampleKit.i32(min(xs.reduce(-Double.greatestFiniteMagnitude, max).rounded(.up), lim)) + 1
            let by1 = ResampleKit.i32(min(ys.reduce(-Double.greatestFiniteMagnitude, max).rounded(.up), lim)) + 1
            return PixelRect(x0: bx0, y0: by0, x1: bx1, y1: by1)
        }
        let dst: PixelRect
        switch clip {
        case .some(let c) where finite && side != nil: dst = bounds().intersect(c)
        case .some(let c): dst = c
        case .none where finite: dst = bounds()
        case .none: return nil
        }
        if dst.isEmpty { return nil }
        return Setup(inv: inv, srcRect: srcRect, dst: dst, side: side, wLo: wLo)
    }

    /// The source footprint of destination tile `t` (photocraft's per-tile set-up): nil when no
    /// sampled pixel of the tile can land in the source.
    static func footprint(_ s: Setup, _ t: PixelRect) -> PixelRect? {
        let inv = s.inv
        let tc = [(t.x0, t.y0), (t.x1, t.y0), (t.x1, t.y1), (t.x0, t.y1)].map { (Double($0.0), Double($0.1)) }
        let wc = tc.map { inv.m[6] * $0.0 + inv.m[7] * $0.1 + inv.m[8] }
        var poly: [(Double, Double)] = []
        if let sd = s.side {
            // Sutherland-Hodgman against `s * w >= wLo`.
            let d = wc.map { sd * $0 - s.wLo }
            for i in 0..<4 {
                let p = tc[i], dp = d[i], q = tc[(i + 1) % 4], dq = d[(i + 1) % 4]
                if dp >= 0 { poly.append(p) }
                if (dp >= 0) != (dq >= 0) {
                    let k = dp / (dp - dq)
                    poly.append((p.0 + (q.0 - p.0) * k, p.1 + (q.1 - p.1) * k))
                }
            }
        } else {
            poly = tc
        }
        if poly.isEmpty { return nil }
        let fp = poly.map { inv.apply($0.0, $0.1) }
        // Saturating: the casts saturate for a strongly skewed affine, and a wrapping ∓3 would turn
        // that into a footprint on the far side (photocraft #5451).
        let fx0 = Int32(clamping: Int64(ResampleKit.i32(fp.map(\.0).reduce(Double.greatestFiniteMagnitude, min).rounded(.down))) - 3)
        let fy0 = Int32(clamping: Int64(ResampleKit.i32(fp.map(\.1).reduce(Double.greatestFiniteMagnitude, min).rounded(.down))) - 3)
        let fx1 = Int32(clamping: Int64(ResampleKit.i32(fp.map(\.0).reduce(-Double.greatestFiniteMagnitude, max).rounded(.up))) + 3)
        let fy1 = Int32(clamping: Int64(ResampleKit.i32(fp.map(\.1).reduce(-Double.greatestFiniteMagnitude, max).rounded(.up))) + 3)
        // Without a one-signed forward w, a tile straddling the inverse horizon has no bounded footprint.
        let straddles = s.side == nil && wc.contains { $0 <= 0 } && wc.contains { $0 >= 0 }
        let foot = straddles ? s.srcRect : PixelRect(x0: fx0, y0: fy0, x1: fx1, y1: fy1).intersect(s.srcRect)
        return foot.isEmpty ? nil : foot
    }

    /// One destination tile (photocraft's `work`): `px` is the premultiplied source over `foot`
    /// (0 outside it). Returns nil when no pixel is drawn.
    static func renderTile(_ s: Setup, _ t: PixelRect, interp: Interp, foot: PixelRect, px: UnsafeBufferPointer<Float>, n: Int,
                           into outp: UnsafeMutableBufferPointer<Float>, stride ow: Int, origin: (Int32, Int32)) -> Bool {
        let inv = s.inv, sr = s.srcRect, a = n - 1
        let fw = foot.width
        @inline(__always) func at(_ x: Int32, _ y: Int32, _ c: Int) -> Double {
            if x < foot.x0 || y < foot.y0 || x >= foot.x1 || y >= foot.y1 { return 0 }
            return Double(px[(Int(y - foot.y0) * fw + Int(x - foot.x0)) * n + c])
        }
        var any = false
        var acc = [Double](repeating: 0, count: n)
        for y in t.y0..<t.y1 {
            for x in t.x0..<t.x1 {
                var (u, v) = inv.apply(Double(x) + 0.5, Double(y) + 0.5)
                u -= 0.5; v -= 0.5
                if u < Double(sr.x0) - 1 || v < Double(sr.y0) - 1 || u > Double(sr.x1) || v > Double(sr.y1) { continue }
                for c in 0..<n { acc[c] = 0 }
                switch interp {
                case .nearest:
                    let ix = ResampleKit.i32((u + 0.5).rounded(.down)), iy = ResampleKit.i32((v + 0.5).rounded(.down))
                    for c in 0..<n { acc[c] = at(ix, iy, c) }
                case .bilinear:
                    let ix = ResampleKit.i32(u.rounded(.down)), iy = ResampleKit.i32(v.rounded(.down))
                    let fx = u - Double(ix), fy = v - Double(iy)
                    for (dy, wy) in [(Int32(0), 1 - fy), (1, fy)] {
                        for (dx, wx) in [(Int32(0), 1 - fx), (1, fx)] {
                            for c in 0..<n { acc[c] += at(ix + dx, iy + dy, c) * wx * wy }
                        }
                    }
                case .bicubic:
                    let ix = ResampleKit.i32(u.rounded(.down)), iy = ResampleKit.i32(v.rounded(.down))
                    let cx = catmullRom(u - Double(ix)), cy = catmullRom(v - Double(iy))
                    let wx = [cx.0, cx.1, cx.2, cx.3], wy = [cy.0, cy.1, cy.2, cy.3]
                    for j in 0..<4 {
                        for i in 0..<4 {
                            let k = wx[i] * wy[j]
                            for c in 0..<n { acc[c] += at(ix - 1 + Int32(i), iy - 1 + Int32(j), c) * k }
                        }
                    }
                }
                let al = min(max(acc[a], 0), 1)
                if al <= 0 { continue }
                any = true
                let o = (Int(y - origin.1) * ow + Int(x - origin.0)) * n
                for c in 0..<a {
                    // Integer storage clips on write; float colours retain their signed/HDR range.
                    outp[o + c] = Float(acc[c] / al)
                }
                outp[o + a] = Float(al)
            }
        }
        return any
    }

    /// The destination tiles of `dst` (256-px grid, clipped).
    static func tiles(_ dst: PixelRect) -> [PixelRect] {
        dst.tiles.map { $0.rect.intersect(dst) }.filter { !$0.isEmpty }
    }

    /// Premultiplied `src` over `foot` (0 outside `src`).
    static func premulWindow(_ src: FloatImage, _ foot: PixelRect) -> [Float] {
        var px = src.crop(foot).data
        premultiply(&px, src.channels, true)
        return px
    }

    /// The CPU warp of a dense image with alpha (after pre-reduction) into a dense result over `s.dst`.
    static func warpCPU(_ src: FloatImage, _ s: Setup, interp: Interp) -> FloatImage {
        let n = src.channels
        var res = FloatImage(rect: s.dst, channels: n)
        let ts = tiles(s.dst)
        let ow = s.dst.width, origin = (s.dst.x0, s.dst.y0)
        res.data.withUnsafeMutableBufferPointer { rb in
            let r = UnsafeSendable(rb)
            parallelFor(ts.count) { i in
                let t = ts[i]
                guard let foot = footprint(s, t), !foot.intersect(src.rect).isEmpty else { return }
                let px = premulWindow(src, foot)
                px.withUnsafeBufferPointer { p in
                    _ = renderTile(s, t, interp: interp, foot: foot, px: p, n: n, into: r.value, stride: ow, origin: origin)
                }
            }
        }
        return res
    }

    /// Pre-reduction and set-up shared by every path; returns the (possibly reduced) source, the
    /// set-up, or nil when nothing is drawn.
    static func prepare(_ img: FloatImage, srcRect: PixelRect, h h0: Homography, interp: Interp, clip: PixelRect?, ctx: FilterContext,
                        backend: Backend) throws -> (FloatImage, Setup)? {
        if srcRect.isEmpty || (clip?.isEmpty ?? false) { return nil }
        var src = img, h = h0, sr = srcRect
        if let f = prefilter(srcRect: srcRect, h: h, interp: interp, clip: clip) {
            src = try Resample.resize(img, sx: f, sy: f, filter: .bicubic, context: ctx, on: backend)
            h = h.mul(Homography([1 / f, 0, 0, 0, 1 / f, 0, 0, 0, 1]))
            sr = Resample.scaledRect(srcRect, sx: f, sy: f)
        }
        guard let s = setup(srcRect: sr, h: h, clip: clip) else { return nil }
        return (src, s)
    }

    /// `Transform.warp` on an image with alpha.
    static func warpImage(_ img: FloatImage, srcRect: PixelRect, h: Homography, interp: Interp, clip: PixelRect?, ctx: FilterContext,
                          backend: Backend) throws -> FloatImage? {
        guard let (src, s) = try prepare(img, srcRect: srcRect, h: h, interp: interp, clip: clip, ctx: ctx, backend: backend) else { return nil }
        let f = WarpFilter(setup: s, interp: interp)
        let useGPU: Bool
        let fits = max(src.width, src.height, s.dst.width, s.dst.height) <= FilterEngine.maxGPUSize
        switch backend {
        case .cpu: useGPU = false
        case .gpu:
            guard fits else { throw FilterError.gpuUnsupported("Free Transform larger than \(FilterEngine.maxGPUSize) px") }
            useGPU = true
        case .auto: useGPU = fits && AlgoGPU.isAvailable
        }
        var c = ctx
        c.bounds = s.dst
        return try FilterEngine.apply(f, to: src, output: s.dst, context: c, on: useGPU ? .gpu : .cpu)
    }

    /// The surface-level warp (photocraft `warp`): per destination tile, reading only each tile's
    /// footprint, so memory stays bounded by the tile working set.
    static func warpSurface(_ src0: Surface, srcRect: PixelRect, h: Homography, interp: Interp, clip: PixelRect?, backend: Backend) -> Surface {
        let fmt0 = src0.format
        let fmt = fmt0.with(alpha: true)
        var out = Surface(format: fmt)
        if srcRect.isEmpty || (clip?.isEmpty ?? false) { return out }
        let ctx = FilterContext(bounds: srcRect, format: fmt)
        if backend != .cpu, AlgoGPU.isAvailable {
            do {
                if let r = try warpSurfaceDense(src0, srcRect: srcRect, h: h, interp: interp, clip: clip, ctx: ctx), !r.rect.isEmpty {
                    ResampleKit.write(&out, r.rect, r.data)
                }
                ResampleKit.prune(&out)
                return out
            } catch {
                // Too large for one GPU pass (or no GPU): the tiled CPU path below.
            }
        }
        // Pre-reduce on the CPU (Image Size of the whole surface).
        var src = src0
        var hh = h, sr = srcRect
        if let f = prefilter(srcRect: srcRect, h: h, interp: interp, clip: clip) {
            src = Resample.resizeSurface(src0, sx: f, sy: f, filter: .bicubic, on: .cpu)
            hh = h.mul(Homography([1 / f, 0, 0, 0, 1 / f, 0, 0, 0, 1]))
            sr = Resample.scaledRect(srcRect, sx: f, sy: f)
        }
        guard let s = setup(srcRect: sr, h: hh, clip: clip) else { return out }
        let n = fmt.channels
        let addAlpha = !fmt0.alpha
        let ts = tiles(s.dst)
        var done = [(PixelRect, [Float])?](repeating: nil, count: ts.count)
        done.withUnsafeMutableBufferPointer { db in
            let d = UnsafeSendable(db)
            parallelFor(ts.count) { i in
                let t = ts[i]
                guard let foot = footprint(s, t), foot.tiles.contains(where: { src.tile($0) != nil }) else { return }
                var px = readWithAlpha(src, foot, addAlpha: addAlpha)
                premultiply(&px, n, true)
                var outp = [Float](repeating: 0, count: t.area * n)
                let any = px.withUnsafeBufferPointer { p in
                    outp.withUnsafeMutableBufferPointer { o in
                        renderTile(s, t, interp: interp, foot: foot, px: p, n: n, into: o, stride: t.width, origin: (t.x0, t.y0))
                    }
                }
                if any { d.value[i] = (t, outp) }
            }
        }
        for case let (r, v)? in done { ResampleKit.write(&out, r, v) }
        ResampleKit.prune(&out)
        return out
    }

    /// `r` of `s` as floats, with alpha 1 appended when the surface has none.
    static func readWithAlpha(_ s: Surface, _ r: PixelRect, addAlpha: Bool) -> [Float] {
        let raw = s.readRegion(r)
        if !addAlpha { return raw }
        let n = s.channels
        var out = [Float](repeating: 1, count: r.area * (n + 1))
        for i in 0..<r.area { for c in 0..<n { out[i * (n + 1) + c] = raw[i * n + c] } }
        return out
    }

    /// The surface warp through the dense image path (GPU), when the source and result are small
    /// enough to hold and the surface's default pixel is transparent; nil when nothing is drawn,
    /// throws to fall back to the tiled CPU path.
    static func warpSurfaceDense(_ src: Surface, srcRect: PixelRect, h: Homography, interp: Interp, clip: PixelRect?,
                                 ctx: FilterContext) throws -> FloatImage? {
        // Without alpha, photocraft's conversion makes the default pixel opaque; the dense image
        // reads transparency outside the content, so those surfaces stay on the CPU path.
        guard src.format.alpha, src.defaultPixelValue.allSatisfy({ $0 == 0 }) else { throw FilterError.gpuUnsupported("opaque default pixel") }
        let content = ResampleKit.contentBounds(src)
        let m = FilterEngine.maxGPUSize
        if content.isEmpty { return nil }
        if content.width > m || content.height > m || content.area > 1 << 26 { throw FilterError.gpuUnsupported("large source") }
        let n = src.format.with(alpha: true).channels
        let img = FloatImage(rect: content, channels: n, data: readWithAlpha(src, content, addAlpha: !src.format.alpha))
        guard let (s0, s) = try prepare(img, srcRect: srcRect, h: h, interp: interp, clip: clip, ctx: ctx, backend: .auto) else { return nil }
        if max(s0.width, s0.height, s.dst.width, s.dst.height) > m || s.dst.area > 1 << 26 { throw FilterError.gpuUnsupported("large result") }
        var c = ctx
        c.bounds = s.dst
        return try FilterEngine.apply(WarpFilter(setup: s, interp: interp), to: s0, output: s.dst, context: c, on: .gpu)
    }
}

// MARK: - Metal

extension TransformKit {
    /// MSL `pca_rs_warp_params`.
    struct WarpParams: BitwiseCopyable {
        var rectLo: SIMD2<Int32>
        var rectHi: SIMD2<Int32>
        var interp: Int32
        var pad0: Int32 = 0
        var pad1: Int32 = 0
        var pad2: Int32 = 0
    }

    /// The warp of one set-up as a filter over `setup.dst` (the source has alpha).
    struct WarpFilter: Filter {
        var setup: Setup
        var interp: Interp
        var label: String { "Free Transform" }
        func halo(bounds: PixelRect) -> Halo { .bounds }

        func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
            precondition(ctx.alpha && out == setup.dst)
            return warpCPU(src, setup, interp: interp)
        }

        func encodeGPU(_ pass: GPUPass) throws {
            let mb = try pass.buffer(setup.inv.m.map(\.bitPattern))
            let sr = setup.srcRect
            try pass.dispatchOut("pca_rs_warp", params: WarpParams(rectLo: SIMD2(sr.x0, sr.y0), rectHi: SIMD2(sr.x1, sr.y1), interp: interp.code),
                                 buffers: [mb])
        }
    }
}
