// Port of photocraft-algo (crates/algo/src/stack.rs, trap.rs, vectorscope.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Stack Mode statistics per pixel across layers, Trap's ink dilation, and the vectorscope histogram.

struct pca_misc_stack_params {
    uint count;
    uint layers;
    uint stat;   // StackStat.allCases order: entropy kurtosis maximum mean median minimum range skewness sd summation variance
    uint pad;
};

inline uint pca_misc_key(float v) {
    uint b = as_type<uint>(v);
    return (b & 0x80000000u) != 0u ? ~b : b | 0x80000000u;
}

inline float pca_misc_stat(thread float* v, int n, uint s) {
    if (n == 0) return 0.0f;
    float nf = float(n);
    float sum = 0.0f;
    for (int i = 0; i < n; i++) sum += v[i];
    float mean = sum / nf;
    float m2 = 0.0f, m3 = 0.0f, m4 = 0.0f;
    if (s == 1u || s == 7u || s == 8u || s == 10u) {
        for (int i = 0; i < n; i++) {
            float d = v[i] - mean;
            float d2 = d * d;
            m2 += d2;
            m3 += d * d * d;
            m4 += d2 * d2;
        }
        m2 /= nf; m3 /= nf; m4 /= nf;
    }
    switch (s) {
        case 3u: return mean;
        case 9u: return sum;
        case 5u: { float m = FLT_MAX; for (int i = 0; i < n; i++) m = fmin(m, v[i]); return m; }
        case 2u: { float m = -FLT_MAX; for (int i = 0; i < n; i++) m = fmax(m, v[i]); return m; }
        case 6u: {
            float hi = -FLT_MAX, lo = FLT_MAX;
            for (int i = 0; i < n; i++) { hi = fmax(hi, v[i]); lo = fmin(lo, v[i]); }
            return hi - lo;
        }
        case 4u: {
            // Insertion sort by total order.
            for (int i = 1; i < n; i++) {
                float x = v[i];
                uint kx = pca_misc_key(x);
                int j = i - 1;
                while (j >= 0 && pca_misc_key(v[j]) > kx) { v[j + 1] = v[j]; j--; }
                v[j + 1] = x;
            }
            return (n % 2 == 1) ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2.0f;
        }
        case 10u: return m2;
        case 8u: return sqrt(m2);
        case 7u: { float sd = sqrt(m2); return sd < 1e-6f ? 0.5f : clamp(m3 / (sd * sd * sd) / 4.0f + 0.5f, 0.0f, 1.0f); }
        case 1u: return m2 < 1e-12f ? 0.0f : clamp(m4 / (m2 * m2) / 10.0f, 0.0f, 1.0f);
        default: {
            if (n < 2) return 0.0f;
            // Counts per 8-bit level, summed in level order (as the Swift reference).
            for (int i = 0; i < n; i++) v[i] = round(clamp(v[i], 0.0f, 1.0f) * 255.0f);
            for (int i = 1; i < n; i++) {
                float x = v[i]; int j = i - 1;
                while (j >= 0 && v[j] > x) { v[j + 1] = v[j]; j--; }
                v[j + 1] = x;
            }
            float h = 0.0f;
            int i = 0;
            while (i < n) {
                int j = i;
                while (j < n && v[j] == v[i]) j++;
                float p = float(j - i) / nf;
                h += -p * log2(p);
                i = j;
            }
            return h / log2(nf);
        }
    }
}

kernel void pca_misc_stack(constant pca_frame& f [[buffer(0)]], constant pca_misc_stack_params& p [[buffer(1)]],
                           const device float4* layers [[buffer(2)]], device float4* out [[buffer(3)]],
                           uint gid [[thread_position_in_grid]]) {
    if (gid >= p.count) return;
    float r[64], g[64], b[64];
    int n = 0;
    float alpha = 0.0f;
    for (uint k = 0; k < p.layers; k++) {
        float4 v = layers[k * p.count + gid];
        if (v.w > 0.0f) {
            r[n] = v.x; g[n] = v.y; b[n] = v.z; n++;
            alpha = fmax(alpha, v.w);
        }
    }
    if (alpha <= 0.0f) { out[gid] = float4(0.0f); return; }
    out[gid] = float4(pca_misc_stat(r, n, p.stat), pca_misc_stat(g, n, p.stat), pca_misc_stat(b, n, p.stat), alpha);
}

struct pca_misc_trap_params {
    int width;
    int height;
    int radius;
    int channels;
};

/// Row pass of Trap's dilation: per ink, the clipped-window maximum from 0 (x = column).
kernel void pca_misc_trap_h(constant pca_frame& f [[buffer(0)]], constant pca_misc_trap_params& p [[buffer(1)]],
                            const device float* px [[buffer(2)]], device float4* tmp [[buffer(3)]], uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.width || y >= p.height) return;
    float4 m = float4(0.0f);
    for (int xx = max(x - p.radius, 0); xx <= min(x + p.radius, p.width - 1); xx++) {
        int b = (y * p.width + xx) * p.channels;
        m = fmax(m, float4(px[b], px[b + 1], px[b + 2], px[b + 3]));
    }
    tmp[y * p.width + x] = m;
}

kernel void pca_misc_trap_v(constant pca_frame& f [[buffer(0)]], constant pca_misc_trap_params& p [[buffer(1)]],
                            const device float4* tmp [[buffer(2)]], device float4* dil [[buffer(3)]], uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.width || y >= p.height) return;
    float4 m = float4(0.0f);
    for (int yy = max(y - p.radius, 0); yy <= min(y + p.radius, p.height - 1); yy++) m = fmax(m, tmp[yy * p.width + x]);
    dil[y * p.width + x] = m;
}

