// Port of photocraft-compose (crates/compose/src/adjust.rs) and photocraft-gpu (compose.wgsl `adjust`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Adjustment kernels, specialised per adjustment kind with a function constant (the WGSL
// `override` / photocraft's "specialised pipelines per adjustment"). Parameters arrive in op.p,
// tables (tone LUTs, hue-range tables, stops, 3D LUTs) in buffer(1), each 4096-entry row
// contiguous; formulas mirror `PreparedAdjustment` / `AdjustMath` one for one.

constant uint pcr_adjust_kind [[function_constant(0)]];

#define PCR_LUTN 4096

inline float pcr_t_decode(float v, float g) {
    if (g <= 0.0f) return pcr_srgb_to_linear(max(v, 0.0f));
    if (g == 1.0f) return max(v, 0.0f);
    return pow(max(v, 0.0f), g);
}
inline float pcr_t_encode(float v, float g) {
    if (g <= 0.0f) return pcr_linear_to_srgb(max(v, 0.0f));
    if (g == 1.0f) return max(v, 0.0f);
    return pow(max(v, 0.0f), 1.0f / g);
}

inline float pcr_posterize(float v, float n) {
    float x = round(clamp(v, 0.0f, 1.0f) * 255.0f);
    float bin = min(floor(x * n / 256.0f), n - 1.0f);
    return floor(bin * 255.0f / (n - 1.0f)) / 255.0f;
}

/// Light Brightness/Contrast (`AdjustMath.lightTone`): sRGB → linear ProPhoto, four stages (lut +
/// i·4096, mode p0[i]: 0 skip, 1 RGB tone on linear channels, 2 RGB tone on sRGB-encoded channels,
/// 3 the curve's change at the encoded mean added to every channel), back to sRGB; lut + 4·4096:
/// ProPhoto ← sRGB rows, then sRGB ← ProPhoto rows.
inline float3 pcr_light_rgb_tone(float3 u, device const float* t, bool linear) {
    float mx = max(max(u.r, u.g), u.b), mn = min(min(u.r, u.g), u.b);
    float tmx, tmn;
    if (linear) {
        tmx = pcr_srgb_to_linear(pcr_lut(t, PCR_LUTN, pcr_linear_to_srgb(max(mx, 0.0f))));
        tmn = pcr_srgb_to_linear(pcr_lut(t, PCR_LUTN, pcr_linear_to_srgb(max(mn, 0.0f))));
    } else {
        tmx = pcr_lut(t, PCR_LUTN, mx);
        tmn = pcr_lut(t, PCR_LUTN, mn);
    }
    return mx > mn ? float3(tmn) + (u - float3(mn)) * ((tmx - tmn) / (mx - mn)) : float3(tmx);
}
inline float3 pcr_enc3(float3 v) { return float3(pcr_linear_to_srgb(max(v.r, 0.0f)), pcr_linear_to_srgb(max(v.g, 0.0f)), pcr_linear_to_srgb(max(v.b, 0.0f))); }
inline float3 pcr_dec3(float3 v) { return float3(pcr_srgb_to_linear(max(v.r, 0.0f)), pcr_srgb_to_linear(max(v.g, 0.0f)), pcr_srgb_to_linear(max(v.b, 0.0f))); }
inline float3 pcr_light_tone(float3 c, device const float* t, float4 modes) {
    device const float* m = t + 4 * PCR_LUTN;
    float3 l0 = float3(pcr_srgb_to_linear(clamp(c.r, 0.0f, 1.0f)), pcr_srgb_to_linear(clamp(c.g, 0.0f, 1.0f)), pcr_srgb_to_linear(clamp(c.b, 0.0f, 1.0f)));
    float3 l = float3(m[0] * l0.r + m[1] * l0.g + m[2] * l0.b, m[3] * l0.r + m[4] * l0.g + m[5] * l0.b, m[6] * l0.r + m[7] * l0.g + m[8] * l0.b);
    for (int i = 0; i < 4; i++) {
        device const float* row = t + i * PCR_LUTN;
        int mode = int(modes[i] + 0.5f);
        if (mode == 1) {
            l = pcr_light_rgb_tone(max(l, float3(0.0f)), row, true);
        } else if (mode == 2) {
            l = pcr_dec3(pcr_light_rgb_tone(pcr_enc3(l), row, false));
        } else if (mode == 3) {
            float3 u = pcr_enc3(l);
            float k = (u.r + u.g + u.b) / 3.0f;
            l = pcr_dec3(u + float3(pcr_lut(row, PCR_LUTN, k) - k));
        }
    }
    device const float* n = m + 9;
    float3 s = float3(n[0] * l.r + n[1] * l.g + n[2] * l.b, n[3] * l.r + n[4] * l.g + n[5] * l.b, n[6] * l.r + n[7] * l.g + n[8] * l.b);
    return float3(pcr_linear_to_srgb(clamp(s.r, 0.0f, 1.0f)), pcr_linear_to_srgb(clamp(s.g, 0.0f, 1.0f)), pcr_linear_to_srgb(clamp(s.b, 0.0f, 1.0f)));
}

