// Port of photocraft-compose (crates/compose/src/effects.rs map builders) and photocraft-gpu (fx.rs, compose.wgsl `fs_m*`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Effect-map kernels: single-channel r32Float maps over a layer's effect region (`op.origin` = the
// region origin, `op.size` = the threads), each mirroring one step of the CPU builders in
// EffectMaps.swift. Reads outside a map return 0 (`FxMap.get`). The distance fields come from the
// CPU (DistanceFields.swift), bit for bit the reference's.

#define PCR_MIN texture2d<float, access::read>
#define PCR_MOUT texture2d<float, access::write>

inline float pcr_ra(PCR_MIN t, int2 p, int2 size) { return pcr_inside(p, size) ? t.read(uint2(p)).r : 0.0f; }
inline float4 pcr_mv(float v) { return float4(v, 0.0f, 0.0f, 1.0f); }

/// `FxMap.shifted` by whole pixels: p0 = (dx, dy, outside, invert (1 − v of the source)).
kernel void pcr_m_shift(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], PCR_MIN a [[texture(0)]], PCR_MOUT out [[texture(7)]]) {
    if (int(gid.x) >= op.size.x || int(gid.y) >= op.size.y) return;
    int2 s = int2(gid) - int2(int(op.p[0].x), int(op.p[0].y));
    float v;
    if (!pcr_inside(s, op.size)) {
        v = op.p[0].z;
    } else {
        v = a.read(uint2(s)).r;
        if (op.p[0].w > 0.5f) v = 1.0f - v;
    }
    out.write(pcr_mv(v), gid);
}

/// `dilate`: inside (d < 0) min(A + r, 1), else max(A, clamp(r + 0.5 − d)); B = distances, p0.x = r.
kernel void pcr_m_dilate(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], PCR_MIN a [[texture(0)]], PCR_MIN b [[texture(1)]],
                         PCR_MOUT out [[texture(7)]]) {
    if (int(gid.x) >= op.size.x || int(gid.y) >= op.size.y) return;
    float v = a.read(gid).r, d = b.read(gid).r, r = op.p[0].x;
    out.write(pcr_mv(d < 0.0f ? min(v + r, 1.0f) : max(v, clamp(r + 0.5f - d, 0.0f, 1.0f))), gid);
}

inline float pcr_box_at(PCR_MIN a, bool vertical, int line, int i, int n) {
    if (i < 0 || i >= n) return 0.0f;
    return vertical ? a.read(uint2(line, i)).r : a.read(uint2(i, line)).r;
}

/// One box pass of fractional width along an axis (`EffectMath.boxLine`), zero outside the source:
/// output k reads source position x0 + k. p0 = (axis, r, f, norm), aux = (source length, x0),
/// p1.x = outputs per thread. Thread grid: (segments, lines); `op.size` = (output length, lines).
kernel void pcr_m_box(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], PCR_MIN a [[texture(0)]], PCR_MOUT out [[texture(7)]]) {
    int seg = int(op.p[1].x);
    int k0 = int(gid.x) * seg;
    int line = int(gid.y);
    int outLen = op.size.x;
    if (k0 >= outLen || line >= op.size.y) return;
    bool vertical = op.p[0].x > 0.5f;
    int r = int(op.p[0].y);
    float f = op.p[0].z, norm = op.p[0].w;
    int n = op.aux.x, x0 = op.aux.y;
    int k1 = min(k0 + seg, outLen);
    if (r == 0) {
        for (int k = k0; k < k1; k++) {
            float v = pcr_box_at(a, vertical, line, x0 + k, n);
            if (vertical) out.write(pcr_mv(v), uint2(line, k)); else out.write(pcr_mv(v), uint2(k, line));
        }
        return;
    }
    int xs = x0 + k0;
    float inner = 0.0f;
    for (int i = xs - (r - 1); i <= xs + (r - 1); i++) inner += pcr_box_at(a, vertical, line, i, n);
    for (int k = k0; k < k1; k++) {
        int x = x0 + k;
        float v = (inner + f * (pcr_box_at(a, vertical, line, x - r, n) + pcr_box_at(a, vertical, line, x + r, n))) * norm;
        if (vertical) out.write(pcr_mv(v), uint2(line, k)); else out.write(pcr_mv(v), uint2(k, line));
        inner += pcr_box_at(a, vertical, line, x + r, n) - pcr_box_at(a, vertical, line, x - r + 1, n);
    }
}

/// Precise glow from a distance map: p0 = (solid, soft).
kernel void pcr_m_glow(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], PCR_MIN a [[texture(0)]], PCR_MOUT out [[texture(7)]]) {
    if (int(gid.x) >= op.size.x || int(gid.y) >= op.size.y) return;
    float d = a.read(gid).r + 0.5f;
    float solid = op.p[0].x, soft = op.p[0].y;
    out.write(pcr_mv(d <= solid ? 1.0f : 0.5f * clamp(1.0f - (d - solid) / soft, 0.0f, 1.0f)), gid);
}

