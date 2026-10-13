// Port of photocraft-algo (crates/algo/src/tone.rs: ShadowsHighlights; tone/shadows_highlights.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Image › Adjustments › Shadows/Highlights, as photocraft measured Photoshop 25.4 doing it:
// - Neighbourhood brightness: per pixel the mean of its brightest channel and its Rec. 601 luma,
//   averaged edge-aware (a Gaussian of σ = 1.14·Radius whose weights fall linearly with the
//   difference from the pixel's lightly blurred brightness — a 17-level bilateral grid, Durand &
//   Dorsey 2002, on a grid `d` times coarser), quantised to 8 bits.
// - Tonal mask: 1 − the Beta CDF of the neighbourhood (Beta(1.95, 23) at Tone 0 … 1 − L at 95+).
// - Curve: 1 − (1 − v)^q blended between q = 1, 2, 4, 8 by the Amount's strength.
// - Colour: only the luma of the result is kept; the pixel's own colour differences are added
//   back scaled by Color and shortened where they would leave the gamut. Midtone is an S-curve.
// The Metal path gathers each grid cell in the CPU's summation order, blurs two levels per pass
// and accumulates the interpolation level by level, so it needs no 17-level buffer.

import Metal
import PCFoundation

/// Image › Adjustments › Shadows/Highlights (photocraft `tone::ShadowsHighlights`; percentages
/// 0…100). As a filter it treats the reference bounds as the image.
public struct ShadowsHighlights: Filter, Hashable {
    public var shadowAmount: Float
    public var shadowTone: Float
    public var shadowRadius: Float
    public var highlightAmount: Float
    public var highlightTone: Float
    public var highlightRadius: Float
    /// Colour (saturation) correction in −100…100, applied where tones were changed.
    public var color: Float
    /// Midtone contrast in −100…100.
    public var midtone: Float
    /// Percent of pixels clipped to black / white (0…50).
    public var blackClip: Float
    public var whiteClip: Float

    /// photocraft's defaults (Photoshop's).
    public init(shadowAmount: Float = 35, shadowTone: Float = 50, shadowRadius: Float = 30, highlightAmount: Float = 0,
                highlightTone: Float = 50, highlightRadius: Float = 30, color: Float = 20, midtone: Float = 0,
                blackClip: Float = 0.01, whiteClip: Float = 0.01) {
        self.shadowAmount = shadowAmount; self.shadowTone = shadowTone; self.shadowRadius = shadowRadius
        self.highlightAmount = highlightAmount; self.highlightTone = highlightTone; self.highlightRadius = highlightRadius
        self.color = color; self.midtone = midtone; self.blackClip = blackClip; self.whiteClip = whiteClip
    }

    public var label: String { "Shadows/Highlights" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }
    public var gpuChannels: GPUChannels { .joint }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let b = ctx.bounds
        var px = ToneKit.rgbaPixels(src, b, ctx)
        ToneKit.shadowsHighlights(&px, w: b.width, h: b.height, self)
        return ToneKit.writeRGBA(px, b, src, out, ctx)
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        try ToneKit.SH.encode(self, pass)
    }
}

extension ToneKit {
    /// Image › Adjustments › Shadows/Highlights on a straight RGBA buffer `w × h` (photocraft
    /// `tone::shadows_highlights`).
    public static func shadowsHighlights(_ px: inout [SIMD4<Float>], w: Int, h: Int, _ p: ShadowsHighlights) {
        SH.run(&px, w, h, p)
    }

    /// `shadowsHighlights` on the CPU (`.cpu`) or through the Metal path.
    public static func shadowsHighlights(_ px: inout [SIMD4<Float>], w: Int, h: Int, _ p: ShadowsHighlights, on backend: Backend) throws {
        if backend == .cpu { SH.run(&px, w, h, p) } else { try runRGBA(p, &px, w: w, h: h, on: backend) }
    }

    /// photocraft `tone/shadows_highlights.rs`.
    enum SH {
        /// Neighbourhood σ per pixel of Radius.
        static let spatial: Float = 1.1424
        /// σ of the blur of the pixel's own brightness the edge weights compare with.
        static let guideSigma: Float = 1.3559
        /// Brightness difference at which a neighbour's weight reaches zero.
        static let range: Float = 1.0152
        /// Brightness levels of the piecewise-linear edge-aware average.
        static let levels = 17
        static let step: Float = 1 / Float(levels - 1)
        static let tMax: Float = Float(levels - 1) - 1e-4

