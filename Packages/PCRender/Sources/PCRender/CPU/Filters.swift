// Filter adjustment layers (AB-T-0258): the CPU reference of Grain, Add Noise, Gaussian Blur and
// Motion Blur. New; no photocraft counterpart. Grain's and Add Noise's patterns are Compositor's
// (EditorPixelKernels' AdjustPixels.c `adjust_grain` and NoisePixels.c `noise_add_at`: the same
// hashes, lattice and Box–Muller, in Float so the Metal kernels in PCR8Filters.metal repeat them);
// its blurs are Core Image's as Compositor draws them (`CIGaussianBlur` with sigma = radius,
// `CIMotionBlur` with radius = distance / √12, measured here as a Gaussian of that sigma along the
// line), on premultiplied colour with nothing past the canvas, so a blur thins at the canvas edge
// as Compositor's does. Compositor is MIT, © 2026 Wonder Assembly LLC.
//
// Patterns are fixed in document space: Grain's field is evaluated at each pixel's centre in
// document pixels, Add Noise hashes each document pixel's coordinates with the seed, so tiles, cells
// and bands of a render agree. At a level of detail (`FilterSpec.scale` < 1) Grain reads its field at
// the level pixel's centre, and Add Noise hashes level pixels with a seed of the level and scales
// its spread by `scale` (a level pixel averages 1/scale² independent document pixels).

import Foundation
import PCDocument
import PCFoundation
import simd

/// The filters' arithmetic, shared by the CPU reference and the Metal encoding.
enum FilterMath {
    // MARK: Hashes (Compositor's `mix32` / `noise_hash`)

    @inline(__always) static func mix32(_ v: UInt32) -> UInt32 {
        var x = v
        x ^= x >> 16; x = x &* 0x7feb_352d
        x ^= x >> 15; x = x &* 0x846c_a68b
        x ^= x >> 16
        return x
    }

    /// Uniform in [0, 1).
    @inline(__always) static func unit(_ key: UInt32) -> Float { Float(mix32(key) >> 8) * (1 / 16_777_216) }

    // MARK: Grain

    /// What a Grain kernel needs.
    struct Grain {
        var strength: Float
        var roughness: Float
        var size: Float
        var detailSize: Float
        /// Document pixels per plan pixel.
        var unitsPerPixel: Float
        var seed: UInt32
        var fineSeed: UInt32

        init(_ g: FilterAdjustment.Grain, scale: Float) {
            strength = min(g.amount, 100) / 100 * 0.35 * 255
            roughness = min(max(g.roughness, 0), 100) / 100
            size = g.size
            detailSize = max(0.5, g.size * 0.35)
            unitsPerPixel = 1 / max(scale, 1e-6)
            seed = g.seed
            fineSeed = FilterMath.mix32(g.seed ^ 0xa511_e9b3)
        }
    }

    /// A value in −1…1 for an integer lattice point, fixed by the point and the seed (two uniform
    /// halves summed: a triangular spread).
    @inline(__always) static func lattice(_ ix: Int32, _ iy: Int32, _ seed: UInt32) -> Float {
        let h = mix32(UInt32(bitPattern: ix) &* 0x9e37_79b1 ^ mix32(UInt32(bitPattern: iy) &* 0x85eb_ca77 ^ seed))
        return Float(h & 0xffff) / 65535 + Float(h >> 16) / 65535 - 1
    }

    /// Smooth seeded noise with features `scale` document pixels across.
    @inline(__always) static func grainField(_ u: Float, _ v: Float, _ scale: Float, _ seed: UInt32) -> Float {
        let su = u / scale, sv = v / scale
        let cellX = su.rounded(.down), cellY = sv.rounded(.down)
        var tx = su - cellX, ty = sv - cellY
        tx = tx * tx * (3 - 2 * tx)
        ty = ty * ty * (3 - 2 * ty)
        let ix = Int32(clamping: Int64(cellX)), iy = Int32(clamping: Int64(cellY))
        let n00 = lattice(ix, iy, seed), n10 = lattice(ix &+ 1, iy, seed)
        let n01 = lattice(ix, iy &+ 1, seed), n11 = lattice(ix &+ 1, iy &+ 1, seed)
        let top = n00 + (n10 - n00) * tx, bottom = n01 + (n11 - n01) * tx
        return (top + (bottom - top) * ty) * 1.6
    }

