// Port of photocraft-compose (crates/compose/src/psblend.rs, adjust.rs) and photocraft-gpu (compose.wgsl), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Shared MSL for every PCRender kernel: the per-dispatch uniform record (mirrored by `PCROp` in
// MetalKernels.swift), colour conversions matching PCFoundation's `ColorConvert`, Photoshop's blend
// variants over foundation's `pc_blend_rgb`, and the compositing formulas of `PSBlend`.
// PCBlend.metal (foundation) is prepended by `MetalContext.library(bundle:key:)`.

struct PCROp {
    int2 origin;        // document pixel of the accumulators' texel (0, 0)
    int2 offset;        // accumulator texel of thread (0, 0)
    int2 size;          // threads that run (the rest return)
    uint mode;          // blend mode (BlendMode.rawValue)
    uint flags;
    float opacity;
    float fill;
    float gamma;        // text gamma (1 = off)
    float density;      // pixel-mask density
    int2 maskOrigin;    // pixel (or combined) mask texture placement
    int2 maskSize;
    int2 vmaskOrigin;   // vector-mask coverage texture placement
    int2 vmaskSize;
    float maskDefault;  // pixel mask value outside its texture
    float vmaskOutside; // coverage outside its texture
    int2 leafOrigin;    // leaf / pattern / map texture placement
    int2 leafSize;
    int2 mapOrigin;
    int2 mapSize;
    int2 aux;           // kernel-specific integers
    float4 leafOutside; // leaf value outside its texture
    float4 color;
    float4 p[8];
};

constant uint PCR_F_MASK = 1u;        // a pixel (or combined) mask is bound
constant uint PCR_F_VMASK = 2u;       // a vector-mask coverage is bound
constant uint PCR_F_COMBINED = 4u;    // the mask texture holds final values (no density)
constant uint PCR_F_DENSITY = 8u;     // apply density (< 1)
constant uint PCR_F_LEAF = 16u;       // a leaf texture is bound
constant uint PCR_F_LAB = 32u;        // Lab document: Normal mixes in CIELAB
constant uint PCR_F_HDR = 64u;        // 32-bit document: unclipped Add / Divide / non-separable
constant uint PCR_F_ATOP = 128u;      // effects: clipped layer over an opaque base
constant uint PCR_F_OWN = 256u;       // finish: the layer's own colours are bound
constant uint PCR_F_CHANNELS = 512u;  // finish: channel restrictions in p[0]
constant uint PCR_F_BLENDIF = 1024u;  // finish: Blend If ranges in the buffer
constant uint PCR_F_RGBMODE = 2048u;  // finish: RGB document (Gray + R, G, B ranges)
constant uint PCR_F_CLIPALPHA = 4096u;// knockout: alpha can't grow
constant uint PCR_F_DITHER = 8192u;   // gradient fill: dither
constant uint PCR_F_QUANT = 16384u;   // gradient fill dither rounded to p[1].x steps
constant uint PCR_F_NLAB = 1u << 25;  // native Lab buffers (L/100, (a+128)/255, (b+128)/255): Lab blend rules
constant uint PCR_F_KPLANE = 1u << 26;// CMYK black plane (1 − K): non-separable modes keep base / take source K

// Blend space bits (`pcr_sp`): 32-bit document, native Lab, CMYK black plane.
constant uint PCR_SP_HDR = 1u, PCR_SP_LAB = 2u, PCR_SP_K = 4u, PCR_SP_8 = 8u;
constant uint PCR_F_PS8 = 1u << 27;   // 8-bit document: 128 as the middle level (Linear / Hard / Soft Light)

inline bool pcr_inside(int2 p, int2 size) { return p.x >= 0 && p.y >= 0 && p.x < size.x && p.y < size.y; }

