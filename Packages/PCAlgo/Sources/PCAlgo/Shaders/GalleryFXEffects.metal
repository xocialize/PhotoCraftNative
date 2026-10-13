// Port of photocraft-algo (crates/algo/src/artistic_fx.rs `apply`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// One per-pixel kernel per Filter Gallery effect (the step after its blurs / Sobel / Kuwahara
// passes; see GalleryFXGPU.swift for which textures and values each receives). Textures: the
// inputs in order, then the output window. Same formulas and operation order as the CPU.

#define PCA_GFX_PROLOGUE \
    int2 q; \
    if (!pca_gfx_win_pixel(p, gid, q)) return;

#define PCA_GFX_K1 constant pca_frame& f [[buffer(0)]], constant pca_gfx_params& p [[buffer(1)]], \
    pca_in t0 [[texture(0)]], pca_out o [[texture(1)]], uint2 gid [[thread_position_in_grid]]
#define PCA_GFX_K2 constant pca_frame& f [[buffer(0)]], constant pca_gfx_params& p [[buffer(1)]], \
    pca_in t0 [[texture(0)]], pca_in t1 [[texture(1)]], pca_out o [[texture(2)]], uint2 gid [[thread_position_in_grid]]
#define PCA_GFX_K3 constant pca_frame& f [[buffer(0)]], constant pca_gfx_params& p [[buffer(1)]], \
    pca_in t0 [[texture(0)]], pca_in t1 [[texture(1)]], pca_in t2 [[texture(2)]], pca_out o [[texture(3)]], \
    uint2 gid [[thread_position_in_grid]]

#define PCA_GFX_PUT(v) o.write(float4((v), 0.0f), gid)

// ---------------------------------------------------------------- Artistic

/// t0 window, t1 Sobel of its luma. v0 = (stroke len, stroke width, pressure), v1.xyz paper.
kernel void pca_gfx_fx_coloredPencil(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    float3 c = t0.read(gid).xyz;
    float d = 1.0f - pca_gfx_lum(c);
    float e2 = t1.read(gid).z;
    float h1 = pca_gfx_strokes(q.x, q.y, int2(1, 1), p.v0.x, p.v0.y, 11u);
    float h2 = pca_gfx_strokes(q.x, q.y, int2(1, -1), p.v0.x, p.v0.y, 12u);
    float hatch = fmax(h1, h2 * pca_gfx_ss(0.3f, 0.8f, d));
    float cov = pca_gfx_clamp01(d * (0.55f + p.v0.z) + e2 * 3.0f - (1.0f - hatch) * 0.8f + 0.25f);
    PCA_GFX_PUT(pca_gfx_mix(p.v1.xyz, c * 0.88f, cov));
}

/// t0 blurred window. v0.x levels.
kernel void pca_gfx_fx_cutout(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float3 c = t0.read(gid).xyz;
    float levels = p.v0.x;
    float l = fmax(pca_gfx_lum(c), 1e-4f);
    float k = pca_gfx_posterize(l, levels) / l;
    float lv2 = levels * 2.0f;
    PCA_GFX_PUT(float3(pca_gfx_posterize(pca_gfx_clamp01(c.x * k), lv2), pca_gfx_posterize(pca_gfx_clamp01(c.y * k), lv2),
                       pca_gfx_posterize(pca_gfx_clamp01(c.z * k), lv2)));
}

/// Dry Brush / Fresco: t0 Kuwahara + unsharp window, t1 Sobel of its luma (Fresco).
/// v0 = (levels, amp, fresco).
kernel void pca_gfx_fx_dryBrush(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    float3 c = t0.read(gid).xyz;
    float n = (pca_hash01(q.x, q.y, 0u, 21u) - 0.5f) * p.v0.y;
    float3 r;
    for (int i = 0; i < 3; i++) r[i] = pca_gfx_posterize(c[i], p.v0.x) * 0.6f + c[i] * 0.4f + n;
    if (p.v0.z != 0.0f) {
        float k = 1.0f - pca_gfx_clamp01(t1.read(gid).z * 2.5f) * 0.6f;
        for (int i = 0; i < 3; i++) r[i] = pow(pca_gfx_clamp01((r[i] - 0.5f) * 1.3f + 0.45f), 1.15f) * k;
    }
    PCA_GFX_PUT(r);
}

/// v0 = (grain, highlight area, intensity).
kernel void pca_gfx_fx_filmGrain(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float3 c = t0.read(gid).xyz;
    float l = pca_gfx_lum(c);
    float n = (pca_hash01(q.x, q.y, 0u, 31u) - 0.5f) * p.v0.x * 0.5f * (0.3f + 2.8f * l * (1.0f - l));
    PCA_GFX_PUT(pca_gfx_highlights(c + n, l, p.v0.y, p.v0.z));
}

