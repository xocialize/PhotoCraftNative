// Port of photocraft-algo (crates/algo/src/panorama.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Photomerge's multi-band blend (photocraft `multiband`): push-pull hole filling, the panorama
// pyramid's own REDUCE (integer binomial weights, then /16) and half-pixel bilinear EXPAND, each
// image's Laplacian bands accumulated into the panorama levels with their Gaussian weights, the
// normalisation and the collapse. Summation orders follow the CPU reference (bit-exact). Uses
// `pca_pho_dims` (Photo.metal).

#pragma METAL fp contract(off)

constant float pca_pho_pk[5] = {1.0f, 4.0f, 6.0f, 4.0f, 1.0f};

struct pca_pho_band_params {
    int cw;       // band level size
    int chh;
    int nw;       // next (coarser) level size
    int nh;
    int pw;       // panorama level size
    int ph;
    int ox;       // band origin in the panorama level
    int oy;
    int ch;
    uint has_up;
    int pad0;
    int pad1;
};

/// Horizontal half of the panorama REDUCE (sw × sh → dw × sh).
kernel void pca_pho_pano_reduce_h(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                                  device const float* src [[buffer(2)]], device float* dst [[buffer(3)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.sh) return;
    for (int c = 0; c < p.ch; c++) {
        float s = 0.0f;
        for (int t = 0; t < 5; t++) {
            int xx = clamp(2 * x + t - 2, 0, p.sw - 1);
            s += pca_pho_pk[t] * src[(uint(y) * uint(p.sw) + uint(xx)) * uint(p.ch) + uint(c)];
        }
        dst[(uint(y) * uint(p.dw) + uint(x)) * uint(p.ch) + uint(c)] = s / 16.0f;
    }
}

/// Vertical half of the panorama REDUCE (dw × sh → dw × dh).
kernel void pca_pho_pano_reduce_v(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                                  device const float* tmp [[buffer(2)]], device float* dst [[buffer(3)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.dh) return;
    for (int c = 0; c < p.ch; c++) {
        float s = 0.0f;
        for (int t = 0; t < 5; t++) {
            int yy = clamp(2 * y + t - 2, 0, p.sh - 1);
            s += pca_pho_pk[t] * tmp[(uint(yy) * uint(p.dw) + uint(x)) * uint(p.ch) + uint(c)];
        }
        dst[(uint(y) * uint(p.dw) + uint(x)) * uint(p.ch) + uint(c)] = s / 16.0f;
    }
}

/// Half-pixel bilinear EXPAND of `src` (sw × sh) at output pixel (x, y) of a dw × dh grid, channel c.
inline float pca_pho_pano_up(device const float* src, int sw, int sh, int ch, int x, int y, int c) {
    float fy = clamp((float(y) + 0.5f) / 2.0f - 0.5f, 0.0f, float(sh - 1));
    float fly = floor(fy);
    int y0 = int(fly);
    float ty = fy - fly;
    int y1 = min(y0 + 1, sh - 1);
    float fx = clamp((float(x) + 0.5f) / 2.0f - 0.5f, 0.0f, float(sw - 1));
    float flx = floor(fx);
    int x0 = int(flx);
    float tx = fx - flx;
    int x1 = min(x0 + 1, sw - 1);
    #define PCA_PHO_S(xx, yy) src[(uint(yy) * uint(sw) + uint(xx)) * uint(ch) + uint(c)]
    float top = PCA_PHO_S(x0, y0) + (PCA_PHO_S(x1, y0) - PCA_PHO_S(x0, y0)) * tx;
    float bot = PCA_PHO_S(x0, y1) + (PCA_PHO_S(x1, y1) - PCA_PHO_S(x0, y1)) * tx;
    #undef PCA_PHO_S
    return top + (bot - top) * ty;
}

/// One image's band `cur − EXPAND(down)` (or `cur` for the residual) accumulated into the
/// panorama level at its offset: Σw += k, Σw·L += k·band, where its Gaussian weight k > 0.
kernel void pca_pho_pano_band_acc(constant pca_frame& f [[buffer(0)]], constant pca_pho_band_params& p [[buffer(1)]],
                                  device const float* cur [[buffer(2)]], device const float* down [[buffer(3)]],
                                  device const float* gau [[buffer(4)]], device float* acc [[buffer(5)]],
                                  device float* wsum [[buffer(6)]], uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.cw || y >= p.chh) return;
    int px = p.ox + x, py = p.oy + y;
    if (px >= p.pw || py >= p.ph) return;
    uint i = uint(y) * uint(p.cw) + uint(x);
    float k = gau[i];
    if (k <= 0.0f) return;
    uint q = uint(py) * uint(p.pw) + uint(px);
    wsum[q] = wsum[q] + k;
    for (int c = 0; c < p.ch; c++) {
        float band = cur[i * uint(p.ch) + uint(c)];
        if (p.has_up != 0u) band = band - pca_pho_pano_up(down, p.nw, p.nh, p.ch, x, y, c);
        uint j = q * uint(p.ch) + uint(c);
        acc[j] = acc[j] + k * band;
    }
}

/// Collapse step in place: `acc += EXPAND(coarser)` (sw × sh → dw × dh).
kernel void pca_pho_pano_expand_add(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                                    device const float* coarse [[buffer(2)]], device float* acc [[buffer(3)]],
                                    uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.dh) return;
    for (int c = 0; c < p.ch; c++) {
        uint j = (uint(y) * uint(p.dw) + uint(x)) * uint(p.ch) + uint(c);
        acc[j] = acc[j] + pca_pho_pano_up(coarse, p.sw, p.sh, p.ch, x, y, c);
    }
}