    /// Grain on straight colour `c` (0…1 encoded; 32-bit documents unclipped above) at plan pixel
    /// (x, y).
    @inline(__always) static func grain(_ c: SIMD3<Float>, _ x: Int32, _ y: Int32, _ g: Grain, hdr: Bool) -> SIMD3<Float> {
        let u = (Float(x) + 0.5) * g.unitsPerPixel, v = (Float(y) + 0.5) * g.unitsPerPixel
        let smooth = grainField(u, v, g.size, g.seed)
        let fine = grainField(u, v, g.detailSize, g.fineSeed)
        let noise = smooth + (fine - smooth) * g.roughness
        let r = c.x * 255, gg = c.y * 255, b = c.z * 255
        var level = (0.2126 * r + 0.7152 * gg + 0.0722 * b) / 255
        if level > 1 { level = 1 }
        if level < 0 { level = 0 }
        let delta = noise * g.strength * (0.4 + 2.4 * level * (1 - level))
        return SIMD3(clamp255(r + delta, hdr), clamp255(gg + delta, hdr), clamp255(b + delta, hdr)) / 255
    }

    @inline(__always) static func clamp255(_ v: Float, _ hdr: Bool) -> Float { v < 0 ? 0 : (!hdr && v > 255) ? 255 : v }

    // MARK: Add Noise

    struct Noise {
        var spread: Float
        var gaussian: Bool
        var monochromatic: Bool
        var seed: UInt32

        init(_ n: FilterAdjustment.AddNoise, scale: Float) {
            spread = n.amount / 100 * 127.5 * (scale < 1 ? scale : 1)
            gaussian = n.gaussian
            monochromatic = n.monochromatic
            // A level of detail hashes its own pixels: a pattern of its own per level.
            seed = scale == 1 ? n.seed : FilterMath.mix32(n.seed ^ scale.bitPattern)
        }
    }

    /// Add Noise on straight colour `c` at plan pixel (x, y).
    @inline(__always) static func noise(_ c: SIMD3<Float>, _ x: Int32, _ y: Int32, _ n: Noise, hdr: Bool) -> SIMD3<Float> {
        let px = UInt32(bitPattern: x), py = UInt32(bitPattern: y)
        let base = mix32(n.seed ^ mix32(px &* 0x9e37_79b9 ^ mix32(py &* 0x85eb_ca6b)))
        var out = SIMD3<Float>.zero
        for ch in 0..<3 {
            let key = n.monochromatic ? base : base &+ UInt32(ch) &* 0x9e37_79b9
            let d: Float
            if n.gaussian {
                // Box–Muller: two uniform values make one normally distributed one.
                let u1 = unit(key), u2 = unit(key ^ 0x68e3_1da4)
                d = (-2 * logf(1 - u1)).squareRoot() * cosf(6.2831853 * u2) * n.spread * (2.0 / 3.0)
            } else {
                d = (unit(key) * 2 - 1) * n.spread
            }
            out[ch] = clamp255(c[ch] * 255 + d, hdr) / 255
        }
        return out
    }

    // MARK: Blurs

    /// Normalised Gaussian weights of standard deviation `sigma` over −R…R, R = ⌈3σ⌉ (at least 1):
    /// Core Image's extent for `CIGaussianBlur`.
    static func gaussianWeights(sigma: Float) -> [Float] {
        let s = max(sigma, 1e-3)
        let r = gaussianRadius(sigma: s)
        var w = [Float](repeating: 0, count: 2 * r + 1)
        var sum: Float = 0
        for k in -r...r {
            let v = expf(-Float(k * k) / (2 * s * s))
            w[k + r] = v
            sum += v
        }
        for i in w.indices { w[i] /= sum }
        return w
    }

