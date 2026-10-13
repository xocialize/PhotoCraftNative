// Port of photocraft-algo (crates/algo/src/pyramid.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Burt–Adelson pyramids on interleaved `w × h × ch` float buffers (any channel count): REDUCE and
// EXPAND as separable passes with photocraft's clamped borders and summation order, the per-level
// blend / focus-stack selection / halo folds fused into the vertical EXPAND pass, region energy,
// local deviation + entropy and the residual's Pareto rule. One thread per output pixel; every
// sum runs in the CPU reference's order (no FMA: see 00_Common.metal), so results are bit-exact
// except halo control's exp/log weights.

#pragma METAL fp contract(off)

constant float pca_pho_k[5] = {0.0625f, 0.25f, 0.375f, 0.25f, 0.0625f};

struct pca_pho_dims {
    int sw;        // source width
    int sh;        // source height
    int dw;        // destination width
    int dh;        // destination height
    int ch;        // channels per pixel
    uint mode;
    uint flags;    // bit 0: the level has a coarser one to EXPAND; bit 1: first image
    uint base;     // element offset into packed outputs
    float a;
    float b;
    float c;
    float d;
};

#define PCA_PHO_HAS_UP 1u
#define PCA_PHO_FIRST 2u

/// Horizontal half of REDUCE: even columns of the 5-tap binomial, clamped (photocraft `reduce`).
kernel void pca_pho_reduce_h(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                             device const float* src [[buffer(2)]], device float* dst [[buffer(3)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.sh) return;
    int ch = p.ch;
    uint o = (uint(y) * uint(p.dw) + uint(x)) * uint(ch);
    for (int c = 0; c < ch; c++) {
        float s = 0.0f;
        for (int k = 0; k < 5; k++) {
            int sx = clamp(2 * x + k - 2, 0, p.sw - 1);
            s += pca_pho_k[k] * src[(uint(y) * uint(p.sw) + uint(sx)) * uint(ch) + uint(c)];
        }
        dst[o + uint(c)] = s;
    }
}

/// Vertical half of REDUCE: even rows of the horizontally filtered `tmp` (dw × sh).
kernel void pca_pho_reduce_v(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                             device const float* tmp [[buffer(2)]], device float* dst [[buffer(3)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.dh) return;
    int ch = p.ch;
    uint o = (uint(y) * uint(p.dw) + uint(x)) * uint(ch);
    for (int c = 0; c < ch; c++) {
        float s = 0.0f;
        for (int k = 0; k < 5; k++) {
            int sy = clamp(2 * y + k - 2, 0, p.sh - 1);
            s += pca_pho_k[k] * tmp[(uint(sy) * uint(p.dw) + uint(x)) * uint(ch) + uint(c)];
        }
        dst[o + uint(c)] = s;
    }
}

/// Horizontal half of EXPAND: zero insertion + the binomial ×2 along rows (sw × sh → dw × sh).
kernel void pca_pho_expand_h(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                             device const float* src [[buffer(2)]], device float* dst [[buffer(3)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.sh) return;
    int ch = p.ch;
    uint o = (uint(y) * uint(p.dw) + uint(x)) * uint(ch);
    for (int c = 0; c < ch; c++) {
        float s = 0.0f;
        for (int k = 0; k < 5; k++) {
            int t = x + k - 2;
            if ((t & 1) != 0) continue;
            int sx = clamp(t / 2, 0, p.sw - 1);
            s += (2.0f * pca_pho_k[k]) * src[(uint(y) * uint(p.sw) + uint(sx)) * uint(ch) + uint(c)];
        }
        dst[o + uint(c)] = s;
    }
}

/// Vertical half of EXPAND (`tmp` is dw × sh, the output dw × dh) fused with what the level is
/// for. `mode`: 0 up; 1 base − up (a Laplacian band); 2 base + up (collapse); 3 the same clamped
/// to 0…1; 4 focus-stack selection (`aux1` the image's region energy, `aux2` the best so far:
/// strictly more energy, or the first image, takes the band); 5 halo fold (`aux1` the weight,
/// `aux2` Σw: Σ w·L); 6 blend accumulation (`aux1` the weight, `aux2` Σw). Without
/// `PCA_PHO_HAS_UP` the band is `base` itself (the residual).
kernel void pca_pho_expand_v(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                             device const float* tmp [[buffer(2)]], device const float* base [[buffer(3)]],
                             device float* dst [[buffer(4)]], device const float* aux1 [[buffer(5)]],
                             device float* aux2 [[buffer(6)]], uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.dh) return;
    int ch = p.ch;
    uint i = uint(y) * uint(p.dw) + uint(x);
    uint o = i * uint(ch);
    bool has_up = (p.flags & PCA_PHO_HAS_UP) != 0u;
    bool first = (p.flags & PCA_PHO_FIRST) != 0u;
    bool take = false;
    float k = 0.0f;
    if (p.mode == 4u) {
        float e = aux1[i];
        take = first || e > aux2[i];
        if (!take) return;
        aux2[i] = e;
    } else if (p.mode == 5u) {
        k = aux1[i];
        aux2[i] = first ? k : aux2[i] + k;
    } else if (p.mode == 6u) {
        k = aux1[i];
        aux2[i] = aux2[i] + k;
    }
    for (int c = 0; c < ch; c++) {
        float up = 0.0f;
        if (has_up) {
            for (int kk = 0; kk < 5; kk++) {
                int t = y + kk - 2;
                if ((t & 1) != 0) continue;
                int sy = clamp(t / 2, 0, p.sh - 1);
                up += (2.0f * pca_pho_k[kk]) * tmp[(uint(sy) * uint(p.dw) + uint(x)) * uint(ch) + uint(c)];
            }
        }
        uint j = o + uint(c);
        switch (p.mode) {
            case 0u: dst[j] = up; break;
            case 1u: dst[j] = base[j] - up; break;
            case 2u: dst[j] = base[j] + up; break;
            case 3u: dst[j] = clamp(base[j] + up, 0.0f, 1.0f); break;
            case 4u: dst[j] = has_up ? base[j] - up : base[j]; break;
            case 5u: {
                float lp = has_up ? base[j] - up : base[j];
                dst[j] = first ? lp * k : dst[j] + k * lp;
                break;
            }
            default: {
                float lp = has_up ? base[j] - up : base[j];
                dst[j] = dst[j] + k * lp;
                break;
            }
        }
    }
}

/// `acc / Σw` where Σw > `a`, else 0 (blend: a = 1e-6; halo control: a = 0).
kernel void pca_pho_normalize(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                              device float* acc [[buffer(2)]], device const float* wsum [[buffer(3)]],
                              uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.dh) return;
    uint i = uint(y) * uint(p.dw) + uint(x);
    float k = wsum[i];
    for (int c = 0; c < p.ch; c++) {
        uint j = i * uint(p.ch) + uint(c);
        acc[j] = k > p.a ? acc[j] / k : 0.0f;
    }
}

/// `clamp(src, 0, 1)` (a one-level pyramid's output).
kernel void pca_pho_clamp(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                          device const float* src [[buffer(2)]], device float* dst [[buffer(3)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.dh) return;
    uint o = (uint(y) * uint(p.dw) + uint(x)) * uint(p.ch);
    for (int c = 0; c < p.ch; c++) dst[o + uint(c)] = clamp(src[o + uint(c)], 0.0f, 1.0f);
}

/// Horizontal window sum of L² (photocraft `region_energy` → `window_sum`, `wt` of length `ch`).
kernel void pca_pho_energy_h(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                             device const float* band [[buffer(2)]], device float* dst [[buffer(3)]],
                             device const float* wt [[buffer(4)]], uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.dh) return;
    int n = p.ch, r = n / 2;
    float s = -0.0f;
    for (int t = 0; t < n; t++) {
        int sx = clamp(x + t - r, 0, p.dw - 1);
        float v = band[uint(y) * uint(p.dw) + uint(sx)];
        s += wt[t] * (v * v);
    }
    dst[uint(y) * uint(p.dw) + uint(x)] = s;
}

/// Vertical window sum (mode 0) or, for a radius-0 window, L² itself (mode 1); then the image's
/// coverage: −1 (no energy) where it is below one half.
kernel void pca_pho_energy_v(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                             device const float* src [[buffer(2)]], device const float* cover [[buffer(3)]],
                             device float* dst [[buffer(4)]], device const float* wt [[buffer(5)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.dh) return;
    uint i = uint(y) * uint(p.dw) + uint(x);
    float s;
    if (p.mode == 1u) {
        float v = src[i];
        s = v * v;
    } else {
        int n = p.ch, r = n / 2;
        s = 0.0f;
        for (int t = 0; t < n; t++) {
            int sy = clamp(y + t - r, 0, p.dh - 1);
            s += wt[t] * src[uint(sy) * uint(p.dw) + uint(x)];
        }
    }
    dst[i] = cover[i] < 0.5f ? -1.0f : s;
}

/// Halo control's weight `((e + 1e-8) / 1e-4)^a`, exponent clamped to ±60; 0 where e < 0.
kernel void pca_pho_halo_weight(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                                device const float* e [[buffer(2)]], device float* dst [[buffer(3)]],
                                uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.dh) return;
    uint i = uint(y) * uint(p.dw) + uint(x);
    float v = e[i];
    dst[i] = v < 0.0f ? 0.0f : exp(clamp(p.a * log((max(v, 0.0f) + 1e-8f) / 1e-4f), -60.0f, 60.0f));
}

/// Local deviation and entropy over a 5×5 window, clamped (photocraft `deviation_entropy`):
/// the entropy's `p ln p` terms come from `terms[count]` (computed on the CPU with its logf) and
/// are subtracted in first-touch order, so the result is bit-identical.
kernel void pca_pho_dev_ent(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                            device const float* lum [[buffer(2)]], device float* dev [[buffer(3)]],
                            device float* ent [[buffer(4)]], device const float* terms [[buffer(5)]],
                            uint2 gid [[thread_position_in_grid]]) {
    int j = int(gid.x), i = int(gid.y);
    int w = p.dw, h = p.dh;
    if (j >= w || i >= h) return;
    const float inv_n = 1.0f / 25.0f;
    int q[25];
    float s = 0.0f, s2 = 0.0f;
    int n = 0;
    for (int dy = 0; dy <= 4; dy++) {
        int yy = clamp(i + dy - 2, 0, h - 1);
        for (int dx = 0; dx <= 4; dx++) {
            float v = lum[uint(yy) * uint(w) + uint(clamp(j + dx - 2, 0, w - 1))];
            s += v;
            s2 += v * v;
            float qf = clamp(v, 0.0f, 1.0f) * 255.0f + 0.5f;
            int qi = qf > 0.0f ? int(qf) : 0;
            q[n++] = min(qi, 255);
        }
    }
    float mean = s * inv_n;
    uint o = p.base + uint(i) * uint(w) + uint(j);
    dev[o] = max(s2 * inv_n - mean * mean, 0.0f);
    float e = 0.0f;
    for (int a = 0; a < 25; a++) {
        bool seen = false;
        for (int b = 0; b < a; b++) seen = seen || q[b] == q[a];
        if (seen) continue;
        int cnt = 0;
        for (int b = 0; b < 25; b++) cnt += q[b] == q[a] ? 1 : 0;
        e -= terms[cnt];
    }
    ent[o] = e;
}

/// The residual's region-information rule (photocraft `fuse_residuals`): the mean of the images
/// no other covering image Pareto-dominates on (deviation, entropy). `mode` = image count; the
/// inputs are packed image after image.
kernel void pca_pho_fuse_residuals(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                                   device const float* px [[buffer(2)]], device const float* dev [[buffer(3)]],
                                   device const float* ent [[buffer(4)]], device const float* cover [[buffer(5)]],
                                   device float* dst [[buffer(6)]], uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.dh) return;
    uint plane = uint(p.dw) * uint(p.dh);
    uint i = uint(y) * uint(p.dw) + uint(x);
    int n = int(p.mode), ch = p.ch;
    bool any_cover = false;
    for (int a = 0; a < n; a++) any_cover = any_cover || cover[uint(a) * plane + i] >= 0.5f;
    int kept = 0;
    for (int pass = 0; pass < 2; pass++) {
        float inv = 1.0f / float(max(kept, 1));
        for (int c = 0; c < ch && pass == 1; c++) dst[i * uint(ch) + uint(c)] = 0.0f;
        for (int a = 0; a < n; a++) {
            bool ea_ok = !any_cover || cover[uint(a) * plane + i] >= 0.5f;
            if (!ea_ok) continue;
            float da = dev[uint(a) * plane + i], ea = ent[uint(a) * plane + i];
            bool dominated = false;
            for (int b = 0; b < n && !dominated; b++) {
                if (b == a) continue;
                if (any_cover && cover[uint(b) * plane + i] < 0.5f) continue;
                float db = dev[uint(b) * plane + i], eb = ent[uint(b) * plane + i];
                dominated = db >= da && eb >= ea && (db > da || eb > ea);
            }
            if (dominated) continue;
            if (pass == 0) {
                kept++;
            } else {
                for (int c = 0; c < ch; c++) {
                    uint j = i * uint(ch) + uint(c);
                    dst[j] = dst[j] + px[(uint(a) * plane + i) * uint(ch) + uint(c)] * inv;
                }
            }
        }
    }
}

