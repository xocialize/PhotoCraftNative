// Port of photocraft-algo (crates/algo/src/render2.rs: `FRAME_STYLES`, `FrameSpec`, `Border`, `flower`, `leaf`, `star`, `picture_frame`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Render › Picture Frame: 16 ornament designs walked along a frame inside the canvas.

import Foundation
import PCFoundation

/// Picture Frame options — photocraft `FrameSpec`; fields default when missing.
public struct FrameSpec: Codable, Sendable, Hashable {
    /// 1-based design (see `RenderProc.frameStyles`).
    public var frame: UInt32 = 1
    /// Distance of the frame from the canvas edge, % of the shorter side (0–30).
    public var margin: Float = 4
    /// Ornament size 1–100.
    public var size: Float = 50
    /// Ornament spacing / density 1–100 (higher = denser).
    public var arrangement: Float = 50
    /// Number of parallel lines for line designs (1–5).
    public var lines: UInt32 = 1
    /// Line / vine thickness 1–100.
    public var thickness: Float = 30
    /// 0–100 %: fade the ornaments towards the inside.
    public var fade: Float = 0
    public var vineColor = SIMD4<Float>(0.25, 0.4, 0.15, 1)
    public var flowerColor = SIMD4<Float>(0.9, 0.3, 0.45, 1)
    public var leafColor = SIMD4<Float>(0.3, 0.6, 0.2, 1)
    public var seed: UInt32 = 0

    public init() {}

    enum CodingKeys: String, CodingKey { case frame, margin, size, arrangement, lines, thickness, fade, vineColor, flowerColor, leafColor, seed }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FrameSpec()
        frame = try c.decodeIfPresent(UInt32.self, forKey: .frame) ?? d.frame
        margin = try c.decodeIfPresent(Float.self, forKey: .margin) ?? d.margin
        size = try c.decodeIfPresent(Float.self, forKey: .size) ?? d.size
        arrangement = try c.decodeIfPresent(Float.self, forKey: .arrangement) ?? d.arrangement
        lines = try c.decodeIfPresent(UInt32.self, forKey: .lines) ?? d.lines
        thickness = try c.decodeIfPresent(Float.self, forKey: .thickness) ?? d.thickness
        fade = try c.decodeIfPresent(Float.self, forKey: .fade) ?? d.fade
        vineColor = try c.decodeIfPresent(SIMD4<Float>.self, forKey: .vineColor) ?? d.vineColor
        flowerColor = try c.decodeIfPresent(SIMD4<Float>.self, forKey: .flowerColor) ?? d.flowerColor
        leafColor = try c.decodeIfPresent(SIMD4<Float>.self, forKey: .leafColor) ?? d.leafColor
        seed = try c.decodeIfPresent(UInt32.self, forKey: .seed) ?? d.seed
    }
}

extension RenderProcKit {
    /// The frame rectangle walked by arc length, clockwise from the top-left (photocraft `Border`).
    struct Border {
        var x0: Float, y0: Float, w: Float, h: Float

        var len: Float { 2 * (w + h) }

        /// Point, unit tangent and inward normal at arc length `s`.
        func at(_ s0: Float) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
            let s = euclidMod(s0, len)
            if s < w { return (SIMD2(x0 + s, y0), SIMD2(1, 0), SIMD2(0, 1)) }
            if s < w + h { return (SIMD2(x0 + w, y0 + s - w), SIMD2(0, 1), SIMD2(-1, 0)) }
            if s < 2 * w + h { return (SIMD2(x0 + w - (s - w - h), y0 + h), SIMD2(-1, 0), SIMD2(0, -1)) }
            return (SIMD2(x0, y0 + h - (s - 2 * w - h)), SIMD2(0, -1), SIMD2(1, 0))
        }
    }

    static func flower(_ out: inout [RenderProc.Prim], _ c: SIMD2<Float>, _ r: Float, _ petals: Int, _ petal: SIMD4<Float>, _ centre: SIMD4<Float>, _ rot: Float) {
        for k in 0..<petals {
            let a = rot + Float(k) / Float(petals) * PCAMath.tau
            let p = SIMD2(c.x + cosf(a) * r * 0.55, c.y + sinf(a) * r * 0.55)
            out.append(.ellipse(p, r * 0.5, r * 0.26, a, petal, shade(rgb(petal), 0.8)))
        }
        out.append(.ellipse(c, r * 0.28, r * 0.28, 0, centre, shade(rgb(centre), 0.75)))
    }

    static func leaf(_ out: inout [RenderProc.Prim], _ p: SIMD2<Float>, _ ang: Float, _ len: Float, _ col: SIMD4<Float>) {
        let c = SIMD2(p.x + cosf(ang) * len * 0.5, p.y + sinf(ang) * len * 0.5)
        out.append(.ellipse(c, len * 0.5, len * 0.22, ang, shade(rgb(col), 1.12), shade(rgb(col), 0.8)))
    }

    static func star(_ out: inout [RenderProc.Prim], _ c: SIMD2<Float>, _ r: Float, _ points: Int, _ col: SIMD4<Float>, _ rot: Float) {
        for k in 0..<points {
            let a = rot + Float(k) / Float(points) * PCAMath.tau
            out.append(.capsule(c, SIMD2(c.x + cosf(a) * r, c.y + sinf(a) * r), r * 0.28, 0.4, col, col))
        }
    }
}