kernel void pca_misc_trap_apply(constant pca_frame& f [[buffer(0)]], constant pca_misc_trap_params& p [[buffer(1)]],
                                device float* px [[buffer(2)]], const device float4* dil [[buffer(3)]], uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.width || y >= p.height) return;
    int b = (y * p.width + x) * p.channels;
    bool inked = px[b] > 1e-4f || px[b + 1] > 1e-4f || px[b + 2] > 1e-4f || px[b + 3] > 1e-4f;
    if (!inked) return;
    float4 d = dil[y * p.width + x];
    for (int c = 0; c < 4; c++) px[b + c] = fmax(px[b + c], d[c]);
}

/// Vectorscope bins (128 hues × 64 saturations) and the sample count (last slot), atomically.
kernel void pca_misc_vectorscope(constant pca_frame& f [[buffer(0)]], constant uint4& p [[buffer(1)]],
                                 const device float4* px [[buffer(2)]], device atomic_uint* bins [[buffer(3)]],
                                 uint gid [[thread_position_in_grid]]) {
    if (gid >= p.x) return;
    float4 v = px[gid];
    if (v.w <= 0.0f || !(isfinite(v.x) && isfinite(v.y) && isfinite(v.z) && isfinite(v.w))) return;
    float r = clamp(v.x, 0.0f, 1.0f), g = clamp(v.y, 0.0f, 1.0f), b = clamp(v.z, 0.0f, 1.0f);
    float high = fmax(fmax(r, g), b), low = fmin(fmin(r, g), b);
    float delta = high - low;
    float hue = 0.0f, sat = 0.0f;
    if (!(delta <= FLT_EPSILON || high <= 0.0f)) {
        float h = high == r ? (g - b) / delta : (high == g ? 2.0f + (b - r) / delta : 4.0f + (r - g) / delta);
        hue = pca_rem_euclid_f(h / 6.0f, 1.0f);
        sat = delta / high;
    }
    uint hb = min(uint(hue * 128.0f), 127u);
    uint sb = min(uint(round(sat * 63.0f)), 63u);
    atomic_fetch_add_explicit(&bins[hb * 64u + sb], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&bins[128u * 64u], 1u, memory_order_relaxed);
}

struct pca_misc_gradient_params {
    float2 from;
    float2 to;
    uint shape;     // linear radial angle reflected diamond
    int stops;
    uint reverse;
    uint dither;
    uint mode;      // BlendMode raw value
    uint lock;
    uint gray;
    uint pad;
};

inline float pca_misc_gradient_t(constant pca_misc_gradient_params& p, float x, float y) {
    float dx = p.to.x - p.from.x, dy = p.to.y - p.from.y;
    float len = max(sqrt(dx * dx + dy * dy), 1e-6f);
    float ux = dx / len, uy = dy / len;
    float px = x - p.from.x, py = y - p.from.y;
    float along = px * ux + py * uy;
    float across = -px * uy + py * ux;
    float t;
    switch (p.shape) {
        case 0u: t = along / len; break;
        case 1u: t = sqrt(px * px + py * py) / len; break;
        case 3u: t = fabs(along) / len; break;
        case 4u: t = (fabs(along) + fabs(across)) / len; break;
        default: t = pca_rem_euclid_f(atan2(across, along) / 6.28318530717958647692f, 1.0f); break;
    }
    return clamp(t, 0.0f, 1.0f);
}

kernel void pca_misc_gradient(constant pca_frame& f [[buffer(0)]], constant pca_misc_gradient_params& p [[buffer(1)]],
                              constant float4* pos [[buffer(2)]], constant float4* col [[buffer(3)]], const device float* cov [[buffer(4)]],
                              pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float4 v = pca_get(src, f, q);
    float k = cov[gid.y * uint(f.out_size.x) + gid.x];
    if (k <= 0.0f) { dst.write(v, gid); return; }
    float tt = pca_misc_gradient_t(p, float(q.x) + 0.5f, float(q.y) + 0.5f);
    float t = p.reverse != 0u ? 1.0f - tt : tt;
    float4 c;
    if (p.stops == 0) c = float4(0.0f);
    else if (p.stops == 1 || t <= pos[0].x) c = col[0];
    else {
        c = col[p.stops - 1];
        for (int i = 1; i < p.stops; i++) {
            if (t <= pos[i].x) {
                float k2 = pos[i].x > pos[i - 1].x ? (t - pos[i - 1].x) / (pos[i].x - pos[i - 1].x) : 0.0f;
                c = col[i - 1] + (col[i] - col[i - 1]) * k2;
                break;
            }
        }
    }
    if (p.dither != 0u) {
        float nz = (pc_dither_noise(q.x, q.y) - 0.5f) / 255.0f;
        c.xyz = clamp(c.xyz + nz, 0.0f, 1.0f);
    }
    // Backdrop as straight sRGB RGBA (Gray: g, g, g).
    float a = f.alpha != 0u ? v.w : 1.0f;
    float4 d = p.gray != 0u ? float4(v.x, v.x, v.x, a) : float4(v.xyz, a);
    float4 o = pc_composite(p.mode, d, c, k);
    if (p.lock != 0u) o.w = d.w;
    float4 r = p.gray != 0u ? float4(0.299f * o.x + 0.587f * o.y + 0.114f * o.z, 0.0f, 0.0f, o.w) : o;
    if (f.alpha == 0u) r.w = 0.0f;
    dst.write(r, gid);
}
