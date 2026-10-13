// Port of photocraft-algo (crates/algo/src/tone.rs: replace_color, lab_stats, match_color, hdr_toning; selection.rs: color_range), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Destructive tone and colour adjustments that need more than a per-pixel formula (Image ›
// Adjustments): Replace Color, Match Color and HDR Toning (Shadows/Highlights is in its own file).
//
// photocraft runs them on straight (non-premultiplied) RGBA buffers in 0…1, row-major `w × h`;
// `ToneKit.replaceColor` / `matchColor` / `hdrToning` are those functions on `[SIMD4<Float>]`.
// Each is also a `Filter` (`ReplaceColor`, `MatchColorFilter`, `HdrToning`) so it runs on any
// FloatImage through `FilterEngine` — converted to RGBA and back like photocraft-engine's
// `process_surface` (`to_rgba` / `from_rgba`) — with a Metal path for Gray- and RGB-like images.
// The global ones (HDR Toning, Shadows/Highlights) treat the reference bounds as the image.

import Metal
import PCFoundation

// MARK: - Shared RGBA plumbing

extension ToneKit {
    /// Straight RGBA of `src` over `rect` (photocraft `to_rgba` of every pixel; 0 outside `src`).
    static func rgbaPixels(_ src: FloatImage, _ rect: PixelRect, _ ctx: FilterContext) -> [SIMD4<Float>] {
        let img = src.crop(rect)
        let n = img.channels
        var px = [SIMD4<Float>](repeating: .zero, count: rect.area)
        img.data.withUnsafeBufferPointer { d in
            px.withUnsafeMutableBufferPointer { p in
                let ps = UnsafeSendable(p)
                parallelChunks(rect.area, minChunk: 4096) { r in
                    for i in r { ps.value[i] = ctx.rgba(UnsafeBufferPointer(rebasing: d[(i * n)..<(i * n + n)])) }
                }
            }
        }
        return px
    }

    /// `src` cropped to `out`, with the pixels inside `rect` set from the RGBA buffer `px` (which
    /// covers `rect`) — photocraft `from_rgba`.
    static func writeRGBA(_ px: [SIMD4<Float>], _ rect: PixelRect, _ src: FloatImage, _ out: PixelRect, _ ctx: FilterContext) -> FloatImage {
        var res = src.crop(out)
        let inner = out.intersect(rect)
        if inner.isEmpty { return res }
        let n = res.channels
        res.data.withUnsafeMutableBufferPointer { d in
            let ds = UnsafeSendable(d)
            parallelChunks(inner.height, minChunk: 8) { rows in
                for ry in rows {
                    let y = inner.y0 + Int32(ry)
                    for x in inner.x0..<inner.x1 {
                        let o = (Int(y - out.y0) * out.width + Int(x - out.x0)) * n
                        let i = Int(y - rect.y0) * rect.width + Int(x - rect.x0)
                        ctx.setRGBA(UnsafeMutableBufferPointer(rebasing: ds.value[o..<(o + n)]), px[i])
                    }
                }
            }
        }
        return res
    }

    /// Runs `filter` on a straight RGBA buffer through `FilterEngine` (RGB + alpha, bounds = the
    /// buffer) — the GPU entry point of the buffer API.
    static func runRGBA<F: Filter>(_ filter: F, _ px: inout [SIMD4<Float>], w: Int, h: Int, on backend: Backend) throws {
        precondition(px.count == w * h, "buffer is not w × h")
        if px.isEmpty { return }
        let rect = PixelRect(x: 0, y: 0, width: w, height: h)
        var data = [Float](repeating: 0, count: px.count * 4)
        data.withUnsafeMutableBufferPointer { d in
            px.withUnsafeBytes { s in d.baseAddress!.update(from: s.bindMemory(to: Float.self).baseAddress!, count: px.count * 4) }
        }
        let img = FloatImage(rect: rect, channels: 4, data: data)
        let res = try FilterEngine.apply(filter, to: img, output: rect, context: FilterContext(bounds: rect, mode: .rgb, alpha: true), on: backend)
        res.data.withUnsafeBufferPointer { s in
            px.withUnsafeMutableBytes { d in d.bindMemory(to: Float.self).baseAddress!.update(from: s.baseAddress!, count: s.count) }
        }
    }

