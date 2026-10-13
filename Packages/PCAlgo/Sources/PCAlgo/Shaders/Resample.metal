// Port of photocraft-algo (crates/algo/src/resample.rs, transform.rs, warp.rs, sharpen.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Geometry kernels: the separable Image Size pass (horizontal taps into an intermediate, vertical
// taps out of it, tap tables computed in f64 on the CPU), Free Transform's inverse-mapped sampler
// (emulated f64 so nearest picks photocraft's pixel), the mesh warp's per-pixel sampler (the
// rasterisation comes from the CPU), and Preserve Details' unsharp combine.

// MARK: Image Size pass

struct pca_rs_tap {
    int start;    // first source sample (document coordinate)
    int offset;   // into the weight array
    int count;
    float outside; // weight of the default pixel
};

struct pca_rs_pass_params {
    float4 def;      // default pixel, straight, in this plane's layout
    int2 tmp_origin; // document coordinates of the intermediate's texel (0, 0)
    int2 tmp_size;
    int x_lo;
    int pad0;
    int pad1;
    int pad2;
};

/// The source pixel at `p`, or the default pixel outside the source rectangle.
inline float4 pca_rs_src_or_def(pca_in src, constant pca_frame& f, int2 p, float4 def) {
    int2 q = p - f.src_origin;
    if (q.x < 0 || q.y < 0 || q.x >= f.src_size.x || q.y >= f.src_size.y) return def;
    return src.read(uint2(q));
}

/// Horizontal taps over premultiplied source rows: one thread per (output column, source row).
kernel void pca_rs_resample_h(constant pca_frame& f [[buffer(0)]], constant pca_rs_pass_params& p [[buffer(1)]],
                              device const pca_rs_tap* taps [[buffer(2)]], device const float* w [[buffer(3)]],
                              pca_in src [[texture(0)]], pca_out tmp [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.tmp_size.x || int(gid.y) >= p.tmp_size.y) return;
    bool alpha = f.alpha != 0u;
    pca_rs_tap t = taps[gid.x];
    int y = p.tmp_origin.y + int(gid.y);
    float4 acc = float4(0.0f);
    for (int k = 0; k < t.count; k++) {
        float4 s = pca_premul(pca_rs_src_or_def(src, f, int2(t.start + k, y), p.def), alpha);
        acc += s * w[t.offset + k];
    }
    acc += pca_premul(p.def, alpha) * t.outside;
    tmp.write(acc, gid);
}

