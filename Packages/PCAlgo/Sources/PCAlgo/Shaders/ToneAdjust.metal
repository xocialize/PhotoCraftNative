// Port of photocraft-algo (crates/algo/src/tone.rs: replace_color, match_color, hdr_toning; selection.rs: color_range) and photocraft-color's Lab conversions (crates/color/src/convert.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Image › Adjustments on straight RGBA: the to/from-RGBA plumbing of the joint (Gray/RGB-like)
// plane, a masked mean reduction, Replace Color, Match Color and HDR Toning.

struct pca_tone_rect_params {
    int2 origin;
    int2 size;
};

/// Straight RGBA of a joint plane pixel (photocraft `to_rgba` for Gray/RGB-like models).
inline float4 pca_tone_to_rgba_px(float4 v, constant pca_frame& f) {
    float3 c = f.mode == 0u ? float3(v.x) : v.xyz;
    return float4(c, f.alpha != 0u ? v.w : 1.0f);
}

/// A plane pixel `v` with its colour set from straight RGBA `c` (photocraft `from_rgba`).
inline float4 pca_tone_from_rgba_px(float4 v, float4 c, constant pca_frame& f) {
    float4 r = f.mode == 0u ? float4(0.299f * c.x + 0.587f * c.y + 0.114f * c.z, v.y, v.z, v.w) : float4(c.xyz, v.w);
    if (f.alpha != 0u) r.w = c.w;
    return r;
}

kernel void pca_tone_to_rgba(constant pca_frame& f [[buffer(0)]], constant pca_tone_rect_params& p [[buffer(1)]],
                             pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    dst.write(pca_tone_to_rgba_px(pca_get(src, f, p.origin + int2(gid)), f), gid);
}

// ---- Masked mean (reduction) ----

struct pca_tone_reduce_params {
    int width;
    uint count;
    uint groups;
    uint pad0;
};

/// Partial sums of values.x over pixels whose mask.w > 0, one per 256-thread group.
kernel void pca_tone_masked_sum(constant pca_frame& f [[buffer(0)]], constant pca_tone_reduce_params& p [[buffer(1)]],
                                device float* sums [[buffer(2)]], device uint* counts [[buffer(3)]],
                                pca_in values [[texture(0)]], pca_in mask [[texture(1)]],
                                uint gid [[thread_position_in_grid]], uint tid [[thread_index_in_threadgroup]],
                                uint tg [[threadgroup_position_in_grid]]) {
    threadgroup float s[256];
    threadgroup uint c[256];
    float v = 0.0f;
    uint k = 0u;
    if (gid < p.count) {
        uint2 xy = uint2(gid % uint(p.width), gid / uint(p.width));
        if (mask.read(xy).w > 0.0f) { v = values.read(xy).x; k = 1u; }
    }
    s[tid] = v;
    c[tid] = k;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = 128u; stride > 0u; stride >>= 1) {
        if (tid < stride) { s[tid] += s[tid + stride]; c[tid] += c[tid + stride]; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0u) { sums[tg] = s[0]; counts[tg] = c[0]; }
}

/// The mean of the partials: Σ sums / max(Σ counts, 1), into result[0] (one 256-thread group).
kernel void pca_tone_masked_mean_final(constant pca_frame& f [[buffer(0)]], constant pca_tone_reduce_params& p [[buffer(1)]],
                                       device const float* sums [[buffer(2)]], device const uint* counts [[buffer(3)]],
                                       device float* result [[buffer(4)]], uint tid [[thread_index_in_threadgroup]]) {
    threadgroup float s[256];
    threadgroup uint c[256];
    float v = 0.0f;
    uint k = 0u;
    for (uint i = tid; i < p.groups; i += 256u) { v += sums[i]; k += counts[i]; }
    s[tid] = v;
    c[tid] = k;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = 128u; stride > 0u; stride >>= 1) {
        if (tid < stride) { s[tid] += s[tid + stride]; c[tid] += c[tid + stride]; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0u) result[0] = s[0] / float(max(c[0], 1u));
}