        /// Brightness of one pixel: (max channel + luma) / 2.
        @inline(__always)
        static func brightness(_ q: SIMD4<Float>) -> Float {
            (Float.maximum(Float.maximum(q.x, q.y), q.z) + luma(SIMD3(q.x, q.y, q.z))) / 2
        }

        /// Grid geometry of the neighbourhood for `radius` (nil: σ < 0.3, the guide itself).
        static func grid(_ w: Int, _ h: Int, _ radius: Float) -> (sigma: Float, d: Int, rw: Int, rh: Int)? {
            let sigma = spatial * radius
            if sigma < 0.3 { return nil }
            let fd = (sigma / 4).rounded(.down)
            let d = max(fd.isFinite && fd < Float(Int.max / 2) ? Int(fd) : Int.max / 2, 1)
            return (sigma, d, (w + d - 1) / d, (h + d - 1) / d)
        }

        /// Edge-aware neighbourhood brightness of `lum` (`w × h`) for Photoshop's Radius
        /// (photocraft `neighbourhood`).
        static func neighbourhood(_ lum: [Float], _ w: Int, _ h: Int, _ radius: Float) -> [Float] {
            var guide = lum
            FxUtil.gaussBlurN(&guide, w, h, 1, guideSigma)
            guard let (sigma, d, rw, rh) = grid(w, h, radius) else { return guide }
            let cells = rw * rh
            var avg = [Float](repeating: 0, count: levels * cells)
            var buf = [Float](repeating: 0, count: 2 * cells)
            for k in 0..<levels {
                let g = Float(k) * step
                // Gather per cell in the order photocraft's scatter adds (rows, then columns).
                lum.withUnsafeBufferPointer { l in
                    buf.withUnsafeMutableBufferPointer { bb in
                        let bs = UnsafeSendable(bb)
                        parallelChunks(rh, minChunk: 1) { cys in
                            for cy in cys {
                                for cx in 0..<rw {
                                    var num: Float = 0, den: Float = 0
                                    for y in (cy * d)..<min(cy * d + d, h) {
                                        for x in (cx * d)..<min(cx * d + d, w) {
                                            let v = l[y * w + x]
                                            let wgt = Float.maximum(1 - abs(v - g) / range, 0)
                                            num += wgt * v
                                            den += wgt
                                        }
                                    }
                                    let c = 2 * (cy * rw + cx)
                                    bs.value[c] = num; bs.value[c + 1] = den
                                }
                            }
                        }
                    }
                }
                FxUtil.gaussBlurN(&buf, rw, rh, 2, sigma / Float(d))
                for j in 0..<cells {
                    avg[k * cells + j] = buf[2 * j + 1] > 1e-6 ? buf[2 * j] / buf[2 * j + 1] : g
                }
            }
            var out = [Float](repeating: 0, count: lum.count)
            out.withUnsafeMutableBufferPointer { ob in
                let os = UnsafeSendable(ob)
                parallelChunks(h, minChunk: 8) { rows in
                    for y in rows {
                        let fy = clampf((Float(y) + 0.5) / Float(d) - 0.5, 0, Float(rh - 1))
                        let y0 = Int(fy.rounded(.down)), ty = fy - fy.rounded(.towardZero)
                        let y1 = min(y0 + 1, rh - 1)
                        for x in 0..<w {
                            let fx = clampf((Float(x) + 0.5) / Float(d) - 0.5, 0, Float(rw - 1))
                            let x0 = Int(fx.rounded(.down)), tx = fx - fx.rounded(.towardZero)
                            let x1 = min(x0 + 1, rw - 1)
                            @inline(__always) func at(_ k: Int) -> Float {
                                let o = k * cells
                                let top = avg[o + y0 * rw + x0] + (avg[o + y0 * rw + x1] - avg[o + y0 * rw + x0]) * tx
                                let bot = avg[o + y1 * rw + x0] + (avg[o + y1 * rw + x1] - avg[o + y1 * rw + x0]) * tx
                                return top + (bot - top) * ty
                            }
                            let t = Float.minimum(clampf(guide[y * w + x], 0, 1) / step, tMax)
                            let k = Int(t.rounded(.down))
                            let f = t - Float(k)
                            os.value[y * w + x] = at(k) * (1 - f) + at(k + 1) * f
                        }
                    }
                }
            }
            return out
        }

