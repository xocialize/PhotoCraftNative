// Port of photocraft-algo (crates/algo/src/blur2.rs: smart_blur) and photocraft-engine (crates/engine/src/extra_cmds.rs: average), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

struct pca_smart_offset {
    int dx;
    int dy;
};

struct pca_smart_params {
    float4 white;
    float4 black;
    float t;
    uint mode;   // 0 normal, 1 edge only, 2 overlay edge
    int count;
    int pad;
};

inline bool pca_smart_differs(float4 q, float4 me, int cc, float t) {
    for (int c = 0; c < cc; c++) if (fabs(q[c] - me[c]) > t) return true;
    return false;
}

kernel void pca_smart_blur(constant pca_frame& f [[buffer(0)]], constant pca_smart_params& p [[buffer(1)]],
                           constant pca_smart_offset* offs [[buffer(2)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    bool alpha = f.alpha != 0u;
    int cc = int(f.ncomp);
    float4 me = pca_get(src, f, q);
    float4 r = me;
    if (p.mode != 0u) {
        bool edge = false;
        int2 nb[4] = {int2(1, 0), int2(0, 1), int2(-1, 0), int2(0, -1)};
        for (int k = 0; k < 4; k++) {
            if (pca_smart_differs(pca_get(src, f, q + nb[k]), me, cc, p.t)) { edge = true; break; }
        }
        for (int c = 0; c < cc; c++) {
            if (edge) r[c] = p.white[c];
            else if (p.mode == 1u) r[c] = p.black[c];
        }
        dst.write(r, gid);
        return;
    }
    float4 acc = float4(0.0f);
    float wsum = 0.0f;
    for (int i = 0; i < p.count; i++) {
        float4 v = pca_get(src, f, q + int2(offs[i].dx, offs[i].dy));
        if (pca_smart_differs(v, me, cc, p.t)) continue;
        acc += pca_premul(v, alpha);
        wsum += 1.0f;
    }
    if (wsum > 0.0f) r = pca_unpremul(acc / wsum, alpha);
    dst.write(r, gid);
}

struct pca_average_params {
    int2 area_origin;
    int2 area_size;
    int groups;
    int pad0;
    int pad1;
    int pad2;
};

struct pca_avg_sum {
    float4 colour;   // Σ colour·α
    float4 weight;   // .x Σ α, .y count
};

/// Each threadgroup sums a strided share of the area's pixels (tree reduction in threadgroup memory).
kernel void pca_average_partial(constant pca_frame& f [[buffer(0)]], constant pca_average_params& p [[buffer(1)]],
                                device pca_avg_sum* partial [[buffer(2)]], pca_in src [[texture(0)]],
                                threadgroup pca_avg_sum* sh [[threadgroup(0)]],
                                uint tid [[thread_index_in_threadgroup]], uint group [[threadgroup_position_in_grid]]) {
    bool alpha = f.alpha != 0u;
    int total = p.area_size.x * p.area_size.y;
    float4 c = float4(0.0f);
    float ws = 0.0f, cnt = 0.0f;
    for (int i = int(group) * 256 + int(tid); i < total; i += p.groups * 256) {
        int2 d = p.area_origin + int2(i % p.area_size.x, i / p.area_size.x);
        float4 v = pca_get(src, f, d);
        float a = alpha ? v.w : 1.0f;
        c += v * a;
        ws += a;
        cnt += 1.0f;
    }
    sh[tid].colour = c;
    sh[tid].weight = float4(ws, cnt, 0.0f, 0.0f);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = 128; s > 0; s >>= 1) {
        if (tid < s) {
            sh[tid].colour += sh[tid + s].colour;
            sh[tid].weight += sh[tid + s].weight;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) partial[group] = sh[0];
}

kernel void pca_average_total(constant pca_frame& f [[buffer(0)]], constant pca_average_params& p [[buffer(1)]],
                              device pca_avg_sum* partial [[buffer(2)]], device pca_avg_sum* total [[buffer(3)]],
                              threadgroup pca_avg_sum* sh [[threadgroup(0)]], uint tid [[thread_index_in_threadgroup]]) {
    pca_avg_sum acc = {float4(0.0f), float4(0.0f)};
    for (int i = int(tid); i < p.groups; i += 256) {
        acc.colour += partial[i].colour;
        acc.weight += partial[i].weight;
    }
    sh[tid] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = 128; s > 0; s >>= 1) {
        if (tid < s) {
            sh[tid].colour += sh[tid + s].colour;
            sh[tid].weight += sh[tid + s].weight;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) total[0] = sh[0];
}

kernel void pca_average_fill(constant pca_frame& f [[buffer(0)]], constant pca_average_params& p [[buffer(1)]],
                             device pca_avg_sum* total [[buffer(2)]], pca_in src [[texture(0)]], pca_out dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int2 q;
    if (!pca_out_pixel(f, gid, q)) return;
    pca_avg_sum t = total[0];
    float ws = t.weight.x;
    if (ws <= 0.0f) { dst.write(pca_get(src, f, q), gid); return; }
    float4 avg = t.colour / ws;
    if (f.alpha != 0u) avg.w = t.weight.x / max(t.weight.y, 1e-9f);
    dst.write(avg, gid);
}
