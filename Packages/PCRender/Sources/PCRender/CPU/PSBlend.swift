// Port of photocraft-compose (crates/compose/src/psblend.rs) and photocraft-gpu (compose.wgsl), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Photoshop-exact blend functions where they differ from the generic reference (PCFoundation
// `Blend`), plus the compositing formulas the compositor uses: Fill opacity's "special eight",
// type layers' text gamma, Lab documents' CIELAB Normal mix and 32-bit documents' unclipped blends.
// photocraft keeps the Lab / HDR switches in thread-locals; here they travel as a `BlendSpace`.

import PCFoundation

/// What a plan's buffers hold. Display RGB by default; Lab and CMYK documents composite natively
/// (Photoshop blends in the document's own colour model, measured on the ps-corpus bands):
/// `.lab` buffers hold L/100, (a+128)/255, (b+128)/255; a CMYK document runs as two plans over
/// ink brightness (1 − ink), `.cmykInk` with 1 − C, 1 − M, 1 − Y and `.cmykBlack` with 1 − K.
public enum NativeSpace: UInt8, Hashable, Sendable {
    case none, lab, cmykInk, cmykBlack
}

/// Document-wide blending switches (photocraft's `LAB_MIX` / `HDR` thread-locals).
public struct BlendSpace: Hashable, Sendable {
    /// Lab document composited in display RGB: Normal blending mixes backdrop and source in CIELAB.
    public var lab: Bool
    /// 32-bit float document: Add / Divide and the non-separable modes don't clip at 1.
    public var hdr: Bool
    public var native: NativeSpace
    /// 8-bit document: Linear Light, Hard Light and Soft Light take 128 (not 127.5) as their middle
    /// level, as Photoshop's 8-bit arithmetic does (ps-corpus bands: Linear Light exact in RGB-like,
    /// CMYK and Lab documents, Hard Light 0.24 instead of 0.6 levels; 16-bit documents use ½).
    public var ps8: Bool
    public init(lab: Bool = false, hdr: Bool = false, native: NativeSpace = .none, ps8: Bool = false) {
        self.lab = lab; self.hdr = hdr; self.native = native; self.ps8 = ps8
    }
    public static let srgb = BlendSpace()
}

public enum PSBlend {
    /// Backdrop values within `edge` of 0 / 1 count as exact in Color Burn / Dodge and Hard Mix.
    public static let edge: Float = 1e-4

    /// Photoshop's "Blend Text Colors Using Gamma" default (1 = off).
    public static let textGammaDefault: Float = 1.45

    @inline(__always) static func vividLightPS(_ cb: Float, _ cs: Float) -> Float {
        if cs <= 0.5 {
            if cs <= 0 { return 0 }
            return 1 - min((1 - cb) / (2 * cs), 1)
        }
        if cs >= 1 { return 1 }
        return min(cb / (2 * (1 - cs)), 1)
    }

    @inline(__always) static func colorBurn(_ cb: Float, _ cs: Float) -> Float {
        if cb >= 1 - edge { return 1 }
        if cs <= 0 { return 0 }
        return 1 - min((1 - cb) / cs, 1)
    }

    @inline(__always) static func colorDodge(_ cb: Float, _ cs: Float) -> Float {
        if cb <= edge { return 0 }
        if cs >= 1 { return 1 }
        return min(cb / (1 - cs), 1)
    }

    @inline(__always) static func vividLightGeneric(_ cb: Float, _ cs: Float) -> Float {
        if cs <= 0.5 {
            if cb >= 1 - edge { return 1 }
            if cs <= 0 { return 0 }
            return 1 - min((1 - cb) / (2 * cs), 1)
        }
        if cb <= edge { return 0 }
        if cs >= 1 { return 1 }
        return min(cb / (2 * (1 - cs)), 1)
    }

    @inline(__always) static func hardMixPS(_ cb: Float, _ cs: Float) -> Float {
        vividLightGeneric(cb, cs) >= 0.5 - 1e-6 ? 1 : 0
    }

