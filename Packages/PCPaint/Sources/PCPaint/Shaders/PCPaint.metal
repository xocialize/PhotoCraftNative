// Port of photocraft-paint (crates/paint/src/render.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Metal dab renderer: the per-pixel half of `BrushContext.rasterizeInto` + `CoverageMap.accumulate`
// (pcp_accumulate) and of `StrokeCompositor.composite` (pcp_composite). Everything per dab (trig,
// grid snapping, mip level, rectangle) is computed on the CPU exactly as the CPU reference does and
// passed in `PcpDab`; the kernels repeat the reference's per-pixel arithmetic operation for
// operation. The library is compiled with `#pragma METAL fp contract(off)` ahead of everything and
// these kernels use `precise::sqrt`, so with Metal's correctly-rounded division the GPU result is
// bit-identical to the CPU reference (see PORT-NOTES.md for the measured parity).
//
// Buffer-backed r32Float tiles: a stroke's coverage lives in 64×64 float tiles pooled in one
// shared MTLBuffer per plane (coverage, wet-edge depth, per-dab colour, dual-brush coverage); only
// touched tiles exist (stroke-local tile storage, an idea from Compositor v1.5, MIT © 2026 Wonder
// Assembly LLC). Each accumulate thread owns one pixel of one tile and walks the tile's dab bin in
// stroke order, so build-up is ordered and race-free without atomics.

#define PCP_TILE 64
#define PCP_TILE_PIXELS 4096u
#define PCP_STAGE 256
#define PCP_STAGE_PIXELS 65536u

#define PCP_DAB_PROJ 1u
#define PCP_DAB_SMALL 2u

struct PcpDab {
    float cx, cy;
    float r, ro, rm, reach2, smallReach2;
    float sn, cs, fx, fy;
    float pax, pay, pk;
    float alpha, ceilv, texDepth;
    float invScale, tw, th;
    uint level, flags;
    int x0, y0, x1, y1;
    float col[4];
};

struct PcpRaster {
    float hardness;
    uint aliased, square, noise, texTip, wantDepth, wantCol, sampled;
    uint nc, texMode, patW, patH;
    float texScale;
    uint jobCount;
    uint pad0, pad1;
};

struct PcpJob {
    uint slot;
    int tx, ty;
    uint binStart, binCount;
    uint pad0, pad1, pad2;
};

// Rust `f32::clamp`: NaN passes through.
inline float pcp_clamp(float v, float lo, float hi) {
    float x = v;
    if (x < lo) x = lo;
    if (x > hi) x = hi;
    return x;
}

inline int pcp_rem(int a, int b) {
    int r = a % b;
    return r < 0 ? r + abs(b) : r;
}

inline long pcp_reml(long a, long b) {
    long r = a % b;
    return r < 0 ? r + (b < 0 ? -b : b) : r;
}

inline ulong pcp_mix64(ulong z) {
    z += 0x9E3779B97F4A7C15ul;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ul;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBul;
    return z ^ (z >> 31);
}

inline float pcp_hash2(int x, int y, ulong salt) {
    ulong k = (ulong(uint(x)) << 32) | ulong(uint(y));
    return float(pcp_mix64(k ^ (salt * 0xA24BAED4963EE407ul)) >> 40) / 16777216.0f;
}

constant ulong PCP_NOISE_SALT = 0x006E6F697365ul;
constant ulong PCP_DITHER_SALT = 0x0000646974686572ul;

inline float pcp_tip_falloff(float d, float radius, float hardness) {
    float inner = radius * pcp_clamp(hardness, 0.0f, 1.0f);
    if (d <= inner || radius - inner < 1e-3f) return 1.0f;
    float t = pcp_clamp((d - inner) / (radius - inner), 0.0f, 1.0f);
    float s = 1.0f - t * t;
    float s2 = s * s;
    return s2 * s2;
}