/// Push-pull, pull half: the weighted mean of each 2×2 block (children in row order), the
/// weight set to 1 where positive; `flags[0]`/`flags[1]` record a zero / a positive weight.
kernel void pca_pho_pp_down(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                            device const float* px [[buffer(2)]], device const float* wt [[buffer(3)]],
                            device float* cpx [[buffer(4)]], device float* cw [[buffer(5)]],
                            device atomic_uint* flags [[buffer(6)]], uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.dh) return;
    int ch = p.ch;
    uint j = uint(y) * uint(p.dw) + uint(x);
    float s = 0.0f;
    for (int c = 0; c < ch; c++) cpx[j * uint(ch) + uint(c)] = 0.0f;
    for (int dy = 0; dy < 2; dy++) {
        int yy = 2 * y + dy;
        if (yy >= p.sh) continue;
        for (int dx = 0; dx < 2; dx++) {
            int xx = 2 * x + dx;
            if (xx >= p.sw) continue;
            uint i = uint(yy) * uint(p.sw) + uint(xx);
            float a = wt[i];
            s = s + a;
            for (int c = 0; c < ch; c++) {
                uint o = j * uint(ch) + uint(c);
                cpx[o] = cpx[o] + a * px[i * uint(ch) + uint(c)];
            }
        }
    }
    if (s > 0.0f) {
        for (int c = 0; c < ch; c++) cpx[j * uint(ch) + uint(c)] /= s;
        s = 1.0f;
    }
    cw[j] = s;
    if (s == 0.0f) atomic_store_explicit(&flags[0], 1u, memory_order_relaxed);
    if (s > 0.0f) atomic_store_explicit(&flags[1], 1u, memory_order_relaxed);
}

/// Push-pull, push half: `px = a·px + (1 − a)·cpx` where the weight a < 1. With `mode` 1 the
/// level was only recursed into when its weights had both a zero and a positive (`flags`).
kernel void pca_pho_pp_up(constant pca_frame& f [[buffer(0)]], constant pca_pho_dims& p [[buffer(1)]],
                          device float* px [[buffer(2)]], device const float* wt [[buffer(3)]],
                          device const float* cpx [[buffer(4)]], device const uint* flags [[buffer(5)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.dw || y >= p.dh) return;
    if (p.mode == 1u && (flags[0] == 0u || flags[1] == 0u)) return;
    uint i = uint(y) * uint(p.dw) + uint(x);
    float a = wt[i];
    if (!(a < 1.0f)) return;
    uint j = uint(y / 2) * uint(p.sw) + uint(x / 2);
    for (int c = 0; c < p.ch; c++) {
        uint o = i * uint(p.ch) + uint(c);
        px[o] = a * px[o] + (1.0f - a) * cpx[j * uint(p.ch) + uint(c)];
    }
}