/// Grid-stride histogram kernels (Shadows/Highlights clip, Equalize Histogram).
struct pca_tone_hist_params {
    int width;
    uint count;
    uint total;   // threads in the grid (grid-stride loop)
    uint pad0;
};

// ---- Lab (photocraft-color convert.rs, as PCFoundation's ColorConvert) ----

inline float pca_tone_srgb_to_linear(float v) {
    return v <= 0.04045f ? v / 12.92f : pow((v + 0.055f) / 1.055f, 2.4f);
}

inline float pca_tone_linear_to_srgb(float v) {
    return v <= 0.0031308f ? v * 12.92f : 1.055f * pow(v, 1.0f / 2.4f) - 0.055f;
}

/// Cube root of t > 0 (MSL has no cbrt): pow, then one Newton step toward libm's cbrtf.
inline float pca_tone_cbrt(float t) {
    float y = pow(t, 1.0f / 3.0f);
    return y - (y * y * y - t) / (3.0f * y * y);
}

inline float pca_tone_lab_f(float t) {
    const float e = 6.0f / 29.0f;
    return t > e * e * e ? pca_tone_cbrt(t) : t / (3.0f * e * e) + 4.0f / 29.0f;
}

inline float pca_tone_lab_finv(float t) {
    const float e = 6.0f / 29.0f;
    return t > e ? t * t * t : 3.0f * e * e * (t - 4.0f / 29.0f);
}

/// Encoded sRGB → CIE L*a*b* (D50).
inline float3 pca_tone_srgb_to_lab(float3 rgb) {
    float3 lin = float3(pca_tone_srgb_to_linear(rgb.x), pca_tone_srgb_to_linear(rgb.y), pca_tone_srgb_to_linear(rgb.z));
    float3 xyz = float3(0.436074f * lin.x + 0.385064f * lin.y + 0.143080f * lin.z,
                        0.222504f * lin.x + 0.716878f * lin.y + 0.060618f * lin.z,
                        0.013932f * lin.x + 0.097104f * lin.y + 0.714173f * lin.z) / float3(0.96422f, 1.0f, 0.82521f);
    float fx = pca_tone_lab_f(xyz.x), fy = pca_tone_lab_f(xyz.y), fz = pca_tone_lab_f(xyz.z);
    return float3(116.0f * fy - 16.0f, 500.0f * (fx - fy), 200.0f * (fy - fz));
}

/// CIE L*a*b* (D50) → encoded sRGB (linear clamped to 0–1).
inline float3 pca_tone_lab_to_srgb(float3 lab) {
    float fy = (lab.x + 16.0f) / 116.0f;
    float fx = fy + lab.y / 500.0f;
    float fz = fy - lab.z / 200.0f;
    float3 xyz = float3(pca_tone_lab_finv(fx), pca_tone_lab_finv(fy), pca_tone_lab_finv(fz)) * float3(0.96422f, 1.0f, 0.82521f);
    float3 lin = float3(3.133856f * xyz.x + -1.616867f * xyz.y + -0.490615f * xyz.z,
                        -0.978768f * xyz.x + 1.916142f * xyz.y + 0.033454f * xyz.z,
                        0.071945f * xyz.x + -0.228991f * xyz.y + 1.405243f * xyz.z);
    return float3(pca_tone_linear_to_srgb(clamp(lin.x, 0.0f, 1.0f)), pca_tone_linear_to_srgb(clamp(lin.y, 0.0f, 1.0f)),
                  pca_tone_linear_to_srgb(clamp(lin.z, 0.0f, 1.0f)));
}

// ---- Replace Color (tone.rs + selection.rs color_range) ----

struct pca_tone_replace_params {
    float4 color;
    float fuzz;        // fuzziness.max(0) + 1
    float hue;
    float saturation;
    float lightness;
};