inline float pcp_dab_coverage(float d, float radius, float hardness) {
    if (d >= radius + 0.5f) return 0.0f;
    float edge = fmin(pcp_clamp(radius + 0.5f - d, 0.0f, 1.0f), 1.0f);
    return edge * pcp_tip_falloff(d, radius, hardness);
}

inline float pcp_smoothstep(float e0, float e1, float x) {
    float t = pcp_clamp((x - e0) / (e1 - e0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

inline float pcp_wet_factor(float rn) { return 0.5f + 0.5f * pcp_smoothstep(0.5f, 1.0f, rn); }

// MaskMode raw order: multiply, subtract, darken, overlay, colorDodge, colorBurn, linearBurn,
// hardMix, linearHeight, height.
inline float pcp_mask_combine(uint mode, float v, float t, float d) {
    if (v <= 0.0f) return 0.0f;
    float r;
    switch (mode) {
        case 0: r = v * (1.0f - d + d * t); break;
        case 1: r = fmax(v - d * (1.0f - t), 0.0f); break;
        case 2: r = fmin(v, 1.0f - d + d * t); break;
        case 3: {
            float o = v < 0.5f ? 2.0f * v * t : 1.0f - 2.0f * (1.0f - v) * (1.0f - t);
            r = v + (o - v) * d;
            break;
        }
        case 4: { float o = fmin(v / fmax(1.0f - t, 1e-3f), 1.0f); r = v + (o - v) * d; break; }
        case 5: { float o = 1.0f - fmin((1.0f - v) / fmax(t, 1e-3f), 1.0f); r = v + (o - v) * d; break; }
        case 6: { float o = fmax(v + t - 1.0f, 0.0f); r = v + (o - v) * d; break; }
        case 7: { float o = v + t > 1.0f ? 1.0f : 0.0f; r = v + (o - v) * d; break; }
        case 8: r = v * pcp_clamp((t - (1.0f - d * v)) * 4.0f + 0.5f, 0.0f, 1.0f); break;
        default: r = t >= 1.0f - d * v ? v : 0.0f; break;
    }
    return pcp_clamp(r, 0.0f, 1.0f);
}

inline float pcp_texture_combine(uint mode, float v, float t, float d) {
    if (v <= 0.0f) return 0.0f;
    float r;
    switch (mode) {
        case 1: r = v - d * t; break;
        case 4: r = v / fmax(1.0f - d * t, 1e-3f); break;
        case 5: r = 1.0f - (1.0f - v) / fmax(1.0f - d + d * t, 1e-3f); break;
        case 9: r = 12.0f * round(d * 255.0f) / 255.0f * v - t; break;
        case 8: {
            float reach = 12.0f * round(d * 255.0f) / 255.0f * v;
            r = reach < 1.0f ? reach * (1.0f - t) : reach - t;
            break;
        }
        default: r = pcp_mask_combine(mode, v, t, d); break;
    }
    return isfinite(r) ? pcp_clamp(r, 0.0f, 1.0f) : 0.0f;
}

inline float pcp_sample_wrap(device const float *p, int w, int h, float x, float y) {
    long xi = pcp_reml(long(floor(x)), long(w));
    long yi = pcp_reml(long(floor(y)), long(h));
    return p[yi * long(w) + xi];
}

inline float pcp_texture_at(device const float *p, int w, int h, float s, int x, int y) {
    if (s == 1.0f) return p[pcp_rem(y, h) * w + pcp_rem(x, w)];
    float fx = (float(x) + 0.5f) / s - 0.5f, fy = (float(y) + 0.5f) / s - 0.5f;
    float x0 = floor(fx), y0 = floor(fy);
    float tx = fx - x0, ty = fy - y0;
    float a = pcp_sample_wrap(p, w, h, x0, y0) + (pcp_sample_wrap(p, w, h, x0 + 1.0f, y0) - pcp_sample_wrap(p, w, h, x0, y0)) * tx;
    float b = pcp_sample_wrap(p, w, h, x0, y0 + 1.0f) + (pcp_sample_wrap(p, w, h, x0 + 1.0f, y0 + 1.0f) - pcp_sample_wrap(p, w, h, x0, y0 + 1.0f)) * tx;
    return a + (b - a) * ty;
}

inline float pcp_mip_get(device const float *m, uint off, int w, int h, int x, int y) {
    return (x < 0 || y < 0 || x >= w || y >= h) ? 0.0f : m[off + uint(y * w + x)];
}

inline float pcp_mip_sample(device const float *m, uint4 lv, float u, float v) {
    int w = int(lv.y), h = int(lv.z);
    float fx = u * float(w) - 0.5f;
    float fy = v * float(h) - 0.5f;
    float x0f = floor(fx), y0f = floor(fy);
    float tx = fx - x0f, ty = fy - y0f;
    int x0 = int(x0f), y0 = int(y0f);
    float a = pcp_mip_get(m, lv.x, w, h, x0, y0) + (pcp_mip_get(m, lv.x, w, h, x0 + 1, y0) - pcp_mip_get(m, lv.x, w, h, x0, y0)) * tx;
    float b = pcp_mip_get(m, lv.x, w, h, x0, y0 + 1) + (pcp_mip_get(m, lv.x, w, h, x0 + 1, y0 + 1) - pcp_mip_get(m, lv.x, w, h, x0, y0 + 1)) * tx;
    return a + (b - a) * ty;
}

inline float2 pcp_to_tip_d(device const PcpDab &d, float dx, float dy) {
    float ux = dx, uy = -dy;
    if ((d.flags & PCP_DAB_PROJ) != 0u) {
        float t = (ux * d.pax + uy * d.pay) * d.pk;
        ux += t * d.pax;
        uy += t * d.pay;
    }
    return float2((ux * d.cs + uy * d.sn) * d.fx, (-ux * d.sn + uy * d.cs) * d.fy);
}

constant float PCP_SUB[4] = {-0.375f, -0.125f, 0.125f, 0.375f};

/// Accumulate a batch of dabs into the stroke's coverage tiles. Grid: (4096, jobs); one thread per
/// pixel of a job's tile, walking the tile's dab bin in stroke order.
kernel void pcp_accumulate(device float *cov [[buffer(0)]],
                           device float *depth [[buffer(1)]],
                           device float *col [[buffer(2)]],
                           device const PcpDab *dabs [[buffer(3)]],
                           device const uint *bins [[buffer(4)]],
                           device const PcpJob *jobs [[buffer(5)]],
                           constant PcpRaster &u [[buffer(6)]],
                           device const float *mips [[buffer(7)]],
                           device const uint4 *mipLevels [[buffer(8)]],
                           device const float *pattern [[buffer(9)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.y >= u.jobCount) return;
    PcpJob job = jobs[gid.y];
    int lx = int(gid.x & 63u), ly = int(gid.x >> 6);
    int x = job.tx * PCP_TILE + lx, y = job.ty * PCP_TILE + ly;
    uint idx = job.slot * PCP_TILE_PIXELS + uint(ly * PCP_TILE + lx);
    float c = cov[idx];
    float dep = u.wantDepth != 0u ? depth[idx] : 0.0f;
    float pc[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    uint nc = u.wantCol != 0u ? u.nc : 0u;
    for (uint k = 0; k < nc; ++k) pc[k] = col[idx * nc + k];
    for (uint b = 0; b < job.binCount; ++b) {
        device const PcpDab &d = dabs[bins[job.binStart + b]];
        if (x < d.x0 || x >= d.x1 || y < d.y0 || y >= d.y1) continue;
        float dy = float(y) + 0.5f - d.cy;
        float dx = float(x) + 0.5f - d.cx;
        float2 uv = pcp_to_tip_d(d, dx, dy);
        float uu = uv.x, vv = uv.y;
        float val, rn;
        if (u.square != 0u) {
            if (fabs(dx) >= d.r || fabs(dy) >= d.r) continue;
            val = 1.0f; rn = 0.0f;
        } else if (u.sampled != 0u) {
            float px = uu * d.invScale + d.tw / 2.0f, py = -(vv / d.ro) * d.invScale + d.th / 2.0f;
            if (px < -1.0f || py < -1.0f || px > d.tw + 1.0f || py > d.th + 1.0f) continue;
            float s = pcp_mip_sample(mips, mipLevels[d.level], px / d.tw, py / d.th);
            val = u.aliased != 0u ? (s >= 0.5f ? 1.0f : 0.0f) : s;
            rn = 1.0f - s;
        } else if ((d.flags & PCP_DAB_SMALL) != 0u) {
            float d2 = (uu * d.ro) * (uu * d.ro) + vv * vv;
            if (d2 >= d.smallReach2) continue;
            float sum = 0.0f;
            for (int sy = 0; sy < 4; ++sy) {
                for (int sx = 0; sx < 4; ++sx) {
                    float2 s2 = pcp_to_tip_d(d, dx + PCP_SUB[sx], dy + PCP_SUB[sy]);
                    float sd = precise::sqrt((s2.x * d.ro) * (s2.x * d.ro) + s2.y * s2.y);
                    float inside = pcp_clamp((d.rm - sd) * 4.0f + 0.5f, 0.0f, 1.0f);
                    if (inside > 0.0f) sum += inside * pcp_tip_falloff(fmin(sd, d.rm), d.rm, u.hardness);
                }
            }
            val = sum / 16.0f;
            rn = precise::sqrt(d2) / d.rm;
        } else {
            float d2 = (uu * d.ro) * (uu * d.ro) + vv * vv;
            if (d2 >= d.reach2) continue;
            float dd = precise::sqrt(d2);
            val = u.aliased != 0u ? (dd <= d.rm ? 1.0f : 0.0f) : pcp_dab_coverage(dd, d.rm, u.hardness);
            rn = dd / d.rm;
        }
        if (val <= 0.0f) continue;
        if (u.noise != 0u && val < 1.0f) {
            float n = pcp_hash2(x, y, PCP_NOISE_SALT);
            float hard = n < val ? 1.0f : 0.0f;
            val += (hard - val) * 0.7f;
        }
        if (u.texTip != 0u) val = pcp_texture_combine(u.texMode, val, pcp_texture_at(pattern, int(u.patW), int(u.patH), u.texScale, x, y), d.texDepth);
        float v = val * d.alpha;
        // CoverageMap.accumulate.
        if (v <= 0.0f) continue;
        if (u.wantDepth != 0u) dep = fmax(dep, pcp_clamp(1.0f - rn, 0.0f, 1.0f));
        float nv = d.ceilv > c ? c + v * (d.ceilv - c) : c;
        if (nv <= c) continue;
        if (nc > 0u) {
            float kk = c < 1.0f ? (nv - c) / (1.0f - c) : 0.0f;
            for (uint k = 0; k < nc; ++k) pc[k] = d.col[k] * kk + pc[k] * (1.0f - kk);
        }
        c = nv;
    }
    cov[idx] = c;
    if (u.wantDepth != 0u) depth[idx] = dep;
    for (uint k = 0; k < nc; ++k) col[idx * nc + k] = pc[k];
}

// ---------------------------------------------------------------------------------------------
// Composite

struct PcpComp {
    uint sample;       // 0 u8, 1 u16, 2 f32
    uint channels;
    uint alphaIdx;     // 0xFFFFFFFF without alpha
    uint nc;
    uint mode;         // BlendMode raw value
    uint flags;
    float opacity;
    uint seedLo, seedHi;
    uint dualMode, texMode;
    float texDepth, texScale;
    int patW, patH;
    uint jobCount;
    float src[8];
    uint passes;
    uint pad0, pad1, pad2;
};

#define PCP_C_ERASE 1u
#define PCP_C_LOCK 2u
#define PCP_C_DITHER 4u
#define PCP_C_DISSOLVE 8u
#define PCP_C_PERDAB 16u
#define PCP_C_WET 32u
#define PCP_C_DUAL 64u
#define PCP_C_TEXTURE 128u
#define PCP_C_SELECTION 256u
#define PCP_C_NORMAL 512u
#define PCP_C_GRAY 1024u

struct PcpCJob {
    int covSlots[4];      // per symmetry pass; -1: the pass has no tile here
    int dualSlots[4];
    uint stage;
    int tx, ty;            // coverage tile
    int stx, sty;          // staging (surface) tile
    int x0, y0, x1, y1;    // clip rectangle (tile ∩ stroke bounds)
    uint pad;
};

inline float pcp_read_px(device const uchar *p8, device const ushort *p16, device const float *p32, uint sample, uint i) {
    if (sample == 0u) return float(p8[i]) / 255.0f;
    if (sample == 1u) return float(p16[i]) / 65535.0f;
    return p32[i];
}

inline void pcp_write_px(device uchar *p8, device ushort *p16, device float *p32, uint sample, uint i, float v) {
    if (sample == 0u) p8[i] = uchar(clamp(v, 0.0f, 1.0f) * 255.0f + 0.5f);
    else if (sample == 1u) p16[i] = ushort(clamp(v, 0.0f, 1.0f) * 65535.0f + 0.5f);
    else p32[i] = v;
}

inline float4 pcp_to_rgba(thread const float *px, uint gray, uint a) {
    float al = a != 0xFFFFFFFFu ? px[a] : 1.0f;
    return gray != 0u ? float4(px[0], px[0], px[0], al) : float4(px[0], px[1], px[2], al);
}

/// Composite the stroke buffer over the pre-stroke pixels staged per 256² surface tile. Grid:
/// (4096, jobs); one thread per pixel of a coverage tile, in place in the staging buffer.
kernel void pcp_composite(device uchar *p8 [[buffer(0)]],
                          device ushort *p16 [[buffer(1)]],
                          device float *p32 [[buffer(2)]],
                          device const float *cov [[buffer(3)]],
                          device const float *depth [[buffer(4)]],
                          device const float *col [[buffer(5)]],
                          device const float *dualCov [[buffer(6)]],
                          device const PcpCJob *jobs [[buffer(7)]],
                          device const float *sel [[buffer(8)]],
                          constant PcpComp &u [[buffer(9)]],
                          device const float *pattern [[buffer(10)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.y >= u.jobCount) return;
    PcpCJob job = jobs[gid.y];
    int lx = int(gid.x & 63u), ly = int(gid.x >> 6);
    int x = job.tx * PCP_TILE + lx, y = job.ty * PCP_TILE + ly;
    if (x < job.x0 || x >= job.x1 || y < job.y0 || y >= job.y1) return;
    uint local = uint(ly * PCP_TILE + lx);
    bool wet = (u.flags & PCP_C_WET) != 0u;
    // Symmetry passes merge as CoverageMap.unionMax does, in pass order: the first pass with a tile
    // is taken whole; later passes win where their coverage is greater (with their colour), and
    // the wet-edge depth keeps the deepest.
    float c = 0.0f, dep = 0.0f;
    uint ti = 0u;
    bool any = false;
    for (uint p = 0; p < u.passes; ++p) {
        int s = job.covSlots[p];
        if (s < 0) continue;
        uint pi = uint(s) * PCP_TILE_PIXELS + local;
        float cp = cov[pi];
        if (!any) {
            any = true; c = cp; ti = pi;
            if (wet) dep = depth[pi];
        } else {
            if (cp > c) { c = cp; ti = pi; }
            if (wet) dep = fmax(dep, depth[pi]);
        }
    }
    if (!any || c <= 0.0f) return;
    float m = c;
    if (wet) m = c * pcp_wet_factor(1.0f - dep);
    if ((u.flags & PCP_C_DUAL) != 0u) {
        float dv = 0.0f;
        bool dany = false;
        for (uint p = 0; p < u.passes; ++p) {
            int s = job.dualSlots[p];
            if (s < 0) continue;
            float v = dualCov[uint(s) * PCP_TILE_PIXELS + local];
            if (!dany) { dany = true; dv = v; } else if (v > dv) { dv = v; }
        }
        m = pcp_mask_combine(u.dualMode, m, dv, 1.0f);
    }
    if ((u.flags & PCP_C_TEXTURE) != 0u) m = pcp_texture_combine(u.texMode, m, pcp_texture_at(pattern, u.patW, u.patH, u.texScale, x, y), u.texDepth);
    uint sp = job.stage * PCP_STAGE_PIXELS + uint((y - job.sty * PCP_STAGE) * PCP_STAGE + (x - job.stx * PCP_STAGE));
    float s = (u.flags & PCP_C_SELECTION) != 0u ? sel[sp] : 1.0f;
    float k = fmin(m * u.opacity * s, 1.0f);
    if (!(k > 0.0f)) return;
    if ((u.flags & PCP_C_DISSOLVE) != 0u) {
        ulong seed = (ulong(u.seedHi) << 32) | ulong(u.seedLo);
        k = pcp_hash2(x, y, seed) < k ? 1.0f : 0.0f;
        if (k == 0.0f) return;
    }
    uint n = u.channels;
    uint base = sp * n;
    float px[8];
    for (uint i = 0; i < n; ++i) px[i] = pcp_read_px(p8, p16, p32, u.sample, base + i);
    uint a = u.alphaIdx;
    bool hasA = a != 0xFFFFFFFFu;
    bool lock = (u.flags & PCP_C_LOCK) != 0u;
    bool dither = (u.flags & PCP_C_DITHER) != 0u;
    if ((u.flags & PCP_C_ERASE) != 0u) {
        if (hasA && !lock) px[a] *= 1.0f - k;
    } else {
        if (lock && hasA && px[a] <= 0.0f) return;
        float src[8];
        for (uint i = 0; i < 8; ++i) src[i] = u.src[i];
        if ((u.flags & PCP_C_PERDAB) != 0u) {
            for (uint ch = 0; ch < u.nc; ++ch) src[ch] = col[ti * u.nc + ch] / c;
        }
        if ((u.flags & PCP_C_NORMAL) != 0u) {
            if (hasA) {
                float da = px[a], sa = src[a] * k;
                float oa = sa + da * (1.0f - sa);
                if (oa > 0.0f) {
                    for (uint ch = 0; ch < a; ++ch) px[ch] = (src[ch] * sa + px[ch] * da * (1.0f - sa)) / oa;
                }
                if (!lock) px[a] = oa;
            } else {
                for (uint ch = 0; ch < n; ++ch) px[ch] += (src[ch] - px[ch]) * k;
            }
        } else {
            uint gray = (u.flags & PCP_C_GRAY) != 0u ? 1u : 0u;
            float4 d = pcp_to_rgba(px, gray, a);
            float4 sr = pcp_to_rgba(src, gray, a);
            float4 o = pc_composite(u.mode, d, sr, k);
            if (lock) o.a = d.a;
            if (gray != 0u) {
                px[0] = 0.299f * o.r + 0.587f * o.g + 0.114f * o.b;
                if (hasA) px[1] = o.a;
            } else {
                px[0] = o.r; px[1] = o.g; px[2] = o.b;
                if (hasA) px[3] = o.a;
            }
        }
    }
    if (dither) {
        float dd = (pcp_hash2(x, y, PCP_DITHER_SALT) - 0.5f) / 255.0f;
        for (uint i = 0; i < n; ++i) px[i] += dd;
    }
    for (uint i = 0; i < n; ++i) pcp_write_px(p8, p16, p32, u.sample, base + i, px[i]);
}
