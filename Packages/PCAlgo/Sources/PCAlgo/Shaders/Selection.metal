// Port of photocraft-algo (crates/algo/src/selection.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Selection masks on buffers (binding: buffer(0) params, buffer(1…) data; see SelectionGPU.swift):
// magic wand similarity, flood propagation sweeps and anti-aliasing; Color Range (samples,
// localized), the Lab box, hue families and tonal ranges. Arithmetic mirrors the Swift reference
// operation for operation (no FMA: 00_Common.metal turns contraction off), NaN semantics
// included (Rust's `f32::max`/`min` are `fmax`/`fmin`; `f32::clamp` keeps NaN).

#define PCA_SEL_NO_SEED 0xffffffffu

/// Rust `f32::clamp` (NaN stays NaN; MSL's `clamp` would return the lower bound).
inline float pca_sel_clamp(float v, float lo, float hi) { return isnan(v) ? v : min(max(v, lo), hi); }

struct pca_sel_grid {
    uint w;
    uint h;
    uint pad0;
    uint pad1;
};

// MARK: Magic wand

struct pca_sel_wand_params {
    float4 target;
    float t;          // tolerance + 1e-3 (levels)
    uint n;
    uint seed;
    uint contiguous;
};

/// photocraft `close` per pixel; marks the seed (contiguous) or every similar pixel (global).
kernel void pca_sel_wand_similar(constant pca_sel_wand_params& p [[buffer(0)]], device const float4* px [[buffer(1)]],
                                 device uchar* sim [[buffer(2)]], device uchar* mark [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.n) return;
    float4 a = px[i], b = p.target;
    bool s = (a.w == 0.0f && b.w == 0.0f) ||
             (fabs(a.x - b.x) * 255.0f <= p.t && fabs(a.y - b.y) * 255.0f <= p.t && fabs(a.z - b.z) * 255.0f <= p.t &&
              fabs(a.w - b.w) * 255.0f <= p.t);
    sim[i] = s ? 1 : 0;
    mark[i] = p.contiguous != 0u ? (i == p.seed ? 1 : 0) : (s ? 1 : 0);
}

/// One propagation sweep per row (left to right, then right to left): a similar pixel next to a
/// marked one is marked. Repeated with the column sweeps until nothing changes, this marks the
/// 4-connected component of the seed.
kernel void pca_sel_flood_rows(constant pca_sel_grid& g [[buffer(0)]], device const uchar* sim [[buffer(1)]], device uchar* mark [[buffer(2)]],
                               device atomic_uint* changed [[buffer(3)]], uint y [[thread_position_in_grid]]) {
    if (y >= g.h) return;
    uint base = y * g.w;
    bool any = false;
    for (uint x = 1; x < g.w; x++) {
        uint i = base + x;
        if (mark[i] == 0 && sim[i] != 0 && mark[i - 1] != 0) { mark[i] = 1; any = true; }
    }
    for (int x = int(g.w) - 2; x >= 0; x--) {
        uint i = base + uint(x);
        if (mark[i] == 0 && sim[i] != 0 && mark[i + 1] != 0) { mark[i] = 1; any = true; }
    }
    if (any) atomic_store_explicit(changed, 1u, memory_order_relaxed);
}

kernel void pca_sel_flood_cols(constant pca_sel_grid& g [[buffer(0)]], device const uchar* sim [[buffer(1)]], device uchar* mark [[buffer(2)]],
                               device atomic_uint* changed [[buffer(3)]], uint x [[thread_position_in_grid]]) {
    if (x >= g.w) return;
    uint w = g.w;
    bool any = false;
    for (uint y = 1; y < g.h; y++) {
        uint i = y * w + x;
        if (mark[i] == 0 && sim[i] != 0 && mark[i - w] != 0) { mark[i] = 1; any = true; }
    }
    for (int y = int(g.h) - 2; y >= 0; y--) {
        uint i = uint(y) * w + x;
        if (mark[i] == 0 && sim[i] != 0 && mark[i + w] != 0) { mark[i] = 1; any = true; }
    }
    if (any) atomic_store_explicit(changed, 1u, memory_order_relaxed);
}

