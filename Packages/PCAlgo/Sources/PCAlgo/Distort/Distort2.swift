// Port of photocraft-algo (crates/algo/src/distort2.rs, params_ext.rs, lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Distort, second batch: Displace (a caller-supplied map), Shear (a Catmull–Rom curve of
// per-row offsets) and ZigZag (radial ripples). Inverse mappings over the reference bounds through
// `DistortKit.remap`; Metal kernels in Shaders/Distort2.metal.

import Foundation
import PCFoundation

/// ZigZag style (photocraft `ZigZagStyle`).
public enum ZigZagStyle: String, Codable, Sendable, Hashable, CaseIterable {
    case aroundCenter, outFromCenter, pondRipples
}

// MARK: GPU uniforms (mirrored in Distort2.metal)

struct DistortDisplaceGPU: BitwiseCopyable {
    var b0: SIMD2<Float>; var bsize: SIMD2<Float>; var msize: SIMD2<Float>; var scale: SIMD2<Float>
    var mdim: SIMD2<Int32>; var stretch: UInt32; var edge: UInt32
}
struct DistortShearGPU: BitwiseCopyable { var rows: Int32; var edge: UInt32; var pad0: Int32 = 0; var pad1: Int32 = 0 }
struct DistortZigZagGPU: BitwiseCopyable {
    var c: SIMD2<Float>; var rr: Float; var a: Float; var k: Float; var style: UInt32; var pad0: Int32 = 0; var pad1: Int32 = 0
}

// MARK: Displace

/// Filter › Distort › Displace: the map's first channel shifts pixels horizontally and its
/// second (or first, for one- and two-channel maps) vertically; mid-grey is no shift, and 100 %
/// moves 128 px at full contrast. The map is stretched over the bounds or tiled from their
/// top-left. Without a map the filter is an identity.
public struct Displace: Filter, Hashable {
    /// Horizontal scale, −999…999 %.
    public var horizontal: Float
    /// Vertical scale, −999…999 %.
    public var vertical: Float
    /// Stretch the map over the bounds (else tile it).
    public var stretch: Bool
    public var undefined: UndefinedAreas
    /// The displacement map, in its own coordinates (`map.rect`), with straight samples. Supplied
    /// by the caller and not encoded (photocraft's `#[serde(skip)] map`).
    public var map: FloatImage?

    enum CodingKeys: String, CodingKey { case horizontal, vertical, stretch, undefined }

    public init(horizontal: Float = 10, vertical: Float = 10, stretch: Bool = true, undefined: UndefinedAreas = .repeat, map: FloatImage? = nil) {
        self.horizontal = horizontal; self.vertical = vertical; self.stretch = stretch; self.undefined = undefined; self.map = map
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(horizontal: try c.decode(Float.self, forKey: .horizontal), vertical: try c.decode(Float.self, forKey: .vertical),
                  stretch: try c.decode(Bool.self, forKey: .stretch), undefined: try c.decode(UndefinedAreas.self, forKey: .undefined))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(horizontal, forKey: .horizontal); try c.encode(vertical, forKey: .vertical)
        try c.encode(stretch, forKey: .stretch); try c.encode(undefined, forKey: .undefined)
    }

    public func hash(into h: inout Hasher) {
        h.combine(horizontal); h.combine(vertical); h.combine(stretch); h.combine(undefined)
        h.combine(map?.rect); h.combine(map?.channels)
    }

    /// Max displacement at 100 % scale and full map contrast, px (photocraft `DISPLACE_PX`).
    static let displacePx: Float = 128

    public var label: String { "Displace" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }

    /// The map's vertical channel: 1 for maps with three or more channels, else 0.
    static func verticalChannel(_ map: FloatImage) -> Int { map.channels >= 3 ? 1 : 0 }