/// Last steps of a coverage map: p0 = (|A − B| (satin), invert before the LUT, LUT, invert after
/// it (centre glow)), p1 = (noise amount, × shape S); LUT in buffer(1) (`aux.x` entries).
kernel void pcr_m_finish(constant PCROp& op [[buffer(0)]], device const float* lut [[buffer(1)]], uint2 gid [[thread_position_in_grid]],
                         PCR_MIN a [[texture(0)]], PCR_MIN b [[texture(1)]], PCR_MIN s [[texture(2)]], PCR_MOUT out [[texture(7)]]) {
    if (int(gid.x) >= op.size.x || int(gid.y) >= op.size.y) return;
    float v = a.read(gid).r;
    if (op.p[0].x > 0.5f) v = fabs(v - b.read(gid).r);
    if (op.p[0].y > 0.5f) v = 1.0f - v;
    if (op.p[0].z > 0.5f) v = pcr_lut_at(lut, op.aux.x, v);
    if (op.p[0].w > 0.5f) v = 1.0f - v;
    float amount = op.p[1].x;
    if (amount > 0.0f && v > 1e-5f) {  // EffectMath.noiseFloor
        int2 d = int2(gid) + op.origin;
        v = clamp(v + (pcr_dissolve_noise(d) - 0.5f) * 2.0f * amount, 0.0f, 1.0f);
    }
    if (op.p[1].y > 0.5f) v *= s.read(gid).r;
    out.write(pcr_mv(v), gid);
}

/// Anti-aliased contour (`EffectMath.contourSupersampled`): the mean of the LUT (buffer(1),
/// `aux.x` entries) over 3 × 3 bilinear samples of A at (x + i/3, y + j/3), 0 outside.
kernel void pcr_m_contour_aa(constant PCROp& op [[buffer(0)]], device const float* lut [[buffer(1)]], uint2 gid [[thread_position_in_grid]],
                             PCR_MIN a [[texture(0)]], PCR_MOUT out [[texture(7)]]) {
    if (int(gid.x) >= op.size.x || int(gid.y) >= op.size.y) return;
    int2 p = int2(gid);
    float p00 = pcr_ra(a, p, op.size), p10 = pcr_ra(a, p + int2(1, 0), op.size);
    float p01 = pcr_ra(a, p + int2(0, 1), op.size), p11 = pcr_ra(a, p + int2(1, 1), op.size);
    float acc = 0.0f;
    for (int j = 0; j < 3; j++) {
        float fy = float(j) / 3.0f;
        for (int i = 0; i < 3; i++) {
            float fx = float(i) / 3.0f;
            float v = (p00 * (1.0f - fx) + p10 * fx) * (1.0f - fy) + (p01 * (1.0f - fx) + p11 * fx) * fy;
            acc += pcr_lut_at(lut, op.aux.x, v);
        }
    }
    out.write(pcr_mv(acc / 9.0f), gid);
}

/// Chiselled bevel height from A = inside distance, B = outside distance (`bevelChiselH`):
/// p0 = (paint (0 inner, 1 outer, 2 both), size, soft).
kernel void pcr_m_bevel_h(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], PCR_MIN a [[texture(0)]], PCR_MIN b [[texture(1)]],
                          PCR_MOUT out [[texture(7)]]) {
    if (int(gid.x) >= op.size.x || int(gid.y) >= op.size.y) return;
    float din = a.read(gid).r, dout = b.read(gid).r;
    float size = op.p[0].y;
    bool soft = op.p[0].z > 0.5f;
    float ramp = size + 1.0f;
    float h;
    int paint = int(op.p[0].x);
    if (paint == 1) {
        if (!soft) {
            float top = (size + 2.0f) / ramp;
            h = dout > 0.0f ? clamp((size + 1.5f - dout) / ramp, 0.0f, top) : top;
        } else {
            h = dout > 0.0f ? 1.0f - clamp((dout + 0.5f) / ramp, 0.0f, 1.0f) : (size + 2.0f) / ramp;
        }
    } else if (paint == 2) {
        float halfSize = size / 2.0f + 0.5f;
        h = din > 0.0f ? 0.5f + 0.5f * clamp(din / halfSize, 0.0f, 1.0f) : 0.5f - 0.5f * clamp(dout / halfSize, 0.0f, 1.0f);
    } else if (soft) {
        h = din > 0.0f ? clamp((din + 1.5f) / ramp, 0.0f, (size + 2.0f) / ramp) : 0.0f;
    } else {
        h = din > 0.0f ? clamp((din + 0.5f) / ramp, 0.0f, 1.0f) : 0.0f;
    }
    out.write(pcr_mv(h), gid);
}