    /// Soft Light as Photoshop 27 renders it: the W3C definition (ps-corpus soft-light bands at 8
    /// and 16 bits, in CMYK and in Lab fit it within 0.25–0.33 level; photocraft's variant, from
    /// PCFoundation, is 4–10 levels off in the lower half).
    @inline(__always) static func softLight(_ cb: Float, _ cs: Float) -> Float {
        if cs <= 0.5 { return cb - (1 - 2 * cs) * cb * (1 - cb) }
        let d = cb <= 0.25 ? ((16 * cb - 12) * cb + 4) * cb : max(cb, 0).squareRoot()
        return cb + (2 * cs - 1) * (d - cb)
    }

    /// `B(Cb, Cs)` in the blend space: display RGB (`blendRGB`), native Lab (`blendLab`), or a CMYK
    /// plane (1 − ink per channel: Photoshop's CMYK blends are the RGB formulas on ink brightness;
    /// on the black plane the non-separable modes keep the base's K, Luminosity takes the source's).
    @inline(__always)
    public static func blend(_ mode: BlendMode, _ cb: SIMD3<Float>, _ cs: SIMD3<Float>, _ space: BlendSpace) -> SIMD3<Float> {
        switch space.native {
        case .lab: return blendLab(mode, cb, cs, ps8: space.ps8)
        case .cmykBlack:
            switch mode {
            case .hue, .saturation, .color: return cb
            case .luminosity: return cs
            case .darkerColor: return cs.x < cb.x ? cs : cb
            case .lighterColor: return cs.x > cb.x ? cs : cb
            default: break
            }
        default: break
        }
        if space.ps8, let v = mid128(mode, cb, cs, vivid: false) { return v }
        if space.ps8, let v = nonSeparable8(mode, cb, cs) { return v }
        return blendRGB(mode, cb, cs, hdr: space.hdr)
    }

    /// 8-bit Hue, Saturation, Color and Luminosity as Photoshop 27.11 computes them (M1 lattices,
    /// both permutations): on whole levels, luminosity (4915 R + 9667 G + 1802 B + 8192) >> 14
    /// (0.30 / 0.59 / 0.11 in 14-bit fixed point, rounded), SetLum's shift a whole number of
    /// levels, SetSat rounded to levels, ClipColor rounded half up. Exact on every unclipped
    /// pixel; clipped ones within 1 level (the float W3C formulas were 3–4 levels off, 0.1–0.6 %
    /// of pixels beyond 2). 16-bit documents keep the float formulas (exact to 2/65535).
    static func nonSeparable8(_ mode: BlendMode, _ cb: SIMD3<Float>, _ cs: SIMD3<Float>) -> SIMD3<Float>? {
        switch mode {
        case .hue, .saturation, .color, .luminosity: break
        default: return nil
        }
        func q(_ c: SIMD3<Float>) -> SIMD3<Int32> {
            let v = (simd_clamp(c, .zero, SIMD3(repeating: 1)) * 255).rounded(.toNearestOrAwayFromZero)
            return SIMD3(Int32(v.x), Int32(v.y), Int32(v.z))
        }
        let (b, s) = (q(cb), q(cs))
        let r: SIMD3<Int32>
        switch mode {
        case .luminosity: r = setLum8(b, lum8(s))
        case .color: r = setLum8(s, lum8(b))
        case .hue: r = setLum8(setSat8(s, b.max() - b.min()), lum8(b))
        default: r = setLum8(setSat8(b, s.max() - s.min()), lum8(b))
        }
        return SIMD3(Float(r.x), Float(r.y), Float(r.z)) / 255
    }

    /// Photoshop's 8-bit luminosity of whole levels.
    @inline(__always) static func lum8(_ c: SIMD3<Int32>) -> Int32 { (4915 * c.x + 9667 * c.y + 1802 * c.z + 8192) >> 14 }

    /// SetSat on whole levels (rounded half up).
    static func setSat8(_ c: SIMD3<Int32>, _ s: Int32) -> SIMD3<Int32> {
        let (mx, mn) = (c.max(), c.min())
        if mx <= mn { return .zero }
        let d = mx - mn
        var o = SIMD3<Int32>.zero
        for i in 0..<3 { o[i] = (2 * (c[i] - mn) * s + d) / (2 * d) }
        return o
    }

