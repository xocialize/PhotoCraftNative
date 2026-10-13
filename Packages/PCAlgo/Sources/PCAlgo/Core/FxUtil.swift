// Port of photocraft-algo (crates/algo/src/fxutil.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Shared helpers of photocraft's second filter batch: window buffers, single-buffer box and
// almost-Gaussian blurs with edges clamped to the buffer (f64 running sums on the CPU), jittered
// cell points, and the premultiplied bilinear accumulator the gallery blurs use. The Metal twins
// of the buffer blurs are `GPUPass.encodeBoxBlurN` / `encodeGaussBlurN`.

import Metal
import PCFoundation

enum FxUtil {
    /// Max channels per pixel kept on the stack in photocraft (CMYK + alpha + spare).
    static let maxChannels = 8

    /// Interleaved premultiplied copy of `src` over `win` (zero outside) — photocraft `premul_window`.
    static func premulWindow(_ src: FloatImage, _ win: PixelRect, _ alpha: Bool) -> [Float] {
        var v = src.crop(win).data
        premultiply(&v, src.channels, alpha)
        return v
    }

    /// Unpremultiplies one interleaved pixel in place (photocraft `unpremul_px`).
    @inline(__always)
    static func unpremulPx(_ px: inout [Float], _ alpha: Bool) {
        guard alpha else { return }
        let n = px.count, a = px[n - 1]
        for c in 0..<(n - 1) { px[c] = a > 1e-7 ? px[c] / a : 0 }
    }

    /// In-place running-sum box blur of every row of a `w × h × n` buffer, radius `r`, edges
    /// clamped, f64 sums (photocraft `box_rows_n`).
    static func boxRowsN(_ buf: inout [Float], _ w: Int, _ h: Int, _ n: Int, _ r: Int) {
        if r == 0 || w == 0 { return }
        let norm = 1 / Double(2 * r + 1)
        buf.withUnsafeMutableBufferPointer { b in
            let bs = UnsafeSendable(b)
            parallelChunks(h, minChunk: 4) { rows in
                var scratch = [Float](repeating: 0, count: w * n)
                for y in rows {
                    let base = y * w * n
                    for i in 0..<(w * n) { scratch[i] = bs.value[base + i] }
                    @inline(__always) func at(_ x: Int, _ c: Int) -> Double { Double(scratch[min(max(x, 0), w - 1) * n + c]) }
                    for c in 0..<n {
                        var acc = 0.0
                        for x in -r...r { acc += at(x, c) }
                        for x in 0..<w {
                            bs.value[base + x * n + c] = Float(acc * norm)
                            acc += at(x + r + 1, c) - at(x - r, c)
                        }
                    }
                }
            }
        }
    }

    /// `boxRowsN` over columns (photocraft `box_cols_n`).
    static func boxColsN(_ buf: inout [Float], _ w: Int, _ h: Int, _ n: Int, _ r: Int) {
        if r == 0 || h == 0 { return }
        let norm = 1 / Double(2 * r + 1)
        buf.withUnsafeMutableBufferPointer { b in
            let bs = UnsafeSendable(b)
            parallelChunks(w, minChunk: 4) { cols in
                var scratch = [Float](repeating: 0, count: h * n)
                for x in cols {
                    for y in 0..<h { for c in 0..<n { scratch[y * n + c] = bs.value[(y * w + x) * n + c] } }
                    @inline(__always) func at(_ y: Int, _ c: Int) -> Double { Double(scratch[min(max(y, 0), h - 1) * n + c]) }
                    for c in 0..<n {
                        var acc = 0.0
                        for y in -r...r { acc += at(y, c) }
                        for y in 0..<h {
                            bs.value[(y * w + x) * n + c] = Float(acc * norm)
                            acc += at(y + r + 1, c) - at(y - r, c)
                        }
                    }
                }
            }
        }
    }

    /// Box blur of an interleaved buffer, radius `r` in both directions (photocraft `box_blur_n`).
    static func boxBlurN(_ buf: inout [Float], _ w: Int, _ h: Int, _ n: Int, _ r: Int) {
        boxRowsN(&buf, w, h, n, r)
        boxColsN(&buf, w, h, n, r)
    }

    /// Radii of three boxes approximating a Gaussian of `sigma` (Kovesi 2010), with photocraft's
    /// fix that the smallest real blur is one radius-1 pass (photocraft `gauss_box_radii`).
    static func gaussBoxRadii(_ sigma: Float) -> [Int] {
        let n: Float = 3
        let wIdeal = (12 * sigma * sigma / n + 1).squareRoot()
        var wl = PCAMath.i32(wIdeal.rounded(.down))
        if wl % 2 == 0 { wl -= 1 }
        wl = max(wl, 1)
        let wu = wl &+ 2
        let mf = (12 * sigma * sigma - n * Float(wl * wl) - 4 * n * Float(wl) - 3 * n) / (-4 * Float(wl) - 4)
        let m = PCAMath.usize(Float.minimum(Float.maximum(mf.rounded(.toNearestOrAwayFromZero), 0), n))
        var radii = (0..<3).map { $0 < m ? Int(wl - 1) / 2 : Int(wu - 1) / 2 }
        if radii.allSatisfy({ $0 == 0 }) { radii[0] = 1 }
        return radii
    }

