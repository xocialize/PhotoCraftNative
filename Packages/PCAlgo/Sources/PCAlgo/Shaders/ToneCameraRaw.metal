// Port of photocraft-algo (crates/algo/src/camera_raw.rs: develop's per-pixel stages; photo_util.rs: hash01), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Camera Raw Filter's per-pixel stages in one kernel: white balance and exposure, Contrast,
// Vibrance / Saturation, parametric and point curves, the Color Mixer, Color Grading, the
// post-crop vignette, grain and the final clamp. Image coordinates are relative to the bounds.

struct pca_tone_cr_params {
    int2 origin;
    int2 size;
    float4 wb;
    float4 tint0;
    float4 tint1;
    float4 tint2;
    float4 tint3;
    float4 lums;
    uint flags;      // 1 wb, 2 contrast, 4 vib/sat, 8 parametric, 16 master, 32/64/128 R/G/B curves,
                     // 256 hsl, 512 grade, 1024 vignette, 2048 grain, 4096 clamp
    float k_con;
    float saturation;
    float vibrance;
    float blend;
    float bal;
    float vig_amt;
    float vig_hl;
    float cx;
    float cy;
    float ax;
    float ay;
    float pw;
    float edge0;
    float edge1;
    uint vig_style;  // 0 highlightPriority, 1 colorPriority, 2 paintOverlay
    float grain_cell;
    float grain_rough;
    float grain_amt;
    float grain_pscale;
    uint seed_lo;
    uint seed_hi;
    uint pad0;
    uint pad1;
};

inline float pca_tone_cr_luma(float3 c) { return 0.2126f * c.x + 0.7152f * c.y + 0.0722f * c.z; }