    /// SetLum on whole levels: shift by l − lum, then ClipColor towards l, rounded half up.
    static func setLum8(_ c: SIMD3<Int32>, _ l: Int32) -> SIMD3<Int32> {
        let r = c &+ SIMD3(repeating: l - lum8(c))
        let (n, x) = (r.min(), r.max())
        if n >= 0 && x <= 255 { return r }
        var o = r
        if n < 0 && x > 255 {
            var f = SIMD3<Float>(Float(r.x), Float(r.y), Float(r.z))
            let lf = Float(l)
            for i in 0..<3 { f[i] = lf + (f[i] - lf) * lf / (lf - Float(n)) }
            for i in 0..<3 { f[i] = lf + (f[i] - lf) * (255 - lf) / (Float(x) - lf) }
            for i in 0..<3 { o[i] = Int32((f[i] + 0.5).rounded(.down)) }
        } else if n < 0 {
            let den = l - n
            for i in 0..<3 { o[i] = (2 * l * (r[i] - n) + den) / (2 * den) }
        } else {
            let den = x - l
            for i in 0..<3 { o[i] = (2 * (l * den + (r[i] - l) * (255 - l)) + den) / (2 * den) }
        }
        return simd_clamp(o, SIMD3(repeating: 0), SIMD3(repeating: 255))
    }

    /// The 8-bit variants with 128 as the middle level (see `BlendSpace.ps8`); `vivid` includes
    /// Vivid Light (Lab documents only: elsewhere ½ fits better).
    static func mid128(_ mode: BlendMode, _ cb: SIMD3<Float>, _ cs: SIMD3<Float>, vivid: Bool) -> SIMD3<Float>? {
        let h: Float = 128.0 / 255.0
        func ch(_ b: Float, _ s: Float) -> Float {
            switch mode {
            case .linearLight: return min(max(b + 2 * s - 2 * h, 0), 1)
            case .hardLight: return s <= h ? 2 * b * s : 1 - (1 - b) * (1 - (2 * s - 2 * h))
            case .softLight:
                if s <= h { return b - (1 - 2 * s) * b * (1 - b) }
                let d = b <= 0.25 ? ((16 * b - 12) * b + 4) * b : max(b, 0).squareRoot()
                return b + (2 * s - 2 * h) * (d - b)
            default:
                return s <= h ? colorBurn(b, 2 * s) : colorDodge(b, 2 * s - 2 * h)
            }
        }
        switch mode {
        case .linearLight, .hardLight, .softLight: break
        case .vividLight where vivid: break
        default: return nil
        }
        return SIMD3(ch(cb.x, cs.x), ch(cb.y, cs.y), ch(cb.z, cs.z))
    }

