// Port of photocraft-algo (crates/algo/src/resample.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Image Size's interpolation methods: the per-axis filters (nearest, bilinear with whole-pixel
// averaging below ½, Photoshop's Keys bicubics with their stretch and reduction rules, Lanczos-3),
// the pass plan (which axis first, Bicubic Automatic's split), and the per-output-sample tap tables
// (source window, f32 weights with the taps beyond the edge folded onto it, and the weight of taps
// outside the content, which read the default pixel). All weight maths is f64, as in photocraft;
// the tables are what both the CPU passes and the Metal kernels consume.

import Foundation
import PCFoundation

/// Resampling method (Photoshop's Image Size options, and Lanczos) — photocraft `Resample`.
public enum Resample: String, Codable, Sendable, Hashable, CaseIterable {
    case nearest
    case bilinear
    /// Photoshop's Bicubic (the Keys cubic, a = −0.75). photocraft's default.
    case bicubic
    /// Photoshop's Bicubic Smoother, for enlargement.
    case bicubicSmoother
    /// Photoshop's Bicubic Sharper, for reduction.
    case bicubicSharper
    /// Photoshop's Bicubic Automatic: Smoother where the image grows, Sharper where it shrinks.
    case bicubicAutomatic
    case lanczos
    /// Lanczos followed by a light sharpening when enlarging; Bicubic Sharper when reducing, as
    /// Photoshop's Preserve Details reduces.
    case preserveDetails

    /// photocraft's `#[default]`.
    public static let `default` = Resample.bicubic
}

/// Internal machinery of the resampling area (photocraft `resample.rs` private items).
enum ResampleKit {
    /// Sub-pixel positions Photoshop's filters resolve: a sample's offset is rounded to 1/128 pixel.
    static let phases: Double = 128

    /// The filter of one axis.
    enum Kernel: Hashable, Codable, Sendable {
        case nearest
        /// Linear interpolation, never widened. Below half size, each output pixel is the plain
        /// average of the source pixels it covers.
        case bilinear
        /// The Keys cubic with parameter `a`, stretched over `stretch` source pixels.
        case keys(a: Double, stretch: Double)
        /// Lanczos-3, widened by 1/scale when reducing.
        case lanczos
    }

    /// One resampling pass: scale factors and the filter of each axis.
    struct Pass: Hashable, Codable, Sendable {
        var sx: Double
        var sy: Double
        var kx: Kernel
        var ky: Kernel
    }

    /// Per-output-sample source window and normalised weights.
    struct Taps: Hashable, Codable, Sendable {
        var start: Int32
        var weights: [Float]
        /// Total weight of taps outside the source's content, which all read the default pixel.
        var outside: Float
    }

    /// Floor division (photocraft `div_euclid` for a positive divisor).
    @inline(__always)
    static func floorDiv(_ a: Int32, _ b: Int32) -> Int32 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// Rust's saturating `f64 as i32` (NaN → 0, truncation toward zero).
    @inline(__always)
    static func i32(_ d: Double) -> Int32 {
        if d.isNaN { return 0 }
        if d >= 2_147_483_647 { return .max }
        if d <= -2_147_483_648 { return .min }
        return Int32(d)
    }

    /// Photoshop's bicubic filters, measured on Photoshop 25.4 (the Keys cubic, phase table and
    /// stretch fitted to within 1/4000 of every weight). `s` is the scale the filter is designed for.
    ///
    /// - Bicubic: a = −0.75.
    /// - Bicubic Smoother: stretched by 1.15; a = −0.625, and −0.625 − 0.5·(1 − s) when reducing.
    /// - Bicubic Sharper: stretched by 1.05; a = −1, and −1 − 1.6·(1 − s) when reducing.
    ///
    /// Reducing widens the filter by 1/s, down to ¼; below that `taps` first averages the image
    /// down to four times the target.
    static func keys(_ method: Resample, _ s0: Double) -> Kernel {
        let s = min(max(s0, 0.25), 1.0)
        let a: Double, stretch: Double
        switch method {
        case .bicubicSmoother: (a, stretch) = (-0.625 - 0.5 * (1.0 - s), 1.15)
        case .bicubicSharper: (a, stretch) = (-1.0 - 1.6 * (1.0 - s), 1.05)
        default: (a, stretch) = (-0.75, 1.0)
        }
        return .keys(a: a, stretch: stretch / s)
    }

