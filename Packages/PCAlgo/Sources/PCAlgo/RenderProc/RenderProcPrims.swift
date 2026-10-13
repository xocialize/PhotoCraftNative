// Port of photocraft-algo (crates/algo/src/render2.rs: `Shape`, `Prim`, `Blend`, `Rng`, `noise1`, `fbm1`, `Spine`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Procedural renderers of Filter › Render (Flame, Picture Frame, Tree). Each renderer turns its
// options into a list of anti-aliased vector primitives — tapered capsules and shaded ellipses,
// blended normally, additively or by lightening — and `RenderProc.composite` rasterises the list
// over a surface. Primitive generation is CPU work and reproduces photocraft's lists (same
// SplitMix64 stream, same float operations, same libm calls); the rasterisation runs on the CPU
// or in Metal with identical results.

import Foundation
import PCFoundation

/// Filter › Render › Flame, Picture Frame and Tree (photocraft `render2`).
public enum RenderProc {
    /// Geometry of a primitive in document pixel coordinates (photocraft `Shape`).
    public enum Shape: Equatable, Sendable {
        /// A segment from `a` to `b` whose radius goes from `ra` to `rb`; colour goes `c0` → `c1` along it.
        case capsule(a: SIMD2<Float>, b: SIMD2<Float>, ra: Float, rb: Float)
        /// An ellipse rotated by `angle` radians; colour goes `c0` (centre) → `c1` (rim).
        case ellipse(c: SIMD2<Float>, rx: Float, ry: Float, angle: Float)
    }

    /// How a primitive combines with what is under it (photocraft `Blend`).
    public enum Blend: Equatable, Sendable {
        /// Source over.
        case normal
        /// Additive light (glows).
        case add
        /// Per-channel maximum of the premultiplied values (overlapping strands don't build up).
        case lighten
    }

    /// One drawable primitive; colours are straight sRGB RGBA (0–1) (photocraft `Prim`).
    public struct Prim: Equatable, Sendable {
        public var shape: Shape
        public var c0: SIMD4<Float>
        public var c1: SIMD4<Float>
        /// Edge softness in pixels (≥ 1 for anti-aliasing; larger for glows).
        public var soft: Float
        public var blend: Blend

        public init(shape: Shape, c0: SIMD4<Float>, c1: SIMD4<Float>, soft: Float = 1, blend: Blend = .normal) {
            self.shape = shape; self.c0 = c0; self.c1 = c1; self.soft = soft; self.blend = blend
        }

        public static func capsule(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ ra: Float, _ rb: Float, _ c0: SIMD4<Float>, _ c1: SIMD4<Float>) -> Prim {
            Prim(shape: .capsule(a: a, b: b, ra: ra, rb: rb), c0: c0, c1: c1)
        }
        public static func ellipse(_ c: SIMD2<Float>, _ rx: Float, _ ry: Float, _ angle: Float, _ c0: SIMD4<Float>, _ c1: SIMD4<Float>) -> Prim {
            Prim(shape: .ellipse(c: c, rx: rx, ry: ry, angle: angle), c0: c0, c1: c1)
        }
        public static func disc(_ c: SIMD2<Float>, _ r: Float, _ col: SIMD4<Float>) -> Prim { ellipse(c, r, r, 0, col, col) }

        func withSoft(_ s: Float) -> Prim { var p = self; p.soft = s; return p }
        func additive() -> Prim { var p = self; p.blend = .add; return p }
        func lightened() -> Prim { var p = self; p.blend = .lighten; return p }

        /// Pixel bounds this primitive can touch (photocraft `Prim::bounds`).
        public var bounds: PixelRect {
            let s = Float.maximum(soft, 1) + 1
            let x0: Float, y0: Float, x1: Float, y1: Float
            switch shape {
            case .capsule(let a, let b, let ra, let rb):
                let r = Float.maximum(ra, rb) + s
                (x0, y0, x1, y1) = (Float.minimum(a.x, b.x) - r, Float.minimum(a.y, b.y) - r, Float.maximum(a.x, b.x) + r, Float.maximum(a.y, b.y) + r)
            case .ellipse(let c, let rx, let ry, let angle):
                let (sn, cs) = (sinf(angle), cosf(angle))
                let ex = ((rx * cs) * (rx * cs) + (ry * sn) * (ry * sn)).squareRoot() + s
                let ey = ((rx * sn) * (rx * sn) + (ry * cs) * (ry * cs)).squareRoot() + s
                (x0, y0, x1, y1) = (c.x - ex, c.y - ey, c.x + ex, c.y + ey)
            }
            if !(x0.isFinite && y0.isFinite && x1.isFinite && y1.isFinite) { return .empty }
            func cl(_ v: Float) -> Int32 { PCAMath.i32(clampf(v, -1.0e8, 1.0e8)) }
            return PixelRect(x0: cl(x0.rounded(.down)), y0: cl(y0.rounded(.down)), x1: cl(x1.rounded(.up)), y1: cl(y1.rounded(.up)))
        }