    /// Photoshop's blend modes on Lab channels (L/100, (a+128)/255, (b+128)/255), fitted on the
    /// ps-corpus Lab bands (≤ 1 unit): Multiply / Screen blend L and pull a, b as
    /// `t_b + t_s(1 − |t_b|)` (t = a/128); Linear Dodge / Burn add a, b; Hue keeps L and gives the
    /// source's a, b the base's Chebyshev magnitude max(|a|, |b|), Saturation the reverse; Color
    /// takes a, b, Luminosity L; Darker / Lighter Color compare L; the contrast modes act on every
    /// channel. Darken, Lighten, Color Burn / Dodge, Difference, Exclusion, Subtract and Divide aren't
    /// available in Lab in Photoshop; they act on every channel here.
    public static func blendLab(_ mode: BlendMode, _ cb: SIMD3<Float>, _ cs: SIMD3<Float>, ps8: Bool = false) -> SIMD3<Float> {
        @inline(__always) func t(_ v: Float) -> Float { (v * 255 - 128) / 128 }
        @inline(__always) func v(_ t: Float) -> Float { (t * 128 + 128) / 255 }
        func scaled(_ ab: SIMD2<Float>, _ m: Float) -> SIMD2<Float> {
            let c = max(abs(ab.x), abs(ab.y))
            return c > 0 ? ab * (m / c) : .zero
        }
        switch mode {
        case .normal, .dissolve, .passThrough: return cs
        case .multiply, .screen:
            let l = mode == .multiply ? cb.x * cs.x : cb.x + cs.x - cb.x * cs.x
            let tb = SIMD2(t(cb.y), t(cb.z)), ts = SIMD2(t(cs.y), t(cs.z))
            let o = tb + ts * (SIMD2(repeating: 1) - abs(tb))
            return SIMD3(l, v(o.x), v(o.y))
        case .linearDodge, .linearBurn:
            let l = mode == .linearDodge ? min(cb.x + cs.x, 1) : max(cb.x + cs.x - 1, 0)
            return SIMD3(l, min(max(cb.y + cs.y - 128 / 255, 0), 1), min(max(cb.z + cs.z - 128 / 255, 0), 1))
        case .hue, .saturation, .color, .luminosity:
            let ab = SIMD2(cb.y, cb.z) * 255 - 128, as_ = SIMD2(cs.y, cs.z) * 255 - 128
            let o: SIMD2<Float>
            switch mode {
            case .hue: o = scaled(as_, max(abs(ab.x), abs(ab.y)))
            case .saturation: o = scaled(ab, max(abs(as_.x), abs(as_.y)))
            case .color: o = as_
            default: o = ab
            }
            let n = (o + 128) / 255
            return SIMD3(mode == .luminosity ? cs.x : cb.x, n.x, n.y)
        case .darkerColor: return cs.x < cb.x ? cs : cb
        case .lighterColor: return cs.x > cb.x ? cs : cb
        case .softLight, .hardLight, .vividLight, .linearLight:
            // 8-bit: 128 as the middle level on every channel (≤ 0.26 unit mean; 0.45–1.12 with ½),
            // except Vivid Light's L, which takes ½ (ps-corpus blend-bands-lab-8: exact on opaque
            // band pixels, up to 4 levels off with 128).
            if ps8, var v = mid128(mode, cb, cs, vivid: true) {
                if mode == .vividLight { v.x = vividLightPS(cb.x, cs.x) }
                return v
            }
            return blendRGB(mode, cb, cs, hdr: false)
        default: return blendRGB(mode, cb, cs, hdr: false)
        }
    }

    @inline(__always) static func lum(_ c: SIMD3<Float>) -> Float { 0.3 * c.x + 0.59 * c.y + 0.11 * c.z }

    /// SetSat (W3C).
    static func setSat(_ c: SIMD3<Float>, _ s: Float) -> SIMD3<Float> {
        let mx = c.max(), mn = c.min()
        if mx <= mn { return .zero }
        var o = SIMD3<Float>.zero
        for i in 0..<3 { o[i] = (c[i] - mn) * s / (mx - mn) }
        return o
    }

    /// 32-bit documents: Photoshop 27 clips nothing (ps-corpus blend-bands-rgb-32): Subtract goes
    /// negative and the non-separable modes skip ClipColor altogether (photocraft clips below 0).
    static func blendHDR(_ mode: BlendMode, _ cb: SIMD3<Float>, _ cs: SIMD3<Float>) -> SIMD3<Float>? {
        func setLum(_ c: SIMD3<Float>, _ l: Float) -> SIMD3<Float> { c + (l - lum(c)) }
        switch mode {
        case .subtract: return cb - cs
        case .hue: return setLum(setSat(cs, cb.max() - cb.min()), lum(cb))
        case .saturation: return setLum(setSat(cb, cs.max() - cs.min()), lum(cb))
        case .color: return setLum(cs, lum(cb))
        case .luminosity: return setLum(cb, lum(cs))
        default: return nil
        }
    }