/// Pixel-mask value × vector coverage at document pixel `d` (`compose::mask_vals`).
inline float pcr_mask(constant PCROp& op, texture2d<float, access::read> mtex, texture2d<float, access::read> vtex, int2 d) {
    float m = 1.0f;
    if ((op.flags & PCR_F_MASK) != 0u) {
        int2 q = d - op.maskOrigin;
        float v = op.maskDefault;
        if (pcr_inside(q, op.maskSize)) v = mtex.read(uint2(q)).r;
        if ((op.flags & PCR_F_COMBINED) == 0u && (op.flags & PCR_F_DENSITY) != 0u) v = 1.0f - op.density * (1.0f - v);
        m = v;
    }
    if ((op.flags & PCR_F_VMASK) != 0u) {
        int2 q = d - op.vmaskOrigin;
        float v = op.vmaskOutside;
        if (pcr_inside(q, op.vmaskSize)) v = vtex.read(uint2(q)).r;
        m = ((op.flags & PCR_F_MASK) != 0u) ? m * v : v;
    }
    return m;
}

/// A leaf's RGBA at document pixel `d` (its outside value beyond its texture).
inline float4 pcr_leaf(constant PCROp& op, texture2d<float, access::read> tex, int2 d) {
    if ((op.flags & PCR_F_LEAF) != 0u) {
        int2 q = d - op.leafOrigin;
        if (pcr_inside(q, op.leafSize)) return tex.read(uint2(q));
    }
    return op.leafOutside;
}

/// Thread → (accumulator texel, document pixel); false for threads past the dispatch.
inline bool pcr_coords(constant PCROp& op, uint2 gid, thread uint2& t, thread int2& d) {
    if (int(gid.x) >= op.size.x || int(gid.y) >= op.size.y) return false;
    int2 l = int2(gid) + op.offset;
    t = uint2(l);
    d = l + op.origin;
    return true;
}

// ---- colour (PCFoundation ColorConvert) ----------------------------------------------------

inline float pcr_srgb_to_linear(float v) { return v <= 0.04045f ? v / 12.92f : pow((v + 0.055f) / 1.055f, 2.4f); }
inline float pcr_linear_to_srgb(float v) { return v <= 0.0031308f ? v * 12.92f : 1.055f * pow(v, 1.0f / 2.4f) - 0.055f; }

constant float3 PCR_D50 = float3(0.96422f, 1.0f, 0.82521f);

inline float3 pcr_srgb_to_lab(float3 c) {
    float3 lin = float3(pcr_srgb_to_linear(c.r), pcr_srgb_to_linear(c.g), pcr_srgb_to_linear(c.b));
    float3 xyz = float3(0.436074f * lin.r + 0.385064f * lin.g + 0.143080f * lin.b,
                        0.222504f * lin.r + 0.716878f * lin.g + 0.060618f * lin.b,
                        0.013932f * lin.r + 0.097104f * lin.g + 0.714173f * lin.b) / PCR_D50;
    const float e = 6.0f / 29.0f;
    float3 f;
    for (int i = 0; i < 3; i++) f[i] = xyz[i] > e * e * e ? pow(xyz[i], 1.0f / 3.0f) : xyz[i] / (3.0f * e * e) + 4.0f / 29.0f;
    return float3(116.0f * f.y - 16.0f, 500.0f * (f.x - f.y), 200.0f * (f.y - f.z));
}

inline float3 pcr_lab_to_srgb(float3 lab) {
    float fy = (lab.x + 16.0f) / 116.0f;
    float fx = fy + lab.y / 500.0f;
    float fz = fy - lab.z / 200.0f;
    const float e = 6.0f / 29.0f;
    float3 t = float3(fx, fy, fz);
    float3 xyz;
    for (int i = 0; i < 3; i++) xyz[i] = t[i] > e ? t[i] * t[i] * t[i] : 3.0f * e * e * (t[i] - 4.0f / 29.0f);
    xyz *= PCR_D50;
    float3 lin = float3(3.133856f * xyz.x - 1.616867f * xyz.y - 0.490615f * xyz.z,
                        -0.978768f * xyz.x + 1.916142f * xyz.y + 0.033454f * xyz.z,
                        0.071945f * xyz.x - 0.228991f * xyz.y + 1.405243f * xyz.z);
    return float3(pcr_linear_to_srgb(clamp(lin.r, 0.0f, 1.0f)), pcr_linear_to_srgb(clamp(lin.g, 0.0f, 1.0f)),
                  pcr_linear_to_srgb(clamp(lin.b, 0.0f, 1.0f)));
}