inline float pca_tone_cr_smoothstep(float e0, float e1, float x) {
    float t = clamp((x - e0) / (e1 - e0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

inline float3 pca_tone_cr_rgb_to_hsv(float3 c) {
    float mx = fmax(fmax(c.x, c.y), c.z), mn = fmin(fmin(c.x, c.y), c.z);
    float d = mx - mn;
    float h;
    if (d <= 1e-9f) h = 0.0f;
    else if (mx == c.x) h = 60.0f * pca_rem_euclid_f((c.y - c.z) / d, 6.0f);
    else if (mx == c.y) h = 60.0f * ((c.z - c.x) / d + 2.0f);
    else h = 60.0f * ((c.x - c.y) / d + 4.0f);
    return float3(h, mx > 1e-9f ? d / mx : 0.0f, mx);
}

inline float3 pca_tone_cr_hsv_to_rgb(float h0, float s, float v) {
    float h = pca_rem_euclid_f(h0, 360.0f) / 60.0f;
    float c = v * s;
    float x = c * (1.0f - fabs(pca_fmod(h, 2.0f) - 1.0f));
    uint seg = (isnan(h) || h <= 0.0f) ? 0u : uint(h);
    float3 rgb;
    switch (seg) {
        case 0u: rgb = float3(c, x, 0.0f); break;
        case 1u: rgb = float3(x, c, 0.0f); break;
        case 2u: rgb = float3(0.0f, c, x); break;
        case 3u: rgb = float3(0.0f, x, c); break;
        case 4u: rgb = float3(x, 0.0f, c); break;
        default: rgb = float3(c, 0.0f, x); break;
    }
    float m = v - c;
    return float3(rgb.x + m, rgb.y + m, rgb.z + m);
}

constant float pca_tone_cr_bands[8] = {0.0f, 30.0f, 60.0f, 120.0f, 180.0f, 240.0f, 270.0f, 300.0f};

inline float pca_tone_cr_band_weight(float h, int k) {
    float c = pca_tone_cr_bands[k], prev = pca_tone_cr_bands[(k + 7) % 8], next = pca_tone_cr_bands[(k + 1) % 8];
    float diff = pca_fmod(h - c + 540.0f, 360.0f) - 180.0f;
    float span = diff >= 0.0f ? pca_rem_euclid_f(next - c, 360.0f) : pca_rem_euclid_f(c - prev, 360.0f);
    return fmax(1.0f - fabs(diff) / fmax(span, 1e-3f), 0.0f);
}

inline float pca_tone_cr_lut(constant float* lut, float v) {
    const int n = 1024;
    if (!(v >= 0.0f && v <= 1.0f)) return v < 0.0f ? v + lut[0] : lut[n - 1] + (v - 1.0f);
    float x = v * float(n - 1);
    int i = min(int(x), n - 2);
    float t = x - float(i);
    return lut[i] + (lut[i + 1] - lut[i]) * t;
}

/// photocraft `photo_util::hash01`: 64-bit position hash → [0, 1).
inline float pca_tone_cr_hash01(long x, long y, ulong seed) {
    ulong z = (ulong(x) * 0x9E3779B97F4A7C15ul) ^ (ulong(y) * 0xC2B2AE3D27D4EB4Ful) ^ (seed * 0x165667B19E3779F9ul);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ul;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBul;
    z ^= z >> 31;
    return float(uint(z >> 40)) / 16777216.0f;
}

inline float pca_tone_cr_value_noise(float x, float y, ulong seed) {
    float xi = floor(x), yi = floor(y);
    float tx = x - xi, ty = y - yi;
    float sx = tx * tx * (3.0f - 2.0f * tx), sy = ty * ty * (3.0f - 2.0f * ty);
    long ix = long(xi), iy = long(yi);
    float h00 = pca_tone_cr_hash01(ix, iy, seed), h10 = pca_tone_cr_hash01(ix + 1, iy, seed);
    float h01 = pca_tone_cr_hash01(ix, iy + 1, seed), h11 = pca_tone_cr_hash01(ix + 1, iy + 1, seed);
    float top = h00 + (h10 - h00) * sx;
    float bot = h01 + (h11 - h01) * sx;
    return top + (bot - top) * sy;
}

kernel void pca_tone_camera_raw(constant pca_frame& f [[buffer(0)]], constant pca_tone_cr_params& p [[buffer(1)]],
                                constant float* luts [[buffer(2)]], constant float* hsl [[buffer(3)]],
                                pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q);
    int2 r = q - p.origin;
    if (r.x < 0 || r.y < 0 || r.x >= p.size.x || r.y >= p.size.y) { dst.write(v, gid); return; }
    float4 c4 = pca_tone_to_rgba_px(v, f);
    float3 c = c4.xyz;
    uint fl = p.flags;
    // 1. White balance + exposure in linear light.
    if ((fl & 1u) != 0u) {
        for (int ch = 0; ch < 3; ch++) c[ch] = pca_tone_linear_to_srgb(fmax(pca_tone_srgb_to_linear(c[ch]) * p.wb[ch], 0.0f));
    }
    // 3. Contrast (an S-curve on luminance, colour ratios kept).
    if ((fl & 2u) != 0u) {
        const float tau = 6.28318530717958647692f;
        float l0 = fmax(pca_tone_cr_luma(c), 0.0f);
        float lc = fmin(l0, 1.0f);
        float lv = lc;
        if (p.k_con != 0.0f) {
            float xx = clamp(lv, 0.0f, 1.0f);
            lv += -p.k_con * sin(tau * xx) / tau;
        }
        float lv2 = fmax(lv, 0.0f) + (l0 - lc);
        float ratio = l0 > 1e-5f ? lv2 / l0 : 1.0f;
        for (int ch = 0; ch < 3; ch++) c[ch] = l0 > 1e-5f ? c[ch] * ratio : c[ch] + (lv2 - l0);
    }
    // 4. Vibrance and Saturation.
    if ((fl & 4u) != 0u) {
        float l = pca_tone_cr_luma(c);
        float mx = fmax(fmax(c.x, c.y), c.z), mn = fmin(fmin(c.x, c.y), c.z);
        float s = mx > 1e-6f ? (mx - mn) / mx : 0.0f;
        float hh = pca_tone_cr_rgb_to_hsv(c).x;
        float skin = clamp(1.0f - fabs(hh - 25.0f) / 25.0f, 0.0f, 1.0f) * 0.5f;
        float k = fmax(1.0f + p.saturation / 100.0f + p.vibrance / 100.0f * (1.0f - s) * (1.0f - skin), 0.0f);
        c = float3(l + (c.x - l) * k, l + (c.y - l) * k, l + (c.z - l) * k);
    }
    // 5. Tone curves.
    if ((fl & 8u) != 0u) c = float3(pca_tone_cr_lut(luts, c.x), pca_tone_cr_lut(luts, c.y), pca_tone_cr_lut(luts, c.z));
    if ((fl & 16u) != 0u) c = float3(pca_tone_cr_lut(luts + 1024, c.x), pca_tone_cr_lut(luts + 1024, c.y), pca_tone_cr_lut(luts + 1024, c.z));
    for (int ch = 0; ch < 3; ch++) {
        if ((fl & (32u << uint(ch))) != 0u) c[ch] = pca_tone_cr_lut(luts + (2 + ch) * 1024, c[ch]);
    }
    // 6. Color Mixer.
    if ((fl & 256u) != 0u) {
        float3 hsv = pca_tone_cr_rgb_to_hsv(fmax(c, 0.0f));
        float hh = hsv.x, s = hsv.y, vv = hsv.z;
        if (s > 1e-4f) {
            float dh = 0.0f, ds = 0.0f, dl = 0.0f;
            for (int k = 0; k < 8; k++) {
                float w = pca_tone_cr_band_weight(hh, k);
                dh += w * hsl[k];
                ds += w * hsl[8 + k];
                dl += w * hsl[16 + k];
            }
            float nh = hh + dh / 100.0f * 30.0f;
            float ns = clamp(s * (1.0f + ds / 100.0f), 0.0f, 1.0f);
            float3 o = pca_tone_cr_hsv_to_rgb(nh, ns, vv);
            float l0 = pca_tone_cr_luma(c), l1 = pca_tone_cr_luma(o);
            if (l1 > 1e-6f) o = float3(o.x * l0 / l1, o.y * l0 / l1, o.z * l0 / l1);
            float k = pow(2.0f, dl / 100.0f * 1.0f * s);
            c = float3(o.x * k, o.y * k, o.z * k);
        }
    }
    // 7. Color Grading.
    if ((fl & 512u) != 0u) {
        float l = clamp(pca_tone_cr_luma(c), 0.0f, 1.0f);
        float sh = 1.0f - pca_tone_cr_smoothstep(0.0f, 0.5f + p.bal + p.blend, l);
        float hi = pca_tone_cr_smoothstep(0.5f + p.bal - p.blend, 1.0f, l);
        float mid = fmax(1.0f - sh - hi, 0.0f);
        float masks[4] = {sh, mid, hi, 1.0f};
        float4 tints[4] = {p.tint0, p.tint1, p.tint2, p.tint3};
        for (int k = 0; k < 4; k++) {
            for (int ch = 0; ch < 3; ch++) c[ch] += masks[k] * tints[k][ch];
            if (p.lums[k] != 0.0f) {
                float fk = pow(2.0f, masks[k] * p.lums[k] / 100.0f * 0.6f);
                c = float3(c.x * fk, c.y * fk, c.z * fk);
            }
        }
    }
    // 9. Vignette.
    if ((fl & 1024u) != 0u) {
        float dx = fabs((float(r.x) + 0.5f - p.cx) / p.ax), dy = fabs((float(r.y) + 0.5f - p.cy) / p.ay);
        float rr = pow(pow(dx, p.pw) + pow(dy, p.pw), 1.0f / p.pw);
        float m = pca_tone_cr_smoothstep(p.edge0, p.edge1, rr);
        if (m > 0.0f) {
            float l = clamp(pca_tone_cr_luma(c), 0.0f, 1.0f);
            if (p.vig_style == 2u) {
                float target = p.vig_amt < 0.0f ? 0.0f : 1.0f;
                float k = m * fabs(p.vig_amt);
                for (int ch = 0; ch < 3; ch++) c[ch] += (target - c[ch]) * k;
            } else {
                float k = pow(2.0f, p.vig_amt * 2.0f * m);
                if (p.vig_amt < 0.0f && p.vig_hl > 0.0f) {
                    float protect = pca_tone_cr_smoothstep(0.6f, 1.0f, l) * p.vig_hl;
                    k += (1.0f - k) * protect;
                }
                if (p.vig_style == 1u) {
                    float nl = l * k;
                    for (int ch = 0; ch < 3; ch++) c[ch] += nl - l;
                } else {
                    c = float3(c.x * k, c.y * k, c.z * k);
                }
            }
        }
    }
    // 9. Grain.
    if ((fl & 2048u) != 0u) {
        ulong seed = (ulong(p.seed_hi) << 32) | ulong(p.seed_lo);
        float fx = float(r.x) * p.grain_pscale / p.grain_cell, fy = float(r.y) * p.grain_pscale / p.grain_cell;
        float n = pca_tone_cr_value_noise(fx, fy, seed) * (1.0f - p.grain_rough)
                + (pca_tone_cr_value_noise(fx * 2.3f, fy * 2.3f, seed + 7ul) - 0.0f) * p.grain_rough;
        float l = clamp(pca_tone_cr_luma(c), 0.0f, 1.0f);
        float g = (n - 0.5f) * 2.0f * p.grain_amt * (0.4f + 2.4f * l * (1.0f - l));
        c = float3(c.x + g, c.y + g, c.z + g);
    }
    if ((fl & 4096u) != 0u) c = clamp(c, 0.0f, 1.0f);
    c4.xyz = c;
    dst.write(pca_tone_from_rgba_px(v, c4, f), gid);
}
