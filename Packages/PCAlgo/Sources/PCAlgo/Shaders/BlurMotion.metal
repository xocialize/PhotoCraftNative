// Port of photocraft-algo (crates/algo/src/blur.rs: motion, radial, average_samples; blur/radial.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Motion Blur (merged bilinear taps over the premultiplied source, in first-seen order) and
// Radial Blur (Spin / Zoom samples from a CPU-built rotation/scale table, premultiplied mean).

struct pca_motion_tap {
    int dx;
    int dy;
    float w;
    float pad;
};

struct pca_motion_params {
    int count;
    int pad0;
    int pad1;
    int pad2;
};

kernel void pca_motion_blur(constant pca_frame& f [[buffer(0)]], constant pca_motion_params& p [[buffer(1)]],
                            constant pca_motion_tap* taps [[buffer(2)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool alpha = f.alpha != 0u;
    float4 acc = float4(0.0f);
    for (int i = 0; i < p.count; i++) {
        acc += taps[i].w * pca_premul(pca_get(src, f, q + int2(taps[i].dx, taps[i].dy)), alpha);
    }
    dst.write(pca_unpremul(acc, alpha), gid);
}

struct pca_radial_params {
    float2 center;
    float extent;
    uint spin;
    int max_n;
    int pad0;
    int pad1;
    int pad2;
};

kernel void pca_radial_blur(constant pca_frame& f [[buffer(0)]], constant pca_radial_params& p [[buffer(1)]],
                            const device float2* table [[buffer(2)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool alpha = f.alpha != 0u;
    float dx = float(q.x) + 0.5f - p.center.x;
    float dy = float(q.y) + 0.5f - p.center.y;
    float r = pca_sqrt(dx * dx + dy * dy);
    float path = p.extent * r;
    int n = isnan(path) ? 1 : int(clamp(ceil(path), 1.0f, float(p.max_n)));
    int start = (n - 1) * (n + 2) / 2;
    float4 acc = float4(0.0f);
    for (int i = 0; i <= n; i++) {
        float2 t = table[start + i];
        float2 s = p.spin != 0u ? float2(p.center.x + dx * t.y - dy * t.x, p.center.y + dx * t.x + dy * t.y)
                                : float2(p.center.x + dx * t.y, p.center.y + dy * t.y);
        float4 v = pca_sample(src, f, s, PCA_EDGE_TRANSPARENT, f.src_origin, f.src_size);
        if (alpha) acc += float4(v.xyz * v.w, v.w);
        else acc += v;
    }
    float k = 1.0f / float(n + 1);
    float4 res = acc * k;
    if (alpha) {
        float a = acc.w * k;
        res.xyz = a > 1e-7f ? res.xyz / a : float3(0.0f);
    }
    dst.write(res, gid);
}