inline float pcr_legacy(float v, float4 p) { return clamp((v + p.x - p.z) * p.y + p.z + p.w, 0.0f, 1.0f); }

inline float pcr_levels_float(device const float* r, float v) {
    float t = (v - r[0]) / max(r[1] - r[0], 1e-6f);
    if (r[2] != 1.0f) t = copysign(pow(fabs(t), 1.0f / max(r[2], 0.01f)), t);
    return r[3] + t * (r[4] - r[3]);
}

inline float3 pcr_rgb_to_hsl(float3 c) {
    float mx = max(max(c.r, c.g), c.b), mn = min(min(c.r, c.g), c.b);
    float l = (mx + mn) / 2.0f;
    if (fabs(mx - mn) < 1e-7f) return float3(0.0f, 0.0f, l);
    float d = mx - mn;
    float s = l > 0.5f ? d / (2.0f - mx - mn) : d / (mx + mn);
    float h;
    if (mx == c.r) h = pcr_rem_euclid((c.g - c.b) / d, 6.0f);
    else if (mx == c.g) h = (c.b - c.r) / d + 2.0f;
    else h = (c.r - c.g) / d + 4.0f;
    return float3(h / 6.0f, s, l);
}

inline float pcr_hue_ch(float p, float q, float t0) {
    float t = pcr_rem_euclid(t0, 1.0f);
    if (t < 1.0f / 6.0f) return p + (q - p) * 6.0f * t;
    if (t < 0.5f) return q;
    if (t < 2.0f / 3.0f) return p + (q - p) * (2.0f / 3.0f - t) * 6.0f;
    return p;
}

inline float3 pcr_hsl_to_rgb(float h, float s, float l) {
    if (s <= 0.0f) return float3(l);
    float q = l < 0.5f ? l * (1.0f + s) : l + s - l * s;
    float p = 2.0f * l - q;
    return float3(pcr_hue_ch(p, q, h + 1.0f / 3.0f), pcr_hue_ch(p, q, h), pcr_hue_ch(p, q, h - 1.0f / 3.0f));
}

inline float pcr_lighten(float v, float l) { return l > 0.0f ? v + (1.0f - v) * l : v * (1.0f + l); }

inline float3 pcr_hue_saturation(float3 c, float hue, float s, float l, bool colorize) {
    if (colorize) {
        float ll = pcr_rgb_to_hsl(c).z;
        return pcr_hsl_to_rgb(pcr_rem_euclid(hue, 360.0f) / 360.0f, min(fabs(s), 1.0f), pcr_lighten(ll, l));
    }
    float3 lc = float3(pcr_lighten(c.r, l), pcr_lighten(c.g, l), pcr_lighten(c.b, l));
    float3 hsl = pcr_rgb_to_hsl(lc);
    float hh = pcr_rem_euclid(hsl.x + hue / 360.0f, 1.0f);
    float ss = clamp(s > 0.0f ? hsl.y / max(1.0f - s, 1.0f / 512.0f) : hsl.y * (1.0f + s), 0.0f, 1.0f);
    return pcr_hsl_to_rgb(hh, ss, hsl.z);
}