    /// MSL `pca_tone_rect_params`.
    struct RectParams: BitwiseCopyable {
        var origin: SIMD2<Int32>
        var size: SIMD2<Int32>
        init(_ r: PixelRect) { origin = SIMD2(r.x0, r.y0); size = SIMD2(Int32(r.width), Int32(r.height)) }
    }
}

extension GPUPass {
    /// A float4 texture covering `rect` with the straight RGBA of the source there (photocraft
    /// `to_rgba`: gray replicated, alpha 1 without an alpha channel).
    func toneRGBA(_ rect: PixelRect) throws -> any MTLTexture {
        let t = try texture(rect)
        try dispatch("pca_tone_to_rgba", params: ToneKit.RectParams(rect), textures: [src, t], width: rect.width, height: rect.height)
        return t
    }

    /// One `FxUtil.gaussBlurN` of `tex` (covering `rect`) ping-ponging between `a` and `b` (which
    /// may be larger than `rect`): six box passes, the result in `b` (or `tex` itself when σ < 0.3).
    /// Unlike `encodeGaussBlurN` it allocates nothing, so large images can blur many times.
    func toneGaussBlur(_ tex: any MTLTexture, rect: PixelRect, sigma: Float, scratch a: any MTLTexture, _ b: any MTLTexture) throws -> any MTLTexture {
        if sigma < 0.3 || rect.isEmpty { return tex }
        let radii = FxUtil.gaussBoxRadii(sigma)
        var cur = tex
        var k = 0
        for axis in [Int32(0), 1] {
            for r in radii {
                let o = k % 2 == 0 ? a : b
                try encodeClampedBox(input: cur, output: o, rect: rect, radius: Int32(r), axis: axis)
                cur = o
                k += 1
            }
        }
        return cur
    }

    /// Sum of `.x` of `values` (covering `rect`) over the pixels whose `mask` texel has `.w > 0`,
    /// divided by their count (max 1): writes one float to `result`. Partial sums per 256-pixel
    /// group, then one 256-thread group sums those (photocraft sums sequentially in f32; the tree
    /// is at least as accurate).
    func toneMaskedMean(_ values: any MTLTexture, mask: any MTLTexture, rect: PixelRect, into result: any MTLBuffer) throws {
        let n = rect.area
        let groups = max((n + 255) / 256, 1)
        let sums = try scratchBuffer(length: groups * 4), counts = try scratchBuffer(length: groups * 4)
        let p = ToneKit.ReduceParams(width: Int32(rect.width), count: UInt32(n), groups: UInt32(groups))
        try dispatch("pca_tone_masked_sum", params: p, textures: [values, mask], buffers: [sums, counts],
                     width: groups * 256, height: 1, threadgroup: (256, 1))
        try dispatch("pca_tone_masked_mean_final", params: p, textures: [], buffers: [sums, counts, result],
                     width: 256, height: 1, threadgroup: (256, 1))
    }
}

extension ToneKit {
    /// MSL `pca_tone_reduce_params`.
    struct ReduceParams: BitwiseCopyable {
        var width: Int32
        var count: UInt32
        var groups: UInt32
        var pad0: UInt32 = 0
    }
}

// MARK: - Replace Color

extension ToneKit {
    /// Color Range › Sampled Colors with one sample (photocraft `selection::color_range`): 1 at the
    /// colour, falling linearly to 0 at `fuzziness + 1` levels (largest channel difference ×255);
    /// transparent pixels 0.
    static func colorRange(_ p: SIMD4<Float>, _ color: SIMD3<Float>, _ f: Float) -> Float {
        if p.w <= 0 { return 0 }
        var d: Float = 0
        for c in 0..<3 { d = Float.maximum(d, abs(p[c] - color[c]) * 255) }
        return clampf(1 - d / f, 0, 1)
    }

