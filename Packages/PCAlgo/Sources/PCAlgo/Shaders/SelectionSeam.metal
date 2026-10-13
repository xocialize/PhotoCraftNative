// Port of photocraft-algo (crates/algo/src/seam.rs: energy_at), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Content-Aware Scale's energy map: |∂x| + |∂y| summed over the channels of an interleaved
// w × h × ch buffer (forward and backward differences, edges clamped), halved — the same
// operations in the same order as SeamCarving.energyAt.

struct pca_sel_seam_params {
    uint w;
    uint h;
    uint ch;
    uint pad0;
};

kernel void pca_sel_seam_energy(constant pca_sel_seam_params& p [[buffer(0)]], device const float* img [[buffer(1)]], device float* e [[buffer(2)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.w || gid.y >= p.h) return;
    uint x = gid.x, y = gid.y, w = p.w, ch = p.ch;
    uint xl = x > 0 ? x - 1 : 0, xr = min(x + 1, w - 1);
    uint yu = y > 0 ? y - 1 : 0, yd = min(y + 1, p.h - 1);
    float s = 0.0f;
    for (uint c = 0; c < ch; c++) {
        float v = img[(y * w + x) * ch + c];
        s += fabs(img[(y * w + xr) * ch + c] - v) + fabs(v - img[(y * w + xl) * ch + c]);
        s += fabs(img[(yd * w + x) * ch + c] - v) + fabs(v - img[(yu * w + x) * ch + c]);
    }
    e[y * w + x] = s * 0.5f;
}
