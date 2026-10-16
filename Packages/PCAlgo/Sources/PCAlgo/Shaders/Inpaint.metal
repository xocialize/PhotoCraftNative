// Port of photocraft-algo (crates/algo/src/inpaint.rs: best_offset's SSD scan), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Proximity match: one thread per candidate displacement, the ring's squared differences summed in
// the CPU's order (sample point by sample point, channel by channel), divided by the sample count
// and scaled by the nearness penalty computed on the CPU.

struct pca_inp_proximity_params {
    int width;
    int ch;
    int pts;
    int cands;
};

kernel void pca_inp_proximity(constant pca_inp_proximity_params& p [[buffer(1)]], device const float* img [[buffer(2)]],
                              device const int2* pts [[buffer(3)]], device const int2* cands [[buffer(4)]],
                              device const float* pen [[buffer(5)]], device float* out [[buffer(6)]],
                              uint i [[thread_position_in_grid]]) {
    if (i >= uint(p.cands)) return;
    int2 d = cands[i];
    float e = 0.0f;
    for (int k = 0; k < p.pts; k++) {
        int2 q = pts[k];
        long a = (long(q.y) * long(p.width) + long(q.x)) * long(p.ch);
        long b = (long(q.y + d.y) * long(p.width) + long(q.x + d.x)) * long(p.ch);
        for (int c = 0; c < p.ch; c++) {
            float dd = img[a + c] - img[b + c];
            e += dd * dd;
        }
    }
    out[i] = e / float(max(p.pts, 1)) * pen[i];
}

// ---- Completion (inpaint.rs Solver): costs, transforms, vote, source moments ----
//
// Every sum runs in the CPU reference's order (patch rows, pixels, channels; one accumulator per
// moment and channel), and only correctly rounded operations are used: division, and an exact
// square root for the colour-adaptation fit (MSL's sqrt isn't correctly rounded). The vote's
// exp() weights are computed on the CPU. So costs, transforms and votes are bit-identical.

struct pca_inp_solver_params {
    int w;
    int h;
    int ch;
    int r;
    int tx0;
    int ty0;
    int tw;
    int th;
    int hx0;
    int hy0;
    int hw;
    int hh;
    int c8;
    uint adapted;
    float gain_lo;
    float gain_hi;
    float bias;
    uint pad0;
    uint pad1;
    uint pad2;
};

#define PCA_INP_VOID 0u
#define PCA_INP_HOLE 3u
#define PCA_INP_MOM 8

/// Correctly rounded square root of a float (integer square root of the mantissa). Subnormal
/// inputs read as zero on this GPU.
inline float pca_inp_sqrt(float x) {
    if (!(x > 0.0f) || isinf(x)) return sqrt(x);
    uint bits = as_type<uint>(x);
    int e = int((bits >> 23) & 0xffu);
    ulong m = ulong(bits & 0x7fffffu);
    if (e == 0) {
        while ((m & 0x800000ul) == 0ul) { m <<= 1; e -= 1; }
        e += 1;
    } else {
        m |= 0x800000ul;
    }
    int ex = e - 150;
    if ((ex & 1) != 0) { m <<= 1; ex -= 1; }
    m <<= 26;
    ex -= 26;
    ulong s = ulong(sqrt(float(m)));
    while (s * s > m) s--;
    while ((s + 1ul) * (s + 1ul) <= m) s++;
    bool sticky = s * s != m;
    int extra = s >= (1ul << 25) ? 2 : 1;
    ulong q = s >> uint(extra);
    ulong rem = s & ((1ul << uint(extra)) - 1ul);
    ulong hv = 1ul << uint(extra - 1);
    if (rem > hv || (rem == hv && (sticky || (q & 1ul) != 0ul))) q++;
    int k = ex / 2 + extra;
    if (q == (1ul << 24)) { q >>= 1; k += 1; }
    return as_type<float>((uint(k + 23 + 127) << 23) | (uint(q) & 0x7fffffu));
}

/// photocraft `fit`: gain and bias of one channel within the limits.
inline float2 pca_inp_fit(constant pca_inp_solver_params& p, float n, float st, float stt, float ss, float sss) {
    float mt = st / n, ms = ss / n;
    float vt = fmax(stt / n - mt * mt, 0.0f);
    float vs = fmax(sss / n - ms * ms, 0.0f);
    // A flat source (variance within rounding of its moments) keeps gain 1, as the CPU's `fit` (AB-T-0299).
    float g = vs > fmax(1e-5f * (ms * ms), 1e-10f) ? pca_inp_sqrt(vt / vs) : 1.0f;
    g = g < p.gain_lo ? p.gain_lo : (g > p.gain_hi ? p.gain_hi : g);
    float b = mt - g * ms;
    b = b < -p.bias ? -p.bias : (b > p.bias ? p.bias : b);
    return float2(g, b);
}