    static func keysWeight(_ x0: Double, _ a: Double) -> Double {
        let x = abs(x0)
        if x < 1.0 {
            return (a + 2.0) * x * x * x - (a + 3.0) * x * x + 1.0
        } else if x < 2.0 {
            return a * (x * x * x - 5.0 * x * x + 8.0 * x - 4.0)
        }
        return 0.0
    }

    static func lanczosWeight(_ x0: Double) -> Double {
        let x = abs(x0)
        if x < 1e-9 { return 1.0 }
        if x < 3.0 {
            let px = Double.pi * x
            return 3.0 * sin(px) * sin(px / 3.0) / (px * px)
        }
        return 0.0
    }

    /// Photoshop's passes for `filter` at `(sx, sy)`.
    ///
    /// A bicubic filter is designed for the height's scale, or the width's when the height stays,
    /// and serves both axes; the axis with the smaller scale goes first, and the image is clipped and
    /// stored between the passes. Bicubic Automatic with one axis growing and the other shrinking is
    /// two Image Sizes: the shrinking axis with Sharper, then the growing one with Smoother, each
    /// designed for its own scale. Nearest, Bilinear and Lanczos run both axes in one pass.
    static func plan(_ filter: Resample, _ sx: Double, _ sy: Double) -> [Pass] {
        func both(_ k: Kernel) -> [Pass] { [Pass(sx: sx, sy: sy, kx: k, ky: k)] }
        switch filter {
        case .nearest: return both(.nearest)
        case .bilinear: return both(.bilinear)
        case .lanczos: return both(.lanczos)
        case .preserveDetails:
            return sx > 1.0 || sy > 1.0 ? both(.lanczos) : plan(.bicubicSharper, sx, sy)
        case .bicubicAutomatic:
            if sx <= 1.0 && sy <= 1.0 { return plan(.bicubicSharper, sx, sy) }
            if sx >= 1.0 && sy >= 1.0 { return plan(.bicubicSmoother, sx, sy) }
            if sx < 1.0 {
                return [Pass(sx: sx, sy: 1.0, kx: keys(.bicubicSharper, sx), ky: .nearest),
                        Pass(sx: 1.0, sy: sy, kx: .nearest, ky: keys(.bicubicSmoother, sy))]
            }
            return [Pass(sx: 1.0, sy: sy, kx: .nearest, ky: keys(.bicubicSharper, sy)),
                    Pass(sx: sx, sy: 1.0, kx: keys(.bicubicSmoother, sx), ky: .nearest)]
        case .bicubic, .bicubicSmoother, .bicubicSharper:
            let k = keys(filter, sy != 1.0 ? sy : sx)
            if sx == 1.0 || sy == 1.0 { return both(k) }
            if sy < sx {
                return [Pass(sx: 1.0, sy: sy, kx: k, ky: k), Pass(sx: sx, sy: 1.0, kx: k, ky: k)]
            }
            return [Pass(sx: sx, sy: 1.0, kx: k, ky: k), Pass(sx: 1.0, sy: sy, kx: k, ky: k)]
        }
    }

    /// The source position of output sample `o`, `(o + 0.5) / scale − 0.5`, kept on the edge
    /// samples (`[first, last]`) when there is an edge, and rounded to Photoshop's 1/128 pixel.
    static func position(_ o: Int32, _ scale: Double, _ edge: (Int32, Int32)?) -> Double {
        var u = (Double(o) + 0.5) / scale - 0.5
        if let (a, b) = edge { u = min(max(u, Double(a)), Double(max(b, a))) }
        let j = u.rounded(.down)
        return j + ((u - j) * phases).rounded() / phases
    }

