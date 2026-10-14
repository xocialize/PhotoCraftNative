// Filter adjustment layers (AB-T-0258) on the GPU: Grain, Add Noise, and the passes of Gaussian
// and Motion Blur over a backdrop rendered for them. New; the arithmetic of CPU/Filters.swift
// (FilterMath / FilterCPU) step for step, divisions, logarithms and cosines precise, so the GPU
// matches the CPU reference (Grain and the blurs exactly, Gaussian Add Noise within an ulp of
// libm's log and cos). Grain's and Add Noise's hashes are Compositor's (EditorPixelKernels), MIT,
// © 2026 Wonder Assembly LLC.

// ---- patterns (FilterMath) ---------------------------------------------------------------

inline uint pcr_mix32(uint x) {
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

inline float pcr_unit(uint key) { return float(pcr_mix32(key) >> 8) * (1.0f / 16777216.0f); }

inline float pcr_lattice(int ix, int iy, uint seed) {
    uint h = pcr_mix32(as_type<uint>(ix) * 0x9e3779b1u ^ pcr_mix32(as_type<uint>(iy) * 0x85ebca77u ^ seed));
    return precise::divide(float(h & 0xffffu), 65535.0f) + precise::divide(float(h >> 16), 65535.0f) - 1.0f;
}

inline float pcr_grain_field(float u, float v, float scale, uint seed) {
    float su = precise::divide(u, scale), sv = precise::divide(v, scale);
    float cellX = floor(su), cellY = floor(sv);
    float tx = su - cellX, ty = sv - cellY;
    tx = tx * tx * (3.0f - 2.0f * tx);
    ty = ty * ty * (3.0f - 2.0f * ty);
    int ix = int(cellX), iy = int(cellY);
    float n00 = pcr_lattice(ix, iy, seed), n10 = pcr_lattice(ix + 1, iy, seed);
    float n01 = pcr_lattice(ix, iy + 1, seed), n11 = pcr_lattice(ix + 1, iy + 1, seed);
    float top = n00 + (n10 - n00) * tx, bottom = n01 + (n11 - n01) * tx;
    return (top + (bottom - top) * ty) * 1.6f;
}

inline float pcr_clamp255(float v, bool hdr) { return v < 0.0f ? 0.0f : (!hdr && v > 255.0f) ? 255.0f : v; }

/// p[0] = (strength, roughness, size, detail size), p[1].x = document pixels per plan pixel,
/// aux = (seed, fine seed), p[1].y = 1 for a 32-bit document.
inline float3 pcr_grain(float3 c, int2 d, constant PCROp& op) {
    float upp = op.p[1].x;
    bool hdr = op.p[1].y != 0.0f;
    float u = (float(d.x) + 0.5f) * upp, v = (float(d.y) + 0.5f) * upp;
    float smooth = pcr_grain_field(u, v, op.p[0].z, as_type<uint>(op.aux.x));
    float fine = pcr_grain_field(u, v, op.p[0].w, as_type<uint>(op.aux.y));
    float noise = smooth + (fine - smooth) * op.p[0].y;
    float r = c.x * 255.0f, g = c.y * 255.0f, b = c.z * 255.0f;
    float level = precise::divide(0.2126f * r + 0.7152f * g + 0.0722f * b, 255.0f);
    if (level > 1.0f) level = 1.0f;
    if (level < 0.0f) level = 0.0f;
    float delta = noise * op.p[0].x * (0.4f + 2.4f * level * (1.0f - level));
    return float3(precise::divide(pcr_clamp255(r + delta, hdr), 255.0f), precise::divide(pcr_clamp255(g + delta, hdr), 255.0f),
                  precise::divide(pcr_clamp255(b + delta, hdr), 255.0f));
}

/// p[0] = (spread, gaussian, monochromatic, 32-bit document), aux.x = seed.
inline float3 pcr_noise(float3 c, int2 d, constant PCROp& op) {
    bool hdr = op.p[0].w != 0.0f;
    uint px = as_type<uint>(d.x), py = as_type<uint>(d.y);
    uint base = pcr_mix32(as_type<uint>(op.aux.x) ^ pcr_mix32(px * 0x9e3779b9u ^ pcr_mix32(py * 0x85ebca6bu)));
    float spread = op.p[0].x;
    float3 out;
    for (uint ch = 0u; ch < 3u; ++ch) {
        uint key = op.p[0].z != 0.0f ? base : base + ch * 0x9e3779b9u;
        float n;
        if (op.p[0].y != 0.0f) {
            float u1 = pcr_unit(key), u2 = pcr_unit(key ^ 0x68e31da4u);
            n = precise::sqrt(-2.0f * precise::log(1.0f - u1)) * precise::cos(6.2831853f * u2) * spread * (2.0f / 3.0f);
        } else {
            n = (pcr_unit(key) * 2.0f - 1.0f) * spread;
        }
        out[ch] = precise::divide(pcr_clamp255(c[ch] * 255.0f + n, hdr), 255.0f);
    }
    return out;
}

/// Grain (aux.y != 0 … see pcr_grain) or Add Noise on an accumulator, transparent pixels
/// untouched; a native Lab buffer through display RGB (`FilterCPU.pointwise`).
kernel void pcr_filter_grain(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 c = a.read(t);
    if (c.a <= 0.0f) { out.write(c, t); return; }
    if ((op.flags & PCR_F_NLAB) != 0u) { out.write(float4(pcr_lab_norm(pcr_grain(pcr_lab_denorm(c.rgb), d, op)), c.a), t); return; }
    out.write(float4(pcr_grain(c.rgb, d, op), c.a), t);
}

kernel void pcr_filter_noise(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_OUT out [[texture(7)]]) {
    uint2 t; int2 d;
    if (!pcr_coords(op, gid, t, d)) return;
    float4 c = a.read(t);
    if (c.a <= 0.0f) { out.write(c, t); return; }
    if ((op.flags & PCR_F_NLAB) != 0u) { out.write(float4(pcr_lab_norm(pcr_noise(pcr_lab_denorm(c.rgb), d, op)), c.a), t); return; }
    out.write(float4(pcr_noise(c.rgb, d, op), c.a), t);
}

// ---- blurs (FilterCPU.blur) ---------------------------------------------------------------
// Plain textures (not cell accumulators): thread (x, y) is texel (x, y) of the output.

/// Straight → premultiplied over the backdrop area; texels outside the canvas cleared.
/// aux = the area's document origin, p[0] = canvas (x0, y0, x1, y1).
kernel void pcr_blur_premultiply(PCR_ARGS, PCR_IN a [[texture(0)]], PCR_OUT out [[texture(7)]]) {
    if (int(gid.x) >= op.size.x || int(gid.y) >= op.size.y) return;
    int2 d = int2(gid) + op.aux;
    bool inside = float(d.x) >= op.p[0].x && float(d.y) >= op.p[0].y && float(d.x) < op.p[0].z && float(d.y) < op.p[0].w;
    float4 v = a.read(gid);
    out.write(inside ? float4(v.rgb * v.a, v.a) : float4(0.0f), gid);
}

/// The horizontal pass: output texel (i, j) sums weights[k] × area texel (offset.x + i + k − R,
/// offset.y + j) for k in tap order, skipping taps outside the area (size `p[0].xy`).
/// offset = (out.x0 − area.x0, first row − area.y0), aux = (R, taps).
kernel void pcr_blur_h(PCR_ARGS, device const float* w [[buffer(1)]], PCR_IN a [[texture(0)]], PCR_OUT out [[texture(7)]]) {
    if (int(gid.x) >= op.size.x || int(gid.y) >= op.size.y) return;
    int aw = int(op.p[0].x);
    int x = op.offset.x + int(gid.x), sy = op.offset.y + int(gid.y);
    float4 acc = float4(0.0f);
    for (int k = 0; k < op.aux.y; ++k) {
        int sx = x + k - op.aux.x;
        if (sx < 0 || sx >= aw) continue;
        acc = acc + w[k] * a.read(uint2(sx, sy));
    }
    out.write(acc, gid);
}

/// The vertical pass over the horizontal one (`p[0].y` rows), then straight colour (coverage at
/// most 1). offset.y = out.y0 − the horizontal pass's first row, aux = (R, taps).
kernel void pcr_blur_v(PCR_ARGS, device const float* w [[buffer(1)]], PCR_IN h [[texture(0)]], PCR_OUT out [[texture(7)]]) {
    if (int(gid.x) >= op.size.x || int(gid.y) >= op.size.y) return;
    int rows = int(op.p[0].y);
    int y = op.offset.y + int(gid.y);
    float4 acc = float4(0.0f);
    for (int k = 0; k < op.aux.y; ++k) {
        int sy = y + k - op.aux.x;
        if (sy < 0 || sy >= rows) continue;
        acc = acc + w[k] * h.read(uint2(gid.x, uint(sy)));
    }
    float al = min(acc.a, 1.0f);
    out.write(al > 0.0f ? float4(precise::divide(acc.r, acc.a), precise::divide(acc.g, acc.a), precise::divide(acc.b, acc.a), al) : float4(0.0f), gid);
}

inline float4 pcr_area_texel(texture2d<float, access::read> a, int x, int y, int2 size) {
    return (x < 0 || y < 0 || x >= size.x || y >= size.y) ? float4(0.0f) : a.read(uint2(x, y));
}

/// One tap of the streak (FilterMath.MotionTap): weight, whole-pixel step, fractions.
struct PCRMotionTap { float weight; int dx; int dy; float fx; float fy; };

/// The motion streak: each tap read bilinearly at its step from the output pixel in the
/// premultiplied area (size p[0].xy, zero outside), weighted in tap order, then straight colour.
/// offset = out origin − area origin, aux.y = taps.
kernel void pcr_blur_motion(PCR_ARGS, device const PCRMotionTap* taps [[buffer(1)]], PCR_IN a [[texture(0)]], PCR_OUT out [[texture(7)]]) {
    if (int(gid.x) >= op.size.x || int(gid.y) >= op.size.y) return;
    int2 size = int2(int(op.p[0].x), int(op.p[0].y));
    int x = op.offset.x + int(gid.x), y = op.offset.y + int(gid.y);
    float4 acc = float4(0.0f);
    for (int k = 0; k < op.aux.y; ++k) {
        PCRMotionTap t = taps[k];
        int x0 = x + t.dx, y0 = y + t.dy;
        float4 top = pcr_area_texel(a, x0, y0, size) * (1.0f - t.fx) + pcr_area_texel(a, x0 + 1, y0, size) * t.fx;
        float4 bottom = pcr_area_texel(a, x0, y0 + 1, size) * (1.0f - t.fx) + pcr_area_texel(a, x0 + 1, y0 + 1, size) * t.fx;
        acc = acc + t.weight * (top * (1.0f - t.fy) + bottom * t.fy);
    }
    float al = min(acc.a, 1.0f);
    out.write(al > 0.0f ? float4(precise::divide(acc.r, acc.a), precise::divide(acc.g, acc.a), precise::divide(acc.b, acc.a), al) : float4(0.0f), gid);
}
