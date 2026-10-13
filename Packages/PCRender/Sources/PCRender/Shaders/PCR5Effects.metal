// Port of photocraft-compose (crates/compose/src/effects.rs `composite_with_effects`) and photocraft-gpu (compose.wgsl `fs_fxinit`, `fs_fxpaint`, `fs_fxstroke`, `fs_fxstrokeend`, `fs_fxmerge`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Compositing a layer with its effects on accumulator textures. Textures: 0 the buffer being
// painted (exterior W or layer L), 1 content / accumulated stroke colour, 2 the effect shape
// (r32Float, chunk space), 3 the vector stroke / the layer L, 4–5 masks, 6 an effect map (region
// space: `op.mapOrigin` / `op.mapSize`), 8 a pattern, 10 stroke coverage; out 7 (and 9).

constant uint PCR_FX_KNOCK = 1u << 16;     // coverage × (1 − shape) / (1 − fill × shape), p3.z = 1 − fill
constant uint PCR_FX_SHAPELESS = 1u << 17; // Transparency Shapes Layer off
constant uint PCR_FX_OUTLINE = 1u << 18;   // filled-shape outline joins the shape
constant uint PCR_FX_VSTROKE = 1u << 19;   // a vector stroke is bound (3)
constant uint PCR_FX_RELATIVE = 1u << 20;  // layer alpha relative to the shape
constant uint PCR_FX_SHAPEALPHA = 1u << 21;// scale alpha by the shape (else by p0.x)
constant uint PCR_FX_FIRST = 1u << 22;     // first outside stroke (nothing accumulated)
constant uint PCR_FX_VECTOR = 1u << 23;    // shape layer: outside strokes never inside
constant uint PCR_FX_NOPAINT = 1u << 24;   // missing pattern: the stroke keeps the result as is
constant uint PCR_FX_SPLIT = 1u << 28;     // outside strokes take the rest of covered pixels (pcr_fx_merge_split)

constant float PCR_INSIDE_EPS = 0.5f / 255.0f;

inline float pcr_map(constant PCROp& op, texture2d<float, access::read> map, int2 d, float outside) {
    int2 q = d - op.mapOrigin;
    return pcr_inside(q, op.mapSize) ? map.read(uint2(q)).r : outside;
}

/// The effect paint colour at document pixel `d`: aux.y = 0 colour, 1 gradient, 2 pattern.
inline float4 pcr_fx_color(constant PCROp& op, device const float4* stops, texture2d<float, access::read> pat, int2 d) {
    int kind = op.aux.y;
    float px = float(d.x) + 0.5f, py = float(d.y) + 0.5f;
    if (kind == 1) return pcr_effect_ramp(stops, int(op.p[6].x), int(op.p[6].y), pcr_gradient_t(op.p[0], op.p[1], op.p[2].xy, px, py));
    if (kind == 2) return pcr_pattern(pat, op.p[4], op.p[5], px, py);
    return op.color;
}

/// The effect shape: the content's alpha (joined with the vector stroke and its mask), the outline
/// map, or (Transparency Shapes Layer off) the map alone.
kernel void pcr_fx_shape(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], texture2d<float, access::read> content [[texture(1)]],
                         texture2d<float, access::read> vs [[texture(3)]], texture2d<float, access::read> mtex [[texture(4)]],
                         texture2d<float, access::read> vtex [[texture(5)]], texture2d<float, access::read> map [[texture(6)]],
                         texture2d<float, access::write> out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float ca = content.read(t).a;
    float u = ca;
    if ((op.flags & PCR_FX_VSTROKE) != 0u) {
        float km = pcr_mask(op, mtex, vtex, d);
        u = km * (ca + vs.read(t).a * (1.0f - ca));
    }
    float v;
    if ((op.flags & PCR_FX_SHAPELESS) != 0u) v = pcr_map(op, map, d, 0.0f);
    else if ((op.flags & PCR_FX_OUTLINE) != 0u) v = max(pcr_map(op, map, d, 0.0f), u);
    else v = u;
    out.write(float4(v, 0.0f, 0.0f, 1.0f), t);
}