inline float3 pcr_range_lightness(float3 c, float l0) {
    float l = clamp(l0, -1.0f, 1.0f);
    float target = l > 0.0f ? max(max(c.r, c.g), c.b) : min(min(c.r, c.g), c.b);
    return c + (float3(target) - c) * fabs(l);
}

inline float pcr_hsv_hue(float3 c, float mx, float mn) {
    float d = mx - mn;
    float h;
    if (mx == c.r) h = pcr_rem_euclid((c.g - c.b) / d, 6.0f);
    else if (mx == c.g) h = (c.b - c.r) / d + 2.0f;
    else h = (c.r - c.g) / d + 4.0f;
    return h * 60.0f;
}

inline float3 pcr_vibrance_lin(float3 c, float v) {
    float mx = max(max(c.r, c.g), c.b), mn = min(min(c.r, c.g), c.b);
    if (mx <= 0.0f || mx - mn <= 1e-9f) return c;
    float t = 1.0f - mn / mx;
    float shape = t * (1.0f - t) * (2.0f - t + t * t) * mx * max(1.0f - mx, 0.0f);
    float t2, v2;
    if (v < 0.0f) {
        float a = -v;
        t2 = t * (1.0f - a / 4.0f) * (1.0f - a + a * t * (1.0f + t) / 2.0f);
        v2 = mx - a * shape;
    } else {
        // AdjustMath.vibranceBoost / vibranceLift / vibranceSkinFit / vibranceDark.
        float h = pcr_hsv_hue(c, mx, mn);
        float w = h <= 30.17f ? 1.0f : (h < 45.16f ? (45.16f - h) / (45.16f - 30.17f) : (h < 298.34f ? 0.0f : (h - 298.34f) / (360.0f - 298.34f)));
        float protection = w * min(1.0f, max(0.7761f + 1.0504f * (1.0f - v), 0.0f) * pow(1.0f - t, 0.9268f));
        float a = v * (1.0f - protection);
        float boost = (0.7674f * a + 0.08208f * a * a) * pow(t, 0.5788f) * pow(1.0f - t, 0.9946f) *
                      exp((-0.2027f + 0.1551f * a + 1.9724f * (1.0f - t)) * max(1.0f - mx, 0.0f)) * (mx / (mx + 0.005788f));
        t2 = min(t * (1.0f + boost), 1.0f);
        v2 = mx + v * 0.2478f * shape;
    }
    float m2 = v2 * (1.0f - t2);
    float k = (v2 - m2) / (mx - mn);
    return float3(m2) + (c - float3(mn)) * k;
}

inline float pcr_bayer4(int2 p) {
    const float m[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};
    return (m[(p.y & 3) * 4 + (p.x & 3)] + 0.5f) / 16.0f - 0.5f;
}

inline float3 pcr_stops(device const float4* s, int n, float t) {
    if (n == 0) return float3(t);
    if (n == 1 || t <= s[0].x) return s[0].yzw;
    for (int i = 0; i < n - 1; i++) {
        if (t <= s[i + 1].x) {
            float k = s[i + 1].x > s[i].x ? (t - s[i].x) / (s[i + 1].x - s[i].x) : 0.0f;
            return s[i].yzw + (s[i + 1].yzw - s[i].yzw) * k;
        }
    }
    return s[n - 1].yzw;
}

inline float3 pcr_lut3(device const float* lut, int n, int r, int g, int b) {
    int i = ((b * n + g) * n + r) * 3;
    return float3(lut[i], lut[i + 1], lut[i + 2]);
}

