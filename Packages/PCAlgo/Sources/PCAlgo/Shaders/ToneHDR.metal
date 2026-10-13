// Port of photocraft-algo (crates/algo/src/hdr.rs: merge, tone_map), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Merge to HDR Pro on the GPU: the four tone-mapping methods (with their reductions) and the
// per-pixel radiance merge and ghost mask. Radiance is accumulated in f32 (photocraft: f64).

/// Rec. 709 luminance (photocraft `hdr::luma`).
inline float pca_tone_luma709(float3 c) {
    return 0.2126f * c.x + 0.7152f * c.y + 0.0722f * c.z;
}

struct pca_tone_tm_params {
    int2 origin;
    int2 size;
    float a;
    float b;
    float pad0;
    float pad1;
};

/// ln(max(luminance, a)) of the RGBA texture into .x.
kernel void pca_tone_tm_loglum(constant pca_frame& f [[buffer(0)]], constant pca_tone_tm_params& p [[buffer(1)]],
                               pca_in rgba [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    dst.write(float4(log(fmax(pca_tone_luma709(rgba.read(gid).xyz), p.a)), 0.0f, 0.0f, 0.0f), gid);
}

/// The RGBA pixel of output pixel `q` when inside the tone-mapped rect.
inline bool pca_tone_tm_px(constant pca_tone_tm_params& p, pca_in rgba, int2 q, thread float4& c) {
    int2 r = q - p.origin;
    if (r.x < 0 || r.y < 0 || r.x >= p.size.x || r.y >= p.size.y) return false;
    c = rgba.read(uint2(r));
    return true;
}

kernel void pca_tone_tm_exposure_gamma(constant pca_frame& f [[buffer(0)]], constant pca_tone_tm_params& p [[buffer(1)]],
                                       pca_in src [[texture(0)]], pca_in rgba [[texture(1)]], pca_out dst [[texture(2)]],
                                       uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q), c;
    if (!pca_tone_tm_px(p, rgba, q, c)) { dst.write(v, gid); return; }
    for (int i = 0; i < 3; i++) c[i] = pow(pca_tone_linear_to_srgb(clamp(c[i] * p.a, 0.0f, 1.0f)), 1.0f / p.b);
    dst.write(pca_tone_from_rgba_px(v, c, f), gid);
}

kernel void pca_tone_tm_highlight(constant pca_frame& f [[buffer(0)]], constant pca_tone_tm_params& p [[buffer(1)]],
                                  device const float* log_mean [[buffer(2)]],
                                  pca_in src [[texture(0)]], pca_in rgba [[texture(1)]], pca_out dst [[texture(2)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q), c;
    if (!pca_tone_tm_px(p, rgba, q, c)) { dst.write(v, gid); return; }
    float k = pca_tone_key(log_mean);
    float l = pca_tone_luma709(c.xyz) * k;
    float ld = l / (1.0f + l);
    float r = l > 1e-9f ? ld / l * k : 0.0f;
    for (int i = 0; i < 3; i++) c[i] = pca_tone_linear_to_srgb(clamp(c[i] * r, 0.0f, 1.0f));
    dst.write(pca_tone_from_rgba_px(v, c, f), gid);
}

// ---- Equalize Histogram ----

/// Partial (min, max) of values.x over pixels whose mask.w > 0, one per 256-thread group.
kernel void pca_tone_masked_minmax(constant pca_frame& f [[buffer(0)]], constant pca_tone_reduce_params& p [[buffer(1)]],
                                   device float2* partial [[buffer(2)]], pca_in values [[texture(0)]], pca_in mask [[texture(1)]],
                                   uint gid [[thread_position_in_grid]], uint tid [[thread_index_in_threadgroup]],
                                   uint tg [[threadgroup_position_in_grid]]) {
    threadgroup float lo[256];
    threadgroup float hi[256];
    float a = FLT_MAX, b = -FLT_MAX;
    if (gid < p.count) {
        uint2 xy = uint2(gid % uint(p.width), gid / uint(p.width));
        if (mask.read(xy).w > 0.0f) { float v = values.read(xy).x; a = fmin(a, v); b = fmax(b, v); }
    }
    lo[tid] = a;
    hi[tid] = b;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = 128u; s > 0u; s >>= 1) {
        if (tid < s) { lo[tid] = fmin(lo[tid], lo[tid + s]); hi[tid] = fmax(hi[tid], hi[tid + s]); }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0u) partial[tg] = float2(lo[0], hi[0]);
}