    /// One pixel of Replace Color with selection weight `k` > 0.
    @inline(__always)
    static func replaceColorPixel(_ q: SIMD4<Float>, _ k: Float, _ hue: Float, _ saturation: Float, _ lightness: Float) -> SIMD4<Float> {
        let c = SIMD3(q.x, q.y, q.z)
        let hsl = rgbToHSL(c)
        let (hh, ss, ll) = (hsl.x, hsl.y, hsl.z)
        let s = saturation >= 0 ? ss + (1 - ss) * saturation / 100 : ss * (1 + saturation / 100)
        let l = lightness >= 0 ? ll + (1 - ll) * lightness / 100 : ll * (1 + lightness / 100)
        let o = hslToRGB(SIMD3(euclidMod(hh + hue / 360, 1), clampf(s, 0, 1), clampf(l, 0, 1)))
        var r = q
        for i in 0..<3 { r[i] = clampf(c[i] + (o[i] - c[i]) * k, 0, 1) }
        return r
    }

    /// Image › Adjustments › Replace Color (photocraft `tone::replace_color`): a Color Range-style
    /// selection (fuzziness 0…200 levels) around `color`, then a hue (±180°), saturation and
    /// lightness (±100) shift weighted by it. Returns the selection mask (the dialog's preview).
    @discardableResult
    public static func replaceColor(_ px: inout [SIMD4<Float>], color: SIMD3<Float>, fuzziness: Float, hue: Float,
                                    saturation: Float, lightness: Float) -> [Float] {
        let f = Float.maximum(fuzziness, 0) + 1
        var mask = [Float](repeating: 0, count: px.count)
        px.withUnsafeMutableBufferPointer { p in
            mask.withUnsafeMutableBufferPointer { m in
                let (ps, ms) = (UnsafeSendable(p), UnsafeSendable(m))
                parallelChunks(p.count, minChunk: 4096) { r in
                    for i in r {
                        let k = colorRange(ps.value[i], color, f)
                        ms.value[i] = k
                        if k > 0 { ps.value[i] = replaceColorPixel(ps.value[i], k, hue, saturation, lightness) }
                    }
                }
            }
        }
        return mask
    }

    /// `replaceColor` on the CPU (`.cpu`) or through the Metal path.
    public static func replaceColor(_ px: inout [SIMD4<Float>], w: Int, h: Int, _ p: ReplaceColor, on backend: Backend) throws {
        if backend == .cpu { replaceColor(&px, color: p.color, fuzziness: p.fuzziness, hue: p.hue, saturation: p.saturation, lightness: p.lightness) }
        else { try runRGBA(p, &px, w: w, h: h, on: backend) }
    }
}

/// Image › Adjustments › Replace Color as a filter (photocraft `tone::replace_color`).
public struct ReplaceColor: Filter, Hashable {
    /// The selected colour, straight sRGB.
    public var color: SIMD3<Float>
    /// 0…200 levels.
    public var fuzziness: Float
    /// ±180°.
    public var hue: Float
    /// ±100.
    public var saturation: Float
    /// ±100.
    public var lightness: Float

    /// photocraft-engine's defaults: fuzziness 40, no shift.
    public init(color: SIMD3<Float>, fuzziness: Float = 40, hue: Float = 0, saturation: Float = 0, lightness: Float = 0) {
        self.color = color; self.fuzziness = fuzziness; self.hue = hue; self.saturation = saturation; self.lightness = lightness
    }