/// Bevel texture: A + k × luminance × alpha of the pattern (1 − that inverted); p0 = (k, invert),
/// p1 = placement, p2 = (1 / scale, w, h).
kernel void pcr_m_bevel_tex(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], PCR_MIN a [[texture(0)]],
                            texture2d<float, access::read> pat [[texture(6)]], PCR_MOUT out [[texture(7)]]) {
    if (int(gid.x) >= op.size.x || int(gid.y) >= op.size.y) return;
    int2 d = int2(gid) + op.origin;
    float4 c = pcr_pattern(pat, op.p[1], op.p[2], float(d.x) + 0.5f, float(d.y) + 0.5f);
    float l = (0.299f * c.r + 0.587f * c.g + 0.114f * c.b) * c.a;
    if (op.p[0].y > 0.5f) l = 1.0f - l;
    out.write(pcr_mv(a.read(gid).r + op.p[0].x * l), gid);
}

inline bool pcr_on_bevel(PCR_MIN h, int2 p, int2 size, bool reachPast) {
    const float eps = 1e-5f;
    if (pcr_ra(h, p, size) > eps) return true;
    if (!reachPast) return false;
    return pcr_ra(h, p + int2(1, 0), size) > eps || pcr_ra(h, p - int2(1, 0), size) > eps || pcr_ra(h, p + int2(0, 1), size) > eps ||
           pcr_ra(h, p - int2(0, 1), size) > eps;
}

/// One shading value (`bevelMaps` / `shadeInto`): highlight (which = 0) or shadow of the height map
/// at `p` for gradient scale `depth`, times `region`, through the gloss contour.
inline float pcr_bevel_part(PCR_MIN h, int2 p, int2 size, float4 lv, float depth, float region, bool shadow, bool useLut,
                            device const float* lut, int n) {
    float gx = (pcr_ra(h, p + int2(1, 0), size) - pcr_ra(h, p - int2(1, 0), size)) * 0.5f * depth;
    float gy = (pcr_ra(h, p + int2(0, 1), size) - pcr_ra(h, p - int2(0, 1), size)) * 0.5f * depth;
    float3 nn = float3(-gx, -gy, 1.0f);
    float len = sqrt(nn.x * nn.x + nn.y * nn.y + 1.0f);
    float shade = (nn.x * lv.x + nn.y * lv.y + nn.z * lv.z) / len;
    float se = lv.w;
    float k = shade - se;
    float v = 0.0f;
    if (shadow) {
        if (k <= 0.0f) v = clamp(-k / max(se, 1e-3f), 0.0f, 1.0f) * region;
    } else if (k > 0.0f) {
        v = clamp(k / max(1.0f - se, 1e-3f), 0.0f, 1.0f) * region;
    }
    return useLut ? pcr_lut_at(lut, n, v) : v;
}

/// Bevel shading of the height map A over the shape S: p0 = (light vector, sin altitude),
/// p1 = (depth, region (0 inside, 1 outside, 2 emboss, 3 pillow emboss), shadow, contour),
/// p2.x = shade one pixel past the reach (emboss and outer chisel).
kernel void pcr_m_bevel_shade(constant PCROp& op [[buffer(0)]], device const float* lut [[buffer(1)]], uint2 gid [[thread_position_in_grid]],
                              PCR_MIN h [[texture(0)]], PCR_MIN s [[texture(2)]], PCR_MOUT out [[texture(7)]]) {
    if (int(gid.x) >= op.size.x || int(gid.y) >= op.size.y) return;
    int2 p = int2(gid);
    float sv = s.read(gid).r;
    float4 lv = op.p[0];
    float depth = op.p[1].x;
    int kind = int(op.p[1].y);
    bool shadow = op.p[1].z > 0.5f, useLut = op.p[1].w > 0.5f;
    bool reachPast = op.p[2].x > 0.5f;
    int n = op.aux.x;
    float outside = (sv < 1.0f - 0.5f / 255.0f && pcr_on_bevel(h, p, op.size, reachPast)) ? 1.0f : 0.0f;
    float v;
    if (kind == 0) {
        v = pcr_bevel_part(h, p, op.size, lv, depth, sv, shadow, useLut, lut, n);
    } else if (kind == 1) {
        v = pcr_bevel_part(h, p, op.size, lv, depth, outside, shadow, useLut, lut, n);
    } else {
        float inner = pcr_bevel_part(h, p, op.size, lv, depth, sv, shadow, useLut, lut, n);
        float od = kind == 3 ? -depth : depth;
        float outer = pcr_bevel_part(h, p, op.size, lv, od, outside, shadow, useLut, lut, n);
        v = (sv > 0.5f / 255.0f ? inner : 0.0f) + outer * (1.0f - min(sv, 1.0f));
    }
    out.write(pcr_mv(v), gid);
}