    /// R of `gaussianWeights(sigma:)`: ⌈3σ⌉, at least 1.
    static func gaussianRadius(sigma: Float) -> Int { max(1, Int((3 * max(sigma, 1e-3)).rounded(.up))) }

    /// Motion Blur's sigma along its line, in plan pixels: an even streak `distance` long has the
    /// spread distance / √12, and `CIMotionBlur` (Compositor's radius = distance / √12) is a Gaussian
    /// of that sigma along the line.
    static func motionSigma(_ m: FilterAdjustment.MotionBlur, scale: Float) -> Float { m.distance * scale / Float(12).squareRoot() }

    /// The streak's unit step in plan pixels: counterclockwise from horizontal on screen (y down).
    static func motionDirection(_ m: FilterAdjustment.MotionBlur) -> SIMD2<Float> {
        let a = m.angle * .pi / 180
        var d = SIMD2(cosf(a), -sinf(a))
        if abs(d.x) < 1e-6 { d.x = 0 }
        if abs(d.y) < 1e-6 { d.y = 0 }
        return d
    }

    /// One tap of Motion Blur's streak: its weight, and the step along the line as whole pixels and
    /// fractions. The same for every pixel, so where a render starts never changes a sample.
    struct MotionTap {
        var weight: Float
        var dx: Int32, dy: Int32
        var fx: Float, fy: Float
    }

    /// Motion Blur's taps: Gaussian weights at whole steps of the direction either side of a pixel.
    static func motionTaps(_ m: FilterAdjustment.MotionBlur, scale: Float) -> [MotionTap] {
        let w = gaussianWeights(sigma: motionSigma(m, scale: scale))
        let r = (w.count - 1) / 2, d = motionDirection(m)
        return w.indices.map { k in
            let t = Float(k - r)
            let ox = t * d.x, oy = t * d.y
            let x0 = ox.rounded(.down), y0 = oy.rounded(.down)
            return MotionTap(weight: w[k], dx: Int32(x0), dy: Int32(y0), fx: ox - x0, fy: oy - y0)
        }
    }

    /// How far past a pixel a filter reads its backdrop, in plan pixels (0: each pixel alone).
    static func reach(_ spec: FilterSpec) -> Int32 {
        switch spec.filter {
        case .grain, .addNoise: return 0
        case .gaussianBlur(let b): return Int32(gaussianRadius(sigma: b.radius * spec.scale))
        case .motionBlur(let m):
            // Bilinear taps reach one pixel past the line's end.
            return Int32(gaussianRadius(sigma: motionSigma(m, scale: spec.scale))) + 1
        }
    }

    /// The backdrop a blur of `reach` over `region` reads: the region, plus `reach` around it within
    /// the canvas (past the canvas the backdrop counts as clear).
    static func backdropArea(_ region: PixelRect, reach: Int32, canvas: PixelRect) -> PixelRect {
        let grown = region.inflated(reach).intersect(canvas)
        return grown.isEmpty ? region : region.union(grown)
    }
}

/// The CPU reference of filter adjustments.
enum FilterCPU {
    /// `spec` on `buf` in place: Grain and Add Noise per pixel (transparent pixels untouched); a blur
    /// of the buffer alone, clear past it and past `canvas`.
    static func apply(_ spec: FilterSpec, to buf: inout RGBABuffer, canvas: PixelRect, hdr: Bool, native: NativeSpace) {
        switch spec.filter {
        case .gaussianBlur, .motionBlur:
            buf = blur(spec, backdrop: buf, canvas: canvas, over: buf.rect)
        case .grain(let g):
            let p = FilterMath.Grain(g, scale: spec.scale)
            pointwise(&buf, native) { FilterMath.grain($0, $1, $2, p, hdr: hdr) }
        case .addNoise(let n):
            let p = FilterMath.Noise(n, scale: spec.scale)
            pointwise(&buf, native) { FilterMath.noise($0, $1, $2, p, hdr: hdr) }
        }
    }