inline float pcr_gray(float3 c) { return 0.299f * c.r + 0.587f * c.g + 0.114f * c.b; }

inline float pcr_rem_euclid(float x, float m) {
    float r = fmod(x, m);
    return r < 0.0f ? r + fabs(m) : r;
}

/// Interpolated lookup in a 0…1 table of `n` entries (`AdjustMath.lut`: a(1 − f) + b f).
inline float pcr_lut(device const float* t, int n, float v) {
    float x = (isnan(v) ? 0.0f : clamp(v, 0.0f, 1.0f)) * float(n - 1);
    int i = int(floor(x));
    int j = min(i + 1, n - 1);
    float f = x - float(i);
    return t[i] * (1.0f - f) + t[j] * f;
}

/// Interpolated lookup in a 0…1 table (`EffectMath.lutAt`: a + (b − a) f).
inline float pcr_lut_at(device const float* t, int n, float v) {
    float x = (isnan(v) ? 0.0f : clamp(v, 0.0f, 1.0f)) * float(n - 1);
    int i = int(floor(x));
    int j = min(i + 1, n - 1);
    return t[i] + (t[j] - t[i]) * (x - float(i));
}

// ---- blending (PSBlend) -----------------------------------------------------------------------

constant float PCR_EDGE = 1e-4f;

inline float pcr_color_burn(float cb, float cs) {
    if (cb >= 1.0f - PCR_EDGE) return 1.0f;
    if (cs <= 0.0f) return 0.0f;
    return 1.0f - min((1.0f - cb) / cs, 1.0f);
}
inline float pcr_color_dodge(float cb, float cs) {
    if (cb <= PCR_EDGE) return 0.0f;
    if (cs >= 1.0f) return 1.0f;
    return min(cb / (1.0f - cs), 1.0f);
}
inline float pcr_vivid_light_ps(float cb, float cs) {
    if (cs <= 0.5f) {
        if (cs <= 0.0f) return 0.0f;
        return 1.0f - min((1.0f - cb) / (2.0f * cs), 1.0f);
    }
    if (cs >= 1.0f) return 1.0f;
    return min(cb / (2.0f * (1.0f - cs)), 1.0f);
}
inline float pcr_vivid_light_generic(float cb, float cs) {
    if (cs <= 0.5f) {
        if (cb >= 1.0f - PCR_EDGE) return 1.0f;
        if (cs <= 0.0f) return 0.0f;
        return 1.0f - min((1.0f - cb) / (2.0f * cs), 1.0f);
    }
    if (cb <= PCR_EDGE) return 0.0f;
    if (cs >= 1.0f) return 1.0f;
    return min(cb / (2.0f * (1.0f - cs)), 1.0f);
}

/// Soft Light as Photoshop 27 renders it (the W3C definition; ps-corpus soft light bands at 8, 16
/// bits and in CMYK / Lab: 0.25–0.33 level mean; photocraft's lower-half variant is 4–10 off).
inline float pcr_soft_light(float cb, float cs) {
    if (cs <= 0.5f) return cb - (1.0f - 2.0f * cs) * cb * (1.0f - cb);
    float dd = cb <= 0.25f ? ((16.0f * cb - 12.0f) * cb + 4.0f) * cb : sqrt(max(cb, 0.0f));
    return cb + (2.0f * cs - 1.0f) * (dd - cb);
}

inline float pcr_lum3(float3 c) { return 0.3f * c.x + 0.59f * c.y + 0.11f * c.z; }
inline float3 pcr_set_sat(float3 c, float s) {
    float mx = max(max(c.x, c.y), c.z), mn = min(min(c.x, c.y), c.z);
    if (mx <= mn) return float3(0.0f);
    return (c - mn) * s / (mx - mn);
}