    public var label: String { "Replace Color" }
    public func halo(bounds: PixelRect) -> Halo { .radius(0) }
    public var gpuChannels: GPUChannels { .joint }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        var px = ToneKit.rgbaPixels(src, out, ctx)
        ToneKit.replaceColor(&px, color: color, fuzziness: fuzziness, hue: hue, saturation: saturation, lightness: lightness)
        return ToneKit.writeRGBA(px, out, src, out, ctx)
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let p = ToneKit.ReplaceColorParams(color: SIMD4(color, 0), fuzz: Float.maximum(fuzziness, 0) + 1, hue: hue,
                                           saturation: saturation, lightness: lightness)
        try pass.dispatchOut("pca_tone_replace_color", params: p)
    }
}

extension ToneKit {
    /// MSL `pca_tone_replace_params`.
    struct ReplaceColorParams: BitwiseCopyable {
        var color: SIMD4<Float>
        var fuzz: Float
        var hue: Float
        var saturation: Float
        var lightness: Float
    }
}

// MARK: - Match Color

/// Lab mean and standard deviation of the opaque pixels, `[L, a, b]` each (photocraft `LabStats`).
public struct LabStats: Codable, Sendable, Hashable {
    public var mean: SIMD3<Float>
    public var std: SIMD3<Float>
    public init(mean: SIMD3<Float>, std: SIMD3<Float>) { self.mean = mean; self.std = std }
}

/// Image › Adjustments › Match Color options (photocraft `MatchColor`, Photoshop ranges).
public struct MatchColor: Codable, Sendable, Hashable {
    /// 1…200 (100 = matched luminance).
    public var luminance: Float
    /// Color intensity 1…200 (100 = matched chroma; 1 ≈ gray).
    public var intensity: Float
    /// 0…100: blend back toward the original.
    public var fade: Float
    /// Remove the colour cast (target a/b means → 0).
    public var neutralize: Bool

    public init(luminance: Float = 100, intensity: Float = 100, fade: Float = 0, neutralize: Bool = false) {
        self.luminance = luminance; self.intensity = intensity; self.fade = fade; self.neutralize = neutralize
    }
}

extension ToneKit {
    /// Statistics for Match Color: Lab mean and standard deviation of the pixels weighted by alpha ×
    /// the optional mask (photocraft `tone::lab_stats`); nil when nothing has weight. Accumulates in
    /// Double (chunked in parallel; photocraft sums sequentially in f64 — the difference is far
    /// below f32 precision). This reduction stays on the CPU: one pass, and Match Color needs the
    /// numbers before it can run.
    public static func labStats(_ px: [SIMD4<Float>], mask: [Float]? = nil) -> LabStats? {
        let chunks = max(1, min(64, px.count / 16384))
        let per = (px.count + chunks - 1) / max(chunks, 1)
        var parts = [[Double]](repeating: [Double](repeating: 0, count: 7), count: chunks)
        px.withUnsafeBufferPointer { p in
            parts.withUnsafeMutableBufferPointer { pb in
                let ps = UnsafeSendable(pb)
                parallelFor(chunks) { k in
                    var acc = [Double](repeating: 0, count: 7)
                    let lo = k * per, hi = min(p.count, lo + per)
                    if lo < hi {
                        for i in lo..<hi {
                            let q = p[i]
                            let m: Float = mask.map { i < $0.count ? $0[i] : 0 } ?? 1
                            let w = Double(q.w * m)
                            if w <= 0 { continue }
                            let lab = ColorConvert.srgbToLab(SIMD3(q.x, q.y, q.z))
                            for c in 0..<3 {
                                acc[c] += w * Double(lab[c])
                                acc[3 + c] += w * Double(lab[c]) * Double(lab[c])
                            }
                            acc[6] += w
                        }
                    }
                    ps.value[k] = acc
                }
            }
        }
        var sum = [Double](repeating: 0, count: 7)
        for part in parts { for c in 0..<7 { sum[c] += part[c] } }
        let wsum = sum[6]
        if wsum <= 0 { return nil }
        var mean = SIMD3<Float>(), std = SIMD3<Float>()
        for k in 0..<3 {
            let m = sum[k] / wsum
            mean[k] = Float(m)
            std[k] = Float(max(sum[3 + k] / wsum - m * m, 0).squareRoot())
        }
        return LabStats(mean: mean, std: std)
    }

