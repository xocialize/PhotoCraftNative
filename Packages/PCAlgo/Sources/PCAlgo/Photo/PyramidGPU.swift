// Port of photocraft-algo (crates/algo/src/pyramid.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Metal path of the Burt–Adelson pyramids (Shaders/Photo.metal): every level lives in a
// private float buffer of `w × h × ch`; REDUCE and EXPAND are separable two-pass kernels and the
// per-level work (Laplacian band, blend accumulation, focus-stack selection, halo fold, collapse)
// is fused into the vertical EXPAND pass. Images are folded in one command buffer each, so only
// the running result pyramid and one image's pyramid are resident, as in the CPU reference.

import Foundation
import Metal
import PCFoundation

enum PyramidGPU {
    /// MSL `pca_pho_dims`.
    struct Dims: BitwiseCopyable {
        var sw: Int32 = 0
        var sh: Int32 = 0
        var dw: Int32 = 0
        var dh: Int32 = 0
        var ch: Int32 = 1
        var mode: UInt32 = 0
        var flags: UInt32 = 0
        var base: UInt32 = 0
        var a: Float = 0
        var b: Float = 0
        var c: Float = 0
        var d: Float = 0
    }

    static let hasUp: UInt32 = 1
    static let first: UInt32 = 2

    /// The level sizes a pyramid of `levels` levels over `w × h` has (REDUCE stops at 1 × 1).
    static func sizes(_ w: Int, _ h: Int, _ levels: Int) -> [(Int, Int)] {
        var out = [(w, h)]
        while out.count < max(levels, 1) {
            let (a, b) = out[out.count - 1]
            if a <= 1 && b <= 1 { break }
            out.append(((a + 1) / 2, (b + 1) / 2))
        }
        return out
    }

    /// Kernel encoding on one command buffer.
    final class Encoder {
        let gpu: AlgoGPU
        let pass: GPUPass
        let dummy: any MTLBuffer

        init(_ gpu: AlgoGPU, _ cb: any MTLCommandBuffer, _ w: Int, _ h: Int) throws {
            self.gpu = gpu
            pass = try GPUPass.synthetic(gpu, cb, rect: PixelRect(x: 0, y: 0, width: max(w, 1), height: max(h, 1)))
            dummy = try PhotoKit.privateBuffer(gpu, count: 4)
        }

        var cb: any MTLCommandBuffer { pass.commandBuffer }

        func run(_ kernel: String, _ d: Dims, _ buffers: [any MTLBuffer], _ width: Int, _ height: Int) throws {
            try pass.dispatch(kernel, params: d, textures: [], buffers: buffers, width: width, height: height)
        }

        /// REDUCE `src` (sw × sh × ch) into `dst` ((sw+1)/2 × (sh+1)/2); `tmp` holds ≥ (sw+1)/2 · sh · ch.
        func reduce(_ src: any MTLBuffer, _ sw: Int, _ sh: Int, _ ch: Int, into dst: any MTLBuffer, tmp: any MTLBuffer) throws {
            let dw = (sw + 1) / 2, dh = (sh + 1) / 2
            let d = Dims(sw: Int32(sw), sh: Int32(sh), dw: Int32(dw), dh: Int32(dh), ch: Int32(ch))
            try run("pca_pho_reduce_h", d, [src, tmp], dw, sh)
            try run("pca_pho_reduce_v", d, [tmp, dst], dw, dh)
        }

        /// Horizontal EXPAND of `src` (sw × sh) to width `dw` into `tmp`.
        func expandH(_ src: any MTLBuffer, _ sw: Int, _ sh: Int, _ ch: Int, toWidth dw: Int, tmp: any MTLBuffer) throws {
            let d = Dims(sw: Int32(sw), sh: Int32(sh), dw: Int32(dw), dh: 0, ch: Int32(ch))
            try run("pca_pho_expand_h", d, [src, tmp], dw, sh)
        }

