// Port of photocraft-algo (crates/algo/src/render.rs, fxutil.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Fibers, Lens Flare and Lighting Effects. `.joint` kernels: one plane of a Gray-like (g in .x)
// or RGB-like (.xyz) document, alpha in .w when present. Colour goes through straight sRGB as
// photocraft's `fxutil::rgba` / `set_rgba` do. Uses the exact-maths helpers of Distort.metal
// (`pca_dis_sqrt`, `pca_dis_atan2`), which precedes this file in the library.

/// photocraft `fxutil::rgba` of a plane pixel (straight sRGB; alpha 1 without an alpha channel).
inline float4 pca_ren_rgba(float4 v, constant pca_frame& f) {
    float a = f.alpha != 0u ? v.w : 1.0f;
    return f.mode == 0u ? float4(v.x, v.x, v.x, a) : float4(v.xyz, a);
}

/// photocraft `fxutil::set_rgba` into a plane pixel (Gray: Rec. 601 grey; alpha from `c.w`).
inline float4 pca_ren_native(float4 c, constant pca_frame& f) {
    float4 o;
    if (f.mode == 0u) {
        float r = 0.299f * c.x, g = 0.587f * c.y, b = 0.114f * c.z;
        o = float4(r + g + b, 0.0f, 0.0f, 0.0f);
    } else {
        o = float4(c.xyz, 0.0f);
    }
    if (f.alpha != 0u) o.w = c.w;
    return o;
}

/// Rust `f32::powi` (repeated squaring, as LLVM / compiler-rt).
inline float pca_ren_powi(float x, int n) {
    float r = 1.0f, a = x;
    int b = n;
    while (true) {
        if ((b & 1) != 0) r *= a;
        b >>= 1;
        if (b == 0) break;
        a *= a;
    }
    return r;
}

/// photocraft `render::value_noise`.
inline float pca_ren_value_noise(float x, float y, uint seed) {
    int ix = int(floor(x)), iy = int(floor(y));
    float tx = x - float(ix), ty = y - float(iy);
    float sx = tx * tx * (3.0f - 2.0f * tx), sy = ty * ty * (3.0f - 2.0f * ty);
    float h00 = pca_hash01(ix, iy, 0u, seed), h10 = pca_hash01(ix + 1, iy, 0u, seed);
    float h01 = pca_hash01(ix, iy + 1, 0u, seed), h11 = pca_hash01(ix + 1, iy + 1, 0u, seed);
    float top = h00 + (h10 - h00) * sx;
    float bot = h01 + (h11 - h01) * sx;
    return top + (bot - top) * sy;
}

struct pca_ren_fibers_params {
    float4 fg;
    float4 bg;
    float fx;
    float fy;
    float variance;
    uint seed;
};

kernel void pca_ren_fibers(constant pca_frame& f [[buffer(0)]], constant pca_ren_fibers_params& p [[buffer(1)]],
                           pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float xf = float(q.x), yf = float(q.y);
    float sum = 0.0f, amp = 1.0f, norm = 0.0f;
    float ax = p.fx, ay = p.fy;
    for (uint o = 0u; o < 4u; o++) {
        sum += pca_ren_value_noise(xf * ax, yf * ay, p.seed + o * 977u) * amp;
        norm += amp;
        amp *= 0.55f;
        ax *= 2.0f;
        ay *= 2.0f;
    }
    float grain = pca_ren_value_noise(xf * 0.9f, yf * p.fy * 0.25f, p.seed ^ 0x5bd1u) - 0.5f;
    float t = clamp((sum / norm - 0.5f) * (1.6f + p.variance / 40.0f) + 0.5f + grain * 0.25f, 0.0f, 1.0f);
    float4 c = float4(p.fg.xyz + (p.bg.xyz - p.fg.xyz) * t, 1.0f);
    dst.write(pca_ren_native(c, f), gid);
}

struct pca_ren_flare_params {
    float2 c;
    float s;
    float bright;
    float core;
    float glow;
    float ring_r;
    float ring_w;
    float rays;
    float streak;
    uint ghosts;
    int pad0;
};

struct pca_ren_ghost {
    float4 pos;    // x, y, radius·s, strength
    float4 tint;
};

