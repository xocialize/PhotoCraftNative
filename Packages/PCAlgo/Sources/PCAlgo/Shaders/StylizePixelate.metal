// Port of photocraft-algo (crates/algo/src/pixelate.rs, pixelate/{facet,screen}.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Pixelate kernels: Color Halftone (dot radii per screen cell, then per-pixel coverage),
// Crystallize (Voronoi owners, per-cell gathered sums in photocraft's order, fill), Facet
// (quadrant statistics once per 3×3 quadrant, then the least-varied quadrant), Fragment,
// Mezzotint and Pointillize. Uses the pca_sty_ helpers of Stylize.metal.

// ---------------------------------------------------------------- Color Halftone

struct pca_sty_halftone_chan {
    float s;     // sin / cos of the channel's screen angle
    float c;
    int x0;      // radius-table box of this channel's screen cells
    int y0;
    int w;
    int h;
    int valid;   // 1: a colour channel of this plane
    int pad0;
};

struct pca_sty_halftone_params {
    int2 clip_origin;
    int2 clip_size;
    float2 origin;
    int2 table;
    float rmax;
    float cell;
    int ink;     // 1: values are ink (CMYK)
    int pad0;
};

/// The five-tap value of plane component `k` around a document point (photocraft `value`).
inline float pca_sty_ht_value(pca_in src, constant pca_frame& f, constant pca_sty_halftone_params& p, float x, float y, int k) {
    float d = p.cell * 0.25f;
    float2 taps[5] = {float2(0.0f, 0.0f), float2(-d, -d), float2(d, -d), float2(-d, d), float2(d, d)};
    int2 lo = p.clip_origin, hi = p.clip_origin + p.clip_size - 1;
    float acc = 0.0f;
    for (int t = 0; t < 5; t++) {
        int ix = clamp(pca_sty_i32(floor(x + taps[t].x)), lo.x, hi.x);
        int iy = clamp(pca_sty_i32(floor(y + taps[t].y)), lo.y, hi.y);
        acc += pca_get(src, f, int2(ix, iy))[k];
    }
    return acc / 5.0f;
}

/// Dot radius from a value: area tracks ink until dots touch, then grows to the corners.
inline float pca_sty_ht_radius(float v, float cell, bool ink_is_value) {
    float raw = clamp(v, 0.0f, 1.0f);
    float ink = ink_is_value ? raw : 1.0f - raw;
    float touch = 0.78539816f;
    if (ink <= touch) return cell * pca_sty_sqrt(ink / 3.14159265f);
    float t = (ink - touch) / (1.0f - touch);
    t = t * (0.70710677f - 0.5f);
    return cell * (0.5f + t);
}

/// Document centre of screen cell (cu, cv) for a channel's rotation.
inline float2 pca_sty_ht_center(float cu, float cv, constant pca_sty_halftone_chan& ch, constant pca_sty_halftone_params& p,
                                 thread float2& m) {
    float mu = (cu + 0.5f) * p.cell, mv = (cv + 0.5f) * p.cell;
    m = float2(mu, mv);
    float dx = mu * ch.c - mv * ch.s;
    float dy = mu * ch.s + mv * ch.c;
    return float2(dx + p.origin.x, dy + p.origin.y);
}

kernel void pca_sty_halftone_radii(constant pca_frame& f [[buffer(0)]], constant pca_sty_halftone_params& p [[buffer(1)]],
                                   constant pca_sty_halftone_chan* chans [[buffer(2)]],
                                   pca_in src [[texture(0)]], pca_out table [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.table.x || int(gid.y) >= p.table.y) return;
    float4 r = float4(0.0f);
    for (int k = 0; k < 4; k++) {
        constant pca_sty_halftone_chan& ch = chans[k];
        if (ch.valid == 0 || int(gid.x) >= ch.w || int(gid.y) >= ch.h) continue;
        float2 m;
        float2 d = pca_sty_ht_center(float(ch.x0 + int(gid.x)), float(ch.y0 + int(gid.y)), ch, p, m);
        r[k] = pca_sty_ht_radius(pca_sty_ht_value(src, f, p, d.x, d.y, k), p.cell, p.ink != 0);
    }
    table.write(r, gid);
}

