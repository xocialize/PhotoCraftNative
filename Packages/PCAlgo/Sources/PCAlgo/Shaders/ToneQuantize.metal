// Port of photocraft-algo (crates/algo/src/quantize.rs, quantize/nearest.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Indexed Color's nearest-colour mapping (None / Pattern / Noise dither) and Bitmap's per-pixel
// methods (Threshold, Pattern, Halftone), bit-exact with the CPU.

constant uchar pca_tone_bayer[64] = {
    0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, 12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22, 3, 35, 11, 43, 1, 33, 9, 41,
    51, 19, 59, 27, 49, 17, 57, 25, 15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
};

/// 8×8 Bayer threshold in −0.5…0.5.
inline float pca_tone_bayer8(uint x, uint y) {
    return (float(pca_tone_bayer[(y % 8u) * 8u + x % 8u]) + 0.5f) / 64.0f - 0.5f;
}

/// quantize.rs's position hash → 0…1.
inline float pca_tone_qhash01(uint x, uint y, uint seed) {
    uint h = (x * 0x8da6b343u) ^ (y * 0xd8163841u) ^ (seed * 0xcb1ab31fu);
    h ^= h >> 13;
    h *= 0x5bd1e995u;
    h ^= h >> 15;
    return float(h & 0xffffu) / 65535.0f;
}

struct pca_tone_quantize_params {
    uint width;
    uint count;
    uint dither;      // 0 none, 2 pattern, 3 noise
    int transparent;  // -1: none
    float spread;
    uint pal_count;
    uint pad0;
    uint pad1;
};

kernel void pca_tone_quantize(constant pca_tone_quantize_params& p [[buffer(0)]], device float4* px [[buffer(1)]],
                              device uchar* idx [[buffer(2)]], constant float4* pal [[buffer(3)]],
                              uint i [[thread_position_in_grid]]) {
    if (i >= p.count) return;
    uint x = i % p.width, y = i / p.width;
    float4 pv = px[i];
    if (pv.w < 0.5f) {
        if (p.transparent >= 0) { idx[i] = uchar(p.transparent); px[i] = float4(0.0f); return; }
        if (pv.w <= 0.0f) return;
    }
    float3 c = pv.xyz;
    if (p.dither == 2u) { float t = pca_tone_bayer8(x, y) * p.spread; c = float3(c.x + t, c.y + t, c.z + t); }
    else if (p.dither == 3u) { float t = (pca_tone_qhash01(x, y, 7u) - 0.5f) * p.spread; c = float3(c.x + t, c.y + t, c.z + t); }
    uint k = 0u;
    if (!any(isnan(c))) {
        c = clamp(c, 0.0f, 1.0f);
        float3 q = float3(c.x * 255.0f, c.y * 255.0f, c.z * 255.0f);
        float best = FLT_MAX;
        for (uint j = 0u; j < p.pal_count; j++) {
            float3 e = pal[j].xyz;
            float d0 = e.x - q.x, d1 = e.y - q.y, d2 = e.z - q.z;
            float d = d0 * d0 + d1 * d1 + d2 * d2;
            if (d < best) { best = d; k = j; }
        }
    }
    idx[i] = uchar(k);
    float3 e = pal[k].xyz;
    px[i] = float4(e.x / 255.0f, e.y / 255.0f, e.z / 255.0f, p.transparent >= 0 ? 1.0f : pv.w);
}

struct pca_tone_bitmap_params {
    uint width;
    uint count;
    uint method;   // 0 threshold, 1 pattern, 3 halftone
    uint shape;    // round, ellipse, line, square, diamond, cross
    float cell;
    float sin_a;
    float cos_a;
    float pad0;
};

/// Halftone spot function in 0–1 for (u, v) in −1…1.
inline float pca_tone_spot(uint shape, float u, float v) {
    float s;
    switch (shape) {
        case 0u: s = 1.0f - (u * u + v * v) / 2.0f; break;
        case 1u: s = 1.0f - (u * u + 0.6f * v * v) / 1.6f; break;
        case 2u: s = 1.0f - fabs(v); break;
        case 3u: s = 1.0f - fmax(fabs(u), fabs(v)); break;
        case 4u: s = 1.0f - (fabs(u) + fabs(v)) / 2.0f; break;
        default: s = 1.0f - fmin(fabs(u), fabs(v)); break;
    }
    return clamp(s, 0.0f, 1.0f);
}

kernel void pca_tone_bitmap(constant pca_tone_bitmap_params& p [[buffer(0)]], device float* gray [[buffer(1)]],
                            constant float* table [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.count) return;
    float v = gray[i];
    uint x = i % p.width, y = i / p.width;
    if (p.method == 0u) { gray[i] = v >= 0.5f ? 1.0f : 0.0f; return; }
    if (p.method == 1u) { gray[i] = v > pca_tone_bayer8(x, y) + 0.5f ? 1.0f : 0.0f; return; }
    float fx = float(x) + 0.5f, fy = float(y) + 0.5f;
    float rx = fx * p.cos_a + fy * p.sin_a, ry = -fx * p.sin_a + fy * p.cos_a;
    float u = pca_rem_euclid_f(rx / p.cell, 1.0f) * 2.0f - 1.0f;
    float vv = pca_rem_euclid_f(ry / p.cell, 1.0f) * 2.0f - 1.0f;
    float sp = pca_tone_spot(p.shape, u, vv);
    uint lo = 0u, hi = 1024u;
    while (lo < hi) { uint m = (lo + hi) / 2u; if (table[m] < sp) lo = m + 1u; else hi = m; }
    gray[i] = float(lo) / 1024.0f >= v ? 0.0f : 1.0f;
}