/// t0 window, t1 blurred glow mask. v0.x brightness; fg, bg, color.
kernel void pca_gfx_fx_neonGlow(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    float l = pca_gfx_lum(t0.read(gid).xyz);
    float3 base = pca_gfx_mix(p.fg.xyz, p.bg.xyz, l);
    float k = pca_gfx_clamp01(t1.read(gid).x * 1.2f) * p.v0.x * 2.0f;
    float3 r;
    for (int i = 0; i < 3; i++) r[i] = 1.0f - (1.0f - base[i]) * (1.0f - pca_gfx_clamp01(p.color[i] * k));
    PCA_GFX_PUT(r);
}

/// Rough Paint Daubs: t0 window, t1 Sobel of its luma (sparkle). i0 = 1 light, 2 dark, 3 sparkle.
kernel void pca_gfx_fx_paintDaubs(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    float3 c = t0.read(gid).xyz;
    float n = pca_gfx_fbm(float(q.x) / 2.0f, float(q.y) / 2.0f, 41u) - 0.5f;
    if (p.i0 == 1) { PCA_GFX_PUT(c + fmax(n, 0.0f) * 0.35f); return; }
    if (p.i0 == 2) { PCA_GFX_PUT(c * (1.0f - fmax(n, 0.0f) * 0.7f)); return; }
    float s = pca_gfx_clamp01(t1.read(gid).z * 4.0f) * pca_gfx_ss(0.75f, 0.95f, pca_hash01(q.x, q.y, 0u, 42u)) * 0.8f;
    PCA_GFX_PUT(c + s);
}

/// t0 Kuwahara window. v0.x levels.
kernel void pca_gfx_fx_paletteKnife(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float3 c = t0.read(gid).xyz;
    float3 r;
    for (int i = 0; i < 3; i++) r[i] = pca_gfx_posterize(c[i], p.v0.x) * 0.5f + c[i] * 0.5f;
    PCA_GFX_PUT(r);
}

/// t0 window, t1 Sobel of the blurred luma. v0.x highlight strength, v1.xyz half vector.
kernel void pca_gfx_fx_plasticWrap(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    float3 c = t0.read(gid).xyz;
    float4 s = t1.read(gid);
    float k = 14.0f;
    float3 n = pca_gfx_normalize3(float3(-k * s.x, -k * s.y, 1.0f));
    float3 hv = p.v1.xyz;
    float ndh = fmax(n.x * hv.x + n.y * hv.y + n.z * hv.z, 0.0f);
    float tilt = 1.0f - n.z;
    float spec = pow(ndh, 30.0f) * pca_gfx_ss(0.01f, 0.12f, tilt) + pca_gfx_ss(0.25f, 0.6f, tilt) * 0.25f;
    float add = spec * p.v0.x * 1.3f;
    PCA_GFX_PUT(c * 0.88f + add);
}

/// t0 window, t1 Sobel of the blurred luma. v0 = (intensity, levels).
kernel void pca_gfx_fx_posterEdges(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    float3 c = t0.read(gid).xyz;
    float inten = p.v0.x;
    float ink = pca_gfx_ss(0.015f, 0.06f, t1.read(gid).z * (1.0f + inten * 3.0f)) * (0.55f + inten * 0.45f);
    float3 r;
    for (int i = 0; i < 3; i++) r[i] = pca_gfx_posterize(c[i], p.v0.y) * (1.0f - ink);
    PCA_GFX_PUT(r);
}

/// Rough Pastels' strokes: t0 window, t1 softened window. v0 = (length, detail).
kernel void pca_gfx_fx_roughPastels(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    float len = p.v0.x, det = p.v0.y;
    float t;
    float3 c = pca_gfx_paint_stroke(t1, p, q.x, q.y, int2(1, -1), 2.0f + len, 1.5f, 51u, t);
    float n = (pca_gfx_strokes(q.x, q.y, int2(1, -1), 2.0f + len * 0.5f, 0.8f, 52u) - 0.5f) * 0.12f + (0.5f - fabs(t - 0.5f)) * 0.06f;
    PCA_GFX_PUT(pca_gfx_mix(c, t0.read(gid).xyz, det * 0.6f) + n);
}

/// t0 line-blurred window. v0 = (highlight area, intensity).
kernel void pca_gfx_fx_smudgeStick(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float3 c = t0.read(gid).xyz;
    float l = pca_gfx_lum(c);
    PCA_GFX_PUT(pca_gfx_highlights(c * (0.7f + 0.3f * l), l, p.v0.x, p.v0.y));
}