        /// Vertical EXPAND of `tmp` (dw × sh) to dw × dh fused with `mode` (see the kernel).
        func expandV(_ tmp: any MTLBuffer?, sh: Int, _ dw: Int, _ dh: Int, _ ch: Int, mode: UInt32, flags: UInt32,
                     base: any MTLBuffer, dst: any MTLBuffer, aux1: (any MTLBuffer)? = nil, aux2: (any MTLBuffer)? = nil) throws {
            let d = Dims(sw: 0, sh: Int32(sh), dw: Int32(dw), dh: Int32(dh), ch: Int32(ch), mode: mode, flags: flags)
            try run("pca_pho_expand_v", d, [tmp ?? dummy, base, dst, aux1 ?? dummy, aux2 ?? dummy], dw, dh)
        }

        func normalize(_ acc: any MTLBuffer, _ wsum: any MTLBuffer, _ w: Int, _ h: Int, _ ch: Int, threshold: Float) throws {
            let d = Dims(dw: Int32(w), dh: Int32(h), ch: Int32(ch), a: threshold)
            try run("pca_pho_normalize", d, [acc, wsum], w, h)
        }

        func clamp(_ src: any MTLBuffer, _ dst: any MTLBuffer, _ w: Int, _ h: Int, _ ch: Int) throws {
            try run("pca_pho_clamp", Dims(dw: Int32(w), dh: Int32(h), ch: Int32(ch)), [src, dst], w, h)
        }

        /// Collapses the Laplacian pyramid `levels` in place; the clamped (or plain) result lands
        /// in `out` (level 0's size).
        func collapse(_ levels: [any MTLBuffer], _ sz: [(Int, Int)], _ ch: Int, tmp: any MTLBuffer, out: any MTLBuffer, clamp01: Bool) throws {
            let n = levels.count
            if n == 1 {
                if clamp01 { try clamp(levels[0], out, sz[0].0, sz[0].1, ch) } else { try PhotoKit.copy(cb, levels[0], to: out, count: sz[0].0 * sz[0].1 * ch) }
                return
            }
            for li in stride(from: n - 2, through: 0, by: -1) {
                let (w, h) = sz[li], (sw, sh) = sz[li + 1]
                try expandH(levels[li + 1], sw, sh, ch, toWidth: w, tmp: tmp)
                let mode: UInt32 = li == 0 ? (clamp01 ? 3 : 2) : 2
                try expandV(tmp, sh: sh, w, h, ch, mode: mode, flags: hasUp, base: levels[li], dst: li == 0 ? out : levels[li])
            }
        }
    }

    /// Private buffers for every level of a pyramid with `ch` channels (level 0 optional).
    static func levelBuffers(_ gpu: AlgoGPU, _ sz: [(Int, Int)], _ ch: Int, from: Int = 0) throws -> [any MTLBuffer] {
        try sz.enumerated().map { i, s in try PhotoKit.privateBuffer(gpu, count: i < from ? 1 : s.0 * s.1 * ch) }
    }

    /// Scratch for one separable pass anywhere in the pyramid.
    static func tmpCount(_ w: Int, _ h: Int, _ ch: Int) -> Int {
        max((w + 1) / 2 * h, w * ((h + 1) / 2), 1) * ch
    }

    /// Copies `values` into a shared buffer of matching size.
    static func upload(_ values: [Float], _ buf: any MTLBuffer) {
        values.withUnsafeBytes { s in
            if s.count > 0 { buf.contents().copyMemory(from: s.baseAddress!, byteCount: min(s.count, buf.length)) }
        }
    }

    static func checkSize(_ w: Int, _ h: Int, _ ch: Int, _ name: String) throws {
        if !PhotoKit.gpuFits(w, h, ch) { throw FilterError.gpuUnsupported("\(name) \(w)×\(h)×\(ch)") }
    }

    // MARK: - Pyramids

    /// `Pyramid.gaussian` on the GPU.
    static func gaussian(_ w: Int, _ h: Int, _ ch: Int, _ px: [Float], _ levels: Int) throws -> [Pyramid.Level] {
        try checkSize(w, h, ch, "Pyramid.gaussian")
        let gpu = try AlgoGPU.shared()
        let sz = sizes(w, h, levels)
        let bufs = try sz.map { try PhotoKit.sharedBuffer(gpu, count: $0.0 * $0.1 * ch) }
        upload(px, bufs[0])
        let tmp = try PhotoKit.privateBuffer(gpu, count: tmpCount(w, h, ch))
        try gpu.metal.run(label: "Pyramid.gaussian") { cb in
            let e = try Encoder(gpu, cb, w, h)
            for li in 1..<max(sz.count, 1) where li < sz.count {
                try e.reduce(bufs[li - 1], sz[li - 1].0, sz[li - 1].1, ch, into: bufs[li], tmp: tmp)
            }
        }
        return sz.enumerated().map { i, s in
            Pyramid.Level(w: s.0, h: s.1, px: i == 0 ? px : PhotoKit.read(bufs[i], count: s.0 * s.1 * ch))
        }
    }

