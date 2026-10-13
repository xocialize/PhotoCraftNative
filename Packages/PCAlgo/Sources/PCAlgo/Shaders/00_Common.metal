// Port of photocraft-algo (crates/algo/src/image.rs, noise.rs, fxutil.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Shared MSL for every PCAlgo kernel: the frame uniforms, photocraft `Image` sampling semantics
// (0 outside the source, edge policies, premultiplied bilinear), the coordinate hash, and the
// float4 plane conventions (alpha in .w when frame.alpha; see GPU.swift).

// No FMA contraction anywhere in PCAlgo: `.safe` math mode still fuses `a * b + c` into fmuladd,
// which the Swift references never do; fused results flip hard thresholds 1 ulp apart.
#pragma METAL fp contract(off)

struct pca_frame {
    int2 src_origin;     // document coordinates of source texel (0, 0)
    int2 src_size;
    int2 out_origin;     // document coordinates of destination texel (0, 0)
    int2 out_size;
    int2 bounds_origin;  // reference bounds (distortion centre, mosaic anchor…)
    int2 bounds_size;
    uint alpha;          // 1: .w is alpha
    uint mode;           // 0 gray-like, 1 RGB-like, 2 other
    uint ncomp;          // colour components used in this plane
    uint plane;
    uint color_channels; // colour channels of the whole image
    uint first_channel;  // image channel of this plane's .x
    uint pad0;
    uint pad1;
};

typedef texture2d<float, access::read> pca_in;
typedef texture2d<float, access::write> pca_out;

#define PCA_EDGE_TRANSPARENT 0u
#define PCA_EDGE_REPEAT 1u
#define PCA_EDGE_WRAP 2u

/// The source pixel at document `p`; 0 outside the source (photocraft `Image::get`).
inline float4 pca_get(pca_in t, constant pca_frame& f, int2 p) {
    int2 q = p - f.src_origin;
    if (q.x < 0 || q.y < 0 || q.x >= f.src_size.x || q.y >= f.src_size.y) return float4(0.0f);
    return t.read(uint2(q));
}

/// A texture covering `origin`/`size` (an intermediate) read at document `p`; 0 outside.
inline float4 pca_get_at(pca_in t, int2 origin, int2 size, int2 p) {
    int2 q = p - origin;
    if (q.x < 0 || q.y < 0 || q.x >= size.x || q.y >= size.y) return float4(0.0f);
    return t.read(uint2(q));
}

/// The source pixel at document `p`, clamped to the source rectangle (edge repeated).
inline float4 pca_get_clamped(pca_in t, constant pca_frame& f, int2 p) {
    if (f.src_size.x <= 0 || f.src_size.y <= 0) return float4(0.0f);
    int2 q = clamp(p - f.src_origin, int2(0), f.src_size - 1);
    return t.read(uint2(q));
}

inline int pca_rem_euclid(int a, int b) {
    int r = a % b;
    return r < 0 ? r + abs(b) : r;
}

/// Exact `fmod` (musl's `fmodf` on the bit patterns): MSL's `fmod` is not exact, which would
/// move hard edges that depend on a remainder (found by the Distort port, `pca_dis_fmod`).
inline float pca_fmod(float x, float y) {
    uint uxi = as_type<uint>(x), uyi = as_type<uint>(y);
    int ex = int((uxi >> 23) & 0xffu), ey = int((uyi >> 23) & 0xffu);
    uint sx = uxi & 0x80000000u;
    uint i;
    if ((uyi << 1) == 0u || isnan(y) || ex == 0xff) return NAN;
    if ((uxi << 1) <= (uyi << 1)) {
        if ((uxi << 1) == (uyi << 1)) return 0.0f * x;
        return x;
    }
    if (ex == 0) {
        for (i = uxi << 9; (i >> 31) == 0u; ex--, i <<= 1) {}
        uxi <<= uint(-ex + 1);
    } else {
        uxi &= 0xffffffffu >> 9;
        uxi |= 1u << 23;
    }
    if (ey == 0) {
        for (i = uyi << 9; (i >> 31) == 0u; ey--, i <<= 1) {}
        uyi <<= uint(-ey + 1);
    } else {
        uyi &= 0xffffffffu >> 9;
        uyi |= 1u << 23;
    }
    for (; ex > ey; ex--) {
        i = uxi - uyi;
        if ((i >> 31) == 0u) {
            if (i == 0u) return 0.0f * x;
            uxi = i;
        }
        uxi <<= 1;
    }
    i = uxi - uyi;
    if ((i >> 31) == 0u) {
        if (i == 0u) return 0.0f * x;
        uxi = i;
    }
    for (; (uxi >> 23) == 0u; uxi <<= 1, ex--) {}
    if (ex > 0) {
        uxi -= 1u << 23;
        uxi |= uint(ex) << 23;
    } else {
        uxi >>= uint(-ex + 1);
    }
    uxi |= sx;
    return as_type<float>(uxi);
}

