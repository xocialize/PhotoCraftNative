// Blend-mode maths in MSL, matching PCFoundation's `Blend` (Swift) one for one.
// Port of photocraft-color's blend.rs and the blend section of photocraft-gpu's compose.wgsl,
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Mode numbers are `BlendMode.rawValue`; never reorder.

#include <metal_stdlib>
using namespace metal;

// No fused multiply-add contraction anywhere in the library: with it, ~26% of GPU multiply-adds
// differ from the Swift reference (PCPaint, measured). Ports that need bit-exact parity also use
// precise::sqrt (fast sqrt differed on ~32% of inputs).
#pragma METAL fp contract(off)

#define PC_PASS_THROUGH 0u
#define PC_NORMAL 1u
#define PC_DISSOLVE 2u
#define PC_DARKEN 3u
#define PC_MULTIPLY 4u
#define PC_COLOR_BURN 5u
#define PC_LINEAR_BURN 6u
#define PC_DARKER_COLOR 7u
#define PC_LIGHTEN 8u
#define PC_SCREEN 9u
#define PC_COLOR_DODGE 10u
#define PC_LINEAR_DODGE 11u
#define PC_LIGHTER_COLOR 12u
#define PC_OVERLAY 13u
#define PC_SOFT_LIGHT 14u
#define PC_HARD_LIGHT 15u
#define PC_VIVID_LIGHT 16u
#define PC_LINEAR_LIGHT 17u
#define PC_PIN_LIGHT 18u
#define PC_HARD_MIX 19u
#define PC_DIFFERENCE 20u
#define PC_EXCLUSION 21u
#define PC_SUBTRACT 22u
#define PC_DIVIDE 23u
#define PC_HUE 24u
#define PC_SATURATION 25u
#define PC_COLOR 26u
#define PC_LUMINOSITY 27u
#define PC_REFLECT 28u
#define PC_GLOW 29u
#define PC_NEGATION 30u
#define PC_XOR 31u
#define PC_PDN_COLOR_BURN 32u
#define PC_PDN_COLOR_DODGE 33u

inline float pc_color_burn(float cb, float cs) {
    if (cb >= 1.0f) return 1.0f;
    if (cs <= 0.0f) return 0.0f;
    return 1.0f - min((1.0f - cb) / cs, 1.0f);
}

inline float pc_color_dodge(float cb, float cs) {
    if (cb <= 0.0f) return 0.0f;
    if (cs >= 1.0f) return 1.0f;
    return min(cb / (1.0f - cs), 1.0f);
}

inline float pc_hard_light(float cb, float cs) {
    if (cs <= 0.5f) return cb * 2.0f * cs;
    float s = 2.0f * cs - 1.0f;
    return cb + s - cb * s;
}

// Soft Light as Photoshop 27 renders it: the W3C definition (see Blend.softLightPS).
inline float pc_soft_light_ps(float cb, float cs) {
    if (cs <= 0.5f) return cb - (1.0f - 2.0f * cs) * cb * (1.0f - cb);
    float d = cb <= 0.25f ? ((16.0f * cb - 12.0f) * cb + 4.0f) * cb : precise::sqrt(max(cb, 0.0f));
    return cb + (2.0f * cs - 1.0f) * (d - cb);
}

inline float pc_reflect(float cb, float cs) { return cs >= 1.0f ? 1.0f : min(cb * cb / (1.0f - cs), 1.0f); }

inline float pc_vivid_hard_mix(float cb, float cs) {
    const float edge = 1e-4f;
    if (cs <= 0.5f) {
        if (cb >= 1.0f - edge) return 1.0f;
        if (cs <= 0.0f) return 0.0f;
        return 1.0f - min((1.0f - cb) / (2.0f * cs), 1.0f);
    }
    if (cb <= edge) return 0.0f;
    if (cs >= 1.0f) return 1.0f;
    return min(cb / (2.0f * (1.0f - cs)), 1.0f);
}