    /// `f` on the display colour of every pixel with alpha > 0 (a native Lab buffer converted there
    /// and back, as `PreparedAdjustment` converts).
    static func pointwise(_ buf: inout RGBABuffer, _ native: NativeSpace, _ f: (SIMD3<Float>, Int32, Int32) -> SIMD3<Float>) {
        let rect = buf.rect, w = rect.width
        let lab = native == .lab
        buf.px.withUnsafeMutableBufferPointer { p in
            let pb = UnsafeSendable(p)
            withoutActuallyEscaping(f) { fn in
                let fb = UnsafeSendable(fn)
                parallelRows(rect.height, width: w) { y in
                    for x in 0..<w {
                        let i = y * w + x
                        let q = pb.value[i]
                        if q.w <= 0 { continue }
                        var c = SIMD3(q.x, q.y, q.z)
                        if lab { c = AdjustMath.labDenorm(c) }
                        var r = fb.value(c, rect.x0 + Int32(x), rect.y0 + Int32(y))
                        if lab { r = AdjustMath.labNorm(r) }
                        pb.value[i] = SIMD4(r, q.w)
                    }
                }
            }
        }
    }

    /// A blur of `backdrop` (straight RGBA; clear outside its rect and outside `canvas`) over `out`,
    /// on premultiplied colour, as straight RGBA.
    static func blur(_ spec: FilterSpec, backdrop: RGBABuffer, canvas: PixelRect, over out: PixelRect) -> RGBABuffer {
        if out.isEmpty { return RGBABuffer(transparent: out) }
        let pm = premultiplied(backdrop, canvas: canvas)
        let a = backdrop.rect
        var result: [SIMD4<Float>]
        switch spec.filter {
        case .gaussianBlur(let b):
            result = gaussian(pm, a, sigma: b.radius * spec.scale, out: out)
        case .motionBlur(let m):
            result = motion(pm, a, taps: FilterMath.motionTaps(m, scale: spec.scale), out: out)
        default:
            return backdrop.cropped(to: out)
        }
        unpremultiply(&result)
        return RGBABuffer(rect: out, px: result)
    }

    /// Premultiplied, with pixels outside `canvas` cleared.
    static func premultiplied(_ b: RGBABuffer, canvas: PixelRect) -> [SIMD4<Float>] {
        let r = b.rect, w = r.width
        var out = [SIMD4<Float>](repeating: .zero, count: b.px.count)
        let inside = r.intersect(canvas)
        if inside.isEmpty { return out }
        out.withUnsafeMutableBufferPointer { op in
            let O = UnsafeSendable(op)
            b.px.withUnsafeBufferPointer { bp in
                let B = UnsafeSendable(bp)
                parallelRows(inside.height, width: inside.width) { j in
                    let y = Int(inside.y0 - r.y0) + j
                    for x in Int(inside.x0 - r.x0)..<Int(inside.x1 - r.x0) {
                        let p = B.value[y * w + x]
                        O.value[y * w + x] = SIMD4(p.x * p.w, p.y * p.w, p.z * p.w, p.w)
                    }
                }
            }
        }
        return out
    }

    /// Premultiplied → straight (coverage at most 1).
    static func unpremultiply(_ px: inout [SIMD4<Float>]) {
        px.withUnsafeMutableBufferPointer { p in
            let P = UnsafeSendable(p)
            parallelChunks(p.count, work: p.count) { r in
                for i in r {
                    let v = P.value[i]
                    let a = min(v.w, 1)
                    P.value[i] = a > 0 ? SIMD4(v.x / v.w, v.y / v.w, v.z / v.w, a) : .zero
                }
            }
        }
    }