/// t0 Kuwahara window. v0 = (definition, noise scale).
kernel void pca_gfx_fx_sponge(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float3 c = t0.read(gid).xyz;
    float def = p.v0.x, sc = p.v0.y;
    float s = pca_gfx_fbm(float(q.x) / sc, float(q.y) / sc, 61u);
    float hole = pca_gfx_ss(0.58f, 0.75f, s);
    float3 r;
    for (int i = 0; i < 3; i++) r[i] = pca_gfx_clamp01((c[i] - 0.5f) * (1.0f + def * 0.6f) + 0.5f) * (1.0f - hole * def * 0.4f);
    PCA_GFX_PUT(r);
}

/// t0 original window, t1 blurred.
kernel void pca_gfx_fx_underpainting(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    PCA_GFX_PUT(pca_gfx_saturate(pca_gfx_mix(t0.read(gid).xyz, t1.read(gid).xyz, 0.8f), 1.15f));
}

/// t0 Kuwahara window, t1 Sobel of its luma. v0 = (shadow intensity, texture amp).
kernel void pca_gfx_fx_watercolor(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    float sh = p.v0.x;
    float n = (pca_gfx_fbm(float(q.x) / 3.0f, float(q.y) / 3.0f, 71u) - 0.5f) * p.v0.y;
    float k = 1.0f - pca_gfx_clamp01(t1.read(gid).z * (3.0f + sh * 8.0f)) * 0.6f;
    float3 c = pca_gfx_saturate(t0.read(gid).xyz, 1.2f);
    float e = 1.1f + sh * 0.6f;
    float3 r;
    for (int i = 0; i < 3; i++) r[i] = pow(pca_gfx_clamp01(c[i] * k + n), e);
    PCA_GFX_PUT(r);
}

// ---------------------------------------------------------------- Brush Strokes

/// t0 window, t1 blurred Sobel (edge in .z). v0.x edge brightness / 50.
kernel void pca_gfx_fx_accentedEdges(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    float3 c = t0.read(gid).xyz;
    float k = pca_gfx_clamp01(t1.read(gid).z * 6.0f);
    float eb = p.v0.x;
    float3 r;
    if (eb >= 0.5f) { for (int i = 0; i < 3; i++) r[i] = c[i] + (1.0f - c[i]) * k * (eb - 0.5f) * 2.0f; }
    else { for (int i = 0; i < 3; i++) r[i] = c[i] * (1.0f - k * (0.5f - eb) * 2.0f); }
    PCA_GFX_PUT(r);
}

/// t0 softened window. v0 = (stroke length, balance).
kernel void pca_gfx_fx_angledStrokes(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float len = p.v0.x, bal = p.v0.y;
    float k = pca_gfx_ss(1.0f - bal - 0.05f, 1.0f - bal + 0.05f, pca_gfx_lum(t0.read(gid).xyz));
    float t;
    float3 down = pca_gfx_paint_stroke(t0, p, q.x, q.y, int2(1, 1), len, 2.0f, 83u, t);
    float3 up = pca_gfx_paint_stroke(t0, p, q.x, q.y, int2(1, -1), len, 2.0f, 84u, t);
    float n = (pca_gfx_strokes(q.x, q.y, int2(1, 1), len * 0.5f, 0.7f, 85u) - 0.5f) * (1.0f - k)
        + (pca_gfx_strokes(q.x, q.y, int2(1, -1), len * 0.5f, 0.7f, 86u) - 0.5f) * k;
    PCA_GFX_PUT(pca_gfx_mix(down, up, k) + n * 0.1f);
}

/// Crosshatch's grain: v0.x strength.
kernel void pca_gfx_fx_crosshatch(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float n = (pca_hash01(q.x, q.y, 0u, 81u) - 0.5f) * 0.12f * p.v0.x;
    PCA_GFX_PUT(t0.read(gid).xyz + n);
}

/// t0 window, t1 down-right blurred, t2 up-right blurred. v0 = (black, white, threshold).
kernel void pca_gfx_fx_darkStrokes(PCA_GFX_K3) {
    PCA_GFX_PROLOGUE
    float l = pca_gfx_lum(t0.read(gid).xyz);
    float3 d = t1.read(gid).xyz * (1.0f - p.v0.x * 0.85f);
    float3 b = t2.read(gid).xyz;
    float3 li = float3(b.x + (1.0f - b.x) * p.v0.y * 0.5f, b.y + (1.0f - b.y) * p.v0.y * 0.5f, b.z + (1.0f - b.z) * p.v0.y * 0.5f);
    float t = p.v0.z;
    PCA_GFX_PUT(pca_gfx_mix(d, li, pca_gfx_ss(t - 0.1f, t + 0.1f, l)));
}