/// Vertical taps over the intermediate rows, the default row's share, alpha clipped, unpremultiplied.
kernel void pca_rs_resample_v(constant pca_frame& f [[buffer(0)]], constant pca_rs_pass_params& p [[buffer(1)]],
                              device const pca_rs_tap* htaps [[buffer(2)]], device const float* hw [[buffer(3)]],
                              device const pca_rs_tap* vtaps [[buffer(4)]], device const float* vw [[buffer(5)]],
                              pca_in tmp [[texture(0)]], pca_out dst [[texture(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool alpha = f.alpha != 0u;
    pca_rs_tap t = vtaps[gid.y];
    float4 acc = float4(0.0f);
    for (int k = 0; k < t.count; k++) {
        int row = t.start + k - p.tmp_origin.y;
        acc += tmp.read(uint2(gid.x, uint(row))) * vw[t.offset + k];
    }
    // A source row of nothing but the default pixel, after the horizontal pass.
    float4 dp = pca_premul(p.def, alpha);
    pca_rs_tap h = htaps[gid.x];
    float4 dr = float4(0.0f);
    for (int k = 0; k < h.count; k++) dr += dp * hw[h.offset + k];
    dr += dp * h.outside;
    acc += dr * t.outside;
    if (alpha) acc.w = clamp(acc.w, 0.0f, 1.0f);
    dst.write(pca_unpremul(acc, alpha), gid);
}

// MARK: IEEE binary64 emulation
//
// Free Transform's inverse map runs in f64 in photocraft, and nearest sampling floors its result:
// exact ties (a 170 % scale lands pixel centres on x.5) must round exactly as f64 does. Doubles are
// kept as their bit patterns in `ulong`; add, mul and div round to nearest even like IEEE 754
// (inputs finite; results below the normal range flush to zero, far below any pixel maths).

constant ulong pca_rs_d_sign = 0x8000000000000000ul;
constant ulong pca_rs_d_frac = 0x000ffffffffffffful;

/// value = ±m × 2^e (m < 2^53; 0 for zero).
inline void pca_rs_d_unpack(ulong a, thread bool& neg, thread ulong& m, thread int& e) {
    neg = (a & pca_rs_d_sign) != 0ul;
    int be = int((a >> 52) & 0x7fful);
    ulong f = a & pca_rs_d_frac;
    if (be == 0) { m = f; e = -1074; } else { m = f | (1ul << 52); e = be - 1075; }
}

/// ±(m + sticky·ε) × 2^e rounded to a double (m ≠ 0 below 2^53 only without sticky).
inline ulong pca_rs_d_round_pack(bool neg, ulong m, int e, bool sticky) {
    ulong s = neg ? pca_rs_d_sign : 0ul;
    if (m == 0ul) return s;
    int p = 63 - int(clz(m));
    ulong mant;
    if (p > 52) {
        int k = p - 52;
        ulong rnd = m & ((1ul << k) - 1ul), hb = 1ul << (k - 1);
        mant = m >> k;
        e += k;
        if (rnd > hb || (rnd == hb && (sticky || (mant & 1ul) != 0ul))) {
            mant += 1ul;
            if (mant == (1ul << 53)) { mant >>= 1; e += 1; }
        }
    } else {
        mant = m << (52 - p);
        e -= 52 - p;
    }
    int be = e + 1075;
    if (be >= 2047) return s | (0x7fful << 52);
    if (be <= 0) return s;
    return s | (ulong(be) << 52) | (mant & pca_rs_d_frac);
}

inline ulong pca_rs_d_mul(ulong a, ulong b) {
    bool na, nb; ulong ma, mb; int ea, eb;
    pca_rs_d_unpack(a, na, ma, ea);
    pca_rs_d_unpack(b, nb, mb, eb);
    bool neg = na != nb;
    if (ma == 0ul || mb == 0ul) return neg ? pca_rs_d_sign : 0ul;
    ulong hi = mulhi(ma, mb), lo = ma * mb;
    if (hi == 0ul) return pca_rs_d_round_pack(neg, lo, ea + eb, false);
    int sb = 64 - int(clz(hi));
    ulong m = (hi << (64 - sb)) | (lo >> sb);
    return pca_rs_d_round_pack(neg, m, ea + eb + sb, (lo << (64 - sb)) != 0ul);
}

inline ulong pca_rs_d_add(ulong a, ulong b) {
    bool na, nb; ulong ma, mb; int ea, eb;
    pca_rs_d_unpack(a, na, ma, ea);
    pca_rs_d_unpack(b, nb, mb, eb);
    if (ma == 0ul) return mb == 0ul ? ((na && nb) ? pca_rs_d_sign : 0ul) : b;
    if (mb == 0ul) return a;
    // Ten guard bits, the larger magnitude first, the smaller shifted with its lost bits jammed
    // into the last bit (SoftFloat's scheme).
    ma <<= 10; mb <<= 10; ea -= 10; eb -= 10;
    if (ea < eb || (ea == eb && ma < mb)) {
        bool tn = na; na = nb; nb = tn;
        ulong tm = ma; ma = mb; mb = tm;
        int te = ea; ea = eb; eb = te;
    }
    int d = ea - eb;
    if (d >= 64) mb = 1ul;
    else if (d > 0) mb = (mb >> d) | (((mb << (64 - d)) != 0ul) ? 1ul : 0ul);
    ulong m = na == nb ? ma + mb : ma - mb;
    if (m == 0ul) return 0ul;
    return pca_rs_d_round_pack(na, m, ea, false);
}

inline ulong pca_rs_d_div(ulong a, ulong b) {
    bool na, nb; ulong ma, mb; int ea, eb;
    pca_rs_d_unpack(a, na, ma, ea);
    pca_rs_d_unpack(b, nb, mb, eb);
    bool neg = na != nb;
    if (mb == 0ul) return (neg ? pca_rs_d_sign : 0ul) | (0x7fful << 52);
    if (ma == 0ul) return neg ? pca_rs_d_sign : 0ul;
    int sa = int(clz(ma)) - 11, sb = int(clz(mb)) - 11;
    ma <<= sa; ea -= sa; mb <<= sb; eb -= sb;
    ulong q = 0ul, r = ma;
    for (int i = 0; i < 56; i++) {
        q <<= 1;
        if (r >= mb) { r -= mb; q |= 1ul; }
        r <<= 1;
    }
    return pca_rs_d_round_pack(neg, q, ea - eb - 55, r != 0ul);
}

/// The double of `v · 2^shift` (exact for |v| < 2^53).
inline ulong pca_rs_d_from_long(long v, int shift) {
    return pca_rs_d_round_pack(v < 0, ulong(v < 0 ? -v : v), shift, false);
}

/// A key ordered like the doubles (−0 = +0).
inline long pca_rs_d_key(ulong a) {
    long mag = long(a & ~pca_rs_d_sign);
    return (a & pca_rs_d_sign) != 0ul ? -mag : mag;
}

/// Rust's `v.floor() as i32` (saturating).
inline int pca_rs_d_floor_int(ulong a) {
    bool neg; ulong m; int e;
    pca_rs_d_unpack(a, neg, m, e);
    if (m == 0ul) return 0;
    if (e >= 0) return neg ? INT_MIN : INT_MAX;
    int k = -e;
    ulong ip = k >= 64 ? 0ul : m >> k;
    bool frac = k >= 64 ? true : (m & ((1ul << k) - 1ul)) != 0ul;
    if (ip > 0x80000000ul) return neg ? INT_MIN : INT_MAX;
    long v = neg ? -long(ip) - (frac ? 1 : 0) : long(ip);
    return int(clamp(v, long(INT_MIN), long(INT_MAX)));
}

/// `Float(v)` (one rounding).
inline float pca_rs_d_to_float(ulong a) {
    bool neg; ulong m; int e;
    pca_rs_d_unpack(a, neg, m, e);
    float f = ldexp(float(m), e);
    return neg ? -f : f;
}

/// photocraft `Homography::apply` row: (m[i]·x + m[i+1]·y) + m[i+2].
inline ulong pca_rs_d_row(constant ulong* m, int i, ulong x, ulong y) {
    return pca_rs_d_add(pca_rs_d_add(pca_rs_d_mul(m[i], x), pca_rs_d_mul(m[i + 1], y)), m[i + 2]);
}

/// photocraft `catmull_rom`.
inline float4 pca_rs_catmull(float t) {
    float t2 = t * t, t3 = t2 * t;
    return float4(-0.5f * t3 + t2 - 0.5f * t, 1.5f * t3 - 2.5f * t2 + 1.0f, -1.5f * t3 + 2.0f * t2 + 0.5f * t, 0.5f * t3 - 0.5f * t2);
}

/// The premultiplied source pixel inside `[lo, hi)`, else 0.
inline float4 pca_rs_at(pca_in src, constant pca_frame& f, int2 lo, int2 hi, int2 q) {
    if (q.x < lo.x || q.y < lo.y || q.x >= hi.x || q.y >= hi.y) return float4(0.0f);
    return pca_premul(pca_get(src, f, q), true);
}

/// photocraft's premultiplied bilinear tap order (rows, then columns).
inline float4 pca_rs_bilinear(pca_in src, constant pca_frame& f, int2 lo, int2 hi, int ix, int iy, float fx, float fy) {
    float4 acc = float4(0.0f);
    float wy[2] = {1.0f - fy, fy};
    float wx[2] = {1.0f - fx, fx};
    for (int dy = 0; dy < 2; dy++) {
        for (int dx = 0; dx < 2; dx++) {
            acc += pca_rs_at(src, f, lo, hi, int2(ix + dx, iy + dy)) * wx[dx] * wy[dy];
        }
    }
    return acc;
}

// MARK: Free Transform

struct pca_rs_warp_params {
    int2 rect_lo; // source rectangle sampled
    int2 rect_hi;
    int interp;   // 0 nearest, 1 bilinear, 2 bicubic
    int pad0;
    int pad1;
    int pad2;
};

/// Inverse-mapped sampling of one destination pixel (photocraft `transform::warp`'s tile loop):
/// `m` is the inverse homography, f64 bit patterns, evaluated in emulated f64.
kernel void pca_rs_warp(constant pca_frame& f [[buffer(0)]], constant pca_rs_warp_params& p [[buffer(1)]],
                        constant ulong* m [[buffer(2)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    const ulong dhalf = 0x3fe0000000000000ul, mhalf = 0xbfe0000000000000ul;
    ulong x = pca_rs_d_from_long(2 * long(q.x) + 1, -1), y = pca_rs_d_from_long(2 * long(q.y) + 1, -1);
    ulong w = pca_rs_d_row(m, 6, x, y);
    ulong u = pca_rs_d_add(pca_rs_d_div(pca_rs_d_row(m, 0, x, y), w), mhalf);
    ulong v = pca_rs_d_add(pca_rs_d_div(pca_rs_d_row(m, 3, x, y), w), mhalf);
    long ku = pca_rs_d_key(u), kv = pca_rs_d_key(v);
    bool nonfinite = ((u >> 52) & 0x7fful) == 0x7fful || ((v >> 52) & 0x7fful) == 0x7fful;
    if (nonfinite || ku < pca_rs_d_key(pca_rs_d_from_long(long(p.rect_lo.x) - 1, 0)) || kv < pca_rs_d_key(pca_rs_d_from_long(long(p.rect_lo.y) - 1, 0)) ||
        ku > pca_rs_d_key(pca_rs_d_from_long(long(p.rect_hi.x), 0)) || kv > pca_rs_d_key(pca_rs_d_from_long(long(p.rect_hi.y), 0))) {
        dst.write(float4(0.0f), gid);
        return;
    }
    float4 acc = float4(0.0f);
    if (p.interp == 0) {
        int ix = pca_rs_d_floor_int(pca_rs_d_add(u, dhalf)), iy = pca_rs_d_floor_int(pca_rs_d_add(v, dhalf));
        acc = pca_rs_at(src, f, p.rect_lo, p.rect_hi, int2(ix, iy));
    } else {
        int ix = pca_rs_d_floor_int(u), iy = pca_rs_d_floor_int(v);
        float fx = pca_rs_d_to_float(pca_rs_d_add(u, pca_rs_d_from_long(-long(ix), 0)));
        float fy = pca_rs_d_to_float(pca_rs_d_add(v, pca_rs_d_from_long(-long(iy), 0)));
        if (p.interp == 1) {
            acc = pca_rs_bilinear(src, f, p.rect_lo, p.rect_hi, ix, iy, fx, fy);
        } else {
            float4 wx = pca_rs_catmull(fx), wy = pca_rs_catmull(fy);
            for (int j = 0; j < 4; j++) {
                for (int i = 0; i < 4; i++) {
                    float k = wx[i] * wy[j];
                    acc += pca_rs_at(src, f, p.rect_lo, p.rect_hi, int2(ix - 1 + i, iy - 1 + j)) * k;
                }
            }
        }
    }
    float al = clamp(acc.w, 0.0f, 1.0f);
    if (!(al > 0.0f)) {
        dst.write(float4(0.0f), gid);
        return;
    }
    dst.write(float4(acc.xyz / al, al), gid);
}

// MARK: Mesh warp

struct pca_rs_mesh_px {
    int bx;    // point sample: the cell (or the nearest pixel); subsampled: floor of the centre
    int by;
    float fx;  // the fraction within the cell
    float fy;
    int owner; // triangle, < 0 uncovered
};

struct pca_rs_mesh_tri {
    float4 j;  // source step per destination pixel along x (j.xy) and y (j.zw)
    int nx;    // subsamples per axis (1 × 1: point sample)
    int ny;
    int pad0;
    int pad1;
};

struct pca_rs_mesh_params {
    int2 rect_lo;
    int2 rect_hi;
    int interp;
    int pad0;
    int pad1;
    int pad2;
};

/// One destination pixel of a mesh warp (photocraft `warp_triangles`' sampling): a point sample,
/// or the mean of nx × ny bilinear subsamples over the pixel's source footprint.
kernel void pca_rs_mesh(constant pca_frame& f [[buffer(0)]], constant pca_rs_mesh_params& p [[buffer(1)]],
                        device const pca_rs_mesh_px* table [[buffer(2)]], device const pca_rs_mesh_tri* tris [[buffer(3)]],
                        pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    pca_rs_mesh_px e = table[int(gid.y) * f.out_size.x + int(gid.x)];
    if (e.owner < 0) {
        dst.write(float4(0.0f), gid);
        return;
    }
    pca_rs_mesh_tri t = tris[e.owner];
    float4 acc = float4(0.0f);
    if (t.nx * t.ny == 1) {
        if (p.interp == 0) {
            acc = pca_rs_at(src, f, p.rect_lo, p.rect_hi, int2(e.bx, e.by));
        } else if (p.interp == 1) {
            acc = pca_rs_bilinear(src, f, p.rect_lo, p.rect_hi, e.bx, e.by, e.fx, e.fy);
        } else {
            float4 wx = pca_rs_catmull(e.fx), wy = pca_rs_catmull(e.fy);
            for (int j = 0; j < 4; j++) {
                for (int i = 0; i < 4; i++) {
                    float k = wx[i] * wy[j];
                    if (k == 0.0f) continue;
                    acc += pca_rs_at(src, f, p.rect_lo, p.rect_hi, int2(e.bx - 1 + i, e.by - 1 + j)) * k;
                }
            }
        }
    } else {
        for (int sy = 0; sy < t.ny; sy++) {
            float tt = (float(sy) + 0.5f) / float(t.ny) - 0.5f;
            for (int sx = 0; sx < t.nx; sx++) {
                float s = (float(sx) + 0.5f) / float(t.nx) - 0.5f;
                float ru = e.fx + s * t.j.x + tt * t.j.z;
                float rv = e.fy + s * t.j.y + tt * t.j.w;
                float fu = floor(ru), fv = floor(rv);
                acc += pca_rs_bilinear(src, f, p.rect_lo, p.rect_hi, e.bx + int(fu), e.by + int(fv), ru - fu, rv - fv);
            }
        }
        acc *= 1.0f / float(t.nx * t.ny);
    }
    float al = clamp(acc.w, 0.0f, 1.0f);
    if (!(al > 1e-6f)) {
        dst.write(float4(0.0f), gid);
        return;
    }
    dst.write(float4(clamp(acc.xyz / al, 0.0f, 1.0f), al), gid);
}

// MARK: Unsharp Mask (Preserve Details)

struct pca_rs_unsharp_params {
    float k;   // amount / 100
    float t;   // threshold / 255
    int pad0;
    int pad1;
};

/// photocraft `with_blur` + `unsharp`: o + k·(o − blur) on the colour channels where the
/// difference clears the threshold; transparent pixels left alone.
kernel void pca_rs_unsharp(constant pca_frame& f [[buffer(0)]], constant pca_rs_unsharp_params& p [[buffer(1)]],
                           pca_in src [[texture(0)]], pca_in blur [[texture(1)]], pca_out dst [[texture(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool alpha = f.alpha != 0u;
    float4 o = pca_get(src, f, q);
    if (alpha && o.w <= 0.0f) {
        dst.write(o, gid);
        return;
    }
    float4 b = blur.read(gid);
    float4 r = o;
    int nc = alpha ? 3 : 4;
    for (int c = 0; c < nc; c++) {
        float d = o[c] - b[c];
        if (fabs(d) + 1e-6f >= p.t) r[c] = o[c] + p.k * d;
    }
    dst.write(r, gid);
}
