// Port of photocraft-algo (crates/algo/src/matting/morphology.rs; matting.rs: running_extreme, max_square, morph), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Exact flat octagonal grey morphology (Select and Mask's Shift Edge): a square of radius ⌈r/2⌉
// (van Herk / Gil–Werman running extremes, three comparisons per sample whatever the radius)
// followed by a Manhattan ball of radius ⌊r/2⌋ built from doubling crosses — the same result as
// r alternating 3×3 square / cross steps. NaN payloads and negative zero keep the step-by-step
// visitation order. Photocraft's tiled and blocked-transpose variants only change memory use and
// give identical values; this port runs the dense form with parallel rows and columns.

import Foundation

extension Matting {
    /// Grey dilation (`grow`) or erosion with the octagonal element of radius `r`. Invalid sizes
    /// return an empty buffer; samples past w × h are kept.
    public static func morph(_ src: [Float], w: Int, h: Int, r: Int, grow: Bool) -> [Float] {
        let (n, ovf) = w.multipliedReportingOverflow(by: h)
        if ovf || n > src.count { return [] }
        if n == 0 || r == 0 { return src }
        // The step-by-step order matters for NaN payloads and signed zero; small radii too.
        if r <= 2 || src[0..<n].contains(where: { $0.isNaN || ($0 == 0 && $0.sign == .minus) }) {
            return SegmentKit.morphRepeated(src, w, h, r, grow)
        }
        var out = SegmentKit.morphDense(Array(src[0..<n]), w, h, r, grow)
        out.append(contentsOf: src[n...])
        return out
    }

