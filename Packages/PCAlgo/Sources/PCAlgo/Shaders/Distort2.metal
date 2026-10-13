// Port of photocraft-algo (crates/algo/src/distort2.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Displace, Shear and ZigZag: photocraft `distort::remap` per output pixel (helpers in
// Distort.metal). Displace reads its map from a buffer of (horizontal, vertical) channel pairs;
// Shear reads per-row offsets computed in Swift.

/// Rust's saturating `f32 as i32` of a floored coordinate, kept within ±1e9 (DistortKit.floorToInt).
inline int pca_dis_floor_i(float v) {
    if (isnan(v)) return 0;
    return int(clamp(v, -1e9f, 1e9f));
}

struct pca_dis_displace_params {
    float2 b0;      // bounds origin
    float2 bsize;   // bounds size, each ≥ 1
    float2 msize;   // map size
    float2 scale;   // px at full contrast
    int2 mdim;      // map size (texels)
    uint stretch;
    uint edge;
};

/// One clamped map texel (photocraft `map_sample`'s `g`).
inline float2 pca_dis_map_texel(device const float2* m, int2 dim, int x, int y) {
    int xx = clamp(x, 0, dim.x - 1), yy = clamp(y, 0, dim.y - 1);
    return m[yy * dim.x + xx];
}

/// photocraft `map_sample` for both displacement channels at map-local (u, v).
inline float2 pca_dis_map_sample(device const float2* m, int2 dim, float u, float v) {
    float fx = u - 0.5f, fy = v - 0.5f;
    float flx = floor(fx), fly = floor(fy);
    float ax = fx - flx, ay = fy - fly;
    int x0 = pca_dis_floor_i(flx), y0 = pca_dis_floor_i(fly);
    float2 g00 = pca_dis_map_texel(m, dim, x0, y0), g10 = pca_dis_map_texel(m, dim, x0 + 1, y0);
    float2 g01 = pca_dis_map_texel(m, dim, x0, y0 + 1), g11 = pca_dis_map_texel(m, dim, x0 + 1, y0 + 1);
    float2 top = g00 + (g10 - g00) * ax;
    float2 bot = g01 + (g11 - g01) * ax;
    return top + (bot - top) * ay;
}

kernel void pca_dis_displace(constant pca_frame& f [[buffer(0)]], constant pca_dis_displace_params& p [[buffer(1)]],
                             device const float2* map [[buffer(2)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float2 xy = pca_dis_centre_of(q);
    float lx = xy.x - p.b0.x, ly = xy.y - p.b0.y;
    float u, v;
    if (p.stretch != 0u) {
        u = lx / p.bsize.x * p.msize.x;
        v = ly / p.bsize.y * p.msize.y;
    } else {
        u = pca_dis_rem_euclid(lx, p.msize.x);
        v = pca_dis_rem_euclid(ly, p.msize.y);
    }
    float2 m = pca_dis_map_sample(map, p.mdim, u, v);
    float dx = (m.x - 0.5f) * 2.0f * p.scale.x;
    float dy = (m.y - 0.5f) * 2.0f * p.scale.y;
    dst.write(pca_dis_at(src, f, float2(xy.x + dx, xy.y + dy), p.edge), gid);
}

struct pca_dis_shear_params {
    int rows;
    uint edge;
    int pad0;
    int pad1;
};

/// `rows[i]` = the horizontal offset of output row i.
kernel void pca_dis_shear(constant pca_frame& f [[buffer(0)]], constant pca_dis_shear_params& p [[buffer(1)]],
                          device const float* rows [[buffer(2)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float2 xy = pca_dis_centre_of(q);
    int i = clamp(q.y - f.out_origin.y, 0, p.rows - 1);
    dst.write(pca_dis_at(src, f, float2(xy.x - rows[i], xy.y), p.edge), gid);
}

struct pca_dis_zigzag_params {
    float2 c;
    float rr;
    float a;
    float k;
    uint style;   // 0 around centre, 1 out from centre, 2 pond ripples
    int pad0;
    int pad1;
};

kernel void pca_dis_zigzag(constant pca_frame& f [[buffer(0)]], constant pca_dis_zigzag_params& p [[buffer(1)]],
                           pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float2 xy = pca_dis_centre_of(q);
    float dx = xy.x - p.c.x, dy = xy.y - p.c.y;
    float r = sqrt(dx * dx + dy * dy);
    float2 s = xy;
    if (!(r >= p.rr || r <= 0.0f || p.a == 0.0f)) {
        float rn = r / p.rr;
        float wave = sin(PCA_DIS_TAU * p.k * rn) * (1.0f - rn);
        float radial = 0.0f, angular = 0.0f;
        if (p.style == 1u) {
            radial = p.a * wave * p.rr / (4.0f * p.k);
        } else if (p.style == 0u) {
            angular = p.a * wave * PCA_DIS_PI / (2.0f * p.k);
        } else {
            radial = p.a * wave * p.rr / (8.0f * p.k);
            angular = p.a * wave * PCA_DIS_PI / (4.0f * p.k);
        }
        float th = pca_dis_atan2(dy, dx) + angular;
        float rs = max(r + radial, 0.0f);
        s = float2(p.c.x + rs * cos(th), p.c.y + rs * sin(th));
    }
    dst.write(pca_dis_at(src, f, s, PCA_EDGE_REPEAT), gid);
}