/// `[Σt, Σt², Σs, Σs², Σts]` per channel (the first c8) of target patch `t` (its in-grid,
/// non-void pixels) against source patch `s`; returns the pixel count.
inline int pca_inp_moments(constant pca_inp_solver_params& p, device const float* img, device const uchar* px, int2 t, int2 s,
                           thread float* m) {
    for (int i = 0; i < PCA_INP_MOM * 5; i++) m[i] = 0.0f;
    int n = 0;
    for (int dy = -p.r; dy <= p.r; dy++) {
        int ty = t.y + dy;
        if (ty < 0 || ty >= p.h) continue;
        int sy = s.y + dy;
        for (int dx = -p.r; dx <= p.r; dx++) {
            int tx = t.x + dx;
            if (tx < 0 || tx >= p.w || px[long(ty) * p.w + tx] == PCA_INP_VOID) continue;
            long ti = (long(ty) * p.w + tx) * p.ch, si = (long(sy) * p.w + (s.x + dx)) * p.ch;
            for (int c = 0; c < p.c8; c++) {
                float a = img[ti + c], b = img[si + c];
                m[c * 5 + 0] += a;
                m[c * 5 + 1] += a * a;
                m[c * 5 + 2] += b;
                m[c * 5 + 3] += b * b;
                m[c * 5 + 4] += a * b;
            }
            n += 1;
        }
    }
    return n;
}

/// photocraft `adapted_cost`.
inline float pca_inp_adapted_cost(constant pca_inp_solver_params& p, float nf, thread const float* m) {
    float sum = 0.0f;
    for (int c = 0; c < p.c8; c++) {
        thread const float* mc = m + c * 5;
        float2 gb = pca_inp_fit(p, nf, mc[0], mc[1], mc[2], mc[3]);
        float g = gb.x, b = gb.y;
        sum += mc[1] + g * g * mc[3] + nf * b * b - 2.0f * g * mc[4] - 2.0f * b * mc[0] + 2.0f * g * b * mc[2];
    }
    return fmax(sum, 0.0f) / (nf * float(p.c8));
}

/// `Σv, Σv²` per channel of the full patch centred at `c` (rows, then pixels).
inline void pca_inp_patch_moments(constant pca_inp_solver_params& p, device const float* img, int2 c, device float2* out) {
    for (int k = 0; k < p.c8; k++) out[k] = float2(0.0f);
    for (int y = c.y - p.r; y <= c.y + p.r; y++) {
        for (int x = c.x - p.r; x <= c.x + p.r; x++) {
            long i = (long(y) * p.w + x) * p.ch;
            for (int k = 0; k < p.c8; k++) {
                float a = img[i + k];
                float2 o = out[k];
                o.x += a;
                o.y += a * a;
                out[k] = o;
            }
        }
    }
}