    /// photocraft `map_sample`: bilinear read of channel `c` at map-local `(u, v)`, clamped.
    static func mapSample(_ map: FloatImage, _ u: Float, _ v: Float, _ c: Int) -> Float {
        let r = map.rect
        let w = Int32(r.width), h = Int32(r.height)
        let fx = u - 0.5, fy = v - 0.5
        let flx = fx.rounded(.down), fly = fy.rounded(.down)
        let ax = fx - flx, ay = fy - fly
        let x0 = DistortKit.floorToInt(flx), y0 = DistortKit.floorToInt(fly)
        let n = map.channels
        @inline(__always) func g(_ x: Int32, _ y: Int32) -> Float {
            let xx = min(max(x, 0), w - 1), yy = min(max(y, 0), h - 1)
            return map.data[(Int(yy) * Int(w) + Int(xx)) * n + c]
        }
        let top = g(x0, y0) + (g(x0 + 1, y0) - g(x0, y0)) * ax
        let bot = g(x0, y0 + 1) + (g(x0 + 1, y0 + 1) - g(x0, y0 + 1)) * ax
        return top + (bot - top) * ay
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        guard let map, !map.rect.isEmpty, map.channels > 0 else { return src.crop(out) }
        let b = ctx.bounds
        let mw = Float(map.rect.width), mh = Float(map.rect.height)
        let bw = Float(max(b.width, 1)), bh = Float(max(b.height, 1))
        let vc = Displace.verticalChannel(map)
        let sx = horizontal / 100 * Displace.displacePx, sy = vertical / 100 * Displace.displacePx
        let stretch = self.stretch
        return DistortKit.remap(src, out, ctx, undefined.edge) { x, y in
            let lx = x - Float(b.x0), ly = y - Float(b.y0)
            let (u, v) = stretch ? (lx / bw * mw, ly / bh * mh) : (euclidMod(lx, mw), euclidMod(ly, mh))
            let dx = (Displace.mapSample(map, u, v, 0) - 0.5) * 2 * sx
            let dy = (Displace.mapSample(map, u, v, vc) - 0.5) * 2 * sy
            return (x + dx, y + dy)
        }
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        guard let map, !map.rect.isEmpty, map.channels > 0 else {
            try pass.dispatchOut("pca_copy", params: NoParams())
            return
        }
        let b = pass.ctx.bounds
        let n = map.channels, vc = Displace.verticalChannel(map)
        // The map's two displacement channels, row-major over map.rect (an extra GPU input).
        var packed = [SIMD2<Float>](repeating: .zero, count: map.rect.area)
        map.data.withUnsafeBufferPointer { m in
            for i in 0..<packed.count { packed[i] = SIMD2(m[i * n], m[i * n + vc]) }
        }
        let p = DistortDisplaceGPU(b0: SIMD2(Float(b.x0), Float(b.y0)), bsize: SIMD2(Float(max(b.width, 1)), Float(max(b.height, 1))),
                                   msize: SIMD2(Float(map.rect.width), Float(map.rect.height)),
                                   scale: SIMD2(horizontal / 100 * Displace.displacePx, vertical / 100 * Displace.displacePx),
                                   mdim: SIMD2(Int32(map.rect.width), Int32(map.rect.height)), stretch: stretch ? 1 : 0,
                                   edge: undefined.gpuEdge)
        try pass.dispatchOut("pca_dis_displace", params: p, buffers: [try pass.buffer(packed)])
    }
}

// MARK: Shear

/// Filter › Distort › Shear: each row shifts horizontally by the curve through `points`
/// (`[t, offset]`: t 0…1 top → bottom, offset −1…1 of half the bounds' width).
public struct Shear: Filter, Hashable {
    public var points: [SIMD2<Float>]
    public var undefined: UndefinedAreas

