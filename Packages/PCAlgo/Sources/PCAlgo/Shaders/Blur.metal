// Port of photocraft-algo (crates/algo/src/blur.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Separable blurs: the exact premultiplied Gaussian convolution (`conv_sep`) as a horizontal and a
// vertical pass, and the running-sum box pass (`box_pass`) in segments of 32 pixels per thread,
// reading its input clamped to a rectangle (the source's repeated edge).

struct pca_conv_params {
    int2 tmp_origin;
    int2 tmp_size;
    int taps;
    int radius;
    int pad0;
    int pad1;
};

/// Horizontal pass of `conv_sep`: premultiplied source (0 outside) × kernel, into the
/// intermediate covering the output columns and the vertical reach.
kernel void pca_conv_h(constant pca_frame& f [[buffer(0)]], constant pca_conv_params& p [[buffer(1)]],
                       constant float* k [[buffer(2)]], pca_in src [[texture(0)]], pca_out tmp [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.tmp_size.x || int(gid.y) >= p.tmp_size.y) return;
    bool alpha = f.alpha != 0u;
    int2 q = p.tmp_origin + int2(gid);
    float4 acc = float4(0.0f);
    for (int i = 0; i < p.taps; i++) {
        float4 s = pca_premul(pca_get(src, f, int2(q.x - p.radius + i, q.y)), alpha);
        acc += s * k[i];
    }
    tmp.write(acc, gid);
}

/// Vertical pass of `conv_sep`, unpremultiplied into the output.
kernel void pca_conv_v(constant pca_frame& f [[buffer(0)]], constant pca_conv_params& p [[buffer(1)]],
                       constant float* k [[buffer(2)]], pca_in tmp [[texture(0)]], pca_out dst [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 acc = float4(0.0f);
    int tx = q.x - p.tmp_origin.x;
    int ty = q.y - p.radius - p.tmp_origin.y;
    for (int i = 0; i < p.taps; i++) {
        acc += tmp.read(uint2(tx, ty + i)) * k[i];
    }
    dst.write(pca_unpremul(acc, f.alpha != 0u), gid);
}

struct pca_box_params {
    int2 in_origin;
    int2 in_size;
    int2 o_origin;
    int2 o_size;
    int2 clamp_lo;
    int2 clamp_hi;
    int radius;
    int axis;      // 0 horizontal, 1 vertical
    int segment;   // pixels per thread
    uint premul_in;
    uint unpremul_out;
    float norm;      // 1/(2r+1) as the nearest float (high part)
    float norm_lo;   // and the remainder (low part), from a double
    int pad1;
};

inline float4 pca_box_read(pca_in t, constant pca_box_params& p, int2 q, bool premul, bool alpha) {
    int2 c = clamp(q, p.clamp_lo, p.clamp_hi) - p.in_origin;
    float4 v = t.read(uint2(c));
    return premul ? pca_premul(v, alpha) : v;
}

/// Box sums are float-float (`pca_ff_add`, renormalised TwoSum): the running sums return exactly to
/// the window's sum after a bright run leaves it (plain float sums keep residue that shows as garbage
/// colour where alpha is ~0 once unpremultiplied), and the mean `sum × norm` is the f64 product
/// photocraft's buffer blurs round (`pca_ff_mul_round`).
inline void pca_box_add(thread float4& s, thread float4& e, float4 v) { pca_ff_add(s, e, v); }

/// One running-sum box pass along rows (axis 0) or columns (axis 1): output element `x` is the
/// mean of input `x - r … x + r`. gid.x is the line, gid.y the segment.
kernel void pca_box_pass(constant pca_frame& f [[buffer(0)]], constant pca_box_params& p [[buffer(1)]],
                         pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    bool alpha = f.alpha != 0u;
    bool premul = p.premul_in != 0u;
    bool unpremul = p.unpremul_out != 0u;
    int line = int(gid.x);
    int along0 = int(gid.y) * p.segment;
    int2 dir = p.axis == 0 ? int2(1, 0) : int2(0, 1);
    int lines = p.axis == 0 ? p.o_size.y : p.o_size.x;
    int len = p.axis == 0 ? p.o_size.x : p.o_size.y;
    if (line >= lines || along0 >= len) return;
    int along1 = min(along0 + p.segment, len);
    // Document coordinates of the first output element of this segment.
    int2 o = p.axis == 0 ? int2(p.o_origin.x + along0, p.o_origin.y + line) : int2(p.o_origin.x + line, p.o_origin.y + along0);
    float4 s = float4(0.0f), e = float4(0.0f);
    for (int i = -p.radius; i <= p.radius; i++) pca_box_add(s, e, pca_box_read(src, p, o + dir * i, premul, alpha));
    for (int a = along0; a < along1; a++) {
        float4 v = pca_ff_mul_round(s, e, p.norm, p.norm_lo);
        uint2 w = p.axis == 0 ? uint2(a, line) : uint2(line, a);
        dst.write(unpremul ? pca_unpremul(v, alpha) : v, w);
        int2 q = o + dir * (a - along0);
        pca_box_add(s, e, pca_box_read(src, p, q + dir * (p.radius + 1), premul, alpha));
        pca_box_add(s, e, -pca_box_read(src, p, q - dir * p.radius, premul, alpha));
    }
}

/// The same box mean as `pca_box_pass` with one thread per output element and the window summed
/// directly (compensated): horizontal passes with small radii, where the running sum's
/// row-per-lane traversal starves the texture cache.
kernel void pca_box_direct(constant pca_frame& f [[buffer(0)]], constant pca_box_params& p [[buffer(1)]],
                           pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.o_size.x || int(gid.y) >= p.o_size.y) return;
    bool alpha = f.alpha != 0u;
    bool premul = p.premul_in != 0u;
    int2 dir = p.axis == 0 ? int2(1, 0) : int2(0, 1);
    int2 o = p.o_origin + int2(gid);
    float4 s = float4(0.0f), e = float4(0.0f);
    for (int i = -p.radius; i <= p.radius; i++) pca_box_add(s, e, pca_box_read(src, p, o + dir * i, premul, alpha));
    float4 v = pca_ff_mul_round(s, e, p.norm, p.norm_lo);
    dst.write(p.unpremul_out != 0u ? pca_unpremul(v, alpha) : v, gid);
}

/// Zero output (an empty source).
kernel void pca_clear(constant pca_frame& f [[buffer(0)]], pca_out dst [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    dst.write(float4(0.0f), gid);
}