    /// `B(Cb, Cs)` with Photoshop's variants (`psblend::blend_rgb`).
    @inline(__always)
    public static func blendRGB(_ mode: BlendMode, _ cb: SIMD3<Float>, _ cs: SIMD3<Float>, hdr: Bool) -> SIMD3<Float> {
        if hdr, let v = blendHDR(mode, cb, cs) { return v }
        switch mode {
        case .softLight: return SIMD3(softLight(cb.x, cs.x), softLight(cb.y, cs.y), softLight(cb.z, cs.z))
        case .vividLight: return SIMD3(vividLightPS(cb.x, cs.x), vividLightPS(cb.y, cs.y), vividLightPS(cb.z, cs.z))
        case .hardMix: return SIMD3(hardMixPS(cb.x, cs.x), hardMixPS(cb.y, cs.y), hardMixPS(cb.z, cs.z))
        case .colorBurn: return SIMD3(colorBurn(cb.x, cs.x), colorBurn(cb.y, cs.y), colorBurn(cb.z, cs.z))
        case .colorDodge: return SIMD3(colorDodge(cb.x, cs.x), colorDodge(cb.y, cs.y), colorDodge(cb.z, cs.z))
        default: return hdr ? Blend.rgbHDR(mode, cb, cs) : Blend.rgb(mode, cb, cs)
        }
    }

    /// Photoshop's "special eight": Fill isn't just less coverage for these modes.
    @inline(__always) public static func fillIsSpecial(_ mode: BlendMode) -> Bool {
        switch mode {
        case .colorBurn, .linearBurn, .colorDodge, .linearDodge, .vividLight, .linearLight, .hardMix, .difference: true
        default: false
        }
    }

    /// `blend_rgb` for a layer at `fill`: the special eight pull the source toward the mode's neutral.
    public static func blendRGBFill(_ mode: BlendMode, _ cb: SIMD3<Float>, _ cs: SIMD3<Float>, fill: Float, _ space: BlendSpace) -> SIMD3<Float> {
        let f = min(max(fill, 0), 1)
        if f >= 1 || !fillIsSpecial(mode) { return blend(mode, cb, cs, space) }
        func toward(_ n: Float) -> SIMD3<Float> { SIMD3(repeating: n) + (cs - SIMD3(repeating: n)) * f }
        switch mode {
        case .hardMix:
            let v = (cb - f * (SIMD3<Float>(repeating: 1) - cs)) / (1 - f)
            return simd_clamp(v, .zero, SIMD3(repeating: 1))
        case .colorBurn, .linearBurn: return blend(mode, cb, toward(1), space)
        case .vividLight, .linearLight: return blend(mode, cb, toward(0.5), space)
        default: return blend(mode, cb, toward(0), space)
        }
    }

    /// Straight-alpha source over straight-alpha backdrop (`psblend::composite`), Normal mixing in
    /// CIELAB in Lab documents.
    @inline(__always)
    public static func composite(_ mode: BlendMode, _ backdrop: SIMD4<Float>, _ source: SIMD4<Float>, _ opacity: Float, _ space: BlendSpace) -> SIMD4<Float> {
        let ab = backdrop.w
        let as_ = source.w * opacity
        if as_ <= 0 { return backdrop }
        let ao = as_ + ab * (1 - as_)
        if mode == .normal && space.lab && ab > 0 && ao > 0 {
            let lb = ColorConvert.srgbToLab(SIMD3(backdrop.x, backdrop.y, backdrop.z))
            let ls = ColorConvert.srgbToLab(SIMD3(source.x, source.y, source.z))
            let kb = ab * (1 - as_) / ao
            let k = as_ / ao
            let r = ColorConvert.labToSRGB(lb * kb + ls * k)
            return SIMD4(r, ao)
        }
        if mode == .normal { return normalRGB(backdrop, source, as_, ao) }
        let cb = SIMD3(backdrop.x, backdrop.y, backdrop.z)
        let cs = SIMD3(source.x, source.y, source.z)
        let b = blend(mode, cb, cs, space)
        if ao <= 0 { return .zero }
        let rgb = ((1 - as_) * ab * cb + (1 - ab) * as_ * cs + as_ * ab * b) / ao
        return SIMD4(rgb, ao)
    }

    /// Normal mixing outside Lab.
    @inline(__always)
    public static func compositeNormalRGB(_ backdrop: SIMD4<Float>, _ source: SIMD4<Float>, _ opacity: Float) -> SIMD4<Float> {
        let as_ = source.w * opacity
        if as_ <= 0 { return backdrop }
        let ao = as_ + backdrop.w * (1 - as_)
        return normalRGB(backdrop, source, as_, ao)
    }

