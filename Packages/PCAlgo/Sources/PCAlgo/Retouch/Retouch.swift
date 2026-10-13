// Port of photocraft-algo (crates/algo/src/retouch.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Per-pixel and per-dab kernels of the toning and focus retouching tools: Dodge, Burn, Sponge,
// Blur, Sharpen. The brush engine decides where and how strongly each dab applies; these decide
// what happens to the pixels. CPU only: they run per brush dab on small windows (a GPU brush
// engine would inline the same maths in its dab shader).

import Foundation

/// Tonal range targeted by Dodge/Burn.
public enum ToneRange: String, Codable, Sendable, Hashable, CaseIterable { case shadows, midtones, highlights }

public enum Retouch {
    /// Rec. 601 luma of a straight RGB triple.
    @inline(__always) public static func luma(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }

    /// The dodge/burn transfer for one value `v` (0…1) with strength `e` (0…1).
    public static func toneCurve(_ v0: Float, _ e0: Float, _ range: ToneRange, burn: Bool) -> Float {
        let v = max(v0, 0), e = clampf(e0, 0, 1)
        switch (range, burn) {
        case (.midtones, false):
            let w = clampf(4 * v * (1 - v), 0, 1)
            return v + w * (powf(min(v, 1), 1 / (1 + e)) - v)
        case (.midtones, true):
            let w = clampf(4 * v * (1 - v), 0, 1)
            return v + w * (powf(min(v, 1), 1 + e) - v)
        case (.shadows, false): let q = 1 - min(v, 1); return v + e * (q * q) * q
        case (.shadows, true): let q = 1 - min(v, 1); return v - e * (q * q) * v
        case (.highlights, false): let q = min(v, 1); return v + e * (q * q) * (1 - q)
        case (.highlights, true): let q = min(v, 1); return v - e * (q * q) * v
        }
    }

    /// Back into 0…1 keeping luma (mix toward grey) instead of clipping each channel.
    static func compressGamut(_ c: SIMD3<Float>, _ l0: Float) -> SIMD3<Float> {
        let l = clampf(l0, 0, 1)
        let lo = min(c.x, c.y, c.z), hi = max(c.x, c.y, c.z)
        var t: Float = 1
        if hi > 1 && hi - l > 1e-9 { t = min(t, (1 - l) / (hi - l)) }
        if lo < 0 && l - lo > 1e-9 { t = min(t, l / (l - lo)) }
        return SIMD3(l + (c.x - l) * t, l + (c.y - l) * t, l + (c.z - l) * t)
    }

    /// Dodge (`burn` false) or Burn one straight-RGB colour with strength `e` (0…1). With
    /// `protectTones` the curve applies to luma and the colour is scaled to it (hue kept,
    /// gamut-compressed); otherwise each channel goes through the curve.
    public static func dodgeBurn(_ c: SIMD3<Float>, _ e: Float, _ range: ToneRange, burn: Bool, protectTones: Bool) -> SIMD3<Float> {
        if e <= 0 { return c }
        if protectTones {
            let l = luma(c)
            let nl = toneCurve(l, e, range, burn: burn)
            let out = l > 1e-6 ? SIMD3(c.x * nl / l, c.y * nl / l, c.z * nl / l) : SIMD3(repeating: nl)
            return compressGamut(out, nl)
        }
        return SIMD3(toneCurve(c.x, e, range, burn: burn), toneCurve(c.y, e, range, burn: burn), toneCurve(c.z, e, range, burn: burn))
    }

    /// HSV-style saturation (chroma / max).
    public static func saturation(_ c: SIMD3<Float>) -> Float {
        let lo = min(c.x, c.y, c.z), hi = max(c.x, c.y, c.z)
        return hi <= 1e-6 ? 0 : clampf((hi - lo) / hi, 0, 1)
    }

    /// Sponge: move a colour away from (`saturate`) or toward its luma grey by `amount` (0…1);
    /// `vibrance` damps the change where it would clip.
    public static func sponge(_ c: SIMD3<Float>, _ amount: Float, saturate: Bool, vibrance: Bool) -> SIMD3<Float> {
        var a = clampf(amount, 0, 1)
        if a <= 0 { return c }
        let s = saturation(c)
        if vibrance { a *= saturate ? 1 - s : 0.25 + 0.75 * s }
        let l = luma(c)
        let k = saturate ? 1 + a : 1 - a
        return compressGamut(SIMD3(l + (c.x - l) * k, l + (c.y - l) * k, l + (c.z - l) * k), l)
    }

