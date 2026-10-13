// Port of photocraft-algo (crates/algo/src/lens.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Lens Correction (photocraft `LensMap::sample` + `remap_impl`): pass 1 maps every pixel of the
// 128-px tiles covering the output (f32) and folds each tile's sample bounds into atomics (the
// source window photocraft reads per tile); pass 2 samples premultiplied Catmull-Rom with taps
// clamped to the frame and the tile's window, applies lateral CA, gain, edge mode.

struct pca_geo_lens_params {
    float2 c;
    float r;
    float scale;
    float rot_s;
    float rot_c;
    float m6;
    float m7;
    float m8;
    float k1;
    float k2;
    float p1;
    float p2;
    float ca_r;
    float ca_b;
    float vig_amount;
    float4 vig;       // v1, v2, v3, midpoint
    float4 edge_px;   // edge colour in this plane's layout
    int2 cover_origin;
    int2 cover_size;
    int2 cell_origin; // document origin of the first covering tile
    int tiles_x;
    int mode;         // 0 other, 1 RGB (CA), 2 CMYK, 3 Lab
    int2 frame_lo;
    int2 frame_hi;
    uint src_alpha;
    uint out_alpha;
    uint clip;
    uint edge_kind;   // 0 extension, 1 transparency, 2 colour
};

/// photocraft `photo_util::catmull_rom` (f32).
inline float4 pca_geo_catmull(float t) {
    float t2 = t * t, t3 = t2 * t;
    return float4(-0.5f * t3 + t2 - 0.5f * t, 1.5f * t3 - 2.5f * t2 + 1.0f, -1.5f * t3 + 2.0f * t2 + 0.5f * t, 0.5f * t3 - 0.5f * t2);
}

inline int pca_geo_lens_tile(constant pca_geo_lens_params& p, int2 q) {
    int2 t = (q - p.cell_origin) / 128;
    return t.y * p.tiles_x + t.x;
}

inline void pca_geo_bbox_add(device atomic_int* bb, float2 v) {
    if (!isfinite(v.x) || !isfinite(v.y)) return;
    atomic_fetch_min_explicit(&bb[0], int(clamp(floor(v.x), -1e9f, 1e9f)), memory_order_relaxed);
    atomic_fetch_min_explicit(&bb[1], int(clamp(floor(v.y), -1e9f, 1e9f)), memory_order_relaxed);
    atomic_fetch_max_explicit(&bb[2], int(clamp(ceil(v.x), -1e9f, 1e9f)), memory_order_relaxed);
    atomic_fetch_max_explicit(&bb[3], int(clamp(ceil(v.y), -1e9f, 1e9f)), memory_order_relaxed);
}

/// Pass 1: where every pixel of the covering tiles samples (photocraft `LensMap::sample`):
/// t1 = (p, pr), t2 = (pb, gain, valid).
kernel void pca_geo_lens_map(constant pca_frame& f [[buffer(0)]], constant pca_geo_lens_params& p [[buffer(1)]],
                             device atomic_int* bbox [[buffer(2)]], pca_out t1 [[texture(0)]], pca_out t2 [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.cover_size.x || int(gid.y) >= p.cover_size.y) return;
    int2 q = p.cover_origin + int2(gid);
    // Undo scale and rotation (about the centre).
    float dx = (float(q.x) + 0.5f - p.c.x) / p.scale, dy = (float(q.y) + 0.5f - p.c.y) / p.scale;
    float rx = p.rot_c * dx + p.rot_s * dy, ry = -p.rot_s * dx + p.rot_c * dy;
    // Undo the keystone.
    float nx = rx / p.r, ny = ry / p.r;
    float w = p.m6 * nx + p.m7 * ny + p.m8;
    if (w <= 0.05f) {
        t1.write(float4(0.0f), gid);
        t2.write(float4(0.0f), gid);
        return;
    }
    float ux = nx / w, uy = ny / w;
    // Brown–Conrady.
    float r2 = ux * ux + uy * uy;
    float radial = 1.0f + p.k1 * r2 + p.k2 * r2 * r2;
    float sx = ux * radial + 2.0f * p.p1 * ux * uy + p.p2 * (r2 + 2.0f * ux * ux);
    float sy = uy * radial + p.p1 * (r2 + 2.0f * uy * uy) + 2.0f * p.p2 * ux * uy;
    float kr = 1.0f + p.ca_r, kb = 1.0f + p.ca_b;
    float2 pp = float2(p.c.x + sx * 1.0f * p.r, p.c.y + sy * 1.0f * p.r);
    float2 pr = float2(p.c.x + sx * kr * p.r, p.c.y + sy * kr * p.r);
    float2 pb = float2(p.c.x + sx * kb * p.r, p.c.y + sy * kb * p.r);
    // Vignetting on the source radius.
    float rs2 = sx * sx + sy * sy;
    float falloff = max(1.0f + p.vig.x * rs2 + p.vig.y * rs2 * rs2 + p.vig.z * rs2 * rs2 * rs2, 0.05f);
    float start = (1.0f - p.vig.w) * 0.9f;
    float t = clamp((sqrt(rs2) - start) / (1.0f - start + 1e-9f), 0.0f, 1.0f);
    float ramp = t * t * (3.0f - 2.0f * t);
    float gain = exp2(p.vig_amount * 1.5f * ramp) / falloff;
    t1.write(float4(pp, pr), gid);
    t2.write(float4(pb, gain, 1.0f), gid);
    device atomic_int* bb = bbox + pca_geo_lens_tile(p, q) * 4;
    pca_geo_bbox_add(bb, pp);
    pca_geo_bbox_add(bb, pr);
    pca_geo_bbox_add(bb, pb);
}