    @inline(__always) static func normalRGB(_ b: SIMD4<Float>, _ s: SIMD4<Float>, _ as_: Float, _ ao: Float) -> SIMD4<Float> {
        if ao <= 0 { return .zero }
        let kb = b.w * (1 - as_)
        let inv = 1 / ao
        return SIMD4((kb * b.x + as_ * s.x) * inv, (kb * b.y + as_ * s.y) * inv, (kb * b.z + as_ * s.z) * inv, ao)
    }

    /// Into the text blending space: linear light raised to `1 / gamma`.
    @inline(__always) public static func textEncode(_ v: Float, _ gamma: Float) -> Float {
        powf(ColorConvert.srgbToLinear(max(v, 0)), 1 / gamma)
    }

    /// Inverse of `textEncode`.
    @inline(__always) public static func textDecode(_ v: Float, _ gamma: Float) -> Float {
        ColorConvert.linearToSRGB(powf(max(v, 0), gamma))
    }

    /// `composite` with the coverage mix done in the text blending space (`psblend::composite_gamma`).
    public static func compositeGamma(_ mode: BlendMode, _ backdrop: SIMD4<Float>, _ source: SIMD4<Float>, _ opacity: Float,
                                      _ gamma: Float, _ space: BlendSpace) -> SIMD4<Float> {
        if gamma == 1 { return composite(mode, backdrop, source, opacity, space) }
        let ab = backdrop.w
        let as_ = source.w * opacity
        if as_ <= 0 { return backdrop }
        let ao = as_ + ab * (1 - as_)
        if ao <= 0 { return .zero }
        let cb = SIMD3(backdrop.x, backdrop.y, backdrop.z)
        let cs = SIMD3(source.x, source.y, source.z)
        let b = blend(mode, cb, cs, space)
        let (wb, ws, wbs) = ((1 - as_) * ab / ao, (1 - ab) * as_ / ao, as_ * ab / ao)
        var out = SIMD4<Float>(0, 0, 0, ao)
        for i in 0..<3 {
            out[i] = textDecode(wb * textEncode(cb[i], gamma) + ws * textEncode(cs[i], gamma) + wbs * textEncode(b[i], gamma), gamma)
        }
        return out
    }

    /// `composite_gamma` for a layer with separate `opacity` and `fill` (`psblend::composite_fill`).
    public static func compositeFill(_ mode: BlendMode, _ backdrop: SIMD4<Float>, _ source: SIMD4<Float>, opacity: Float,
                                     fill: Float, gamma: Float, _ space: BlendSpace) -> SIMD4<Float> {
        if fill >= 1 || !fillIsSpecial(mode) {
            return compositeGamma(mode, backdrop, source, opacity * min(max(fill, 0), 1), gamma, space)
        }
        let ab = backdrop.w
        let over = source.w * opacity
        let alone = over * min(max(fill, 0), 1)
        if over <= 0 { return backdrop }
        let ao = ab + (1 - ab) * alone
        if ao <= 0 { return .zero }
        let cb = SIMD3(backdrop.x, backdrop.y, backdrop.z)
        let cs = SIMD3(source.x, source.y, source.z)
        let b = blendRGBFill(mode, cb, cs, fill: fill, space)
        let (wb, wbs, ws) = (ab * (1 - over) / ao, ab * over / ao, (1 - ab) * alone / ao)
        var out = SIMD4<Float>(0, 0, 0, ao)
        for i in 0..<3 {
            out[i] = gamma == 1 ? wb * cb[i] + wbs * b[i] + ws * cs[i]
                : textDecode(wb * textEncode(cb[i], gamma) + wbs * textEncode(b[i], gamma) + ws * textEncode(cs[i], gamma), gamma)
        }
        return out
    }

    /// Deterministic hash for Dissolve (document-coordinate based, stable under tiling). `field`
    /// picks an independent field: 0 thresholds opacity (and drives effect noise), 1 Fill, 2 the
    /// mask × pixel coverage — Photoshop's Opacity, Fill and mask patterns are mutually unrelated
    /// (M2: 50 % each pairwise equal on 49.97–50.06 % of pixels, joint coverage 0.260).
    @inline(__always) public static func dissolveNoise(_ x: Int32, _ y: Int32, field: UInt32 = 0) -> Float {
        var h = UInt32(bitPattern: x) &* 0x8da6_b343 ^ UInt32(bitPattern: y) &* 0xd816_3841 ^ (0x9e37_79b9 &+ field &* 0x632b_e5ab)
        h ^= h >> 15
        h = h &* 0x2c1b_3c6d
        h ^= h >> 12
        return Float(h & 0xffff) / 65536
    }