/// The layer before its interior effects: its colour, alpha = fill (p0.x) inside the shape (relative
/// to it within an outline / with a vector stroke).
kernel void pcr_fx_lay(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], texture2d<float, access::read> content [[texture(1)]],
                       texture2d<float, access::read> shape [[texture(2)]], texture2d<float, access::read> mtex [[texture(4)]],
                       texture2d<float, access::read> vtex [[texture(5)]], texture2d<float, access::write> out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 p = content.read(t);
    float a = shape.read(t).r;
    float cf = op.p[0].x;
    float alpha = 0.0f;
    if (a > PCR_INSIDE_EPS) {
        if ((op.flags & PCR_FX_RELATIVE) != 0u) {
            float km = (op.flags & PCR_FX_VSTROKE) != 0u ? pcr_mask(op, mtex, vtex, d) : 1.0f;
            alpha = cf * min(km * p.a / a, 1.0f);
        } else {
            alpha = cf;
        }
    }
    out.write(float4(p.rgb, alpha), t);
}

/// One effect paint into the buffer 0: coverage (aux.x: 0 map, 1 inside the shape, 2 map relative
/// to the shape, 3 inside-stroke band of width p3.y), knockout, then colour / gradient / pattern
/// (aux.y 0–2) or a glow's gradient (aux.y 3, gain p3.x) composited at coverage × opacity.
kernel void pcr_fx_paint(constant PCROp& op [[buffer(0)]], device const float4* stops [[buffer(1)]], uint2 gid [[thread_position_in_grid]],
                         texture2d<float, access::read> target [[texture(0)]], texture2d<float, access::read> shape [[texture(2)]],
                         texture2d<float, access::read> map [[texture(6)]], texture2d<float, access::read> pat [[texture(8)]],
                         texture2d<float, access::write> out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 dst = target.read(t);
    float a = shape.read(t).r;
    bool inside = a > PCR_INSIDE_EPS;
    float m;
    switch (op.aux.x) {
        case 1: m = inside ? 1.0f : 0.0f; break;
        case 2: { float mm = pcr_map(op, map, d, op.p[3].w); m = inside ? min(mm / a, 1.0f) : 0.0f; break; }
        case 3: { float dv = pcr_map(op, map, d, 0.0f); m = inside ? clamp(op.p[3].y + 0.5f - dv, 0.0f, 1.0f) : 0.0f; break; }
        default: m = pcr_map(op, map, d, op.p[3].w); break;
    }
    if ((op.flags & PCR_FX_KNOCK) != 0u) {
        // `EffectsCPU.knockout` (p3.z = 1 − fill).
        float ka = clamp(a, 0.0f, 1.0f), kf = clamp(1.0f - op.p[3].z, 0.0f, 1.0f);
        float kd = 1.0f - kf * ka;
        m *= kd <= 1e-6f ? 1.0f : (1.0f - ka) / kd;
    }
    bool lab = (op.flags & PCR_F_LAB) != 0u; uint hdr = pcr_sp(op);
    if (op.aux.y == 3) {
        float k = min(m * op.p[3].x, 1.0f) * op.opacity;
        if (k <= 0.0f) { out.write(dst, t); return; }
        float4 c = pcr_effect_ramp(stops, int(op.p[6].x), int(op.p[6].y), 1.0f - clamp(m, 0.0f, 1.0f));
        out.write(pcr_composite(op.mode, dst, float4(c.rgb, c.a * k), 1.0f, lab, hdr), t);
        return;
    }
    float k = m * op.opacity;
    if (k <= 0.0f) { out.write(dst, t); return; }
    float4 c = pcr_fx_color(op, stops, pat, d);
    out.write(pcr_composite(op.mode, dst, float4(c.rgb, c.a * k), 1.0f, lab, hdr), t);
}