inline float3 pcr_lut3d(device const float* lut, int n, float3 c, bool tetra) {
    float m = float(n - 1);
    float3 pos = clamp(c, float3(0.0f), float3(1.0f)) * m;
    int3 i0 = min(int3(floor(pos)), int3(n - 2));
    float3 f = pos - float3(i0);
    int r = i0.x, g = i0.y, b = i0.z;
    float fr = f.x, fg = f.y, fb = f.z;
    if (tetra) {
        float3 c000 = pcr_lut3(lut, n, r, g, b), c111 = pcr_lut3(lut, n, r + 1, g + 1, b + 1);
        if (fr > fg) {
            if (fg > fb) return (1.0f - fr) * c000 + (fr - fg) * pcr_lut3(lut, n, r + 1, g, b) + (fg - fb) * pcr_lut3(lut, n, r + 1, g + 1, b) + fb * c111;
            if (fr > fb) return (1.0f - fr) * c000 + (fr - fb) * pcr_lut3(lut, n, r + 1, g, b) + (fb - fg) * pcr_lut3(lut, n, r + 1, g, b + 1) + fg * c111;
            return (1.0f - fb) * c000 + (fb - fr) * pcr_lut3(lut, n, r, g, b + 1) + (fr - fg) * pcr_lut3(lut, n, r + 1, g, b + 1) + fg * c111;
        }
        if (fb > fg) return (1.0f - fb) * c000 + (fb - fg) * pcr_lut3(lut, n, r, g, b + 1) + (fg - fr) * pcr_lut3(lut, n, r, g + 1, b + 1) + fr * c111;
        if (fb > fr) return (1.0f - fg) * c000 + (fg - fb) * pcr_lut3(lut, n, r, g + 1, b) + (fb - fr) * pcr_lut3(lut, n, r, g + 1, b + 1) + fr * c111;
        return (1.0f - fg) * c000 + (fg - fr) * pcr_lut3(lut, n, r, g + 1, b) + (fr - fb) * pcr_lut3(lut, n, r + 1, g + 1, b) + fb * c111;
    }
    float3 c00 = mix(pcr_lut3(lut, n, r, g, b), pcr_lut3(lut, n, r + 1, g, b), fr);
    float3 c10 = mix(pcr_lut3(lut, n, r, g + 1, b), pcr_lut3(lut, n, r + 1, g + 1, b), fr);
    float3 c01 = mix(pcr_lut3(lut, n, r, g, b + 1), pcr_lut3(lut, n, r + 1, g, b + 1), fr);
    float3 c11 = mix(pcr_lut3(lut, n, r, g + 1, b + 1), pcr_lut3(lut, n, r + 1, g + 1, b + 1), fr);
    return mix(mix(c00, c10, fg), mix(c01, c11, fg), fb);
}

inline float pcr_balance(float4 sh, float4 mi, float4 hi, bool preserve, int ch, float v0) {
    float v = clamp(v0, 0.0f, 1.0f);
    const float L = 0.39f;
    for (int ti = 0; ti < 3; ti++) {
        int tone = ti == 0 ? 2 : (ti == 1 ? 0 : 1);
        float3 sl = tone == 2 ? hi.xyz : (tone == 0 ? sh.xyz : mi.xyz);
        float3 a = clamp(sl / 100.0f, float3(-1.0f), float3(1.0f));
        if (preserve && tone != 1) {
            float own = a[ch];
            float lo = min(min(a.x, a.y), a.z), hh = max(max(a.x, a.y), a.z);
            if (tone == 0) { float b = L * (hh - own); v = max((v - b) / (1.0f - b), 0.0f); }
            else { float w = 1.0f - L * (own - lo); v = min(v / w, 1.0f); }
            continue;
        }
        for (int src = 0; src < 3; src++) {
            float s = clamp(sl[src] / 100.0f, -1.0f, 1.0f);
            bool own = src == ch;
            if (s == 0.0f || (!preserve && !own)) continue;
            if (tone == 1) {
                v = preserve ? pow(v, pow(2.0f, (own ? -s : s) / 2.0f)) : pow(v, pow(2.0f, -s));
            } else if (tone == 0 && !preserve) {
                if (s < 0.0f) { float b = L * -s; v = pow(max((v - b) / (1.0f - b), 0.0f), pow(2.0f, -s / 2.0f)); }
                else v = pow(v, pow(2.0f, -s / 2.0f));
            } else if (tone == 2 && !preserve) {
                if (s > 0.0f) { float w = 1.0f - L * s; v = pow(min(v / w, 1.0f), pow(2.0f, -s / 2.0f)); }
                else v = pow(v, pow(2.0f, -s / 2.0f));
            }
        }
    }
    return v;
}