/// `PSBlend.blendHDR`: 32-bit documents clip nothing.
inline float3 pcr_blend_hdr(uint mode, float3 cb, float3 cs) {
    switch (mode) {
        case PC_SUBTRACT: return cb - cs;
        case PC_HUE: { float3 c = pcr_set_sat(cs, max(max(cb.x, cb.y), cb.z) - min(min(cb.x, cb.y), cb.z)); return c + (pcr_lum3(cb) - pcr_lum3(c)); }
        case PC_SATURATION: { float3 c = pcr_set_sat(cb, max(max(cs.x, cs.y), cs.z) - min(min(cs.x, cs.y), cs.z)); return c + (pcr_lum3(cb) - pcr_lum3(c)); }
        case PC_COLOR: return cs + (pcr_lum3(cb) - pcr_lum3(cs));
        default: return cb + (pcr_lum3(cs) - pcr_lum3(cb));
    }
}

/// `B(Cb, Cs)` with Photoshop's variants (`PSBlend.blendRGB`).
inline float3 pcr_blend_rgb_ps(uint mode, float3 cb, float3 cs, bool hdr) {
    if (hdr && (mode == PC_SUBTRACT || mode == PC_HUE || mode == PC_SATURATION || mode == PC_COLOR || mode == PC_LUMINOSITY)) return pcr_blend_hdr(mode, cb, cs);
    switch (mode) {
        case PC_VIVID_LIGHT: return float3(pcr_vivid_light_ps(cb.r, cs.r), pcr_vivid_light_ps(cb.g, cs.g), pcr_vivid_light_ps(cb.b, cs.b));
        case PC_HARD_MIX: {
            float3 o;
            // `PSBlend.hardMixPS`: on the tie (cb + cs = 1) 1 below a ½ blend value, 0 above.
            for (int i = 0; i < 3; i++) {
                float v = pcr_vivid_light_generic(cb[i], cs[i]);
                o[i] = cs[i] > 0.5f ? (v > 0.5f + 1e-6f ? 1.0f : 0.0f) : (v >= 0.5f - 1e-6f ? 1.0f : 0.0f);
            }
            return o;
        }
        case PC_COLOR_BURN: return float3(pcr_color_burn(cb.r, cs.r), pcr_color_burn(cb.g, cs.g), pcr_color_burn(cb.b, cs.b));
        case PC_COLOR_DODGE: return float3(pcr_color_dodge(cb.r, cs.r), pcr_color_dodge(cb.g, cs.g), pcr_color_dodge(cb.b, cs.b));
        case PC_SOFT_LIGHT: return float3(pcr_soft_light(cb.r, cs.r), pcr_soft_light(cb.g, cs.g), pcr_soft_light(cb.b, cs.b));
        default: return pc_blend_rgb(mode, cb, cs, hdr ? FLT_MAX : 1.0f);
    }
}

inline float pcr_lab_t(float v) { return (v * 255.0f - 128.0f) / 128.0f; }
inline float pcr_lab_v(float t) { return (t * 128.0f + 128.0f) / 255.0f; }

/// `a, b` scaled to Chebyshev magnitude `m` (a-units, centred).
inline float2 pcr_lab_scale(float2 ab, float m) {
    float c = max(abs(ab.x), abs(ab.y));
    return c > 0.0f ? ab * (m / c) : float2(0.0f);
}

/// `PSBlend.mid128`: the 8-bit variants with 128 as the middle level.
inline float pcr_mid128(uint mode, float b, float s) {
    const float h = 128.0f / 255.0f;
    if (mode == PC_LINEAR_LIGHT) return clamp(b + 2.0f * s - 2.0f * h, 0.0f, 1.0f);
    if (mode == PC_HARD_LIGHT) return s <= h ? 2.0f * b * s : 1.0f - (1.0f - b) * (1.0f - (2.0f * s - 2.0f * h));
    if (mode == PC_SOFT_LIGHT) {
        if (s <= h) return b - (1.0f - 2.0f * s) * b * (1.0f - b);
        float dd = b <= 0.25f ? ((16.0f * b - 12.0f) * b + 4.0f) * b : sqrt(max(b, 0.0f));
        return b + (2.0f * s - 2.0f * h) * (dd - b);
    }
    return s <= h ? pcr_color_burn(b, 2.0f * s) : pcr_color_dodge(b, 2.0f * s - 2.0f * h);
}
inline float3 pcr_mid128_rgb(uint mode, float3 cb, float3 cs) {
    return float3(pcr_mid128(mode, cb.x, cs.x), pcr_mid128(mode, cb.y, cs.y), pcr_mid128(mode, cb.z, cs.z));
}