/// Rust `f32::rem_euclid` (exact remainder).
inline float pca_rem_euclid_f(float a, float b) {
    float r = pca_fmod(a, b);
    return r < 0.0f ? r + fabs(b) : r;
}

/// The source pixel with an edge policy relative to `area` (photocraft `Image::get_edge`).
inline float4 pca_get_edge(pca_in t, constant pca_frame& f, int2 p, uint edge, int2 area_origin, int2 area_size) {
    if (area_size.x <= 0 || area_size.y <= 0) return float4(0.0f);
    int2 q = p - area_origin;
    if (q.x >= 0 && q.y >= 0 && q.x < area_size.x && q.y < area_size.y) return pca_get(t, f, p);
    if (edge == PCA_EDGE_TRANSPARENT) return float4(0.0f);
    if (edge == PCA_EDGE_REPEAT) return pca_get(t, f, area_origin + clamp(q, int2(0), area_size - 1));
    return pca_get(t, f, area_origin + int2(pca_rem_euclid(q.x, area_size.x), pca_rem_euclid(q.y, area_size.y)));
}

inline float4 pca_premul(float4 v, bool alpha) { return alpha ? float4(v.xyz * v.w, v.w) : v; }

/// Inverse of premultiplication: colour 0 where alpha ≤ 1e-7 (photocraft `unpremultiply`).
inline float4 pca_unpremul(float4 v, bool alpha) {
    if (!alpha) return v;
    return v.w > 1e-7f ? float4(v.xyz / v.w, v.w) : float4(0.0f, 0.0f, 0.0f, v.w);
}

/// Bilinear sample of the premultiplied pixel at continuous `pos` (pixel centres at .5), returned
/// straight with alpha in .w (photocraft `Image::sample`).
inline float4 pca_sample(pca_in t, constant pca_frame& f, float2 pos, uint edge, int2 area_origin, int2 area_size) {
    bool alpha = f.alpha != 0u;
    float2 fp = pos - 0.5f;
    float2 fl = floor(fp);
    float ax = fp.x - fl.x, ay = fp.y - fl.y;
    // Rust's saturating `as i32` (NaN → 0), within ±1e9 so neighbour taps cannot overflow.
    float2 cl = select(clamp(fl, -1e9f, 1e9f), float2(0.0f), isnan(fl));
    int2 p0 = int2(cl);
    float4 acc = float4(0.0f);
    float acc_a = 0.0f;
    float w[4] = {(1.0f - ax) * (1.0f - ay), ax * (1.0f - ay), (1.0f - ax) * ay, ax * ay};
    int2 d[4] = {int2(0, 0), int2(1, 0), int2(0, 1), int2(1, 1)};
    for (int k = 0; k < 4; k++) {
        if (w[k] <= 0.0f) continue;
        float4 s = pca_get_edge(t, f, p0 + d[k], edge, area_origin, area_size);
        if (alpha) {
            float a = s.w;
            acc.xyz += s.xyz * a * w[k];
            acc_a += a * w[k];
        } else {
            acc += s * w[k];
        }
    }
    if (alpha) {
        if (acc_a > 0.0f) acc.xyz /= acc_a;
        acc.w = acc_a;
    }
    return acc;
}

