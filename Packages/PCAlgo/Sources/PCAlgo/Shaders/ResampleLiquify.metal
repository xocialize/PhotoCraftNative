// Port of photocraft-algo (crates/algo/src/liquify.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Liquify's resampling (photocraft `apply_liquify`): the node field upsampled per pixel with
// Catmull-Rom (nodes clamped to the grid), the 256-px tiles where it moves marked, then the source
// sampled at p + d(p) with premultiplied Catmull-Rom, taps clamped to the tile grown by the largest
// displacement (within the field bounds); tiles that don't move are copied untouched.

struct pca_rs_liquify_params {
    int2 b_origin;    // field bounds
    int2 b_size;
    int2 grid;        // field nodes (w, h)
    int2 tile_origin; // document origin of the tile grid
    int tiles_x;
    int maxd;         // ceil(max displacement) + 3
    float cell;       // document pixels per node
    int pad0;
};

inline int pca_rs_liquify_tile(constant pca_rs_liquify_params& p, int2 q) {
    int2 t = (q - p.tile_origin) / 256;
    return t.y * p.tiles_x + t.x;
}

/// The field at every pixel of the bounds in a touched tile (photocraft `sample_cubic`); marks the
/// tiles where it is non-zero.
kernel void pca_rs_liquify_field(constant pca_frame& f [[buffer(0)]], constant pca_rs_liquify_params& p [[buffer(1)]],
                                 device const float2* nodes [[buffer(2)]], device const uint* touched [[buffer(3)]],
                                 device atomic_uint* moved [[buffer(4)]], pca_out disp [[texture(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.b_size.x || int(gid.y) >= p.b_size.y) return;
    int2 q = p.b_origin + int2(gid);
    int tile = pca_rs_liquify_tile(p, q);
    if (touched[tile] == 0u) return;
    float gx = float(q.x - p.b_origin.x) / p.cell, gy = float(q.y - p.b_origin.y) / p.cell;
    float fgx = floor(gx), fgy = floor(gy);
    float4 wx = pca_rs_catmull(gx - fgx), wy = pca_rs_catmull(gy - fgy);
    int ix = int(fgx), iy = int(fgy);
    float2 acc = float2(0.0f);
    for (int jj = 0; jj < 4; jj++) {
        int y = clamp(iy - 1 + jj, 0, p.grid.y - 1);
        for (int ii = 0; ii < 4; ii++) {
            int x = clamp(ix - 1 + ii, 0, p.grid.x - 1);
            float k = wx[ii] * wy[jj];
            float2 v = nodes[y * p.grid.x + x];
            acc.x += v.x * k;
            acc.y += v.y * k;
        }
    }
    disp.write(float4(acc, 0.0f, 0.0f), gid);
    if (acc.x != 0.0f || acc.y != 0.0f) atomic_store_explicit(&moved[tile], 1u, memory_order_relaxed);
}

/// One output pixel: the source where nothing moves, else the premultiplied Catmull-Rom sample at
/// p + d(p) (snapped to the pixel grid within 1e-7).
kernel void pca_rs_liquify(constant pca_frame& f [[buffer(0)]], constant pca_rs_liquify_params& p [[buffer(1)]],
                           device const float2* nodes [[buffer(2)]], device const uint* touched [[buffer(3)]],
                           device atomic_uint* moved [[buffer(4)]], pca_in src [[texture(0)]], pca_in disp [[texture(1)]],
                           pca_out dst [[texture(2)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 s0 = pca_get(src, f, q);
    int2 bq = q - p.b_origin;
    if (bq.x < 0 || bq.y < 0 || bq.x >= p.b_size.x || bq.y >= p.b_size.y) { dst.write(s0, gid); return; }
    int tile = pca_rs_liquify_tile(p, q);
    if (touched[tile] == 0u || atomic_load_explicit(&moved[tile], memory_order_relaxed) == 0u) { dst.write(s0, gid); return; }
    bool alpha = f.alpha != 0u;
    float2 d = disp.read(uint2(bq)).xy;
    float flx = floor(d.x), frx = d.x - flx, fly = floor(d.y), fry = d.y - fly;
    if (frx < 1e-7f) frx = 0.0f; else if (frx > 1.0f - 1e-7f) { frx = 0.0f; flx += 1.0f; }
    if (fry < 1e-7f) fry = 0.0f; else if (fry > 1.0f - 1e-7f) { fry = 0.0f; fly += 1.0f; }
    int ix = q.x + int(flx), iy = q.y + int(fly);
    // The tile (clipped to the bounds) grown by the largest displacement, within the bounds.
    int2 t0 = p.tile_origin + ((q - p.tile_origin) / 256) * 256;
    int2 blo = p.b_origin, bhi = p.b_origin + p.b_size;
    int2 lo = max(max(t0, blo) - p.maxd, blo), hi = min(min(t0 + 256, bhi) + p.maxd, bhi) - 1;
    float4 wx = pca_rs_catmull(frx), wy = pca_rs_catmull(fry);
    float4 acc = float4(0.0f);
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            float k = wx[i] * wy[j];
            if (k == 0.0f) continue;
            int2 pp = clamp(int2(ix - 1 + i, iy - 1 + j), lo, hi);
            acc += pca_premul(pca_get(src, f, pp), alpha) * k;
        }
    }
    if (alpha) {
        float al = clamp(acc.w, 0.0f, 1.0f);
        float3 c = al > 0.0f ? clamp(acc.xyz / al, 0.0f, 1.0f) : float3(0.0f);
        dst.write(float4(c, al), gid);
    } else {
        dst.write(clamp(acc, 0.0f, 1.0f), gid);
    }
}
