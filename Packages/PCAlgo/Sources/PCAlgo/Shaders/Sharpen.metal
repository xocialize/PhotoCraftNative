// Port of photocraft-algo (crates/algo/src/sharpen.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Unsharp Mask / Smart Sharpen / High Pass: the original against its exact Gaussian blur
// (computed by pca_conv_h/pca_conv_v into `blur`, which covers the output).

struct pca_sharpen_params {
    uint op;   // 0 unsharp, 1 smart, 2 high pass
    float k;
    float t;
    float nr;
};

kernel void pca_sharpen_combine(constant pca_frame& f [[buffer(0)]], constant pca_sharpen_params& p [[buffer(1)]],
                                pca_in src [[texture(0)]], pca_in blur [[texture(1)]], pca_out dst [[texture(2)]],
                                uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 o = pca_get(src, f, q);
    bool alpha = f.alpha != 0u;
    if (alpha && o.w <= 0.0f) { dst.write(o, gid); return; }
    float4 b = blur.read(gid);
    float4 r = o;
    int cc = alpha ? 3 : 4;
    for (int c = 0; c < cc; c++) {
        float ov = o[c];
        float d = ov - b[c];
        float v;
        if (p.op == 0u) {
            v = fabs(d) + 1e-6f >= p.t ? ov + p.k * d : ov;
        } else if (p.op == 1u) {
            float keep = 1.0f - p.nr * exp(-(fabs(d) * 40.0f));
            v = ov + p.k * d * keep;
        } else {
            v = 0.5f + d;
        }
        r[c] = v;
    }
    dst.write(r, gid);
}