    /// `Pyramid.laplacian` on the GPU.
    static func laplacian(_ w: Int, _ h: Int, _ ch: Int, _ px: [Float], _ levels: Int) throws -> [Pyramid.Level] {
        try checkSize(w, h, ch, "Pyramid.laplacian")
        let gpu = try AlgoGPU.shared()
        let sz = sizes(w, h, levels)
        let g = try sz.map { try PhotoKit.sharedBuffer(gpu, count: $0.0 * $0.1 * ch) }
        let bands = try sz.map { try PhotoKit.sharedBuffer(gpu, count: $0.0 * $0.1 * ch) }
        upload(px, g[0])
        let tmp = try PhotoKit.privateBuffer(gpu, count: tmpCount(w, h, ch))
        try gpu.metal.run(label: "Pyramid.laplacian") { cb in
            let e = try Encoder(gpu, cb, w, h)
            for li in 1..<max(sz.count, 1) where li < sz.count {
                try e.reduce(g[li - 1], sz[li - 1].0, sz[li - 1].1, ch, into: g[li], tmp: tmp)
            }
            for li in 0..<(sz.count - 1) {
                try e.expandH(g[li + 1], sz[li + 1].0, sz[li + 1].1, ch, toWidth: sz[li].0, tmp: tmp)
                try e.expandV(tmp, sh: sz[li + 1].1, sz[li].0, sz[li].1, ch, mode: 1, flags: hasUp, base: g[li], dst: bands[li])
            }
        }
        return sz.enumerated().map { i, s in
            let n = s.0 * s.1 * ch
            return Pyramid.Level(w: s.0, h: s.1, px: PhotoKit.read(i + 1 == sz.count ? g[i] : bands[i], count: n))
        }
    }

    /// `Pyramid.collapse` on the GPU.
    static func collapse(_ pyr: [Pyramid.Level], _ ch: Int) throws -> [Float] {
        guard let l0 = pyr.first else { return [] }
        try checkSize(l0.w, l0.h, ch, "Pyramid.collapse")
        let gpu = try AlgoGPU.shared()
        let sz = pyr.map { ($0.w, $0.h) }
        let bufs = try pyr.map { try PhotoKit.sharedBuffer(gpu, $0.px) }
        let out = try PhotoKit.sharedBuffer(gpu, count: l0.w * l0.h * ch)
        let tmp = try PhotoKit.privateBuffer(gpu, count: tmpCount(l0.w, l0.h, ch))
        try gpu.metal.run(label: "Pyramid.collapse") { cb in
            let e = try Encoder(gpu, cb, l0.w, l0.h)
            try e.collapse(bufs, sz, ch, tmp: tmp, out: out, clamp01: false)
        }
        return PhotoKit.read(out, count: l0.w * l0.h * ch)
    }

    // MARK: - Blend