        /// Coverage (0–1) and colour position (0–1) at a pixel centre (photocraft `Prim::eval`).
        @inline(__always)
        func eval(_ x: Float, _ y: Float, _ sc: (Float, Float)) -> (Float, Float) {
            let soft = Float.maximum(self.soft, 1)
            switch shape {
            case .capsule(let a, let b, let ra, let rb):
                let dx = b.x - a.x, dy = b.y - a.y
                let l2 = dx * dx + dy * dy
                let t: Float = l2 > 1e-9 ? clampf(((x - a.x) * dx + (y - a.y) * dy) / l2, 0, 1) : 0
                let px = a.x + dx * t - x, py = a.y + dy * t - y
                let d = (px * px + py * py).squareRoot()
                let r = ra + (rb - ra) * t
                // Hairlines thinner than a pixel fade instead of vanishing.
                let thin = clampf(2 * r, 0, 1)
                return (clampf((Float.maximum(r, 0.5) - d) / soft + 0.5, 0, 1) * thin, t)
            case .ellipse(let c, let rx0, let ry0, _):
                let (s, co) = sc
                let dx = x - c.x, dy = y - c.y
                let u = dx * co + dy * s, v = -dx * s + dy * co
                let rx = Float.maximum(rx0, 0.05), ry = Float.maximum(ry0, 0.05)
                let e = ((u / rx) * (u / rx) + (v / ry) * (v / ry)).squareRoot()
                let edge = (1 - e) * Float.minimum(rx, ry)
                let thin = clampf(2 * Float.minimum(rx, ry), 0, 1)
                return (clampf(edge / soft + 0.5, 0, 1) * thin, Float.minimum(e, 1))
            }
        }

        /// (sin, cos) of the ellipse angle (photocraft evaluates `angle.sin_cos()` per pixel; the
        /// value does not depend on the pixel).
        var sinCos: (Float, Float) {
            if case .ellipse(_, _, _, let a) = shape { return (sinf(a), cosf(a)) }
            return (0, 1)
        }
    }

    /// Small deterministic PRNG (SplitMix64) — photocraft `Rng`.
    public struct Rng: Sendable {
        public var state: UInt64

        public init(state: UInt64) { self.state = state }
        public init(seed: UInt32, salt: UInt64) {
            state = (UInt64(seed) << 32) ^ (salt &* 0x9E37_79B9_7F4A_7C15) ^ 0x2545_F491_4F6C_DD1D
        }
        public mutating func nextU64() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// Uniform in [0, 1).
        public mutating func f() -> Float { Float(nextU64() >> 40) / Float(1 << 24) }
        /// Uniform in [a, b).
        public mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * f() }
        /// Uniform in [−1, 1).
        public mutating func sym() -> Float { f() * 2 - 1 }
    }
}

/// Helpers of the RenderProc area.
enum RenderProcKit {
    /// Rust `f32 as i64` (saturating, NaN → 0).
    @inline(__always)
    static func i64(_ v: Float) -> Int64 {
        if v.isNaN { return 0 }
        if v >= 9.223372e18 { return .max }
        if v <= -9.223372e18 { return .min }
        return Int64(v)
    }

    /// Rust `i32::div_euclid` (positive divisor).
    @inline(__always)
    static func divEuclid(_ a: Int32, _ b: Int32) -> Int32 {
        let q = a / b
        return a % b < 0 ? q - 1 : q
    }