    /// Photoshop 27.11's Dissolve coverage (M2, aggregate only, operator decision AB-D-0130): the
    /// share of pixels drawn at each stored 8-bit opacity, Fill or mask value (`dissolveThreshold`
    /// interpolates it). Fill 50 % and a 50 % mask cover 50.98 / 50.96 %, as Opacity 50 % (51.00 %).
    static let dissolveCoverage: [SIMD2<Float>] = [
        SIMD2(0, 0), SIMD2(3, 0.01492), SIMD2(13, 0.05321), SIMD2(26, 0.10695), SIMD2(51, 0.20588), SIMD2(64, 0.25922),
        SIMD2(77, 0.30899), SIMD2(89, 0.35798), SIMD2(102, 0.40467), SIMD2(115, 0.45699), SIMD2(128, 0.51001), SIMD2(140, 0.55598),
        SIMD2(153, 0.60789), SIMD2(166, 0.65514), SIMD2(179, 0.70874), SIMD2(191, 0.75417), SIMD2(204, 0.80321), SIMD2(217, 0.85335),
        SIMD2(230, 0.90189), SIMD2(242, 0.94902), SIMD2(252, 0.98686), SIMD2(255, 1),
    ]

    /// The noise threshold for coverage `a` (0…1): Photoshop's measured coverage curve, linear
    /// between the measured opacities (our noise fields are uniform, so this is our coverage too).
    @inline(__always) public static func dissolveThreshold(_ a: Float) -> Float {
        let x = (a.isNaN ? 0 : min(max(a, 0), 1)) * 255
        let t = dissolveCoverage
        var i = 1
        while i < t.count - 1 && x > t[i].x { i += 1 }
        let (p, q) = (t[i - 1], t[i])
        return p.y + (q.y - p.y) * (x - p.x) / (q.x - p.x)
    }

    /// Whether Dissolve draws the pixel at (x, y): each of opacity, Fill and the source's coverage
    /// (mask × pixel alpha) thresholded on its own field.
    @inline(__always) public static func dissolveDraws(_ x: Int32, _ y: Int32, opacity: Float, fill: Float, coverage: Float) -> Bool {
        dissolveNoise(x, y, field: 0) < dissolveThreshold(opacity) && dissolveNoise(x, y, field: 1) < dissolveThreshold(fill)
            && dissolveNoise(x, y, field: 2) < dissolveThreshold(coverage)
    }

    /// Premultiplied linear interpolation between two straight-alpha pixels (`effects::mix_premul`).
    @inline(__always) public static func mixPremul(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ k: Float) -> SIMD4<Float> {
        let alpha = a.w + (b.w - a.w) * k
        if alpha <= 0 { return .zero }
        var out = SIMD4<Float>(0, 0, 0, alpha)
        for c in 0..<3 { out[c] = (a[c] * a.w + (b[c] * b.w - a[c] * a.w) * k) / alpha }
        return out
    }

    /// `advanced::mix`: premultiplied mix with colours clamped to 0…1 and alpha to ≤ 1.
    @inline(__always) public static func mixClamped(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ k: Float) -> SIMD4<Float> {
        let alpha = a.w + (b.w - a.w) * k
        if alpha <= 0 { return .zero }
        var out = SIMD4<Float>(0, 0, 0, min(alpha, 1))
        for c in 0..<3 { out[c] = min(max((a[c] * a.w + (b[c] * b.w - a[c] * a.w) * k) / alpha, 0), 1) }
        return out
    }
}

import simd

/// `x.rem_euclid(m)` for floats (Rust semantics: result in [0, |m|)).
@inline(__always) func remEuclid(_ x: Float, _ m: Float) -> Float {
    let r = x.truncatingRemainder(dividingBy: m)
    return r < 0 ? r + abs(m) : r
}
