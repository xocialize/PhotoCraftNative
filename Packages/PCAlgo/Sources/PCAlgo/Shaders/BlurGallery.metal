// Port of photocraft-algo (crates/algo/src/gallery.rs, gallery/spin_plan.rs, fxutil.rs: add_sample_premul), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Blur Gallery: the σ map (Tilt-Shift band, Iris pins, Field pins), the level accumulation of
// the spatially varying blur, and the Spin / Path samplers (bilinear premultiplied, clamped to
// the bounds ∩ source).

/// Premultiplied copy of the source window (the level stack's base).
kernel void pca_premul_copy(constant pca_frame& f [[buffer(0)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    dst.write(pca_premul(pca_get(src, f, q), f.alpha != 0u), gid);
}

struct pca_gal_sigma_params {
    uint kind;     // 0 tilt-shift, 1 iris, 2 field
    int count;
    float smax;
    float ss;
    float2 center;
    float2 normal;
    float f0;
    float f1;
    float pad0;
    float pad1;
};

struct pca_iris_pin {
    float cx, cy, rx, ry;
    float sn, cs, exponent, feather;
    float blur, pad0, pad1, pad2;
};

inline float pca_iris_sigma(constant pca_iris_pin& p, float x, float y) {
    float dx = x - p.cx, dy = y - p.cy;
    float u = (dx * p.cs + dy * p.sn) / p.rx, v = (-dx * p.sn + dy * p.cs) / p.ry;
    float e;
    if (fabs(u) >= 1.0f || fabs(v) >= 1.0f) e = INFINITY;
    else if (fabs(p.exponent - 2.0f) < 1e-3f) e = pca_sqrt(u * u + v * v);
    else e = pow(pow(fabs(u), p.exponent) + pow(fabs(v), p.exponent), 1.0f / p.exponent);
    if (!isfinite(e)) e = INFINITY;
    return p.blur * pca_smoothstep(p.feather, 1.0f, e);
}

kernel void pca_gal_sigma(constant pca_frame& f [[buffer(0)]], constant pca_gal_sigma_params& p [[buffer(1)]],
                          constant float* pins [[buffer(2)]], pca_out sig [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float x = float(q.x) + 0.5f, y = float(q.y) + 0.5f;
    float s = 0.0f;
    if (p.kind == 0u) {
        float d = fabs((x - p.center.x) * p.normal.x + (y - p.center.y) * p.normal.y) / p.ss;
        s = p.smax * pca_smoothstep(p.f0, p.f1, d);
    } else if (p.kind == 1u) {
        constant pca_iris_pin* ip = (constant pca_iris_pin*)pins;
        s = FLT_MAX;
        for (int i = 0; i < p.count; i++) s = min(s, pca_iris_sigma(ip[i], x, y));
    } else {
        constant float4* pts = (constant float4*)pins;
        float ws = 0.0f, acc = 0.0f;
        for (int i = 0; i < p.count; i++) {
            float4 pt = pts[i];
            float w = 1.0f / ((x - pt.x) * (x - pt.x) + (y - pt.y) * (y - pt.y) + 1.0f);
            ws += w;
            acc += w * pt.z;
        }
        s = acc / ws;
    }
    sig.write(float4(clamp(s, 0.0f, p.smax), 0.0f, 0.0f, 0.0f), gid);
}

struct pca_gal_accum_params {
    float lo;
    float mid;
    float hi;
    uint first;
    uint last;
    uint has_lo;
    uint has_hi;
    uint pad;
};

/// acc += hat weight × level (premultiplied); the last level unpremultiplies into the output.
kernel void pca_gal_accum(constant pca_frame& f [[buffer(0)]], constant pca_gal_accum_params& p [[buffer(1)]],
                          pca_in acc [[texture(0)]], pca_in level [[texture(1)]], pca_in sig [[texture(2)]],
                          pca_out next [[texture(3)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float s = sig.read(gid).x;
    float c = p.mid;
    float w;
    if (p.has_lo != 0u && s >= p.lo && s <= c) w = (s - p.lo) / max(c - p.lo, 1e-6f);
    else if (p.has_hi != 0u && s >= c && s <= p.hi) w = (p.hi - s) / max(p.hi - c, 1e-6f);
    else if (p.last != 0u && s >= c) w = 1.0f;
    else w = 0.0f;
    float4 a = p.first != 0u ? float4(0.0f) : acc.read(gid);
    if (w > 0.0f) a += pca_get(level, f, q) * w;
    next.write(p.last != 0u ? pca_unpremul(a, f.alpha != 0u) : a, gid);
}

/// photocraft `add_sample_premul`: bilinear, positions and taps clamped to the clip rectangle.
inline void pca_add_sample_premul(pca_in t, constant pca_frame& f, float2 pos, int2 co, int2 cs, bool alpha, thread float4& acc) {
    if (!isfinite(pos.x) || !isfinite(pos.y) || cs.x <= 0 || cs.y <= 0) return;
    float fx = clamp(pos.x - 0.5f, float(co.x), float(co.x + cs.x - 1));
    float fy = clamp(pos.y - 0.5f, float(co.y), float(co.y + cs.y - 1));
    int x0 = int(floor(fx)), y0 = int(floor(fy));
    int x1 = min(x0 + 1, co.x + cs.x - 1), y1 = min(y0 + 1, co.y + cs.y - 1);
    float ax = fx - float(x0), ay = fy - float(y0);
    int2 pts[4] = {int2(x0, y0), int2(x1, y0), int2(x0, y1), int2(x1, y1)};
    float ks[4] = {(1.0f - ax) * (1.0f - ay), ax * (1.0f - ay), (1.0f - ax) * ay, ax * ay};
    for (int i = 0; i < 4; i++) {
        float k = ks[i];
        if (k <= 0.0f) continue;
        float4 px = pca_get(t, f, pts[i]);
        if (alpha) {
            float a = px.w * k;
            acc.xyz += px.xyz * a;
            acc.w += a;
        } else {
            acc += px * k;
        }
    }
}

struct pca_clip_params {
    int2 clip_origin;
    int2 clip_size;
    int count;
    int pad0;
    int pad1;
    int pad2;
};

struct pca_spin_geo {
    float cx, cy, rxd, ryd;
    float sa, ca, rx, ry;
    float rmax, theta, ss, pad;
};

kernel void pca_spin_blur(constant pca_frame& f [[buffer(0)]], constant pca_clip_params& p [[buffer(1)]],
                          constant pca_spin_geo* geos [[buffer(2)]], const device float2* tables [[buffer(3)]],
                          pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool alpha = f.alpha != 0u;
    float fx = float(q.x) + 0.5f, fy = float(q.y) + 0.5f;
    float4 px = pca_get(src, f, q);
    for (int pi = 0; pi < p.count; pi++) {
        pca_spin_geo g = geos[pi];
        float dx = fx - g.cx, dy = fy - g.cy;
        float u = (dx * g.ca + dy * g.sa) / g.rxd, v = (-dx * g.sa + dy * g.ca) / g.ryd;
        float e = pca_sqrt(u * u + v * v);
        if (!isfinite(e) || e >= 1.0f) continue;
        float rpx = max(e * g.rmax * g.ss, 0.0f);
        int m = (isfinite(rpx) && isfinite(g.theta)) ? clamp(int(ceil(g.theta * rpx / 2.0f)), 2, 64) : 2;
        int start = pi * 2079 + m * (m - 1) / 2 - 1;
        float4 acc = float4(0.0f);
        for (int j = 0; j < m; j++) {
            float2 t = tables[start + j];
            float ru = u * t.y - v * t.x, rv = u * t.x + v * t.y;
            float lu = ru * g.rx * g.ss, lv = rv * g.ry * g.ss;
            pca_add_sample_premul(src, f, float2(g.cx + lu * g.ca - lv * g.sa, g.cy + lu * g.sa + lv * g.ca),
                                  p.clip_origin, p.clip_size, alpha, acc);
        }
        acc /= float(m);
        acc = pca_unpremul(acc, alpha);
        float k = 1.0f - pca_smoothstep(0.85f, 1.0f, e);
        px += (acc - px) * k;
        break;
    }
    dst.write(px, gid);
}

struct pca_path_seg {
    float ax, ay, bx, by;
    float speed, taper, t0, t1;
};

kernel void pca_path_blur(constant pca_frame& f [[buffer(0)]], constant pca_clip_params& p [[buffer(1)]],
                          const device pca_path_seg* segs [[buffer(2)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool alpha = f.alpha != 0u;
    float fx = float(q.x) + 0.5f, fy = float(q.y) + 0.5f;
    float dx = 0.0f, dy = 0.0f, len = 0.0f, ws = 0.0f;
    for (int i = 0; i < p.count; i++) {
        pca_path_seg s = segs[i];
        float sx = s.bx - s.ax, sy = s.by - s.ay;
        float l2 = max(sx * sx + sy * sy, 1e-6f);
        float t = clamp(((fx - s.ax) * sx + (fy - s.ay) * sy) / l2, 0.0f, 1.0f);
        float ex = fx - s.ax - sx * t, ey = fy - s.ay - sy * t;
        float d2 = ex * ex + ey * ey;
        float w = 1.0f / (d2 + 1.0f);
        float l = pca_sqrt(l2);
        float along = s.t0 + (s.t1 - s.t0) * t;
        dx += w * sx / l;
        dy += w * sy / l;
        len += w * s.speed * (1.0f - s.taper * along);
        ws += w;
    }
    float m = pca_sqrt(dx * dx + dy * dy);
    float ln = len / ws;
    if (m < 1e-6f || ln < 0.5f) { dst.write(pca_get(src, f, q), gid); return; }
    float ux = dx / m, uy = dy / m;
    int steps = clamp(int(ceil(ln / 1.5f)) + 1, 2, 64);
    float4 acc = float4(0.0f);
    for (int j = 0; j < steps; j++) {
        float o = ln * (float(j) / float(steps - 1) - 0.5f);
        pca_add_sample_premul(src, f, float2(fx + ux * o, fy + uy * o), p.clip_origin, p.clip_size, alpha, acc);
    }
    acc /= float(steps);
    dst.write(pca_unpremul(acc, alpha), gid);
}
