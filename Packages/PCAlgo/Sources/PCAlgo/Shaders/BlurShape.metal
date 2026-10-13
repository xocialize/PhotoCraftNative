// Port of photocraft-algo (crates/algo/src/blur2.rs: Prefix, lens_blur; shape_blur.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Span kernels over per-row prefix sums. photocraft's prefix sums are f64; here each row is
// summed by one thread with TwoSum compensation into a (high, low) float pair, and span
// differences are accumulated the same way, which keeps ~48 bits like the CPU's doubles.

struct pca_prefix_params {
    int width;
    int height;
    uint premul;
    uint pad;
};

inline void pca_two_sum(thread float4& s, thread float4& e, float4 v) {
    float4 t = s + v;
    float4 bb = t - s;
    e += (s - (t - bb)) + (v - bb);
    s = t;
}

/// One thread per row: hi/lo[x] = Σ of row pixels [0, x) (premultiplied first when asked).
kernel void pca_row_prefix(constant pca_frame& f [[buffer(0)]], constant pca_prefix_params& p [[buffer(1)]],
                           pca_in src [[texture(0)]], pca_out hi [[texture(1)]], pca_out lo [[texture(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
    int row = int(gid.x);
    if (row >= p.height) return;
    bool alpha = f.alpha != 0u;
    float4 s = float4(0.0f), e = float4(0.0f);
    hi.write(s, uint2(0, row));
    lo.write(e, uint2(0, row));
    for (int x = 0; x < p.width; x++) {
        float4 v = src.read(uint2(x, row));
        if (p.premul != 0u) v = pca_premul(v, alpha);
        pca_two_sum(s, e, v);
        hi.write(s, uint2(x + 1, row));
        lo.write(e, uint2(x + 1, row));
    }
}

struct pca_span {
    int dy;
    int a;
    int b;
    int pad;
};

struct pca_span_level {
    int start;
    int count;
    float inv_count;
    float pad;
};

/// Kernel mean of level `lv` at window pixel (wx, wy) (premultiplied).
inline float4 pca_span_mean(pca_in hi, pca_in lo, constant pca_frame& f, const device pca_span* spans,
                            constant pca_span_level& lv, float count, int wx, int wy) {
    int w = f.src_size.x, h = f.src_size.y;
    float4 s = float4(0.0f), e = float4(0.0f);
    for (int i = lv.start; i < lv.start + lv.count; i++) {
        pca_span sp = spans[i];
        int yy = wy + sp.dy;
        if (yy < 0 || yy >= h) continue;
        int x0 = clamp(wx + sp.a, 0, w), x1 = clamp(wx + sp.b + 1, 0, w);
        float4 d = (hi.read(uint2(x1, yy)) - hi.read(uint2(x0, yy))) + (lo.read(uint2(x1, yy)) - lo.read(uint2(x0, yy)));
        pca_two_sum(s, e, d);
    }
    return (s + e) / count;
}

struct pca_shape_params {
    int levels;
    int pad0;
    int pad1;
    int pad2;
};

kernel void pca_shape_blur(constant pca_frame& f [[buffer(0)]], constant pca_shape_params& p [[buffer(1)]],
                           const device pca_span* spans [[buffer(2)]], constant pca_span_level* levels [[buffer(3)]],
                           constant float* counts [[buffer(4)]], pca_in hi [[texture(0)]], pca_in lo [[texture(1)]],
                           pca_out dst [[texture(2)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 m = pca_span_mean(hi, lo, f, spans, levels[0], counts[0], q.x - f.src_origin.x, q.y - f.src_origin.y);
    dst.write(pca_unpremul(m, f.alpha != 0u), gid);
}

struct pca_lens_boost_params {
    float boost;
    float th;
    uint luma_rgb;
    uint pad;
};

/// Specular boost of the premultiplied window (Gray / RGB / Lab plane).
kernel void pca_lens_boost(constant pca_frame& f [[buffer(0)]], constant pca_lens_boost_params& p [[buffer(1)]],
                           pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool alpha = f.alpha != 0u;
    float4 v = pca_premul(pca_get(src, f, q), alpha);
    float a = alpha ? v.w : 1.0f;
    if (a > 0.0f) {
        float4 st = alpha ? float4(v.xyz / a, v.w) : v;
        float l = p.luma_rgb != 0u ? 0.299f * st.x + 0.587f * st.y + 0.114f * st.z : st.x;
        float k = 1.0f + p.boost * pca_smoothstep(p.th, p.th + 0.02f, l);
        int cc = alpha ? 3 : 4;
        for (int c = 0; c < cc; c++) v[c] = v[c] * k;
    }
    dst.write(v, gid);
}

struct pca_lens_params {
    uint depth;     // 0 none, 1 transparency, 2 map (map rect in frame.bounds_*)
    uint invert;
    float focal;
    float amount;
    uint gaussian;
    uint mono;
    uint seed;
    int levels;
};

kernel void pca_lens_blur(constant pca_frame& f [[buffer(0)]], constant pca_lens_params& p [[buffer(1)]],
                          const device pca_span* spans [[buffer(2)]], constant pca_span_level* levels [[buffer(3)]],
                          constant float* counts [[buffer(4)]], pca_in hi [[texture(0)]], pca_in lo [[texture(1)]],
                          pca_in src [[texture(2)]], pca_in map [[texture(3)]], pca_out dst [[texture(4)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool alpha = f.alpha != 0u;
    float lvmax = float(p.levels);
    float level = lvmax;
    if (p.depth != 0u) {
        float d = p.depth == 1u ? pca_get(src, f, q).w : pca_get_at(map, f.bounds_origin, f.bounds_size, q).x;
        if (p.invert != 0u) d = 1.0f - d;
        level = min(fabs(d - p.focal) * lvmax, lvmax);
    }
    int lo_i = int(floor(level));
    float fr = level - float(lo_i);
    int wx = q.x - f.src_origin.x, wy = q.y - f.src_origin.y;
    float4 m = pca_span_mean(hi, lo, f, spans, levels[lo_i], counts[lo_i], wx, wy);
    if (fr > 1e-4f && lo_i < p.levels) {
        float4 m2 = pca_span_mean(hi, lo, f, spans, levels[lo_i + 1], counts[lo_i + 1], wx, wy);
        m += (m2 - m) * fr;
    }
    float4 px = pca_unpremul(m, alpha);
    if (p.amount > 0.0f && (!alpha || px.w > 0.0f)) {
        for (uint k = 0; k < f.ncomp; k++) {
            uint ch = p.mono != 0u ? 0u : f.first_channel + k;
            if (p.gaussian == 0u) {
                px[k] += (pca_hash01(q.x, q.y, ch + 200u, p.seed) - 0.5f) * 2.0f * p.amount;
            } else {
                float u1 = max(pca_hash01(q.x, q.y, ch * 2u + 301u, p.seed), 1e-7f);
                float u2 = pca_hash01(q.x, q.y, ch * 2u + 302u, p.seed);
                px[k] += sqrt(-2.0f * log(u1)) * cos(6.28318530717958647692f * u2) * p.amount * 0.5f;
            }
        }
    }
    dst.write(px, gid);
}