    /// Running max (or min) over a square window of radius `r` (edge-clipped), separable
    /// (photocraft `max_square`).
    static func maxSquare(_ src: [Float], _ w: Int, _ h: Int, _ r: Int, _ max: Bool) -> [Float] {
        var tmp = [Float](repeating: 0, count: w * h)
        src.withUnsafeBufferPointer { sb in
            tmp.withUnsafeMutableBufferPointer { tb in
                let t = UnsafeSendable(tb)
                parallelChunks(h, minChunk: 16) { rows in
                    var g: [Float] = [], hb: [Float] = []
                    for y in rows {
                        SegmentKit.runningExtreme(UnsafeBufferPointer(rebasing: sb[(y * w)..<(y * w + w)]),
                                                  UnsafeMutableBufferPointer(rebasing: t.value[(y * w)..<(y * w + w)]), min(r, Swift.max(w - 1, 0)), max, &g, &hb)
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        tmp.withUnsafeBufferPointer { tb in
            out.withUnsafeMutableBufferPointer { ob in
                let o = UnsafeSendable(ob)
                parallelChunks(w, minChunk: 16) { cols in
                    var g: [Float] = [], hb: [Float] = []
                    var col = [Float](repeating: 0, count: h), res = [Float](repeating: 0, count: h)
                    for x in cols {
                        for y in 0..<h { col[y] = tb[y * w + x] }
                        col.withUnsafeBufferPointer { cb in
                            res.withUnsafeMutableBufferPointer { rb in SegmentKit.runningExtreme(cb, rb, min(r, Swift.max(h - 1, 0)), max, &g, &hb) }
                        }
                        for y in 0..<h { o.value[y * w + x] = res[y] }
                    }
                }
            }
        }
        return out
    }
}

extension SegmentKit {
    /// Running max (or min) over a window of radius `r` (edge-clipped): van Herk / Gil–Werman
    /// (photocraft `running_extreme`; Rust's `f32::max`/`min` ignore NaN).
    static func runningExtreme(_ src: UnsafeBufferPointer<Float>, _ out: UnsafeMutableBufferPointer<Float>, _ r: Int, _ max: Bool,
                               _ g: inout [Float], _ hb: inout [Float]) {
        let n = src.count
        let k = 2 * r + 1
        @inline(__always) func f(_ a: Float, _ b: Float) -> Float { max ? Float.maximum(a, b) : Float.minimum(a, b) }
        let pad: Float = max ? -.infinity : .infinity
        let m = (n + 2 * r + k - 1) / k * k
        g = [Float](repeating: pad, count: m)
        hb = [Float](repeating: pad, count: m)
        @inline(__always) func p(_ j: Int) -> Float { j >= r && j < r + n ? src[j - r] : pad }
        for j in 0..<m { g[j] = j % k == 0 ? p(j) : f(g[j - 1], p(j)) }
        for j in Swift.stride(from: m - 1, through: 0, by: -1) { hb[j] = j % k == k - 1 || j == m - 1 ? p(j) : f(hb[j + 1], p(j)) }
        for i in 0..<out.count { out[i] = f(hb[i], g[i + 2 * r]) }
    }

    /// ⌈r/2⌉ unit squares as one square of that radius, then ⌊r/2⌋ unit crosses as doubling
    /// Manhattan balls (photocraft `dense`); radii saturate at the image extent.
    static func morphDense(_ src: [Float], _ w: Int, _ h: Int, _ r: Int, _ grow: Bool) -> [Float] {
        let extent = max(w, h) - 1
        let square = min(r / 2 + r % 2, extent)
        let diamond = min(r / 2, max(w + h - 2, 0))
        var cur = Matting.maxSquare(src, w, h, square, grow)
        if diamond > 0 {
            var next = [Float](repeating: 0, count: src.count)
            var built = 0
            let bits = Int.bitWidth - diamond.leadingZeroBitCount
            for bit in Swift.stride(from: bits - 1, through: 0, by: -1) {
                if built > 0 {
                    cross(cur, &next, w, h, built, grow)
                    swap(&cur, &next)
                    built *= 2
                }
                if (diamond >> bit) & 1 != 0 {
                    cross(cur, &next, w, h, 1, grow)
                    swap(&cur, &next)
                    built += 1
                }
            }
        }
        return cur
    }

    /// A radius-2d Manhattan ball is the union of five radius-d balls (here and d pixels along
    /// each axis, centres clamped at the canvas edge) — photocraft `cross`.
    static func cross(_ src: [Float], _ dst: inout [Float], _ w: Int, _ h: Int, _ d: Int, _ grow: Bool) {
        @inline(__always) func pick(_ a: Float, _ b: Float) -> Float { grow ? Float.maximum(a, b) : Float.minimum(a, b) }
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { db in
                let o = UnsafeSendable(db)
                parallelChunks(h, minChunk: 16) { rows in
                    for y in rows {
                        let a = y * w
                        let up = (y > d ? y - d : 0) * w, down = min(y + d, h - 1) * w
                        for x in 0..<w {
                            let l = s[a + (x > d ? x - d : 0)], rr = s[a + min(x + d, w - 1)]
                            o.value[a + x] = pick(pick(pick(pick(s[a + x], l), rr), s[up + x]), s[down + x])
                        }
                    }
                }
            }
        }
    }

    /// r alternating 3×3 square / cross steps (photocraft `repeated`, the reference order).
    static func morphRepeated(_ src: [Float], _ w: Int, _ h: Int, _ r: Int, _ grow: Bool) -> [Float] {
        var cur = src, nxt = src
        // Neighbours in the reference order (dy, then dx), without the centre.
        let squareN: [(Int, Int)] = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
        let crossN: [(Int, Int)] = [(0, -1), (-1, 0), (1, 0), (0, 1)]
        for k in 0..<r {
            let nb = k % 2 == 0 ? squareN : crossN
            cur.withUnsafeBufferPointer { c in
                nxt.withUnsafeMutableBufferPointer { o in
                    for y in 0..<h {
                        for x in 0..<w {
                            var v = c[y * w + x]
                            for (dx, dy) in nb {
                                let nx = x + dx, ny = y + dy
                                if nx >= 0 && ny >= 0 && nx < w && ny < h {
                                    let u = c[ny * w + nx]
                                    v = grow ? Float.maximum(v, u) : Float.minimum(v, u)
                                }
                            }
                            o[y * w + x] = v
                        }
                    }
                }
            }
            swap(&cur, &nxt)
        }
        return cur
    }
}