        /// Beta(α, β) parameters of the tonal mask for Tone 0, 5, …, 95 (fitted to Photoshop's
        /// masks within 2/255).
        static let maskBeta: [(Float, Float)] = [
            (1.9468, 22.9366), (1.7770, 18.3471), (1.6403, 14.7559), (1.5270, 11.9346), (1.4269, 9.6467),
            (1.3470, 7.8430), (1.2807, 6.4038), (1.2240, 5.2384), (1.1772, 4.2967), (1.1373, 3.5350),
            (1.1021, 2.9109), (1.0755, 2.4186), (1.0508, 2.0189), (1.0307, 1.7034), (1.0140, 1.4583),
            (1.0015, 1.2758), (1.0, 1.1403), (1.0, 1.0510), (1.0, 1.0002), (1.0, 1.0),
        ]

        /// The tonal mask for `tone` (0…100) at the 256 neighbourhood levels: 1 − I_L(α, β)
        /// (photocraft `tonal_mask`, midpoint sums of the Beta density in f64).
        static func tonalMask(_ tone: Float) -> [Float] {
            let t = clampf(tone, 0, 95) / 5
            let i = min(Int(t.rounded(.down)), maskBeta.count - 2)
            let f = t - Float(i)
            let (a0, b0) = maskBeta[i], (a1, b1) = maskBeta[i + 1]
            let a = Double(a0 + (a1 - a0) * f), b = Double(b0 + (b1 - b0) * f)
            let sub = 16
            let n = 255 * sub
            var cum = [Double](repeating: 0, count: 256)
            var acc = 0.0
            for j in 0..<n {
                let x = (Double(j) + 0.5) / Double(n)
                acc += exp((a - 1) * log(x) + (b - 1) * log(1 - x))
                if (j + 1) % sub == 0 { cum[(j + 1) / sub] = acc }
            }
            let total = max(acc, Double.leastNormalMagnitude)
            return (0..<256).map { Float(1 - cum[$0] / total) }
        }

        /// Curve strength for Amount `a` (0…100): 0 at 0, 1 near 15, 2 at 50, 3 at 100.
        static func strength(_ a: Float) -> Float {
            let u = powf(clampf(a, 0, 100) / 100, 0.6216)
            return u <= 0.3 ? u / 0.3 : (1 + 20 * u) / 7
        }

        /// The full-strength curve of strength `s`: 1 − (1 − v)^q between q = 2^⌊s⌋ and 2^(⌊s⌋+1).
        @inline(__always)
        static func lift(_ s: Float, _ v: Float) -> Float {
            let fl = s.rounded(.down)
            let n = fl.isNaN ? 0 : Int(clampf(fl, 0, 2))
            let t = clampf(s - Float(n), 0, 1)
            let c = clampf(1 - v, 0, 1)
            var lo = c
            for _ in 0..<n { lo = lo * lo }   // powi(1 << n) by squaring, as compiler-rt's __powisf2
            let hi = lo * lo
            return 1 - ((1 - t) * lo + t * hi)
        }

        /// Linear interpolation in a table of `(x, y)` sorted by `x`.
        static func interp(_ table: [(Float, Float)], _ x: Float) -> Float {
            guard let (x0, y0) = table.first else { return 0 }
            if x <= x0 { return y0 }
            for i in 0..<(table.count - 1) {
                let (xa, ya) = table[i], (xb, yb) = table[i + 1]
                if x <= xb { return ya + (yb - ya) * (x - xa) / (xb - xa) }
            }
            return table.last?.1 ?? 0
        }

        /// Color: h of the colour-difference gain for positive values (exp(h · F)) …
        static let colorUp: [(Float, Float)] = [
            (0, 0), (1, 0.1566), (2, 0.2271), (5, 0.3776), (10, 0.5653), (20, 0.8669), (30, 1.1299), (40, 1.3748),
            (50, 1.6093), (60, 1.8375), (75, 2.1721), (100, 2.7193),
        ]
        /// … and for negative values (1 + h · F), by −Color.
        static let colorDown: [(Float, Float)] = [
            (0, 0), (1, -0.0145), (5, -0.0709), (10, -0.1373), (20, -0.2570), (30, -0.3612), (50, -0.5312), (75, -0.6866), (100, -0.7968),
        ]
        /// Midtone: (value, k, p) of k · (Y − ½) · (4Y(1 − Y))^p.
        static let midtoneTable: [(Float, Float, Float)] = [
            (-100, -0.6955, 2.267), (-75, -0.5873, 2.362), (-50, -0.4429, 2.492), (-25, -0.2514, 2.667), (-10, -0.1088, 2.803),
            (0, 0, 2.9), (10, 0.1206, 3.016), (25, 0.3262, 3.216), (50, 0.7423, 3.625), (75, 1.2635, 4.160), (100, 1.9032, 4.850),
        ]