/// Separable `B(cb, cs)`; `hi` is 1 at integer depths, FLT_MAX in 32-bit documents.
inline float pc_blend_channel(uint mode, float cb, float cs, float hi) {
    switch (mode) {
        case PC_DARKEN: return min(cb, cs);
        case PC_MULTIPLY: return cb * cs;
        case PC_COLOR_BURN: return pc_color_burn(cb, cs);
        case PC_LINEAR_BURN: return max(cb + cs - 1.0f, 0.0f);
        case PC_LIGHTEN: return max(cb, cs);
        case PC_SCREEN: return cb + cs - cb * cs;
        case PC_COLOR_DODGE: return pc_color_dodge(cb, cs);
        case PC_LINEAR_DODGE: return min(cb + cs, hi);
        case PC_OVERLAY: return pc_hard_light(cs, cb);
        case PC_SOFT_LIGHT: return pc_soft_light_ps(cb, cs);
        case PC_HARD_LIGHT: return pc_hard_light(cb, cs);
        case PC_VIVID_LIGHT:
            if (cs <= 0.0f) return 0.0f;
            if (cs >= 1.0f) return 1.0f;
            return cs <= 0.5f ? pc_color_burn(cb, 2.0f * cs) : pc_color_dodge(cb, 2.0f * (cs - 0.5f));
        case PC_LINEAR_LIGHT: return clamp(cb + 2.0f * cs - 1.0f, 0.0f, 1.0f);
        case PC_PIN_LIGHT: return cs <= 0.5f ? min(cb, 2.0f * cs) : max(cb, 2.0f * cs - 1.0f);
        case PC_HARD_MIX: return pc_vivid_hard_mix(cb, cs) >= 0.5f - 1e-6f ? 1.0f : 0.0f;
        case PC_DIFFERENCE: return fabs(cb - cs);
        case PC_EXCLUSION: return cb + cs - 2.0f * cb * cs;
        case PC_SUBTRACT: return hi > 1.0f ? cb - cs : max(cb - cs, 0.0f);   // 32-bit: unclipped
        case PC_DIVIDE:
            if (cs <= 0.0f) return cb <= 0.0f ? 0.0f : 1.0f;
            return min(cb / cs, hi);
        case PC_REFLECT: return pc_reflect(cb, cs);
        case PC_GLOW: return pc_reflect(cs, cb);
        case PC_NEGATION: return 1.0f - fabs(1.0f - cb - cs);
        case PC_XOR: {
            uint b = uint(rint(clamp(cb, 0.0f, 1.0f) * 255.0f));
            uint s = uint(rint(clamp(cs, 0.0f, 1.0f) * 255.0f));
            return float(b ^ s) / 255.0f;
        }
        case PC_PDN_COLOR_BURN: return cs <= 0.0f ? 0.0f : max(1.0f - (1.0f - cb) / cs, 0.0f);
        case PC_PDN_COLOR_DODGE: return cs >= 1.0f ? 1.0f : min(cb / (1.0f - cs), 1.0f);
        default: return cs;  // Normal, Dissolve, Pass Through; non-separable handled by pc_blend_rgb
    }
}

inline float pc_lum(float3 c) { return 0.3f * c.r + 0.59f * c.g + 0.11f * c.b; }

inline float3 pc_clip_color(float3 c, float top) {
    float l = pc_lum(c);
    float n = min(min(c.r, c.g), c.b);
    float x = max(max(c.r, c.g), c.b);
    float3 out = c;
    if (n < 0.0f) {
        float d = l - n;
        out = (l > 0.0f && d > 0.0f) ? l + (out - l) * l / d : float3(l);
    }
    if (x > top) {
        float d = x - l;
        out = (l < top && d > 0.0f) ? l + (out - l) * (top - l) / d : float3(l);
    }
    return out;
}

inline float3 pc_set_lum(float3 c, float l, float top) { return pc_clip_color(c + (l - pc_lum(c)), top); }

