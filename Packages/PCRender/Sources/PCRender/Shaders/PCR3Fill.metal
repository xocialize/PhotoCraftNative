// Port of photocraft-compose (crates/compose/src/gradient_fill.rs, pattern.rs, effects.rs `gradient_t`) and photocraft-gpu (compose.wgsl `gradient_t`, `pattern_sample`, `layer_texel`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Gradient and pattern paint shared by fill layers and layer effects. Ramps are evaluated from
// their stops (not a sampled LUT), so the GPU matches `GradientMath` exactly.

/// Gradient geometry: g0 = (angle°, scale, reverse, style), g1 = frame (x0, y0, w, h), g2.xy = centre offset.
inline float pcr_gradient_t(float4 g0, float4 g1, float2 off, float px, float py) {
    float w = max(g1.z, 1.0f), h = max(g1.w, 1.0f);
    float cx = g1.x + w / 2.0f + off.x * w;
    float cy = g1.y + h / 2.0f + off.y * h;
    float a = g0.x * (M_PI_F / 180.0f);
    float s = sin(a), c = cos(a);
    float dx = px - cx, dy = py - cy;
    float along = dx * c - dy * s;
    float across = dx * s + dy * c;
    float len = max(sqrt((c * w) * (c * w) + (s * h) * (s * h)), 1.0f) * max(g0.y, 1e-3f);
    float chord = max(min(w / max(fabs(c), 1e-6f), h / max(fabs(s), 1e-6f)), 1.0f) * max(g0.y, 1e-3f);
    float corner = 0.5f * (c - s);
    float t;
    switch (int(g0.w)) {
        case 1: t = sqrt(dx * dx + dy * dy) / (len / 2.0f); break;
        case 2: t = pcr_rem_euclid((a - atan2(-dy, dx)) / (2.0f * M_PI_F), 1.0f); break;
        case 3: t = fabs((along - corner) / (chord / 2.0f)); break;
        case 4: t = (fabs(along) + fabs(across)) / (len / 2.0f); break;
        default: t = (along - corner) / chord + 0.5f; break;
    }
    t = clamp(t, 0.0f, 1.0f);
    return g0.z > 0.5f ? 1.0f - t : t;
}

inline float3 pcr_stops3(device const float4* s, int n, float t) {
    if (n == 0) return float3(t);
    if (n == 1 || t <= s[0].x) return s[0].yzw;
    for (int i = 0; i < n - 1; i++) {
        if (t <= s[i + 1].x) {
            float k = s[i + 1].x > s[i].x ? (t - s[i].x) / (s[i + 1].x - s[i].x) : 0.0f;
            return s[i].yzw + (s[i + 1].yzw - s[i].yzw) * k;
        }
    }
    return s[n - 1].yzw;
}

/// Effect gradient (`GradientMath.EffectRamp`): `nc` colour stops (loc, r, g, b), then `no` opacity
/// stops (loc, a, 0, 0).
inline float4 pcr_effect_ramp(device const float4* s, int nc, int no, float t) {
    float3 c = pcr_stops3(s, nc, t);
    float a = no == 0 ? 1.0f : pcr_stops3(s + nc, no, t).x;
    return float4(c, a);
}

inline float pcr_midpoint_remap(float u, float m0) {
    float m = clamp(m0, 0.05f, 0.95f);
    if (fabs(m - 0.5f) < 1e-6f) return u;
    return u <= m ? 0.5f * u / m : 0.5f + 0.5f * (u - m) / (1.0f - m);
}

/// Fill gradient (`GradientMath.FillRamp`): `nc` colour stops (loc, r, g, b), `nc` (alpha, midpoint,
/// 0, 0), then `no` opacity stops (loc, opacity, 0, 0).
inline float4 pcr_fill_ramp(device const float4* s, int nc, int no, float t) {
    float4 c = float4(0.0f);
    if (nc > 0) {
        device const float4* aux = s + nc;
        if (t <= s[0].x) {
            c = float4(s[0].yzw, aux[0].x);
        } else {
            c = float4(s[nc - 1].yzw, aux[nc - 1].x);
            for (int i = 0; i < nc - 1; i++) {
                if (t <= s[i + 1].x) {
                    float u = s[i + 1].x > s[i].x ? (t - s[i].x) / (s[i + 1].x - s[i].x) : 0.0f;
                    float k = pcr_midpoint_remap(u, aux[i].y);
                    float4 a = float4(s[i].yzw, aux[i].x), b = float4(s[i + 1].yzw, aux[i + 1].x);
                    c = a + (b - a) * k;
                    break;
                }
            }
        }
    }
    if (no > 0) {
        device const float4* o = s + 2 * nc;
        float op = o[no - 1].y;
        if (t <= o[0].x) {
            op = o[0].y;
        } else {
            for (int i = 0; i < no - 1; i++) {
                if (t <= o[i + 1].x) {
                    float u = o[i + 1].x > o[i].x ? (t - o[i].x) / (o[i + 1].x - o[i].x) : 0.0f;
                    op = o[i].y + (o[i + 1].y - o[i].y) * u;
                    break;
                }
            }
        }
        c.a *= op;
    }
    return c;
}

