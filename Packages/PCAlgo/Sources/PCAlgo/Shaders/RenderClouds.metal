// Port of photocraft-engine (crates/engine/src/extra_cmds.rs: hash, clouds_value, clouds), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Clouds / Difference Clouds (`.joint`; helpers `pca_ren_rgba` / `pca_ren_native` from Render.metal).

/// photocraft-engine's own coordinate hash → [0, 1] (not `pca_hash01`).
inline float pca_ren_clouds_hash(int x, int y, uint seed) {
    uint h = (uint(x) * 0x8da6b343u) ^ (uint(y) * 0xd8163841u) ^ (seed * 0xcb1ab31fu);
    h ^= h >> 13;
    h *= 0x5bd1e995u;
    h ^= h >> 15;
    return float(h & 0x00ffffffu) / 16777215.0f;
}

/// photocraft-engine `clouds_value` (`freq` = 1 / base).
inline float pca_ren_clouds_value(float x, float y, float freq0, uint seed) {
    float sum = 0.0f, amp = 1.0f, freq = freq0, norm = 0.0f;
    for (uint o = 0u; o < 8u; o++) {
        float fx = x * freq, fy = y * freq;
        int ix = int(floor(fx)), iy = int(floor(fy));
        float tx = fx - float(ix), ty = fy - float(iy);
        float sx = tx * tx * (3.0f - 2.0f * tx), sy = ty * ty * (3.0f - 2.0f * ty);
        uint s = seed + o * 7919u;
        float h00 = pca_ren_clouds_hash(ix, iy, s), h10 = pca_ren_clouds_hash(ix + 1, iy, s);
        float h01 = pca_ren_clouds_hash(ix, iy + 1, s), h11 = pca_ren_clouds_hash(ix + 1, iy + 1, s);
        float top = h00 + (h10 - h00) * sx;
        float bot = h01 + (h11 - h01) * sx;
        sum += (top + (bot - top) * sy) * amp;
        norm += amp;
        amp *= 0.5f;
        freq *= 2.0f;
    }
    // An S-curve with slope 2.2 at mid-grey that meets 0 and 1 only where the sum does, so the
    // tails are compressed instead of clipped to the two colours (photocraft #9959).
    const float c = 2.2f;
    float h = sqrt(c * c - 1.0f);
    float d = (sum / norm - 0.5f) * 2.0f * h;
    return clamp(0.5f + 0.5f * c / h * d / sqrt(1.0f + d * d), 0.0f, 1.0f);
}

struct pca_ren_clouds_params {
    float4 fg;
    float4 bg;
    float freq;
    uint seed;
    uint difference;
    int pad0;
};

kernel void pca_ren_clouds(constant pca_frame& f [[buffer(0)]], constant pca_ren_clouds_params& p [[buffer(1)]],
                           pca_in src [[texture(0)]], pca_out dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    float t = pca_ren_clouds_value(float(q.x), float(q.y), p.freq, p.seed);
    float3 c = p.fg.xyz + (p.bg.xyz - p.fg.xyz) * t;
    float4 o;
    if (p.difference != 0u) {
        o = pca_ren_rgba(pca_get(src, f, q), f);
        o.xyz = fabs(o.xyz - c);
    } else {
        o = float4(c, 1.0f);
    }
    dst.write(pca_ren_native(o, f), gid);
}
