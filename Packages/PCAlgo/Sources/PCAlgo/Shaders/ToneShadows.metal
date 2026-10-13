// Port of photocraft-algo (crates/algo/src/tone/shadows_highlights.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Image › Adjustments › Shadows/Highlights: brightness, the bilateral-grid neighbourhood (gather
// per cell in the CPU's summation order, two levels per pass, interpolation accumulated level by
// level), the new luma, the Black/White Clip histogram and search, and the colour step.

/// Brightness: (max channel + Rec. 601 luma) / 2 of the RGBA texture, into .x.
kernel void pca_tone_sh_lum(constant pca_frame& f [[buffer(0)]], constant pca_tone_rect_params& p [[buffer(1)]],
                            pca_in rgba [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    float4 c = rgba.read(gid);
    float v = (fmax(fmax(c.x, c.y), c.z) + pca_tone_luma(c.xyz)) / 2.0f;
    dst.write(float4(v, 0.0f, 0.0f, 0.0f), gid);
}

struct pca_tone_sh_grid_params {
    int w;
    int h;
    int d;
    int rw;
    int rh;
    int level0;
    int levels;
    int pad0;
    float step;
    float range;
    float t_max;
    float pad1;
};

/// The neighbourhood is the guide itself (σ < 0.3): guide.x into the buffer.
kernel void pca_tone_sh_copy_x(constant pca_frame& f [[buffer(0)]], constant pca_tone_sh_grid_params& p [[buffer(1)]],
                               device float* nb [[buffer(2)]], pca_in guide [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.w || int(gid.y) >= p.h) return;
    nb[gid.y * uint(p.w) + gid.x] = guide.read(gid).x;
}

/// Grid cell sums of levels level0 and level0 + 1: (Σ w·l, Σ w, Σ w·l, Σ w), pixels in row-major
/// order like photocraft's scatter.
kernel void pca_tone_sh_grid(constant pca_frame& f [[buffer(0)]], constant pca_tone_sh_grid_params& p [[buffer(1)]],
                             pca_in lum [[texture(0)]], pca_out grid [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.rw || int(gid.y) >= p.rh) return;
    int cx = int(gid.x), cy = int(gid.y);
    int ye = min(cy * p.d + p.d, p.h), xe = min(cx * p.d + p.d, p.w);
    bool two = p.level0 + 1 < p.levels;
    float g0 = float(p.level0) * p.step, g1 = float(p.level0 + 1) * p.step;
    float n0 = 0.0f, d0 = 0.0f, n1 = 0.0f, d1 = 0.0f;
    for (int y = cy * p.d; y < ye; y++) {
        for (int x = cx * p.d; x < xe; x++) {
            float l = lum.read(uint2(x, y)).x;
            float w0 = fmax(1.0f - fabs(l - g0) / p.range, 0.0f);
            n0 += w0 * l;
            d0 += w0;
            if (two) {
                float w1 = fmax(1.0f - fabs(l - g1) / p.range, 0.0f);
                n1 += w1 * l;
                d1 += w1;
            }
        }
    }
    grid.write(float4(n0, d0, n1, d1), gid);
}

/// Adds the two blurred levels' share of every pixel's interpolated neighbourhood:
/// at(k)·(1 − f) where the pixel's level k is one of them, + at(k + 1)·f where k + 1 is.
kernel void pca_tone_sh_accum(constant pca_frame& f [[buffer(0)]], constant pca_tone_sh_grid_params& p [[buffer(1)]],
                              device float* nb [[buffer(2)]], pca_in guide [[texture(0)]], pca_in grid [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.w || int(gid.y) >= p.h) return;
    float t = fmin(clamp(guide.read(gid).x, 0.0f, 1.0f) / p.step, p.t_max);
    int k = int(floor(t));
    float fr = t - float(k);
    int l0 = p.level0, l1 = p.level0 + 1;
    bool hit0 = k == l0 || k + 1 == l0;
    bool hit1 = l1 < p.levels && (k == l1 || k + 1 == l1);
    if (!hit0 && !hit1) return;
    float fy = clamp((float(gid.y) + 0.5f) / float(p.d) - 0.5f, 0.0f, float(p.rh - 1));
    int y0 = int(floor(fy));
    float ty = fy - trunc(fy);
    int y1 = min(y0 + 1, p.rh - 1);
    float fx = clamp((float(gid.x) + 0.5f) / float(p.d) - 0.5f, 0.0f, float(p.rw - 1));
    int x0 = int(floor(fx));
    float tx = fx - trunc(fx);
    int x1 = min(x0 + 1, p.rw - 1);
    float4 b00 = grid.read(uint2(x0, y0)), b01 = grid.read(uint2(x1, y0));
    float4 b10 = grid.read(uint2(x0, y1)), b11 = grid.read(uint2(x1, y1));
    uint i = gid.y * uint(p.w) + gid.x;
    for (int j = 0; j < 2; j++) {
        int lv = p.level0 + j;
        if (lv >= p.levels) break;
        if (k != lv && k + 1 != lv) continue;
        float g = float(lv) * p.step;
        float a00 = b00[2 * j + 1] > 1e-6f ? b00[2 * j] / b00[2 * j + 1] : g;
        float a01 = b01[2 * j + 1] > 1e-6f ? b01[2 * j] / b01[2 * j + 1] : g;
        float a10 = b10[2 * j + 1] > 1e-6f ? b10[2 * j] / b10[2 * j + 1] : g;
        float a11 = b11[2 * j + 1] > 1e-6f ? b11[2 * j] / b11[2 * j + 1] : g;
        float top = a00 + (a01 - a00) * tx;
        float bot = a10 + (a11 - a10) * tx;
        float at = top + (bot - top) * ty;
        if (k == lv) nb[i] = at * (1.0f - fr);
        else nb[i] = nb[i] + at * fr;
    }
}

struct pca_tone_sh_y2_params {
    int width;
    int height;
    uint has_s;
    uint has_h;
    float ss;
    float hs;
    float midtone;
    float mk;
    float mp;
    float pad0;
    float pad1;
    float pad2;
};

/// photocraft `lift`: 1 − ((1 − t)·c^(2^n) + t·c^(2^(n+1))), c = 1 − v.
inline float pca_tone_sh_lift(float s, float v) {
    float fl = floor(s);
    int n = isnan(fl) ? 0 : int(clamp(fl, 0.0f, 2.0f));
    float t = clamp(s - float(n), 0.0f, 1.0f);
    float c = clamp(1.0f - v, 0.0f, 1.0f);
    float lo = c;
    for (int i = 0; i < n; i++) lo = lo * lo;
    float hi = lo * lo;
    return 1.0f - ((1.0f - t) * lo + t * hi);
}

inline int pca_tone_sh_level(float v) {
    return int(round(clamp(v, 0.0f, 1.0f) * 255.0f));
}

/// The new luma of every pixel (shadows lift, highlights darken, midtone curve).
kernel void pca_tone_sh_y2(constant pca_frame& f [[buffer(0)]], constant pca_tone_sh_y2_params& p [[buffer(1)]],
                           device const float* nbs [[buffer(2)]], device const float* nbh [[buffer(3)]],
                           constant float* ms [[buffer(4)]], constant float* mh [[buffer(5)]], device float* y2 [[buffer(6)]],
                           pca_in rgba [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.width || int(gid.y) >= p.height) return;
    uint i = gid.y * uint(p.width) + gid.x;
    float3 o = rgba.read(gid).xyz;
    float3 adj = o;
    if (p.has_s != 0u) {
        float m = ms[pca_tone_sh_level(nbs[i])];
        for (int c = 0; c < 3; c++) adj[c] += m * (pca_tone_sh_lift(p.ss, adj[c]) - adj[c]);
    }
    if (p.has_h != 0u) {
        float m = mh[255 - pca_tone_sh_level(nbh[i])];
        for (int c = 0; c < 3; c++) adj[c] -= m * (pca_tone_sh_lift(p.hs, 1.0f - o[c]) - (1.0f - o[c]));
    }
    float y = clamp(pca_tone_luma(adj), 0.0f, 1.0f);
    if (p.midtone != 0.0f) y = clamp(y + p.mk * (y - 0.5f) * pow(fmax(4.0f * y * (1.0f - y), 0.0f), p.mp), 0.0f, 1.0f);
    y2[i] = y;
}

/// 4096-bin histogram of the new luma over opaque pixels (bin 4096: the count), threadgroup-local
/// then merged; integer counts, so exact.
kernel void pca_tone_sh_hist(constant pca_frame& f [[buffer(0)]], constant pca_tone_hist_params& p [[buffer(1)]],
                             device const float* y2 [[buffer(2)]], device atomic_uint* hist [[buffer(3)]],
                             pca_in rgba [[texture(0)]], uint gid [[thread_position_in_grid]], uint tid [[thread_index_in_threadgroup]]) {
    threadgroup atomic_uint local[4097];
    for (uint i = tid; i < 4097u; i += 256u) atomic_store_explicit(&local[i], 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint n = 0u;
    for (uint i = gid; i < p.count; i += p.total) {
        uint2 xy = uint2(i % uint(p.width), i / uint(p.width));
        if (rgba.read(xy).w > 0.0f) {
            uint bin = uint(round(clamp(y2[i], 0.0f, 1.0f) * 4095.0f));
            atomic_fetch_add_explicit(&local[bin], 1u, memory_order_relaxed);
            n++;
        }
    }
    if (n > 0u) atomic_fetch_add_explicit(&local[4096], n, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint i = tid; i < 4097u; i += 256u) {
        uint v = atomic_load_explicit(&local[i], memory_order_relaxed);
        if (v > 0u) atomic_fetch_add_explicit(&hist[i], v, memory_order_relaxed);
    }
}

struct pca_tone_sh_clip_params {
    float black;
    float white;
    float pad0;
    float pad1;
};

inline float pca_tone_sh_find(device const uint* hist, uint n, float pct, bool rev) {
    uint target = uint(clamp(pct, 0.0f, 50.0f) / 100.0f * float(n));
    uint acc = 0u;
    for (int k = 0; k < 4096; k++) {
        int i = rev ? 4095 - k : k;
        acc += hist[i];
        if (acc > target) return float(i) / 4095.0f;
    }
    return rev ? 0.0f : 1.0f;
}

/// Black and White Clip points (photocraft `clip_levels`): lohi = (lo, hi, stretch?).
kernel void pca_tone_sh_clip_find(constant pca_frame& f [[buffer(0)]], constant pca_tone_sh_clip_params& p [[buffer(1)]],
                                  device const uint* hist [[buffer(2)]], device float* lohi [[buffer(3)]],
                                  uint gid [[thread_position_in_grid]]) {
    if (gid != 0u) return;
    uint n = hist[4096];
    if (n == 0u) { lohi[2] = 0.0f; return; }
    float lo = p.black > 0.0f ? pca_tone_sh_find(hist, n, p.black, false) : 0.0f;
    float hi = p.white > 0.0f ? pca_tone_sh_find(hist, n, p.white, true) : 1.0f;
    lohi[0] = lo;
    lohi[1] = hi;
    lohi[2] = hi - lo < 1e-3f ? 0.0f : 1.0f;
}

struct pca_tone_sh_final_params {
    int2 origin;
    int2 size;
    float gain_h;
    uint gain_up;
    uint clip;
    uint pad0;
};

/// The colour step: the new luma plus the pixel's colour differences, scaled by the Color gain and
/// shortened to stay in 0–1; converted back to the plane's model.
kernel void pca_tone_sh_final(constant pca_frame& f [[buffer(0)]], constant pca_tone_sh_final_params& p [[buffer(1)]],
                              device const float* y2 [[buffer(2)]], device const float* lohi [[buffer(3)]],
                              pca_in src [[texture(0)]], pca_in rgba [[texture(1)]], pca_out dst [[texture(2)]],
                              uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q);
    int2 r = q - p.origin;
    if (r.x < 0 || r.y < 0 || r.x >= p.size.x || r.y >= p.size.y) { dst.write(v, gid); return; }
    float4 c4 = rgba.read(uint2(r));
    if (c4.w > 0.0f) {
        float yn = y2[uint(r.y) * uint(p.size.x) + uint(r.x)];
        if (p.clip != 0u && lohi[2] != 0.0f) {
            float lo = lohi[0], hi = lohi[1];
            yn = clamp((yn - lo) / (hi - lo), 0.0f, 1.0f);
        }
        float3 c = c4.xyz;
        float y1 = pca_tone_luma(c);
        float fr = fabs(yn - y1) / fmax(fmax(yn, y1), 1e-6f);
        float g = p.gain_up != 0u ? exp(p.gain_h * fr) : 1.0f + p.gain_h * fr;
        float3 d = float3((c.x - y1) * g, (c.y - y1) * g, (c.z - y1) * g);
        float k = 1.0f;
        for (int i = 0; i < 3; i++) {
            float dv = d[i];
            if (dv > 1e-9f) k = fmin(k, (1.0f - yn) / dv);
            else if (dv < -1e-9f) k = fmin(k, yn / -dv);
        }
        k = clamp(k, 0.0f, 1.0f);
        c4.xyz = float3(clamp(yn + k * d.x, 0.0f, 1.0f), clamp(yn + k * d.y, 0.0f, 1.0f), clamp(yn + k * d.z, 0.0f, 1.0f));
    }
    dst.write(pca_tone_from_rgba_px(v, c4, f), gid);
}
