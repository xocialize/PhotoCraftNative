// Port of photocraft-algo (crates/algo/src/selection/distance.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Exact binary Euclidean distance transform: nearest seeds along each column (one thread per
// column), then the lower envelope of the parabolas along each row (one thread per row, its
// sites in a scratch row). Envelope boundaries are compared as exact rationals in 64-bit
// integers, and the distance is the correctly rounded Float square root of the exact integer
// squared distance — the CPU's `Float(sqrt(Double(n)))` (no double-rounding below 2^34).

/// Nearest seed above and below along column x: vert[x * h + y] (column-major), NO_SEED where
/// the column has none.
kernel void pca_sel_edt_cols(constant pca_sel_grid& g [[buffer(0)]], device const uchar* ins [[buffer(1)]], device uint* vert [[buffer(2)]],
                             uint x [[thread_position_in_grid]]) {
    if (x >= g.w) return;
    uint w = g.w, h = g.h;
    device uint* col = vert + x * h;
    int nearest = -1;
    for (uint y = 0; y < h; y++) {
        if (ins[y * w + x] != 0) nearest = int(y);
        col[y] = nearest >= 0 ? uint(int(y) - nearest) : PCA_SEL_NO_SEED;
    }
    nearest = -1;
    for (int y = int(h) - 1; y >= 0; y--) {
        if (col[y] == 0u) nearest = y;
        if (nearest >= 0) col[y] = min(col[y], uint(nearest - y));
    }
}

/// The envelope boundary between sites p < q of a row as N / D (D > 0): where their parabolas
/// cross, ((dq² − dp²) + (q² − p²)) / (2(q − p)).
struct pca_sel_ratio {
    long num;
    long den;
};

inline pca_sel_ratio pca_sel_boundary(device const uint* vert, uint h, uint y, uint p, uint q) {
    long dp = long(vert[p * h + y]), dq = long(vert[q * h + y]);
    long lp = long(p), lq = long(q);
    pca_sel_ratio r;
    r.num = (dq * dq - dp * dp) + (lq * lq - lp * lp);
    r.den = 2 * (lq - lp);
    return r;
}

/// −1, 0 or 1 as a·b (Floats ≥ 4096, exact) is below, at or above the integer n.
inline int pca_sel_prod_cmp(float a, float b, ulong n) {
    uint ba = as_type<uint>(a), bb = as_type<uint>(b);
    ulong ma = ulong((ba & 0x7fffffu) | 0x800000u), mb = ulong((bb & 0x7fffffu) | 0x800000u);
    int e = (int((ba >> 23) & 0xffu) - 150) + (int((bb >> 23) & 0xffu) - 150);
    ulong prod = ma * mb;
    ulong rhs = n;
    if (e >= 0) prod <<= uint(e); else rhs <<= uint(-e);
    return prod < rhs ? -1 : (prod > rhs ? 1 : 0);
}

/// The correctly rounded Float square root of an integer (Tuckerman's test with exact products).
inline float pca_sel_sqrt_u64(ulong n) {
    if (n == 0ul) return 0.0f;
    if (n < (1ul << 24)) return pca_dis_sqrt(float(n));
    float s = sqrt(float(n));
    for (int k = 0; k < 4; k++) {
        float sp = nextafter(s, INFINITY), sm = nextafter(s, 0.0f);
        if (pca_sel_prod_cmp(s, sp, n) < 0) { s = sp; continue; }    // s·s⁺ < n: round up
        if (pca_sel_prod_cmp(sm, s, n) >= 0) { s = sm; continue; }   // s⁻·s ≥ n: round down
        break;
    }
    return s;
}

/// Row y: lower envelope of the parabolas (x − q)² + vert(q)² over the columns with a seed,
/// then each pixel's distance to its envelope site.
kernel void pca_sel_edt_rows(constant pca_sel_grid& g [[buffer(0)]], device const uint* vert [[buffer(1)]], device uint* sites [[buffer(2)]],
                             device float* out [[buffer(3)]], uint y [[thread_position_in_grid]]) {
    if (y >= g.h) return;
    uint w = g.w, h = g.h;
    device uint* st = sites + y * w;
    int count = 0;
    for (uint q = 0; q < w; q++) {
        if (vert[q * h + y] == PCA_SEL_NO_SEED) continue;
        // Pop sites whose interval the new parabola covers (the first site starts at −∞).
        while (count > 1) {
            pca_sel_ratio a = pca_sel_boundary(vert, h, y, st[count - 1], q);
            pca_sel_ratio b = pca_sel_boundary(vert, h, y, st[count - 2], st[count - 1]);
            if (a.num * b.den > b.num * a.den) break;
            count--;
        }
        st[count] = q;
        count++;
    }
    device float* o = out + y * w;
    if (count == 0) {
        for (uint x = 0; x < w; x++) o[x] = 1e10f;
        return;
    }
    int k = 0;
    for (uint x = 0; x < w; x++) {
        while (k + 1 < count) {
            pca_sel_ratio b = pca_sel_boundary(vert, h, y, st[k], st[k + 1]);
            if (!(b.num < long(x) * b.den)) break;
            k++;
        }
        uint site = st[k];
        ulong v = ulong(vert[site * h + y]);
        long dx = long(x) - long(site);
        o[x] = pca_sel_sqrt_u64(ulong(dx * dx) + v * v);
    }
}
