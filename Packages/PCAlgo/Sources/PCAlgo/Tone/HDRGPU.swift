// Port of photocraft-algo (crates/algo/src/hdr.rs: merge, tone_map), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Metal paths of Merge to HDR Pro: tone mapping (all four methods, with their global
// reductions — mean log luminance, min/max and the 1024-bin histogram of log luminance — on the
// GPU) and the per-pixel radiance merge with the ghost mask.

import Foundation
import Metal
import PCFoundation

extension ToneKit {
    /// `HDRToneMap.encodeGPU`.
    static func encodeToneMap(_ method: HDRToneMethod, _ pass: GPUPass) throws {
        let b = pass.ctx.bounds
        if b.isEmpty {
            try pass.dispatchOut("pca_copy", params: NoParams())
            return
        }
        let rect = RectParams(b)
        let rgba = try pass.toneRGBA(b)
        /// Mean of ln(max(Rec. 709 luminance, `floor`)) over opaque pixels, into a buffer; the
        /// per-pixel values stay in the returned texture.
        func logLuminance(floor: Float) throws -> (any MTLTexture, any MTLBuffer) {
            let t = try pass.texture(b)
            try pass.dispatch("pca_tone_tm_loglum", params: TMParams(rect: rect, a: floor), textures: [rgba, t], width: b.width, height: b.height)
            let m = try pass.scratchBuffer(length: 16)
            try pass.toneMaskedMean(t, mask: rgba, rect: b, into: m)
            return (t, m)
        }
        switch method {
        case .localAdaptation(let p):
            let (_, lm) = try logLuminance(floor: 1e-6)
            try encodeHdrToning(p, pass, rgba: rgba, rect: b, prescale: lm, encode: true)
        case .exposureGamma(let exposure, let gamma):
            let tp = TMParams(rect: rect, a: powf(2, exposure), b: clampf(gamma, 0.1, 10))
            try pass.dispatchOut("pca_tone_tm_exposure_gamma", params: tp, textures: [pass.src, rgba, pass.dst])
        case .highlightCompression:
            let (_, lm) = try logLuminance(floor: 1e-6)
            try pass.dispatchOut("pca_tone_tm_highlight", params: TMParams(rect: rect), textures: [pass.src, rgba, pass.dst], buffers: [lm])
        case .equalizeHistogram:
            let lv = try pass.texture(b)
            try pass.dispatch("pca_tone_tm_loglum", params: TMParams(rect: rect, a: 1e-7), textures: [rgba, lv], width: b.width, height: b.height)
            let n = b.area
            let groups = max((n + 255) / 256, 1)
            let partial = try pass.scratchBuffer(length: groups * 8), lohi = try pass.scratchBuffer(length: 16)
            let rp = ReduceParams(width: Int32(b.width), count: UInt32(n), groups: UInt32(groups))
            try pass.dispatch("pca_tone_masked_minmax", params: rp, textures: [lv, rgba], buffers: [partial],
                              width: groups * 256, height: 1, threadgroup: (256, 1))
            try pass.dispatch("pca_tone_masked_minmax_final", params: rp, textures: [], buffers: [partial, lohi],
                              width: 256, height: 1, threadgroup: (256, 1))
            let hist = try pass.scratchBuffer(length: 1024 * 4)
            guard let blit = pass.commandBuffer.makeBlitCommandEncoder() else { throw FilterError.gpuUnavailable("blit") }
            blit.fill(buffer: hist, range: 0..<(1024 * 4), value: 0)
            blit.endEncoding()
            let hp = SH.HistParams(width: Int32(b.width), count: UInt32(n), total: UInt32(SH.histGroups * 256), pad0: 0)
            try pass.dispatch("pca_tone_tm_eq_hist", params: hp, textures: [lv, rgba], buffers: [lohi, hist],
                              width: SH.histGroups * 256, height: 1, threadgroup: (256, 1))
            let cdf = try pass.scratchBuffer(length: 1024 * 4)
            try pass.dispatch("pca_tone_tm_eq_cdf", params: NoParams(), textures: [], buffers: [hist, cdf], width: 1, height: 1, threadgroup: (1, 1))
            try pass.dispatchOut("pca_tone_tm_equalize", params: TMParams(rect: rect), textures: [pass.src, rgba, lv, pass.dst], buffers: [lohi, cdf])
        }
    }

    /// MSL `pca_tone_tm_params`.
    struct TMParams: BitwiseCopyable {
        var origin: SIMD2<Int32>
        var size: SIMD2<Int32>
        var a: Float
        var b: Float
        var pad0: Float = 0
        var pad1: Float = 0
        init(rect: RectParams, a: Float = 0, b: Float = 0) { origin = rect.origin; size = rect.size; self.a = a; self.b = b }
    }