    /// Approximate Gaussian blur (three box passes per axis) of an interleaved buffer; σ < 0.3 is
    /// a no-op (photocraft `gauss_blur_n`).
    static func gaussBlurN(_ buf: inout [Float], _ w: Int, _ h: Int, _ n: Int, _ sigma: Float) {
        if sigma < 0.3 { return }
        let radii = gaussBoxRadii(sigma)
        for r in radii { boxRowsN(&buf, w, h, n, r) }
        for r in radii { boxColsN(&buf, w, h, n, r) }
    }

    /// Jittered feature point of grid cell `(cx, cy)` (photocraft `cell_point`).
    @inline(__always)
    static func cellPoint(_ cx: Int32, _ cy: Int32, _ cell: Float, _ seed: UInt32, _ origin: (Float, Float)) -> (Float, Float) {
        (origin.0 + (Float(cx) + 0.1 + 0.8 * hash01(cx, cy, 11, seed)) * cell,
         origin.1 + (Float(cy) + 0.1 + 0.8 * hash01(cx, cy, 12, seed)) * cell)
    }

    /// Adds the premultiplied bilinear sample of `src` at `(x, y)` (pixel centres at .5, edges
    /// clamped to `clip`, inside `src.rect`) into `acc` (photocraft `add_sample_premul`).
    @inline(__always)
    static func addSamplePremul(_ src: FloatImage, _ x: Float, _ y: Float, _ clip: PixelRect, _ alpha: Bool, _ acc: inout [Float]) {
        if !x.isFinite || !y.isFinite || clip.isEmpty { return }
        let n = src.channels
        let fx = clampf(x - 0.5, Float(clip.x0), Float(clip.x1 - 1))
        let fy = clampf(y - 0.5, Float(clip.y0), Float(clip.y1 - 1))
        let x0 = Int32(fx.rounded(.down)), y0 = Int32(fy.rounded(.down))
        let x1 = min(x0 + 1, clip.x1 - 1), y1 = min(y0 + 1, clip.y1 - 1)
        let ax = fx - Float(x0), ay = fy - Float(y0)
        let w = src.rect.width
        @inline(__always) func idx(_ xx: Int32, _ yy: Int32) -> Int { (Int(yy - src.rect.y0) * w + Int(xx - src.rect.x0)) * n }
        let taps = [(idx(x0, y0), (1 - ax) * (1 - ay)), (idx(x1, y0), ax * (1 - ay)), (idx(x0, y1), (1 - ax) * ay), (idx(x1, y1), ax * ay)]
        for (i, k) in taps {
            if k <= 0 { continue }
            if alpha {
                let a = src.data[i + n - 1] * k
                for c in 0..<(n - 1) { acc[c] += src.data[i + c] * a }
                acc[n - 1] += a
            } else {
                for c in 0..<n { acc[c] += src.data[i + c] * k }
            }
        }
    }
}

extension GPUPass {
    /// `FxUtil.boxBlurN` on a float4 texture covering `rect` (edges clamped to `rect`, one row
    /// pass then one column pass). Returns the blurred texture (a new one; `tex` is untouched).
    /// Intermediates are recycled; recycle the result too when done with it.
    func encodeBoxBlurN(_ tex: any MTLTexture, rect: PixelRect, radius r: Int) throws -> any MTLTexture {
        if r == 0 || rect.isEmpty { return tex }
        var cur = tex
        for axis in [Int32(0), 1] {
            let o = try texture(rect)
            try encodeClampedBox(input: cur, output: o, rect: rect, radius: Int32(r), axis: axis)
            if cur !== tex { recycle(cur) }
            cur = o
        }
        return cur
    }

    /// `FxUtil.gaussBlurN` on a float4 texture covering `rect`; returns the blurred texture
    /// (the input itself when σ < 0.3; otherwise a new one, `tex` untouched).
    func encodeGaussBlurN(_ tex: any MTLTexture, rect: PixelRect, sigma: Float) throws -> any MTLTexture {
        if sigma < 0.3 || rect.isEmpty { return tex }
        let radii = FxUtil.gaussBoxRadii(sigma)
        var cur = tex
        for axis in [Int32(0), 1] {
            for r in radii {
                let o = try texture(rect)
                try encodeClampedBox(input: cur, output: o, rect: rect, radius: Int32(r), axis: axis)
                if cur !== tex { recycle(cur) }
                cur = o
            }
        }
        return cur
    }

    /// One box pass along `axis` over a texture covering `rect`, edges clamped to `rect`.
    func encodeClampedBox(input: any MTLTexture, output: any MTLTexture, rect: PixelRect, radius: Int32, axis: Int32) throws {
        let segment: Int32 = BlurCore.boxSegment
        let p = BoxParams(inOrigin: SIMD2(rect.x0, rect.y0), inSize: SIMD2(Int32(rect.width), Int32(rect.height)),
                          oOrigin: SIMD2(rect.x0, rect.y0), oSize: SIMD2(Int32(rect.width), Int32(rect.height)),
                          clampLo: SIMD2(rect.x0, rect.y0), clampHi: SIMD2(rect.x1 - 1, rect.y1 - 1),
                          radius: radius, axis: axis, segment: segment, premulIn: 0, unpremulOut: 0,
                          norm: BoxParams.norm(radius).0, normLo: BoxParams.norm(radius).1)
        try dispatchBoxPass(p, input: input, output: output)
    }
}
