// Port of photocraft-algo (crates/algo/src/stylize2.rs `extrude_direct`, stylize2/extrude.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Extrude: per-cell colour/height, then per pixel the pyramid face or the highest swept block
// (photocraft's candidate search, visiting only cells whose sweep can reach the pixel).

struct pca_sty_extrude_params {
    int2 b_origin;
    int2 b_size;
    int2 c0;       // first stored cell
    int2 ncell;    // stored cells across / down
    float2 bc;     // bounds centre
    int cs;
    int k;
    float half_diag;
    float reach;
    float depth;   // clamped 1…255
    uint seed;
    int level_based;
    int solid;
    int mask;
    int sub;
    int luma;
    int pad0;
    int pad1;
    int pad2;
};

/// Sparse-sampled premultiplied mean of each stored cell (straight result) and its height.
kernel void pca_sty_extrude_cells(constant pca_frame& f [[buffer(0)]], constant pca_sty_extrude_params& p [[buffer(1)]],
                                  pca_in src [[texture(0)]], pca_out cols [[texture(1)]], pca_out info [[texture(2)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.ncell.x || int(gid.y) >= p.ncell.y) return;
    bool alpha = f.alpha != 0u;
    int gx = p.c0.x + int(gid.x), gy = p.c0.y + int(gid.y);
    int2 b0 = p.b_origin, b1 = p.b_origin + p.b_size;
    int x0 = max(b0.x + gx * p.cs, b0.x), x1 = min(b0.x + (gx + 1) * p.cs, b1.x);
    int y0 = max(b0.y + gy * p.cs, b0.y), y1 = min(b0.y + (gy + 1) * p.cs, b1.y);
    int step = max(p.cs / 8, 1);
    float4 acc = float4(0.0f);
    float cnt = 0.0f;
    for (int yy = y0; yy < y1; yy += step) {
        for (int xx = x0; xx < x1; xx += step) {
            acc += pca_sty_premul(pca_get(src, f, int2(xx, yy)), alpha);
            cnt += 1.0f;
        }
    }
    if (cnt > 0.0f) acc /= cnt;
    acc = pca_sty_unpremul(acc, alpha);
    float h = p.level_based != 0 ? clamp(pca_sty_luma(acc, p.luma), 0.0f, 1.0f) : pca_hash01(gx, gy, 21u, p.seed);
    cols.write(acc, gid);
    info.write(float4(h, 0.0f, 0.0f, 0.0f), gid);
}

/// Clears the pruning flag when any cell height is not finite.
kernel void pca_sty_extrude_finite(constant pca_frame& f [[buffer(0)]], constant pca_sty_extrude_params& p [[buffer(1)]],
                                   device atomic_uint* flag [[buffer(2)]], pca_in info [[texture(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.ncell.x || int(gid.y) >= p.ncell.y) return;
    if (!isfinite(info.read(gid).x)) atomic_store_explicit(flag, 0u, memory_order_relaxed);
}

/// The shaded colour of a cell: colour channels scaled toward black (ink models: toward
/// paper), alpha from the cell.
inline float4 pca_sty_extrude_shade(float4 col, float k, constant pca_frame& f, constant pca_sty_extrude_params& p) {
    float4 r;
    for (int c = 0; c < 4; c++) {
        float v = p.sub != 0 ? 1.0f - (1.0f - col[c]) * k : col[c] * k;
        r[c] = clamp(v, 0.0f, 1.0f);
    }
    if (f.alpha != 0u) r.w = col.w;
    return r;
}

inline bool pca_sty_extrude_incomplete(int cx, int cy, constant pca_sty_extrude_params& p) {
    int2 b0 = p.b_origin, b1 = p.b_origin + p.b_size;
    int x0 = b0.x + cx * p.cs, y0 = b0.y + cy * p.cs;
    return x0 < b0.x || y0 < b0.y || x0 + p.cs > b1.x || y0 + p.cs > b1.y;
}

/// Rust `f32::signum` (+0 → 1).
inline float pca_sty_signum(float v) {
    if (isnan(v)) return v;
    return signbit(v) ? -1.0f : 1.0f;
}

kernel void pca_sty_extrude_pyramids(constant pca_frame& f [[buffer(0)]], constant pca_sty_extrude_params& p [[buffer(1)]],
                                     device const uint* flag [[buffer(2)]],
                                     pca_in src [[texture(0)]], pca_in cols [[texture(1)]], pca_in info [[texture(2)]],
                                     pca_out dst [[texture(3)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 px = pca_get(src, f, q);
    int2 b0 = p.b_origin, b1 = p.b_origin + p.b_size;
    if (q.x < b0.x || q.y < b0.y || q.x >= b1.x || q.y >= b1.y) { dst.write(px, gid); return; }
    int gx = pca_sty_div_euclid(q.x - b0.x, p.cs), gy = pca_sty_div_euclid(q.y - b0.y, p.cs);
    if (p.mask != 0 && pca_sty_extrude_incomplete(gx, gy, p)) { dst.write(px, gid); return; }
    uint2 ci = uint2(gx - p.c0.x, gy - p.c0.y);
    float h = info.read(ci).x;
    float fx = float(q.x) + 0.5f, fy = float(q.y) + 0.5f;
    float csf = float(p.cs);
    float mx = float(b0.x + gx * p.cs) + csf / 2.0f, my = float(b0.y + gy * p.cs) + csf / 2.0f;
    float u = fx - mx, v = fy - my;
    float hgt = h * p.depth;
    hgt = hgt / 255.0f;
    hgt = hgt * csf;
    float s = csf / 2.0f;
    float nx = 0.0f, ny = 0.0f;
    if (fabs(u) >= fabs(v)) nx = pca_sty_signum(u) * hgt; else ny = pca_sty_signum(v) * hgt;
    float nn = nx * nx + ny * ny;
    nn = nn + s * s;
    float norm = sqrt(nn);
    float dl = nx * -0.5f + ny * -0.5f;
    dl = dl + s * 0.70710677f;
    float lambert = max(dl / norm, 0.0f);
    float k = 0.35f + 0.9f * lambert;
    dst.write(pca_sty_extrude_shade(cols.read(ci), k, f, p), gid);
}

/// photocraft `interval`: t-range of the sweep putting `pt` inside the square; false when empty.
inline bool pca_sty_interval(float pt, float m, float o, float hs, thread float2& r) {
    if (fabs(o) < 1e-6f) {
        r = float2(0.0f, 1.0f);
        return fabs(pt - m) <= hs;
    }
    float d = pt - m;
    float a = (d - hs) / o, b = (d + hs) / o;
    float lo = fmax(fmin(a, b), 0.0f), hi = fmin(fmax(a, b), 1.0f);
    r = float2(lo, hi);
    return lo <= hi;
}

/// Cells along one axis whose sweep can reach `pt` (superset; see Extrude.swift `candidates`).
inline int2 pca_sty_extrude_cands(float pt, int origin, float center, float hs, float off_max, int cs, int lo, int hi) {
    float eps = 2.0f;
    float a = pt + hs;
    a = a + eps;
    float c = pt - hs;
    c = c - eps;
    float bn = c - center;
    bn = center + bn / (1.0f + off_max);
    float dn = a - center;
    dn = center + dn / (1.0f + off_max);
    float mlo = min(bn, c), mhi = max(a, dn);
    float o = float(origin) + hs;
    float csf = float(cs);
    int l = pca_sty_i32(floor((mlo - o) / csf)) - 1;
    int h = pca_sty_i32(ceil((mhi - o) / csf)) + 1;
    return int2(max(l, lo), min(h, hi));
}

kernel void pca_sty_extrude_blocks(constant pca_frame& f [[buffer(0)]], constant pca_sty_extrude_params& p [[buffer(1)]],
                                   device const uint* flag [[buffer(2)]],
                                   pca_in src [[texture(0)]], pca_in cols [[texture(1)]], pca_in info [[texture(2)]],
                                   pca_out dst [[texture(3)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 px = pca_get(src, f, q);
    int2 b0 = p.b_origin, b1 = p.b_origin + p.b_size;
    if (q.x < b0.x || q.y < b0.y || q.x >= b1.x || q.y >= b1.y) { dst.write(px, gid); return; }
    int gx = pca_sty_div_euclid(q.x - b0.x, p.cs), gy = pca_sty_div_euclid(q.y - b0.y, p.cs);
    float fx = float(q.x) + 0.5f, fy = float(q.y) + 0.5f;
    float csf = float(p.cs);
    float hs = csf / 2.0f;
    int2 rx = int2(max(gx - p.k, p.c0.x), min(gx + p.k, p.c0.x + p.ncell.x - 1));
    int2 ry = int2(max(gy - p.k, p.c0.y), min(gy + p.k, p.c0.y + p.ncell.y - 1));
    if (flag[0] != 0u) {
        float off_max = p.reach / p.half_diag;
        rx = pca_sty_extrude_cands(fx, b0.x, p.bc.x, hs, off_max, p.cs, rx.x, rx.y);
        ry = pca_sty_extrude_cands(fy, b0.y, p.bc.y, hs, off_max, p.cs, ry.x, ry.y);
    }
    bool found = false;
    float bh = 0.0f;
    int2 bc = int2(0);
    int face = 0;
    for (int cy = ry.x; cy <= ry.y; cy++) {
        for (int cx = rx.x; cx <= rx.y; cx++) {
            if (p.mask != 0 && pca_sty_extrude_incomplete(cx, cy, p)) continue;
            float h = info.read(uint2(cx - p.c0.x, cy - p.c0.y)).x;
            if (found && bh >= h) continue;
            float mx = float(b0.x + cx * p.cs) + hs, my = float(b0.y + cy * p.cs) + hs;
            float off = p.reach * h;
            off = off / p.half_diag;
            float ox = (mx - p.bc.x) * off, oy = (my - p.bc.y) * off;
            float2 ix, iy;
            if (!pca_sty_interval(fx, mx, ox, hs, ix)) continue;
            if (!pca_sty_interval(fy, my, oy, hs, iy)) continue;
            float lo = max(ix.x, iy.x), hi = min(ix.y, iy.y);
            if (lo > hi) continue;
            int fc;
            if (hi >= 1.0f) fc = 0;
            else if (ix.y < iy.y) fc = ox > 0.0f ? 1 : 2;
            else if (oy > 0.0f) fc = 3;
            else fc = 4;
            found = true;
            bh = h;
            bc = int2(cx, cy);
            face = fc;
        }
    }
    if (!found) { dst.write(px, gid); return; }
    uint2 ci = uint2(bc.x - p.c0.x, bc.y - p.c0.y);
    if (face == 0 && p.solid == 0) {
        int rx0 = b0.x + bc.x * p.cs, ry0 = b0.y + bc.y * p.cs;
        float mx = float(rx0) + hs, my = float(ry0) + hs;
        float off = p.reach * bh;
        off = off / p.half_diag;
        float sxf = fx - (mx - p.bc.x) * off, syf = fy - (my - p.bc.y) * off;
        int sx = clamp(pca_sty_i32(floor(sxf)), rx0, rx0 + p.cs - 1);
        int sy = clamp(pca_sty_i32(floor(syf)), ry0, ry0 + p.cs - 1);
        dst.write(pca_get(src, f, int2(sx, sy)), gid);
        return;
    }
    float k = face == 0 ? 1.0f : face == 1 ? 0.85f : face == 2 ? 0.55f : face == 3 ? 0.95f : 0.45f;
    dst.write(pca_sty_extrude_shade(cols.read(ci), k, f, p), gid);
}