    /// The separable Gaussian of premultiplied `pm` (over `a`; zero outside) over `out`: rows first
    /// (over `out`'s columns and its rows ± R), then columns, each a weighted sum taken in tap order.
    static func gaussian(_ pm: [SIMD4<Float>], _ a: PixelRect, sigma: Float, out: PixelRect) -> [SIMD4<Float>] {
        let w = FilterMath.gaussianWeights(sigma: sigma)
        let r = (w.count - 1) / 2
        let aw = a.width
        // Rows of the horizontal pass: out's, ± R, where the backdrop has any.
        let hy0 = max(out.y0 - Int32(r), a.y0), hy1 = min(out.y1 + Int32(r), a.y1)
        let hRows = max(0, Int(hy1 - hy0)), ow = out.width
        var h = [SIMD4<Float>](repeating: .zero, count: hRows * ow)
        h.withUnsafeMutableBufferPointer { hp in
            let H = UnsafeSendable(hp)
            pm.withUnsafeBufferPointer { pp in
                let P = UnsafeSendable(pp)
                w.withUnsafeBufferPointer { wp in
                    let W = UnsafeSendable(wp)
                    parallelRows(hRows, width: ow * w.count) { j in
                        let sy = Int(hy0 - a.y0) + j
                        for i in 0..<ow {
                            let x = Int(out.x0) + i
                            var acc = SIMD4<Float>.zero
                            for k in 0..<W.value.count {
                                let sx = x + k - r - Int(a.x0)
                                if sx < 0 || sx >= aw { continue }
                                acc = acc + W.value[k] * P.value[sy * aw + sx]
                            }
                            H.value[j * ow + i] = acc
                        }
                    }
                }
            }
        }
        var o = [SIMD4<Float>](repeating: .zero, count: out.area)
        o.withUnsafeMutableBufferPointer { op in
            let O = UnsafeSendable(op)
            h.withUnsafeBufferPointer { hp in
                let H = UnsafeSendable(hp)
                w.withUnsafeBufferPointer { wp in
                    let W = UnsafeSendable(wp)
                    parallelRows(out.height, width: ow * w.count) { j in
                        let y = Int(out.y0) + j
                        for i in 0..<ow {
                            var acc = SIMD4<Float>.zero
                            for k in 0..<W.value.count {
                                let sy = y + k - r - Int(hy0)
                                if sy < 0 || sy >= hRows { continue }
                                acc = acc + W.value[k] * H.value[sy * ow + i]
                            }
                            O.value[j * ow + i] = acc
                        }
                    }
                }
            }
        }
        return o
    }

    /// The motion streak of premultiplied `pm` (over `a`; zero outside) over `out`: each tap read
    /// bilinearly at its step from the pixel, weighted, in tap order.
    static func motion(_ pm: [SIMD4<Float>], _ a: PixelRect, taps: [FilterMath.MotionTap], out: PixelRect) -> [SIMD4<Float>] {
        let aw = Int32(a.width), ah = Int32(a.height), ow = out.width
        var o = [SIMD4<Float>](repeating: .zero, count: out.area)
        o.withUnsafeMutableBufferPointer { op in
            let O = UnsafeSendable(op)
            pm.withUnsafeBufferPointer { pp in
                let P = UnsafeSendable(pp)
                taps.withUnsafeBufferPointer { tp in
                    let T = UnsafeSendable(tp)
                    @inline(__always) func at(_ x: Int32, _ y: Int32) -> SIMD4<Float> {
                        x < 0 || y < 0 || x >= aw || y >= ah ? .zero : P.value[Int(y) * Int(aw) + Int(x)]
                    }
                    parallelRows(out.height, width: ow * taps.count) { j in
                        let y = out.y0 - a.y0 + Int32(j)
                        for i in 0..<ow {
                            let x = out.x0 - a.x0 + Int32(i)
                            var acc = SIMD4<Float>.zero
                            for t in T.value {
                                let x0 = x + t.dx, y0 = y + t.dy
                                let top = at(x0, y0) * (1 - t.fx) + at(x0 + 1, y0) * t.fx
                                let bottom = at(x0, y0 + 1) * (1 - t.fx) + at(x0 + 1, y0 + 1) * t.fx
                                acc = acc + t.weight * (top * (1 - t.fy) + bottom * t.fy)
                            }
                            O.value[j * ow + i] = acc
                        }
                    }
                }
            }
        }
        return o
    }
}
