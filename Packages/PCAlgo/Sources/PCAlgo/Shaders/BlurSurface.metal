// Port of photocraft-algo (crates/algo/src/blur.rs: surface_direct), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Surface Blur: threshold-weighted window mean, transparent pixels skipped, alpha kept.

struct pca_surface_params {
    int r;
    float t;
    float pad0;
    float pad1;
};

kernel void pca_surface_blur(constant pca_frame& f [[buffer(0)]], constant pca_surface_params& p [[buffer(1)]],
                             pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool alpha = f.alpha != 0u;
    float4 v0 = pca_get(src, f, q);
    float4 acc = float4(0.0f), wsum = float4(0.0f);
    for (int yy = q.y - p.r; yy <= q.y + p.r; yy++) {
        for (int xx = q.x - p.r; xx <= q.x + p.r; xx++) {
            float4 v = pca_get(src, f, int2(xx, yy));
            if (alpha && v.w <= 0.0f) continue;
            float4 w = max(1.0f - fabs(v - v0) / p.t, 0.0f);
            acc += v * w;
            wsum += w;
        }
    }
    float4 r = select(v0, acc / wsum, wsum > 0.0f);
    if (alpha) r.w = v0.w;
    dst.write(r, gid);
}

/// `pca_surface_blur` with the threadgroup's source tile (+ radius) in threadgroup memory.
kernel void pca_surface_blur_tg(constant pca_frame& f [[buffer(0)]], constant pca_surface_params& p [[buffer(1)]],
                                pca_in src [[texture(0)]], pca_out dst [[texture(1)]], threadgroup float4* tile [[threadgroup(0)]],
                                uint2 gid [[thread_position_in_grid]], uint2 lid [[thread_position_in_threadgroup]],
                                uint2 tsize [[threads_per_threadgroup]]) {
    int r = p.r;
    int tw = int(tsize.x) + 2 * r, th = int(tsize.y) + 2 * r;
    int2 base = f.out_origin + int2(gid - lid) - int2(r);
    for (int i = int(lid.y * tsize.x + lid.x); i < tw * th; i += int(tsize.x * tsize.y)) {
        tile[i] = pca_get(src, f, base + int2(i % tw, i / tw));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool alpha = f.alpha != 0u;
    int cx = int(lid.x) + r, cy = int(lid.y) + r;
    float4 v0 = tile[cy * tw + cx];
    float4 acc = float4(0.0f), wsum = float4(0.0f);
    for (int yy = cy - r; yy <= cy + r; yy++) {
        for (int xx = cx - r; xx <= cx + r; xx++) {
            float4 v = tile[yy * tw + xx];
            if (alpha && v.w <= 0.0f) continue;
            float4 w = max(1.0f - fabs(v - v0) / p.t, 0.0f);
            acc += v * w;
            wsum += w;
        }
    }
    float4 res = select(v0, acc / wsum, wsum > 0.0f);
    if (alpha) res.w = v0.w;
    dst.write(res, gid);
}
