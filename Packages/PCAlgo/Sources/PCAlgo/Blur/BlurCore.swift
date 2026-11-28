// Port of photocraft-algo (crates/algo/src/blur.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The separable machinery shared by the blurs and sharpeners: the exact Gaussian kernel and its
// premultiplied separable convolution (`conv_sep`), and the running-sum box passes that
// approximate a large Gaussian with three boxes (Kovesi 2010) or run Box Blur at a large radius
// (`box_blur`), with the source extended beyond its rectangle by repeating its edge pixels.

import Foundation
import Metal
import PCFoundation

enum BlurCore {
    /// Output pixels per thread of the Metal running-sum box pass (the initial window sum is
    /// amortised over a segment).
    nonisolated(unsafe) static var boxSegment: Int32 = Int32(ProcessInfo.processInfo.environment["PCALGO_BOX_SEGMENT"].flatMap { Int($0) } ?? 32)

    /// Normalised Gaussian kernel with standard deviation `sigma` (radius ⌈3σ⌉) — photocraft
    /// `gaussian_kernel`.
    static func gaussianKernel(_ sigma: Float) -> [Float] {
        if !(sigma >= 0.05) { return [1] }
        let r = PCAMath.i32((sigma * 3).rounded(.up))
        var k: [Float] = []
        k.reserveCapacity(Int(2 * r + 1))
        for i in -r...r { k.append(expf(Float(-(i * i)) / (2 * sigma * sigma))) }
        var s: Float = 0
        for v in k { s += v }
        return k.map { $0 / s }
    }

    /// Gaussian Blur's kernel for `radius` (its standard deviation), photocraft
    /// `gaussian_blur_kernel` (#8544). Sampling the curve at whole pixels leaves a small radius
    /// almost no blur: at 0.3 the kernel's variance is 0.008, not 0.09. Below 1 the sampling width
    /// is chosen so the kernel has exactly the variance `radius²`; from 1 up it is unchanged.
    static func gaussianBlurKernel(_ radius: Float) -> [Float] {
        if !(radius >= 0.05 && radius < 1) { return gaussianKernel(radius) }
        func variance(_ k: [Float]) -> Float {
            let r = Float(k.count / 2)
            var s: Float = 0
            for (i, w) in k.enumerated() { s += w * (Float(i) - r) * (Float(i) - r) }
            return s
        }
        let target = radius * radius
        // The sampled kernel's variance only falls short of sigma², so the width lies above `radius`.
        var lo = radius, hi = radius + 1
        for _ in 0..<40 {
            let mid = 0.5 * (lo + hi)
            if variance(gaussianKernel(mid)) < target { lo = mid } else { hi = mid }
        }
        return gaussianKernel(0.5 * (lo + hi))
    }

    /// Box widths (odd) whose `n`-fold convolution has standard deviation `sigma` (photocraft
    /// `boxes_for_gauss`).
    static func boxesForGauss(_ sigma: Float, _ n: Int) -> [Int] {
        let nf = Float(n)
        let wIdeal = (12 * sigma * sigma / nf + 1).squareRoot()
        var wl = PCAMath.i32(wIdeal.rounded(.down))
        if wl % 2 == 0 { wl -= 1 }
        wl = max(wl, 1)
        let wu = wl &+ 2
        let mIdeal = (12 * sigma * sigma - nf * Float(wl * wl) - 4 * nf * Float(wl) - 3 * nf) / (-4 * Float(wl) - 4)
        let m = PCAMath.usize(Float.minimum(Float.maximum(mIdeal.rounded(.toNearestOrAwayFromZero), 0), nf))
        return (0..<n).map { $0 < m ? Int(wl) : Int(wu) }
    }

    /// Box widths Gaussian Blur runs as running-sum passes (radius > 4), else nil (photocraft
    /// `box_widths`).
    static func gaussianBoxes(_ radius: Float) -> [Int]? { radius > 4 ? boxesForGauss(radius, 3) : nil }