inline float3 pcr_selective(device const float4* adj, float3 c, bool relative) {
    float mx = max(max(c.r, c.g), c.b), mn = min(min(c.r, c.g), c.b);
    float md = c.r + c.g + c.b - mx - mn;
    float w[9] = {c.r >= mx ? mx - md : 0.0f, c.b <= mn ? md - mn : 0.0f, c.g >= mx ? mx - md : 0.0f,
                  c.r <= mn ? md - mn : 0.0f, c.b >= mx ? mx - md : 0.0f, c.g <= mn ? md - mn : 0.0f,
                  max((mn - 0.5f) * 2.0f, 0.0f), clamp(1.0f - fabs(mx - 0.5f) - fabs(mn - 0.5f), 0.0f, 1.0f), max((0.5f - mx) * 2.0f, 0.0f)};
    float3 o = c;
    for (int r = 0; r < 9; r++) {
        if (w[r] <= 0.0f) continue;
        float4 a = adj[r] / 100.0f;
        if (all(a == 0.0f)) continue;
        for (int i = 0; i < 3; i++) {
            float d = relative ? (a[i] + a.w) * (1.0f - c[i]) : (1.0f + a[i]) * (1.0f + a.w) - 1.0f;
            o[i] += w[r] * (clamp(c[i] - d, 0.0f, 1.0f) - c[i]);
        }
    }
    return clamp(o, float3(0.0f), float3(1.0f));
}

inline float pcr_bw_gray(float3 c, float4 w03, float2 w45) {
    float w[6] = {w03.x, w03.y, w03.z, w03.w, w45.x, w45.y};
    float mx = max(max(c.r, c.g), c.b), mn = min(min(c.r, c.g), c.b);
    float mid = c.r + c.g + c.b - mx - mn;
    int primary = (c.r >= c.g && c.r >= c.b) ? 0 : (c.g >= c.b ? 2 : 4);
    int secondary = (c.b <= c.r && c.b <= c.g) ? 1 : (c.r <= c.g ? 3 : 5);
    return clamp(mn + (mid - mn) * w[secondary] / 100.0f + (mx - mid) * w[primary] / 100.0f, 0.0f, 1.0f);
}

inline float3 pcr_lab_norm(float3 c) {
    float3 l = pcr_srgb_to_lab(c);
    return float3(l.x / 100.0f, (l.y + 128.0f) / 255.0f, (l.z + 128.0f) / 255.0f);
}
inline float3 pcr_lab_denorm(float3 n) { return pcr_lab_to_srgb(float3(n.x * 100.0f, n.y * 255.0f - 128.0f, n.z * 255.0f - 128.0f)); }

inline float4 pcr_cmyk_naive(float3 rgb0) {
    float3 rgb = clamp(rgb0, float3(0.0f), float3(1.0f));
    float k = 1.0f - max(max(rgb.r, rgb.g), rgb.b);
    if (k >= 1.0f - 1e-6f) return float4(0.0f, 0.0f, 0.0f, 1.0f);
    float d = 1.0f - k;
    return float4((1.0f - rgb.r - k) / d, (1.0f - rgb.g - k) / d, (1.0f - rgb.b - k) / d, k);
}
inline float3 pcr_cmyk_to_rgb_naive(float4 c) {
    float k = 1.0f - c.w;
    return float3((1.0f - c.x) * k, (1.0f - c.y) * k, (1.0f - c.z) * k);
}