    /// The source pixels `[floor(o / scale), floor((o + 1) / scale))` output pixel `o` covers.
    static func cover(_ o: Int32, _ scale: Double) -> (Int32, Int32) {
        let a = i32((Double(o) / scale + 1e-9).rounded(.down))
        return (a, i32(max((Double(o + 1) / scale + 1e-9).rounded(.down), Double(a) + 1.0)))
    }

    /// Unclamped weights of output sample `o` over source samples `lo ..< lo + len`.
    static func weights(_ o: Int32, _ scale: Double, _ kernel: Kernel, _ edge: (Int32, Int32)?) -> (Int32, [Double]) {
        switch kernel {
        case .nearest:
            let u = (Double(o) + 0.5) / scale - 0.5
            return (i32((u + 0.5).rounded(.down)), [1.0])
        case .bilinear where scale < 0.5:
            let (a, b) = cover(o, scale)
            return (a, [Double](repeating: 1.0 / Double(b - a), count: Int(b - a)))
        case .bilinear:
            let u = position(o, scale, edge)
            let j = u.rounded(.down)
            return (i32(j), [1.0 - (u - j), u - j])
        case .keys(let a, let stretch) where scale < 0.25:
            // Averaged down to four times the target first (pixels of `inner`), then filtered.
            let inner = 4.0 * scale
            let innerEdge: (Int32, Int32)? = edge.map { (ea, eb) in
                (i32((Double(ea) * inner - 1e-9).rounded(.up)), i32((Double(eb + 1) * inner - 1e-9).rounded(.up)) - 1)
            }
            let (k0, kw) = weights(o, 0.25, .keys(a: a, stretch: stretch), innerEdge)
            func clampK(_ k: Int32) -> Int32 {
                guard let (ea, eb) = innerEdge else { return k }
                return min(max(k, ea), max(eb, ea))
            }
            let boxes: [(Int32, Int32)] = kw.indices.map { cover(clampK(k0 + Int32($0)), inner) }
            let lo = boxes.map(\.0).min() ?? 0
            let hi = boxes.map(\.1).max() ?? lo
            var w = [Double](repeating: 0, count: Int(max(hi - lo, 0)))
            for ((ba, bb), v) in zip(boxes, kw) {
                let i0 = Int(ba - lo), i1 = Int(bb - lo)
                if i0 < 0 || i1 > w.count || i0 > i1 { continue }
                for slot in i0..<i1 { w[slot] += v / Double(bb - ba) }
            }
            return (lo, w)
        case .keys(let a, let stretch):
            let u = position(o, scale, edge)
            let lo = i32((u - 2.0 * stretch).rounded(.down))
            let hi = i32((u + 2.0 * stretch).rounded(.up))
            var w: [Double] = []
            if hi >= lo {
                w.reserveCapacity(Int(hi - lo) + 1)
                for i in lo...hi { w.append(keysWeight((u - Double(i)) / stretch, a)) }
            }
            var sum = 0.0
            for v in w { sum += v }
            return (lo, w.map { $0 / sum })
        case .lanczos:
            let stretch = scale < 1.0 ? 1.0 / scale : 1.0
            var u = (Double(o) + 0.5) / scale - 0.5
            if let (ea, eb) = edge { u = min(max(u, Double(ea)), Double(max(eb, ea))) }
            let lo = i32((u - 3.0 * stretch).rounded(.up))
            let hi = i32((u + 3.0 * stretch).rounded(.down))
            var w: [Double] = []
            if hi >= lo {
                w.reserveCapacity(Int(hi - lo) + 1)
                for i in lo...hi { w.append(lanczosWeight((Double(i) - u) / stretch)) }
            }
            var sum = 0.0
            for v in w { sum += v }
            let k = abs(sum) > 1e-12 ? 1.0 / sum : 1.0
            return (lo, w.map { $0 * k })
        }
    }

