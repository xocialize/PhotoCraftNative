// Port of photocraft-algo (crates/algo/src/camera_raw.rs: develop's vignette and grain; photo_util.rs: hash01), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Camera Raw Filter's per-pixel stages in one kernel: the color stages as one lattice composed on the
// CPU (Photoshop's sliders, fitted, CameraRawModel.swift), looked up by tetrahedral interpolation; the
// post-crop vignette, grain and the final clamp. Image coordinates are relative to the bounds.

struct pca_tone_cr_params {
    int2 origin;
    int2 size;
    uint flags;      // 1 lattice, 2 vignette, 4 grain, 8 clamp, 16 exposure as a linear gain (float documents)
    int lattice_size;
    float exposure_gain;
    float vig_amt;
    float vig_hl;
    float cx;
    float cy;
    float ax;
    float ay;
    float pw;
    float edge0;
    float edge1;
    uint vig_style;  // 0 highlightPriority, 1 colorPriority, 2 paintOverlay
    float grain_cell;
    float grain_rough;
    float grain_amt;
    float grain_pscale;
    uint seed_lo;
    uint seed_hi;
    uint pad0;
};

inline float pca_tone_cr_luma(float3 c) { return 0.2126f * c.x + 0.7152f * c.y + 0.0722f * c.z; }