/// t0 window, t1 Sobel of its luma, t2 line-blurred window. v0 = (dark, light).
kernel void pca_gfx_fx_inkOutlines(PCA_GFX_K3) {
    PCA_GFX_PROLOGUE
    float di = p.v0.x, li = p.v0.y;
    float l = pca_gfx_lum(t0.read(gid).xyz);
    float ink = pca_gfx_clamp01(t1.read(gid).z * 5.0f) * di * 1.5f;
    float lt = pca_gfx_ss(0.5f, 1.0f, l) * li, dk = pca_gfx_ss(0.5f, 0.0f, l) * di * 0.8f;
    float3 c = t2.read(gid).xyz;
    float3 r;
    for (int i = 0; i < 3; i++) r[i] = (c[i] + (1.0f - c[i]) * lt) * (1.0f - dk) * (1.0f - pca_gfx_clamp01(ink));
    PCA_GFX_PUT(r);
}

/// Spatter / Sprayed Strokes displacement: v0 = (spray radius, noise scale).
kernel void pca_gfx_fx_spatter(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float fx = float(q.x) / p.v0.y, fy = float(q.y) / p.v0.y;
    float dx = (pca_gfx_vnoise(fx, fy, 91u) - 0.5f) * 2.0f * p.v0.x;
    float dy = (pca_gfx_vnoise(fx, fy, 92u) - 0.5f) * 2.0f * p.v0.x;
    PCA_GFX_PUT(pca_gfx_sample(t0, p, float(q.x) + 0.5f + dx, float(q.y) + 0.5f + dy));
}

/// t0 blurred + line-blurred window. v0 = (pressure, contrast).
kernel void pca_gfx_fx_sumiE(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float3 c = t0.read(gid).xyz;
    float pr = p.v0.x, con = p.v0.y;
    float ink = pow(pca_gfx_ss(0.65f, 0.15f, pca_gfx_lum(c)), 1.0f - pr * 0.5f);
    float3 r;
    for (int i = 0; i < 3; i++) r[i] = pca_gfx_clamp01((c[i] - 0.5f) * (1.0f + con) + 0.5f) * (1.0f - ink * 0.9f * (0.5f + con));
    PCA_GFX_PUT(r);
}

// ---------------------------------------------------------------- Distort

/// v0 = (graininess, glow amount, threshold); bg.
kernel void pca_gfx_fx_diffuseGlow(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float3 c = t0.read(gid).xyz;
    float l = pca_gfx_lum(c);
    float thr = p.v0.z;
    float m = pca_gfx_ss(thr - 0.3f, thr + 0.1f, l) * p.v0.y * 1.4f;
    if (pca_hash01(q.x, q.y, 0u, 101u) < p.v0.x * 0.3f * (m + 0.15f)) m += 0.5f;
    PCA_GFX_PUT(pca_gfx_mix(c, p.bg.xyz, pca_gfx_clamp01(m)));
}

/// v0 = (distortion, step, scale, sign), v1.x max shift, i0 texture kind.
kernel void pca_gfx_fx_glass(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float fx = float(q.x), fy = float(q.y);
    float dist = p.v0.x, st = p.v0.y, s = p.v0.z, sign = p.v0.w, mx = p.v1.x;
    float gx = pca_gfx_texture(p.i0, fx + st, fy, s) - pca_gfx_texture(p.i0, fx - st, fy, s);
    float gy = pca_gfx_texture(p.i0, fx, fy + st, s) - pca_gfx_texture(p.i0, fx, fy - st, s);
    float dx = clamp(gx * sign * dist * 3.0f, -mx, mx);
    float dy = clamp(gy * sign * dist * 3.0f, -mx, mx);
    PCA_GFX_PUT(pca_gfx_sample(t0, p, fx + 0.5f + dx, fy + 0.5f + dy));
}

/// v0 = (scale, magnitude).
kernel void pca_gfx_fx_oceanRipple(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float fx = float(q.x) / p.v0.x, fy = float(q.y) / p.v0.x;
    float dx = (pca_gfx_vnoise(fx, fy, 111u) - 0.5f) * 2.0f * p.v0.y;
    float dy = (pca_gfx_vnoise(fx, fy, 112u) - 0.5f) * 2.0f * p.v0.y;
    PCA_GFX_PUT(pca_gfx_sample(t0, p, float(q.x) + 0.5f + dx, float(q.y) + 0.5f + dy));
}

// ---------------------------------------------------------------- Sketch