    // MARK: Merge

    /// The per-pixel radiance merge and ghost handling in Metal (before the per-channel scale,
    /// which needs a median of the result and stays on the CPU).
    static func mergeGPU(_ w: Int, _ h: Int, _ imgs: [[SIMD4<Float>]], _ logDt: [Double], _ response: [[Double]],
                         _ base: Int, _ ghosts: Bool) throws -> ([SIMD4<Float>], Double) {
        let gpu = try AlgoGPU.shared()
        let dev = gpu.device
        let n = w * h, p = imgs.count
        if n == 0 { return ([], 0) }
        if max(w, h) > FilterEngine.maxGPUSize { throw FilterError.gpuUnsupported("images larger than \(FilterEngine.maxGPUSize) px") }
        guard let imgBuf = dev.makeBuffer(length: n * p * 16, options: .storageModeShared),
              let outBuf = dev.makeBuffer(length: n * 16, options: .storageModeShared),
              let countBuf = dev.makeBuffer(length: 16, options: .storageModeShared) else {
            throw FilterError.gpuUnavailable("merge buffers")
        }
        for (j, im) in imgs.enumerated() {
            im.withUnsafeBytes { s in (imgBuf.contents() + j * n * 16).copyMemory(from: s.baseAddress!, byteCount: n * 16) }
        }
        memset(countBuf.contents(), 0, 16)
        let rect = PixelRect(x: 0, y: 0, width: w, height: h)
        let resp: [Float] = response.flatMap { $0.map { Float($0) } }
        let ldt: [Float] = logDt.prefix(p).map { Float($0) }
        try gpu.metal.run(label: "Merge to HDR Pro") { cb in
            let pass = try syntheticPass(gpu, cb, rect)
            let respB = try pass.buffer(resp), ldtB = try pass.buffer(ldt)
            let mp = MergeParams(width: Int32(w), height: Int32(h), images: Int32(p), base: Int32(base), pixels: UInt32(n))
            try pass.dispatch("pca_tone_hdr_merge", params: mp, textures: [], buffers: [imgBuf, respB, ldtB, outBuf], width: w, height: h)
            if ghosts {
                let mask = try pass.texture(rect)
                try pass.dispatch("pca_tone_hdr_ghost_score", params: mp, textures: [mask], buffers: [imgBuf, respB, ldtB], width: w, height: h)
                let a = try pass.texture(rect), bT = try pass.texture(rect)
                let blurred = try pass.toneGaussBlur(mask, rect: rect, sigma: Float.maximum(Float(max(w, h)) / 200, 2), scratch: a, bT)
                try pass.dispatch("pca_tone_hdr_ghost_mix", params: mp, textures: [blurred], buffers: [imgBuf, respB, ldtB, outBuf, countBuf],
                                  width: w, height: h)
            }
        }
        var px = [SIMD4<Float>](repeating: .zero, count: n)
        px.withUnsafeMutableBytes { d in d.copyMemory(from: UnsafeRawBufferPointer(start: outBuf.contents(), count: n * 16)) }
        let ghostCount = countBuf.contents().load(as: UInt32.self)
        return (px, ghosts ? Double(ghostCount) / Double(n) : 0)
    }

    /// A GPUPass on a caller-owned command buffer for kernels that don't read a filter source
    /// (the frame describes `rect`; `src`/`dst` are placeholders).
    static func syntheticPass(_ gpu: AlgoGPU, _ cb: any MTLCommandBuffer, _ rect: PixelRect) throws -> GPUPass {
        let ph = try gpu.privateTexture(width: 1, height: 1)
        let o = SIMD2(rect.x0, rect.y0), s = SIMD2(Int32(rect.width), Int32(rect.height))
        let frame = PCAFrame(srcOrigin: o, srcSize: s, outOrigin: o, outSize: s, boundsOrigin: o, boundsSize: s,
                             alpha: 1, mode: 1, ncomp: 3, plane: 0, colorChannels: 3, firstChannel: 0)
        return GPUPass(gpu: gpu, commandBuffer: cb, src: ph, dst: ph, frame: frame, ctx: FilterContext(bounds: rect, mode: .rgb, alpha: true),
                       srcRect: rect, out: rect, plane: 0, planeChannels: [0, 1, 2])
    }

    /// MSL `pca_tone_hdr_merge_params`.
    struct MergeParams: BitwiseCopyable {
        var width: Int32
        var height: Int32
        var images: Int32
        var base: Int32
        var pixels: UInt32
        var pad0: UInt32 = 0
        var pad1: UInt32 = 0
        var pad2: UInt32 = 0
    }
}
