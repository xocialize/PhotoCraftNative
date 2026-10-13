// Port of photocraft-algo (crates/algo/src/denoise.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Reduce Noise on the GPU: luma/chroma decomposition (.x luma, .y/.z chroma), JPEG deblocking,
// the guided filter as moments → box → (a, b) → box → apply, luma sharpening, recomposition.

struct pca_rn_params {
    uint model;   // 0 gray, 1 YCC (RGB), 2 Lab
    uint chan;    // plane channel the guided filter smooths
    float k;
    float eps;
};

kernel void pca_rn_decompose(constant pca_frame& f [[buffer(0)]], constant pca_rn_params& p [[buffer(1)]],
                             pca_in src [[texture(0)]], pca_out yc [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q);
    float4 o = float4(0.0f);
    if (p.model == 0u) o.x = v.x;
    else if (p.model == 2u) o.xyz = v.xyz;
    else {
        float l = 0.299f * v.x + 0.587f * v.y + 0.114f * v.z;
        o = float4(l, v.z - l, v.x - l, 0.0f);
    }
    yc.write(o, gid);
}

kernel void pca_rn_jpeg(constant pca_frame& f [[buffer(0)]], constant pca_rn_params& p [[buffer(1)]],
                        pca_in yc [[texture(0)]], pca_out o [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = yc.read(gid);
    int xx = int(gid.x), yy = int(gid.y);
    if (xx >= 1 && yy >= 1 && xx < f.out_size.x - 1 && yy < f.out_size.y - 1) {
        int dx = pca_rem_euclid(q.x, 8), dy = pca_rem_euclid(q.y, 8);
        if (dx == 0 || dx == 7 || dy == 0 || dy == 7) {
            float a = 0.0f;
            for (int j = 0; j < 3; j++)
                for (int k = 0; k < 3; k++) a += yc.read(uint2(xx + k - 1, yy + j - 1)).x;
            v.x = 0.5f * v.x + 0.5f * a / 9.0f;
        }
    }
    o.write(v, gid);
}

/// Moments of guide (luma, .x) and input (channel `chan`): (g, p, g², g·p).
kernel void pca_rn_moments(constant pca_frame& f [[buffer(0)]], constant pca_rn_params& p [[buffer(1)]],
                           pca_in yc [[texture(0)]], pca_out m [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = yc.read(gid);
    float g = v.x, x = v[p.chan];
    m.write(float4(g, x, g * g, g * x), gid);
}

kernel void pca_rn_ab(constant pca_frame& f [[buffer(0)]], constant pca_rn_params& p [[buffer(1)]],
                      pca_in m [[texture(0)]], pca_out ab [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = m.read(gid);
    float mg = v.x, mp = v.y, mgg = v.z, mgp = v.w;
    float var = max(mgg - mg * mg, 0.0f);
    float a = (mgp - mg * mp) / (var + p.eps);
    ab.write(float4(a, mp - a * mg, 0.0f, 0.0f), gid);
}

kernel void pca_rn_apply(constant pca_frame& f [[buffer(0)]], constant pca_rn_params& p [[buffer(1)]],
                         pca_in yc [[texture(0)]], pca_in ab [[texture(1)]], pca_out o [[texture(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = yc.read(gid);
    float4 c = ab.read(gid);
    float d = c.x * v.x + c.y;
    v[p.chan] += (d - v[p.chan]) * p.k;
    o.write(v, gid);
}

kernel void pca_rn_sharpen(constant pca_frame& f [[buffer(0)]], constant pca_rn_params& p [[buffer(1)]],
                           pca_in yc [[texture(0)]], pca_in bl [[texture(1)]], pca_out o [[texture(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = yc.read(gid);
    v.x += (v.x - bl.read(gid).x) * p.k;
    o.write(v, gid);
}

kernel void pca_rn_compose(constant pca_frame& f [[buffer(0)]], constant pca_rn_params& p [[buffer(1)]],
                           pca_in src [[texture(0)]], pca_in yc [[texture(1)]], pca_out dst [[texture(2)]],
                           uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 o = pca_get(src, f, q);
    float4 v = yc.read(uint2(q - f.src_origin));
    if (p.model == 0u) o.x = v.x;
    else if (p.model == 2u) o.xyz = v.xyz;
    else {
        float l = v.x;
        float b = v.y + l, r = v.z + l;
        float g = (l - 0.299f * r - 0.114f * b) / 0.587f;
        o.xyz = float3(r, g, b);
    }
    dst.write(o, gid);
}