inline float pca_tone_cr_smoothstep(float e0, float e1, float x) {
    float t = clamp((x - e0) / (e1 - e0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

/// The lattice (size³ × 3, red slowest) at `c` (0…1), by tetrahedral interpolation of the cube around it.
inline float3 pca_tone_cr_at(device const float* l, int n, int3 i) {
    int k = ((i.x * n + i.y) * n + i.z) * 3;
    return float3(l[k], l[k + 1], l[k + 2]);
}

inline float3 pca_tone_cr_lattice(device const float* l, int n, float3 c) {
    float3 p = clamp(c, 0.0f, 1.0f) * float(n - 1);
    int3 i = min(int3(p), int3(n - 2));
    float3 f = p - float3(i);
    float3 c000 = pca_tone_cr_at(l, n, i), c111 = pca_tone_cr_at(l, n, i + int3(1, 1, 1));
    if (f.x >= f.y) {
        if (f.y >= f.z) {
            float3 c100 = pca_tone_cr_at(l, n, i + int3(1, 0, 0)), c110 = pca_tone_cr_at(l, n, i + int3(1, 1, 0));
            return c000 + f.x * (c100 - c000) + f.y * (c110 - c100) + f.z * (c111 - c110);
        } else if (f.x >= f.z) {
            float3 c100 = pca_tone_cr_at(l, n, i + int3(1, 0, 0)), c101 = pca_tone_cr_at(l, n, i + int3(1, 0, 1));
            return c000 + f.x * (c100 - c000) + f.z * (c101 - c100) + f.y * (c111 - c101);
        } else {
            float3 c001 = pca_tone_cr_at(l, n, i + int3(0, 0, 1)), c101 = pca_tone_cr_at(l, n, i + int3(1, 0, 1));
            return c000 + f.z * (c001 - c000) + f.x * (c101 - c001) + f.y * (c111 - c101);
        }
    } else {
        if (f.z >= f.y) {
            float3 c001 = pca_tone_cr_at(l, n, i + int3(0, 0, 1)), c011 = pca_tone_cr_at(l, n, i + int3(0, 1, 1));
            return c000 + f.z * (c001 - c000) + f.y * (c011 - c001) + f.x * (c111 - c011);
        } else if (f.z >= f.x) {
            float3 c010 = pca_tone_cr_at(l, n, i + int3(0, 1, 0)), c011 = pca_tone_cr_at(l, n, i + int3(0, 1, 1));
            return c000 + f.y * (c010 - c000) + f.z * (c011 - c010) + f.x * (c111 - c011);
        } else {
            float3 c010 = pca_tone_cr_at(l, n, i + int3(0, 1, 0)), c110 = pca_tone_cr_at(l, n, i + int3(1, 1, 0));
            return c000 + f.y * (c010 - c000) + f.x * (c110 - c010) + f.z * (c111 - c110);
        }
    }
}

/// photocraft `photo_util::hash01`: 64-bit position hash → [0, 1).
inline float pca_tone_cr_hash01(long x, long y, ulong seed) {
    ulong z = (ulong(x) * 0x9E3779B97F4A7C15ul) ^ (ulong(y) * 0xC2B2AE3D27D4EB4Ful) ^ (seed * 0x165667B19E3779F9ul);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ul;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBul;
    z ^= z >> 31;
    return float(uint(z >> 40)) / 16777216.0f;
}

inline float pca_tone_cr_value_noise(float x, float y, ulong seed) {
    float xi = floor(x), yi = floor(y);
    float tx = x - xi, ty = y - yi;
    float sx = tx * tx * (3.0f - 2.0f * tx), sy = ty * ty * (3.0f - 2.0f * ty);
    long ix = long(xi), iy = long(yi);
    float h00 = pca_tone_cr_hash01(ix, iy, seed), h10 = pca_tone_cr_hash01(ix + 1, iy, seed);
    float h01 = pca_tone_cr_hash01(ix, iy + 1, seed), h11 = pca_tone_cr_hash01(ix + 1, iy + 1, seed);
    float top = h00 + (h10 - h00) * sx;
    float bot = h01 + (h11 - h01) * sx;
    return top + (bot - top) * sy;
}

kernel void pca_tone_camera_raw(constant pca_frame& f [[buffer(0)]], constant pca_tone_cr_params& p [[buffer(1)]],
                                device const float* lattice [[buffer(2)]],
                                pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q);
    int2 r = q - p.origin;
    if (r.x < 0 || r.y < 0 || r.x >= p.size.x || r.y >= p.size.y) { dst.write(v, gid); return; }
    float4 c4 = pca_tone_to_rgba_px(v, f);
    float3 c = c4.xyz;
    uint fl = p.flags;
    // Float documents: Exposure is a gain in linear light.
    if ((fl & 16u) != 0u) {
        for (int ch = 0; ch < 3; ch++) c[ch] = pca_tone_linear_to_srgb(fmax(pca_tone_srgb_to_linear(c[ch]) * p.exposure_gain, 0.0f));
    }
    // 1–4. The color stages; in float documents a value past 0…1 keeps its excess.
    if ((fl & 1u) != 0u) {
        float3 inside = clamp(c, 0.0f, 1.0f);
        float3 o = pca_tone_cr_lattice(lattice, p.lattice_size, inside);
        if ((fl & 8u) == 0u) o += c - inside;
        c = o;
    }
    // 6. Vignette.
    if ((fl & 2u) != 0u) {
        float dx = fabs((float(r.x) + 0.5f - p.cx) / p.ax), dy = fabs((float(r.y) + 0.5f - p.cy) / p.ay);
        float rr = pow(pow(dx, p.pw) + pow(dy, p.pw), 1.0f / p.pw);
        float m = pca_tone_cr_smoothstep(p.edge0, p.edge1, rr);
        if (m > 0.0f) {
            float l = clamp(pca_tone_cr_luma(c), 0.0f, 1.0f);
            if (p.vig_style == 2u) {
                float target = p.vig_amt < 0.0f ? 0.0f : 1.0f;
                float k = m * fabs(p.vig_amt);
                for (int ch = 0; ch < 3; ch++) c[ch] += (target - c[ch]) * k;
            } else {
                float k = pow(2.0f, p.vig_amt * 2.0f * m);
                if (p.vig_amt < 0.0f && p.vig_hl > 0.0f) {
                    float protect = pca_tone_cr_smoothstep(0.6f, 1.0f, l) * p.vig_hl;
                    k += (1.0f - k) * protect;
                }
                if (p.vig_style == 1u) {
                    float nl = l * k;
                    for (int ch = 0; ch < 3; ch++) c[ch] += nl - l;
                } else {
                    c = float3(c.x * k, c.y * k, c.z * k);
                }
            }
        }
    }
    // 6. Grain.
    if ((fl & 4u) != 0u) {
        ulong seed = (ulong(p.seed_hi) << 32) | ulong(p.seed_lo);
        float fx = float(r.x) * p.grain_pscale / p.grain_cell, fy = float(r.y) * p.grain_pscale / p.grain_cell;
        float n = pca_tone_cr_value_noise(fx, fy, seed) * (1.0f - p.grain_rough)
                + (pca_tone_cr_value_noise(fx * 2.3f, fy * 2.3f, seed + 7ul) - 0.0f) * p.grain_rough;
        float l = clamp(pca_tone_cr_luma(c), 0.0f, 1.0f);
        float g = (n - 0.5f) * 2.0f * p.grain_amt * (0.4f + 2.4f * l * (1.0f - l));
        c = float3(c.x + g, c.y + g, c.z + g);
    }
    if ((fl & 8u) != 0u) c = clamp(c, 0.0f, 1.0f);
    c4.xyz = c;
    dst.write(pca_tone_from_rgba_px(v, c4, f), gid);
}