    /// Taps for mapping output coordinate `o` (in `[dst0, dst1)`) to the source at `scale`
    /// (a scale of 1 copies). With `edge` (`[first, last]` source index), taps outside it read the
    /// nearest sample inside it: the image repeats its edge instead of fading out.
    /// Taps outside `content` (`[first, last]`) all read the default pixel, so they are folded into
    /// `outside` instead of being read: the read window never grows past the content, however small
    /// the scale (photocraft #713).
    static func taps(_ dst0: Int32, _ dst1: Int32, _ scale: Double, _ kernel0: Kernel, _ edge: (Int32, Int32)?,
                     _ content: (Int32, Int32)) -> [Taps] {
        @inline(__always) func clampE(_ i: Int32) -> Int32 {
            guard let (a, b) = edge else { return i }
            return min(max(i, a), b)
        }
        let kernel: Kernel = scale == 1.0 ? .nearest : kernel0
        if dst1 <= dst0 { return [] }
        var out = [Taps](repeating: Taps(start: 0, weights: [], outside: 0), count: Int(dst1 - dst0))
        out.withUnsafeMutableBufferPointer { ob in
            let o = UnsafeSendable(ob)
            parallelChunks(Int(dst1 - dst0), minChunk: 256) { range in
                for i in range {
                    o.value[i] = oneTap(dst0 + Int32(i), scale, kernel, edge, content, clampE)
                }
            }
        }
        return out
    }

    @inline(__always)
    private static func oneTap(_ o: Int32, _ scale: Double, _ kernel: Kernel, _ edge: (Int32, Int32)?, _ content: (Int32, Int32),
                               _ clampE: (Int32) -> Int32) -> Taps {
        let (lo, w) = weights(o, scale, kernel, edge)
        let hi = lo + Int32(w.count) - 1
        // Fold the weights of taps beyond the edge onto the edge sample.
        let start = clampE(lo)
        var folded = [Float](repeating: 0, count: Int(max(clampE(hi) - start + 1, 1)))
        for (k, v) in w.enumerated() {
            let idx = Int(clampE(lo + Int32(k)) - start)
            if idx >= 0 && idx < folded.count { folded[idx] += Float(v) }
        }
        // Keep the part inside the content; the rest reads the default pixel.
        let a = max(start, content.0), b = min(start + Int32(folded.count) - 1, content.1)
        if a > b {
            var s: Float = 0
            for v in folded { s += v }
            return Taps(start: content.0, weights: [], outside: s)
        }
        let i0 = Int(a - start), i1 = Int(b - start) + 1
        var outside: Float = 0
        for v in folded[..<i0] { outside += v }
        for v in folded[i1...] { outside += v }
        return Taps(start: a, weights: Array(folded[i0..<i1]), outside: outside)
    }

    /// The premultiplied default pixel (photocraft `premultiply(&mut def, n, alpha)`).
    static func premultiplied(_ px: [Float], alpha: Bool) -> [Float] {
        var v = px
        if alpha, let a = v.last { for c in 0..<(v.count - 1) { v[c] *= a } }
        return v
    }

    /// A sample stored in `sample` and read back (integer types clip and round, as a surface write
    /// does; floats are kept).
    @inline(__always)
    static func quantize(_ v: Float, _ sample: SampleType) -> Float {
        switch sample {
        case .u8: return Float(UInt8(min(max(v, 0), 1) * 255 + 0.5)) / 255
        case .u16: return Float(UInt16(min(max(v, 0), 1) * 65535 + 0.5)) / 65535
        case .f32: return v
        }
    }
}

extension Resample {
    /// Output rectangle for `r` scaled by `(sx, sy)` about the origin (photocraft `scaled_rect`).
    public static func scaledRect(_ r: PixelRect, sx: Double, sy: Double) -> PixelRect {
        if r.isEmpty { return .empty }
        return PixelRect(x0: ResampleKit.i32((Double(r.x0) * sx).rounded(.down)), y0: ResampleKit.i32((Double(r.y0) * sy).rounded(.down)),
                         x1: ResampleKit.i32((Double(r.x1) * sx).rounded(.up)), y1: ResampleKit.i32((Double(r.y1) * sy).rounded(.up)))
    }
}
