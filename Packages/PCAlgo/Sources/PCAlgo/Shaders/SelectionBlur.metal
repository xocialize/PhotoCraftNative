// Port of photocraft-algo (crates/algo/src/selection_blur.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Smooth (box average, edges replicated) and Feather (direct truncated Gaussian) over the mask's
// window: the non-zero rows `by0..<by0 + bh` of the mask, columns `wx0..<wx0 + gw`, are blurred
// horizontally into `tmp` (bh × gw), then vertically over the window's `gh` rows (rows outside
// the non-zero band read 0) into `res` (gh × gw). See SelectionBlur.swift for the exactness notes.

struct pca_sel_window {
    uint w;       // mask row width
    uint bx0;
    uint by0;
    uint bh;
    uint wx0;
    uint gw;
    uint gh;
    uint off;     // window row of the first non-zero row
    uint r;
    uint taps;
    uint segment;
    uint pad0;
};

/// A Kahan-compensated Float sum.
struct pca_sel_ksum {
    float s;
    float c;
};

inline void pca_sel_kadd(thread pca_sel_ksum& k, float v) {
    float y = v - k.c;
    float t = k.s + y;
    k.c = (t - k.s) - y;
    k.s = t;
}

/// Sample `i` of a mask line, edges replicated.
inline float pca_sel_row_at(device const float* src, int n, int i) { return src[clamp(i, 0, n - 1)]; }

/// Sample `i` of a window column (edges replicated; rows outside the non-zero band read 0).
inline float pca_sel_col_at(device const float* tmp, uint gw, uint col, int n, int off, int bh, int i) {
    int yy = clamp(i, 0, n - 1) - off;
    return (yy >= 0 && yy < bh) ? tmp[uint(yy) * gw + col] : 0.0f;
}

/// Smooth's horizontal box pass: thread = (non-zero row, segment of `segment` columns). The
/// first window sum Σ_{j=-r}^{r} line[clamp(x0 + j)] takes O(min(n, 2r + 1)) (edge copies
/// counted), then the window slides; Kahan-compensated Float sums.
kernel void pca_sel_box_rows(constant pca_sel_window& p [[buffer(0)]], device const float* m [[buffer(1)]], device float* tmp [[buffer(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.bh) return;
    int n = int(p.gw), r = int(p.r);
    int x0 = int(gid.y * p.segment);
    if (x0 >= n) return;
    int x1 = min(x0 + int(p.segment), n);
    device const float* src = m + (p.by0 + gid.x) * p.w + p.wx0;
    device float* dst = tmp + gid.x * p.gw;
    pca_sel_ksum acc = {0.0f, 0.0f};
    if (n == 1) {
        pca_sel_kadd(acc, float(2 * r + 1) * src[0]);
    } else {
        int left = clamp(r - x0 + 1, 0, 2 * r + 1), right = clamp(r + x0 - n + 2, 0, 2 * r + 1);
        if (left > 0) pca_sel_kadd(acc, float(left) * src[0]);
        for (int i = max(1, x0 - r); i <= min(n - 2, x0 + r); i++) pca_sel_kadd(acc, src[i]);
        if (right > 0) pca_sel_kadd(acc, float(right) * src[n - 1]);
    }
    float norm = float(2 * r + 1);
    for (int x = x0; x < x1; x++) {
        dst[x] = acc.s / norm;
        pca_sel_kadd(acc, pca_sel_row_at(src, n, x + r + 1) - pca_sel_row_at(src, n, x - r));
    }
}

/// Smooth's vertical box pass over the window rows: thread = (column, segment of rows).
kernel void pca_sel_box_cols(constant pca_sel_window& p [[buffer(0)]], device const float* tmp [[buffer(1)]], device float* res [[buffer(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.gw) return;
    int n = int(p.gh), r = int(p.r);
    int y0 = int(gid.y * p.segment);
    if (y0 >= n) return;
    int y1 = min(y0 + int(p.segment), n);
    uint col = gid.x, gw = p.gw;
    int off = int(p.off), bh = int(p.bh);
    pca_sel_ksum acc = {0.0f, 0.0f};
    if (n == 1) {
        pca_sel_kadd(acc, float(2 * r + 1) * pca_sel_col_at(tmp, gw, col, n, off, bh, 0));
    } else {
        int left = clamp(r - y0 + 1, 0, 2 * r + 1), right = clamp(r + y0 - n + 2, 0, 2 * r + 1);
        if (left > 0) pca_sel_kadd(acc, float(left) * pca_sel_col_at(tmp, gw, col, n, off, bh, 0));
        for (int i = max(1, y0 - r); i <= min(n - 2, y0 + r); i++) pca_sel_kadd(acc, pca_sel_col_at(tmp, gw, col, n, off, bh, i));
        if (right > 0) pca_sel_kadd(acc, float(right) * pca_sel_col_at(tmp, gw, col, n, off, bh, n - 1));
    }
    float norm = float(2 * r + 1);
    for (int y = y0; y < y1; y++) {
        res[uint(y) * gw + col] = acc.s / norm;
        pca_sel_kadd(acc, pca_sel_col_at(tmp, gw, col, n, off, bh, y + r + 1) - pca_sel_col_at(tmp, gw, col, n, off, bh, y - r));
    }
}

/// Feather's horizontal pass: direct taps (k[i] for offsets i − r), zero outside the window line,
/// accumulated in tap order as the CPU's direct kernel does.
kernel void pca_sel_feather_rows(constant pca_sel_window& p [[buffer(0)]], device const float* m [[buffer(1)]], device const float* k [[buffer(2)]],
                                 device float* tmp [[buffer(3)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.gw || gid.y >= p.bh) return;
    device const float* src = m + (p.by0 + gid.y) * p.w + p.wx0;
    int x = int(gid.x), r = int(p.r), n = int(p.gw);
    float acc = 0.0f;
    for (int i = 0; i < int(p.taps); i++) {
        int xx = x + i - r;
        if (xx >= 0 && xx < n) acc += k[i] * src[xx];
    }
    tmp[gid.y * p.gw + gid.x] = acc;
}

/// Feather's vertical pass over the window rows (rows outside the non-zero band read 0).
kernel void pca_sel_feather_cols(constant pca_sel_window& p [[buffer(0)]], device const float* tmp [[buffer(1)]], device const float* k [[buffer(2)]],
                                 device float* res [[buffer(3)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.gw || gid.y >= p.gh) return;
    int yy = int(gid.y), r = int(p.r), off = int(p.off), bh = int(p.bh);
    float acc = 0.0f;
    for (int i = 0; i < int(p.taps); i++) {
        int y = yy + i - r;
        int row = y - off;
        if (y >= 0 && row >= 0 && row < bh) acc += k[i] * tmp[uint(row) * p.gw + gid.x];
    }
    res[gid.y * p.gw + gid.x] = acc;
}
