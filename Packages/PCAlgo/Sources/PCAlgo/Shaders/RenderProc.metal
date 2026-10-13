// Port of photocraft-algo (crates/algo/src/render2.rs: `Prim::eval`, `lerp4`, `raster_tile`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Render › Flame / Picture Frame / Tree rasterisation: every pixel blends, in list order, the
// primitives of its bin whose bounds contain it (exactly the primitives photocraft's
// `raster_tile` visits for that pixel) into a premultiplied RGBA paint buffer. Same operations
// as RenderProcKit.rasterTile; `pca_sqrt` is correctly rounded like Swift's `squareRoot`.

struct pca_rp_prim {
    int kind;     // 0 capsule, 1 ellipse
    int blend;    // 0 normal, 1 add, 2 lighten
    float soft;
    int same;     // c0 == c1
    float4 c0;
    float4 c1;
    float4 g0;    // capsule (ax, ay, bx, by) / ellipse (cx, cy, rx, ry)
    float4 g1;    // capsule (ra, rb) / ellipse (sin, cos) of the angle
    int bx0;
    int by0;
    int bx1;
    int by1;
};

struct pca_rp_params {
    int2 origin;      // the used rectangle: pixels outside it stay 0
    int2 size;
    int2 bin_origin;  // first bin (div_euclid by bin_size)
    int2 bins;        // bins across the grid, active bins in this dispatch
    int bin_size;
    int pad0;
    int pad1;
    int pad2;
};

inline int pca_rp_div_euclid(int a, int b) {
    int q = a / b;
    return a % b < 0 ? q - 1 : q;
}

/// photocraft `Prim::eval`: coverage and colour position at a pixel centre.
inline float2 pca_rp_eval(device const pca_rp_prim& p, float x, float y) {
    float soft = fmax(p.soft, 1.0f);
    if (p.kind == 0) {
        float ax = p.g0.x, ay = p.g0.y;
        float dx = p.g0.z - ax, dy = p.g0.w - ay;
        float l2 = dx * dx + dy * dy;
        float t = l2 > 1e-9f ? clamp(((x - ax) * dx + (y - ay) * dy) / l2, 0.0f, 1.0f) : 0.0f;
        float px = ax + dx * t - x, py = ay + dy * t - y;
        float d = pca_sqrt(px * px + py * py);
        float ra = p.g1.x, rb = p.g1.y;
        float r = ra + (rb - ra) * t;
        // Hairlines thinner than a pixel fade instead of vanishing.
        float thin = clamp(2.0f * r, 0.0f, 1.0f);
        return float2(clamp((fmax(r, 0.5f) - d) / soft + 0.5f, 0.0f, 1.0f) * thin, t);
    }
    float s = p.g1.x, co = p.g1.y;
    float dx = x - p.g0.x, dy = y - p.g0.y;
    float u = dx * co + dy * s, v = -dx * s + dy * co;
    float rx = fmax(p.g0.z, 0.05f), ry = fmax(p.g0.w, 0.05f);
    float ux = u / rx, vy = v / ry;
    float e = pca_sqrt(ux * ux + vy * vy);
    float edge = (1.0f - e) * fmin(rx, ry);
    float thin = clamp(2.0f * fmin(rx, ry), 0.0f, 1.0f);
    return float2(clamp(edge / soft + 0.5f, 0.0f, 1.0f) * thin, fmin(e, 1.0f));
}

/// gid.y = active bin (its grid index in `active`), gid.x = pixel inside the bin; the bin's
/// primitives are bin_idx[bin_start[gid.y] ..< bin_start[gid.y + 1]].
kernel void pca_rp_raster(constant pca_frame& f [[buffer(0)]], constant pca_rp_params& p [[buffer(1)]],
                          device const pca_rp_prim* prims [[buffer(2)]], device const int* active [[buffer(3)]],
                          device const uint* bin_start [[buffer(4)]], device const uint* bin_idx [[buffer(5)]],
                          device float4* paint [[buffer(6)]], uint2 gid [[thread_position_in_grid]]) {
    int bs = p.bin_size;
    if (int(gid.x) >= bs * bs || int(gid.y) >= p.bins.y) return;
    int bin = active[gid.y];
    int x = (p.bin_origin.x + bin % p.bins.x) * bs + int(gid.x) % bs;
    int y = (p.bin_origin.y + bin / p.bins.x) * bs + int(gid.x) / bs;
    float4 d = float4(0.0f);
    if (x >= p.origin.x && y >= p.origin.y && x < p.origin.x + p.size.x && y < p.origin.y + p.size.y) {
        float fx = float(x) + 0.5f, fy = float(y) + 0.5f;
        for (uint i = bin_start[gid.y]; i < bin_start[gid.y + 1u]; i++) {
            device const pca_rp_prim& q = prims[bin_idx[i]];
            if (x < q.bx0 || x >= q.bx1 || y < q.by0 || y >= q.by1) continue;
            float2 ev = pca_rp_eval(q, fx, fy);
            float cov = ev.x, ct = ev.y;
            if (cov <= 0.0f) continue;
            float4 c = q.same != 0 ? q.c0 : float4(q.c0.x + (q.c1.x - q.c0.x) * ct, q.c0.y + (q.c1.y - q.c0.y) * ct,
                                                  q.c0.z + (q.c1.z - q.c0.z) * ct, q.c0.w + (q.c1.w - q.c0.w) * ct);
            float a = clamp(c.w * cov, 0.0f, 1.0f);
            if (a <= 0.0f) continue;
            if (q.blend == 1) {
                d.x += c.x * a; d.y += c.y * a; d.z += c.z * a;
                d.w += a * (1.0f - d.w);
            } else if (q.blend == 2) {
                d.x = fmax(d.x, c.x * a); d.y = fmax(d.y, c.y * a); d.z = fmax(d.z, c.z * a);
                d.w = fmax(d.w, a);
            } else {
                float k = 1.0f - a;
                d.x = c.x * a + d.x * k; d.y = c.y * a + d.y * k; d.z = c.z * a + d.z * k;
                d.w = a + d.w * k;
            }
        }
    }
    paint[gid.y * uint(bs * bs) + gid.x] = d;
}