kernel void pca_tone_replace_color(constant pca_frame& f [[buffer(0)]], constant pca_tone_replace_params& p [[buffer(1)]],
                                   pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q);
    float4 c4 = pca_tone_to_rgba_px(v, f);
    float k = 0.0f;
    if (c4.w > 0.0f) {
        float d = 0.0f;
        for (int i = 0; i < 3; i++) d = fmax(d, fabs(c4[i] - p.color[i]) * 255.0f);
        k = clamp(1.0f - d / p.fuzz, 0.0f, 1.0f);
    }
    if (k > 0.0f) {
        float3 c = c4.xyz;
        float3 hsl = pca_tone_rgb_to_hsl(c);
        float ss = hsl.y, ll = hsl.z;
        float s = p.saturation >= 0.0f ? ss + (1.0f - ss) * p.saturation / 100.0f : ss * (1.0f + p.saturation / 100.0f);
        float l = p.lightness >= 0.0f ? ll + (1.0f - ll) * p.lightness / 100.0f : ll * (1.0f + p.lightness / 100.0f);
        float3 o = pca_tone_hsl_to_rgb(float3(pca_rem_euclid_f(hsl.x + p.hue / 360.0f, 1.0f), clamp(s, 0.0f, 1.0f), clamp(l, 0.0f, 1.0f)));
        for (int i = 0; i < 3; i++) c4[i] = clamp(c[i] + (o[i] - c[i]) * k, 0.0f, 1.0f);
    }
    dst.write(pca_tone_from_rgba_px(v, c4, f), gid);
}

// ---- Match Color (tone.rs) ----

struct pca_tone_match_params {
    float4 tmean;
    float4 scale;
    float4 dst;
    float lum;
    float inten;
    float fade;
    float pad0;
};

kernel void pca_tone_match_color(constant pca_frame& f [[buffer(0)]], constant pca_tone_match_params& p [[buffer(1)]],
                                 pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q);
    float4 c4 = pca_tone_to_rgba_px(v, f);
    if (c4.w > 0.0f) {
        float3 c = c4.xyz;
        float3 lab = pca_tone_srgb_to_lab(c);
        float l = ((lab.x - p.tmean.x) * p.scale.x + p.dst.x) * p.lum;
        float a = ((lab.y - p.tmean.y) * p.scale.y + p.dst.y) * p.inten;
        float b = ((lab.z - p.tmean.z) * p.scale.z + p.dst.z) * p.inten;
        float3 o = pca_tone_lab_to_srgb(float3(clamp(l, 0.0f, 100.0f), a, b));
        for (int i = 0; i < 3; i++) c4[i] = clamp(o[i] + (c[i] - o[i]) * p.fade, 0.0f, 1.0f);
    }
    dst.write(pca_tone_from_rgba_px(v, c4, f), gid);
}

// ---- HDR Toning (tone.rs) ----

struct pca_tone_hdr_logl_params {
    int2 origin;
    int2 size;
    float eps;
    uint prescale;
    float pad1;
    float pad2;
};

/// Merge to HDR Pro's key to middle grey: 0.18 / exp(mean log luminance).
inline float pca_tone_key(device const float* log_mean) {
    return 0.18f / fmax(exp(log_mean[0]), 1e-6f);
}