/// |∇²L| of a luminance plane, edge-clamped (photocraft `stack_weights`' detail measure).
kernel void pca_pho_abs_laplacian(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                                  device const float* l [[buffer(2)]], device float* dst [[buffer(3)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y), w = p.dw, h = p.dh;
    if (x >= w || y >= h) return;
    int xl = max(x - 1, 0), xr = min(x + 1, w - 1), yu = max(y - 1, 0), yd = min(y + 1, h - 1);
    #define PCA_PHO_L(xx, yy) l[uint(yy) * uint(w) + uint(xx)]
    dst[uint(y) * uint(w) + uint(x)] = fabs(PCA_PHO_L(xl, y) + PCA_PHO_L(xr, y) + PCA_PHO_L(x, yu) + PCA_PHO_L(x, yd) - 4.0f * PCA_PHO_L(x, y));
    #undef PCA_PHO_L
}

/// Winner-take-all over the images, one image per dispatch (`mode` = its index; `flags` bit 1 =
/// first): its score is the smoothed detail where it covers the pixel (alpha > ½), else −1; it
/// takes the pixel when strictly above the best so far (which starts at −FLT_MAX).
kernel void pca_pho_stack_winner(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                                 device const float* s [[buffer(2)]], device const float* alpha [[buffer(3)]],
                                 device float* best [[buffer(4)]], device uint* idx [[buffer(5)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.dh) return;
    uint i = uint(y) * uint(p.dw) + uint(x);
    float b = (p.flags & PCA_PHO_FIRST) != 0u ? -FLT_MAX : best[i];
    uint k = (p.flags & PCA_PHO_FIRST) != 0u ? 0u : idx[i];
    float score = alpha[i] > 0.5f ? s[i] : -1.0f;
    if (score > b) { b = score; k = p.mode; }
    best[i] = b;
    idx[i] = k;
}

/// The one-hot weight planes (`mode` images, packed plane after plane).
kernel void pca_pho_stack_onehot(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                                 device const float* best [[buffer(2)]], device const uint* idx [[buffer(3)]],
                                 device float* dst [[buffer(4)]], uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.dh) return;
    uint i = uint(y) * uint(p.dw) + uint(x), plane = uint(p.dw) * uint(p.dh);
    bool any = best[i] > -FLT_MAX;
    for (uint k = 0; k < p.mode; k++) dst[k * plane + i] = any && idx[i] == k ? 1.0f : 0.0f;
}