kernel void pca_ren_lens_flare(constant pca_frame& f [[buffer(0)]], constant pca_ren_flare_params& p [[buffer(1)]],
                               constant pca_ren_ghost* gh [[buffer(2)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float fx = float(q.x) + 0.5f, fy = float(q.y) + 0.5f;
    float dx = fx - p.c.x, dy = fy - p.c.y;
    float d = sqrt(dx * dx + dy * dy);
    float3 fl = float3(0.0f);
    float qd = d / (p.core * p.s);
    float g = exp(-(qd * qd)) + 0.35f * exp(-d / (p.glow * p.s));
    fl += g * float3(1.0f, 0.95f, 0.85f);
    if (p.rays > 0.0f) {
        float th = pca_dis_atan2(dy, dx);
        float m = pca_ren_powi(sin(th * 12.0f) * 0.5f + 0.5f, 8) + pca_ren_powi(sin(th * 7.0f + 1.3f) * 0.5f + 0.5f, 12) * 0.6f;
        float rr = p.rays * m * exp(-d / (p.glow * 1.6f * p.s));
        fl += float3(rr * 0.6f);
    }
    if (p.streak > 0.0f) {
        float st = exp(-(fabs(dy) / (2.5f * p.s))) * exp(-(fabs(dx) / (450.0f * p.s)));
        fl += st * float3(0.5f, 0.7f, 1.0f);
    }
    if (p.ring_r > 0.0f) {
        float3 off = float3(1.04f, 1.0f, 0.96f);
        for (int k = 0; k < 3; k++) {
            float rd = (d - p.ring_r * p.s * off[k]) / (p.ring_w * p.s);
            fl[k] += 0.18f * exp(-rd * rd);
        }
    }
    for (uint i = 0u; i < p.ghosts; i++) {
        // The disc edges are hard thresholds on gd: products in separate statements (no fma
        // contraction) and a correctly rounded sqrt keep gd bit-identical to the CPU.
        float ex = fx - gh[i].pos.x, ey = fy - gh[i].pos.y;
        float ex2 = ex * ex;
        float ey2 = ey * ey;
        float gd = pca_dis_sqrt(ex2 + ey2) / gh[i].pos.z;
        if (gd < 1.2f) {
            float e = (gd >= 0.85f ? 1.0f : 0.0f) * (0.6f + 0.4f * gd);   // photocraft smoothstep(1, 0.85, gd): a step
            fl += e * gh[i].pos.w * gh[i].tint.xyz;
        }
    }
    float4 c = pca_ren_rgba(pca_get(src, f, q), f);
    for (int k = 0; k < 3; k++) {
        float a = max(fl[k] * p.bright, 0.0f);
        c[k] = 1.0f - (1.0f - c[k]) * (1.0f - min(a, 1.0f));
    }
    dst.write(pca_ren_native(c, f), gid);
}

struct pca_ren_lighting_params {
    float ambient;
    float shininess;
    float spec_k;
    float metal;
    float expo;
    float hscale;
    uint texture;        // 0 none, 1 red, 2 green, 3 blue, 4 alpha, 5 luminance
    uint white_is_high;
    uint lights;
    int pad0;
    int pad1;
    int pad2;
};

struct pca_ren_light {
    float4 pos;     // light position (document px; z above the surface)
    float4 dir;     // infinite: direction to the light; spot: the cone axis
    float4 color;   // rgb, w = intensity / 50
    float4 extra;   // spot: outer cos, smoothstep upper edge; point: z = reach; w = kind (0 spot, 1 point, 2 infinite)
};

/// photocraft `render::norm3`.
inline float3 pca_ren_norm3(float3 v) {
    float m = max(sqrt(v.x * v.x + v.y * v.y + v.z * v.z), 1e-9f);
    return v / m;
}

/// The bump texture value at document `p` clamped to the bounds (photocraft `lighting`'s `tex`).
inline float pca_ren_tex(pca_in src, constant pca_frame& f, constant pca_ren_lighting_params& p, int2 at) {
    int2 c = clamp(at, f.bounds_origin, f.bounds_origin + f.bounds_size - 1);
    float4 v = pca_get(src, f, c);
    float t;
    switch (p.texture) {
        case 4u: t = f.alpha != 0u ? v.w : 1.0f; break;
        case 5u: t = pca_luma(v, f.mode); break;
        case 1u: t = v.x; break;
        case 2u: t = f.mode == 0u ? v.x : v.y; break;
        case 3u: t = f.mode == 0u ? v.x : v.z; break;
        default: t = 0.0f; break;
    }
    return p.white_is_high != 0u ? t : 1.0f - t;
}

kernel void pca_ren_lighting(constant pca_frame& f [[buffer(0)]], constant pca_ren_lighting_params& p [[buffer(1)]],
                             constant pca_ren_light* ls [[buffer(2)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float fx = float(q.x) + 0.5f, fy = float(q.y) + 0.5f;
    float3 nrm = float3(0.0f, 0.0f, 1.0f);
    if (!(p.texture == 0u || p.hscale <= 0.0f)) {
        float hx = (pca_ren_tex(src, f, p, q + int2(1, 0)) - pca_ren_tex(src, f, p, q - int2(1, 0))) * 0.5f * p.hscale;
        float hy = (pca_ren_tex(src, f, p, q + int2(0, 1)) - pca_ren_tex(src, f, p, q - int2(0, 1))) * 0.5f * p.hscale;
        nrm = pca_ren_norm3(float3(-hx, -hy, 1.0f));
    }
    float4 c = pca_ren_rgba(pca_get(src, f, q), f);
    float3 base = c.xyz;
    float3 lit = float3(p.ambient);
    float3 spc = float3(0.0f);
    for (uint i = 0u; i < p.lights; i++) {
        pca_ren_light l = ls[i];
        float3 ldir;
        float atten;
        if (l.extra.w == 2.0f) {
            ldir = l.dir.xyz;
            atten = 1.0f;
        } else if (l.extra.w == 1.0f) {
            float3 v = float3(l.pos.x - fx, l.pos.y - fy, l.pos.z);
            float dist = sqrt(v.x * v.x + v.y * v.y);
            ldir = pca_ren_norm3(v);
            atten = pca_ren_powi(clamp(1.0f - dist / l.extra.z, 0.0f, 1.0f), 2);
        } else {
            ldir = pca_ren_norm3(float3(l.pos.x - fx, l.pos.y - fy, l.pos.z));
            float cosang = -dot(ldir, l.dir.xyz);
            atten = pca_smoothstep(l.extra.x, l.extra.y, cosang);
        }
        if (atten <= 0.0f) continue;
        float inten = l.color.w * atten;
        float ndl = max(dot(nrm, ldir), 0.0f);
        float3 hv = pca_ren_norm3(float3(ldir.x, ldir.y, ldir.z + 1.0f));
        float s = pow(max(dot(nrm, hv), 0.0f), p.shininess) * p.spec_k;
        lit += ndl * inten * l.color.xyz;
        float3 sc = l.color.xyz * (1.0f - p.metal) + base * p.metal;
        spc += s * max(inten, 0.0f) * sc;
    }
    c.xyz = max((base * lit + spc) * p.expo, 0.0f);
    dst.write(pca_ren_native(c, f), gid);
}