/// Alpha × min(shape, 1) (PCR_FX_SHAPEALPHA) or × max(p0.x, 0) (Blend Interior Effects as Group).
kernel void pcr_fx_scale_alpha(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], texture2d<float, access::read> target [[texture(0)]],
                               texture2d<float, access::read> content [[texture(1)]], texture2d<float, access::read> shape [[texture(2)]],
                               texture2d<float, access::write> out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 p = target.read(t);
    if ((op.flags & PCR_FX_RELATIVE) != 0u) {
        // The content's own transparency within the shape (grouped interior effects drawn atop it).
        float a = shape.read(t).r;
        p.a *= a > PCR_INSIDE_EPS ? min(content.read(t).a / a, 1.0f) : 1.0f;
    } else {
        p.a *= (op.flags & PCR_FX_SHAPEALPHA) != 0u ? min(shape.read(t).r, 1.0f) : max(op.p[0].x, 0.0f);
    }
    out.write(p, t);
}

/// A stroked shape's vector stroke over the layer, relative to the shape, at fill p0.x.
kernel void pcr_fx_vstroke(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], texture2d<float, access::read> target [[texture(0)]],
                           texture2d<float, access::read> shape [[texture(2)]], texture2d<float, access::read> vs [[texture(3)]],
                           texture2d<float, access::read> mtex [[texture(4)]], texture2d<float, access::read> vtex [[texture(5)]],
                           texture2d<float, access::write> out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 p = target.read(t);
    float4 s = vs.read(t);
    float a = shape.read(t).r;
    if (s.a > 0.0f && a > PCR_INSIDE_EPS) {
        float km = pcr_mask(op, mtex, vtex, d);
        p = pcr_composite(PC_NORMAL, p, float4(s.rgb, op.p[0].x * min(km * s.a / a, 1.0f)), 1.0f, (op.flags & PCR_F_LAB) != 0u, pcr_sp(op));
    }
    out.write(p, t);
}

inline float pcr_outline_share(float cov, float l) {
    float outside = max(1.0f - clamp(cov, 0.0f, 1.0f), 0.0f);
    float rest = 1.0f - clamp(l, 0.0f, 1.0f);
    return rest <= 1e-6f ? (outside > 0.0f ? 1.0f : 0.0f) : min(outside / rest, 1.0f);
}

/// One outside stroke: its share (band of width p3.y × opacity not yet covered) of the stroke
/// blended over the exterior result 0 at full coverage, accumulated premultiplied (1 → 7) with
/// the coverage (10 → 9). 3 = the layer (its alpha), 6 = the outside distance field.
kernel void pcr_fx_stroke_acc(constant PCROp& op [[buffer(0)]], device const float4* stops [[buffer(1)]], uint2 gid [[thread_position_in_grid]],
                              texture2d<float, access::read> base [[texture(0)]], texture2d<float, access::read> accIn [[texture(1)]],
                              texture2d<float, access::read> shape [[texture(2)]], texture2d<float, access::read> lay [[texture(3)]],
                              texture2d<float, access::read> map [[texture(6)]], texture2d<float, access::read> pat [[texture(8)]],
                              texture2d<float, access::read> coverIn [[texture(10)]], texture2d<float, access::write> accOut [[texture(7)]],
                              texture2d<float, access::write> coverOut [[texture(9)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    bool first = (op.flags & PCR_FX_FIRST) != 0u;
    float cover = first ? 0.0f : coverIn.read(t).r;
    float4 acc = first ? float4(0.0f) : accIn.read(t);
    float a = shape.read(t).r;
    float la = lay.read(t).a;
    float dv = pcr_map(op, map, d, 1.0e9f);
    float band = clamp(op.p[3].y + 0.5f - dv, 0.0f, 1.0f);
    float kk;
    if ((op.flags & PCR_FX_OUTLINE) != 0u) {
        kk = band * pcr_outline_share(a, la);
    } else if (a > PCR_INSIDE_EPS) {
        if ((op.flags & PCR_FX_VECTOR) != 0u) kk = 0.0f;
        else if ((op.flags & PCR_FX_SPLIT) != 0u) kk = 1.0f;
        else {
            float c = clamp(la, 0.0f, 1.0f);
            float outside = 1.0f - clamp(a, 0.0f, 1.0f);
            kk = c >= 1.0f ? (outside > 0.0f ? 1.0f : 0.0f) : clamp(outside / (1.0f - c), 0.0f, 1.0f);
        }
    } else {
        kk = band;
    }
    float share = kk * op.opacity * (1.0f - cover);
    if (share > 0.0f) {
        float4 b = base.read(t);
        if ((op.flags & PCR_FX_NOPAINT) == 0u) {
            float4 c = pcr_fx_color(op, stops, pat, d);
            b = pcr_composite(op.mode, b, c, 1.0f, (op.flags & PCR_F_LAB) != 0u, pcr_sp(op));
        }
        acc += share * pcr_premul(b);
    }
    accOut.write(acc, t);
    coverOut.write(float4(cover + share, 0.0f, 0.0f, 1.0f), t);
}

/// Outside strokes resolved over the exterior result 0: 1 = accumulated colour, 10 = coverage.
kernel void pcr_fx_stroke_resolve(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], texture2d<float, access::read> w0 [[texture(0)]],
                                  texture2d<float, access::read> accIn [[texture(1)]], texture2d<float, access::read> coverIn [[texture(10)]],
                                  texture2d<float, access::write> out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 w = w0.read(t);
    float c = coverIn.read(t).r;
    if (c > 0.0f) {
        float4 acc = accIn.read(t);
        float k = 1.0f - min(c, 1.0f);
        float alpha = w.a * k + acc.a;
        if (alpha > 0.0f) w = float4((w.rgb * w.a * k + acc.rgb) / alpha, min(alpha, 1.0f));
    }
    out.write(w, t);
}

/// The layer 3 (with interior effects) over the exterior result 0 in the layer's mode.
kernel void pcr_fx_merge(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], texture2d<float, access::read> w0 [[texture(0)]],
                         texture2d<float, access::read> lay [[texture(3)]], texture2d<float, access::write> out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 w = w0.read(t), l = lay.read(t);
    if (l.a > 0.0f) w = pcr_composite_gamma(op.mode, w, l, 1.0f, op.gamma, (op.flags & PCR_F_LAB) != 0u, pcr_sp(op));
    out.write(w, t);
}