        /// k and p of the Midtone curve for slider value `m`.
        static func midtoneKP(_ m: Float) -> (Float, Float) {
            (interp(midtoneTable.map { ($0.0, $0.1) }, m), interp(midtoneTable.map { ($0.0, $0.2) }, m))
        }

        @inline(__always)
        static func midtone(_ m: Float, _ kp: (Float, Float), _ y: Float) -> Float {
            if m == 0 { return y }
            let (k, p) = kp
            return clampf(y + k * (y - 0.5) * powf(Float.maximum(4 * y * (1 - y), 0), p), 0, 1)
        }

        @inline(__always)
        static func level(_ v: Float) -> Int { Int((clampf(v, 0, 1) * 255).rounded()) }

        /// The colour gain's h and whether it is the exponential (Color ≥ 0) form.
        static func colorGain(_ color: Float) -> (h: Float, up: Bool) {
            color >= 0 ? (interp(colorUp, color), true) : (interp(colorDown, -color), false)
        }

        /// One pixel's final colour from its new luma `yn` (photocraft's last loop body).
        @inline(__always)
        static func finish(_ q: SIMD4<Float>, _ yn: Float, _ gain: (h: Float, up: Bool)) -> SIMD4<Float> {
            let y1 = luma(SIMD3(q.x, q.y, q.z))
            let f = abs(yn - y1) / Float.maximum(Float.maximum(yn, y1), 1e-6)
            let g = gain.up ? expf(gain.h * f) : 1 + gain.h * f
            let d = SIMD3((q.x - y1) * g, (q.y - y1) * g, (q.z - y1) * g)
            var k: Float = 1
            for c in 0..<3 {
                let v = d[c]
                if v > 1e-9 { k = Float.minimum(k, (1 - yn) / v) }
                else if v < -1e-9 { k = Float.minimum(k, yn / -v) }
            }
            k = clampf(k, 0, 1)
            return SIMD4(clampf(yn + k * d.x, 0, 1), clampf(yn + k * d.y, 0, 1), clampf(yn + k * d.z, 0, 1), q.w)
        }

        static func run(_ px: inout [SIMD4<Float>], _ w: Int, _ h: Int, _ p: ShadowsHighlights) {
            if px.isEmpty || px.count != w * h { return }
            let (sa, ha) = (p.shadowAmount, p.highlightAmount)
            let lum = px.map(brightness)
            let ls: [Float]? = sa > 0 ? neighbourhood(lum, w, h, p.shadowRadius) : nil
            let lh: [Float]? = ha > 0 ? (ls != nil && abs(p.highlightRadius - p.shadowRadius) < 1e-3 ? ls : neighbourhood(lum, w, h, p.highlightRadius)) : nil
            let (ms, mh) = (tonalMask(p.shadowTone), tonalMask(p.highlightTone))
            let (ss, hs) = (strength(sa), strength(ha))
            let kp = midtoneKP(p.midtone)
            // The new luma of every pixel.
            var y2 = [Float](repeating: 0, count: px.count)
            px.withUnsafeBufferPointer { q in
                y2.withUnsafeMutableBufferPointer { yb in
                    let ys = UnsafeSendable(yb)
                    parallelChunks(q.count, minChunk: 4096) { r in
                        for i in r {
                            let o = SIMD3(q[i].x, q[i].y, q[i].z)
                            var adj = o
                            if let l = ls {
                                let m = ms[level(l[i])]
                                for c in 0..<3 { adj[c] += m * (lift(ss, adj[c]) - adj[c]) }
                            }
                            if let l = lh {
                                let m = mh[255 - level(l[i])]
                                for c in 0..<3 { adj[c] -= m * (lift(hs, 1 - o[c]) - (1 - o[c])) }
                            }
                            ys.value[i] = midtone(p.midtone, kp, clampf(luma(adj), 0, 1))
                        }
                    }
                }
            }
            clipLevels(&y2, px, p.blackClip, p.whiteClip)
            let gain = colorGain(p.color)
            px.withUnsafeMutableBufferPointer { q in
                let qs = UnsafeSendable(q)
                parallelChunks(q.count, minChunk: 4096) { r in
                    for i in r where qs.value[i].w > 0 { qs.value[i] = finish(qs.value[i], y2[i], gain) }
                }
            }
        }

