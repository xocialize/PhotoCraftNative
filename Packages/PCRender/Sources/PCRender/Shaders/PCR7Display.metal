// Port of photocraft-gpu (crates/gpu/src/lib.rs display sink) and photocraft's engine display transform (docs/architecture.md §7.3), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Level selection (halvings rounded up, drawn from the copy at least as large as the screen) adapted from Compositor v1.5 (Compositor/Rendering/DownsampleCache.swift, GPUCanvas.swift), MIT, © 2026 Wonder Assembly LLC.
//
// The canvas display pass: the composite placed by the view transform (zoom, pan), nearest
// sampling from 100 % up, bilinear on premultiplied colour below it, drawn from a 2× area-averaged
// reduction chain when zoomed out past 50 %, over a checkerboard, then the 33³ display LUT
// (document profile → monitor, from PCPlatform's ColorSync code) as the final step.

struct PCRDisplay {
    float2 translate;   // view pixel of document (0, 0)
    float zoom;         // view pixels per document pixel
    float levelScale;   // document pixels per texel of the bound level (2^level)
    int4 canvas;        // document rect of the composite texture (x0, y0, x1, y1)
    int2 levelSize;     // texels of the bound level
    float checker;      // checkerboard square (view pixels)
    uint flags;         // 1 nearest, 2 level is premultiplied, 4 apply LUT
    float4 pasteboard;  // colour outside the canvas
    float4 checkerA;
    float4 checkerB;
    float lutSize;      // LUT grid size (33)
    float3 pad;
};

struct PCRVOut { float4 position [[position]]; };

vertex PCRVOut pcr_display_vertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    PCRVOut o;
    o.position = float4(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f, 0.0f, 1.0f);
    return o;
}

inline float4 pcr_disp_texel(texture2d<float, access::read> tex, int2 p, int2 size, bool premul) {
    if (!pcr_inside(p, size)) return float4(0.0f);
    float4 c = tex.read(uint2(p));
    return premul ? c : float4(c.rgb * c.a, c.a);
}

/// The displayed colour of view pixel `pos` (premultiplied composite over the checkerboard,
/// pasteboard outside the canvas); `PCRDisplayMath.shade` is the CPU mirror.
inline float4 pcr_display_shade(constant PCRDisplay& u, texture2d<float, access::read> tex, float2 pos) {
    float2 doc = (pos - u.translate) / u.zoom;
    float4 cv = float4(u.canvas);
    if (doc.x < cv.x || doc.y < cv.y || doc.x >= cv.z || doc.y >= cv.w) return u.pasteboard;
    bool premul = (u.flags & 2u) != 0u;
    float4 c;
    float2 tp = (doc - cv.xy) / u.levelScale;
    if ((u.flags & 1u) != 0u) {
        c = pcr_disp_texel(tex, int2(floor(tp)), u.levelSize, premul);
    } else {
        float2 f = tp - 0.5f;
        float2 i0 = floor(f);
        float2 w = f - i0;
        int2 p = int2(i0);
        // Clamp to the edge texels: the composite stops at the canvas edge.
        int2 a = clamp(p, int2(0), u.levelSize - 1), b = clamp(p + 1, int2(0), u.levelSize - 1);
        float4 c00 = pcr_disp_texel(tex, int2(a.x, a.y), u.levelSize, premul), c10 = pcr_disp_texel(tex, int2(b.x, a.y), u.levelSize, premul);
        float4 c01 = pcr_disp_texel(tex, int2(a.x, b.y), u.levelSize, premul), c11 = pcr_disp_texel(tex, int2(b.x, b.y), u.levelSize, premul);
        c = mix(mix(c00, c10, w.x), mix(c01, c11, w.x), w.y);
    }
    int2 cell = int2(floor(pos / u.checker));
    float4 ck = ((cell.x + cell.y) & 1) == 0 ? u.checkerA : u.checkerB;
    float a = clamp(c.a, 0.0f, 1.0f);
    return float4(c.rgb + ck.rgb * (1.0f - a), 1.0f);
}

fragment float4 pcr_display_fragment(PCRVOut in [[stage_in]], constant PCRDisplay& u [[buffer(0)]],
                                     texture2d<float, access::read> tex [[texture(0)]], texture3d<float> lut [[texture(1)]],
                                     sampler s [[sampler(0)]]) {
    float4 c = pcr_display_shade(u, tex, in.position.xy);
    if ((u.flags & 4u) != 0u) {
        float n = u.lutSize;
        float3 uvw = clamp(c.rgb, 0.0f, 1.0f) * ((n - 1.0f) / n) + 0.5f / n;
        c.rgb = lut.sample(s, uvw).rgb;
    }
    return c;
}

/// The display pass as a compute kernel into a texture (headless tests, offscreen snapshots).
kernel void pcr_display_kernel(constant PCRDisplay& u [[buffer(0)]], texture2d<float, access::read> tex [[texture(0)]], texture3d<float> lut [[texture(1)]],
                               sampler s [[sampler(0)]], texture2d<float, access::write> out [[texture(2)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float4 c = pcr_display_shade(u, tex, float2(gid) + 0.5f);
    if ((u.flags & 4u) != 0u) {
        float n = u.lutSize;
        float3 uvw = clamp(c.rgb, 0.0f, 1.0f) * ((n - 1.0f) / n) + 0.5f / n;
        c.rgb = lut.sample(s, uvw).rgb;
    }
    out.write(c, gid);
}

/// One 2× area reduction (premultiplied; odd edges average what is there). aux.x = 1: the source
/// is straight alpha.
kernel void pcr_display_halve(constant PCROp& op [[buffer(0)]], texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(7)]], uint2 gid [[thread_position_in_grid]]) {
    // `op.offset`: the first output texel (a partial update of the chain).
    int2 g = int2(gid) + op.offset;
    if (g.x >= int(dst.get_width()) || g.y >= int(dst.get_height())) return;
    int2 sz = int2(src.get_width(), src.get_height());
    float4 acc = float4(0.0f);
    float n = 0.0f;
    for (int dy = 0; dy < 2; dy++) {
        for (int dx = 0; dx < 2; dx++) {
            int2 p = g * 2 + int2(dx, dy);
            if (p.x < sz.x && p.y < sz.y) {
                float4 c = src.read(uint2(p));
                acc += op.aux.x == 1 ? float4(c.rgb * c.a, c.a) : c;
                n += 1.0f;
            }
        }
    }
    dst.write(acc / max(n, 1.0f), uint2(g));
}