/// ln(max(luma, 0) + ε) of the RGBA texture (covering the bounds) into .x (colours keyed first
/// with `prescale`).
kernel void pca_tone_hdr_logl(constant pca_frame& f [[buffer(0)]], constant pca_tone_hdr_logl_params& p [[buffer(1)]],
                              device const float* log_mean [[buffer(2)]],
                              pca_in rgba [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    float3 c = rgba.read(gid).xyz;
    if (p.prescale != 0u) { float k = pca_tone_key(log_mean); c = float3(c.x * k, c.y * k, c.z * k); }
    dst.write(float4(log(fmax(pca_tone_luma(c), 0.0f) + p.eps), 0.0f, 0.0f, 0.0f), gid);
}

struct pca_tone_hdr_map_params {
    int2 origin;
    int2 size;
    float compress;
    float detail;
    float exposure;
    float gamma;
    float shadow;
    float highlight;
    float saturation;
    float vibrance;
    float eps;
    int curve_count;
    uint prescale;
    uint encode;
};

/// photocraft `curve_eval`.
inline float pca_tone_curve_eval(constant float2* pts, int n, float x) {
    if (n < 2) return x;
    if (x <= pts[0].x) return pts[0].y;
    for (int i = 0; i + 1 < n; i++) {
        float2 a = pts[i], b = pts[i + 1];
        if (x <= b.x) {
            float span = fmax(b.x - a.x, 1e-6f);
            return a.y + (b.y - a.y) * (x - a.x) / span;
        }
    }
    return pts[n - 1].y;
}

kernel void pca_tone_hdr_map(constant pca_frame& f [[buffer(0)]], constant pca_tone_hdr_map_params& p [[buffer(1)]],
                             device const float* mean_buf [[buffer(2)]], constant float2* curve [[buffer(3)]],
                             device const float* log_mean [[buffer(4)]],
                             pca_in src [[texture(0)]], pca_in rgba [[texture(1)]], pca_in logl_t [[texture(2)]],
                             pca_in base_t [[texture(3)]], pca_out dst [[texture(4)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q);
    int2 r = q - p.origin;
    if (r.x < 0 || r.y < 0 || r.x >= p.size.x || r.y >= p.size.y) { dst.write(v, gid); return; }
    float4 c4 = rgba.read(uint2(r));
    if (p.prescale != 0u) { float k = pca_tone_key(log_mean); c4.xyz = float3(c4.x * k, c4.y * k, c4.z * k); }
    if (c4.w > 0.0f) {
        float mean = mean_buf[0];
        float logl = logl_t.read(uint2(r)).x, base = base_t.read(uint2(r)).x;
        float3 c = c4.xyz;
        float l0 = fmax(pca_tone_luma(c), 0.0f) + p.eps;
        float new_log = mean + (base - mean) * p.compress + (logl - base) * p.detail;
        float l1 = pow(fmax(exp(new_log) * p.exposure, 0.0f), 1.0f / p.gamma);
        float inv = 1.0f - l1;
        l1 += p.shadow / 100.0f * (inv * inv * inv) * 0.5f - p.highlight / 100.0f * (l1 * l1 * l1) * 0.5f;
        l1 = pca_tone_curve_eval(curve, p.curve_count, clamp(l1, 0.0f, 1.0f));
        float ratio = l1 / l0;
        float3 o = float3(c.x * ratio, c.y * ratio, c.z * ratio);
        float ll = pca_tone_luma(o);
        float mx = fmax(fmax(o.x, o.y), o.z), mn = fmin(fmin(o.x, o.y), o.z);
        float sat_now = mx > 0.0f ? (mx - mn) / mx : 0.0f;
        float s = 1.0f + p.saturation / 100.0f + p.vibrance / 100.0f * (1.0f - sat_now);
        float sm = fmax(s, 0.0f);
        o = float3(ll + (o.x - ll) * sm, ll + (o.y - ll) * sm, ll + (o.z - ll) * sm);
        c4.xyz = clamp(o, 0.0f, 1.0f);
    }
    if (p.encode != 0u) {
        c4.xyz = float3(pca_tone_linear_to_srgb(clamp(c4.x, 0.0f, 1.0f)), pca_tone_linear_to_srgb(clamp(c4.y, 0.0f, 1.0f)),
                        pca_tone_linear_to_srgb(clamp(c4.z, 0.0f, 1.0f)));
    }
    dst.write(pca_tone_from_rgba_px(v, c4, f), gid);
}