/// The layer 3 over the exterior result with outside strokes: each pixel mixes the stroked result
/// 0 with the layer blended over the unstroked one 1 by the shape's coverage 2.
kernel void pcr_fx_merge_split(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], texture2d<float, access::read> w0 [[texture(0)]],
                               texture2d<float, access::read> pre [[texture(1)]], texture2d<float, access::read> shape [[texture(2)]],
                               texture2d<float, access::read> lay [[texture(3)]], texture2d<float, access::write> out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 w = w0.read(t);
    float a = clamp(shape.read(t).r, 0.0f, 1.0f);
    if (a > 0.0f) {
        float4 b = pre.read(t), l = lay.read(t);
        l.a = min(l.a / a, 1.0f);
        if (l.a > 0.0f) b = pcr_composite_gamma(op.mode, b, l, 1.0f, op.gamma, (op.flags & PCR_F_LAB) != 0u, pcr_sp(op));
        w = pcr_mix_premul(w, b, a);
    }
    out.write(w, t);
}

/// Layer opacity against the backdrop 1: mix_premul(backdrop, W 0, opacity); atop (clipped layer):
/// against the opaque base, keeping its alpha.
kernel void pcr_fx_final(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], texture2d<float, access::read> w0 [[texture(0)]],
                         texture2d<float, access::read> backdrop [[texture(1)]], texture2d<float, access::write> out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 w = w0.read(t), b = backdrop.read(t);
    if ((op.flags & PCR_F_ATOP) != 0u) {
        float4 o = pcr_mix_premul(float4(b.rgb, 1.0f), w, op.opacity);
        out.write(b.a > 0.0f ? float4(o.rgb, b.a) : b, t);
    } else {
        out.write(pcr_mix_premul(b, w, op.opacity), t);
    }
}

/// An opaque copy of the base 1 (effects of a clipped layer paint over it).
kernel void pcr_fx_opaque(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], texture2d<float, access::read> base [[texture(1)]],
                          texture2d<float, access::write> out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    out.write(float4(base.read(t).rgb, 1.0f), t);
}