/// t0 window (original luma), t1 Sobel of the blurred luma. v0 = (light x, light y, k); fg, bg.
kernel void pca_gfx_fx_basRelief(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    float l = pca_gfx_lum(t0.read(gid).xyz);
    float4 s = t1.read(gid);
    float t = pca_gfx_clamp01(l * 0.5f + 0.25f + p.v0.z * -(s.x * p.v0.x + s.y * p.v0.y));
    PCA_GFX_PUT(pca_gfx_mix(p.fg.xyz, p.bg.xyz, t));
}

/// v0 = (charcoal area, chalk area, pressure); fg, bg.
kernel void pca_gfx_fx_chalkCharcoal(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float l = pca_gfx_lum(t0.read(gid).xyz);
    float ca = p.v0.x, ch = p.v0.y, pr = p.v0.z;
    float3 mid = pca_gfx_mix(p.fg.xyz, p.bg.xyz, 0.5f);
    float cn = pca_gfx_strokes(q.x, q.y, int2(1, 1), 9.0f, 0.9f, 121u) - 0.5f;
    float kn = pca_gfx_strokes(q.x, q.y, int2(1, -1), 9.0f, 0.9f, 122u) - 0.5f;
    float cc = pca_gfx_ss(0.25f, 0.6f, (1.0f - l) * (0.4f + ca * 1.2f) + cn * (0.6f + pr * 0.4f) - 0.15f);
    float kc = pca_gfx_ss(0.25f, 0.6f, l * (0.4f + ch * 1.2f) + kn * (0.6f + pr * 0.4f) - 0.15f);
    PCA_GFX_PUT(pca_gfx_mix(pca_gfx_mix(mid, p.fg.xyz, cc), p.bg.xyz, kc * (1.0f - cc)));
}

/// t0 blurred luma, t1 its Sobel. v0 = (thickness, detail, balance); fg, bg.
kernel void pca_gfx_fx_charcoal(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    float th = p.v0.x, det = p.v0.y, bal = p.v0.z;
    float l = t0.read(gid).x;
    float sn = pca_gfx_strokes(q.x, q.y, int2(1, 1), 8.0f + th * 3.0f, 0.6f + th * 0.5f, 131u) - 0.5f;
    float cov = pca_gfx_ss(1.0f - bal - 0.2f, 1.0f - bal + 0.2f, 1.0f - l + sn * 0.6f) + pca_gfx_clamp01(t1.read(gid).z * det * 6.0f);
    PCA_GFX_PUT(pca_gfx_mix(p.bg.xyz, p.fg.xyz, pca_gfx_clamp01(cov)));
}

/// t0 blurred luma, t1 its Sobel. v0.x detail.
kernel void pca_gfx_fx_chrome(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    float det = p.v0.x;
    float a = t0.read(gid).x * (2.5f + det * 3.0f) + t1.read(gid).z * 6.0f;
    float v = 0.5f + 0.5f * sin(a * 2.0f * 3.14159265358979323846f);
    PCA_GFX_PUT(float3(pca_gfx_ss(0.05f, 0.95f, v)));
}

/// v0 = (foreground level, background level); fg, bg.
kernel void pca_gfx_fx_conteCrayon(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float l = pca_gfx_lum(t0.read(gid).xyz);
    float fl = p.v0.x, bl = p.v0.y;
    float3 mid = pca_gfx_mix(p.fg.xyz, p.bg.xyz, 0.5f);
    float sn = pca_gfx_strokes(q.x, q.y, int2(1, -1), 7.0f, 1.0f, 141u) - 0.5f;
    float cf = pca_gfx_clamp01((0.6f - l) * 2.0f * fl * 1.4f + sn * 0.5f);
    float cb = pca_gfx_clamp01((l - 0.4f) * 2.0f * bl * 1.4f - sn * 0.5f);
    PCA_GFX_PUT(pca_gfx_mix(pca_gfx_mix(mid, p.fg.xyz, cf), p.bg.xyz, cb * (1.0f - cf)));
}

/// t0 window, t1 line-blurred noise. v0 = (balance, noise sd); fg, bg.
kernel void pca_gfx_fx_graphicPen(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    float l = pca_gfx_lum(t0.read(gid).xyz);
    float z = (t1.read(gid).x - 0.5f) / p.v0.y;
    float t = l + z * 0.16f;
    float bal = p.v0.x;
    PCA_GFX_PUT(pca_gfx_mix(p.bg.xyz, p.fg.xyz, pca_gfx_ss(bal + 0.04f, bal - 0.04f, t)));
}