    /// Lab statistics of a FloatImage over `rect` in any colour model (through sRGB).
    public static func labStats(_ img: FloatImage, rect: PixelRect? = nil, context: FilterContext, mask: [Float]? = nil) -> LabStats? {
        labStats(rgbaPixels(img, rect ?? img.rect, context), mask: mask)
    }

    /// The per-channel scales and destination means of a Match Color transfer.
    static func matchColorPlan(_ target: LabStats, _ source: LabStats?, _ o: MatchColor) -> (scale: SIMD3<Float>, dst: SIMD3<Float>) {
        let src = source ?? target
        var scale = SIMD3<Float>()
        for k in 0..<3 { scale[k] = target.std[k] > 1e-4 ? src.std[k] / target.std[k] : 1 }
        var dst = src.mean
        if o.neutralize { dst[1] = 0; dst[2] = 0 }
        return (scale, dst)
    }

    @inline(__always)
    static func matchColorPixel(_ q: SIMD4<Float>, _ tmean: SIMD3<Float>, _ scale: SIMD3<Float>, _ dst: SIMD3<Float>,
                                _ lum: Float, _ inten: Float, _ fade: Float) -> SIMD4<Float> {
        let c = SIMD3(q.x, q.y, q.z)
        let lab = ColorConvert.srgbToLab(c)
        let l = ((lab.x - tmean.x) * scale.x + dst.x) * lum
        let a = ((lab.y - tmean.y) * scale.y + dst.y) * inten
        let b = ((lab.z - tmean.z) * scale.z + dst.z) * inten
        let o = ColorConvert.labToSRGB(SIMD3(clampf(l, 0, 100), a, b))
        var r = q
        for i in 0..<3 { r[i] = clampf(o[i] + (c[i] - o[i]) * fade, 0, 1) }
        return r
    }

    /// Reinhard-style colour transfer in Lab (photocraft `tone::match_color`): shift and scale each
    /// channel of `px` (statistics `target`) toward `source`'s; with no source only Neutralize /
    /// intensity / luminance act on the image's own statistics.
    public static func matchColor(_ px: inout [SIMD4<Float>], target: LabStats, source: LabStats?, options o: MatchColor) {
        let (scale, dst) = matchColorPlan(target, source, o)
        let lum = o.luminance / 100, inten = o.intensity / 100, fade = clampf(o.fade / 100, 0, 1)
        let tmean = target.mean
        px.withUnsafeMutableBufferPointer { p in
            let ps = UnsafeSendable(p)
            parallelChunks(p.count, minChunk: 4096) { r in
                for i in r where ps.value[i].w > 0 {
                    ps.value[i] = matchColorPixel(ps.value[i], tmean, scale, dst, lum, inten, fade)
                }
            }
        }
    }

    /// `matchColor` on the CPU (`.cpu`) or through the Metal path.
    public static func matchColor(_ px: inout [SIMD4<Float>], w: Int, h: Int, target: LabStats, source: LabStats?,
                                  options: MatchColor, on backend: Backend) throws {
        if backend == .cpu { matchColor(&px, target: target, source: source, options: options) }
        else { try runRGBA(MatchColorFilter(options: options, target: target, source: source), &px, w: w, h: h, on: backend) }
    }
}

/// Image › Adjustments › Match Color as a per-pixel filter: the transfer from statistics computed
/// beforehand (`ToneKit.labStats` of the target layer and of the source).
public struct MatchColorFilter: Filter, Hashable {
    public var options: MatchColor
    /// The statistics of the image being changed.
    public var target: LabStats
    /// The statistics to match (nil: the image's own — Neutralize / Luminance / Intensity only).
    public var source: LabStats?

    public init(options: MatchColor = MatchColor(), target: LabStats, source: LabStats? = nil) {
        self.options = options; self.target = target; self.source = source
    }