inline float3 pcr_adjust_color(float3 c, int2 d, constant PCROp& op, device const float* lut) {
    float4 p0 = op.p[0], p1 = op.p[1], p2 = op.p[2], p3 = op.p[3];
    bool hdr = (op.flags & PCR_F_HDR) != 0u;
    switch (pcr_adjust_kind) {
        case 1: return float3(1.0f) - c;
        case 2: return float3(round(pcr_gray(c) * 255.0f) >= p0.x ? 1.0f : 0.0f);
        case 3: return float3(pcr_posterize(c.r, p0.x), pcr_posterize(c.g, p0.x), pcr_posterize(c.b, p0.x));
        case 4: return float3(pcr_legacy(c.r, p0), pcr_legacy(c.g, p0), pcr_legacy(c.b, p0));
        case 5: return any(p0 > 0.5f) ? pcr_light_tone(c, lut, p0) : c;  // Light: four stages through ProPhoto
        case 6: {
            float3 o;
            for (int i = 0; i < 3; i++) {
                float v = c[i];
                if (hdr) {
                    float lin = v * p0.x + p0.y;
                    o[i] = p0.z == 1.0f ? lin : copysign(pow(fabs(lin), 1.0f / p0.z), lin);
                } else {
                    float lin = max(pcr_t_decode(v, p0.w) * p0.x + p0.y, 0.0f);
                    if (p0.z != 1.0f) lin = pow(lin, 1.0f / p0.z);
                    o[i] = clamp(pcr_t_encode(lin, p0.w), 0.0f, 1.0f);
                }
            }
            return o;
        }
        case 7: {
            float3 o;
            for (int i = 0; i < 3; i++) o[i] = p0[i] > 0.5f ? c[i] : pcr_lut(lut + i * PCR_LUTN, PCR_LUTN, c[i]);
            return o;
        }
        case 8: {
            // 32-bit Levels: records master, R, G, B (5 floats each); p0 = identity flags (master, R, G, B).
            float3 o;
            for (int i = 0; i < 3; i++) {
                float v = p0[i + 1] > 0.5f ? c[i] : pcr_levels_float(lut + (i + 1) * 5, c[i]);
                o[i] = p0.x > 0.5f ? v : pcr_levels_float(lut, v);
            }
            return o;
        }
        case 9: {
            // Lab tone space: LUTs on L, a, b; added as the difference of two round trips.
            float3 n = pcr_lab_norm(c);
            float3 o = float3(pcr_lut(lut, PCR_LUTN, n.x), pcr_lut(lut + PCR_LUTN, PCR_LUTN, n.y), pcr_lut(lut + 2 * PCR_LUTN, PCR_LUTN, n.z));
            if (all(o == n)) return c;
            return clamp(c + pcr_lab_denorm(o) - pcr_lab_denorm(n), float3(0.0f), float3(1.0f));
        }
        case 10: {
            // CMYK tone space (naive conversions; a managed CMYK converter keeps this on the CPU).
            float4 ink = pcr_cmyk_naive(c);
            float4 o;
            for (int i = 0; i < 4; i++) o[i] = 1.0f - pcr_lut(lut + i * PCR_LUTN, PCR_LUTN, 1.0f - ink[i]);
            if (all(o == ink)) return c;
            return clamp(c + pcr_cmyk_to_rgb_naive(o) - pcr_cmyk_to_rgb_naive(ink), float3(0.0f), float3(1.0f));
        }
        case 11: {
            float dh = 0.0f, ds = 0.0f, dl = 0.0f;
            if (p1.x > 0.5f) {
                float h0 = pcr_rgb_to_hsl(c).x;
                float chroma = min((max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b)) * 4.0f, 1.0f);
                dh = pcr_lut(lut, PCR_LUTN, h0) * chroma;
                ds = pcr_lut(lut + PCR_LUTN, PCR_LUTN, h0) * chroma;
                dl = pcr_lut(lut + 2 * PCR_LUTN, PCR_LUTN, h0) * chroma;
            }
            float3 out = pcr_hue_saturation(c, p0.x + dh, clamp(p0.y + ds, -1.0f, 1.0f), clamp(p0.z, -1.0f, 1.0f), p0.w > 0.5f);
            return pcr_range_lightness(out, dl);
        }
        case 12: {
            float g = p0.z, hi = p0.w;
            float3 l = float3(pcr_t_decode(c.r, g), pcr_t_decode(c.g, g), pcr_t_decode(c.b, g));
            if (p0.x != 0.0f) l = pcr_vibrance_lin(l, p0.x);
            if (p0.y != 0.0f) {
                float gr = 0.288f * l.r + 0.712f * l.g;
                for (int i = 0; i < 3; i++) l[i] = min(max(gr + (1.0f + p0.y) * (l[i] - gr), 0.0f), hi);
            }
            return float3(pcr_t_encode(min(max(l.r, 0.0f), hi), g), pcr_t_encode(min(max(l.g, 0.0f), hi), g), pcr_t_encode(min(max(l.b, 0.0f), hi), g));
        }
        case 13: {
            float r = clamp(p0.x * c.r + p0.y * c.g + p0.z * c.b + p0.w, 0.0f, 1.0f);
            if (p3.x > 0.5f) return float3(r);
            return float3(r, clamp(p1.x * c.r + p1.y * c.g + p1.z * c.b + p1.w, 0.0f, 1.0f), clamp(p2.x * c.r + p2.y * c.g + p2.z * c.b + p2.w, 0.0f, 1.0f));
        }
        case 14: {
            float g = p3.y;
            float3 l = float3(pcr_t_decode(c.r, g), pcr_t_decode(c.g, g), pcr_t_decode(c.b, g));
            float3 f = float3(pcr_t_encode(p0.x * l.x + p0.y * l.y + p0.z * l.z, g), pcr_t_encode(p1.x * l.x + p1.y * l.y + p1.z * l.z, g),
                              pcr_t_encode(p2.x * l.x + p2.y * l.y + p2.z * l.z, g));
            if (p3.x > 0.5f) f = pc_set_lum(f, pc_lum(c), 1.0f);
            return clamp(f, float3(0.0f), float3(1.0f));
        }
        case 15: {
            float g = pcr_bw_gray(c, p0, p1.xy);
            if (p1.z > 0.5f) return clamp(pc_set_lum(p2.xyz, g, 1.0f), float3(0.0f), float3(1.0f));
            return float3(g);
        }
        case 16: {
            float t = pcr_lum3(c);  // AdjustMath.gradientMapInput
            if (p0.x > 0.5f) t = 1.0f - t;
            float3 o = pcr_stops((device const float4*)lut, int(p0.z), t);
            if (p0.y > 0.5f) o = clamp(o + pcr_bayer4(d) / 255.0f, float3(0.0f), float3(1.0f));
            return o;
        }
        case 17: {
            bool pl = p3.x > 0.5f;
            return float3(pcr_balance(p0, p1, p2, pl, 0, c.r), pcr_balance(p0, p1, p2, pl, 1, c.g), pcr_balance(p0, p1, p2, pl, 2, c.b));
        }
        case 18: {
            float3 o = pcr_selective((device const float4*)lut, c, p0.x > 0.5f);
            return p0.y > 0.5f ? float3(pcr_gray(o)) : o;  // Grayscale documents: the result's grey
        }
        case 19: {
            float3 o = pcr_lut3d(lut, int(p0.x), c, p0.y > 0.5f);
            if (p0.z > 0.5f) o = clamp(o + pcr_bayer4(d) / 255.0f, float3(0.0f), float3(1.0f));
            return o;
        }
        case 20: return pcr_lab_denorm(float3(1.0f) - clamp(pcr_lab_norm(c), float3(0.0f), float3(1.0f)));
        case 21: {
            float3 n = pcr_lab_norm(c);
            return pcr_lab_denorm(float3(pcr_posterize(n.x, p0.x), pcr_posterize(n.y, p0.x), pcr_posterize(n.z, p0.x)));
        }
        case 22: return float3(round(clamp(pcr_lab_norm(c).x, 0.0f, 1.0f) * 255.0f) >= p0.x ? 1.0f : 0.0f);
        case 23: {
            float3 n = pcr_lab_norm(c);
            float l = p2.x > 0.5f ? pcr_legacy(n.x, p0) : pcr_lut(lut, PCR_LUTN, n.x);
            if (l == n.x) return c;
            return clamp(c + pcr_lab_denorm(float3(l, n.y, n.z)) - pcr_lab_denorm(n), float3(0.0f), float3(1.0f));
        }
        case 24: {
            float l = clamp(pcr_lab_norm(c).x, 0.0f, 1.0f);
            float3 o = pcr_stops((device const float4*)lut, int(p0.z), p0.x > 0.5f ? 1.0f - l : l);
            if (p0.y > 0.5f) o = clamp(o + pcr_bayer4(d) / 255.0f, float3(0.0f), float3(1.0f));
            return o;
        }
        default: return c;
    }
}