/// t0 blurred luma. v0 = (cell, contrast), i0 = 0 dot / 1 circle / 2 line; bc; fg, bg.
kernel void pca_gfx_fx_halftonePattern(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float cell = p.v0.x, con = p.v0.y;
    float fx = float(q.x) + 0.5f, fy = float(q.y) + 0.5f;
    float d = pca_gfx_clamp01((1.0f - t0.read(gid).x - 0.5f) * (1.0f + con * 3.0f) + 0.5f);
    float aa = 1.0f / cell;
    float ink;
    if (p.i0 == 1) {
        float ex = fx - p.bc.x, ey = fy - p.bc.y;
        float r = pca_gfx_sqrt(ex * ex + ey * ey) / cell;
        float qv = fabs(pca_gfx_fract(r) - 0.5f) * 2.0f;
        ink = pca_gfx_ss(d + aa, d - aa, qv);
    } else if (p.i0 == 2) {
        float qv = fabs(pca_gfx_fract(fy / cell) - 0.5f) * 2.0f;
        ink = pca_gfx_ss(d + aa, d - aa, qv);
    } else {
        float u = pca_gfx_fract(fx / cell) - 0.5f, v = pca_gfx_fract(fy / cell) - 0.5f;
        float qv = pca_gfx_sqrt(u * u + v * v) * 2.0f;
        float rr = pca_gfx_sqrt(d) * 1.15f;
        ink = pca_gfx_ss(rr + aa, rr - aa, qv);
    }
    PCA_GFX_PUT(pca_gfx_mix(p.bg.xyz, p.fg.xyz, ink));
}

/// t0 blurred mask (m in .x), t1 its Sobel. v0 = (graininess, relief), v1.xy light; fg, bg.
kernel void pca_gfx_fx_notePaper(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    float n = (pca_hash01(q.x, q.y, 0u, 161u) - 0.5f) * p.v0.x * 0.3f;
    float4 s = t1.read(gid);
    float fct = clamp(pca_gfx_shade(s.x, s.y, p.v1.xy, p.v0.y * 6.0f), 0.0f, 2.0f);
    float3 c = pca_gfx_mix(p.fg.xyz, p.bg.xyz, t0.read(gid).x);
    PCA_GFX_PUT((c + n) * fct);
}

/// t0 window (luma), t1 blurred luma. v0.x darkness; fg, bg.
kernel void pca_gfx_fx_photocopy(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    float l = pca_gfx_lum(t0.read(gid).xyz);
    float hp = l - t1.read(gid).x;
    float dk = p.v0.x;
    float ink = pca_gfx_ss(0.0f, 0.06f, -hp * (1.0f + dk * 8.0f)) + pca_gfx_ss(0.35f, 0.05f, l) * dk * 1.5f;
    PCA_GFX_PUT(pca_gfx_mix(p.bg.xyz, p.fg.xyz, pca_gfx_clamp01(ink)));
}

/// t0 blurred mask, t1 its Sobel. v1.xy light; fg, bg.
kernel void pca_gfx_fx_plaster(PCA_GFX_K2) {
    PCA_GFX_PROLOGUE
    float4 s = t1.read(gid);
    float fct = clamp(pca_gfx_shade(s.x, s.y, p.v1.xy, 6.0f), 0.0f, 2.0f);
    PCA_GFX_PUT(pca_gfx_mix(p.bg.xyz, p.fg.xyz, t0.read(gid).x * 0.6f) * fct);
}

/// v0.x density; v1 ink colour, v2 paper colour.
kernel void pca_gfx_fx_reticulation(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float n = 0.5f * pca_hash01(q.x, q.y, 0u, 171u) + 0.5f * pca_gfx_vnoise(float(q.x) / 1.8f, float(q.y) / 1.8f, 172u);
    float t = (1.0f - pca_gfx_lum(t0.read(gid).xyz)) + (n - 0.5f) * (0.4f + p.v0.x * 1.2f);
    PCA_GFX_PUT(pca_gfx_mix(p.v2.xyz, p.v1.xyz, pca_gfx_ss(0.45f, 0.55f, t)));
}

/// t0 blurred luma. v0.x balance; fg, bg.
kernel void pca_gfx_fx_stamp(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float bal = p.v0.x;
    PCA_GFX_PUT(pca_gfx_mix(p.bg.xyz, p.fg.xyz, pca_gfx_ss(bal + 0.02f, bal - 0.02f, t0.read(gid).x)));
}

/// t0 blurred luma. v0 = (balance, roughness, anti-alias); fg, bg.
kernel void pca_gfx_fx_tornEdges(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float bal = p.v0.x, aa = p.v0.z;
    float t = t0.read(gid).x + (pca_gfx_fbm(float(q.x) / 2.0f, float(q.y) / 2.0f, 181u) - 0.5f) * p.v0.y;
    PCA_GFX_PUT(pca_gfx_mix(p.bg.xyz, p.fg.xyz, pca_gfx_ss(bal + aa, bal - aa, t)));
}