    public var label: String { "Match Color" }
    public func halo(bounds: PixelRect) -> Halo { .radius(0) }
    public var gpuChannels: GPUChannels { .joint }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        var px = ToneKit.rgbaPixels(src, out, ctx)
        ToneKit.matchColor(&px, target: target, source: source, options: options)
        return ToneKit.writeRGBA(px, out, src, out, ctx)
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let (scale, dst) = ToneKit.matchColorPlan(target, source, options)
        let p = ToneKit.MatchColorParams(tmean: SIMD4(target.mean, 0), scale: SIMD4(scale, 0), dst: SIMD4(dst, 0),
                                         lum: options.luminance / 100, inten: options.intensity / 100,
                                         fade: clampf(options.fade / 100, 0, 1))
        try pass.dispatchOut("pca_tone_match_color", params: p)
    }
}

extension ToneKit {
    /// MSL `pca_tone_match_params`.
    struct MatchColorParams: BitwiseCopyable {
        var tmean: SIMD4<Float>
        var scale: SIMD4<Float>
        var dst: SIMD4<Float>
        var lum: Float
        var inten: Float
        var fade: Float
        var pad0: Float = 0
    }
}

// MARK: - HDR Toning

/// Image › Adjustments › HDR Toning, "Local Adaptation" (photocraft `HdrToning`): a Durand–Dorsey
/// style base/detail split in log luminance — the blurred log luminance is the base layer,
/// compressed toward its mean by `strength`; detail is boosted; then exposure, gamma,
/// shadow/highlight lift, the toning curve, and saturation/vibrance. As a filter it maps the
/// reference bounds as one image.
public struct HdrToning: Filter, Hashable {
    /// Edge glow radius in px (1…500).
    public var radius: Float
    /// Edge glow strength 0.1…4.
    public var strength: Float
    /// 0.1…2 (1 = neutral; lower = more contrast).
    public var gamma: Float
    /// −5…5 stops.
    public var exposure: Float
    /// −100…300 %.
    public var detail: Float
    public var shadow: Float
    public var highlight: Float
    /// −100…100.
    public var vibrance: Float
    public var saturation: Float
    /// Toning curve on luminance, (input, output) in 0…1; empty = identity.
    public var curve: [SIMD2<Float>]

    public init(radius: Float = 30, strength: Float = 0.5, gamma: Float = 1, exposure: Float = 0, detail: Float = 30,
                shadow: Float = 0, highlight: Float = 0, vibrance: Float = 0, saturation: Float = 20, curve: [SIMD2<Float>] = []) {
        self.radius = radius; self.strength = strength; self.gamma = gamma; self.exposure = exposure; self.detail = detail
        self.shadow = shadow; self.highlight = highlight; self.vibrance = vibrance; self.saturation = saturation; self.curve = curve
    }

    public var label: String { "HDR Toning" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }
    public var gpuChannels: GPUChannels { .joint }

    static let eps: Float = 1e-4

    /// The curve sorted by input (stable, IEEE total order — photocraft's `sort_by(total_cmp)`).
    var sortedCurve: [SIMD2<Float>] {
        curve.enumerated().sorted { a, b in
            if a.element.x.isTotallyOrdered(belowOrEqualTo: b.element.x) && b.element.x.isTotallyOrdered(belowOrEqualTo: a.element.x) {
                return a.offset < b.offset
            }
            return a.element.x.isTotallyOrdered(belowOrEqualTo: b.element.x)
        }.map(\.element)
    }

    /// photocraft `curve_eval`.
    static func curveEval(_ pts: [SIMD2<Float>], _ x: Float) -> Float {
        if pts.count < 2 { return x }
        if x <= pts[0].x { return pts[0].y }
        for i in 0..<(pts.count - 1) {
            let (a, b) = (pts[i], pts[i + 1])
            if x <= b.x {
                let span = Float.maximum(b.x - a.x, 1e-6)
                return a.y + (b.y - a.y) * (x - a.x) / span
            }
        }
        return pts[pts.count - 1].y
    }

