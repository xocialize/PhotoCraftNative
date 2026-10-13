// Port of photocraft-algo (crates/algo/src/artistic_fx.rs: `Win`, helpers, `run`; fxutil.rs buffer blurs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter Gallery on the GPU: the sRGB working window is a float4 texture (rgb, 0) covering the
// source window from texel (0, 0); every effect turns it into a new window texture. This file
// holds the shared maths (the artistic_fx free functions, op for op), the window load / write
// back, luma, Sobel, the f64-faithful line / box blur (float-float sums, like StylizeOil's
// `pca_sty_box_ff`), Kuwahara and unsharp. Per-effect kernels are in GalleryFXEffects.metal.

struct pca_gfx_params {
    int2 win_origin;   // document coordinates of window texel (0, 0)
    int2 win_size;
    float4 fg;         // effect colours (straight sRGB)
    float4 bg;
    float4 color;
    float4 v0;         // effect values (see GalleryFXGPU.swift)
    float4 v1;
    float4 v2;
    float4 v3;
    int i0;
    int i1;
    int i2;
    int i3;
    float2 bc;         // bounds centre
    float half_b;      // half the longer bounds side (≥ 1)
    int pad0;
};

// ---------------------------------------------------------------- shared maths
// (This file sorts before Stylize*.metal in the concatenated library, so it carries its own
// copies of the sqrt / cast / float-float helpers.)