/// Premultiplied Catmull-Rom at `pos` (pixel centres at +0.5), clamped to the frame, taps clamped
/// to the window [wlo, whi).
inline float4 pca_geo_bicubic(pca_in src, constant pca_frame& f, constant pca_geo_lens_params& p, float2 pos, int2 wlo, int2 whi) {
    float x = clamp(pos.x - 0.5f, float(p.frame_lo.x), float(p.frame_hi.x - 1));
    float y = clamp(pos.y - 0.5f, float(p.frame_lo.y), float(p.frame_hi.y - 1));
    float xi = floor(x), yi = floor(y);
    float4 wx = pca_geo_catmull(x - xi), wy = pca_geo_catmull(y - yi);
    float4 acc = float4(0.0f);
    bool premul = p.src_alpha != 0u;
    for (int j = 0; j < 4; j++) {
        int yy = clamp(int(yi) + j - 1, wlo.y, whi.y - 1);
        for (int i = 0; i < 4; i++) {
            int xx = clamp(int(xi) + i - 1, wlo.x, whi.x - 1);
            float4 v = pca_get(src, f, int2(xx, yy));
            if (premul) v = float4(v.xyz * v.w, v.w);
            acc += wx[i] * wy[j] * v;
        }
    }
    return acc;
}

/// Pass 2: one output pixel (photocraft `remap_impl`'s pixel loop).
kernel void pca_geo_lens(constant pca_frame& f [[buffer(0)]], constant pca_geo_lens_params& p [[buffer(1)]],
                         device const int* bbox [[buffer(2)]], pca_in src [[texture(0)]], pca_in t1 [[texture(1)]],
                         pca_in t2 [[texture(2)]], pca_out dst [[texture(3)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    uint2 cq = uint2(q - p.cover_origin);
    float4 a = t1.read(cq), b = t2.read(cq);
    device const int* bb = bbox + pca_geo_lens_tile(p, q) * 4;
    bool any = bb[0] <= bb[2];
    int2 wlo = int2(0), whi = int2(0);
    if (any) {
        wlo = clamp(int2(bb[0], bb[1]) - 3, p.frame_lo, p.frame_hi);
        whi = clamp(int2(bb[2], bb[3]) + 4, p.frame_lo, p.frame_hi);
    }
    if (b.w < 0.5f || !any || whi.x <= wlo.x || whi.y <= wlo.y) {
        dst.write(p.edge_px, gid);
        return;
    }
    float2 pp = a.xy, pr = a.zw, pb = b.xy;
    float gain = b.z;
    // Inside-frame weight (1 px soft edge) unless edges extend.
    float inside = 1.0f;
    if (p.edge_kind != 0u) {
        float fx = clamp(min(pp.x - float(p.frame_lo.x), float(p.frame_hi.x) - pp.x) + 0.5f, 0.0f, 1.0f);
        float fy = clamp(min(pp.y - float(p.frame_lo.y), float(p.frame_hi.y) - pp.y) + 0.5f, 0.0f, 1.0f);
        inside = fx * fy;
    }
    bool src_alpha = p.src_alpha != 0u, out_alpha = p.out_alpha != 0u;
    float4 sp = pca_geo_bicubic(src, f, p, pp, wlo, whi);
    float4 spr = sp, spb = sp;
    if (p.mode == 1) {
        spr = pca_geo_bicubic(src, f, p, pr, wlo, whi);
        spb = pca_geo_bicubic(src, f, p, pb, wlo, whi);
    }
    float alpha = src_alpha ? clamp(sp.w, 0.0f, 1.0f) : 1.0f;
    int nc = min(int(f.ncomp), out_alpha ? 3 : 4);
    float4 col = float4(0.0f);
    for (int k = 0; k < nc; k++) {
        int ch = int(f.first_channel) + k;
        float pm = (p.mode == 1 && ch == 0) ? spr[k] : ((p.mode == 1 && ch == 2) ? spb[k] : sp[k]);
        float straight = src_alpha ? (alpha > 1e-6f ? pm / alpha : 0.0f) : pm;
        float v;
        if (p.mode == 2) v = 1.0f - (1.0f - straight) * gain;
        else if (p.mode == 3) v = ch == 0 ? straight * gain : straight;
        else v = straight * gain;
        if (p.clip != 0u) v = clamp(v, 0.0f, 1.0f);
        col[k] = v;
    }
    float4 o = col;
    if (p.edge_kind == 2u && inside < 1.0f) {
        // Blend towards the edge colour by the outside share.
        float ea = out_alpha ? p.edge_px.w : 1.0f;
        float oa = alpha * inside + ea * (1.0f - inside);
        for (int k = 0; k < nc; k++) {
            float mixed = col[k] * alpha * inside + p.edge_px[k] * ea * (1.0f - inside);
            o[k] = oa > 1e-6f ? mixed / oa : 0.0f;
        }
        if (out_alpha) o.w = oa;
    } else if (out_alpha) {
        o.w = alpha * inside;
    }
    dst.write(o, gid);
}