inline float pc_sat(float3 c) { return max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b); }

inline float3 pc_set_sat(float3 c, float s) {
    // Stable sort of the three indices by value (ties keep index order, as Swift's sort on [0,1,2]).
    int i0 = 0, i1 = 1, i2 = 2;
    if (c[i1] < c[i0]) { int t = i0; i0 = i1; i1 = t; }
    if (c[i2] < c[i1]) { int t = i1; i1 = i2; i2 = t; }
    if (c[i1] < c[i0]) { int t = i0; i0 = i1; i1 = t; }
    float3 out = float3(0.0f);
    if (c[i2] > c[i0]) {
        out[i1] = (c[i1] - c[i0]) * s / (c[i2] - c[i0]);
        out[i2] = s;
    }
    out[i0] = 0.0f;
    return out;
}

/// `B(Cb, Cs)` on RGB including the non-separable modes, clipping at `top`. `top` > 1 selects the
/// 32-bit rules (Blend.rgbHDR): no ClipColor on the non-separable modes, unclipped Subtract.
inline float3 pc_blend_rgb(uint mode, float3 cb, float3 cs, float top) {
    if (top > 1.0f) {
        switch (mode) {
            case PC_HUE: { float3 c = pc_set_sat(cs, pc_sat(cb)); return c + (pc_lum(cb) - pc_lum(c)); }
            case PC_SATURATION: { float3 c = pc_set_sat(cb, pc_sat(cs)); return c + (pc_lum(cb) - pc_lum(c)); }
            case PC_COLOR: return cs + (pc_lum(cb) - pc_lum(cs));
            case PC_LUMINOSITY: return cb + (pc_lum(cs) - pc_lum(cb));
            default: break;
        }
    }
    switch (mode) {
        case PC_HUE: return pc_set_lum(pc_set_sat(cs, pc_sat(cb)), pc_lum(cb), top);
        case PC_SATURATION: return pc_set_lum(pc_set_sat(cb, pc_sat(cs)), pc_lum(cb), top);
        case PC_COLOR: return pc_set_lum(cs, pc_lum(cb), top);
        case PC_LUMINOSITY: return pc_set_lum(cb, pc_lum(cs), top);
        case PC_DARKER_COLOR: return pc_lum(cs) < pc_lum(cb) ? cs : cb;
        case PC_LIGHTER_COLOR: return pc_lum(cs) > pc_lum(cb) ? cs : cb;
        default: {
            float hi = top > 1.0f ? FLT_MAX : 1.0f;
            return float3(pc_blend_channel(mode, cb.r, cs.r, hi), pc_blend_channel(mode, cb.g, cs.g, hi),
                          pc_blend_channel(mode, cb.b, cs.b, hi));
        }
    }
}

/// Straight-alpha source over straight-alpha backdrop (W3C/PDF general formula), as `Blend.composite`.
inline float4 pc_composite(uint mode, float4 backdrop, float4 source, float opacity) {
    float ab = backdrop.a;
    float as = source.a * opacity;
    if (as <= 0.0f) return backdrop;
    float3 cb = backdrop.rgb, cs = source.rgb;
    float3 b = pc_blend_rgb(mode, cb, cs, 1.0f);
    float ao = as + ab * (1.0f - as);
    if (ao <= 0.0f) return float4(0.0f);
    float3 premul = (1.0f - as) * ab * cb + (1.0f - ab) * as * cs + as * ab * b;
    return float4(premul / ao, ao);
}

/// Position-hash dither noise in [0, 1), as `ColorConvert.ditherNoise`.
inline float pc_dither_noise(int x, int y) {
    uint h = (uint(x) * 0x9E3779B1u) ^ (uint(y) * 0x85EBCA77u);
    h ^= h >> 15;
    h *= 0x2C1B3C6Du;
    h ^= h >> 12;
    return float(h & 0xFFFFu) / 65535.0f;
}
