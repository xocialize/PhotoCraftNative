// Port of photocraft-algo (crates/algo/src/stylize.rs, stylize2.rs, fxutil.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Stylize kernels (Mosaic, Emboss, Find Edges, Solarize/Invert, Desaturate, Diffuse, Tiles,
// Trace Contour, Wind, Glowing Edges) and the helpers the other Stylize*.metal files share.
// The hard thresholds of these filters (cell owners, tile edges, sweep intervals, LIC rounding)
// rely on 00_Common.metal's `fp contract(off)` and on mirroring the Swift reference's operation
// order exactly.

// ---------------------------------------------------------------- shared helpers

/// photocraft luma of a plane pixel: 0 → .x (gray-like, Lab L), 1 → Rec. 601 of .xyz
/// (RGB-like), 2 → the gray replicated to RGB then Rec. 601 (stylize's luma of a gray pixel).
inline float pca_sty_luma(float4 v, int code) {
    if (code == 0) return v.x;
    if (code == 2) return 0.299f * v.x + 0.587f * v.x + 0.114f * v.x;
    return 0.299f * v.x + 0.587f * v.y + 0.114f * v.z;
}

/// stylize `set_gray`: gray `g` in the plane's model (gray-like via Rec. 601 of (g, g, g)),
/// alpha from `orig`.
inline float4 pca_sty_set_gray(float g, float4 orig, constant pca_frame& f) {
    float w = f.alpha != 0u ? orig.w : 0.0f;
    if (f.mode == 0u) return float4(0.299f * g + 0.587f * g + 0.114f * g, 0.0f, 0.0f, w);
    return float4(g, g, g, w);
}

/// Rust `i32::div_euclid`.
inline int pca_sty_div_euclid(int a, int b) {
    int q = a / b;
    if (a % b < 0) return b > 0 ? q - 1 : q + 1;
    return q;
}

/// Rust `f as i32` (truncating, saturating, NaN → 0).
inline int pca_sty_i32(float v) {
    if (isnan(v)) return 0;
    if (v >= 2147483648.0f) return INT_MAX;
    if (v <= -2147483648.0f) return INT_MIN;
    return int(v);
}

/// Correctly rounded square root (MSL `sqrt` is within 2 ulp; the Swift reference rounds
/// exactly): the neighbour whose square is closest to `x`, by exact FMA residuals.
inline float pca_sty_sqrt(float x) {
    float s = sqrt(x);
    if (!(x > 0.0f) || isinf(x)) return s;
    for (int i = 0; i < 3; i++) {
        float up = nextafter(s, INFINITY), dn = nextafter(s, 0.0f);
        float r = fabs(fma(-s, s, x)), ru = fabs(fma(-up, up, x)), rd = fabs(fma(-dn, dn, x));
        if (ru < r) s = up;
        else if (rd < r) s = dn;
        else break;
    }
    return s;
}

/// Unpremultiplies an accumulated plane value (photocraft `unpremul_px`).
inline float4 pca_sty_unpremul(float4 v, bool alpha) {
    if (!alpha) return v;
    float a = v.w;
    return a > 1e-7f ? float4(v.xyz / a, a) : float4(0.0f, 0.0f, 0.0f, a);
}

/// A plane pixel premultiplied (alpha unchanged).
inline float4 pca_sty_premul(float4 s, bool alpha) {
    return alpha ? float4(s.x * s.w, s.y * s.w, s.z * s.w, s.w) : s;
}

// ---------------------------------------------------------------- Mosaic

struct pca_sty_mosaic_params {
    int2 b_origin;
    int2 b_size;
    int2 c0;      // first cell (cx0, cy0)
    int2 ncell;   // cells across / down
    int cs;
    int row0;     // document row of rows-texture row 0
    int nrows;
    int pad0;
};

/// Premultiplied sum of each cell column's pixels inside the bounds, per document row.
kernel void pca_sty_mosaic_rows(constant pca_frame& f [[buffer(0)]], constant pca_sty_mosaic_params& p [[buffer(1)]],
                                pca_in src [[texture(0)]], pca_out rows [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.ncell.x || int(gid.y) >= p.nrows) return;
    bool alpha = f.alpha != 0u;
    int cx = p.c0.x + int(gid.x);
    int y = p.row0 + int(gid.y);
    int bx1 = p.b_origin.x + p.b_size.x;
    int x0 = max(p.b_origin.x + cx * p.cs, p.b_origin.x);
    int x1 = min(p.b_origin.x + (cx + 1) * p.cs, bx1);
    float4 acc = float4(0.0f);
    for (int x = x0; x < x1; x++) acc += pca_sty_premul(pca_get(src, f, int2(x, y)), alpha);
    rows.write(acc, gid);
}

