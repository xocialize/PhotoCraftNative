// Port of photocraft-compose (crates/compose/src/lib.rs, advanced.rs) and photocraft-gpu (compose.wgsl `fs_blend`, `fs_atop`, `fs_adjmix`, `fs_lerp`, `fs_content`, `fs_mask`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The accumulator kernels the DrawOp interpreter dispatches: every op reads its stack inputs
// (textures 0–3), the masks (4, 5) and a leaf (6), and writes a fresh accumulator (7).

#define PCR_IN texture2d<float, access::read>
#define PCR_OUT texture2d<float, access::write>
#define PCR_ARGS constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]]

kernel void pcr_clear(PCR_ARGS, PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    out.write(float4(0.0f), t);
}

kernel void pcr_copy(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    out.write(a.read(t), t);
}

/// The cell's result into the region-sized output at texel offset aux (format conversion included).
kernel void pcr_copy_out(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    out.write(a.read(t), uint2(int2(t) + op.aux));
}

/// The cell's alpha into a region-sized r32Float output at texel offset aux (effect shapes rendered
/// on the GPU: MetalEffects.swift).
kernel void pcr_copy_alpha(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    out.write(float4(a.read(t).a), uint2(int2(t) + op.aux));
}

/// A leaf (layer pixels) with its masks: `.drawTiles`, solid fills (outside value = the colour).
kernel void pcr_draw_leaf(PCR_ARGS, PCR_IN mtex [[texture(4)]], PCR_IN vtex [[texture(5)]], PCR_IN leaf [[texture(6)]],
                          PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 c = pcr_leaf(op, leaf, d);
    if ((op.flags & (PCR_F_MASK | PCR_F_VMASK)) != 0u) c.a *= pcr_mask(op, mtex, vtex, d);
    out.write(c, t);
}