kernel void pca_sty_halftone(constant pca_frame& f [[buffer(0)]], constant pca_sty_halftone_params& p [[buffer(1)]],
                             constant pca_sty_halftone_chan* chans [[buffer(2)]],
                             pca_in src [[texture(0)]], pca_in table [[texture(1)]], pca_out dst [[texture(2)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 res = pca_get(src, f, q);
    float fx = float(q.x) + 0.5f;
    fx = fx - p.origin.x;
    float fy = float(q.y) + 0.5f;
    fy = fy - p.origin.y;
    for (int k = 0; k < 4; k++) {
        constant pca_sty_halftone_chan& ch = chans[k];
        if (ch.valid == 0) continue;
        // Rotate into screen space.
        float u = fx * ch.c + fy * ch.s;
        float w2 = -fx * ch.s + fy * ch.c;
        float cu = floor(u / p.cell), cv = floor(w2 / p.cell);
        float cov = 0.0f;
        for (int dj = -1; dj <= 1; dj++) {
            for (int di = -1; di <= 1; di++) {
                float ku = cu + float(di), kv = cv + float(dj);
                float2 m;
                float2 dc = pca_sty_ht_center(ku, kv, ch, p, m);
                float du = u - m.x, dv = w2 - m.y;
                float dd = du * du;
                dd = pca_sty_sqrt(dd + dv * dv);
                if (dd >= p.rmax + 0.5f) continue;
                float r;
                int sx = int(ku) - ch.x0, sy = int(kv) - ch.y0;
                bool cached = isfinite(ku) && isfinite(kv) && fabs(ku) <= 4000001.0f && fabs(kv) <= 4000001.0f
                    && sx >= 0 && sy >= 0 && sx < ch.w && sy < ch.h;
                if (cached) r = table.read(uint2(sx, sy))[k];
                else r = pca_sty_ht_radius(pca_sty_ht_value(src, f, p, dc.x, dc.y, k), p.cell, p.ink != 0);
                // Tiny dots cannot cover more than their own area.
                cov = fmax(cov, fmin(clamp(r - dd + 0.5f, 0.0f, 1.0f), 3.14159265f * r * r));
            }
        }
        res[k] = p.ink != 0 ? cov : 1.0f - cov;
    }
    dst.write(res, gid);
}

// ---------------------------------------------------------------- Crystallize

struct pca_sty_crystal_params {
    int2 b_origin;
    int2 b_size;
    int2 win_origin;
    int2 win_size;
    int2 c0;
    int2 c1;
    float2 origin;
    float cell;
    uint seed;
    int chunks;   // 16-row chunks per cell box (large cells)
    int pad0;
    int pad1;
    int pad2;
};

/// The Voronoi cell owning pixel `q`: nearest jittered point of its 3×3 grid neighbourhood.
inline int2 pca_sty_crystal_owner_of(int2 q, constant pca_sty_crystal_params& p) {
    float fx = float(q.x) + 0.5f, fy = float(q.y) + 0.5f;
    int cx = pca_sty_i32(floor((fx - p.origin.x) / p.cell)), cy = pca_sty_i32(floor((fy - p.origin.y) / p.cell));
    float best = FLT_MAX;
    int2 bc = int2(cx, cy);
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float2 pt = pca_cell_point(cx + dx, cy + dy, p.cell, p.seed, p.origin);
            float ex = pt.x - fx, ey = pt.y - fy;
            float d = ex * ex;
            d = d + ey * ey;
            if (d < best) { best = d; bc = int2(cx + dx, cy + dy); }
        }
    }
    return bc;
}

kernel void pca_sty_crystal_owner(constant pca_frame& f [[buffer(0)]], constant pca_sty_crystal_params& p [[buffer(1)]],
                                  pca_out owners [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.win_size.x || int(gid.y) >= p.win_size.y) return;
    int2 o = pca_sty_crystal_owner_of(p.win_origin + int2(gid), p);
    owners.write(float4(float(o.x), float(o.y), 0.0f, 0.0f), gid);
}

/// The territory box of cell (cx, cy) (pixels whose own grid cell is within one of it, with a
/// pixel of slack) inside the window.
inline int4 pca_sty_crystal_box(int cx, int cy, constant pca_sty_crystal_params& p) {
    int x0 = p.b_origin.x + pca_sty_i32(floor(float(cx - 1) * p.cell)) - 1;
    int y0 = p.b_origin.y + pca_sty_i32(floor(float(cy - 1) * p.cell)) - 1;
    int x1 = p.b_origin.x + pca_sty_i32(ceil(float(cx + 2) * p.cell)) + 1;
    int y1 = p.b_origin.y + pca_sty_i32(ceil(float(cy + 2) * p.cell)) + 1;
    return int4(max(x0, p.win_origin.x), max(y0, p.win_origin.y),
                min(x1, p.win_origin.x + p.win_size.x), min(y1, p.win_origin.y + p.win_size.y));
}