/// Each cell's average (photocraft: premultiplied mean, then unpremultiplied).
kernel void pca_sty_mosaic_cells(constant pca_frame& f [[buffer(0)]], constant pca_sty_mosaic_params& p [[buffer(1)]],
                                 pca_in rows [[texture(0)]], pca_out cells [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.ncell.x || int(gid.y) >= p.ncell.y) return;
    bool alpha = f.alpha != 0u;
    int cx = p.c0.x + int(gid.x), cy = p.c0.y + int(gid.y);
    int2 b0 = p.b_origin, b1 = p.b_origin + p.b_size;
    int x0 = max(b0.x + cx * p.cs, b0.x), x1 = min(b0.x + (cx + 1) * p.cs, b1.x);
    int y0 = max(b0.y + cy * p.cs, b0.y), y1 = min(b0.y + (cy + 1) * p.cs, b1.y);
    float4 acc = float4(0.0f);
    float count = 0.0f;
    if (x1 > x0 && y1 > y0) {
        for (int y = y0; y < y1; y++) acc += rows.read(uint2(gid.x, uint(y - p.row0)));
        count = float(x1 - x0) * float(y1 - y0);
    }
    if (count > 0.0f) acc /= count;
    cells.write(pca_sty_unpremul(acc, alpha), gid);
}

/// Every output pixel takes its cell's average.
kernel void pca_sty_mosaic_out(constant pca_frame& f [[buffer(0)]], constant pca_sty_mosaic_params& p [[buffer(1)]],
                               pca_in cells [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    int cx = pca_sty_div_euclid(q.x - p.b_origin.x, p.cs) - p.c0.x;
    int cy = pca_sty_div_euclid(q.y - p.b_origin.y, p.cs) - p.c0.y;
    dst.write(cells.read(uint2(cx, cy)), gid);
}

// ---------------------------------------------------------------- Emboss, Desaturate

struct pca_sty_emboss_params {
    int2 d;
    float k;
    int luma;
};

kernel void pca_sty_emboss(constant pca_frame& f [[buffer(0)]], constant pca_sty_emboss_params& p [[buffer(1)]],
                           pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float l1 = pca_sty_luma(pca_get(src, f, q + p.d), p.luma);
    float l2 = pca_sty_luma(pca_get(src, f, q - p.d), p.luma);
    float diff = l1 - l2;
    float g = clamp(0.5f + p.k * diff, 0.0f, 1.0f);
    dst.write(pca_sty_set_gray(g, pca_get(src, f, q), f), gid);
}

kernel void pca_sty_desaturate(constant pca_frame& f [[buffer(0)]], constant pca_sty_emboss_params& p [[buffer(1)]],
                               pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q);
    dst.write(pca_sty_set_gray(pca_sty_luma(v, p.luma), v, f), gid);
}

// ---------------------------------------------------------------- Find Edges, Solarize, Invert

struct pca_sty_find_edges_params {
    int sub;   // 1: channel values are ink (CMYK), so the edge strength is written as ink
    int pad0;
    int pad1;
    int pad2;
};

kernel void pca_sty_find_edges(constant pca_frame& f [[buffer(0)]], constant pca_sty_find_edges_params& p [[buffer(1)]],
                               pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 nw = pca_get(src, f, q + int2(-1, -1)), n = pca_get(src, f, q + int2(0, -1)), ne = pca_get(src, f, q + int2(1, -1));
    float4 w = pca_get(src, f, q + int2(-1, 0)), c = pca_get(src, f, q), e = pca_get(src, f, q + int2(1, 0));
    float4 sw = pca_get(src, f, q + int2(-1, 1)), s = pca_get(src, f, q + int2(0, 1)), se = pca_get(src, f, q + int2(1, 1));
    float4 gx = (ne + 2.0f * e + se) - (nw + 2.0f * w + sw);
    float4 gy = (sw + 2.0f * s + se) - (nw + 2.0f * n + ne);
    float4 m = gx * gx;
    m = m + gy * gy;
    float4 edge = clamp(sqrt(m) / 4.0f, 0.0f, 1.0f);
    float4 r = p.sub != 0 ? edge : 1.0f - edge;
    if (f.alpha != 0u) r.w = c.w;
    dst.write(r, gid);
}