/// `PSBlend.blendLab`: Photoshop's blend modes on Lab channels (see the Swift reference).
inline float3 pcr_blend_lab(uint mode, float3 cb, float3 cs, bool ps8) {
    switch (mode) {
        case PC_NORMAL: case PC_DISSOLVE: return cs;
        case PC_MULTIPLY: case PC_SCREEN: {
            float l = mode == PC_MULTIPLY ? cb.x * cs.x : cb.x + cs.x - cb.x * cs.x;
            float3 o = float3(l, 0.0f, 0.0f);
            for (int i = 1; i < 3; i++) {
                float tb = pcr_lab_t(cb[i]), ts = pcr_lab_t(cs[i]);
                o[i] = pcr_lab_v(tb + ts * (1.0f - abs(tb)));
            }
            return o;
        }
        case PC_LINEAR_DODGE: case PC_LINEAR_BURN: {
            float l = mode == PC_LINEAR_DODGE ? min(cb.x + cs.x, 1.0f) : max(cb.x + cs.x - 1.0f, 0.0f);
            float3 o = float3(l, 0.0f, 0.0f);
            for (int i = 1; i < 3; i++) o[i] = clamp(cb[i] + cs[i] - 128.0f / 255.0f, 0.0f, 1.0f);
            return o;
        }
        case PC_HUE: case PC_SATURATION: case PC_COLOR: case PC_LUMINOSITY: {
            float2 ab = float2(cb.y, cb.z) * 255.0f - 128.0f, as = float2(cs.y, cs.z) * 255.0f - 128.0f;
            float2 o;
            if (mode == PC_HUE) o = pcr_lab_scale(as, max(abs(ab.x), abs(ab.y)));
            else if (mode == PC_SATURATION) o = pcr_lab_scale(ab, max(abs(as.x), abs(as.y)));
            else if (mode == PC_COLOR) o = as;
            else o = ab;
            o = (o + 128.0f) / 255.0f;
            return float3(mode == PC_LUMINOSITY ? cs.x : cb.x, o.x, o.y);
        }
        case PC_DARKER_COLOR: return cs.x < cb.x ? cs : cb;
        case PC_LIGHTER_COLOR: return cs.x > cb.x ? cs : cb;
        case PC_SOFT_LIGHT: case PC_HARD_LIGHT: case PC_VIVID_LIGHT: case PC_LINEAR_LIGHT:
            if (ps8) {
                float3 v = pcr_mid128_rgb(mode, cb, cs);
                if (mode == PC_VIVID_LIGHT) v.x = pcr_vivid_light_ps(cb.x, cs.x);  // L: ½ as the middle
                return v;
            }
            return pcr_blend_rgb_ps(mode, cb, cs, false);
        default: return pcr_blend_rgb_ps(mode, cb, cs, false);
    }
}

