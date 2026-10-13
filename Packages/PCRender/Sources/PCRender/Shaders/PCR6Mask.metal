// Port of photocraft-compose (crates/compose/src/masks.rs `build_mask`, `gaussian`, `blur_line`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Feathered masks on the GPU: a leaf's channel 0 gathered over the mask area (density applied),
// three clamped box passes per axis (a Gaussian of sigma = feather), the pixel mask times the
// vector coverage, rounded to the 16-bit mask format.

/// Channel 0 of the leaf (6) over the area (`op.origin`), outside value leafOutside.x;
/// p0.x = density (applied when < 1).
kernel void pcr_mask_gather(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], texture2d<float, access::read> leaf [[texture(6)]],
                            texture2d<float, access::write> out [[texture(7)]]) {
    if (int(gid.x) >= op.size.x || int(gid.y) >= op.size.y) return;
    int2 d = int2(gid) + op.origin;
    float v = pcr_leaf(op, leaf, d).r;
    float density = op.p[0].x;
    if (density < 1.0f) v = 1.0f - density * (1.0f - v);
    out.write(float4(v, 0.0f, 0.0f, 1.0f), gid);
}

inline float pcr_mask_at(texture2d<float, access::read> a, bool vertical, int line, int i, int n) {
    int c = clamp(i, 0, n - 1);
    return vertical ? a.read(uint2(line, c)).r : a.read(uint2(c, line)).r;
}

/// One clamped box pass of radius r = aux.x along an axis (p0.x = vertical), p1.x outputs per
/// thread; `op.size` = (line length, lines).
kernel void pcr_mask_box(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], texture2d<float, access::read> a [[texture(0)]],
                         texture2d<float, access::write> out [[texture(7)]]) {
    int seg = int(op.p[1].x);
    int k0 = int(gid.x) * seg;
    int line = int(gid.y);
    int n = op.size.x;
    if (k0 >= n || line >= op.size.y) return;
    bool vertical = op.p[0].x > 0.5f;
    int r = op.aux.x;
    float cnt = float(2 * r + 1);
    float acc = 0.0f;
    for (int i = k0 - r; i <= k0 + r; i++) acc += pcr_mask_at(a, vertical, line, i, n);
    int k1 = min(k0 + seg, n);
    for (int i = k0; i < k1; i++) {
        float v = acc / cnt;
        if (vertical) out.write(float4(v, 0.0f, 0.0f, 1.0f), uint2(line, i)); else out.write(float4(v, 0.0f, 0.0f, 1.0f), uint2(i, line));
        acc += pcr_mask_at(a, vertical, line, i + r + 1, n) - pcr_mask_at(a, vertical, line, i - r, n);
    }
}

/// A (× B when aux.x = 1), rounded to 16 bits.
kernel void pcr_mask_combine(constant PCROp& op [[buffer(0)]], uint2 gid [[thread_position_in_grid]], texture2d<float, access::read> a [[texture(0)]],
                             texture2d<float, access::read> b [[texture(1)]], texture2d<float, access::write> out [[texture(7)]]) {
    if (int(gid.x) >= op.size.x || int(gid.y) >= op.size.y) return;
    float v = a.read(gid).r;
    if (op.aux.x == 1) v *= b.read(gid).r;
    v = float(uint(clamp(v, 0.0f, 1.0f) * 65535.0f + 0.5f)) / 65535.0f;
    out.write(float4(v, 0.0f, 0.0f, 1.0f), gid);
}

/// One pass of the exact Gaussian vector-mask feathers use: weights (2·aux.x + 1) in buffer 1,
/// clamped edges, along an axis (p0.x = vertical); `op.size` = (line length, lines). The sum runs
/// in the CPU reference's order.
kernel void pcr_mask_gauss(constant PCROp& op [[buffer(0)]], constant float* weights [[buffer(1)]], uint2 gid [[thread_position_in_grid]],
                           texture2d<float, access::read> a [[texture(0)]], texture2d<float, access::write> out [[texture(7)]]) {
    int i = int(gid.x), line = int(gid.y);
    int n = op.size.x;
    if (i >= n || line >= op.size.y) return;
    bool vertical = op.p[0].x > 0.5f;
    int r = op.aux.x;
    float acc = 0.0f;
    for (int j = -r; j <= r; j++) acc += weights[j + r] * pcr_mask_at(a, vertical, line, i + j, n);
    if (vertical) out.write(float4(acc, 0.0f, 0.0f, 1.0f), uint2(line, i)); else out.write(float4(acc, 0.0f, 0.0f, 1.0f), uint2(i, line));
}