/// Correctly rounded square root (MSL `sqrt` may be off by an ulp): the neighbour whose square
/// is closest to `x`, by exact FMA residuals.
inline float pca_gfx_sqrt(float x) {
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

/// Rust `f as i32` (truncating, saturating, NaN → 0).
inline int pca_gfx_i32(float v) {
    if (isnan(v)) return 0;
    if (v >= 2147483648.0f) return INT_MAX;
    if (v <= -2147483648.0f) return INT_MIN;
    return int(v);
}

/// (hi, lo) += v in float-float (Knuth two-sum, renormalised).
inline void pca_gfx_ff_add(thread float4& hi, thread float4& lo, float4 v) {
    float4 s = hi + v;
    float4 bb = s - hi;
    float4 e = (hi - (s - bb)) + (v - bb);
    e = e + lo;
    hi = s + e;
    lo = e - (hi - s);
}

inline float pca_gfx_lum(float3 p) { return 0.299f * p.x + 0.587f * p.y + 0.114f * p.z; }
inline float3 pca_gfx_mix(float3 a, float3 b, float t) { return a + (b - a) * t; }
inline float pca_gfx_clamp01(float v) { return clamp(v, 0.0f, 1.0f); }

/// The gallery's Hermite step (`e0 > e1` falls).
inline float pca_gfx_ss(float e0, float e1, float x) {
    if (fabs(e1 - e0) < 1e-9f) return x >= e1 ? 1.0f : 0.0f;
    float t = clamp((x - e0) / (e1 - e0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

inline float pca_gfx_posterize(float v, float levels) {
    float l = fmax(levels - 1.0f, 1.0f);
    return round(pca_gfx_clamp01(v) * l) / l;
}

inline float3 pca_gfx_saturate(float3 p, float k) {
    float l = pca_gfx_lum(p);
    return float3(l + (p.x - l) * k, l + (p.y - l) * k, l + (p.z - l) * k);
}

/// Rust `f32::fract`: x − trunc(x).
inline float pca_gfx_fract(float x) { return x - trunc(x); }

inline float3 pca_gfx_normalize3(float3 v) {
    float l = fmax(pca_gfx_sqrt(v.x * v.x + v.y * v.y + v.z * v.z), 1e-9f);
    return float3(v.x / l, v.y / l, v.z / l);
}

/// Smooth value noise (0–1) on a unit lattice.
inline float pca_gfx_vnoise(float x, float y, uint seed) {
    int ix = pca_gfx_i32(floor(x)), iy = pca_gfx_i32(floor(y));
    float tx = x - float(ix), ty = y - float(iy);
    float sx = tx * tx * (3.0f - 2.0f * tx), sy = ty * ty * (3.0f - 2.0f * ty);
    float h00 = pca_hash01(ix, iy, 0u, seed), h10 = pca_hash01(ix + 1, iy, 0u, seed);
    float h01 = pca_hash01(ix, iy + 1, 0u, seed), h11 = pca_hash01(ix + 1, iy + 1, 0u, seed);
    float top = h00 + (h10 - h00) * sx;
    float bot = h01 + (h11 - h01) * sx;
    return top + (bot - top) * sy;
}

/// Three-octave value noise (0–1).
inline float pca_gfx_fbm(float x, float y, uint seed) {
    return (pca_gfx_vnoise(x, y, seed) * 0.57f + pca_gfx_vnoise(x * 2.03f, y * 2.03f, seed ^ 0x51u) * 0.29f
            + pca_gfx_vnoise(x * 4.1f, y * 4.1f, seed ^ 0xa3u) * 0.14f) / 1.0f;
}

inline float2 pca_gfx_unit(int2 d) {
    float dx = float(d.x), dy = float(d.y);
    float l = fmax(pca_gfx_sqrt(dx * dx + dy * dy), 1e-6f);
    return float2(dx / l, dy / l);
}

/// Stroke texture: value noise stretched `len` px along `d` and `wid` px across.
inline float pca_gfx_strokes(int x, int y, int2 d, float len, float wid, uint seed) {
    float2 u2 = pca_gfx_unit(d);
    float fx = float(x), fy = float(y);
    float u = fx * u2.x + fy * u2.y;
    float v = -fx * u2.y + fy * u2.x;
    return pca_gfx_vnoise(u / fmax(len, 0.5f), v / fmax(wid, 0.3f), seed);
}

/// The window pixel nearest document `q`, clamped to the window.
inline float3 pca_gfx_at(pca_in t, constant pca_gfx_params& p, int2 q) {
    int2 w = clamp(q - p.win_origin, int2(0), p.win_size - 1);
    return t.read(uint2(w)).xyz;
}

/// Bilinear window sample at document coordinates (pixel centres at .5), clamped to the window.
inline float3 pca_gfx_sample(pca_in t, constant pca_gfx_params& p, float x, float y) {
    float fx = clamp(x - 0.5f - float(p.win_origin.x), 0.0f, float(p.win_size.x - 1));
    float fy = clamp(y - 0.5f - float(p.win_origin.y), 0.0f, float(p.win_size.y - 1));
    int x0 = int(floor(fx)), y0 = int(floor(fy));
    int x1 = min(x0 + 1, p.win_size.x - 1), y1 = min(y0 + 1, p.win_size.y - 1);
    float ax = fx - float(x0), ay = fy - float(y0);
    float3 top = pca_gfx_mix(t.read(uint2(x0, y0)).xyz, t.read(uint2(x1, y0)).xyz, ax);
    float3 bot = pca_gfx_mix(t.read(uint2(x0, y1)).xyz, t.read(uint2(x1, y1)).xyz, ax);
    return pca_gfx_mix(top, bot, ay);
}

/// photocraft `paint_stroke`: the stroke colour (from `src`) and where the pixel lies along it.
inline float3 pca_gfx_paint_stroke(pca_in src, constant pca_gfx_params& p, int x, int y, int2 d, float len, float wid, uint seed,
                                   thread float& t) {
    float2 u2 = pca_gfx_unit(d);
    len = fmax(len, 1.0f);
    wid = fmax(wid, 0.5f);
    float fx = float(x) + 0.5f, fy = float(y) + 0.5f;
    float u = fx * u2.x + fy * u2.y;
    float v = -fx * u2.y + fy * u2.x;
    int lane = pca_gfx_i32(floor(v / wid));
    float off = pca_hash01(lane, 0, 0u, seed) * len;
    t = pca_rem_euclid_f((u + off) / len, 1.0f);
    float du = (0.5f - t) * len;
    return pca_gfx_sample(src, p, fx + du * u2.x, fy + du * u2.y);
}

/// Lambert shading factor (1 = flat) of a height field with gradient (gx, gy).
inline float pca_gfx_shade(float gx, float gy, float2 light, float k) {
    float nx = -k * gx, ny = -k * gy, nz = 1.0f;
    float nl = pca_gfx_sqrt(nx * nx + ny * ny + nz * nz);
    float lx = light.x, ly = light.y, lz = 1.0f;
    float ll = pca_gfx_sqrt(lx * lx + ly * ly + lz * lz);
    float d = (nx * lx + ny * ly + nz * lz) / (nl * ll);
    return d / (lz / ll);
}

/// Basket weave of threads `p` px wide with `noise` irregularity.
inline float pca_gfx_weave(float x, float y, float pw, float noise) {
    int cx = pca_gfx_i32(floor(x / pw)), cy = pca_gfx_i32(floor(y / pw));
    bool over_h = pca_rem_euclid(cx + cy, 2) == 0;
    float u = pca_rem_euclid_f(x, pw) / pw, v = pca_rem_euclid_f(y, pw) / pw;
    float ridge = over_h ? sin(v * 3.14159265358979323846f) : sin(u * 3.14159265358979323846f);
    float n = pca_gfx_vnoise(x / (pw * 0.7f), y / (pw * 2.0f), 97u);
    return ridge * (1.0f - noise) + n * noise;
}

/// Procedural textures (0–1) at document coordinates, scaled by `s` (GalleryFXKit.textureCode).
inline float pca_gfx_texture(int kind, float x, float y, float s) {
    x = x / s;
    y = y / s;
    switch (kind) {
        case 0: {
            float bw = 24.0f, bh = 12.0f;
            float row = floor(y / bh);
            float xo = x + (pca_gfx_i32(row) % 2 == 0 ? 0.0f : bw / 2.0f);
            float u = pca_rem_euclid_f(xo, bw), v = pca_rem_euclid_f(y, bh);
            float d = fmin(fmin(u, bw - u), fmin(v, bh - v));
            return pca_gfx_ss(0.6f, 2.2f, d) * (0.85f + 0.15f * pca_gfx_vnoise(x / 3.0f, y / 3.0f, 91u));
        }
        case 1: return pca_gfx_weave(x, y, 7.0f, 0.35f);
        case 2: return pca_gfx_weave(x, y, 3.5f, 0.18f);
        case 3: return pca_gfx_fbm(x / 7.0f, y / 7.0f, 93u) * 0.7f + pca_hash01(pca_gfx_i32(x), pca_gfx_i32(y), 0u, 94u) * 0.3f;
        case 4: {
            float b = 18.0f;
            float u = pca_rem_euclid_f(x, b) / b, v = pca_rem_euclid_f(y, b) / b;
            return fmin(fmin(fmin(u, 1.0f - u), fmin(v, 1.0f - v)) * 4.0f, 1.0f);
        }
        case 5: return pca_gfx_fbm(x / 2.5f, y / 2.5f, 95u);
        case 6: {
            float pw = 12.0f;
            float u = (pca_rem_euclid_f(x, pw) / pw - 0.5f) * 2.0f, v = (pca_rem_euclid_f(y, pw) / pw - 0.5f) * 2.0f;
            return pca_gfx_sqrt(fmax(1.0f - (u * u + v * v), 0.0f));
        }
        default: return 0.5f;
    }
}

/// Closest and second-closest jittered cell points: (d1, d2) and the closest point.
inline float2 pca_gfx_voronoi(float x, float y, float cell, uint seed, thread float2& p1) {
    int cx = pca_gfx_i32(floor(x / cell)), cy = pca_gfx_i32(floor(y / cell));
    float d1 = FLT_MAX, d2 = FLT_MAX;
    p1 = float2(x, y);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 q = pca_cell_point(cx + i, cy + j, cell, seed, float2(0.0f));
            float ex = q.x - x, ey = q.y - y;
            float d = pca_gfx_sqrt(ex * ex + ey * ey);
            if (d < d1) { d2 = d1; d1 = d; p1 = q; }
            else if (d < d2) { d2 = d; }
        }
    }
    return float2(d1, d2);
}

/// Brightens highlights (Film Grain / Smudge Stick).
inline float3 pca_gfx_highlights(float3 p, float l, float area, float intensity) {
    if (area <= 0.0f) return p;
    float m = pca_gfx_ss(1.0f - area / 20.0f * 0.75f, 1.02f, l) * (1.0f - intensity / 10.0f * 0.6f);
    return float3(p.x + (1.0f - p.x) * m, p.y + (1.0f - p.y) * m, p.z + (1.0f - p.z) * m);
}

/// Window-kernel prologue: false outside the window; `q` = document pixel.
inline bool pca_gfx_win_pixel(constant pca_gfx_params& p, uint2 gid, thread int2& q) {
    if (int(gid.x) >= p.win_size.x || int(gid.y) >= p.win_size.y) return false;
    q = p.win_origin + int2(gid);
    return true;
}

// ---------------------------------------------------------------- window load / write back

/// The working copy: sRGB of every source window pixel (gray-like → (g, g, g)).
kernel void pca_gfx_load(constant pca_frame& f [[buffer(0)]], constant pca_gfx_params& p [[buffer(1)]],
                         pca_in src [[texture(0)]], pca_out win [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_gfx_win_pixel(p, gid, q)) return;
    float4 v = pca_get(src, f, q);
    win.write(f.mode == 0u ? float4(v.x, v.x, v.x, 0.0f) : float4(v.xyz, 0.0f), gid);
}

/// photocraft `run`'s write back: the nearest window colour, clamped, in the native model; the
/// source alpha kept.
kernel void pca_gfx_out(constant pca_frame& f [[buffer(0)]], constant pca_gfx_params& p [[buffer(1)]],
                        pca_in src [[texture(0)]], pca_in win [[texture(1)]], pca_out dst [[texture(2)]],
                        uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float3 c = pca_gfx_at(win, p, q);
    float3 g = float3(pca_gfx_clamp01(c.x), pca_gfx_clamp01(c.y), pca_gfx_clamp01(c.z));
    float a = f.alpha != 0u ? pca_get(src, f, q).w : 0.0f;
    dst.write(f.mode == 0u ? float4(0.299f * g.x + 0.587f * g.y + 0.114f * g.z, 0.0f, 0.0f, a) : float4(g, a), gid);
}

// ---------------------------------------------------------------- planes: luma, steps, noise, Sobel

/// .x = luma of the window colour (i0 = 1: 1 − luma), or a step of a plane's .x (i0 = 2:
/// smoothstep(v0.x, v0.y, t.x)).
kernel void pca_gfx_plane(constant pca_frame& f [[buffer(0)]], constant pca_gfx_params& p [[buffer(1)]],
                          pca_in t [[texture(0)]], pca_out o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_gfx_win_pixel(p, gid, q)) return;
    float4 v = t.read(gid);
    float r;
    if (p.i0 == 2) r = pca_gfx_ss(p.v0.x, p.v0.y, v.x);
    else if (p.i0 == 1) r = 1.0f - pca_gfx_lum(v.xyz);
    else r = pca_gfx_lum(v.xyz);
    o.write(float4(r, 0.0f, 0.0f, 0.0f), gid);
}

/// Graphic Pen's noise plane: hash01(x, y, 0, 151).
kernel void pca_gfx_hash_plane(constant pca_frame& f [[buffer(0)]], constant pca_gfx_params& p [[buffer(1)]],
                               pca_out o [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_gfx_win_pixel(p, gid, q)) return;
    o.write(float4(pca_hash01(q.x, q.y, 0u, 151u), 0.0f, 0.0f, 0.0f), gid);
}

/// photocraft `sobel` / `grad_mag` of a plane's .x, edges clamped: (gx, gy, magnitude, 0).
kernel void pca_gfx_sobel(constant pca_frame& f [[buffer(0)]], constant pca_gfx_params& p [[buffer(1)]],
                          pca_in t [[texture(0)]], pca_out o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.win_size.x || y >= p.win_size.y) return;
    int2 hi = p.win_size - 1;
    float v[3][3];
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++) v[dy + 1][dx + 1] = t.read(uint2(clamp(int2(x + dx, y + dy), int2(0), hi))).x;
    float gx = ((v[0][2] + 2.0f * v[1][2] + v[2][2]) - (v[0][0] + 2.0f * v[1][0] + v[2][0])) / 8.0f;
    float gy = ((v[2][0] + 2.0f * v[2][1] + v[2][2]) - (v[0][0] + 2.0f * v[0][1] + v[0][2])) / 8.0f;
    o.write(float4(gx, gy, pca_gfx_sqrt(gx * gx + gy * gy), 0.0f), gid);
}