inline int pcr_wrap(int i, int n) { return ((i % n) + n) % n; }

/// `PatternTile.sample` through `PatternPlacement.map`: pl = (origin.x, origin.y, cos, sin),
/// q = (1 / scale, tile w, tile h); `pat` holds premultiplied RGBA.
inline float4 pcr_pattern(texture2d<float, access::read> pat, float4 pl, float4 q, float px, float py) {
    float dx = px - pl.x, dy = py - pl.y;
    float u = (dx * pl.z - dy * pl.w) * q.x - 0.5f;
    float v = (dx * pl.w + dy * pl.z) * q.x - 0.5f;
    float x0 = floor(u), y0 = floor(v);
    float fx = u - x0, fy = v - y0;
    int tw = int(q.y), th = int(q.z);
    int ix = int(x0), iy = int(y0);
    float4 acc = float4(0.0f);
    float wy[2] = {1.0f - fy, fy};
    float wx[2] = {1.0f - fx, fx};
    for (int j = 0; j < 2; j++) {
        if (wy[j] == 0.0f) continue;
        for (int i = 0; i < 2; i++) {
            if (wx[i] == 0.0f) continue;
            acc += pat.read(uint2(pcr_wrap(ix + i, tw), pcr_wrap(iy + j, th))) * (wx[i] * wy[j]);
        }
    }
    if (acc.a <= 0.0f) return float4(0.0f);
    return float4(acc.rgb / acc.a, min(acc.a, 1.0f));
}

/// Fill content rounded to the document's stored depth (`q` steps per unit; 0 = float).
inline float4 pcr_fill_store(float4 c, float q) {
    return q > 0.0f ? floor(clamp(c, 0.0f, 1.0f) * q + 0.5f) / q : c;
}

/// A gradient fill layer: p0 = geometry, p1 = frame, p2.xy = offset, p2.z = quantum, p2.w = stored
/// depth; aux = (colour stops, opacity stops); masks as for `pcr_draw_leaf`.
kernel void pcr_fill_gradient(constant PCROp& op [[buffer(0)]], device const float4* stops [[buffer(1)]], uint2 gid [[thread_position_in_grid]],
                              texture2d<float, access::read> mtex [[texture(4)]], texture2d<float, access::read> vtex [[texture(5)]],
                              texture2d<float, access::write> out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float tt = pcr_gradient_t(op.p[0], op.p[1], op.p[2].xy, float(d.x) + 0.5f, float(d.y) + 0.5f);
    float4 c = pcr_fill_ramp(stops, op.aux.x, op.aux.y, tt);
    if ((op.flags & PCR_F_DITHER) != 0u) {
        float n = (pc_dither_noise(d.x, d.y) - 0.5f) / 255.0f;
        for (int i = 0; i < 3; i++) {
            float v = clamp(c[i] + n, 0.0f, 1.0f);
            if ((op.flags & PCR_F_QUANT) != 0u) v = floor(v * op.p[2].z + 0.5f) / op.p[2].z;
            c[i] = v;
        }
    }
    c = pcr_fill_store(c, op.p[2].w);
    if ((op.flags & (PCR_F_MASK | PCR_F_VMASK)) != 0u) c.a *= pcr_mask(op, mtex, vtex, d);
    out.write(c, t);
}

/// A pattern fill layer: p0 = placement, p1 = (1 / scale, w, h, stored depth).
kernel void pcr_fill_pattern(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]],
                             texture2d<float, access::read> mtex [[texture(4)]], texture2d<float, access::read> vtex [[texture(5)]],
                             texture2d<float, access::read> pat [[texture(6)]], texture2d<float, access::write> out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 c = pcr_fill_store(pcr_pattern(pat, op.p[0], op.p[1], float(d.x) + 0.5f, float(d.y) + 0.5f), op.p[1].w);
    if ((op.flags & (PCR_F_MASK | PCR_F_VMASK)) != 0u) c.a *= pcr_mask(op, mtex, vtex, d);
    out.write(c, t);
}