/// `PSBlend.lum8 / setSat8 / setLum8 / nonSeparable8`: Photoshop's 8-bit Hue, Saturation, Color
/// and Luminosity on whole levels.
inline int pcr_lum8(int3 c) { return (4915 * c.x + 9667 * c.y + 1802 * c.z + 8192) >> 14; }
inline int3 pcr_set_sat8(int3 c, int s) {
    int mx = max(max(c.x, c.y), c.z), mn = min(min(c.x, c.y), c.z);
    if (mx <= mn) return int3(0);
    int d = mx - mn;
    return (2 * (c - mn) * s + d) / (2 * d);
}
inline int3 pcr_set_lum8(int3 c, int l) {
    int3 r = c + (l - pcr_lum8(c));
    int n = min(min(r.x, r.y), r.z), x = max(max(r.x, r.y), r.z);
    if (n >= 0 && x <= 255) return r;
    int3 o;
    if (n < 0 && x > 255) {
        float3 f = float3(r);
        float lf = float(l);
        f = lf + (f - lf) * lf / (lf - float(n));
        f = lf + (f - lf) * (255.0f - lf) / (float(x) - lf);
        o = int3(floor(f + 0.5f));
    } else if (n < 0) {
        int den = l - n;
        o = (2 * l * (r - n) + den) / (2 * den);
    } else {
        int den = x - l;
        o = (2 * (l * den + (r - l) * (255 - l)) + den) / (2 * den);
    }
    return clamp(o, int3(0), int3(255));
}
inline float3 pcr_nonsep8(uint mode, float3 cb, float3 cs) {
    int3 b = int3(round(clamp(cb, 0.0f, 1.0f) * 255.0f)), s = int3(round(clamp(cs, 0.0f, 1.0f) * 255.0f));
    int3 r;
    if (mode == PC_LUMINOSITY) r = pcr_set_lum8(b, pcr_lum8(s));
    else if (mode == PC_COLOR) r = pcr_set_lum8(s, pcr_lum8(b));
    else if (mode == PC_HUE) r = pcr_set_lum8(pcr_set_sat8(s, max(max(b.x, b.y), b.z) - min(min(b.x, b.y), b.z)), pcr_lum8(b));
    else r = pcr_set_lum8(pcr_set_sat8(b, max(max(s.x, s.y), s.z) - min(min(s.x, s.y), s.z)), pcr_lum8(b));
    return float3(r) / 255.0f;
}

/// `PSBlend.blend`: the blend in the document's working space.
inline float3 pcr_blend_rgb(uint mode, float3 cb, float3 cs, uint sp) {
    if ((sp & PCR_SP_LAB) != 0u) return pcr_blend_lab(mode, cb, cs, (sp & PCR_SP_8) != 0u);
    if ((sp & PCR_SP_K) != 0u) {
        switch (mode) {
            case PC_HUE: case PC_SATURATION: case PC_COLOR: return cb;
            case PC_LUMINOSITY: return cs;
            case PC_DARKER_COLOR: return cs.x < cb.x ? cs : cb;
            case PC_LIGHTER_COLOR: return cs.x > cb.x ? cs : cb;
            default: break;
        }
    }
    if ((sp & PCR_SP_8) != 0u && (mode == PC_LINEAR_LIGHT || mode == PC_HARD_LIGHT || mode == PC_SOFT_LIGHT)) return pcr_mid128_rgb(mode, cb, cs);
    if ((sp & PCR_SP_8) != 0u && (mode == PC_HUE || mode == PC_SATURATION || mode == PC_COLOR || mode == PC_LUMINOSITY)) return pcr_nonsep8(mode, cb, cs);
    return pcr_blend_rgb_ps(mode, cb, cs, (sp & PCR_SP_HDR) != 0u);
}

inline uint pcr_sp(constant PCROp& op) {
    return ((op.flags & PCR_F_HDR) != 0u ? PCR_SP_HDR : 0u) | ((op.flags & PCR_F_NLAB) != 0u ? PCR_SP_LAB : 0u) | ((op.flags & PCR_F_KPLANE) != 0u ? PCR_SP_K : 0u)
         | ((op.flags & PCR_F_PS8) != 0u ? PCR_SP_8 : 0u);
}

inline bool pcr_fill_is_special(uint m) {
    return m == PC_COLOR_BURN || m == PC_LINEAR_BURN || m == PC_COLOR_DODGE || m == PC_LINEAR_DODGE || m == PC_VIVID_LIGHT ||
           m == PC_LINEAR_LIGHT || m == PC_HARD_MIX || m == PC_DIFFERENCE;
}