// ---------------------------------------------------------------- f64-faithful line / box blur

struct pca_gfx_line_params {
    int2 size;      // window size
    int2 d;         // direction (1,0), (0,1), (1,1) or (1,-1)
    int radius;
    int segment;    // elements per thread
    float norm_hi;  // 1 / (2r + 1) as a float-float (the CPU's f64 norm)
    float norm_lo;
    int lines;
    int pad0;
    int pad1;
    int pad2;
};

/// Start and length of line `l` along `d` (photocraft `line_blur`'s walk from each line start).
inline int3 pca_gfx_line(int l, int2 d, int2 size) {
    int w = size.x, h = size.y;
    if (d.x == 1 && d.y == 0) return int3(0, l, w);
    if (d.x == 0) return int3(l, 0, h);
    if (d.y == 1) {
        int2 s = l < h ? int2(0, l) : int2(l - h + 1, 0);
        return int3(s, min(w - s.x, h - s.y));
    }
    int2 s = l < h ? int2(0, l) : int2(l - h + 1, h - 1);
    return int3(s, min(w - s.x, s.y + 1));
}

/// Running mean of radius r along each line, ends clamped per line, sums in float-float so the
/// result equals the CPU's f64 `(acc · norm) as f32` (FxUtil box passes, artistic_fx `line_blur`).
kernel void pca_gfx_line_ff(constant pca_frame& f [[buffer(0)]], constant pca_gfx_line_params& p [[buffer(1)]],
                            pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int l = int(gid.x);
    if (l >= p.lines) return;
    int3 ln = pca_gfx_line(l, p.d, p.size);
    int m = ln.z;
    int a0 = int(gid.y) * p.segment;
    if (a0 >= m) return;
    int a1 = min(a0 + p.segment, m);
    int2 s = ln.xy;
    float4 hi = float4(0.0f), lo = float4(0.0f);
    for (int k = a0 - p.radius; k <= a0 + p.radius; k++) pca_gfx_ff_add(hi, lo, src.read(uint2(s + p.d * clamp(k, 0, m - 1))));
    float4 nh = float4(p.norm_hi), nl = float4(p.norm_lo);
    for (int a = a0; a < a1; a++) {
        float4 ph = hi * nh;
        float4 pl = fma(hi, nh, -ph);
        float4 t = hi * nl;
        t = t + lo * nh;
        pl = pl + t;
        dst.write(ph + pl, uint2(s + p.d * a));
        pca_gfx_ff_add(hi, lo, src.read(uint2(s + p.d * clamp(a + p.radius + 1, 0, m - 1))));
        pca_gfx_ff_add(hi, lo, -src.read(uint2(s + p.d * clamp(a - p.radius, 0, m - 1))));
    }
}