    /// Gaussian blur of the window `[x0, x1) × [y0, y1)` of an interleaved `w × h × ch` buffer
    /// (edges clamped; colour premultiplied by the `alpha` channel when given).
    public static func localBlur(_ data: [Float], width w: Int, height h: Int, channels ch: Int, alpha: Int?,
                                 window win: (Int, Int, Int, Int), sigma: Float) -> [Float] {
        let (x0, y0, x1, y1) = win
        let ow = x1 - x0, oh = y1 - y0
        let r = Int32(max((sigma * 3).rounded(.up), 1))
        var k = (-r...r).map { i in expf(-Float(i * i) / max(2 * sigma * sigma, 1e-6)) }
        var ks: Float = 0
        for v in k { ks += v }
        k = k.map { $0 / ks }
        func get(_ x: Int32, _ y: Int32, _ out: inout [Float]) {
            let xx = Int(min(max(x, 0), Int32(w - 1))), yy = Int(min(max(y, 0), Int32(h - 1)))
            let i = (yy * w + xx) * ch
            for c in 0..<ch { out[c] = data[i + c] }
            if let a = alpha { let av = out[a]; for c in 0..<ch where c != a { out[c] *= av } }
        }
        let th = oh + 2 * Int(r)
        var tmp = [Float](repeating: 0, count: ow * th * ch)
        var px = [Float](repeating: 0, count: ch)
        for ty in 0..<th {
            let y = Int32(y0) + Int32(ty) - r
            for ox in 0..<ow {
                let o = (ty * ow + ox) * ch
                for (i, kv) in k.enumerated() {
                    get(Int32(x0 + ox + i) - r, y, &px)
                    for c in 0..<ch { tmp[o + c] += px[c] * kv }
                }
            }
        }
        var out = [Float](repeating: 0, count: ow * oh * ch)
        for oy in 0..<oh {
            for ox in 0..<ow {
                let o = (oy * ow + ox) * ch
                for (i, kv) in k.enumerated() {
                    let s = ((oy + i) * ow + ox) * ch
                    for c in 0..<ch { out[o + c] += tmp[s + c] * kv }
                }
                if let a = alpha {
                    let av = out[o + a]
                    for c in 0..<ch where c != a {
                        out[o + c] = av > 1e-6 ? out[o + c] / av : data[((y0 + oy) * w + x0 + ox) * ch + c]
                    }
                }
            }
        }
        return out
    }

    /// Unsharp-mask sharpen of a window: `v + amount·(v − blur(v))` (σ 1); with `protectDetail`
    /// each result is clamped to its 3×3 neighbourhood's range. Alpha is left unchanged.
    public static func localSharpen(_ data: [Float], width w: Int, height h: Int, channels ch: Int, alpha: Int?,
                                    window win: (Int, Int, Int, Int), amount: Float, protectDetail: Bool) -> [Float] {
        let (x0, y0, x1, y1) = win
        let ow = x1 - x0
        let blur = localBlur(data, width: w, height: h, channels: ch, alpha: alpha, window: win, sigma: 1)
        var out = [Float](repeating: 0, count: blur.count)
        for y in y0..<y1 {
            for x in x0..<x1 {
                let o = ((y - y0) * ow + (x - x0)) * ch, i = (y * w + x) * ch
                for c in 0..<ch {
                    let v = data[i + c]
                    if c == alpha { out[o + c] = v; continue }
                    var s = v + amount * (v - blur[o + c])
                    if protectDetail {
                        var lo = v, hi = v
                        for (dx, dy) in [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)] {
                            let nx = min(max(x + dx, 0), w - 1), ny = min(max(y + dy, 0), h - 1)
                            let nv = data[(ny * w + nx) * ch + c]
                            lo = Float.minimum(lo, nv); hi = Float.maximum(hi, nv)
                        }
                        s = clampf(s, lo, hi)
                    }
                    out[o + c] = s
                }
            }
        }
        return out
    }
}
