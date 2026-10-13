// Port of photocraft-algo (crates/algo/src/features.rs, pyramid.rs `box_blur1`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Harris response map (photocraft `harris`): Sobel gradients and their products, the
// structure tensor's two radius-1 running-sum box passes per axis (one thread per line, the
// running sum updated exactly as the CPU does, so the result is bit-identical), the response
// `det − 0.04·trace²`, its peak (atomic max of the non-negative bit patterns) and the candidate
// local maxima, appended to a list the CPU sorts. Uses `pca_pho_dims` (Photo.metal).

#pragma METAL fp contract(off)

/// Sobel gradients' products (gx², gy², gx·gy) per pixel, 0 on the one-pixel border.
kernel void pca_pho_sobel(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                          device const float* img [[buffer(2)]], device float* dst [[buffer(3)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y), w = p.dw, h = p.dh;
    if (x >= w || y >= h) return;
    uint i = uint(y) * uint(w) + uint(x);
    if (x < 1 || y < 1 || x >= w - 1 || y >= h - 1) {
        dst[i * 3u] = 0.0f; dst[i * 3u + 1u] = 0.0f; dst[i * 3u + 2u] = 0.0f;
        return;
    }
    #define PCA_PHO_P(dx, dy) img[uint(y + (dy)) * uint(w) + uint(x + (dx))]
    float gx = (PCA_PHO_P(1, -1) + 2.0f * PCA_PHO_P(1, 0) + PCA_PHO_P(1, 1)) - (PCA_PHO_P(-1, -1) + 2.0f * PCA_PHO_P(-1, 0) + PCA_PHO_P(-1, 1));
    float gy = (PCA_PHO_P(-1, 1) + 2.0f * PCA_PHO_P(0, 1) + PCA_PHO_P(1, 1)) - (PCA_PHO_P(-1, -1) + 2.0f * PCA_PHO_P(0, -1) + PCA_PHO_P(1, -1));
    #undef PCA_PHO_P
    dst[i * 3u] = gx * gx;
    dst[i * 3u + 1u] = gy * gy;
    dst[i * 3u + 2u] = gx * gy;
}

/// One running-sum box pass of radius `mode` along rows (`flags` 0) or columns (`flags` 1) of a
/// `dw × dh × ch` buffer, edge-clamped: `out = acc / (2r + 1)`, `acc += at(k + r + 1) − at(k − r)`
/// (photocraft `features::blur`). One thread per line.
kernel void pca_pho_box_line(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                             device const float* src [[buffer(2)]], device float* dst [[buffer(3)]],
                             uint2 gid [[thread_position_in_grid]]) {
    bool rows = p.flags == 0u;
    int line = int(gid.x);
    int n = rows ? p.dh : p.dw, m = rows ? p.dw : p.dh;
    if (line >= n || m <= 0) return;
    int r = int(p.mode), ch = p.ch;
    float div = float(2 * r + 1);
    for (int c = 0; c < ch; c++) {
        #define PCA_PHO_AT(k) src[(rows ? uint(line) * uint(p.dw) + uint(clamp((k), 0, m - 1)) \
                                        : uint(clamp((k), 0, m - 1)) * uint(p.dw) + uint(line)) * uint(ch) + uint(c)]
        float acc = -0.0f;
        for (int k = -r; k <= r; k++) acc += PCA_PHO_AT(k);
        for (int k = 0; k < m; k++) {
            uint i = rows ? uint(line) * uint(p.dw) + uint(k) : uint(k) * uint(p.dw) + uint(line);
            dst[i * uint(ch) + uint(c)] = acc / div;
            acc += PCA_PHO_AT(k + r + 1) - PCA_PHO_AT(k - r);
        }
        #undef PCA_PHO_AT
    }
}

/// The response `xx·yy − xy² − 0.04·(xx + yy)²` and the running peak (fold from 0 with max).
kernel void pca_pho_harris_response(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                                    device const float* t [[buffer(2)]], device float* r [[buffer(3)]],
                                    device atomic_uint* peak [[buffer(4)]], uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.dh) return;
    uint i = uint(y) * uint(p.dw) + uint(x);
    float xx = t[i * 3u], yy = t[i * 3u + 1u], xy = t[i * 3u + 2u];
    float s = xx + yy;
    float v = xx * yy - xy * xy - 0.04f * (s * s);
    r[i] = v;
    if (v > 0.0f) atomic_fetch_max_explicit(peak, as_type<uint>(v), memory_order_relaxed);
}

/// Appends `(x, y, score bits)` of every local maximum at least 1 % of the peak inside the margin
/// `mode` (unordered: the CPU sorts by score, y, x).
kernel void pca_pho_harris_candidates(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                                      device const float* r [[buffer(2)]], device const uint* peak_bits [[buffer(3)]],
                                      device atomic_uint* count [[buffer(4)]], device uint* list [[buffer(5)]],
                                      uint2 gid [[thread_position_in_grid]]) {
    int m = int(p.mode), w = p.dw;
    int x = int(gid.x) + m, y = int(gid.y) + m;
    if (x >= p.dw - m || y >= p.dh - m) return;
    float peak = as_type<float>(peak_bits[0]);
    if (peak <= 0.0f) return;
    float v = r[uint(y) * uint(w) + uint(x)];
    if (v < peak * 0.01f) return;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            if (!(r[uint(y + dy) * uint(w) + uint(x + dx)] <= v)) return;
        }
    }
    uint k = atomic_fetch_add_explicit(count, 1u, memory_order_relaxed);
    list[k * 3u] = uint(x);
    list[k * 3u + 1u] = uint(y);
    list[k * 3u + 2u] = as_type<uint>(v);
}