struct pca_sty_per_pixel_params {
    int op;   // 0 invert, 1 solarize, 2 solarize for ink values (CMYK)
    int pad0;
    int pad1;
    int pad2;
};

kernel void pca_sty_per_pixel(constant pca_frame& f [[buffer(0)]], constant pca_sty_per_pixel_params& p [[buffer(1)]],
                              pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q);
    float4 r = p.op == 0 ? 1.0f - v : (p.op == 2 ? select(v, 1.0f - v, v < 0.5f) : select(v, 1.0f - v, v > 0.5f));
    if (f.alpha != 0u) r.w = v.w;
    dst.write(r, gid);
}

// ---------------------------------------------------------------- Diffuse

struct pca_sty_diffuse_params {
    uint seed;
    int mode;    // 0 normal, 1 darken only, 2 lighten only, 3 anisotropic
    int luma;
    int pad0;
};

constant int2 pca_sty_ring[8] = {int2(1, 0), int2(1, 1), int2(0, 1), int2(-1, 1), int2(-1, 0), int2(-1, -1), int2(0, -1), int2(1, -1)};

kernel void pca_sty_diffuse(constant pca_frame& f [[buffer(0)]], constant pca_sty_diffuse_params& p [[buffer(1)]],
                            pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool alpha = f.alpha != 0u;
    float4 px = pca_get(src, f, q);
    if (p.mode == 3) {
        float me = pca_sty_luma(px, p.luma);
        float best = FLT_MAX;
        int2 bd = int2(0);
        int start = int(pca_hash01(q.x, q.y, 3u, p.seed) * 8.0f);
        for (int k = 0; k < 8; k++) {
            int2 d = pca_sty_ring[(start + k) % 8];
            float dd = fabs(pca_sty_luma(pca_get(src, f, q + d), p.luma) - me);
            if (dd < best) { best = dd; bd = d; }
        }
        float4 nb = pca_get(src, f, q + bd);
        dst.write(0.5f * (px + nb), gid);
        return;
    }
    int dx = int(pca_hash01(q.x, q.y, 1u, p.seed) * 3.0f) - 1;
    int dy = int(pca_hash01(q.x, q.y, 2u, p.seed) * 3.0f) - 1;
    float4 nb = pca_get(src, f, q + int2(dx, dy));
    bool take = true;
    if (p.mode != 0) {
        if (alpha && nb.w <= 0.0f && px.w > 0.0f) take = false;
        else if (p.mode == 1) take = pca_sty_luma(nb, p.luma) < pca_sty_luma(px, p.luma);
        else take = pca_sty_luma(nb, p.luma) > pca_sty_luma(px, p.luma);
    }
    dst.write(take ? nb : px, gid);
}

// ---------------------------------------------------------------- Tiles

struct pca_sty_tiles_params {
    float4 fg;
    float4 bg;
    int2 b_origin;
    int2 b_size;
    float ts;
    float m;
    uint seed;
    int fill;   // 0 background, 1 foreground, 2 inverse, 3 unaltered
};