kernel void pca_tone_masked_minmax_final(constant pca_frame& f [[buffer(0)]], constant pca_tone_reduce_params& p [[buffer(1)]],
                                         device const float2* partial [[buffer(2)]], device float* lohi [[buffer(3)]],
                                         uint tid [[thread_index_in_threadgroup]]) {
    threadgroup float lo[256];
    threadgroup float hi[256];
    float a = FLT_MAX, b = -FLT_MAX;
    for (uint i = tid; i < p.groups; i += 256u) { a = fmin(a, partial[i].x); b = fmax(b, partial[i].y); }
    lo[tid] = a;
    hi[tid] = b;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = 128u; s > 0u; s >>= 1) {
        if (tid < s) { lo[tid] = fmin(lo[tid], lo[tid + s]); hi[tid] = fmax(hi[tid], hi[tid + s]); }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0u) { lohi[0] = lo[0]; lohi[1] = hi[0]; }
}

inline uint pca_tone_eq_bin(float v, device const float* lohi, bool clamp01) {
    float span = fmax(lohi[1] - lohi[0], 1e-6f);
    float t = (v - lohi[0]) / span;
    if (clamp01) t = clamp(t, 0.0f, 1.0f);
    float x = t * 1023.0f;
    return x > 0.0f ? min(uint(x), 1023u) : 0u;
}