inline float3 pcr_blend_rgb_fill(uint mode, float3 cb, float3 cs, float fill, uint sp) {
    float f = clamp(fill, 0.0f, 1.0f);
    if (f >= 1.0f || !pcr_fill_is_special(mode)) return pcr_blend_rgb(mode, cb, cs, sp);
    if (mode == PC_HARD_MIX) return clamp((cb - f * (float3(1.0f) - cs)) / (1.0f - f), float3(0.0f), float3(1.0f));
    float n = 0.0f;
    if (mode == PC_COLOR_BURN || mode == PC_LINEAR_BURN) n = 1.0f;
    if (mode == PC_VIVID_LIGHT || mode == PC_LINEAR_LIGHT) n = 0.5f;
    return pcr_blend_rgb(mode, cb, float3(n) + (cs - float3(n)) * f, sp);
}

inline float4 pcr_normal_rgb(float4 b, float4 s, float as, float ao) {
    if (ao <= 0.0f) return float4(0.0f);
    float kb = b.a * (1.0f - as);
    float inv = 1.0f / ao;
    return float4((kb * b.r + as * s.r) * inv, (kb * b.g + as * s.g) * inv, (kb * b.b + as * s.b) * inv, ao);
}

/// `PSBlend.composite`.
inline float4 pcr_composite(uint mode, float4 b, float4 s, float opacity, bool lab, uint sp) {
    float ab = b.a;
    float as = s.a * opacity;
    if (as <= 0.0f) return b;
    float ao = as + ab * (1.0f - as);
    if (mode == PC_NORMAL && lab && ab > 0.0f && ao > 0.0f) {
        float3 lb = pcr_srgb_to_lab(b.rgb), ls = pcr_srgb_to_lab(s.rgb);
        float kb = ab * (1.0f - as) / ao;
        float k = as / ao;
        return float4(pcr_lab_to_srgb(lb * kb + ls * k), ao);
    }
    if (mode == PC_NORMAL) return pcr_normal_rgb(b, s, as, ao);
    float3 bl = pcr_blend_rgb(mode, b.rgb, s.rgb, sp);
    if (ao <= 0.0f) return float4(0.0f);
    return float4(((1.0f - as) * ab * b.rgb + (1.0f - ab) * as * s.rgb + as * ab * bl) / ao, ao);
}

inline float pcr_text_enc(float v, float g) { return pow(pcr_srgb_to_linear(max(v, 0.0f)), 1.0f / g); }
inline float pcr_text_dec(float v, float g) { return pcr_linear_to_srgb(pow(max(v, 0.0f), g)); }

/// `PSBlend.compositeGamma`.
inline float4 pcr_composite_gamma(uint mode, float4 b, float4 s, float opacity, float gamma, bool lab, uint sp) {
    if (gamma == 1.0f) return pcr_composite(mode, b, s, opacity, lab, sp);
    float ab = b.a;
    float as = s.a * opacity;
    if (as <= 0.0f) return b;
    float ao = as + ab * (1.0f - as);
    if (ao <= 0.0f) return float4(0.0f);
    float3 bl = pcr_blend_rgb(mode, b.rgb, s.rgb, sp);
    float wb = (1.0f - as) * ab / ao, ws = (1.0f - ab) * as / ao, wbs = as * ab / ao;
    float4 o = float4(0.0f, 0.0f, 0.0f, ao);
    for (int i = 0; i < 3; i++) {
        o[i] = pcr_text_dec(wb * pcr_text_enc(b[i], gamma) + ws * pcr_text_enc(s[i], gamma) + wbs * pcr_text_enc(bl[i], gamma), gamma);
    }
    return o;
}