kernel void pca_sty_tiles(constant pca_frame& f [[buffer(0)]], constant pca_sty_tiles_params& p [[buffer(1)]],
                          pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 px = pca_get(src, f, q);
    int2 b0 = p.b_origin, b1 = p.b_origin + p.b_size;
    if (q.x < b0.x || q.y < b0.y || q.x >= b1.x || q.y >= b1.y) { dst.write(px, gid); return; }
    float fx = float(q.x) + 0.5f;
    fx = fx - float(b0.x);
    float fy = float(q.y) + 0.5f;
    fy = fy - float(b0.y);
    int gx = pca_sty_i32(floor(fx / p.ts)), gy = pca_sty_i32(floor(fy / p.ts));
    float bw = float(p.b_size.x), bh = float(p.b_size.y);
    bool hit = false;
    int2 order = int2(0);
    float2 off = float2(0.0f);
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int cx = gx + dx, cy = gy + dy;
            float hx = pca_hash01(cx, cy, 31u, p.seed) * 2.0f;
            float hy = pca_hash01(cx, cy, 32u, p.seed) * 2.0f;
            float ox = (hx - 1.0f) * p.m, oy = (hy - 1.0f) * p.m;
            float tx = float(cx) * p.ts, ty = float(cy) * p.ts;
            float u = fx - ox;
            u = u - tx;
            float v = fy - oy;
            v = v - ty;
            if (u >= 0.0f && v >= 0.0f && u < p.ts && v < p.ts && tx < bw && ty < bh && cx >= 0 && cy >= 0) {
                if (!hit || cy > order.x || (cy == order.x && cx > order.y)) {
                    hit = true;
                    order = int2(cy, cx);
                    off = float2(ox, oy);
                }
            }
        }
    }
    if (hit) {
        float sxf = float(q.x) + 0.5f;
        sxf = sxf - off.x;
        float syf = float(q.y) + 0.5f;
        syf = syf - off.y;
        int sx = clamp(pca_sty_i32(floor(sxf)), b0.x, b1.x - 1);
        int sy = clamp(pca_sty_i32(floor(syf)), b0.y, b1.y - 1);
        dst.write(pca_get(src, f, int2(sx, sy)), gid);
        return;
    }
    float4 r = px;
    if (p.fill == 0) r = p.bg;
    else if (p.fill == 1) r = p.fg;
    else if (p.fill == 2) { r = 1.0f - px; if (f.alpha != 0u) r.w = px.w; }
    dst.write(r, gid);
}

// ---------------------------------------------------------------- Trace Contour

struct pca_sty_trace_params {
    int2 area_origin;
    int2 area_size;
    float t;
    int upper;
    int sub;
    int pad0;
};

inline float4 pca_sty_bright(pca_in src, constant pca_frame& f, constant pca_sty_trace_params& p, int2 q) {
    float4 v = pca_get_edge(src, f, q, PCA_EDGE_REPEAT, p.area_origin, p.area_size);
    return p.sub != 0 ? 1.0f - v : v;
}

kernel void pca_sty_trace_contour(constant pca_frame& f [[buffer(0)]], constant pca_sty_trace_params& p [[buffer(1)]],
                                  pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool4 me = pca_sty_bright(src, f, p, q) > p.t;
    bool4 r = pca_sty_bright(src, f, p, q + int2(1, 0)) > p.t;
    bool4 l = pca_sty_bright(src, f, p, q + int2(-1, 0)) > p.t;
    bool4 d = pca_sty_bright(src, f, p, q + int2(0, 1)) > p.t;
    bool4 u = pca_sty_bright(src, f, p, q + int2(0, -1)) > p.t;
    bool up = p.upper != 0;
    float4 res;
    for (int k = 0; k < 4; k++) {
        bool line = me[k] == up && (r[k] != me[k] || l[k] != me[k] || d[k] != me[k] || u[k] != me[k]);
        float paper = line ? 0.0f : 1.0f;
        res[k] = p.sub != 0 ? 1.0f - paper : paper;
    }
    if (f.alpha != 0u) res.w = pca_get(src, f, q).w;
    dst.write(res, gid);
}

// ---------------------------------------------------------------- Wind

struct pca_sty_wind_params {
    int2 lum_origin;
    int2 lum_size;
    int lmax;
    int d;          // +1 streaks extend to +x (wind from the left), −1 from the right
    uint seed;
    float strength;
    int luma;
    int pad0;
    int pad1;
    int pad2;
};

/// Stagger: rows split into 8–40 px segments, each shifted downwind by 0–lmax px.
kernel void pca_sty_wind_stagger(constant pca_frame& f [[buffer(0)]], constant pca_sty_wind_params& p [[buffer(1)]],
                                 pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    int seg_len = 8 + int(pca_hash01(0, q.y, 41u, p.seed) * 32.0f);
    int phase = int(pca_hash01(1, q.y, 42u, p.seed) * float(seg_len));
    int seg = pca_sty_div_euclid(q.x * p.d + phase, seg_len);
    float h = pca_hash01(seg, q.y, 43u, p.seed);
    int shift = pca_sty_i32(h * h * float(p.lmax));
    dst.write(pca_get(src, f, int2(q.x - p.d * shift, q.y)), gid);
}