/// 1024-bin histogram of log luminance over opaque pixels (threadgroup-local, exact counts).
kernel void pca_tone_tm_eq_hist(constant pca_frame& f [[buffer(0)]], constant pca_tone_hist_params& p [[buffer(1)]],
                                device const float* lohi [[buffer(2)]], device atomic_uint* hist [[buffer(3)]],
                                pca_in lv [[texture(0)]], pca_in rgba [[texture(1)]],
                                uint gid [[thread_position_in_grid]], uint tid [[thread_index_in_threadgroup]]) {
    threadgroup atomic_uint local[1024];
    for (uint i = tid; i < 1024u; i += 256u) atomic_store_explicit(&local[i], 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint i = gid; i < p.count; i += p.total) {
        uint2 xy = uint2(i % uint(p.width), i / uint(p.width));
        if (rgba.read(xy).w > 0.0f) atomic_fetch_add_explicit(&local[pca_tone_eq_bin(lv.read(xy).x, lohi, false)], 1u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint i = tid; i < 1024u; i += 256u) {
        uint v = atomic_load_explicit(&local[i], memory_order_relaxed);
        if (v > 0u) atomic_fetch_add_explicit(&hist[i], v, memory_order_relaxed);
    }
}

/// The cumulative distribution of the histogram (one thread).
kernel void pca_tone_tm_eq_cdf(constant pca_frame& f [[buffer(0)]], constant uint& unused [[buffer(1)]],
                               device const uint* hist [[buffer(2)]], device float* cdf [[buffer(3)]],
                               uint gid [[thread_position_in_grid]]) {
    if (gid != 0u) return;
    uint total = 0u;
    for (int b = 0; b < 1024; b++) total += hist[b];
    float t = float(max(total, 1u));
    uint acc = 0u;
    for (int b = 0; b < 1024; b++) {
        acc += hist[b];
        cdf[b] = float(acc) / t;
    }
}

kernel void pca_tone_tm_equalize(constant pca_frame& f [[buffer(0)]], constant pca_tone_tm_params& p [[buffer(1)]],
                                 device const float* lohi [[buffer(2)]], device const float* cdf [[buffer(3)]],
                                 pca_in src [[texture(0)]], pca_in rgba [[texture(1)]], pca_in lv [[texture(2)]], pca_out dst [[texture(3)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q), c;
    if (!pca_tone_tm_px(p, rgba, q, c)) { dst.write(v, gid); return; }
    float target = cdf[pca_tone_eq_bin(lv.read(uint2(q - p.origin)).x, lohi, true)];
    float tl = pca_tone_srgb_to_linear(target);
    float l = fmax(pca_tone_luma709(c.xyz), 1e-7f);
    for (int i = 0; i < 3; i++) c[i] = pca_tone_linear_to_srgb(clamp(c[i] / l * tl, 0.0f, 1.0f));
    dst.write(pca_tone_from_rgba_px(v, c, f), gid);
}

// ---- Merge ----

struct pca_tone_hdr_merge_params {
    int width;
    int height;
    int images;
    int base;
    uint pixels;
    uint pad0;
    uint pad1;
    uint pad2;
};

/// Hat weight on a 0–255 code value.
inline float pca_tone_hat(float z) {
    return fmax(z <= 127.5f ? z : 255.0f - z, 0.0f);
}

/// The response curve `g` of channel c (256 entries) interpolated at code value v·255.
inline float pca_tone_g_at(constant float* resp, int c, float v) {
    float x = clamp(v, 0.0f, 1.0f) * 255.0f;
    int i = min(int(floor(x)), 254);
    float t = x - float(i);
    return resp[c * 256 + i] * (1.0f - t) + resp[c * 256 + i + 1] * t;
}

/// Hat-weighted average of g(Z) − ln Δt over the exposures, per channel; alpha the max.
kernel void pca_tone_hdr_merge(constant pca_frame& f [[buffer(0)]], constant pca_tone_hdr_merge_params& p [[buffer(1)]],
                               device const float4* imgs [[buffer(2)]], constant float* resp [[buffer(3)]],
                               constant float* ldt [[buffer(4)]], device float4* out [[buffer(5)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.width || int(gid.y) >= p.height) return;
    uint i = gid.y * uint(p.width) + gid.x;
    float4 o = float4(0.0f);
    for (int c = 0; c < 3; c++) {
        float num = 0.0f, den = 0.0f;
        for (int j = 0; j < p.images; j++) {
            float v = imgs[uint(j) * p.pixels + i][c];
            float wt = pca_tone_hat(clamp(v, 0.0f, 1.0f) * 255.0f);
            num += wt * (pca_tone_g_at(resp, c, v) - ldt[j]);
            den += wt;
        }
        float le;
        if (den > 1e-6f) le = num / den;
        else {
            // Saturated everywhere: darkest exposure if bright, brightest if dark.
            float s = 0.0f;
            for (int j = 0; j < p.images; j++) s += imgs[uint(j) * p.pixels + i][c];
            bool bright = s / float(p.images) > 0.5f;
            int jb = 0;
            for (int j = 1; j < p.images; j++) {
                if (bright ? ldt[j] < ldt[jb] : ldt[j] > ldt[jb]) jb = j;
            }
            le = pca_tone_g_at(resp, c, imgs[uint(jb) * p.pixels + i][c]) - ldt[jb];
        }
        o[c] = exp(le);
    }
    float alpha = 0.0f;
    for (int j = 0; j < p.images; j++) alpha = fmax(alpha, imgs[uint(j) * p.pixels + i].w);
    o.w = alpha;
    out[i] = o;
}

/// 1 where the per-exposure log radiance estimates disagree (weighted std > 0.35), into .x.
kernel void pca_tone_hdr_ghost_score(constant pca_frame& f [[buffer(0)]], constant pca_tone_hdr_merge_params& p [[buffer(1)]],
                                     device const float4* imgs [[buffer(2)]], constant float* resp [[buffer(3)]],
                                     constant float* ldt [[buffer(4)]], pca_out mask [[texture(0)]],
                                     uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.width || int(gid.y) >= p.height) return;
    uint i = gid.y * uint(p.width) + gid.x;
    float s = 0.0f, s2 = 0.0f, sw = 0.0f;
    for (int j = 0; j < p.images; j++) {
        float4 q = imgs[uint(j) * p.pixels + i];
        float wt = pca_tone_hat(pca_tone_luma709(q.xyz) * 255.0f);
        if (wt < 20.0f) continue;
        float lr = 0.0f;
        for (int c = 0; c < 3; c++) lr += 0.33f * (pca_tone_g_at(resp, c, q[c]) - ldt[j]);
        s += wt * lr;
        s2 += wt * lr * lr;
        sw += wt;
    }
    float score = 0.0f;
    if (sw > 0.0f) {
        float m = s / sw;
        score = sqrt(fmax(s2 / sw - m * m, 0.0f));
    }
    mask.write(float4(score > 0.35f ? 1.0f : 0.0f, 0.0f, 0.0f, 0.0f), gid);
}

/// The feathered ghost mask (blurred × 3, ≤ 1) mixes in the base exposure's radiance.
kernel void pca_tone_hdr_ghost_mix(constant pca_frame& f [[buffer(0)]], constant pca_tone_hdr_merge_params& p [[buffer(1)]],
                                   device const float4* imgs [[buffer(2)]], constant float* resp [[buffer(3)]],
                                   constant float* ldt [[buffer(4)]], device float4* out [[buffer(5)]],
                                   device atomic_uint* count [[buffer(6)]], pca_in mask [[texture(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.width || int(gid.y) >= p.height) return;
    uint i = gid.y * uint(p.width) + gid.x;
    float g = fmin(mask.read(gid).x * 3.0f, 1.0f);
    if (g > 0.5f) atomic_fetch_add_explicit(count, 1u, memory_order_relaxed);
    if (g <= 0.0f) return;
    float4 q = imgs[uint(p.base) * p.pixels + i];
    float4 o = out[i];
    for (int c = 0; c < 3; c++) {
        float e = exp(pca_tone_g_at(resp, c, q[c]) - ldt[p.base]);
        o[c] = o[c] * (1.0f - g) + e * g;
    }
    out[i] = o;
}
