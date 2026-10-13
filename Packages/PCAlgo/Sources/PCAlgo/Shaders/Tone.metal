// Port of photocraft-algo (crates/algo/src/other2.rs, video.rs, color_to_alpha.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Per-pixel colour filters of the tone area: HSB/HSL, De-Interlace, NTSC Colors, Color to Alpha.

// ---- HSB / HSL (other2.rs) ----

struct pca_tone_hsb_params {
    uint input;   // 0 RGB, 1 HSB, 2 HSL
    uint output;
    uint pad0;
    uint pad1;
};

inline float pca_tone_hue(float3 c, float mx, float d) {
    if (d <= 0.0f) return 0.0f;
    float h;
    if (mx == c.x) h = pca_rem_euclid_f((c.y - c.z) / d, 6.0f);
    else if (mx == c.y) h = (c.z - c.x) / d + 2.0f;
    else h = (c.x - c.y) / d + 4.0f;
    return h / 6.0f;
}

inline float3 pca_tone_rgb_to_hsb(float3 c) {
    float mx = fmax(fmax(c.x, c.y), c.z), mn = fmin(fmin(c.x, c.y), c.z);
    float d = mx - mn;
    float h = pca_tone_hue(c, mx, d);
    return float3(h, mx > 0.0f ? d / mx : 0.0f, mx);
}

inline float3 pca_tone_rgb_to_hsl(float3 c) {
    float mx = fmax(fmax(c.x, c.y), c.z), mn = fmin(fmin(c.x, c.y), c.z);
    float d = mx - mn;
    float l = (mx + mn) / 2.0f;
    float s = d <= 0.0f ? 0.0f : d / fmax(1.0f - fabs(2.0f * l - 1.0f), 1e-7f);
    return float3(pca_tone_hue(c, mx, d), clamp(s, 0.0f, 1.0f), l);
}

inline float3 pca_tone_from_hcm(float h, float chroma, float m) {
    float hp = pca_rem_euclid_f(h, 1.0f) * 6.0f;
    float x = chroma * (1.0f - fabs(pca_rem_euclid_f(hp, 2.0f) - 1.0f));
    int seg = isfinite(hp) ? int(hp) : 0;
    float3 rgb;
    switch (seg) {
        case 0: rgb = float3(chroma, x, 0.0f); break;
        case 1: rgb = float3(x, chroma, 0.0f); break;
        case 2: rgb = float3(0.0f, chroma, x); break;
        case 3: rgb = float3(0.0f, x, chroma); break;
        case 4: rgb = float3(x, 0.0f, chroma); break;
        default: rgb = float3(chroma, 0.0f, x); break;
    }
    return float3(rgb.x + m, rgb.y + m, rgb.z + m);
}

inline float3 pca_tone_hsb_to_rgb(float3 c) {
    float chroma = c.z * c.y;
    return pca_tone_from_hcm(c.x, chroma, c.z - chroma);
}

inline float3 pca_tone_hsl_to_rgb(float3 c) {
    float chroma = (1.0f - fabs(2.0f * c.z - 1.0f)) * c.y;
    return pca_tone_from_hcm(c.x, chroma, c.z - chroma / 2.0f);
}

/// photocraft `rgb_to_gray` / `tone::luma` (Rec. 601), evaluated left to right like the CPU.
inline float pca_tone_luma(float3 c) {
    return 0.299f * c.x + 0.587f * c.y + 0.114f * c.z;
}

/// The RGB of a joint plane pixel (gray-like: replicated) — photocraft `to_rgba` for Gray/RGB.
inline float3 pca_tone_rgb_of(float4 v, uint mode) {
    return mode == 0u ? float3(v.x) : v.xyz;
}

/// Writes RGB back into a joint plane pixel (gray-like: its luma) — photocraft `from_rgba`.
inline float4 pca_tone_with_rgb(float4 v, float3 rgb, uint mode) {
    if (mode == 0u) return float4(pca_tone_luma(rgb), v.y, v.z, v.w);
    return float4(rgb, v.w);
}

kernel void pca_tone_hsbhsl(constant pca_frame& f [[buffer(0)]], constant pca_tone_hsb_params& p [[buffer(1)]],
                            pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q);
    float3 c = clamp(pca_tone_rgb_of(v, f.mode), 0.0f, 1.0f);
    float3 rgb = p.input == 1u ? pca_tone_hsb_to_rgb(c) : (p.input == 2u ? pca_tone_hsl_to_rgb(c) : c);
    float3 o = p.output == 1u ? pca_tone_rgb_to_hsb(rgb) : (p.output == 2u ? pca_tone_rgb_to_hsl(rgb) : rgb);
    dst.write(pca_tone_with_rgb(v, o, f.mode), gid);
}

// ---- De-Interlace (video.rs) ----