/// Luma of the source (0 outside) over the rows' search span.
kernel void pca_sty_wind_luma(constant pca_frame& f [[buffer(0)]], constant pca_sty_wind_params& p [[buffer(1)]],
                              pca_in src [[texture(0)]], pca_out lum [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.lum_size.x || int(gid.y) >= p.lum_size.y) return;
    float l = pca_sty_luma(pca_get(src, f, p.lum_origin + int2(gid)), p.luma);
    lum.write(float4(l, 0.0f, 0.0f, 0.0f), gid);
}

/// Wind / Blast: the strongest upwind edge whose random-length streak reaches the pixel.
kernel void pca_sty_wind(constant pca_frame& f [[buffer(0)]], constant pca_sty_wind_params& p [[buffer(1)]],
                         pca_in src [[texture(0)]], pca_in lum [[texture(1)]], pca_out dst [[texture(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float lm = float(p.lmax);
    float best = 0.0f;
    int bs = q.x;
    int ly = q.y - p.lum_origin.y;
    for (int k = 1; k <= p.lmax; k++) {
        int s = q.x - p.d * k;
        float h = pca_hash01(s, q.y, 44u, p.seed);
        float len = max(h * h * lm, 1.0f);
        if (float(k) > len) continue;
        float a = lum.read(uint2(s - p.lum_origin.x, ly)).x;
        float b = lum.read(uint2(s - p.d - p.lum_origin.x, ly)).x;
        float e = min(fabs(a - b) * p.strength, 1.0f);
        float wgt = e * (1.0f - float(k) / (len + 1.0f));
        if (wgt > best) { best = wgt; bs = s; }
    }
    float4 px = pca_get(src, f, q);
    if (best > 0.0f) {
        float4 t = pca_get(src, f, int2(bs, q.y));
        px = px + (t - px) * best;
    }
    dst.write(px, gid);
}

// ---------------------------------------------------------------- Glowing Edges

struct pca_sty_glow_params {
    int2 win_origin;
    int2 win_size;
    float gain;
    int pad0;
    int pad1;
    int pad2;
};

/// The gallery's working copy: sRGB of every window pixel (gray-like → (g, g, g)).
kernel void pca_sty_glow_rgb(constant pca_frame& f [[buffer(0)]], constant pca_sty_glow_params& p [[buffer(1)]],
                             pca_in src [[texture(0)]], pca_out rgb [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.win_size.x || int(gid.y) >= p.win_size.y) return;
    float4 v = src.read(gid);
    rgb.write(f.mode == 0u ? float4(v.x, v.x, v.x, 0.0f) : float4(v.xyz, 0.0f), gid);
}

/// photocraft `grad_mag` per channel: Sobel / 8 with edges clamped to the window.
kernel void pca_sty_glow_sobel(constant pca_frame& f [[buffer(0)]], constant pca_sty_glow_params& p [[buffer(1)]],
                               pca_in c [[texture(0)]], pca_out e [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.win_size.x || y >= p.win_size.y) return;
    int2 hi = p.win_size - 1;
    float4 v[3][3];
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++) v[dy + 1][dx + 1] = c.read(uint2(clamp(int2(x + dx, y + dy), int2(0), hi)));
    float4 gx = ((v[0][2] + 2.0f * v[1][2] + v[2][2]) - (v[0][0] + 2.0f * v[1][0] + v[2][0])) / 8.0f;
    float4 gy = ((v[2][0] + 2.0f * v[2][1] + v[2][2]) - (v[0][0] + 2.0f * v[0][1] + v[0][2])) / 8.0f;
    float4 m = gx * gx;
    m = m + gy * gy;
    e.write(float4(pca_sty_sqrt(m.x), pca_sty_sqrt(m.y), pca_sty_sqrt(m.z), 0.0f), gid);
}

kernel void pca_sty_glow_out(constant pca_frame& f [[buffer(0)]], constant pca_sty_glow_params& p [[buffer(1)]],
                             pca_in src [[texture(0)]], pca_in glow [[texture(1)]], pca_out dst [[texture(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    int2 w = clamp(q - p.win_origin, int2(0), p.win_size - 1);
    float3 g = clamp(clamp(glow.read(uint2(w)).xyz * p.gain, 0.0f, 1.0f), 0.0f, 1.0f);
    float a = f.alpha != 0u ? pca_get(src, f, q).w : 0.0f;
    float4 r = f.mode == 0u ? float4(0.299f * g.x + 0.587f * g.y + 0.114f * g.z, 0.0f, 0.0f, a) : float4(g, a);
    dst.write(r, gid);
}
