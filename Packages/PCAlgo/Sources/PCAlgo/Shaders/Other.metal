// Port of photocraft-algo (crates/algo/src/other.rs, other2.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Minimum / Maximum (square: separable passes; round: the disc row by row), Offset, Custom.

struct pca_minmax_params {
    int2 tmp_origin;
    int2 tmp_size;
    int radius;
    uint is_max;
    int rows;
    int pad0;
};

inline float4 pca_pick(float4 a, float4 b, bool is_max) { return is_max ? fmax(a, b) : fmin(a, b); }

/// Square: the extreme over x − r … x + r of every row the vertical pass needs (0 outside src).
kernel void pca_minmax_h(constant pca_frame& f [[buffer(0)]], constant pca_minmax_params& p [[buffer(1)]],
                         pca_in src [[texture(0)]], pca_out tmp [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.tmp_size.x || int(gid.y) >= p.tmp_size.y) return;
    bool mx = p.is_max != 0u;
    int2 q = p.tmp_origin + int2(gid);
    float4 m = pca_get(src, f, int2(q.x - p.radius, q.y));
    for (int i = -p.radius + 1; i <= p.radius; i++) m = pca_pick(m, pca_get(src, f, int2(q.x + i, q.y)), mx);
    tmp.write(m, gid);
}

kernel void pca_minmax_v(constant pca_frame& f [[buffer(0)]], constant pca_minmax_params& p [[buffer(1)]],
                         pca_in tmp [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool mx = p.is_max != 0u;
    int tx = q.x - p.tmp_origin.x, ty = q.y - p.tmp_origin.y;
    float4 m = tmp.read(uint2(tx, ty - p.radius));
    for (int i = -p.radius + 1; i <= p.radius; i++) m = pca_pick(m, tmp.read(uint2(tx, ty + i)), mx);
    dst.write(m, gid);
}

/// Round: every offset of the disc (row half-widths precomputed as photocraft does).
kernel void pca_minmax_round(constant pca_frame& f [[buffer(0)]], constant pca_minmax_params& p [[buffer(1)]],
                             constant int* hw [[buffer(2)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool mx = p.is_max != 0u;
    float4 m = float4(mx ? -FLT_MAX : FLT_MAX);
    for (int j = 0; j < p.rows; j++) {
        int dy = j - p.radius;
        int h = hw[j];
        for (int dx = -h; dx <= h; dx++) m = pca_pick(m, pca_get(src, f, q + int2(dx, dy)), mx);
    }
    dst.write(m, gid);
}

struct pca_offset_params {
    int dx;
    int dy;
    uint edge;
    uint pad;
};

kernel void pca_offset(constant pca_frame& f [[buffer(0)]], constant pca_offset_params& p [[buffer(1)]],
                       pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    dst.write(pca_get_edge(src, f, q - int2(p.dx, p.dy), p.edge, f.bounds_origin, f.bounds_size), gid);
}

struct pca_custom_tap {
    int dx;
    int dy;
    float w;
    float pad;
};

struct pca_custom_params {
    int count;
    float scale;
    float offset;
    float sub;   // 1: channel values are ink (CMYK); the kernel runs on 1 − ink
};

kernel void pca_custom(constant pca_frame& f [[buffer(0)]], constant pca_custom_params& p [[buffer(1)]],
                       constant pca_custom_tap* taps [[buffer(2)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 o = pca_get(src, f, q);
    if (p.count == 0) { dst.write(o, gid); return; }
    float4 sum = float4(0.0f);
    bool ink = p.sub != 0.0f;
    for (int i = 0; i < p.count; i++) {
        float4 t = pca_get(src, f, q + int2(taps[i].dx, taps[i].dy));
        sum += (ink ? 1.0f - t : t) * taps[i].w;
    }
    float4 v = sum / p.scale + p.offset;
    if (ink) v = 1.0f - v;
    if (f.alpha != 0u) v.w = o.w;
    dst.write(v, gid);
}
