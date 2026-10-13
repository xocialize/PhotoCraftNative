// Port of photocraft-algo (crates/algo/src/matting.rs: box_mean, guided_filter_color; segment/gmm.rs; segment/slic.rs; segment/focus.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Segment-area kernels on shared buffers (buffer(0) params, buffer(1…) data; SegmentGPU.swift):
// clipped box means (Kahan-compensated running sums over segments), the colour guided filter's
// product planes / per-pixel solve / output, GMM data costs, the SLIC assignment step and the
// focus measure's Laplacian.

struct pca_seg_box_params {
    uint w;
    uint h;
    uint r;
    uint planes;
    uint segment;
    uint pad0;
    uint pad1;
    uint pad2;
};

/// A Kahan-compensated Float sum.
struct pca_seg_ksum {
    float s;
    float c;
};

inline void pca_seg_kadd(thread pca_seg_ksum& k, float v) {
    float y = v - k.c;
    float t = k.s + y;
    k.c = (t - k.s) - y;
    k.s = t;
}

/// Box means along rows (window clipped to the row, divided by the pixel count): thread =
/// (plane · h + row, segment of `segment` columns).
kernel void pca_seg_box_rows(constant pca_seg_box_params& p [[buffer(0)]], device const float* src [[buffer(1)]], device float* dst [[buffer(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.h * p.planes) return;
    int w = int(p.w), r = int(p.r);
    int x0 = int(gid.y * p.segment);
    if (x0 >= w) return;
    int x1 = min(x0 + int(p.segment), w);
    uint plane = gid.x / p.h, row = gid.x % p.h;
    device const float* s = src + plane * p.w * p.h + row * p.w;
    device float* d = dst + plane * p.w * p.h + row * p.w;
    pca_seg_ksum acc = {0.0f, 0.0f};
    for (int i = max(x0 - r, 0); i <= min(x0 + r, w - 1); i++) pca_seg_kadd(acc, s[i]);
    for (int x = x0; x < x1; x++) {
        int lo = max(x - r, 0), hi = min(x + r + 1, w);
        d[x] = acc.s / float(hi - lo);
        if (x + r + 1 < w) pca_seg_kadd(acc, s[x + r + 1]);
        if (x - r >= 0) pca_seg_kadd(acc, -s[x - r]);
    }
}

/// Box means down columns: thread = (plane · w + column, segment of rows).
kernel void pca_seg_box_cols(constant pca_seg_box_params& p [[buffer(0)]], device const float* src [[buffer(1)]], device float* dst [[buffer(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.w * p.planes) return;
    int h = int(p.h), r = int(p.r);
    int y0 = int(gid.y * p.segment);
    if (y0 >= h) return;
    int y1 = min(y0 + int(p.segment), h);
    uint plane = gid.x / p.w, col = gid.x % p.w;
    device const float* s = src + plane * p.w * p.h + col;
    device float* d = dst + plane * p.w * p.h + col;
    uint w = p.w;
    pca_seg_ksum acc = {0.0f, 0.0f};
    for (int i = max(y0 - r, 0); i <= min(y0 + r, h - 1); i++) pca_seg_kadd(acc, s[uint(i) * w]);
    for (int y = y0; y < y1; y++) {
        int lo = max(y - r, 0), hi = min(y + r + 1, h);
        d[uint(y) * w] = acc.s / float(hi - lo);
        if (y + r + 1 < h) pca_seg_kadd(acc, s[uint(y + r + 1) * w]);
        if (y - r >= 0) pca_seg_kadd(acc, -s[uint(y - r) * w]);
    }
}

struct pca_seg_guided_params {
    uint n;
    float eps;
    uint pad0;
    uint pad1;
};

/// The 13 planes the colour guided filter averages: I (3), p, I·p (3), I·Iᵀ (6, upper triangle).
kernel void pca_seg_guided_prep(constant pca_seg_guided_params& p [[buffer(0)]], device const float4* g [[buffer(1)]], device const float* pv [[buffer(2)]],
                                device float* planes [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.n) return;
    float3 c = g[i].xyz;
    float q = pv[i];
    uint n = p.n;
    planes[i] = c.x; planes[n + i] = c.y; planes[2 * n + i] = c.z; planes[3 * n + i] = q;
    planes[4 * n + i] = c.x * q; planes[5 * n + i] = c.y * q; planes[6 * n + i] = c.z * q;
    planes[7 * n + i] = c.x * c.x; planes[8 * n + i] = c.x * c.y; planes[9 * n + i] = c.x * c.z;
    planes[10 * n + i] = c.y * c.y; planes[11 * n + i] = c.y * c.z; planes[12 * n + i] = c.z * c.z;
}

/// a = (Σ + εU)⁻¹ cov(I, p), b = mean p − a·mean I (photocraft's solve, in Float).
kernel void pca_seg_guided_solve(constant pca_seg_guided_params& p [[buffer(0)]], device const float* m [[buffer(1)]], device float* ab [[buffer(2)]],
                                 uint i [[thread_position_in_grid]]) {
    if (i >= p.n) return;
    uint n = p.n;
    float m0 = m[i], m1 = m[n + i], m2 = m[2 * n + i], mp = m[3 * n + i];
    float e = p.eps;
    float rr = m[7 * n + i] - m0 * m0 + e, rg = m[8 * n + i] - m0 * m1, rb = m[9 * n + i] - m0 * m2;
    float gg = m[10 * n + i] - m1 * m1 + e, gb = m[11 * n + i] - m1 * m2, bb = m[12 * n + i] - m2 * m2 + e;
    float c0 = m[4 * n + i] - m0 * mp, c1 = m[5 * n + i] - m1 * mp, c2 = m[6 * n + i] - m2 * mp;
    float j00 = gg * bb - gb * gb, j01 = gb * rb - rg * bb, j02 = rg * gb - gg * rb;
    float j11 = rr * bb - rb * rb, j12 = rb * rg - rr * gb, j22 = rr * gg - rg * rg;
    float det = rr * j00 + rg * j01 + rb * j02;
    float a0 = 0.0f, a1 = 0.0f, a2 = 0.0f;
    if (!(fabs(det) < 1e-30f)) {
        a0 = (j00 * c0 + j01 * c1 + j02 * c2) / det;
        a1 = (j01 * c0 + j11 * c1 + j12 * c2) / det;
        a2 = (j02 * c0 + j12 * c1 + j22 * c2) / det;
    }
    ab[i] = a0; ab[n + i] = a1; ab[2 * n + i] = a2; ab[3 * n + i] = mp - a0 * m0 - a1 * m1 - a2 * m2;
}

kernel void pca_seg_guided_out(constant pca_seg_guided_params& p [[buffer(0)]], device const float4* g [[buffer(1)]], device const float* mab [[buffer(2)]],
                               device float* out [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.n) return;
    uint n = p.n;
    float3 c = g[i].xyz;
    out[i] = mab[i] * c.x + mab[n + i] * c.y + mab[2 * n + i] * c.z + mab[3 * n + i];
}

struct pca_seg_cost_params {
    uint n;
    uint nfg;
    uint nbg;
    uint pad0;
};

/// −ln p(z) of a mixture packed as (mean, log-norm), inv rows; clamped to −50…200 (NaN kept).
inline float pca_seg_neg_log(device const float4* comps, uint count, float3 z) {
    float mx = -FLT_MAX;
    float vals[16];
    uint n = min(count, 16u);
    for (uint c = 0; c < n; c++) {
        float4 mu = comps[4 * c];
        float3 d = z - mu.xyz;
        float3 r0 = comps[4 * c + 1].xyz, r1 = comps[4 * c + 2].xyz, r2 = comps[4 * c + 3].xyz;
        float q = d.x * (r0.x * d.x + r0.y * d.y + r0.z * d.z) + d.y * (r1.x * d.x + r1.y * d.y + r1.z * d.z) + d.z * (r2.x * d.x + r2.y * d.y + r2.z * d.z);
        vals[c] = mu.w - 0.5f * q;
        mx = fmax(mx, vals[c]);
    }
    float s = 0.0f;
    for (uint c = 0; c < n; c++) s += exp(vals[c] - mx);
    float v = -(mx + log(s));
    return isnan(v) ? v : clamp(v, -50.0f, 200.0f);
}

kernel void pca_seg_gmm_costs(constant pca_seg_cost_params& p [[buffer(0)]], device const float4* px [[buffer(1)]], device const float4* fg [[buffer(2)]],
                              device const float4* bg [[buffer(3)]], device float* out [[buffer(4)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.n) return;
    float3 z = px[i].xyz;
    out[i] = pca_seg_neg_log(fg, p.nfg, z);
    out[p.n + i] = pca_seg_neg_log(bg, p.nbg, z);
}

struct pca_seg_slic_params {
    uint w;
    uint h;
    int r;
    float wxy;
    int nbx;
    int nby;
    int bucket;
    int pad0;
};

/// SLIC assignment: the nearest centre (colour + weighted xy distance) whose (2r + 1)² window
/// covers the pixel, ties to the lowest index; centres are found through a bucket grid of side r.
kernel void pca_seg_slic_assign(constant pca_seg_slic_params& p [[buffer(0)]], device const float4* lab [[buffer(1)]], device const float4* centers [[buffer(2)]],
                                device const uint* starts [[buffer(3)]], device const uint* items [[buffer(4)]], device uint* labels [[buffer(5)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.w || gid.y >= p.h) return;
    int x = int(gid.x), y = int(gid.y);
    uint i = gid.y * p.w + gid.x;
    float3 c = lab[i].xyz;
    int bx = x / p.bucket, by = y / p.bucket;
    float best = FLT_MAX;
    int bestK = -1;
    for (int yy = max(by - 1, 0); yy <= min(by + 1, p.nby - 1); yy++) {
        for (int xx = max(bx - 1, 0); xx <= min(bx + 1, p.nbx - 1); xx++) {
            uint b = uint(yy * p.nbx + xx);
            for (uint j = starts[b]; j < starts[b + 1]; j++) {
                int k = int(items[j]);
                float4 cl = centers[2 * k], cp = centers[2 * k + 1];
                if (abs(x - int(cp.z)) > p.r || abs(y - int(cp.w)) > p.r) continue;
                float ex = c.x - cl.x, ey = c.y - cl.y, ez = c.z - cl.z;
                float dc = ex * ex + ey * ey + ez * ez;
                float dx = float(x) - cp.x, dy = float(y) - cp.y;
                float d = dc + (dx * dx + dy * dy) * p.wxy;
                if (d < best || (bestK >= 0 && d == best && k < bestK)) { best = d; bestK = k; }
            }
        }
    }
    if (bestK >= 0) labels[i] = uint(bestK);
}

struct pca_seg_focus_params {
    uint w;
    uint h;
    uint pad0;
    uint pad1;
};

inline float pca_seg_luma(device const float4* px, uint w, uint x, uint y) {
    float4 c = px[y * w + x];
    return 0.299f * c.x + 0.587f * c.y + 0.114f * c.z;
}

/// |2c − l − r| + |2c − u − d| of the luma, edges clamped (photocraft `sharpness`).
kernel void pca_seg_laplacian(constant pca_seg_focus_params& p [[buffer(0)]], device const float4* px [[buffer(1)]], device float* lap [[buffer(2)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.w || gid.y >= p.h) return;
    uint x = gid.x, y = gid.y, w = p.w;
    float c = pca_seg_luma(px, w, x, y);
    float l = pca_seg_luma(px, w, x > 0 ? x - 1 : 0, y), r = pca_seg_luma(px, w, min(x + 1, w - 1), y);
    float u = pca_seg_luma(px, w, x, y > 0 ? y - 1 : 0), d = pca_seg_luma(px, w, x, min(y + 1, p.h - 1));
    lap[y * w + x] = fabs(2.0f * c - l - r) + fabs(2.0f * c - u - d);
}
