// Port of photocraft-algo (crates/algo/src/oil.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Oil Paint on one plane: premultiplied window → cleaning blur (GPUPass.encodeGaussBlurN) →
// structure tensor of the channel mean → tensor blur → stroke tangents → line integral
// convolution of colour and bristle noise → relief lighting. All textures except the LIC
// outputs cover the source window; coordinates inside are window-relative like photocraft's.

struct pca_sty_oil_params {
    int2 win;        // window size
    int2 r1_off;     // LIC rect origin, window-relative
    int2 r1_size;
    int2 win_origin; // document origin of the window
    float4 light;
    float4 half_v;
    float h;
    int steps;
    float flat_spec;
    float amp;
    float shine;
    int lighting;
    int sub;
    int lab;
    int cc;
    int pad0;
    int pad1;
    int pad2;
};

/// Mean of the colour components (photocraft: `px[..cc].iter().sum() / cc`).
inline float pca_sty_oil_mean(float4 v, int cc) {
    float s = 0.0f;
    for (int c = 0; c < cc; c++) s += v[c];
    return s / float(cc);
}

kernel void pca_sty_oil_premul(constant pca_frame& f [[buffer(0)]], constant pca_sty_oil_params& p [[buffer(1)]],
                               pca_in src [[texture(0)]], pca_out pre [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.win.x || int(gid.y) >= p.win.y) return;
    pre.write(pca_sty_premul(src.read(gid), f.alpha != 0u), gid);
}

kernel void pca_sty_oil_tensor(constant pca_frame& f [[buffer(0)]], constant pca_sty_oil_params& p [[buffer(1)]],
                               pca_in pre [[texture(0)]], pca_out efg [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.win.x || y >= p.win.y) return;
    if (x < 1 || y < 1 || x >= p.win.x - 1 || y >= p.win.y - 1) { efg.write(float4(0.0f), gid); return; }
    float l[3][3];
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++) l[dy + 1][dx + 1] = pca_sty_oil_mean(pre.read(uint2(x + dx, y + dy)), p.cc);
    float gx = (l[0][2] + 2.0f * l[1][2] + l[2][2]) - (l[0][0] + 2.0f * l[1][0] + l[2][0]);
    float gy = (l[2][0] + 2.0f * l[2][1] + l[2][2]) - (l[0][0] + 2.0f * l[0][1] + l[0][2]);
    efg.write(float4(gx * gx, gx * gy, gy * gy, 0.0f), gid);
}

kernel void pca_sty_oil_tangent(constant pca_frame& f [[buffer(0)]], constant pca_sty_oil_params& p [[buffer(1)]],
                                pca_in efg [[texture(0)]], pca_out tan [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.win.x || int(gid.y) >= p.win.y) return;
    float4 t = efg.read(gid);
    float e = t.x, fv = t.y, g = t.z;
    float d = (e - g) * (e - g);
    float q = 4.0f * fv;
    q = q * fv;
    d = d + q;
    float l1 = e + g;
    l1 = 0.5f * (l1 + pca_sty_sqrt(d));
    float tx = l1 - e, ty = -fv;
    float m = tx * tx;
    m = pca_sty_sqrt(m + ty * ty);
    float iso = e + g;
    iso = l1 - (iso - l1);
    float2 r = (m < 1e-6f || iso < 1e-6f) ? float2(0.70710677f, 0.70710677f) : float2(tx / m, ty / m);
    tan.write(float4(r, 0.0f, 0.0f), gid);
}

/// photocraft oil `sample`: bilinear at window coordinates, clamped, times `k`.
inline float4 pca_sty_oil_sample(pca_in pre, constant pca_sty_oil_params& p, float x, float y, float k) {
    x = clamp(x, 0.0f, float(p.win.x - 1));
    y = clamp(y, 0.0f, float(p.win.y - 1));
    int x0 = int(floor(x)), y0 = int(floor(y));
    int x1 = min(x0 + 1, p.win.x - 1), y1 = min(y0 + 1, p.win.y - 1);
    float ax = x - float(x0), ay = y - float(y0);
    float w00 = (1.0f - ax) * (1.0f - ay) * k, w10 = ax * (1.0f - ay) * k;
    float w01 = (1.0f - ax) * ay * k, w11 = ax * ay * k;
    float4 a = pre.read(uint2(x0, y0)) * w00;
    a = a + pre.read(uint2(x1, y0)) * w10;
    a = a + pre.read(uint2(x0, y1)) * w01;
    a = a + pre.read(uint2(x1, y1)) * w11;
    return a;
}

