// Port of photocraft-algo (crates/algo/src/distort.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Twirl, Pinch, Spherize, Wave, Ripple and Polar Coordinates: photocraft `distort::remap` per
// output pixel — the pixel centre is mapped back to a source position and sampled with
// `pca_sample` (premultiplied bilinear, edge policy relative to the bounds). Per-filter
// constants come from Swift (Distort.swift) so both sides use identical values.

#define PCA_DIS_TAU 6.28318530717958647692f
#define PCA_DIS_PI 3.14159265358979323846f

/// Exact `fmod` (musl's `fmodf`, on the bit patterns). MSL's `fmod` is not exact (it differs
/// from libm for almost every argument), which would move Wave's square-wave edges.
inline float pca_dis_fmod(float x, float y) {
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

/// Rust `f32::rem_euclid` with the exact `fmod`.
inline float pca_dis_rem_euclid(float a, float b) {
    float r = pca_dis_fmod(a, b);
    return r < 0.0f ? r + fabs(b) : r;
}

/// Correctly rounded `sqrt` (libm's). MSL's `sqrt` can be 2 ulp off; Tuckerman's test (exact
/// signs from `fma`) walks it to the IEEE result. Tiny inputs are scaled by 2^64 so the residuals
/// stay normal. Only needed before hard thresholds (Lens Flare's ghost discs).
inline float pca_dis_sqrt(float x) {
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

/// IEEE `atan2` (libm / Rust `f32::atan2`). MSL's `atan2` returns the wrong half-plane when x is
/// −0 (atan2(−5, −0) = +π/2) and NaN for atan2(±0, ±0); polar maps hit both on the centre row.
inline float pca_dis_atan2(float y, float x) {
    if (x == 0.0f) {
        if (y == 0.0f) return signbit(x) ? copysign(PCA_DIS_PI, y) : y;
        return copysign(PCA_DIS_PI / 2.0f, y);
    }
    if (y == 0.0f && x > 0.0f) return y;
    return atan2(y, x);
}

/// photocraft `remap`'s sample: the source at `pos` with `edge` relative to the bounds.
inline float4 pca_dis_at(pca_in src, constant pca_frame& f, float2 pos, uint edge) {
    return pca_sample(src, f, pos, edge, f.bounds_origin, f.bounds_size);
}

/// The output pixel centre (x + .5, y + .5).
inline float2 pca_dis_centre_of(int2 q) { return float2(float(q.x) + 0.5f, float(q.y) + 0.5f); }

struct pca_dis_twirl_params {
    float2 c;
    float rr;
    float a;   // twirl: angle in radians; pinch: the exponent 1 − a/2
};

kernel void pca_dis_twirl(constant pca_frame& f [[buffer(0)]], constant pca_dis_twirl_params& p [[buffer(1)]],
                          pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float2 xy = pca_dis_centre_of(q);
    float dx = xy.x - p.c.x, dy = xy.y - p.c.y;
    float r = sqrt(dx * dx + dy * dy);
    float2 s = xy;
    if (!(r >= p.rr || p.rr <= 0.0f)) {
        float t = p.a * (1.0f - r / p.rr);
        float sn = sin(t), cs = cos(t);
        s = float2(p.c.x + dx * cs - dy * sn, p.c.y + dx * sn + dy * cs);
    }
    dst.write(pca_dis_at(src, f, s, PCA_EDGE_REPEAT), gid);
}

kernel void pca_dis_pinch(constant pca_frame& f [[buffer(0)]], constant pca_dis_twirl_params& p [[buffer(1)]],
                          pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float2 xy = pca_dis_centre_of(q);
    float dx = xy.x - p.c.x, dy = xy.y - p.c.y;
    float r = sqrt(dx * dx + dy * dy);
    float2 s = xy;
    if (!(r >= p.rr || r <= 0.0f)) {
        float rs = p.rr * pow(r / p.rr, p.a);
        s = float2(p.c.x + dx * rs / r, p.c.y + dy * rs / r);
    }
    dst.write(pca_dis_at(src, f, s, PCA_EDGE_REPEAT), gid);
}

struct pca_dis_spherize_params {
    float2 c;
    float2 h;    // half width / height of the bounds
    float rr;
    float a;
    uint mode;   // 0 normal, 1 horizontal only, 2 vertical only
    int pad0;
};

/// photocraft `sphere_1d`.
inline float pca_dis_sphere_1d(float rn, float a) {
    float target = a >= 0.0f ? asin(rn) * 2.0f / PCA_DIS_PI : sin(rn * (PCA_DIS_PI / 2.0f));
    return rn + fabs(a) * (target - rn);
}

/// Rust `f32::signum`.
inline float pca_dis_signum(float v) { return signbit(v) ? -1.0f : 1.0f; }

kernel void pca_dis_spherize(constant pca_frame& f [[buffer(0)]], constant pca_dis_spherize_params& p [[buffer(1)]],
                             pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float2 xy = pca_dis_centre_of(q);
    float dx = xy.x - p.c.x, dy = xy.y - p.c.y;
    float2 s = xy;
    if (p.mode == 0u) {
        float r = sqrt(dx * dx + dy * dy);
        if (!(r >= p.rr || r <= 0.0f)) {
            float rs = p.rr * pca_dis_sphere_1d(r / p.rr, p.a);
            s = float2(p.c.x + dx * rs / r, p.c.y + dy * rs / r);
        }
    } else if (p.mode == 1u) {
        if (!(fabs(dx) >= p.h.x)) s.x = p.c.x + pca_dis_signum(dx) * p.h.x * pca_dis_sphere_1d(fabs(dx) / p.h.x, p.a);
    } else {
        if (!(fabs(dy) >= p.h.y)) s.y = p.c.y + pca_dis_signum(dy) * p.h.y * pca_dis_sphere_1d(fabs(dy) / p.h.y, p.a);
    }
    dst.write(pca_dis_at(src, f, s, PCA_EDGE_REPEAT), gid);
}

struct pca_dis_wave_params {
    float2 b0;   // bounds origin
    uint ngen;
    uint type;   // 0 sine, 1 triangle, 2 square
    uint edge;
    float nf;    // generator count as a float
    int pad0;
    int pad1;
};

/// photocraft `distort::shape`.
inline float pca_dis_wave_shape(uint t, float phase) {
    if (t == 0u) return sin(phase);
    float p = pca_dis_rem_euclid(phase, PCA_DIS_TAU) / PCA_DIS_TAU;
    if (t == 1u) return 1.0f - 4.0f * fabs(p - 0.5f);
    return p < 0.5f ? 1.0f : -1.0f;
}

/// `g[i]` = (wavelength, amplitude, phase x, phase y).
kernel void pca_dis_wave(constant pca_frame& f [[buffer(0)]], constant pca_dis_wave_params& p [[buffer(1)]],
                         constant float4* g [[buffer(2)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float2 xy = pca_dis_centre_of(q);
    float lx = xy.x - p.b0.x, ly = xy.y - p.b0.y;
    float dx = 0.0f, dy = 0.0f;
    for (uint i = 0; i < p.ngen; i++) {
        float4 w = g[i];
        dx += w.y * pca_dis_wave_shape(p.type, PCA_DIS_TAU * ly / w.x + w.z);
        dy += w.y * pca_dis_wave_shape(p.type, PCA_DIS_TAU * lx / w.x + w.w);
    }
    dst.write(pca_dis_at(src, f, float2(xy.x + dx / p.nf, xy.y + dy / p.nf), p.edge), gid);
}

struct pca_dis_ripple_params {
    float2 b0;
    float amp;
    float len;
};

kernel void pca_dis_ripple(constant pca_frame& f [[buffer(0)]], constant pca_dis_ripple_params& p [[buffer(1)]],
                           pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float2 xy = pca_dis_centre_of(q);
    float lx = xy.x - p.b0.x, ly = xy.y - p.b0.y;
    float2 s = float2(xy.x + p.amp * sin(PCA_DIS_TAU * ly / p.len), xy.y + p.amp * sin(PCA_DIS_TAU * lx / p.len));
    dst.write(pca_dis_at(src, f, s, PCA_EDGE_REPEAT), gid);
}

struct pca_dis_polar_params {
    float2 b0;
    float2 wh;
    float2 c;
    float rmax;
    uint mode;   // 0 rectangular → polar, 1 polar → rectangular
};

kernel void pca_dis_polar(constant pca_frame& f [[buffer(0)]], constant pca_dis_polar_params& p [[buffer(1)]],
                          pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float2 xy = pca_dis_centre_of(q);
    float2 s;
    if (p.mode == 0u) {
        float dx = xy.x - p.c.x, dy = xy.y - p.c.y;
        float theta = pca_dis_rem_euclid(pca_dis_atan2(dx, -dy), PCA_DIS_TAU);
        float r = sqrt(dx * dx + dy * dy);
        s = float2(p.b0.x + theta / PCA_DIS_TAU * p.wh.x, p.b0.y + r / p.rmax * p.wh.y);
    } else {
        float theta = (xy.x - p.b0.x) / p.wh.x * PCA_DIS_TAU;
        float r = (xy.y - p.b0.y) / p.wh.y * p.rmax;
        s = float2(p.c.x + r * sin(theta), p.c.y - r * cos(theta));
    }
    dst.write(pca_dis_at(src, f, s, PCA_EDGE_TRANSPARENT), gid);
}