struct pca_tone_deinterlace_params {
    uint eliminate_even;
    uint interpolate;
    uint pad0;
    uint pad1;
};

kernel void pca_tone_deinterlace(constant pca_frame& f [[buffer(0)]], constant pca_tone_deinterlace_params& p [[buffer(1)]],
                                 pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q);
    int2 b0 = f.bounds_origin, b1 = f.bounds_origin + f.bounds_size;
    if (q.x < b0.x || q.x >= b1.x || q.y < b0.y || q.y >= b1.y) { dst.write(v, gid); return; }
    bool odd_line = (q.y - b0.y) % 2 == 0;
    if (odd_line == (p.eliminate_even != 0u)) { dst.write(v, gid); return; }
    bool has_above = q.y > b0.y, has_below = q.y + 1 < b1.y;
    int rows[2];
    int cnt;
    if (p.interpolate != 0u && has_above && has_below) { rows[0] = q.y - 1; rows[1] = q.y + 1; cnt = 2; }
    else if (has_above) { rows[0] = q.y - 1; cnt = 1; }
    else if (has_below) { rows[0] = q.y + 1; cnt = 1; }
    else { dst.write(v, gid); return; }
    bool alpha = f.alpha != 0u;
    float k = 1.0f / float(cnt);
    float4 acc = float4(0.0f);
    for (int r = 0; r < cnt; r++) {
        float4 s = pca_get(src, f, int2(q.x, rows[r]));
        if (alpha) {
            acc.xyz += (s.xyz * s.w) * k;
            acc.w += s.w * k;
        } else {
            acc += s * k;
        }
    }
    dst.write(pca_unpremul(acc, alpha), gid);
}

// ---- NTSC Colors (video.rs) ----

struct pca_tone_ntsc_params {
    float ntsc_max;
    float ntsc_min;
    uint pad0;
    uint pad1;
};

kernel void pca_tone_ntsc(constant pca_frame& f [[buffer(0)]], constant pca_tone_ntsc_params& p [[buffer(1)]],
                          pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q);
    float3 c = pca_tone_rgb_of(v, f.mode);
    float yy = 0.299f * c.x + 0.587f * c.y + 0.114f * c.z;
    float ii = 0.595716f * c.x - 0.274453f * c.y - 0.321263f * c.z;
    float qq = 0.211456f * c.x - 0.522591f * c.y + 0.311135f * c.z;
    float chroma = sqrt(ii * ii + qq * qq);
    if (chroma <= 1e-7f) { dst.write(v, gid); return; }
    float k = 1.0f;
    if (yy + chroma > p.ntsc_max) k = fmin(k, fmax((p.ntsc_max - yy) / chroma, 0.0f));
    if (yy - chroma < p.ntsc_min) k = fmin(k, fmax((yy - p.ntsc_min) / chroma, 0.0f));
    if (k >= 1.0f) { dst.write(v, gid); return; }
    float i2 = ii * k, q2 = qq * k;
    float3 rgb = float3(yy + 0.9563f * i2 + 0.6210f * q2, yy - 0.2721f * i2 - 0.6474f * q2, yy - 1.1070f * i2 + 1.7046f * q2);
    dst.write(pca_tone_with_rgb(v, rgb, f.mode), gid);
}

// ---- Color to Alpha (color_to_alpha.rs) ----

struct pca_tone_c2a_params {
    float4 key;
    float transparency;
    float opacity;
    uint pad0;
    uint pad1;
};

kernel void pca_tone_color_to_alpha(constant pca_frame& f [[buffer(0)]], constant pca_tone_c2a_params& p [[buffer(1)]],
                                    pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q);
    uint m = min(f.ncomp, 3u);
    float a = 0.0f;
    for (uint i = 0; i < m; i++) {
        float pv = v[i], c = p.key[i];
        float ai;
        if (pv > c) ai = c < 1.0f ? (pv - c) / (1.0f - c) : 1.0f;
        else if (pv < c) ai = c > 0.0f ? (c - pv) / c : 1.0f;
        else ai = 0.0f;
        if (isfinite(ai)) a = fmax(a, ai);
    }
    a = clamp(a, 0.0f, 1.0f);
    // remap
    if (a <= p.transparency) a = 0.0f;
    else if (a >= p.opacity) a = 1.0f;
    else a = clamp((a - p.transparency) / (p.opacity - p.transparency), 0.0f, 1.0f);
    if (a >= 1.0f) { dst.write(v, gid); return; }
    for (uint i = 0; i < m; i++) {
        float c = p.key[i];
        v[i] = a <= 0.0f ? c : clamp(c + (v[i] - c) / a, 0.0f, 1.0f);
    }
    v.w *= fmax(a, 0.0f);
    dst.write(v, gid);
}