    /// The parameters derived once per run.
    struct Plan {
        var compress: Float, detail: Float, exposure: Float, gamma: Float
        var shadow: Float, highlight: Float, saturation: Float, vibrance: Float
        var curve: [SIMD2<Float>]
    }

    var plan: Plan {
        Plan(compress: 1 / (1 + Float.maximum(strength, 0)), detail: 1 + detail / 100, exposure: powf(2, exposure),
             gamma: clampf(gamma, 0.1, 4), shadow: shadow, highlight: highlight, saturation: saturation, vibrance: vibrance,
             curve: sortedCurve)
    }

    /// One pixel's tone map (photocraft `hdr_toning`'s per-pixel body).
    @inline(__always)
    static func map(_ q: SIMD4<Float>, logl: Float, base: Float, mean: Float, _ p: Plan) -> SIMD4<Float> {
        let c = SIMD3(q.x, q.y, q.z)
        let l0 = Float.maximum(ToneKit.luma(c), 0) + eps
        let newLog = mean + (base - mean) * p.compress + (logl - base) * p.detail
        var l1 = powf(Float.maximum(expf(newLog) * p.exposure, 0), 1 / p.gamma)
        let inv = 1 - l1
        l1 += p.shadow / 100 * (inv * inv * inv) * 0.5 - p.highlight / 100 * (l1 * l1 * l1) * 0.5
        l1 = curveEval(p.curve, clampf(l1, 0, 1))
        let ratio = l1 / l0
        var out = SIMD3(c.x * ratio, c.y * ratio, c.z * ratio)
        let ll = ToneKit.luma(out)
        let mx = Float.maximum(Float.maximum(out.x, out.y), out.z), mn = Float.minimum(Float.minimum(out.x, out.y), out.z)
        let satNow: Float = mx > 0 ? (mx - mn) / mx : 0
        let s = 1 + p.saturation / 100 + p.vibrance / 100 * (1 - satNow)
        let sm = Float.maximum(s, 0)
        out = SIMD3(ll + (out.x - ll) * sm, ll + (out.y - ll) * sm, ll + (out.z - ll) * sm)
        return SIMD4(clampf(out.x, 0, 1), clampf(out.y, 0, 1), clampf(out.z, 0, 1), q.w)
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let b = ctx.bounds
        var px = ToneKit.rgbaPixels(src, b, ctx)
        ToneKit.hdrToning(&px, w: b.width, h: b.height, self)
        return ToneKit.writeRGBA(px, b, src, out, ctx)
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let b = pass.ctx.bounds
        if b.isEmpty {
            try pass.dispatchOut("pca_copy", params: NoParams())
            return
        }
        try ToneKit.encodeHdrToning(self, pass, rgba: try pass.toneRGBA(b), rect: b, prescale: nil, encode: false)
    }
}