/// t0 line-blurred window. v0 = (fiber length, brightness, contrast).
kernel void pca_gfx_fx_waterPaper(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float fl = p.v0.x, br = p.v0.y, co = p.v0.z;
    float fib = fmax(pca_gfx_strokes(q.x, q.y, int2(1, 0), fl, 1.0f, 191u), pca_gfx_strokes(q.x, q.y, int2(0, 1), fl, 1.0f, 192u));
    float3 c = t0.read(gid).xyz;
    float3 r;
    for (int i = 0; i < 3; i++) r[i] = (c[i] * (0.85f + 0.25f * fib) - 0.5f) * (co * 1.6f + 0.2f) + 0.5f + (br - 0.5f) * 0.8f;
    PCA_GFX_PUT(r);
}

// ---------------------------------------------------------------- Stylize

/// t0 blurred edge magnitudes. v0.x gain.
kernel void pca_gfx_fx_glowingEdges(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float3 e = t0.read(gid).xyz;
    float k = p.v0.x;
    PCA_GFX_PUT(float3(pca_gfx_clamp01(e.x * k), pca_gfx_clamp01(e.y * k), pca_gfx_clamp01(e.z * k)));
}

// ---------------------------------------------------------------- Texture

inline float pca_gfx_crack(float x, float y, float cell, float width) {
    float2 pt;
    float2 d = pca_gfx_voronoi(x, y, cell, 201u, pt);
    return 1.0f - pca_gfx_ss(0.0f, width, d.y - d.x);
}

/// v0 = (cell, crack width, depth, brightness), v1.xy light.
kernel void pca_gfx_fx_craquelure(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float cell = p.v0.x, width = p.v0.y, dep = p.v0.z, bri = p.v0.w;
    float fx = float(q.x) + 0.5f, fy = float(q.y) + 0.5f;
    float c0 = pca_gfx_crack(fx, fy, cell, width);
    float gx = pca_gfx_crack(fx + 1.0f, fy, cell, width) - c0, gy = pca_gfx_crack(fx, fy + 1.0f, cell, width) - c0;
    float fct = clamp(pca_gfx_shade(-gx, -gy, p.v1.xy, dep * 2.0f), 0.0f, 2.0f);
    float3 c = t0.read(gid).xyz;
    float a = 0.55f + bri * 0.5f, b = 1.0f - c0 * dep * 0.6f;
    PCA_GFX_PUT(c * a * b * fct);
}

/// v0 = (intensity, contrast), i0 grain type; fg, bg.
kernel void pca_gfx_fx_grain(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float it = p.v0.x, co = p.v0.y;
    float3 c = t0.read(gid).xyz;
    int x = q.x, y = q.y;
    float3 r;
    switch (p.i0) {
        case 1: r = float3(c.x + (pca_hash01(x, y, 0u, 211u) - 0.5f) * it * 0.4f, c.y + (pca_hash01(x, y, 1u, 211u) - 0.5f) * it * 0.4f,
                           c.z + (pca_hash01(x, y, 2u, 211u) - 0.5f) * it * 0.4f); break;
        case 2: r = pca_hash01(x, y, 3u, 211u) < it * 0.15f ? p.bg.xyz : c; break;
        case 3: { float n = pca_gfx_vnoise(float(x) / 2.0f, float(y) / 2.0f, 212u) - 0.5f; r = c + n * it * 1.2f; break; }
        case 4: { float n = pca_hash01(x, y, 4u, 211u) - 0.5f; r = (c - 0.5f) * (1.0f + it * 2.0f) + 0.5f + n * it * 0.5f; break; }
        case 5: {
            float fx = float(x) / 3.0f, fy = float(y) / 3.0f;
            r = float3(c.x + (pca_gfx_vnoise(fx, fy, 213u) - 0.5f) * it, c.y + (pca_gfx_vnoise(fx, fy, 214u) - 0.5f) * it,
                       c.z + (pca_gfx_vnoise(fx, fy, 215u) - 0.5f) * it);
            break;
        }
        case 6: { float3 st = pca_gfx_lum(c) > pca_hash01(x, y, 5u, 211u) ? p.bg.xyz : p.fg.xyz; r = pca_gfx_mix(c, st, 0.3f + it * 0.7f); break; }
        case 7: { float n = pca_gfx_vnoise(float(x) / 25.0f, float(y), 216u) - 0.5f; r = c + n * it; break; }
        case 8: { float n = pca_gfx_vnoise(float(x), float(y) / 25.0f, 217u) - 0.5f; r = c + n * it; break; }
        case 9: r = pca_hash01(x, y, 6u, 211u) < it * 0.1f ? pca_gfx_mix(c, p.fg.xyz, 0.85f) : c; break;
        default: r = float3(c.x + (pca_hash01(x, y, 0u, 211u) - 0.5f) * it * 0.8f, c.y + (pca_hash01(x, y, 1u, 211u) - 0.5f) * it * 0.8f,
                            c.z + (pca_hash01(x, y, 2u, 211u) - 0.5f) * it * 0.8f); break;
    }
    PCA_GFX_PUT((r - 0.5f) * (0.5f + co) + 0.5f);
}