/// Premultiplied sum and count of the pixels of rows y0…y1 of the box owned by cell (cx, cy),
/// in row-major order (the reference's order).
inline float4 pca_sty_crystal_gather(pca_in src, pca_in owners, constant pca_frame& f, constant pca_sty_crystal_params& p,
                                     int cx, int cy, int4 box, int y0, int y1, thread float& cnt) {
    bool alpha = f.alpha != 0u;
    float4 acc = float4(0.0f);
    float2 me = float2(float(cx), float(cy));
    for (int y = y0; y < y1; y++) {
        for (int x = box.x; x < box.z; x++) {
            float2 o = owners.read(uint2(x - p.win_origin.x, y - p.win_origin.y)).xy;
            if (o.x != me.x || o.y != me.y) continue;
            acc += pca_sty_premul(pca_get(src, f, int2(x, y)), alpha);
            cnt += 1.0f;
        }
    }
    return acc;
}

/// Each cell's premultiplied mean over its window pixels (straight result) and its pixel count,
/// one thread per cell (small cells).
kernel void pca_sty_crystal_cells(constant pca_frame& f [[buffer(0)]], constant pca_sty_crystal_params& p [[buffer(1)]],
                                  pca_in src [[texture(0)]], pca_in owners [[texture(1)]], pca_out avg [[texture(2)]],
                                  pca_out cnt_t [[texture(3)]], uint2 gid [[thread_position_in_grid]]) {
    int2 n = p.c1 - p.c0 + 1;
    if (int(gid.x) >= n.x || int(gid.y) >= n.y) return;
    int cx = p.c0.x + int(gid.x), cy = p.c0.y + int(gid.y);
    int4 box = pca_sty_crystal_box(cx, cy, p);
    float cnt = 0.0f;
    float4 acc = pca_sty_crystal_gather(src, owners, f, p, cx, cy, box, box.y, box.w, cnt);
    avg.write(cnt > 0.0f ? pca_sty_unpremul(acc / cnt, f.alpha != 0u) : float4(0.0f), gid);
    cnt_t.write(float4(cnt, 0.0f, 0.0f, 0.0f), gid);
}

/// Large cells: partial sums of 16-row chunks of each cell's box (gid.x = cell, gid.y = chunk),
/// two float4 per partial (sum, count).
kernel void pca_sty_crystal_partial(constant pca_frame& f [[buffer(0)]], constant pca_sty_crystal_params& p [[buffer(1)]],
                                    device float4* part [[buffer(2)]], pca_in src [[texture(0)]], pca_in owners [[texture(1)]],
                                    uint2 gid [[thread_position_in_grid]]) {
    int2 n = p.c1 - p.c0 + 1;
    if (int(gid.x) >= n.x * n.y || int(gid.y) >= p.chunks) return;
    int cx = p.c0.x + int(gid.x) % n.x, cy = p.c0.y + int(gid.x) / n.x;
    int4 box = pca_sty_crystal_box(cx, cy, p);
    int y0 = box.y + int(gid.y) * 16, y1 = min(y0 + 16, box.w);
    float cnt = 0.0f;
    float4 acc = y0 < y1 ? pca_sty_crystal_gather(src, owners, f, p, cx, cy, box, y0, y1, cnt) : float4(0.0f);
    uint i = (gid.x * uint(p.chunks) + gid.y) * 2u;
    part[i] = acc;
    part[i + 1u] = float4(cnt, 0.0f, 0.0f, 0.0f);
}

