// Port of photocraft-algo (crates/algo/src/relight.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Relight (`.joint`; `pca_ren_rgba` / `pca_ren_native` from Render.metal). Per band of the output:
// `pca_ren_relight_luma` writes the (Rec. 709 luma, weight) field over the band grown by the
// read radius, `GPUPass.encodeGaussBlurN` blurs it (fxutil `gauss_blur_n`, edges clamped to the
// field), and `pca_ren_relight_shade` replaces the shading with the lamp. All intermediates are
// addressed through the explicit field origin/size in the params.

struct pca_ren_relight_params {
    int2 y_origin;     // the luma field (band grown by the read radius)
    int2 y_size;
    int2 dst_origin;   // document coordinates of dst texel (0, 0)
    int step;
    float amb;
    float4 ldir;       // light direction; w = intensity 0…1
    float4 lcol;
};

inline bool pca_ren_finite4(float4 v) { return isfinite(v.x) && isfinite(v.y) && isfinite(v.z) && isfinite(v.w); }

kernel void pca_ren_relight_luma(constant pca_frame& f [[buffer(0)]], constant pca_ren_relight_params& p [[buffer(1)]],
                                 pca_in src [[texture(0)]], pca_out field [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.y_size.x || int(gid.y) >= p.y_size.y) return;
    int2 q = p.y_origin + int2(gid);
    float4 c = pca_ren_rgba(pca_get(src, f, q), f);
    float v = NAN;
    if (pca_ren_finite4(c)) {
        float a = f.alpha != 0u ? c.w : 1.0f;
        if (a > 0.0f && isfinite(a)) v = 0.2126f * c.x + 0.7152f * c.y + 0.0722f * c.z;
    }
    // Non-finite and transparent samples are held out of the blur (weight 0).
    field.write(isfinite(v) ? float4(v, 1.0f, 0.0f, 0.0f) : float4(0.0f), gid);
}

/// photocraft `sample_y` of the blurred field (`blur_channel`'s acc / weight, 0.5 where empty),
/// clamped to the field.
inline float pca_ren_relight_y(pca_in t, constant pca_ren_relight_params& p, int2 at) {
    int2 c = clamp(at, p.y_origin, p.y_origin + p.y_size - 1) - p.y_origin;
    float4 v = t.read(uint2(c));
    float acc = v.x, wgt = v.y;
    float s = (wgt > 1e-6f && isfinite(acc) && isfinite(wgt)) ? acc / wgt : 0.5f;
    return isfinite(s) ? s : 0.04f;
}

/// photocraft relight's `norm3` (non-finite or tiny → straight up).
inline float3 pca_ren_relight_norm3(float3 v) {
    float m = sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    if (!isfinite(m) || m < 1e-9f) return float3(0.0f, 0.0f, 1.0f);
    return v / m;
}

kernel void pca_ren_relight_shade(constant pca_frame& f [[buffer(0)]], constant pca_ren_relight_params& p [[buffer(1)]],
                                  pca_in src [[texture(0)]], pca_in field [[texture(1)]], pca_out dst [[texture(2)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    uint2 w = uint2(q - p.dst_origin);
    bool alpha = f.alpha != 0u;
    float4 px = pca_get(src, f, q);
    float a = alpha ? px.w : 1.0f;
    float4 c = pca_ren_rgba(px, f);
    if (!pca_ren_finite4(px) || (alpha && a <= 0.0f) || !pca_ren_finite4(c)) {
        dst.write(px, w);
        return;
    }
    float s0 = max(pca_ren_relight_y(field, p, q), 0.04f);
    float nx = (pca_ren_relight_y(field, p, q - int2(p.step, 0)) - pca_ren_relight_y(field, p, q + int2(p.step, 0))) * 2.0f;
    float ny = (pca_ren_relight_y(field, p, q - int2(0, p.step)) - pca_ren_relight_y(field, p, q + int2(0, p.step))) * 2.0f;
    float3 nrm = pca_ren_relight_norm3(float3(nx, ny, 1.0f));
    float ndl = max(nrm.x * p.ldir.x + nrm.y * p.ldir.y + nrm.z * p.ldir.z, 0.0f);
    float shade = p.amb + p.ldir.w * ndl;
    float4 o = c;
    o.xyz = (c.xyz / s0) * shade * p.lcol.xyz;
    if (!pca_ren_finite4(o)) {
        dst.write(px, w);
        return;
    }
    float4 r = pca_ren_native(o, f);
    if (alpha) r.w = a;
    dst.write(r, w);
}