    /// Smooth 1-D value noise in [−1, 1] (photocraft `noise1`).
    static func noise1(_ x: Float, _ seed: UInt64) -> Float {
        func h(_ i: Int64) -> Float {
            var r = RenderProc.Rng(state: UInt64(bitPattern: i) &* 0xD6E8_FEB8_6659_FD93 ^ seed)
            return r.sym()
        }
        let fi = x.rounded(.down)
        let f = x - fi
        let i = i64(fi)
        let t = f * f * (3 - 2 * f)
        return h(i) + (h(i &+ 1) - h(i)) * t
    }

    /// Two octaves of `noise1` (photocraft `fbm1`).
    static func fbm1(_ x: Float, _ seed: UInt64) -> Float {
        (noise1(x, seed) + 0.5 * noise1(x * 2.13 + 7.1, seed ^ 0xA5A5)) / 1.5
    }

    /// LLVM's `powi` (compiler-rt `__powisf2`): Rust's `f32::powi` with a run-time exponent.
    static func powi(_ a0: Float, _ b0: Int32) -> Float {
        var a = a0, b = b0
        let recip = b < 0
        var r: Float = 1
        while true {
            if b & 1 != 0 { r *= a }
            b /= 2
            if b == 0 { break }
            a *= a
        }
        return recip ? 1 / r : r
    }

    /// Rust's `slice::binary_search_by` (the branchless version: the loop count depends only on
    /// the length; ties resolve as it does), with photocraft Spine's comparator
    /// `v.partial_cmp(&s).unwrap_or(Less)`.
    static func binarySearch(_ cum: [Float], _ s: Float) -> (found: Bool, index: Int) {
        func cmp(_ v: Float) -> Int { v < s ? -1 : (v > s ? 1 : (v == s ? 0 : -1)) }
        var size = cum.count
        if size == 0 { return (false, 0) }
        var base = 0
        while size > 1 {
            let half = size / 2
            let mid = base + half
            if cmp(cum[mid]) != 1 { base = mid }
            size -= half
        }
        let c = cmp(cum[base])
        if c == 0 { return (true, base) }
        return (false, base + (c == -1 ? 1 : 0))
    }

    /// A polyline parameterised by arc length (photocraft `Spine`).
    struct Spine {
        var pts: [SIMD2<Float>]
        var cum: [Float]

        init(_ pts: [SIMD2<Float>]) {
            self.pts = pts
            var cum: [Float] = [0]
            if pts.count >= 2 {
                for i in 1..<pts.count {
                    let dx = pts[i].x - pts[i - 1].x, dy = pts[i].y - pts[i - 1].y
                    cum.append((cum.last ?? 0) + (dx * dx + dy * dy).squareRoot())
                }
            }
            self.cum = cum
        }

        var len: Float { cum.last ?? 0 }

        /// Point and unit tangent at arc length `s`.
        func at(_ s0: Float) -> (SIMD2<Float>, SIMD2<Float>) {
            let n = pts.count
            if n == 0 { return (SIMD2(0, 0), SIMD2(1, 0)) }
            if n == 1 { return (pts[0], SIMD2(0, -1)) }
            let s = clampf(s0, 0, len)
            let (found, i) = binarySearch(cum, s)
            let k = found ? min(i, n - 2) : min(max(i - 1, 0), n - 2)
            let a = pts[k], b = pts[k + 1]
            let seg = Float.maximum(cum[k + 1] - cum[k], 1e-6)
            let t = clampf((s - cum[k]) / seg, 0, 1)
            let dx = b.x - a.x, dy = b.y - a.y
            let l = Float.maximum((dx * dx + dy * dy).squareRoot(), 1e-6)
            return (SIMD2(a.x + dx * t, a.y + dy * t), SIMD2(dx / l, dy / l))
        }
    }

    /// photocraft `shade`: a colour scaled by `k`, clamped, opaque.
    @inline(__always)
    static func shade(_ c: SIMD3<Float>, _ k: Float) -> SIMD4<Float> {
        SIMD4(clampf(c.x * k, 0, 1), clampf(c.y * k, 0, 1), clampf(c.z * k, 0, 1), 1)
    }

    @inline(__always) static func rgb(_ c: SIMD4<Float>) -> SIMD3<Float> { SIMD3(c.x, c.y, c.z) }

    /// Rust `f32::fract` (x − trunc x).
    @inline(__always) static func fract(_ x: Float) -> Float { x - x.rounded(.towardZero) }

    static let fracPi2: Float = 1.57079632679489661923
    static let fracPi3: Float = 1.04719755119659774615
    static let fracPi4: Float = 0.785398163397448309616
}