        /// The black/white points of Black and White Clip from a 4096-bin histogram of the new
        /// luma over opaque pixels (nil: no stretch) — photocraft `clip_levels`' search.
        static func clipPoints(_ hist: [UInt32], _ n: UInt32, _ black: Float, _ white: Float) -> (Float, Float)? {
            if n == 0 { return nil }
            func find(_ pct: Float, _ rev: Bool) -> Float {
                let target = UInt32(clamping: Int64((clampf(pct, 0, 50) / 100 * Float(n)).rounded(.towardZero)))
                var acc: UInt32 = 0
                for k in 0..<4096 {
                    let i = rev ? 4095 - k : k
                    acc += hist[i]
                    if acc > target { return Float(i) / 4095 }
                }
                return rev ? 0 : 1
            }
            let lo: Float = black > 0 ? find(black, false) : 0
            let hi: Float = white > 0 ? find(white, true) : 1
            if hi - lo < 1e-3 { return nil }
            return (lo, hi)
        }

        /// Black and White Clip: stretches the new luma so `black`% of pixels reach 0 and `white`% 1.
        static func clipLevels(_ y2: inout [Float], _ px: [SIMD4<Float>], _ black: Float, _ white: Float) {
            if black <= 0 && white <= 0 { return }
            var hist = [UInt32](repeating: 0, count: 4096)
            var n: UInt32 = 0
            for i in 0..<y2.count where px[i].w > 0 {
                hist[Int((clampf(y2[i], 0, 1) * 4095).rounded())] += 1
                n += 1
            }
            guard let (lo, hi) = clipPoints(hist, n, black, white) else { return }
            for i in 0..<y2.count { y2[i] = clampf((y2[i] - lo) / (hi - lo), 0, 1) }
        }

        // MARK: Metal

        static func encode(_ p: ShadowsHighlights, _ pass: GPUPass) throws {
            let b = pass.ctx.bounds
            let (w, h) = (b.width, b.height)
            if b.isEmpty {
                try pass.dispatchOut("pca_copy", params: NoParams())
                return
            }
            let rect = RectParams(b)
            let rgba = try pass.toneRGBA(b)
            let lum = try pass.texture(b)
            try pass.dispatch("pca_tone_sh_lum", params: rect, textures: [rgba, lum], width: w, height: h)
            let scratchA = try pass.texture(b), guideT = try pass.texture(b)
            let guide = try pass.toneGaussBlur(lum, rect: b, sigma: guideSigma, scratch: scratchA, guideT)
            let (sa, ha) = (p.shadowAmount, p.highlightAmount)
            var nbS: (any MTLBuffer)?
            var nbH: (any MTLBuffer)?
            if sa > 0 { nbS = try neighbourhoodGPU(pass, lum: lum, guide: guide, scratch: scratchA, w: w, h: h, radius: p.shadowRadius) }
            if ha > 0 {
                nbH = nbS != nil && abs(p.highlightRadius - p.shadowRadius) < 1e-3 ? nbS
                    : try neighbourhoodGPU(pass, lum: lum, guide: guide, scratch: scratchA, w: w, h: h, radius: p.highlightRadius)
            }
            let ms = try pass.buffer(tonalMask(p.shadowTone)), mh = try pass.buffer(tonalMask(p.highlightTone))
            let y2 = try pass.scratchBuffer(length: w * h * 4)
            let kp = midtoneKP(p.midtone)
            let yp = SHY2Params(width: Int32(w), height: Int32(h), hasS: nbS != nil ? 1 : 0, hasH: nbH != nil ? 1 : 0,
                                ss: strength(sa), hs: strength(ha), midtone: p.midtone, mk: kp.0, mp: kp.1)
            let dummy = try pass.scratchBuffer(length: 16)
            try pass.dispatch("pca_tone_sh_y2", params: yp, textures: [rgba], buffers: [nbS ?? dummy, nbH ?? dummy, ms, mh, y2],
                              width: w, height: h)
            let clip = p.blackClip > 0 || p.whiteClip > 0
            let lohi = try pass.scratchBuffer(length: 16)
            if clip {
                let hist = try pass.scratchBuffer(length: 4097 * 4)
                guard let blit = pass.commandBuffer.makeBlitCommandEncoder() else { throw FilterError.gpuUnavailable("blit") }
                blit.fill(buffer: hist, range: 0..<(4097 * 4), value: 0)
                blit.endEncoding()
                let hp = HistParams(width: Int32(w), count: UInt32(w * h), total: UInt32(histGroups * 256), pad0: 0)
                try pass.dispatch("pca_tone_sh_hist", params: hp, textures: [rgba], buffers: [y2, hist],
                                  width: histGroups * 256, height: 1, threadgroup: (256, 1))
                let cp = ClipParams(black: p.blackClip, white: p.whiteClip, pad0: 0, pad1: 0)
                try pass.dispatch("pca_tone_sh_clip_find", params: cp, textures: [], buffers: [hist, lohi], width: 1, height: 1, threadgroup: (1, 1))
            }
            let g = colorGain(p.color)
            let fp = SHFinalParams(origin: rect.origin, size: rect.size, gainH: g.h, gainUp: g.up ? 1 : 0, clip: clip ? 1 : 0, pad0: 0)
            try pass.dispatchOut("pca_tone_sh_final", params: fp, textures: [pass.src, rgba, pass.dst], buffers: [y2, lohi])
        }