// ---------------------------------------------------------------- Kuwahara, unsharp

/// Kuwahara inputs: (r, g, b, l) and (l², 0, 0, 0).
kernel void pca_gfx_kuwa_prep(constant pca_frame& f [[buffer(0)]], constant pca_gfx_params& p [[buffer(1)]],
                              pca_in c [[texture(0)]], pca_out m1 [[texture(1)]], pca_out m2 [[texture(2)]],
                              uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_gfx_win_pixel(p, gid, q)) return;
    float3 v = c.read(gid).xyz;
    float l = pca_gfx_lum(v);
    m1.write(float4(v, l), gid);
    m2.write(float4(l * l, 0.0f, 0.0f, 0.0f), gid);
}

/// The flattest of the four quadrant means at offsets ±i0 (box-blurred m1 / m2).
kernel void pca_gfx_kuwa_select(constant pca_frame& f [[buffer(0)]], constant pca_gfx_params& p [[buffer(1)]],
                                pca_in m1 [[texture(0)]], pca_in m2 [[texture(1)]], pca_out o [[texture(2)]],
                                uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.win_size.x || y >= p.win_size.y) return;
    int off = p.i0;
    int2 hi = p.win_size - 1;
    int2 ds[4] = {int2(-off, -off), int2(off, -off), int2(-off, off), int2(off, off)};
    float best = FLT_MAX;
    float3 col = float3(0.0f);
    for (int k = 0; k < 4; k++) {
        uint2 qq = uint2(clamp(int2(x, y) + ds[k], int2(0), hi));
        float4 a = m1.read(qq);
        float var = m2.read(qq).x - a.w * a.w;
        if (var < best) { best = var; col = a.xyz; }
    }
    o.write(float4(col, 0.0f), gid);
}