/// `PSBlend.compositeFill`.
inline float4 pcr_composite_fill(uint mode, float4 b, float4 s, float opacity, float fill, float gamma, bool lab, uint sp) {
    if (fill >= 1.0f || !pcr_fill_is_special(mode)) return pcr_composite_gamma(mode, b, s, opacity * clamp(fill, 0.0f, 1.0f), gamma, lab, sp);
    float ab = b.a;
    float over = s.a * opacity;
    float alone = over * clamp(fill, 0.0f, 1.0f);
    if (over <= 0.0f) return b;
    float ao = ab + (1.0f - ab) * alone;
    if (ao <= 0.0f) return float4(0.0f);
    float3 bl = pcr_blend_rgb_fill(mode, b.rgb, s.rgb, fill, sp);
    float wb = ab * (1.0f - over) / ao, wbs = ab * over / ao, ws = (1.0f - ab) * alone / ao;
    float4 o = float4(0.0f, 0.0f, 0.0f, ao);
    for (int i = 0; i < 3; i++) {
        o[i] = gamma == 1.0f ? wb * b[i] + wbs * bl[i] + ws * s[i]
            : pcr_text_dec(wb * pcr_text_enc(b[i], gamma) + wbs * pcr_text_enc(bl[i], gamma) + ws * pcr_text_enc(s[i], gamma), gamma);
    }
    return o;
}

inline float pcr_dissolve_noise(int2 d, uint field = 0u) {
    uint h = (uint(d.x) * 0x8da6b343u) ^ (uint(d.y) * 0xd8163841u) ^ (0x9e3779b9u + field * 0x632be5abu);
    h ^= h >> 15;
    h *= 0x2c1b3c6du;
    h ^= h >> 12;
    return float(h & 0xffffu) / 65536.0f;
}

/// `PSBlend.dissolveThreshold`: Photoshop's measured Dissolve coverage per 8-bit value.
constant float2 pcr_dissolve_cov[22] = {
    float2(0, 0), float2(3, 0.01492), float2(13, 0.05321), float2(26, 0.10695), float2(51, 0.20588), float2(64, 0.25922),
    float2(77, 0.30899), float2(89, 0.35798), float2(102, 0.40467), float2(115, 0.45699), float2(128, 0.51001), float2(140, 0.55598),
    float2(153, 0.60789), float2(166, 0.65514), float2(179, 0.70874), float2(191, 0.75417), float2(204, 0.80321), float2(217, 0.85335),
    float2(230, 0.90189), float2(242, 0.94902), float2(252, 0.98686), float2(255, 1),
};
inline float pcr_dissolve_threshold(float a) {
    float x = (isnan(a) ? 0.0f : clamp(a, 0.0f, 1.0f)) * 255.0f;
    int i = 1;
    while (i < 21 && x > pcr_dissolve_cov[i].x) i++;
    float2 p = pcr_dissolve_cov[i - 1], q = pcr_dissolve_cov[i];
    return p.y + (q.y - p.y) * (x - p.x) / (q.x - p.x);
}
/// `PSBlend.dissolveDraws`.
inline bool pcr_dissolve_draws(int2 d, float opacity, float fill, float coverage) {
    return pcr_dissolve_noise(d, 0u) < pcr_dissolve_threshold(opacity) && pcr_dissolve_noise(d, 1u) < pcr_dissolve_threshold(fill)
        && pcr_dissolve_noise(d, 2u) < pcr_dissolve_threshold(coverage);
}

inline float4 pcr_mix_premul(float4 a, float4 b, float k) {
    float alpha = a.a + (b.a - a.a) * k;
    if (alpha <= 0.0f) return float4(0.0f);
    return float4((a.rgb * a.a + (b.rgb * b.a - a.rgb * a.a) * k) / alpha, alpha);
}

/// `advanced::mix`: colours clamped to 0…1, alpha to ≤ 1.
inline float4 pcr_mix_clamped(float4 a, float4 b, float k) {
    float alpha = a.a + (b.a - a.a) * k;
    if (alpha <= 0.0f) return float4(0.0f);
    return float4(clamp((a.rgb * a.a + (b.rgb * b.a - a.rgb * a.a) * k) / alpha, float3(0.0f), float3(1.0f)), min(alpha, 1.0f));
}

inline float4 pcr_premul(float4 p) { return float4(p.rgb * p.a, p.a); }