/// Large cells: the chunk partials summed in row order into the mean and count textures.
kernel void pca_sty_crystal_reduce(constant pca_frame& f [[buffer(0)]], constant pca_sty_crystal_params& p [[buffer(1)]],
                                   device const float4* part [[buffer(2)]], pca_out avg [[texture(0)]], pca_out cnt_t [[texture(1)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    int2 n = p.c1 - p.c0 + 1;
    if (int(gid.x) >= n.x || int(gid.y) >= n.y) return;
    uint cell = gid.y * uint(n.x) + gid.x;
    float4 acc = float4(0.0f);
    float cnt = 0.0f;
    for (int k = 0; k < p.chunks; k++) {
        uint i = (cell * uint(p.chunks) + uint(k)) * 2u;
        acc += part[i];
        cnt += part[i + 1u].x;
    }
    avg.write(cnt > 0.0f ? pca_sty_unpremul(acc / cnt, f.alpha != 0u) : float4(0.0f), gid);
    cnt_t.write(float4(cnt, 0.0f, 0.0f, 0.0f), gid);
}

kernel void pca_sty_crystal_out(constant pca_frame& f [[buffer(0)]], constant pca_sty_crystal_params& p [[buffer(1)]],
                                pca_in src [[texture(0)]], pca_in owners [[texture(1)]], pca_in avg [[texture(2)]],
                                pca_in cnt_t [[texture(3)]], pca_out dst [[texture(4)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 px = pca_get(src, f, q);
    int2 b0 = p.b_origin, b1 = p.b_origin + p.b_size;
    if (q.x < b0.x || q.y < b0.y || q.x >= b1.x || q.y >= b1.y) { dst.write(px, gid); return; }
    int2 w = q - p.win_origin;
    int2 o;
    if (w.x >= 0 && w.y >= 0 && w.x < p.win_size.x && w.y < p.win_size.y) {
        float2 v = owners.read(uint2(w)).xy;
        o = int2(int(v.x), int(v.y));
    } else {
        o = pca_sty_crystal_owner_of(q, p);
    }
    if (o.x < p.c0.x || o.y < p.c0.y || o.x > p.c1.x || o.y > p.c1.y) { dst.write(px, gid); return; }
    uint2 ci = uint2(o - p.c0);
    if (cnt_t.read(ci).x <= 0.0f) { dst.write(px, gid); return; }
    dst.write(avg.read(ci), gid);
}

// ---------------------------------------------------------------- Facet

struct pca_sty_facet_params {
    int2 q_origin;   // quadrant top-left corners: `out` grown by 2 up and left
    int2 q_size;
    int luma;
    int pad0;
    int pad1;
    int pad2;
};

/// Mean and luma variance of the 3×3 quadrant at each top-left corner (nine-sample order kept).
kernel void pca_sty_facet_quadrants(constant pca_frame& f [[buffer(0)]], constant pca_sty_facet_params& p [[buffer(1)]],
                                    pca_in src [[texture(0)]], pca_out means [[texture(1)]], pca_out vars [[texture(2)]],
                                    uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.q_size.x || int(gid.y) >= p.q_size.y) return;
    int2 t = p.q_origin + int2(gid);
    float4 sum = float4(0.0f);
    float s = 0.0f, s2 = 0.0f;
    for (int dy = 0; dy <= 2; dy++) {
        for (int dx = 0; dx <= 2; dx++) {
            float4 v = pca_get(src, f, t + int2(dx, dy));
            sum += v;
            float l = pca_sty_luma(v, p.luma);
            s += l;
            s2 += l * l;
        }
    }
    float m = s / 9.0f;
    means.write(sum / 9.0f, gid);
    vars.write(float4(s2 / 9.0f - m * m, 0.0f, 0.0f, 0.0f), gid);
}

kernel void pca_sty_facet(constant pca_frame& f [[buffer(0)]], constant pca_sty_facet_params& p [[buffer(1)]],
                          pca_in means [[texture(0)]], pca_in vars [[texture(1)]], pca_out dst [[texture(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    uint2 corners[4] = {gid, gid + uint2(2, 0), gid + uint2(0, 2), gid + uint2(2, 2)};
    float best = FLT_MAX;
    float4 r = float4(0.0f);
    for (int k = 0; k < 4; k++) {
        float v = vars.read(corners[k]).x;
        if (v < best) { best = v; r = means.read(corners[k]); }
    }
    dst.write(r, gid);
}

// ---------------------------------------------------------------- Fragment

kernel void pca_sty_fragment(constant pca_frame& f [[buffer(0)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool alpha = f.alpha != 0u;
    int2 offs[4] = {int2(-4, 0), int2(4, 0), int2(0, -4), int2(0, 4)};
    float4 acc = float4(0.0f);
    for (int k = 0; k < 4; k++) acc += pca_sty_premul(pca_get(src, f, q + offs[k]), alpha) * 0.25f;
    dst.write(pca_sty_unpremul(acc, alpha), gid);
}

// ---------------------------------------------------------------- Mezzotint

struct pca_sty_mezzo_params {
    int kind;
    uint seed;
    int pad0;
    int pad1;
};

inline float pca_sty_mezzo_lines(int x, int y, uint c, uint seed, int len) {
    int phase = int(pca_hash01(0, y, c + 40u, seed) * float(len));
    return pca_hash01(pca_sty_div_euclid(x + phase, len), y, c, seed);
}

inline float pca_sty_mezzo_strokes(int x, int y, uint c, uint seed, int len) {
    int d = x - y;
    int phase = int(pca_hash01(d, 0, c + 50u, seed) * float(len));
    return pca_hash01(pca_sty_div_euclid(x + y + phase, len), d, c + 60u, seed);
}

/// photocraft `mezzo_threshold`.
inline float pca_sty_mezzo_threshold(int kind, int x, int y, uint c, uint seed) {
    switch (kind) {
        case 0: return pca_hash01(x, y, c, seed);
        case 1: return pca_hash01(pca_sty_div_euclid(x, 2), pca_sty_div_euclid(y, 2), c, seed);
        case 2: {
            float a = 0.5f * pca_hash01(x, y, c, seed);
            return a + 0.5f * pca_hash01(pca_sty_div_euclid(x, 3), pca_sty_div_euclid(y, 3), c + 7u, seed);
        }
        case 3: return pca_hash01(pca_sty_div_euclid(x, 3), pca_sty_div_euclid(y, 3), c, seed);
        case 4: return pca_sty_mezzo_lines(x, y, c, seed, 6);
        case 5: return pca_sty_mezzo_lines(x, y, c, seed, 14);
        case 6: return pca_sty_mezzo_lines(x, y, c, seed, 32);
        case 7: return pca_sty_mezzo_strokes(x, y, c, seed, 5);
        case 8: return pca_sty_mezzo_strokes(x, y, c, seed, 10);
        default: return pca_sty_mezzo_strokes(x, y, c, seed, 20);
    }
}

kernel void pca_sty_mezzotint(constant pca_frame& f [[buffer(0)]], constant pca_sty_mezzo_params& p [[buffer(1)]],
                              pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q);
    for (uint k = 0; k < f.ncomp; k++) v[k] = v[k] > pca_sty_mezzo_threshold(p.kind, q.x, q.y, f.first_channel + k, p.seed) ? 1.0f : 0.0f;
    dst.write(v, gid);
}

// ---------------------------------------------------------------- Pointillize

struct pca_sty_point_params {
    float4 bg;       // the background in this plane's channels (alpha in .w)
    float2 origin;
    float cell;
    uint seed;
    int sub;
    float bg_alpha;
    int pad0;
    int pad1;
};

kernel void pca_sty_pointillize(constant pca_frame& f [[buffer(0)]], constant pca_sty_point_params& p [[buffer(1)]],
                                pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool alpha = f.alpha != 0u;
    float fx = float(q.x) + 0.5f, fy = float(q.y) + 0.5f;
    int cx = pca_sty_i32(floor((fx - p.origin.x) / p.cell)), cy = pca_sty_i32(floor((fy - p.origin.y) / p.cell));
    // The dot whose edge the pixel is deepest inside wins.
    bool found = false;
    float best = 0.0f;
    int2 bg_cell = int2(0);
    float2 bpt = float2(0.0f);
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int gx = cx + dx, gy = cy + dy;
            float2 pt = pca_cell_point(gx, gy, p.cell, p.seed, p.origin);
            float h = 0.35f * pca_hash01(gx, gy, 13u, p.seed);
            float rad = p.cell * (0.45f + h);
            float ex = pt.x - fx, ey = pt.y - fy;
            float dd = ex * ex;
            dd = pca_sty_sqrt(dd + ey * ey);
            float depth = rad - dd;
            if (depth > -0.5f && (!found || depth > best)) { found = true; best = depth; bg_cell = int2(gx, gy); bpt = pt; }
        }
    }
    float4 orig = pca_get(src, f, q);
    // Canvas first, then the dot over it with an anti-aliased edge.
    float4 canvas = p.bg;
    if (alpha) canvas.w = fmax(orig.w, fmin(p.bg_alpha, 1.0f));
    if (found) {
        float4 dot = pca_get(src, f, int2(pca_sty_i32(floor(bpt.x)), pca_sty_i32(floor(bpt.y))));
        // Slight per-dot brightness jitter, as in pointillist strokes.
        float j = (pca_hash01(bg_cell.x, bg_cell.y, 17u, p.seed) - 0.5f) * 0.08f;
        int ncol = alpha ? 3 : 4;
        for (int c = 0; c < ncol; c++) dot[c] = clamp(dot[c] + (p.sub != 0 ? -j : j), 0.0f, 1.0f);
        float k = clamp(best + 0.5f, 0.0f, 1.0f);
        canvas = canvas + (dot - canvas) * k;
    }
    dst.write(canvas, gid);
}