    /// `Pyramid.blend` on the GPU: per image, its Laplacian bands weighted by the Gaussian of its
    /// weights are accumulated level by level; then normalised, collapsed and clamped.
    static func blend(_ w: Int, _ h: Int, _ ch: Int, _ images: [[Float]], _ weights: [[Float]], _ levels: Int) throws -> [Float] {
        try checkSize(w, h, ch, "Pyramid.blend")
        if images.isEmpty { return [Float](repeating: 0, count: w * h * ch) }
        let gpu = try AlgoGPU.shared()
        let sz = sizes(w, h, levels)
        let nl = sz.count
        let img0 = try PhotoKit.sharedBuffer(gpu, count: w * h * ch), wt0 = try PhotoKit.sharedBuffer(gpu, count: w * h)
        var g = try levelBuffers(gpu, sz, ch, from: 1), gw = try levelBuffers(gpu, sz, 1, from: 1)
        g[0] = img0; gw[0] = wt0
        let acc = try levelBuffers(gpu, sz, ch), wsum = try levelBuffers(gpu, sz, 1)
        let tmp = try PhotoKit.privateBuffer(gpu, count: tmpCount(w, h, ch))
        let out = try PhotoKit.sharedBuffer(gpu, count: w * h * ch)
        for (k, (img, wt)) in zip(images, weights).enumerated() {
            upload(img, img0); upload(wt, wt0)
            let last = k == images.count - 1
            try gpu.metal.run(label: "Pyramid.blend") { cb in
                let e = try Encoder(gpu, cb, w, h)
                if k == 0 {
                    for li in 0..<nl {
                        try PhotoKit.zero(cb, acc[li], count: sz[li].0 * sz[li].1 * ch)
                        try PhotoKit.zero(cb, wsum[li], count: sz[li].0 * sz[li].1)
                    }
                }
                for li in 1..<max(nl, 1) where li < nl {
                    try e.reduce(g[li - 1], sz[li - 1].0, sz[li - 1].1, ch, into: g[li], tmp: tmp)
                    try e.reduce(gw[li - 1], sz[li - 1].0, sz[li - 1].1, 1, into: gw[li], tmp: tmp)
                }
                for li in 0..<nl {
                    let (lw, lh) = sz[li]
                    if li + 1 < nl {
                        try e.expandH(g[li + 1], sz[li + 1].0, sz[li + 1].1, ch, toWidth: lw, tmp: tmp)
                        try e.expandV(tmp, sh: sz[li + 1].1, lw, lh, ch, mode: 6, flags: hasUp, base: g[li], dst: acc[li], aux1: gw[li], aux2: wsum[li])
                    } else {
                        try e.expandV(nil, sh: 0, lw, lh, ch, mode: 6, flags: 0, base: g[li], dst: acc[li], aux1: gw[li], aux2: wsum[li])
                    }
                }
                if last {
                    for li in 0..<nl { try e.normalize(acc[li], wsum[li], sz[li].0, sz[li].1, ch, threshold: 1e-6) }
                    try e.collapse(acc, sz, ch, tmp: tmp, out: out, clamp01: true)
                }
            }
        }
        return PhotoKit.read(out, count: w * h * ch)
    }

    // MARK: - Focus-stack fusion

