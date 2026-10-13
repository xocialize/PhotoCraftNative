// Port of photocraft-algo (crates/algo/src/panorama.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Metal path of Photomerge's multi-band blend (Shaders/PhotoPanorama.metal). Per image (one
// command buffer each, so every panorama pixel accumulates the images in order): its colours,
// coverage and weights on its band grid are uploaded, holes are push-pulled (always recursing to
// 1 × 1; a level's push only applies where the CPU recursion would have happened, recorded by the
// pull as "has a zero and a positive weight"), its Gaussian levels are built and each Laplacian
// band is accumulated into the panorama level at its offset. Then the levels are normalised and
// collapsed. The coverage union stays on the CPU. Bit-identical to `Panorama.multibandCPU`.

import Foundation
import Metal
import PCFoundation

enum PanoramaGPU {
    /// MSL `pca_pho_band_params`.
    struct BandParams: BitwiseCopyable {
        var cw: Int32, chh: Int32, nw: Int32, nh: Int32
        var pw: Int32, ph: Int32, ox: Int32, oy: Int32
        var ch: Int32, hasUp: UInt32
        var pad0: Int32 = 0, pad1: Int32 = 0
    }

    typealias D = PyramidGPU.Dims

    static func multiband(_ w: Int, _ h: Int, _ imgs: [Panorama.RoiImage], _ weights: [[Float]], _ levels: Int) throws -> ([Float], [Float]) {
        let ch = imgs.first?.ch ?? 1
        try PyramidGPU.checkSize(w, h, ch, "Panorama.multiband")
        let gpu = try AlgoGPU.shared()
        var sizes = [(w, h)]
        for _ in 1..<max(levels, 1) {
            let (pw, ph) = sizes[sizes.count - 1]
            sizes.append(((pw + 1) / 2, (ph + 1) / 2))
        }
        let acc = try PyramidGPU.levelBuffers(gpu, sizes, ch), wsum = try PyramidGPU.levelBuffers(gpu, sizes, 1)
        let out = try PhotoKit.sharedBuffer(gpu, count: w * h * ch)
        try gpu.metal.run(label: "Panorama.multiband clear") { cb in
            for l in 0..<levels {
                try PhotoKit.zero(cb, acc[l], count: sizes[l].0 * sizes[l].1 * ch)
                try PhotoKit.zero(cb, wsum[l], count: sizes[l].0 * sizes[l].1)
            }
        }
        for (k, im) in imgs.enumerated() {
            let g = Panorama.bandGrid(im, w, h, levels)
            let (px, cov, wt) = Panorama.bandInputs(im, weights[k], g, ch)
            let bin = cov.map { $0 > 0.5 ? Float(1) : 0 }
            // Push-pull levels down to 1 × 1.
            var ppSizes = [(g.gw, g.gh)]
            while true {
                let (a, b) = ppSizes[ppSizes.count - 1]
                if a <= 1 && b <= 1 { break }
                ppSizes.append(((a + 1) / 2, (b + 1) / 2))
            }
            var ppx = try PyramidGPU.levelBuffers(gpu, ppSizes, ch, from: 1), pw = try PyramidGPU.levelBuffers(gpu, ppSizes, 1, from: 1)
            ppx[0] = try PhotoKit.sharedBuffer(gpu, px)
            pw[0] = try PhotoKit.sharedBuffer(gpu, bin)
            let flags = try ppSizes.map { _ in try PhotoKit.privateBuffer(gpu, count: 4) }
            // The band pyramid of the push-pulled colours and of the weights.
            var bandSizes = [(g.gw, g.gh)]
            for _ in 1..<max(levels, 1) {
                let (a, b) = bandSizes[bandSizes.count - 1]
                bandSizes.append(((a + 1) / 2, (b + 1) / 2))
            }
            var cur = try PyramidGPU.levelBuffers(gpu, bandSizes, ch, from: 1), gau = try PyramidGPU.levelBuffers(gpu, bandSizes, 1, from: 1)
            cur[0] = ppx[0]
            gau[0] = try PhotoKit.sharedBuffer(gpu, wt)
            let btmp = try PhotoKit.privateBuffer(gpu, count: PyramidGPU.tmpCount(g.gw, g.gh, ch))
            try gpu.metal.run(label: "Panorama.multiband") { cb in
                let e = try PyramidGPU.Encoder(gpu, cb, g.gw, g.gh)
                for f in flags { try PhotoKit.zero(cb, f, count: 4) }
                for l in 0..<(ppSizes.count - 1) {
                    let (sw, sh) = ppSizes[l], (dw, dh) = ppSizes[l + 1]
                    let d = D(sw: Int32(sw), sh: Int32(sh), dw: Int32(dw), dh: Int32(dh), ch: Int32(ch))
                    try e.run("pca_pho_pp_down", d, [ppx[l], pw[l], ppx[l + 1], pw[l + 1], flags[l + 1]], dw, dh)
                }
                for l in stride(from: ppSizes.count - 2, through: 0, by: -1) {
                    let (fw, fh) = ppSizes[l], (cw, _) = ppSizes[l + 1]
                    let d = D(sw: Int32(cw), sh: 0, dw: Int32(fw), dh: Int32(fh), ch: Int32(ch), mode: l == 0 ? 0 : 1)
                    try e.run("pca_pho_pp_up", d, [ppx[l], pw[l], ppx[l + 1], flags[l]], fw, fh)
                }
                for l in 1..<max(levels, 1) where l < levels {
                    let (sw, sh) = bandSizes[l - 1], (dw, dh) = bandSizes[l]
                    let dc = D(sw: Int32(sw), sh: Int32(sh), dw: Int32(dw), dh: Int32(dh), ch: Int32(ch))
                    try e.run("pca_pho_pano_reduce_h", dc, [cur[l - 1], btmp], dw, sh)
                    try e.run("pca_pho_pano_reduce_v", dc, [btmp, cur[l]], dw, dh)
                    let d1 = D(sw: Int32(sw), sh: Int32(sh), dw: Int32(dw), dh: Int32(dh), ch: 1)
                    try e.run("pca_pho_pano_reduce_h", d1, [gau[l - 1], btmp], dw, sh)
                    try e.run("pca_pho_pano_reduce_v", d1, [btmp, gau[l]], dw, dh)
                }
                for l in 0..<levels {
                    let (cw, chh) = bandSizes[l]
                    let next = l + 1 < levels ? bandSizes[l + 1] : (1, 1)
                    let bp = BandParams(cw: Int32(cw), chh: Int32(chh), nw: Int32(next.0), nh: Int32(next.1),
                                        pw: Int32(sizes[l].0), ph: Int32(sizes[l].1), ox: g.gx0 >> Int32(l), oy: g.gy0 >> Int32(l),
                                        ch: Int32(ch), hasUp: l + 1 < levels ? 1 : 0)
                    try e.pass.dispatch("pca_pho_pano_band_acc", params: bp, textures: [],
                                        buffers: [cur[l], l + 1 < levels ? cur[l + 1] : e.dummy, gau[l], acc[l], wsum[l]], width: cw, height: chh)
                }
            }
        }
        try gpu.metal.run(label: "Panorama.multiband collapse") { cb in
            let e = try PyramidGPU.Encoder(gpu, cb, w, h)
            for l in 0..<levels { try e.normalize(acc[l], wsum[l], sizes[l].0, sizes[l].1, ch, threshold: 1e-8) }
            if levels >= 2 {
                for l in stride(from: levels - 2, through: 0, by: -1) {
                    let (pw, ph) = sizes[l], (sw, sh) = sizes[l + 1]
                    try e.run("pca_pho_pano_expand_add", D(sw: Int32(sw), sh: Int32(sh), dw: Int32(pw), dh: Int32(ph), ch: Int32(ch)), [acc[l + 1], acc[l]], pw, ph)
                }
            }
            try PhotoKit.copy(cb, acc[0], to: out, count: w * h * ch)
        }
        return (PhotoKit.read(out, count: w * h * ch), Panorama.coverage(w, h, imgs))
    }

}