/// (0, 0, 0, mask): knockout shapes, clips, hiding masks.
kernel void pcr_mask_shape(PCR_ARGS, PCR_IN mtex [[texture(4)]], PCR_IN vtex [[texture(5)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    out.write(float4(0.0f, 0.0f, 0.0f, pcr_mask(op, mtex, vtex, d)), t);
}

kernel void pcr_apply_mask(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_IN mtex [[texture(4)]], PCR_IN vtex [[texture(5)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 c = a.read(t);
    c.a *= pcr_mask(op, mtex, vtex, d);
    out.write(c, t);
}

/// `blend_into_fill`: B blended into the backdrop A (Dissolve, the special eight, text gamma, Lab).
kernel void pcr_composite(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_IN b [[texture(1)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 bd = a.read(t);
    float4 s = b.read(t);
    if (s.a <= 0.0f) { out.write(bd, t); return; }
    bool lab = (op.flags & PCR_F_LAB) != 0u; uint hdr = pcr_sp(op);
    bool special = op.fill < 1.0f && pcr_fill_is_special(op.mode);
    if (special) {
        out.write(pcr_composite_fill(op.mode, bd, s, op.opacity, op.fill, op.gamma, lab, hdr), t);
        return;
    }
    float opacity = op.opacity * op.fill;
    if (op.mode == PC_DISSOLVE) {
        s.a = pcr_dissolve_draws(d, op.opacity, op.fill, s.a) ? 1.0f : 0.0f;
        out.write(pcr_composite(PC_NORMAL, bd, s, 1.0f, lab, hdr), t);
        return;
    }
    out.write(pcr_composite_gamma(op.mode, bd, s, opacity, op.gamma, lab, hdr), t);
}

/// `composite_atop`: B over the base A treated as opaque, keeping the base's alpha.
kernel void pcr_atop(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_IN b [[texture(1)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 base = a.read(t);
    if (base.a <= 0.0f) { out.write(base, t); return; }
    float4 r = pcr_composite_gamma(op.mode, float4(base.rgb, 1.0f), b.read(t), op.opacity * op.fill, op.gamma,
                                   (op.flags & PCR_F_LAB) != 0u, pcr_sp(op));
    out.write(float4(r.rgb, base.a), t);
}

/// An adjustment layer: the adjusted B mixed over the backdrop A by blend mode × opacity × mask.
kernel void pcr_adjust_mix(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_IN b [[texture(1)]], PCR_IN mtex [[texture(4)]],
                           PCR_IN vtex [[texture(5)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 bd = a.read(t);
    float k = op.opacity * pcr_mask(op, mtex, vtex, d);
    if (k <= 0.0f) { out.write(bd, t); return; }
    if ((op.flags & PCR_F_COVERAGE) != 0u && op.mode == PC_NORMAL) {
        // Colour and coverage mixed premultiplied (a blur spreads into clear pixels).
        float4 ad = b.read(t);
        float alpha = bd.a + (ad.a - bd.a) * k;
        float3 pb = bd.rgb * bd.a, pa = ad.rgb * ad.a;
        float3 c = pb + (pa - pb) * k;
        out.write(alpha > 0.0f ? float4(precise::divide(c.x, alpha), precise::divide(c.y, alpha), precise::divide(c.z, alpha), alpha) : float4(0.0f), t);
        return;
    }
    float3 bl = pcr_blend_rgb(op.mode, bd.rgb, b.read(t).rgb, pcr_sp(op));
    out.write(float4(bd.rgb + (bl - bd.rgb) * k, bd.a), t);
}

kernel void pcr_quantize(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float q = op.p[0].x;
    out.write(floor(a.read(t) * q + 0.5f) / q, t);
}

/// A pass-through group's result B mixed back toward the backdrop A by opacity × mask.
kernel void pcr_pass_mix(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_IN b [[texture(1)]], PCR_IN mtex [[texture(4)]],
                         PCR_IN vtex [[texture(5)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 pa = a.read(t), pb = b.read(t);
    float k = op.opacity * pcr_mask(op, mtex, vtex, d);
    float wa = pa.a * (1.0f - k), wb = pb.a * k;
    float alpha = wa + wb;
    out.write(alpha > 0.0f ? float4((pa.rgb * wa + pb.rgb * wb) / alpha, alpha) : float4(0.0f), t);
}

inline float pcr_ramp(float lo, float hi, float x) {
    if (hi <= lo) return x >= lo ? 1.0f : 0.0f;
    return clamp((x - lo + 1.0f) / (hi - lo + 1.0f), 0.0f, 1.0f);
}

/// `BlendIfMath.rangeWeight`: r = (black low, black high, white low, white high).
inline float pcr_range_weight(float4 r, float v) {
    return pcr_ramp(r.x, r.y, v) * pcr_ramp(255.0f - r.w, 255.0f - r.z, 255.0f - v);
}

inline float pcr_blend_if_side(constant float4* ranges, int side, float4 p, bool rgb, bool ps8) {
    float3 v = clamp(p.rgb, 0.0f, 1.0f) * 255.0f;
    if (ps8) v = round(v);
    if (rgb) {
        float gray = 0.30f * v.r + 0.59f * v.g + 0.11f * v.b;
        if (ps8) gray = round(gray);
        float k = pcr_range_weight(ranges[side], gray);
        for (int c = 0; c < 3; c++) k *= pcr_range_weight(ranges[(c + 1) * 2 + side], v[c]);
        return k;
    }
    return pcr_range_weight(ranges[side], v.r) * pcr_range_weight(ranges[2 + side], v.r);
}

/// Channel restrictions (p[0]) then Blend If (ranges: entry × [this, under]) on the composite B
/// over `before` A; C holds the layer's own colours when bound.
kernel void pcr_finish(PCR_ARGS, constant float4* ranges [[buffer(1)]], PCR_IN a [[texture(0)]], PCR_IN b [[texture(1)]],
                       PCR_IN c [[texture(2)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 bd = a.read(t), p = b.read(t);
    if ((op.flags & PCR_F_CHANNELS) != 0u) p.rgb = bd.rgb + (p.rgb - bd.rgb) * op.p[0].xyz;
    if ((op.flags & PCR_F_BLENDIF) != 0u) {
        bool rgb = (op.flags & PCR_F_RGBMODE) != 0u;
        float k = 1.0f;
        bool hasThis = true;
        float4 thisPx = p;
        if ((op.flags & PCR_F_OWN) != 0u) {
            thisPx = c.read(t);
            hasThis = thisPx.a > 0.0f;
        }
        bool ps8 = (op.flags & PCR_F_PS8) != 0u;
        if (hasThis) k *= pcr_blend_if_side(ranges, 0, thisPx, rgb, ps8);
        if (k > 0.0f && bd.a > 0.0f) k *= pcr_blend_if_side(ranges, 1, bd, rgb, ps8);
        if (k < 1.0f) {
            k = max(k, 0.0f);
            float alpha = bd.a + (p.a - bd.a) * k;
            p = alpha > 0.0f ? float4(clamp((bd.rgb * bd.a + (p.rgb * p.a - bd.rgb * bd.a) * k) / alpha, float3(0.0f), float3(1.0f)), alpha)
                             : float4(0.0f);
        }
    }
    out.write(p, t);
}

/// Inside the shape B (its alpha) the backdrop C becomes the target A.
kernel void pcr_knockout_begin(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_IN b [[texture(1)]], PCR_IN c [[texture(2)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 p = c.read(t);
    float k = b.read(t).a;
    if (k > 0.0f) {
        float al = p.a;
        p = pcr_mix_clamped(p, a.read(t), min(k, 1.0f));
        if ((op.flags & PCR_F_CLIPALPHA) != 0u) p.a = min(p.a, al);
    }
    out.write(p, t);
}

/// Layer opacity of a knockout: D + (1 − o)(before A − knocked C) inside the shape B.
kernel void pcr_knockout_end(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_IN b [[texture(1)]], PCR_IN c [[texture(2)]],
                             PCR_IN dd [[texture(3)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 p = dd.read(t);
    if (b.read(t).a > 0.0f) {
        float rest = 1.0f - clamp(op.opacity, 0.0f, 1.0f);
        float4 pm = pcr_premul(p) + rest * (pcr_premul(a.read(t)) - pcr_premul(c.read(t)));
        float al = clamp(pm.a, 0.0f, 1.0f);
        p = al > 0.0f ? float4(clamp(pm.rgb / al, float3(0.0f), float3(1.0f)), al) : float4(0.0f);
    }
    out.write(p, t);
}

/// mix(before A, after B, shape C alpha × p[0].x).
kernel void pcr_mix_by(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_IN b [[texture(1)]], PCR_IN c [[texture(2)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float m = c.read(t).a * op.p[0].x;
    float4 p = b.read(t);
    if (m < 1.0f) p = pcr_mix_clamped(a.read(t), p, max(m, 0.0f));
    out.write(p, t);
}

/// A + (with B − without C), premultiplied.
kernel void pcr_add_difference(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_IN b [[texture(1)]], PCR_IN c [[texture(2)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 pm = pcr_premul(a.read(t)) + pcr_premul(b.read(t)) - pcr_premul(c.read(t));
    float al = clamp(pm.a, 0.0f, 1.0f);
    out.write(al > 0.0f ? float4(clamp(pm.rgb / al, float3(0.0f), float3(1.0f)), al) : float4(0.0f), t);
}

/// B inside the document rect (p[0] = x0, y0, x1, y1), A outside.
kernel void pcr_restrict(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_IN b [[texture(1)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 r = op.p[0];
    bool in = float(d.x) >= r.x && float(d.y) >= r.y && float(d.x) < r.z && float(d.y) < r.w;
    out.write(in ? b.read(t) : a.read(t), t);
}