kernel void pca_sty_oil_lic(constant pca_frame& f [[buffer(0)]], constant pca_sty_oil_params& p [[buffer(1)]],
                            pca_in pre [[texture(0)]], pca_in tan [[texture(1)]], pca_out col [[texture(2)]], pca_out br [[texture(3)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.r1_size.x || int(gid.y) >= p.r1_size.y) return;
    float dx = float(p.r1_off.x + int(gid.x)), dy = float(p.r1_off.y + int(gid.y));
    float4 acc = float4(0.0f);
    acc = acc + pca_sty_oil_sample(pre, p, dx, dy, 1.0f);
    float wsum = 1.0f;
    float nsum = pca_hash01(p.win_origin.x + int(dx), p.win_origin.y + int(dy), 71u, 0u);
    for (int di = 0; di < 2; di++) {
        float dir = di == 0 ? 1.0f : -1.0f;
        float qx = dx, qy = dy;
        float px = 0.0f, py = 0.0f;
        for (int k = 1; k <= p.steps; k++) {
            int ty = int(clamp(round(qy), 0.0f, float(p.win.y - 1)));
            int tx = int(clamp(round(qx), 0.0f, float(p.win.x - 1)));
            float2 t = tan.read(uint2(tx, ty)).xy;
            if (k == 1) {
                t = t * dir;
            } else {
                float dp = t.x * px;
                dp = dp + t.y * py;
                if (dp < 0.0f) t = -t;
            }
            px = t.x;
            py = t.y;
            qx = qx + t.x * p.h;
            qy = qy + t.y * p.h;
            float wk = 1.0f - float(k) / float(p.steps + 1);
            acc = acc + pca_sty_oil_sample(pre, p, qx, qy, wk);
            wsum = wsum + wk;
            float hn = pca_hash01(p.win_origin.x + pca_sty_i32(round(qx)), p.win_origin.y + pca_sty_i32(round(qy)), 71u, 0u);
            nsum = nsum + wk * hn;
        }
    }
    col.write(acc / wsum, gid);
    br.write(float4(nsum / wsum - 0.5f, 0.0f, 0.0f, 0.0f), gid);
}

/// Relief height at LIC-rect texel (rx, ry): brightness ×2 plus the bristle streaks.
inline float pca_sty_oil_height(pca_in col, pca_in br, constant pca_sty_oil_params& p, int rx, int ry) {
    float l = pca_sty_oil_mean(col.read(uint2(rx, ry)), p.cc);
    if (p.sub != 0) l = 1.0f - l;
    float b = br.read(uint2(rx, ry)).x * p.amp;
    return l * 2.0f + b * 6.0f;
}

kernel void pca_sty_oil_out(constant pca_frame& f [[buffer(0)]], constant pca_sty_oil_params& p [[buffer(1)]],
                            pca_in src [[texture(0)]], pca_in col [[texture(1)]], pca_in br [[texture(2)]], pca_out dst [[texture(3)]],
                            uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    int rx = q.x - p.win_origin.x - p.r1_off.x, ry = q.y - p.win_origin.y - p.r1_off.y;
    float4 px = col.read(uint2(rx, ry));
    if (f.alpha != 0u) {
        px = pca_sty_unpremul(px, true);
        // Painting restyles colour, not coverage: keep the layer's own alpha.
        px.w = pca_get(src, f, q).w;
    }
    if (p.lighting != 0) {
        int rw = p.r1_size.x, rh = p.r1_size.y;
        float hx = pca_sty_oil_height(col, br, p, min(rx + 1, rw - 1), ry) - pca_sty_oil_height(col, br, p, max(rx - 1, 0), ry);
        float hy = pca_sty_oil_height(col, br, p, rx, min(ry + 1, rh - 1)) - pca_sty_oil_height(col, br, p, rx, max(ry - 1, 0));
        float n0 = -hx * 0.5f, n1 = -hy * 0.5f;
        float mm = n0 * n0;
        mm = mm + n1 * n1;
        float m = pca_sty_sqrt(mm + 1.0f);
        float dl = n0 * p.light.x;
        dl = dl + n1 * p.light.y;
        dl = dl + 1.0f * p.light.z;
        float ndl = dl / m;
        float dh = n0 * p.half_v.x;
        dh = dh + n1 * p.half_v.y;
        dh = dh + 1.0f * p.half_v.z;
        float ndh = max(dh / m, 0.0f);
        float shade = 1.0f + (ndl - p.light.z) * 1.2f;
        float spec_v = p.shine * max(pow(ndh, 40.0f) - p.flat_spec, 0.0f);
        spec_v = spec_v * 0.8f;
        int chans = p.lab != 0 ? 1 : p.cc;
        for (int c = 0; c < chans; c++) {
            float v = px[c];
            if (p.sub != 0) {
                float t = (1.0f - v) * shade;
                px[c] = 1.0f - (t + spec_v);
            } else {
                float t = v * shade;
                px[c] = t + spec_v;
            }
        }
    }
    dst.write(px, gid);
}

// ---------------------------------------------------------------- f64-faithful buffer blur

struct pca_sty_ff_params {
    int2 size;      // texture extent used (the buffer, edges clamped to it)
    int radius;
    int axis;       // 0 rows, 1 columns
    int segment;    // elements per thread
    float norm_hi;  // 1 / (2r + 1) as a float-float (the CPU's f64 norm)
    float norm_lo;
    int pad0;
};

/// (hi, lo) += v with float-float arithmetic (Knuth two-sum then renormalisation).
inline void pca_sty_ff_add(thread float4& hi, thread float4& lo, float4 v) {
    float4 s = hi + v;
    float4 bb = s - hi;
    float4 e = (hi - (s - bb)) + (v - bb);
    e = e + lo;
    hi = s + e;
    lo = e - (hi - s);
}

/// One running-sum box pass of FxUtil.boxRowsN / boxColsN (edges clamped to the buffer) whose
/// sums are carried in float-float, so the result matches the CPU's f64 sums rounded to float.
kernel void pca_sty_box_ff(constant pca_frame& f [[buffer(0)]], constant pca_sty_ff_params& p [[buffer(1)]],
                           pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int lines = p.axis == 0 ? p.size.y : p.size.x;
    int len = p.axis == 0 ? p.size.x : p.size.y;
    int line = int(gid.x);
    int a0 = int(gid.y) * p.segment;
    if (line >= lines || a0 >= len) return;
    int a1 = min(a0 + p.segment, len);
    float4 hi = float4(0.0f), lo = float4(0.0f);
    for (int i = a0 - p.radius; i <= a0 + p.radius; i++) {
        int c = clamp(i, 0, len - 1);
        pca_sty_ff_add(hi, lo, src.read(p.axis == 0 ? uint2(c, line) : uint2(line, c)));
    }
    float4 nh = float4(p.norm_hi), nl = float4(p.norm_lo);
    for (int a = a0; a < a1; a++) {
        float4 ph = hi * nh;
        float4 pl = fma(hi, nh, -ph);
        float4 t = hi * nl;
        t = t + lo * nh;
        pl = pl + t;
        dst.write(ph + pl, p.axis == 0 ? uint2(a, line) : uint2(line, a));
        int add = clamp(a + p.radius + 1, 0, len - 1), sub = clamp(a - p.radius, 0, len - 1);
        pca_sty_ff_add(hi, lo, src.read(p.axis == 0 ? uint2(add, line) : uint2(line, add)));
        pca_sty_ff_add(hi, lo, -src.read(p.axis == 0 ? uint2(sub, line) : uint2(line, sub)));
    }
}
