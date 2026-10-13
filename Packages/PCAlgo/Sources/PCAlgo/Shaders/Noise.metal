// Port of photocraft-algo (crates/algo/src/noise.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Add Noise (the coordinate hash, bit-identical to the CPU) and the exact disc median: per channel,
// a bisection over the float total order (Rust `total_cmp` keys) finds the sample of rank n/2,
// the same sample photocraft's selection / ranked histogram returns.

struct pca_add_noise_params {
    float a;
    uint gaussian;
    uint mono;
    uint seed;
};

kernel void pca_add_noise(constant pca_frame& f [[buffer(0)]], constant pca_add_noise_params& p [[buffer(1)]],
                          pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q);
    bool alpha = f.alpha != 0u;
    if (alpha && v.w <= 0.0f) { dst.write(v, gid); return; }
    for (uint k = 0; k < f.ncomp; k++) {
        uint ch = p.mono != 0u ? 0u : f.first_channel + k;
        float nz;
        if (p.gaussian == 0u) {
            nz = (pca_hash01(q.x, q.y, ch, p.seed) - 0.5f) * 2.0f * p.a;
        } else {
            float u1 = max(pca_hash01(q.x, q.y, ch * 2u + 101u, p.seed), 1e-7f);
            float u2 = pca_hash01(q.x, q.y, ch * 2u + 102u, p.seed);
            nz = sqrt(-2.0f * log(u1)) * cos(6.28318530717958647692f * u2) * p.a * 0.5f;
        }
        v[k] += nz;
    }
    dst.write(v, gid);
}

struct pca_median_params {
    int radius;
    int rows;
    int target;
    uint use_threshold;
    float threshold;
    float pad0;
    float pad1;
    float pad2;
};

/// Total-order key of a float (Rust `f32::total_cmp`), as an unsigned integer.
inline uint4 pca_total_key(float4 v) {
    uint4 b = as_type<uint4>(v);
    return select(b | 0x80000000u, ~b, (b & 0x80000000u) != 0u);
}

inline float4 pca_total_value(uint4 k) {
    uint4 b = select(~k, k & 0x7fffffffu, (k & 0x80000000u) != 0u);
    return as_type<float4>(b);
}

kernel void pca_median(constant pca_frame& f [[buffer(0)]], constant pca_median_params& p [[buffer(1)]],
                       constant int* hw [[buffer(2)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    // Key range of the disc.
    uint4 lo = uint4(0xffffffffu), hi = uint4(0u);
    for (int j = 0; j < p.rows; j++) {
        int dy = j - p.radius, h = hw[j];
        for (int dx = -h; dx <= h; dx++) {
            uint4 k = pca_total_key(pca_get(src, f, q + int2(dx, dy)));
            lo = min(lo, k); hi = max(hi, k);
        }
    }
    // Smallest key K with #(key ≤ K) > target, per component.
    uint target = uint(p.target);
    while (any(lo < hi)) {
        uint4 mid = lo + (hi - lo) / 2u;
        uint4 cnt = uint4(0u);
        for (int j = 0; j < p.rows; j++) {
            int dy = j - p.radius, h = hw[j];
            for (int dx = -h; dx <= h; dx++) {
                uint4 k = pca_total_key(pca_get(src, f, q + int2(dx, dy)));
                cnt += select(uint4(0u), uint4(1u), k <= mid);
            }
        }
        bool4 enough = cnt > target;
        hi = select(hi, mid, enough && lo < hi);
        lo = select(lo, mid + 1u, !enough && lo < hi);
    }
    float4 m = pca_total_value(lo);
    if (p.use_threshold != 0u) {
        float4 o = pca_get(src, f, q);
        m = select(m, o, fabs(o - m) <= p.threshold);
    }
    dst.write(m, gid);
}

/// Dust & Scratches at radius 1 after MPSImageMedian: keep the original within the threshold.
kernel void pca_median_threshold(constant pca_frame& f [[buffer(0)]], constant pca_median_params& p [[buffer(1)]],
                                 pca_in src [[texture(0)]], pca_in med [[texture(1)]], pca_out dst [[texture(2)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 o = pca_get(src, f, q), m = med.read(gid);
    dst.write(select(m, o, fabs(o - m) <= p.threshold), gid);
}

/// `pca_median` with the threadgroup's source tile (its outputs + the disc's reach) cached in
/// threadgroup memory as total-order keys: the bisection reads the disc ~30 times, on chip.
kernel void pca_median_tg(constant pca_frame& f [[buffer(0)]], constant pca_median_params& p [[buffer(1)]],
                          constant int* hw [[buffer(2)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                          threadgroup uint4* tile [[threadgroup(0)]],
                          uint2 gid [[thread_position_in_grid]], uint2 lid [[thread_position_in_threadgroup]],
                          uint2 tsize [[threads_per_threadgroup]]) {
    int r = p.radius;
    int tw = int(tsize.x) + 2 * r, th = int(tsize.y) + 2 * r;
    // This group's first output (gid − lid stays right for the partial groups at the edges).
    int2 base = f.out_origin + int2(gid - lid) - int2(r);
    for (int i = int(lid.y * tsize.x + lid.x); i < tw * th; i += int(tsize.x * tsize.y)) {
        tile[i] = pca_total_key(pca_get(src, f, base + int2(i % tw, i / tw)));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    int cx = int(lid.x) + r, cy = int(lid.y) + r;
    uint4 lo = uint4(0xffffffffu), hi = uint4(0u);
    for (int j = 0; j < p.rows; j++) {
        int row = (cy + j - r) * tw, h = hw[j];
        for (int dx = -h; dx <= h; dx++) { uint4 k = tile[row + cx + dx]; lo = min(lo, k); hi = max(hi, k); }
    }
    uint target = uint(p.target);
    while (any(lo < hi)) {
        uint4 mid = lo + (hi - lo) / 2u;
        uint4 cnt = uint4(0u);
        for (int j = 0; j < p.rows; j++) {
            int row = (cy + j - r) * tw, h = hw[j];
            for (int dx = -h; dx <= h; dx++) cnt += select(uint4(0u), uint4(1u), tile[row + cx + dx] <= mid);
        }
        bool4 enough = cnt > target;
        hi = select(hi, mid, enough && lo < hi);
        lo = select(lo, mid + 1u, !enough && lo < hi);
    }
    float4 m = pca_total_value(lo);
    if (p.use_threshold != 0u) {
        float4 o = pca_total_value(tile[cy * tw + cx]);
        m = select(m, o, fabs(o - m) <= p.threshold);
    }
    dst.write(m, gid);
}