        /// Threadgroups of the grid-stride histogram kernel.
        static let histGroups = 128

        /// `neighbourhood` on the GPU into a `w × h` float buffer.
        static func neighbourhoodGPU(_ pass: GPUPass, lum: any MTLTexture, guide: any MTLTexture, scratch: any MTLTexture,
                                     w: Int, h: Int, radius: Float) throws -> any MTLBuffer {
            let nb = try pass.scratchBuffer(length: w * h * 4)
            guard let (sigma, d, rw, rh) = grid(w, h, radius) else {
                try pass.dispatch("pca_tone_sh_copy_x", params: SHGridParams(w: w, h: h, d: 1, rw: 1, rh: 1, level0: 0),
                                  textures: [guide], buffers: [nb], width: w, height: h)
                return nb
            }
            let gridRect = PixelRect(x: 0, y: 0, width: rw, height: rh)
            let gridT = try pass.texture(gridRect), blurT = try pass.texture(gridRect)
            var level0 = 0
            while level0 < levels {
                let gp = SHGridParams(w: w, h: h, d: d, rw: rw, rh: rh, level0: level0)
                try pass.dispatch("pca_tone_sh_grid", params: gp, textures: [lum, gridT], width: rw, height: rh)
                let blurred = try pass.toneGaussBlur(gridT, rect: gridRect, sigma: sigma / Float(d), scratch: scratch, blurT)
                try pass.dispatch("pca_tone_sh_accum", params: gp, textures: [guide, blurred], buffers: [nb], width: w, height: h)
                level0 += 2
            }
            return nb
        }

        /// MSL `pca_tone_sh_grid_params`.
        struct SHGridParams: BitwiseCopyable {
            var w: Int32, h: Int32, d: Int32, rw: Int32
            var rh: Int32, level0: Int32, levels: Int32, pad0: Int32 = 0
            var step: Float, range: Float, tMax: Float, pad1: Float = 0
            init(w: Int, h: Int, d: Int, rw: Int, rh: Int, level0: Int) {
                self.w = Int32(w); self.h = Int32(h); self.d = Int32(d); self.rw = Int32(rw); self.rh = Int32(rh)
                self.level0 = Int32(level0); levels = Int32(SH.levels); step = SH.step; range = SH.range; tMax = SH.tMax
            }
        }

        /// MSL `pca_tone_sh_y2_params`.
        struct SHY2Params: BitwiseCopyable {
            var width: Int32, height: Int32, hasS: UInt32, hasH: UInt32
            var ss: Float, hs: Float, midtone: Float, mk: Float
            var mp: Float, pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
        }

        /// MSL `pca_tone_hist_params`.
        struct HistParams: BitwiseCopyable {
            var width: Int32, count: UInt32, total: UInt32, pad0: UInt32
        }

        /// MSL `pca_tone_sh_clip_params`.
        struct ClipParams: BitwiseCopyable {
            var black: Float, white: Float, pad0: Float, pad1: Float
        }

        /// MSL `pca_tone_sh_final_params`.
        struct SHFinalParams: BitwiseCopyable {
            var origin: SIMD2<Int32>, size: SIMD2<Int32>
            var gainH: Float, gainUp: UInt32, clip: UInt32, pad0: UInt32
        }
    }
}