extension RenderProc {
    /// Picture frame designs (index = `frame` − 1) — photocraft `FRAME_STYLES`.
    public static let frameStyles = ["vineWithFlowers", "vineWithLeaves", "ivy", "roses", "daisies", "berries", "bamboo", "waves", "zigzag",
                                     "dots", "rope", "scallops", "doubleLine", "snowflakes", "stars", "hearts"]

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    /// Builds picture-frame primitives inside `canvas` (photocraft `picture_frame`).
    public static func pictureFrame(_ spec: FrameSpec, canvas: PixelRect) -> [Prim] {
        typealias K = RenderProcKit
        var out: [Prim] = []
        let short = Float.maximum(Float(min(canvas.width, canvas.height)), 8)
        let margin = short * clampf(spec.margin, 0, 30) / 100
        let unit = short * (0.008 + clampf(spec.size, 1, 100) / 100 * 0.05)
        let thick = Float.maximum(unit * 0.04 + short * 0.00012 * clampf(spec.thickness, 1, 100), 0.6)
        let spacing = unit * (4 - 3.2 * clampf(spec.arrangement, 1, 100) / 100)
        let inset = margin + unit
        let b = K.Border(x0: Float(canvas.x0) + inset, y0: Float(canvas.y0) + inset,
                         w: Float.maximum(Float(canvas.width) - 2 * inset, 1), h: Float.maximum(Float(canvas.height) - 2 * inset, 1))
        let total = b.len
        let count = PCAMath.usize(Float.maximum((total / spacing).rounded(.toNearestOrAwayFromZero), 4))
        let step = total / Float(count)
        var rng = Rng(seed: spec.seed, salt: 0xF8A3E &+ UInt64(spec.frame))
        let (vine, fl, lf) = (spec.vineColor, spec.flowerColor, spec.leafColor)
        let style = frameStyles[Int(min(max(spec.frame, 1), UInt32(frameStyles.count))) - 1]
        let lines = Int(min(max(spec.lines, 1), 5))
        let white = SIMD4<Float>(1, 1, 1, 1)
        let yellow = SIMD4<Float>(0.98, 0.82, 0.2, 1)
        // A wavy vine along the border.
        func vinePath(_ amp: Float, _ wl: Float, _ col: SIMD4<Float>, _ r: Float) {
            let n = PCAMath.usize(Float.maximum((total / 3).rounded(.up), 8))
            var prev: SIMD2<Float>?
            for k in 0...n {
                let s = Float(k) / Float(n) * total
                let (p, _, nn) = b.at(s)
                let o = amp * sinf(s / wl * PCAMath.tau)
                let q = SIMD2(p.x + nn.x * o, p.y + nn.y * o)
                if let pp = prev { out.append(.capsule(pp, q, r, r, col, col)) }
                prev = q
            }
        }
        func waveOff(_ s: Float, _ amp: Float, _ wl: Float) -> Float { amp * sinf(s / wl * PCAMath.tau) }
        switch style {
        case "vineWithFlowers", "vineWithLeaves", "ivy", "roses", "daisies", "berries":
            let amp = unit * 0.5
            let wl = step * 2
            vinePath(amp, wl, vine, thick)
            for k in 0..<count {
                let s = Float(k) * step + step * 0.5
                let (p, t, nn) = b.at(s)
                let o = waveOff(s, amp, wl)
                let q = SIMD2(p.x + nn.x * o, p.y + nn.y * o)
                let side: Float = k % 2 == 0 ? 1 : -1
                let ta = atan2f(t.y, t.x)
                let la = ta + side * 0.9 + rng.sym() * 0.3
                let ll = unit * rng.range(0.9, 1.2)
                switch style {
                case "vineWithFlowers":
                    K.leaf(&out, q, la, ll, lf)
                    if k % 2 == 0 {
                        let c = SIMD2(q.x + nn.x * unit * 0.7 * side, q.y + nn.y * unit * 0.7 * side)
                        K.flower(&out, c, unit * 0.65, 5, fl, yellow, rng.f() * 6.3)
                    }
                case "vineWithLeaves":
                    K.leaf(&out, q, la, ll, lf)
                    K.leaf(&out, q, ta - side * 0.9, ll * 0.8, lf)
                case "ivy":
                    for j in 0..<3 {
                        let a = la + (Float(j) - 1) * 0.7
                        K.leaf(&out, q, a, ll * 0.75, K.shade(K.rgb(lf), 0.75 + 0.15 * Float(j)))
                    }
                case "roses":
                    K.leaf(&out, q, la, ll, lf)
                    if k % 3 == 0 {
                        let r = unit * 0.7
                        for (j, f) in ([1, 0.75, 0.5, 0.28] as [Float]).enumerated() {
                            let c = K.shade(K.rgb(fl), 0.75 + 0.1 * Float(j))
                            out.append(.ellipse(q, r * f, r * f * 0.9, rng.f() * 3, c, K.shade(K.rgb(fl), 0.55)))
                        }
                    }
                case "daisies":
                    K.leaf(&out, q, la, ll * 0.8, lf)
                    if k % 2 == 1 { K.flower(&out, q, unit * 0.6, 12, white, yellow, rng.f()) }
                default:
                    K.leaf(&out, q, la, ll, lf)
                    for _ in 0..<3 {
                        let cx = q.x + rng.sym() * unit * 0.4
                        let cy = q.y + rng.sym() * unit * 0.4
                        out.append(.ellipse(SIMD2(cx, cy), unit * 0.2, unit * 0.2, 0, K.shade(K.rgb(fl), 1.2), K.shade(K.rgb(fl), 0.6)))
                    }
                }
            }
        case "bamboo":
            for edge in 0..<4 {
                let (s0, l): (Float, Float) = switch edge { case 0: (0, b.w); case 1: (b.w, b.h); case 2: (b.w + b.h, b.w); default: (2 * b.w + b.h, b.h) }
                let a = b.at(s0 + 0.01).0
                let z = b.at(s0 + l - 0.01).0
                let joints = PCAMath.usize(Float.maximum((l / (spacing * 2)).rounded(.toNearestOrAwayFromZero), 1))
                for j in 0..<joints {
                    let f0 = Float(j) / Float(joints), f1 = Float(j + 1) / Float(joints)
                    let p0 = SIMD2(a.x + (z.x - a.x) * f0, a.y + (z.y - a.y) * f0)
                    let p1 = SIMD2(a.x + (z.x - a.x) * f1, a.y + (z.y - a.y) * f1)
                    out.append(.capsule(p0, p1, unit * 0.35, unit * 0.35, vine, K.shade(K.rgb(vine), 0.8)))
                    out.append(.disc(p1, unit * 0.4, K.shade(K.rgb(vine), 0.7)))
                }
                // A few leaves per edge.
                for _ in 0..<max(joints / 2, 1) {
                    let f = rng.f()
                    let p = SIMD2(a.x + (z.x - a.x) * f, a.y + (z.y - a.y) * f)
                    K.leaf(&out, p, rng.f() * 6.3, unit * 1.4, lf)
                }
            }
        case "waves", "zigzag", "doubleLine", "rope":
            for li in 0..<lines {
                let off = (Float(li) - Float(lines - 1) / 2) * thick * 4
                let n = PCAMath.usize(Float.maximum((total / 2).rounded(.up), 8))
                var prev: SIMD2<Float>?
                for k in 0...n {
                    let s = Float(k) / Float(n) * total
                    let (p, _, nn) = b.at(s)
                    let w: Float
                    switch style {
                    case "waves": w = waveOff(s + Float(li) * step * 0.25, unit * 0.4, step)
                    case "zigzag":
                        let ph = K.fract(s / step)
                        w = unit * 0.4 * (4 * abs(ph - 0.5) - 1)
                    default: w = 0
                    }
                    let o = off + w
                    let q = SIMD2(p.x + nn.x * o, p.y + nn.y * o)
                    if style == "rope" {
                        if k % 2 == 0 {
                            let t = b.at(s).1
                            out.append(.ellipse(q, unit * 0.45, unit * 0.2, atan2f(t.y, t.x) + 0.7, K.shade(K.rgb(vine), 1.1), K.shade(K.rgb(vine), 0.65)))
                        }
                    } else if let pp = prev {
                        out.append(.capsule(pp, q, thick, thick, vine, vine))
                    }
                    prev = q
                }
                if style == "doubleLine" {
                    // A second rule inside each line and corner squares.
                    let inner = K.Border(x0: b.x0 + unit * 0.6 + off, y0: b.y0 + unit * 0.6 + off,
                                         w: b.w - 2 * (unit * 0.6 + off), h: b.h - 2 * (unit * 0.6 + off))
                    let starts = [0, inner.w, inner.w + inner.h, 2 * inner.w + inner.h]
                    let ends = [inner.w, inner.w + inner.h, 2 * inner.w + inner.h, inner.len - 0.001]
                    for e in 0..<4 {
                        out.append(.capsule(inner.at(starts[e]).0, inner.at(ends[e]).0, thick * 0.6, thick * 0.6, vine, vine))
                    }
                }
            }
            if style == "doubleLine" {
                for s in [0, b.w, b.w + b.h, 2 * b.w + b.h] {
                    out.append(.ellipse(b.at(s).0, unit * 0.45, unit * 0.45, K.fracPi4, fl, fl))
                }
            }
        case "dots", "scallops", "snowflakes", "stars", "hearts":
            for k in 0..<count {
                let s = Float(k) * step
                let (p, t, nn) = b.at(s)
                let ta = atan2f(t.y, t.x)
                switch style {
                case "dots":
                    let r = unit * (k % 2 == 0 ? 0.4 : 0.22)
                    out.append(.ellipse(p, r, r, 0, K.shade(K.rgb(fl), 1.15), K.shade(K.rgb(fl), 0.75)))
                case "scallops":
                    let c0 = b.at(s - step * 0.5).0
                    let mid = SIMD2((c0.x + p.x) / 2, (c0.y + p.y) / 2)
                    let n = 8
                    let r = step * 0.5
                    func pt(_ a: Float) -> SIMD2<Float> {
                        SIMD2(mid.x - t.x * r * cosf(a) - nn.x * r * sinf(a), mid.y - t.y * r * cosf(a) - nn.y * r * sinf(a))
                    }
                    for j in 0..<n {
                        let a0 = PCAMath.pi * Float(j) / Float(n)
                        let a1 = PCAMath.pi * Float(j + 1) / Float(n)
                        out.append(.capsule(pt(a0), pt(a1), thick, thick, vine, vine))
                    }
                case "snowflakes":
                    let r = unit * 0.6
                    let c = SIMD4<Float>(0.85, 0.92, 1, 1)
                    for j in 0..<6 {
                        let a = ta + Float(j) * K.fracPi3
                        let e = SIMD2(p.x + cosf(a) * r, p.y + sinf(a) * r)
                        out.append(.capsule(p, e, Float.maximum(thick * 0.6, 0.6), Float.maximum(thick * 0.4, 0.5), c, c))
                        let m = SIMD2(p.x + cosf(a) * r * 0.6, p.y + sinf(a) * r * 0.6)
                        for sd: Float in [-0.7, 0.7] {
                            let b2 = SIMD2(m.x + cosf(a + sd) * r * 0.3, m.y + sinf(a + sd) * r * 0.3)
                            out.append(.capsule(m, b2, Float.maximum(thick * 0.4, 0.5), 0.4, c, c))
                        }
                    }
                case "stars":
                    K.star(&out, p, unit * 0.55, 5, k % 2 == 0 ? yellow : fl, ta - K.fracPi2)
                default:
                    // Heart: two lobes and a point towards the inside.
                    let r = unit * 0.3
                    let (tx, ty) = (t.x, t.y)
                    let l = SIMD2(p.x - tx * r * 0.8 - nn.x * r * 0.3, p.y - ty * r * 0.8 - nn.y * r * 0.3)
                    let rr = SIMD2(p.x + tx * r * 0.8 - nn.x * r * 0.3, p.y + ty * r * 0.8 - nn.y * r * 0.3)
                    let tip = SIMD2(p.x + nn.x * r * 1.6, p.y + nn.y * r * 1.6)
                    out.append(.capsule(l, tip, r, 0.6, fl, fl))
                    out.append(.capsule(rr, tip, r, 0.6, fl, fl))
                }
            }
        default: break
        }
        // Fade: lower the opacity of ornaments that reach further inside.
        let fade = clampf(spec.fade, 0, 100) / 100
        if fade > 0 {
            let cx = Float(canvas.x0) + Float(canvas.width) / 2
            let cy = Float(canvas.y0) + Float(canvas.height) / 2
            for i in out.indices {
                let c: SIMD2<Float>
                switch out[i].shape {
                case .capsule(let a, _, _, _): c = a
                case .ellipse(let cc, _, _, _): c = cc
                }
                let edge = clampf(Float.maximum(abs(c.x - cx) / (b.w / 2), abs(c.y - cy) / (b.h / 2)), 0, 1)
                let k = 1 - fade * (1 - edge) * 8
                out[i].c0.w *= clampf(k, 0, 1)
                out[i].c1.w *= clampf(k, 0, 1)
            }
        }
        return out
    }
}