/// Correctly rounded `sqrt` (libm's / Swift's `squareRoot`). MSL's `sqrt` — even `precise::` with
/// precise functions — is 1 ulp off for ~0.8 % of inputs; Tuckerman's test (exact residual signs
/// from `fma`) walks it to the IEEE result (found by the Distort port, `pca_dis_sqrt`). Use it
/// before hard thresholds and `ceil`/`floor` of a distance.
inline float pca_sqrt(float x) {
    if (!(x > 0.0f) || isinf(x)) return sqrt(x);
    float scale = 1.0f;
    if (x < 1.0e-20f) { x *= 18446744073709551616.0f; scale = 1.0f / 4294967296.0f; }
    float s = sqrt(x);
    for (int k = 0; k < 4; k++) {
        float sp = nextafter(s, INFINITY);
        if (fma(-s, sp, x) > 0.0f) { s = sp; continue; }
        float sm = nextafter(s, 0.0f);
        if (fma(-sm, s, x) <= 0.0f) { s = sm; continue; }
        break;
    }
    return s * scale;
}

/// Rust's `f32 as i32`: saturating, NaN → 0.
inline int pca_i32(float v) {
    if (isnan(v)) return 0;
    if (v >= 2147483648.0f) return INT_MAX;
    if (v <= -2147483648.0f) return INT_MIN;
    return int(v);
}

/// Float-float ("double-float") accumulation: (hi, lo) += v with renormalisation, ~48 bits — the
/// GPU stand-in for photocraft's f64 sums.
inline void pca_ff_add(thread float4& hi, thread float4& lo, float4 v) {
    float4 s = hi + v;
    float4 bb = s - hi;
    float4 e = (hi - (s - bb)) + (v - bb);
    e = e + lo;
    hi = s + e;
    lo = e - (hi - s);
}

/// (hi, lo) × (nh, nl) rounded to float: the f64 product `sum * norm` of the CPU references.
inline float4 pca_ff_mul_round(float4 hi, float4 lo, float nh, float nl) {
    float4 ph = hi * nh;
    float4 pl = fma(hi, float4(nh), -ph);
    float4 t = hi * nl;
    t = t + lo * nh;
    pl = pl + t;
    return ph + pl;
}

/// Deterministic hash → [0, 1) from document coordinates (photocraft `noise::hash01`).
inline float pca_hash01(int x, int y, uint c, uint seed) {
    uint h = (uint(x) * 0x8da6b343u) ^ (uint(y) * 0xd8163841u) ^ (c * 0xcb1ab31fu) ^ (seed * 0x9e3779b9u);
    h ^= h >> 16;
    h *= 0x7feb352du;
    h ^= h >> 15;
    h *= 0x846ca68bu;
    h ^= h >> 16;
    return float(h >> 8) / 16777216.0f;
}

/// Jittered feature point of grid cell (cx, cy) (photocraft `fxutil::cell_point`).
inline float2 pca_cell_point(int cx, int cy, float cell, uint seed, float2 origin) {
    return float2(origin.x + (float(cx) + 0.1f + 0.8f * pca_hash01(cx, cy, 11u, seed)) * cell,
                  origin.y + (float(cy) + 0.1f + 0.8f * pca_hash01(cx, cy, 12u, seed)) * cell);
}

/// photocraft `fxutil::smoothstep` (a step when e1 ≤ e0).
inline float pca_smoothstep(float e0, float e1, float x) {
    if (e1 <= e0) return x >= e1 ? 1.0f : 0.0f;
    float t = clamp((x - e0) / (e1 - e0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

/// Rec. 601 luma of a plane pixel (gray-like: .x; RGB-like: weighted .xyz).
inline float pca_luma(float4 v, uint mode) {
    return mode == 0u ? v.x : 0.299f * v.x + 0.587f * v.y + 0.114f * v.z;
}

/// A gray value in the plane's model (alpha kept): RGB-like (g, g, g), gray-like g.
inline float4 pca_gray(float g, float4 orig, constant pca_frame& f) {
    float a = f.alpha != 0u ? orig.w : 0.0f;
    if (f.mode == 0u) return float4(g, 0.0f, 0.0f, f.alpha != 0u ? a : 0.0f);
    return float4(g, g, g, f.alpha != 0u ? a : 0.0f);
}

/// Thread position → document pixel of the output; false outside the output.
inline bool pca_out_pixel(constant pca_frame& f, uint2 gid, thread int2& p) {
    if (int(gid.x) >= f.out_size.x || int(gid.y) >= f.out_size.y) return false;
    p = f.out_origin + int2(gid);
    return true;
}

/// Identity: the source cropped to the output (0 outside the source).
kernel void pca_copy(constant pca_frame& f [[buffer(0)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    int2 p;
    if (!pca_out_pixel(f, gid, p)) return;
    dst.write(pca_get(src, f, p), gid);
}