extension ToneKit {
    /// HDR Toning of the RGBA texture `rgba` (covering `rect`) into the pass output (the source
    /// outside `rect`). With `prescale` (a buffer holding the mean log luminance), colours are
    /// first keyed to middle grey (× 0.18 / exp(mean)); with `encode` the result is sRGB-encoded
    /// (both for Merge to HDR Pro's Local Adaptation).
    static func encodeHdrToning(_ p: HdrToning, _ pass: GPUPass, rgba: any MTLTexture, rect b: PixelRect,
                                prescale: (any MTLBuffer)?, encode: Bool) throws {
        let one = try pass.scratchBuffer(length: 16)
        let lp = HdrLoglParams(origin: SIMD2(b.x0, b.y0), size: SIMD2(Int32(b.width), Int32(b.height)), eps: HdrToning.eps,
                               prescale: prescale != nil ? 1 : 0)
        let logl = try pass.texture(b)
        try pass.dispatch("pca_tone_hdr_logl", params: lp, textures: [rgba, logl], buffers: [prescale ?? one], width: b.width, height: b.height)
        let a = try pass.texture(b), c = try pass.texture(b)
        let base = try pass.toneGaussBlur(logl, rect: b, sigma: Float.maximum(p.radius, 1) / 2, scratch: a, c)
        let mean = try pass.scratchBuffer(length: 16)
        try pass.toneMaskedMean(base, mask: rgba, rect: b, into: mean)
        let pl = p.plan
        let curveBuf = try pass.buffer(pl.curve.isEmpty ? [SIMD2<Float>(0, 0)] : pl.curve)
        let mp = HdrMapParams(origin: SIMD2(b.x0, b.y0), size: SIMD2(Int32(b.width), Int32(b.height)), compress: pl.compress,
                              detail: pl.detail, exposure: pl.exposure, gamma: pl.gamma, shadow: pl.shadow, highlight: pl.highlight,
                              saturation: pl.saturation, vibrance: pl.vibrance, eps: HdrToning.eps, curveCount: Int32(pl.curve.count),
                              prescale: prescale != nil ? 1 : 0, encode: encode ? 1 : 0)
        try pass.dispatchOut("pca_tone_hdr_map", params: mp, textures: [pass.src, rgba, logl, base, pass.dst],
                             buffers: [mean, curveBuf, prescale ?? one])
    }
}

extension ToneKit {
    /// HDR Toning on a straight RGBA buffer `w × h` (photocraft `tone::hdr_toning`).
    public static func hdrToning(_ px: inout [SIMD4<Float>], w: Int, h: Int, _ p: HdrToning) {
        if px.isEmpty { return }
        let eps = HdrToning.eps
        var logl = [Float](repeating: 0, count: px.count)
        px.withUnsafeBufferPointer { q in
            logl.withUnsafeMutableBufferPointer { l in
                let ls = UnsafeSendable(l)
                parallelChunks(q.count, minChunk: 4096) { r in
                    for i in r { ls.value[i] = logf(Float.maximum(luma(SIMD3(q[i].x, q[i].y, q[i].z)), 0) + eps) }
                }
            }
        }
        var base = logl
        FxUtil.gaussBlurN(&base, w, h, 1, Float.maximum(p.radius, 1) / 2)
        // Sequential f32 sum, as photocraft.
        var count = 0
        var sum: Float = 0
        for i in 0..<px.count where px[i].w > 0 { sum += base[i]; count += 1 }
        let mean = sum / Float(max(count, 1))
        let plan = p.plan
        px.withUnsafeMutableBufferPointer { q in
            let qs = UnsafeSendable(q)
            parallelChunks(q.count, minChunk: 4096) { r in
                for i in r where qs.value[i].w > 0 {
                    qs.value[i] = HdrToning.map(qs.value[i], logl: logl[i], base: base[i], mean: mean, plan)
                }
            }
        }
    }

    /// `hdrToning` on the CPU (`.cpu`) or through the Metal path.
    public static func hdrToning(_ px: inout [SIMD4<Float>], w: Int, h: Int, _ p: HdrToning, on backend: Backend) throws {
        if backend == .cpu { hdrToning(&px, w: w, h: h, p) } else { try runRGBA(p, &px, w: w, h: h, on: backend) }
    }

    /// MSL `pca_tone_hdr_logl_params`.
    struct HdrLoglParams: BitwiseCopyable {
        var origin: SIMD2<Int32>
        var size: SIMD2<Int32>
        var eps: Float
        var prescale: UInt32
        var pad1: Float = 0
        var pad2: Float = 0
    }

    /// MSL `pca_tone_hdr_map_params`.
    struct HdrMapParams: BitwiseCopyable {
        var origin: SIMD2<Int32>
        var size: SIMD2<Int32>
        var compress: Float
        var detail: Float
        var exposure: Float
        var gamma: Float
        var shadow: Float
        var highlight: Float
        var saturation: Float
        var vibrance: Float
        var eps: Float
        var curveCount: Int32
        var prescale: UInt32
        var encode: UInt32
    }
}