kernel void pca_sel_marks_to_mask(constant pca_sel_grid& g [[buffer(0)]], device const uchar* mark [[buffer(1)]], device float* out [[buffer(2)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= g.w || gid.y >= g.h) return;
    uint i = gid.y * g.w + gid.x;
    out[i] = mark[i] != 0 ? 1.0f : 0.0f;
}

/// photocraft `antialias`: edge pixels become the 3×3 average (neighbours outside the mask count
/// as the pixel), kept mostly selected when selected.
kernel void pca_sel_antialias(constant pca_sel_grid& g [[buffer(0)]], device const float* src [[buffer(1)]], device float* dst [[buffer(2)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= g.w || gid.y >= g.h) return;
    int w = int(g.w), h = int(g.h), x = int(gid.x), y = int(gid.y);
    int i = y * w + x;
    float c = src[i];
    float sum = 0.0f, cnt = 0.0f;
    bool edge = false;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int xx = x + dx, yy = y + dy;
            float v = (xx < 0 || yy < 0 || xx >= w || yy >= h) ? c : src[yy * w + xx];
            edge = edge || v != c;
            sum += v;
            cnt += 1.0f;
        }
    }
    dst[i] = edge ? (c > 0.5f ? 0.5f + 0.5f * sum / cnt : 0.5f * sum / cnt) : c;
}

// MARK: Color Range

struct pca_sel_range_params {
    float f;          // fuzziness + 1
    uint samples;
    uint w;
    uint localized;
    float radius;
    uint n;
    uint pad0;
    uint pad1;
};

/// Rust `fold(0.0, f32::max)` of the three colour distances in levels.
inline float pca_sel_level_distance(float4 p, float3 c) {
    float d = 0.0f;
    d = fmax(d, fabs(p.x - c.x) * 255.0f);
    d = fmax(d, fabs(p.y - c.y) * 255.0f);
    d = fmax(d, fabs(p.z - c.z) * 255.0f);
    return d;
}

/// Color Range (Sampled Colors): best match over the samples (`s[2k]` = colour + has-position,
/// `s[2k + 1].xy` = position), each fading with distance when localized.
kernel void pca_sel_color_range(constant pca_sel_range_params& p [[buffer(0)]], device const float4* px [[buffer(1)]],
                                device const float4* s [[buffer(2)]], device float* out [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.n) return;
    float4 c = px[i];
    if (c.w <= 0.0f) { out[i] = 0.0f; return; }
    float x = float(i % p.w), y = float(i / p.w);
    float best = 0.0f;
    for (uint k = 0; k < p.samples; k++) {
        float4 col = s[2 * k];
        float kk = pca_sel_clamp(1.0f - pca_sel_level_distance(c, col.xyz) / p.f, 0.0f, 1.0f);
        if (p.localized != 0u && col.w != 0.0f) {
            float2 at = s[2 * k + 1].xy;
            float dx = x - at.x, dy = y - at.y;
            float dist = pca_dis_sqrt(dx * dx + dy * dy);
            kk *= pca_sel_clamp(1.0f - dist / fmax(p.radius, 1.0f), 0.0f, 1.0f);
        }
        best = fmax(best, kk);
    }
    out[i] = best;
}

struct pca_sel_lab_params {
    float4 lo;
    float4 hi;
    float fuzziness;
    uint grid8;
    uint w;
    uint nat;
    float radius;
    uint n;
    uint pad0;
    uint pad1;
};

inline float pca_sel_outside(float v, float lo, float hi) { return fmax(fmax(lo - v, v - hi), 0.0f); }

inline float pca_sel_ab(float v, float lo, float hi, bool grid8) {
    if (!grid8) return pca_sel_outside(v, lo, hi);
    if (v > hi) return v - hi + 0.5f;
    if (v < lo) return fmax(lo - v - 0.5f, 0.0f);
    return 0.0f;
}