    public init(points: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0)], undefined: UndefinedAreas = .wrap) {
        self.points = points; self.undefined = undefined
    }

    public var label: String { "Shear" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }

    /// photocraft `curve_at`: Catmull–Rom through sorted `(t, value)` points, clamped ends.
    static func curveAt(_ pts: [SIMD2<Float>], _ t: Float) -> Float {
        switch pts.count {
        case 0: return 0
        case 1: return pts[0].y
        default:
            if t <= pts[0].x { return pts[0].y }
            let last = pts.count - 1
            if t >= pts[last].x { return pts[last].y }
            var i = 0
            for k in 0..<last where t >= pts[k].x && t <= pts[k + 1].x { i = k; break }
            let p1 = pts[i], p2 = pts[i + 1]
            let p0 = i > 0 ? pts[i - 1] : p1
            let p3 = i + 2 <= last ? pts[i + 2] : p2
            let span = Float.maximum(p2.x - p1.x, 1e-6)
            let s = (t - p1.x) / span
            // Tangents scaled to the span (non-uniform Catmull–Rom).
            let m1 = i > 0 ? (p2.y - p0.y) / Float.maximum(p2.x - p0.x, 1e-6) * span : p2.y - p1.y
            let m2 = i + 2 <= last ? (p3.y - p1.y) / Float.maximum(p3.x - p1.x, 1e-6) * span : p2.y - p1.y
            let s2 = s * s, s3 = s * s * s
            let h00 = (2 * s3 - 3 * s2 + 1) * p1.y
            let h10 = (s3 - 2 * s2 + s) * m1
            let h01 = (-2 * s3 + 3 * s2) * p2.y
            let h11 = (s3 - s2) * m2
            return h00 + h10 + h01 + h11
        }
    }

    /// The points clamped, sorted by t (stable, IEEE total order) and de-duplicated (photocraft's
    /// `sort_by(total_cmp)` + `dedup_by`).
    var prepared: [SIMD2<Float>] {
        let pts = points.map { SIMD2(clampf($0.x, 0, 1), clampf($0.y, -1, 1)) }
        let sorted = pts.enumerated().sorted { a, b in
            if a.element.x.isTotallyOrdered(belowOrEqualTo: b.element.x) && !b.element.x.isTotallyOrdered(belowOrEqualTo: a.element.x) { return true }
            if b.element.x.isTotallyOrdered(belowOrEqualTo: a.element.x) && !a.element.x.isTotallyOrdered(belowOrEqualTo: b.element.x) { return false }
            return a.offset < b.offset
        }.map(\.element)
        var res: [SIMD2<Float>] = []
        for p in sorted {
            if let prev = res.last, abs(p.x - prev.x) < 1e-6 { continue }
            res.append(p)
        }
        return res
    }

    /// Per-row offsets for the rows of `out` (shared by every pixel of the row).
    func rowOffsets(_ out: PixelRect, _ b: PixelRect) -> [Float] {
        let pts = prepared
        let bw = Float(max(b.width, 1)), bh = Float(max(b.height, 1))
        return (out.y0..<out.y1).map { y in Shear.curveAt(pts, (Float(y) + 0.5 - Float(b.y0)) / bh) * bw / 2 }
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let rows = rowOffsets(out, ctx.bounds)
        let last = Int32(rows.count) - 1
        return DistortKit.remap(src, out, ctx, undefined.edge) { x, y in
            let i = Int(min(max(DistortKit.floorToInt(y - 0.5) - out.y0, 0), last))
            return (x - rows[i], y)
        }
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let rows = rowOffsets(pass.out, pass.ctx.bounds)
        try pass.dispatchOut("pca_dis_shear", params: DistortShearGPU(rows: Int32(rows.count), edge: undefined.gpuEdge),
                             buffers: [try pass.buffer(rows)])
    }
}

// MARK: ZigZag

/// Filter › Distort › ZigZag: radial ripples inside the bounds' inscribed circle — around the
/// centre (angular), out from it (radial) or both (pond ripples). `amount` −100…100, `ridges` 0…20.
public struct ZigZag: Filter, Hashable {
    public var amount: Float
    public var ridges: Float
    public var style: ZigZagStyle
    public init(amount: Float = 10, ridges: Float = 5, style: ZigZagStyle = .pondRipples) {
        self.amount = amount; self.ridges = ridges; self.style = style
    }
    public var label: String { "ZigZag" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }

    var a: Float { clampf(amount / 100, -1, 1) }
    var k: Float { Float.maximum(clampf(ridges, 0, 20), 0.5) }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let (cx, cy, rr) = DistortKit.centre(ctx.bounds)
        let a = self.a, k = self.k, style = self.style
        let tau = DistortKit.tau, pi = DistortKit.pi
        return DistortKit.remap(src, out, ctx, .repeatEdge) { x, y in
            let dx = x - cx, dy = y - cy
            let r = (dx * dx + dy * dy).squareRoot()
            if r >= rr || r <= 0 || a == 0 { return (x, y) }
            let rn = r / rr
            let wave = sinf(tau * k * rn) * (1 - rn)
            let radial: Float, angular: Float
            switch style {
            case .outFromCenter: (radial, angular) = (a * wave * rr / (4 * k), 0)
            case .aroundCenter: (radial, angular) = (0, a * wave * pi / (2 * k))
            case .pondRipples: (radial, angular) = (a * wave * rr / (8 * k), a * wave * pi / (4 * k))
            }
            let th = atan2f(dy, dx) + angular
            let rs = Float.maximum(r + radial, 0)
            return (cx + rs * cosf(th), cy + rs * sinf(th))
        }
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let (cx, cy, rr) = DistortKit.centre(pass.ctx.bounds)
        let st: UInt32 = switch style { case .aroundCenter: 0; case .outFromCenter: 1; case .pondRipples: 2 }
        try pass.dispatchOut("pca_dis_zigzag", params: DistortZigZagGPU(c: SIMD2(cx, cy), rr: rr, a: a, k: k, style: st))
    }
}