    /// Box widths Box Blur runs as running-sum passes (rounded radius > 4), else nil.
    static func boxBoxes(_ radius: Float) -> [Int]? {
        let r = PCAMath.usize(PCAMath.pos(radius).rounded(.toNearestOrAwayFromZero))
        return r > 4 ? [2 * r + 1] : nil
    }

    // MARK: Exact separable convolution

    /// Separable convolution of `src` (premultiplied internally; 0 outside `src`) for `out` —
    /// photocraft `conv_sep`. Taps accumulate in kernel order, as `conv_row` does.
    static func convSep(_ src: FloatImage, _ out: PixelRect, _ kx: [Float], _ ky: [Float], _ alpha: Bool) -> FloatImage {
        let n = src.channels
        let rx = Int32(kx.count / 2), ry = Int32(ky.count / 2)
        let ow = out.width, oh = out.height
        var res = FloatImage(rect: out, channels: n)
        if ow == 0 || oh == 0 || n == 0 { return res }
        let th = oh + 2 * Int(ry)
        let win = PixelRect(x0: out.x0 - rx, y0: out.y0 - ry, x1: out.x1 + rx, y1: out.y1 + ry)
        var p = src.crop(win).data
        premultiply(&p, n, alpha)
        let ww = win.width
        var tmp = [Float](repeating: 0, count: ow * th * n)
        p.withUnsafeBufferPointer { pw in
            tmp.withUnsafeMutableBufferPointer { tb in
                let t = UnsafeSendable(tb)
                parallelChunks(th, minChunk: 8) { rows in
                    var acc = [Float](repeating: 0, count: n)
                    for ty in rows {
                        let rowBase = ty * ww * n
                        for ox in 0..<ow {
                            for c in 0..<n { acc[c] = 0 }
                            for (i, kv) in kx.enumerated() {
                                let s = rowBase + (ox + i) * n
                                for c in 0..<n { acc[c] += pw[s + c] * kv }
                            }
                            let d = (ty * ow + ox) * n
                            for c in 0..<n { t.value[d + c] = acc[c] }
                        }
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { tb in
            res.data.withUnsafeMutableBufferPointer { rb in
                let r = UnsafeSendable(rb)
                parallelChunks(oh, minChunk: 8) { rows in
                    for oy in rows {
                        let d = oy * ow * n
                        for (i, kv) in ky.enumerated() {
                            let s = (oy + i) * ow * n
                            for j in 0..<(ow * n) { r.value[d + j] += tb[s + j] * kv }
                        }
                    }
                }
            }
        }
        unpremultiply(&res.data, n, alpha)
        return res
    }

    // MARK: Running-sum box passes

    /// One running-sum box pass of radius `r` along a line of `w`-float elements: element `i` of
    /// `dst` is the mean of elements `i ... i + 2r` of `src` (photocraft `box_pass`).
    static func boxPass(_ src: UnsafeBufferPointer<Float>, _ dst: UnsafeMutableBufferPointer<Float>, _ w: Int, _ r: Int, _ acc: inout [Float]) {
        if w == 0 { return }
        let norm = 1 / Float(2 * r + 1)
        for j in 0..<w { acc[j] = 0 }
        let srcElems = src.count / w
        for e in 0..<min(2 * r + 1, srcElems) { for j in 0..<w { acc[j] += src[e * w + j] } }
        let len = dst.count / w
        for i in 0..<len {
            for j in 0..<w { dst[i * w + j] = acc[j] * norm }
            let add = i + 2 * r + 1
            if add < srcElems {
                for j in 0..<w { acc[j] += src[add * w + j] - src[i * w + j] }
            }
        }
    }

    /// Box passes of `radii` in turn along `line` (consumed), ending in `dst` (photocraft
    /// `line_passes`).
    static func linePasses(_ dst: UnsafeMutableBufferPointer<Float>, _ w: Int, _ radii: [Int], _ line: inout [Float], _ next: inout [Float], _ acc: inout [Float]) {
        let len = dst.count / w
        var tail = radii.reduce(0, +)
        for (k, r) in radii.enumerated() {
            tail -= r
            if k + 1 == radii.count {
                line.withUnsafeBufferPointer { l in boxPass(l, dst, w, r, &acc) }
            } else {
                let count = (len + 2 * tail) * w
                if next.count != count { next = [Float](repeating: 0, count: count) }
                line.withUnsafeBufferPointer { l in next.withUnsafeMutableBufferPointer { nb in boxPass(l, nb, w, r, &acc) } }
                swap(&line, &next)
            }
        }
    }

    /// Box blurs of the given odd widths, one after another along each axis, of `src` extended
    /// beyond its rectangle by repeating its edge pixels (alpha-weighted when `alpha`) — photocraft
    /// `box_blur` / `box_passes`. Only the source's own rows and the output columns are blurred.
    static func boxPasses(_ src: FloatImage, _ out: PixelRect, _ alpha: Bool, _ boxes: [Int]) -> FloatImage {
        let n = src.channels
        let radii = boxes.map { $0 / 2 }
        let reach = Int32(radii.reduce(0, +))
        let ow = out.width, oh = out.height
        var res = FloatImage(rect: out, channels: n)
        let used = src.rect.intersect(out.outset(by: reach))
        if used.isEmpty || n == 0 || ow == 0 || oh == 0 { return res }
        let rows = used.height
        var h = [Float](repeating: 0, count: rows * ow * n)
        let left = Int(used.x0 - (out.x0 - reach)), right = Int((out.x1 + reach) - used.x1)
        src.data.withUnsafeBufferPointer { sp in
            h.withUnsafeMutableBufferPointer { hb in
                let hs = UnsafeSendable(hb)
                parallelChunks(rows, minChunk: 8) { range in
                    var line: [Float] = [], next: [Float] = [], acc = [Float](repeating: 0, count: n)
                    var row = [Float](repeating: 0, count: used.width * n)
                    for ry in range {
                        let y = used.y0 + Int32(ry)
                        let base = (Int(y - src.rect.y0) * src.rect.width + Int(used.x0 - src.rect.x0)) * n
                        for i in 0..<(used.width * n) { row[i] = sp[base + i] }
                        premultiply(&row, n, alpha)
                        line.removeAll(keepingCapacity: true)
                        for _ in 0..<left { line.append(contentsOf: row[0..<n]) }
                        line.append(contentsOf: row)
                        for _ in 0..<right { line.append(contentsOf: row[(row.count - n)...]) }
                        let dst = UnsafeMutableBufferPointer(rebasing: hs.value[(ry * ow * n)..<((ry + 1) * ow * n)])
                        linePasses(dst, n, radii, &line, &next, &acc)
                    }
                }
            }
        }
        let top = Int(used.y0 - (out.y0 - reach)), bottom = Int((out.y1 + reach) - used.y1)
        let stride = ow * n
        h.withUnsafeBufferPointer { hb in
            res.data.withUnsafeMutableBufferPointer { rb in
                let rs = UnsafeSendable(rb)
                parallelChunks(ow, minChunk: 4) { cols in
                    var line: [Float] = [], next: [Float] = [], acc = [Float](repeating: 0, count: n)
                    var col = [Float](repeating: 0, count: oh * n)
                    for x in cols {
                        line.removeAll(keepingCapacity: true)
                        let sx = x * n
                        for _ in 0..<top { for c in 0..<n { line.append(hb[sx + c]) } }
                        for y in 0..<rows { for c in 0..<n { line.append(hb[y * stride + sx + c]) } }
                        for _ in 0..<bottom { for c in 0..<n { line.append(hb[(rows - 1) * stride + sx + c]) } }
                        col.withUnsafeMutableBufferPointer { cb in linePasses(cb, n, radii, &line, &next, &acc) }
                        unpremultiply(&col, n, alpha)
                        for y in 0..<oh { for c in 0..<n { rs.value[(y * ow + x) * n + c] = col[y * n + c] } }
                    }
                }
            }
        }
        return res
    }

    /// The Gaussian blur photocraft runs for `radius` (σ): exact kernel up to 4, three box passes
    /// above (photocraft `blur::gaussian`).
    static func gaussian(_ src: FloatImage, _ out: PixelRect, _ alpha: Bool, _ radius: Float) -> FloatImage {
        if let boxes = gaussianBoxes(radius) { return boxPasses(src, out, alpha, boxes) }
        let k = gaussianBlurKernel(radius)
        return convSep(src, out, k, k, alpha)
    }
}

// MARK: - Metal encoders

/// MSL `pca_conv_params`.
struct ConvParams: BitwiseCopyable {
    var tmpOrigin: SIMD2<Int32>
    var tmpSize: SIMD2<Int32>
    var taps: Int32
    var radius: Int32
    var pad0: Int32 = 0
    var pad1: Int32 = 0
}

/// MSL `pca_box_params`.
struct BoxParams: BitwiseCopyable {
    var inOrigin: SIMD2<Int32>
    var inSize: SIMD2<Int32>
    var oOrigin: SIMD2<Int32>
    var oSize: SIMD2<Int32>
    var clampLo: SIMD2<Int32>
    var clampHi: SIMD2<Int32>
    var radius: Int32
    var axis: Int32
    var segment: Int32
    var premulIn: UInt32
    var unpremulOut: UInt32
    var norm: Float
    var normLo: Float = 0
    var pad1: Int32 = 0

    /// 1/(2r+1) split into a float and its remainder (from a double).
    static func norm(_ r: Int32) -> (Float, Float) {
        let d = 1 / Double(2 * Int64(r) + 1)
        let hi = Float(d)
        return (hi, Float(d - Double(hi)))
    }
}

extension GPUPass {
    /// `BlurCore.convSep` on the GPU: reads `input` (covering `inRect`, 0 outside) and writes the
    /// premultiplied-then-unpremultiplied result for `outRect` into `output` (covering `outRect`).
    func encodeConvSep(input: any MTLTexture, inRect: PixelRect, output: any MTLTexture, outRect: PixelRect,
                       kx: [Float], ky: [Float]) throws {
        let ry = Int32(ky.count / 2), rx = Int32(kx.count / 2)
        let tmpRect = PixelRect(x0: outRect.x0, y0: outRect.y0 - ry, x1: outRect.x1, y1: outRect.y1 + ry)
        let tmp = try texture(tmpRect)
        let f = frame.with(src: inRect, out: outRect)
        let kxb = try buffer(kx), kyb = try buffer(ky)
        let pH = ConvParams(tmpOrigin: SIMD2(tmpRect.x0, tmpRect.y0), tmpSize: SIMD2(Int32(tmpRect.width), Int32(tmpRect.height)),
                            taps: Int32(kx.count), radius: rx)
        try dispatch("pca_conv_h", frame: f, params: pH, textures: [input, tmp], buffers: [kxb], width: tmpRect.width, height: tmpRect.height)
        let pV = ConvParams(tmpOrigin: SIMD2(tmpRect.x0, tmpRect.y0), tmpSize: SIMD2(Int32(tmpRect.width), Int32(tmpRect.height)),
                            taps: Int32(ky.count), radius: ry)
        try dispatch("pca_conv_v", frame: f, params: pV, textures: [tmp, output], buffers: [kyb], width: outRect.width, height: outRect.height)
        recycle(tmp)
    }

    /// `BlurCore.boxPasses` on the GPU: `input` covers `inRect` and is extended by repeating its
    /// edge; the straight result for `outRect` goes to `output`.
    func encodeBoxPasses(input: any MTLTexture, inRect: PixelRect, output: any MTLTexture, outRect: PixelRect, boxes: [Int]) throws {
        let radii = boxes.map { Int32($0 / 2) }
        let reach = radii.reduce(0, +)
        let used = inRect.intersect(outRect.outset(by: reach))
        let f = frame.with(src: inRect, out: outRect)
        if used.isEmpty {
            try dispatch("pca_clear", frame: f, params: NoParams(), textures: [output], width: outRect.width, height: outRect.height)
            return
        }
        let segment: Int32 = BlurCore.boxSegment
        // Horizontal passes over the used rows, for the output columns (plus the remaining reach).
        var cur = input
        var curRect = inRect
        var clampRect = inRect
        var tail = reach
        for (k, r) in radii.enumerated() {
            tail -= r
            let oRect = PixelRect(x0: outRect.x0 - tail, y0: used.y0, x1: outRect.x1 + tail, y1: used.y1)
            let o = try texture(oRect)
            let p = BoxParams(inOrigin: SIMD2(curRect.x0, curRect.y0), inSize: SIMD2(Int32(curRect.width), Int32(curRect.height)),
                              oOrigin: SIMD2(oRect.x0, oRect.y0), oSize: SIMD2(Int32(oRect.width), Int32(oRect.height)),
                              clampLo: SIMD2(clampRect.x0, clampRect.y0), clampHi: SIMD2(clampRect.x1 - 1, clampRect.y1 - 1),
                              radius: r, axis: 0, segment: segment, premulIn: k == 0 ? 1 : 0, unpremulOut: 0,
                              norm: BoxParams.norm(r).0, normLo: BoxParams.norm(r).1)
            try dispatchBoxPass(p, frame: f, input: cur, output: o)
            if k > 0 { recycle(cur) }
            cur = o; curRect = oRect; clampRect = oRect
        }
        // Vertical passes down the output columns; rows beyond the used rows repeat its edge rows.
        tail = reach
        for (k, r) in radii.enumerated() {
            tail -= r
            let last = k + 1 == radii.count
            let oRect = PixelRect(x0: outRect.x0, y0: outRect.y0 - tail, x1: outRect.x1, y1: outRect.y1 + tail)
            let o = last ? output : try texture(oRect)
            let p = BoxParams(inOrigin: SIMD2(curRect.x0, curRect.y0), inSize: SIMD2(Int32(curRect.width), Int32(curRect.height)),
                              oOrigin: SIMD2(oRect.x0, oRect.y0), oSize: SIMD2(Int32(oRect.width), Int32(oRect.height)),
                              clampLo: SIMD2(clampRect.x0, clampRect.y0), clampHi: SIMD2(clampRect.x1 - 1, clampRect.y1 - 1),
                              radius: r, axis: 1, segment: segment, premulIn: 0, unpremulOut: last ? 1 : 0,
                              norm: BoxParams.norm(r).0, normLo: BoxParams.norm(r).1)
            try dispatchBoxPass(p, frame: f, input: cur, output: o)
            recycle(cur)
            cur = o; curRect = oRect; clampRect = oRect
        }
    }

    /// Largest radius summed directly per output along rows (running sums beyond).
    static let directBoxRadius: Int32 = 4

    /// One box pass: running sums in segments, except small horizontal radii, summed directly.
    func dispatchBoxPass(_ p: BoxParams, frame f: PCAFrame? = nil, input: any MTLTexture, output: any MTLTexture) throws {
        let w = Int(p.oSize.x), h = Int(p.oSize.y)
        if p.axis == 0 && p.radius <= GPUPass.directBoxRadius {
            try dispatch("pca_box_direct", frame: f, params: p, textures: [input, output], width: w, height: h)
            return
        }
        let lines = p.axis == 0 ? h : w, len = p.axis == 0 ? w : h
        let segs = (len + Int(p.segment) - 1) / Int(p.segment)
        try dispatch("pca_box_pass", frame: f, params: p, textures: [input, output], width: lines, height: segs, threadgroup: (32, 4))
    }

    /// The Gaussian photocraft runs for `radius` from the pass source into `output` for `outRect`.
    func encodeGaussian(radius: Float, output: any MTLTexture, outRect: PixelRect) throws {
        if let boxes = BlurCore.gaussianBoxes(radius) {
            try encodeBoxPasses(input: src, inRect: srcRect, output: output, outRect: outRect, boxes: boxes)
        } else {
            let k = BlurCore.gaussianBlurKernel(radius)
            try encodeConvSep(input: src, inRect: srcRect, output: output, outRect: outRect, kx: k, ky: k)
        }
    }
}