/// Lab-channel adjustments on a native Lab buffer (L/100, (a+128)/255, (b+128)/255), no
/// conversions (`PreparedAdjustment.applyNativeLab`).
inline float3 pcr_adjust_lab_native(float3 n, int2 d, constant PCROp& op, device const float* lut) {
    float4 p0 = op.p[0], p1 = op.p[1], p2 = op.p[2];
    const float mid = 128.0f / 255.0f;
    switch (pcr_adjust_kind) {
        case 9: return float3(pcr_lut(lut, PCR_LUTN, n.x), pcr_lut(lut + PCR_LUTN, PCR_LUTN, n.y), pcr_lut(lut + 2 * PCR_LUTN, PCR_LUTN, n.z));
        case 20: return float3(1.0f) - clamp(n, float3(0.0f), float3(1.0f));
        case 21: return float3(pcr_posterize(n.x, p0.x), pcr_posterize(n.y, p0.x), pcr_posterize(n.z, p0.x));
        case 22: return float3(round(clamp(n.x, 0.0f, 1.0f) * 255.0f) >= p0.x ? 1.0f : 0.0f, mid, mid);
        case 23: return float3(p2.x > 0.5f ? pcr_legacy(n.x, p0) : pcr_lut(lut, PCR_LUTN, n.x), n.y, n.z);
        case 24: {
            float l = clamp(n.x, 0.0f, 1.0f);
            float3 o = pcr_stops((device const float4*)lut, int(p0.z), p0.x > 0.5f ? 1.0f - l : l);
            if (p0.y > 0.5f) o = clamp(o + pcr_bayer4(d) / 255.0f, float3(0.0f), float3(1.0f));
            return pcr_lab_norm(o);
        }
        default: return n;
    }
}

/// An adjustment applied to A (transparent pixels untouched). Native Lab buffers are adjusted on
/// their channels (Lab-channel kinds) or through display RGB.
kernel void pcr_adjust(constant PCROp& op [[buffer(0)]], device const float* lut [[buffer(1)]], uint2 gid [[thread_position_in_grid]],
                       texture2d<float, access::read> a [[texture(0)]], texture2d<float, access::write> out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 c = a.read(t);
    if (c.a <= 0.0f) { out.write(c, t); return; }
    if ((op.flags & PCR_F_NLAB) != 0u) {
        uint k = pcr_adjust_kind;
        if (k == 9u || (k >= 20u && k <= 24u)) { out.write(float4(pcr_adjust_lab_native(c.rgb, d, op, lut), c.a), t); return; }
        out.write(float4(pcr_lab_norm(pcr_adjust_color(pcr_lab_denorm(c.rgb), d, op, lut)), c.a), t);
        return;
    }
    out.write(float4(pcr_adjust_color(c.rgb, d, op, lut), c.a), t);
}