/// photocraft `selection::coverage` (Lab box membership; see Selection.swift).
inline float pca_sel_lab_coverage(float3 lab, float3 lo, float3 hi, float fuzziness, bool grid8) {
    if (isnan(fuzziness) || fuzziness <= 0.0f) {
        float d = fmax(fmax(pca_sel_outside(lab.x, lo.x, hi.x) * 2.55f, pca_sel_outside(lab.y, lo.y, hi.y)), pca_sel_outside(lab.z, lo.z, hi.z));
        return d < 0.5f ? 1.0f : 0.0f;
    }
    float dl = pca_sel_outside(lab.x, lo.x, hi.x) * 2.55f;
    float da = 3.0f * pca_sel_ab(lab.y, lo.y, hi.y, grid8);
    float db = 3.0f * pca_sel_ab(lab.z, lo.z, hi.z, grid8);
    float t = fmax(fmax(dl, da), db) / (fuzziness * 256.0f / 255.0f);
    float v = t <= 0.5f ? 1.0f - 2.0f * t * t : (t < 1.0f ? 2.0f * (1.0f - t) * (1.0f - t) : 0.0f);
    return pca_sel_clamp(floor(v * 256.0f), 0.0f, 255.0f) / 255.0f;
}

kernel void pca_sel_color_range_lab(constant pca_sel_lab_params& p [[buffer(0)]], device const float4* lab [[buffer(1)]],
                                    device const float2* at [[buffer(2)]], device float* out [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.n) return;
    float4 c = lab[i];
    if (isnan(c.w) || c.w <= 0.0f) { out[i] = 0.0f; return; }
    float k = pca_sel_lab_coverage(c.xyz, p.lo.xyz, p.hi.xyz, p.fuzziness, p.grid8 != 0u);
    if (p.nat > 0u && k > 0.0f) {
        float x = float(i % p.w), y = float(i / p.w);
        float near = 0.0f;
        for (uint s = 0; s < p.nat; s++) {
            float dx = x - at[s].x, dy = y - at[s].y;
            near = fmax(near, pca_sel_clamp(1.0f - pca_dis_sqrt(dx * dx + dy * dy) / fmax(p.radius, 1.0f), 0.0f, 1.0f));
        }
        k *= near;
    }
    out[i] = k;
}

struct pca_sel_hue_params {
    float center;
    uint n;
    uint pad0;
    uint pad1;
};

/// Hue (degrees) and chroma of an RGB colour (photocraft `hue_chroma`).
inline float2 pca_sel_hue_chroma(float3 c) {
    float mx = fmax(fmax(c.x, c.y), c.z), mn = fmin(fmin(c.x, c.y), c.z);
    float d = mx - mn;
    if (d <= 0.0f) return float2(0.0f);
    float h;
    if (mx == c.x) h = pca_rem_euclid_f((c.y - c.z) / d, 6.0f);
    else if (mx == c.y) h = (c.z - c.x) / d + 2.0f;
    else h = (c.x - c.y) / d + 4.0f;
    return float2(h * 60.0f, d);
}

kernel void pca_sel_hue_range(constant pca_sel_hue_params& p [[buffer(0)]], device const float4* px [[buffer(1)]], device float* out [[buffer(2)]],
                              uint i [[thread_position_in_grid]]) {
    if (i >= p.n) return;
    float4 c = px[i];
    if (c.w <= 0.0f) { out[i] = 0.0f; return; }
    float2 hc = pca_sel_hue_chroma(float3(pca_sel_clamp(c.x, 0.0f, 1.0f), pca_sel_clamp(c.y, 0.0f, 1.0f), pca_sel_clamp(c.z, 0.0f, 1.0f)));
    float dh = pca_rem_euclid_f(hc.x - p.center, 360.0f);
    dh = fmin(dh, 360.0f - dh);
    out[i] = pca_sel_clamp(pca_sel_clamp(1.0f - dh / 60.0f, 0.0f, 1.0f) * hc.y, 0.0f, 1.0f);
}

struct pca_sel_tone_params {
    float lo;
    float hi;
    float ramp;
    uint n;
};

kernel void pca_sel_tone_range(constant pca_sel_tone_params& p [[buffer(0)]], device const float4* px [[buffer(1)]], device float* out [[buffer(2)]],
                               uint i [[thread_position_in_grid]]) {
    if (i >= p.n) return;
    float4 c = px[i];
    if (c.w <= 0.0f) { out[i] = 0.0f; return; }
    float l = pca_sel_clamp(0.299f * c.x + 0.587f * c.y + 0.114f * c.z, 0.0f, 1.0f) * 255.0f;
    float o = l < p.lo ? p.lo - l : (l > p.hi ? l - p.hi : 0.0f);
    out[i] = pca_sel_clamp(1.0f - o / p.ramp, 0.0f, 1.0f);
}
