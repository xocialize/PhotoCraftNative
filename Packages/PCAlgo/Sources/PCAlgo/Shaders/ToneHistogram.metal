// Port of photocraft-algo (crates/algo/src/histogram.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// RgbHistogram::from_rgba as a grid-stride reduction: per-threadgroup atomic bins (exact integer
// counts), merged into the global counters. Layout: bins R, G, B (3 × 256), then samples,
// transparent, invalid, underflow[3], overflow[3], shadows[3], highlights[3].

#define PCA_TONE_HIST_N 783u

struct pca_tone_rgbhist_params {
    uint count;
    uint total;   // threads in the grid
    uint pad0;
    uint pad1;
};

kernel void pca_tone_rgb_hist(constant pca_tone_rgbhist_params& p [[buffer(0)]], device const float4* px [[buffer(1)]],
                              device atomic_uint* out [[buffer(2)]], uint gid [[thread_position_in_grid]],
                              uint tid [[thread_index_in_threadgroup]]) {
    threadgroup atomic_uint local[PCA_TONE_HIST_N];
    for (uint i = tid; i < PCA_TONE_HIST_N; i += 256u) atomic_store_explicit(&local[i], 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    // samples, transparent, invalid, underflow ×3, overflow ×3, shadows ×3, highlights ×3
    uint cnt[15] = {0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u};
    for (uint i = gid; i < p.count; i += p.total) {
        float4 q = px[i];
        if (!isfinite(q.w)) { cnt[2]++; continue; }
        if (q.w <= 0.0f) { cnt[1]++; continue; }
        if (!all(isfinite(q))) { cnt[2]++; continue; }
        cnt[0]++;
        for (uint c = 0u; c < 3u; c++) {
            float v = q[c];
            if (v <= 0.0f) cnt[9 + c]++;
            if (v >= 1.0f) cnt[12 + c]++;
            if (v < 0.0f) cnt[3 + c]++;
            else if (v > 1.0f) cnt[6 + c]++;
            uint bin = uint(clamp(v, 0.0f, 1.0f) * 255.0f + 0.5f);
            if (bin < 256u) atomic_fetch_add_explicit(&local[c * 256u + bin], 1u, memory_order_relaxed);
        }
    }
    for (uint k = 0u; k < 15u; k++) {
        if (cnt[k] > 0u) atomic_fetch_add_explicit(&local[768u + k], cnt[k], memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint i = tid; i < PCA_TONE_HIST_N; i += 256u) {
        uint v = atomic_load_explicit(&local[i], memory_order_relaxed);
        if (v > 0u) atomic_fetch_add_explicit(&out[i], v, memory_order_relaxed);
    }
}