    /// `Pyramid.fuseStack` on the GPU. Per image and level, in increasing level order: the
    /// luminance band and its region energy, then the image band fused with the selection
    /// (selecting levels) or the halo fold (levels coarser than the guide); without halo control
    /// the residuals and their deviation / entropy are packed for the final Pareto rule.
    static func fuseStack(_ w: Int, _ h: Int, _ ch: Int, _ images: [[Float]], _ luma: [[Float]], _ alpha: [[Float]],
                          _ p: Pyramid.StackFusion) throws -> [Float] {
        try checkSize(w, h, ch, "Pyramid.fuseStack")
        let n = min(images.count, luma.count, alpha.count)
        if n == 0 { return [Float](repeating: 0, count: w * h * ch) }
        let gpu = try AlgoGPU.shared()
        let levels = Pyramid.fuseLevels(w, h, p)
        let sz = sizes(w, h, levels)
        precondition(sz.count == levels)
        let bands = levels - 1
        let halo = Pyramid.haloSetting(bands, p)
        let nsel = halo.map { $0.g + 1 } ?? bands
        let win = Pyramid.binomial(max(p.energyRadius, 0))
        let r = win.count / 2
        let winB = try PhotoKit.sharedBuffer(gpu, win)
        let terms = try PhotoKit.sharedBuffer(gpu, Pyramid.entropyTerms)

        let img0 = try PhotoKit.sharedBuffer(gpu, count: w * h * ch)
        let lum0 = try PhotoKit.sharedBuffer(gpu, count: w * h), al0 = try PhotoKit.sharedBuffer(gpu, count: w * h)
        var gi = try levelBuffers(gpu, sz, ch, from: 1), gl = try levelBuffers(gpu, sz, 1, from: 1), ga = try levelBuffers(gpu, sz, 1, from: 1)
        gi[0] = img0; gl[0] = lum0; ga[0] = al0
        let acc = try levelBuffers(gpu, sz, ch)
        let best = try (0..<nsel).map { try PhotoKit.privateBuffer(gpu, count: sz[$0].0 * sz[$0].1) }
        let wsum = try halo.map { hl in try ((hl.g + 1)..<levels).map { try PhotoKit.privateBuffer(gpu, count: sz[$0].0 * sz[$0].1) } } ?? []
        let tmp = try PhotoKit.privateBuffer(gpu, count: tmpCount(w, h, ch))
        let lband = try PhotoKit.privateBuffer(gpu, count: w * h), etmp = try PhotoKit.privateBuffer(gpu, count: w * h)
        let energy = try PhotoKit.privateBuffer(gpu, count: w * h)
        let wgt = try (0..<2).map { _ in try PhotoKit.privateBuffer(gpu, count: halo.map { sz[$0.g].0 * sz[$0.g].1 } ?? 1) }
        let (rw, rh) = sz[levels - 1], rn = rw * rh
        let packed = halo == nil
        let rpx = try PhotoKit.privateBuffer(gpu, count: packed ? n * rn * ch : 1)
        let rdev = try PhotoKit.privateBuffer(gpu, count: packed ? n * rn : 1), rent = try PhotoKit.privateBuffer(gpu, count: packed ? n * rn : 1)
        let rcov = try PhotoKit.privateBuffer(gpu, count: packed ? n * rn : 1)
        let out = try PhotoKit.sharedBuffer(gpu, count: w * h * ch)

        for k in 0..<n {
            upload(images[k], img0); upload(luma[k], lum0); upload(alpha[k], al0)
            let firstFlag: UInt32 = k == 0 ? first : 0
            try gpu.metal.run(label: "Pyramid.fuseStack") { cb in
                let e = try Encoder(gpu, cb, w, h)
                for li in 1..<max(levels, 1) where li < levels {
                    let (sw, sh) = sz[li - 1]
                    try e.reduce(gi[li - 1], sw, sh, ch, into: gi[li], tmp: tmp)
                    try e.reduce(gl[li - 1], sw, sh, 1, into: gl[li], tmp: tmp)
                    try e.reduce(ga[li - 1], sw, sh, 1, into: ga[li], tmp: tmp)
                }
                var wgtLevel = 0
                for li in 0..<levels {
                    let (lw, lh) = sz[li]
                    let hasNext = li + 1 < levels
                    if li < nsel {
                        // The luminance band and its region energy.
                        let (nw, nh) = sz[li + 1]
                        try e.expandH(gl[li + 1], nw, nh, 1, toWidth: lw, tmp: tmp)
                        try e.expandV(tmp, sh: nh, lw, lh, 1, mode: 1, flags: hasUp, base: gl[li], dst: lband)
                        let d = Dims(dw: Int32(lw), dh: Int32(lh), ch: Int32(win.count), mode: r == 0 ? 1 : 0)
                        if r > 0 { try e.run("pca_pho_energy_h", d, [lband, etmp, winB], lw, lh) }
                        try e.run("pca_pho_energy_v", d, [r > 0 ? etmp : lband, ga[li], energy, winB], lw, lh)
                        if let hl = halo, li == hl.g {
                            try e.run("pca_pho_halo_weight", Dims(dw: Int32(lw), dh: Int32(lh), a: hl.hard), [energy, wgt[0]], lw, lh)
                            wgtLevel = 0
                        }
                        // The image band, taken where its energy wins.
                        try e.expandH(gi[li + 1], nw, nh, ch, toWidth: lw, tmp: tmp)
                        try e.expandV(tmp, sh: nh, lw, lh, ch, mode: 4, flags: hasUp | firstFlag, base: gi[li], dst: acc[li], aux1: energy, aux2: best[li])
                    } else if let hl = halo {
                        // Halo fold: the guide's weights REDUCEd to this level.
                        let (pw, ph) = sz[li - 1]
                        try e.reduce(wgt[wgtLevel], pw, ph, 1, into: wgt[1 - wgtLevel], tmp: tmp)
                        wgtLevel = 1 - wgtLevel
                        if hasNext {
                            let (nw, nh) = sz[li + 1]
                            try e.expandH(gi[li + 1], nw, nh, ch, toWidth: lw, tmp: tmp)
                        }
                        try e.expandV(hasNext ? tmp : nil, sh: hasNext ? sz[li + 1].1 : 0, lw, lh, ch, mode: 5,
                                      flags: (hasNext ? hasUp : 0) | firstFlag, base: gi[li], dst: acc[li], aux1: wgt[wgtLevel], aux2: wsum[li - hl.g - 1])
                    } else {
                        // The residual, its coverage, deviation and entropy, packed for the end.
                        try PhotoKit.copy(cb, gi[li], to: rpx, k * rn * ch, count: rn * ch)
                        try PhotoKit.copy(cb, ga[li], to: rcov, k * rn, count: rn)
                        let d = Dims(dw: Int32(lw), dh: Int32(lh), base: UInt32(k * rn))
                        try e.run("pca_pho_dev_ent", d, [gl[li], rdev, rent, terms], lw, lh)
                    }
                }
                if k == n - 1 {
                    if let hl = halo {
                        for li in (hl.g + 1)..<levels {
                            try e.normalize(acc[li], wsum[li - hl.g - 1], sz[li].0, sz[li].1, ch, threshold: 0)
                        }
                    } else {
                        let d = Dims(dw: Int32(rw), dh: Int32(rh), ch: Int32(ch), mode: UInt32(n))
                        try e.run("pca_pho_fuse_residuals", d, [rpx, rdev, rent, rcov, acc[levels - 1]], rw, rh)
                    }
                    try e.collapse(acc, sz, ch, tmp: tmp, out: out, clamp01: true)
                }
            }
        }
        return PhotoKit.read(out, count: w * h * ch)
    }