inline float pca_gfx_tile_edge(float x, float y, float ts) {
    float jx = x + (pca_gfx_vnoise(x / ts * 0.7f, y / ts * 0.7f, 221u) - 0.5f) * ts * 0.3f;
    float jy = y + (pca_gfx_vnoise(x / ts * 0.7f, y / ts * 0.7f, 222u) - 0.5f) * ts * 0.3f;
    float u = pca_rem_euclid_f(jx, ts), v = pca_rem_euclid_f(jy, ts);
    return fmin(fmin(u, ts - u), fmin(v, ts - v));
}

/// v0 = (tile size, grout width, lighten grout).
kernel void pca_gfx_fx_mosaicTiles(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float ts = p.v0.x, gw = p.v0.y, lg = p.v0.z;
    float fx = float(q.x) + 0.5f, fy = float(q.y) + 0.5f;
    float de = pca_gfx_tile_edge(fx, fy, ts);
    float grout = pca_gfx_ss(gw * 0.5f + 0.7f, gw * 0.5f - 0.3f, de);
    float h1 = pca_gfx_ss(gw * 0.5f, gw * 0.5f + 2.5f, pca_gfx_tile_edge(fx - 1.0f, fy - 1.0f, ts));
    float h2 = pca_gfx_ss(gw * 0.5f, gw * 0.5f + 2.5f, pca_gfx_tile_edge(fx + 1.0f, fy + 1.0f, ts));
    float s = (h1 - h2) * 0.35f;
    float3 c = t0.read(gid).xyz;
    float l = pca_gfx_lum(c);
    float3 gc = float3(pca_gfx_clamp01(l * 0.5f + lg * 0.45f));
    PCA_GFX_PUT(pca_gfx_mix(c * (1.0f + s), gc, grout));
}

inline float pca_gfx_patch_h(float x, float y, float size) {
    int bx = pca_gfx_i32(floor(x / size)), by = pca_gfx_i32(floor(y / size));
    float u = pca_rem_euclid_f(x, size), v = pca_rem_euclid_f(y, size);
    float bevel = pca_gfx_ss(0.0f, 1.5f, fmin(fmin(u, size - u), fmin(v, size - v)));
    return pca_hash01(bx, by, 0u, 231u) * bevel;
}

/// v0 = (square size, relief).
kernel void pca_gfx_fx_patchwork(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float size = p.v0.x, rel = p.v0.y;
    float fx = float(q.x) + 0.5f, fy = float(q.y) + 0.5f;
    float bx = floor(fx / size), by = floor(fy / size);
    float3 c = pca_gfx_at(t0, p, int2(pca_gfx_i32((bx + 0.5f) * size), pca_gfx_i32((by + 0.5f) * size)));
    float s = (pca_gfx_patch_h(fx - 1.0f, fy - 1.0f, size) - pca_gfx_patch_h(fx + 1.0f, fy + 1.0f, size)) * rel * 1.5f;
    PCA_GFX_PUT(c * (1.0f + s));
}

/// v0 = (cell, border thickness, light intensity); bc, half_b; fg.
kernel void pca_gfx_fx_stainedGlass(PCA_GFX_K1) {
    PCA_GFX_PROLOGUE
    float cell = p.v0.x, bt = p.v0.y, li = p.v0.z;
    float fx = float(q.x) + 0.5f, fy = float(q.y) + 0.5f;
    float2 pt;
    float2 d = pca_gfx_voronoi(fx, fy, cell, 241u, pt);
    float border = pca_gfx_ss(bt * 0.5f + 0.6f, bt * 0.5f - 0.4f, (d.y - d.x) * 0.5f);
    float ex = fx - p.bc.x, ey = fy - p.bc.y;
    float dn = fmin(pca_gfx_sqrt(ex * ex + ey * ey) / p.half_b, 1.0f);
    float3 col = pca_gfx_at(t0, p, int2(pca_gfx_i32(pt.x), pca_gfx_i32(pt.y))) * (1.0f + li * 0.6f * (1.0f - dn));
    PCA_GFX_PUT(pca_gfx_mix(col, p.fg.xyz, border));
}