kernel void pca_inp_source_moments(constant pca_inp_solver_params& p [[buffer(1)]], device const float* img [[buffer(2)]],
                                   device const bool* valid [[buffer(3)]], device float2* smom [[buffer(4)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.w || int(gid.y) >= p.h) return;
    long i = long(gid.y) * p.w + gid.x;
    if (!valid[i]) return;
    pca_inp_patch_moments(p, img, int2(gid), smom + i * p.c8);
}

/// Per cell of the target box: with adaptation, the full patches' own moments (`tmom`); for
/// targets, the cost of their current match (no cutoff).
kernel void pca_inp_costs(constant pca_inp_solver_params& p [[buffer(1)]], device const float* img [[buffer(2)]],
                          device const uchar* px [[buffer(3)]], device const bool* targets [[buffer(4)]],
                          device const bool* full [[buffer(5)]], device const int2* nnf [[buffer(6)]],
                          device float* cost [[buffer(7)]], device float2* tmom [[buffer(8)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.tw || int(gid.y) >= p.th) return;
    int k = int(gid.y) * p.tw + int(gid.x);
    int2 t = int2(p.tx0 + int(gid.x), p.ty0 + int(gid.y));
    if (p.adapted != 0u && full[k]) pca_inp_patch_moments(p, img, t, tmom + long(k) * p.c8);
    if (!targets[k]) return;
    int2 s = nnf[k];
    if (p.adapted == 0u) {
        float sum = 0.0f;
        int n = 0;
        for (int dy = -p.r; dy <= p.r; dy++) {
            int ty = t.y + dy;
            if (ty < 0 || ty >= p.h) continue;
            int sy = s.y + dy;
            for (int dx = -p.r; dx <= p.r; dx++) {
                int tx = t.x + dx;
                if (tx < 0 || tx >= p.w || px[long(ty) * p.w + tx] == PCA_INP_VOID) continue;
                long ti = (long(ty) * p.w + tx) * p.ch, si = (long(sy) * p.w + (s.x + dx)) * p.ch;
                for (int c = 0; c < p.ch; c++) {
                    float d = img[ti + c] - img[si + c];
                    sum += d * d;
                }
                n += p.ch;
            }
        }
        cost[k] = n == 0 ? INFINITY : sum / float(n);
    } else {
        float m[PCA_INP_MOM * 5];
        int n = pca_inp_moments(p, img, px, t, s, m);
        cost[k] = n == 0 ? INFINITY : pca_inp_adapted_cost(p, float(n), m);
    }
}

/// Gain and bias per channel of every voting target (a target with a finite cost).
kernel void pca_inp_transforms(constant pca_inp_solver_params& p [[buffer(1)]], device const float* img [[buffer(2)]],
                               device const uchar* px [[buffer(3)]], device const bool* targets [[buffer(4)]],
                               device const int2* nnf [[buffer(5)]], device const float* cost [[buffer(6)]],
                               device float2* gb [[buffer(7)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.tw || int(gid.y) >= p.th) return;
    int k = int(gid.y) * p.tw + int(gid.x);
    if (!targets[k] || !isfinite(cost[k])) return;
    int2 t = int2(p.tx0 + int(gid.x), p.ty0 + int(gid.y));
    float m[PCA_INP_MOM * 5];
    int n = pca_inp_moments(p, img, px, t, nnf[k], m);
    for (int c = 0; c < p.ch; c++) {
        gb[long(k) * p.ch + c] = (n == 0 || c >= p.c8) ? float2(1.0f, 0.0f)
                                                        : pca_inp_fit(p, float(n), m[c * 5 + 0], m[c * 5 + 1], m[c * 5 + 2], m[c * 5 + 3]);
    }
}

/// The vote of every hole pixel of the hole box: the weighted mean of what the matches of the
/// patches covering it put there (summed patch by patch in raster order of their centres).
kernel void pca_inp_vote(constant pca_inp_solver_params& p [[buffer(1)]], device float* img [[buffer(2)]],
                         device const uchar* px [[buffer(3)]], device const float* wt [[buffer(4)]],
                         device const int* src [[buffer(5)]], device const float2* gb [[buffer(6)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.hw || int(gid.y) >= p.hh) return;
    int x = p.hx0 + int(gid.x), y = p.hy0 + int(gid.y);
    if (px[long(y) * p.w + x] != PCA_INP_HOLE) return;
    int y0 = max(y - p.r, 0), y1 = min(y + p.r, p.h - 1), x0 = max(x - p.r, 0), x1 = min(x + p.r, p.w - 1);
    float wsum = 0.0f;
    for (int ty = y0; ty <= y1; ty++) {
        for (int tx = x0; tx <= x1; tx++) {
            float wv = wt[(ty - p.ty0) * p.tw + tx - p.tx0];
            if (wv != 0.0f) wsum += wv;
        }
    }
    if (!(wsum > 0.0f)) return;
    // Channel by channel (each channel's sum runs in the same patch order as the CPU's).
    for (int c = 0; c < p.ch; c++) {
        float acc = 0.0f;
        for (int ty = y0; ty <= y1; ty++) {
            int dy = ty - y;
            for (int tx = x0; tx <= x1; tx++) {
                int k = (ty - p.ty0) * p.tw + tx - p.tx0;
                float wv = wt[k];
                if (wv == 0.0f) continue;
                long si = (long(src[k]) - long(dy) * p.w - long(tx - x)) * p.ch;
                float v = img[si + c];
                if (p.adapted != 0u) { float2 t = gb[long(k) * p.ch + c]; v = t.x * v + t.y; }
                acc += v * wv;
            }
        }
        img[(long(y) * p.w + x) * p.ch + c] = acc / wsum;
    }
}