/// p + (p − blurred) · v0.x.
kernel void pca_gfx_unsharp(constant pca_frame& f [[buffer(0)]], constant pca_gfx_params& p [[buffer(1)]],
                            pca_in c [[texture(0)]], pca_in b [[texture(1)]], pca_out o [[texture(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_gfx_win_pixel(p, gid, q)) return;
    float3 v = c.read(gid).xyz, u = b.read(gid).xyz;
    float k = p.v0.x;
    o.write(float4(v.x + (v.x - u.x) * k, v.y + (v.y - u.y) * k, v.z + (v.z - u.z) * k, 0.0f), gid);
}

/// a · (1 − t) + b · t blend of two windows (Crosshatch): mix(a, b, v0.x).
kernel void pca_gfx_blend(constant pca_frame& f [[buffer(0)]], constant pca_gfx_params& p [[buffer(1)]],
                          pca_in a [[texture(0)]], pca_in b [[texture(1)]], pca_out o [[texture(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_gfx_win_pixel(p, gid, q)) return;
    o.write(float4(pca_gfx_mix(a.read(gid).xyz, b.read(gid).xyz, p.v0.x), 0.0f), gid);
}

/// Texturizer core (`texturize_by`): relief shading with a procedural texture; i1 = weight mode
/// (0: 1, 1: Rough Pastels' 0.15 + 0.85 (1 − lum)). v0 = (s, k, sign, 0), v1.xy = light, i0 = kind.
kernel void pca_gfx_texturize(constant pca_frame& f [[buffer(0)]], constant pca_gfx_params& p [[buffer(1)]],
                              pca_in c [[texture(0)]], pca_out o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_gfx_win_pixel(p, gid, q)) return;
    float3 v = c.read(gid).xyz;
    float s = p.v0.x, k = p.v0.y, sign = p.v0.z;
    float fx = float(q.x), fy = float(q.y);
    float gx = (pca_gfx_texture(p.i0, fx + 1.0f, fy, s) - pca_gfx_texture(p.i0, fx - 1.0f, fy, s)) * 0.5f * sign;
    float gy = (pca_gfx_texture(p.i0, fx, fy + 1.0f, s) - pca_gfx_texture(p.i0, fx, fy - 1.0f, s)) * 0.5f * sign;
    float wgt = p.i1 == 1 ? 0.15f + 0.85f * (1.0f - pca_gfx_clamp01(pca_gfx_lum(v))) : 1.0f;
    float fct = 1.0f + (clamp(pca_gfx_shade(gx, gy, p.v1.xy, k), 0.0f, 2.0f) - 1.0f) * wgt;
    o.write(float4(v * fct, 0.0f), gid);
}