    // MARK: - Stack weights

    /// `Pyramid.stackWeights` on the GPU: per image |∇²L|, its running-sum box blur (one thread per
    /// line, bit-identical) and the running winner; then the one-hot planes.
    static func stackWeights(_ w: Int, _ h: Int, _ luma: [[Float]], _ alpha: [[Float]]) throws -> [[Float]] {
        try checkSize(w, h, 1, "Pyramid.stackWeights")
        let n = min(luma.count, alpha.count)
        if n == 0 { return [] }
        let gpu = try AlgoGPU.shared()
        let r = min(max(min(w, h) / 64, 2), 12)
        let np = w * h
        let lum = try PhotoKit.sharedBuffer(gpu, count: np), al = try PhotoKit.sharedBuffer(gpu, count: np)
        let lap = try PhotoKit.privateBuffer(gpu, count: np), tmp = try PhotoKit.privateBuffer(gpu, count: np)
        let best = try PhotoKit.privateBuffer(gpu, count: np), idx = try PhotoKit.privateBuffer(gpu, count: np)
        let out = try PhotoKit.sharedBuffer(gpu, count: n * np)
        let d = Dims(dw: Int32(w), dh: Int32(h))
        for k in 0..<n {
            upload(luma[k], lum); upload(alpha[k], al)
            try gpu.metal.run(label: "Pyramid.stackWeights") { cb in
                let e = try Encoder(gpu, cb, w, h)
                try e.run("pca_pho_abs_laplacian", d, [lum, lap], w, h)
                let rows = Dims(dw: Int32(w), dh: Int32(h), ch: 1, mode: UInt32(r), flags: 0)
                let cols = Dims(dw: Int32(w), dh: Int32(h), ch: 1, mode: UInt32(r), flags: 1)
                try e.pass.dispatch("pca_pho_box_line", params: rows, textures: [], buffers: [lap, tmp], width: h, height: 1, threadgroup: (64, 1))
                try e.pass.dispatch("pca_pho_box_line", params: cols, textures: [], buffers: [tmp, lap], width: w, height: 1, threadgroup: (64, 1))
                try e.run("pca_pho_stack_winner", Dims(dw: Int32(w), dh: Int32(h), mode: UInt32(k), flags: k == 0 ? first : 0), [lap, al, best, idx], w, h)
                if k == n - 1 { try e.run("pca_pho_stack_onehot", Dims(dw: Int32(w), dh: Int32(h), mode: UInt32(n)), [best, idx, out], w, h) }
            }
        }
        let all = PhotoKit.read(out, count: n * np)
        return (0..<n).map { Array(all[($0 * np)..<(($0 + 1) * np)]) }
    }
}
