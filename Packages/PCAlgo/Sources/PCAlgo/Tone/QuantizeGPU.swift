// Port of photocraft-algo (crates/algo/src/quantize.rs: quantize, to_bitmap), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Metal paths of Indexed Color and Bitmap: one thread per pixel, the nearest palette entry by
// a linear scan (≤ 256 entries; exact distances and lowest-index ties, so the same answers as the
// CPU's kd-tree), and the per-pixel bitmap methods. Error diffusion is serial: CPU only.

import Foundation
import Metal
import PCFoundation

extension Quantize {
    /// `quantize` on the CPU or the GPU. Diffusion runs on the CPU (`.gpu` throws for it).
    @discardableResult
    public static func quantize(_ px: inout [SIMD4<Float>], w: Int, palette pal: [Rgb8], dither: Dither, amount: Float,
                                transparent: Int?, on backend: Backend) throws -> [UInt8] {
        let gpu: Bool
        switch backend {
        case .cpu: gpu = false
        case .gpu:
            if dither == .diffusion { throw FilterError.gpuUnsupported("error diffusion is serial") }
            gpu = true
        case .auto: gpu = dither != .diffusion && AlgoGPU.isAvailable && px.count >= 1 << 14
        }
        if !gpu || px.isEmpty { return quantize(&px, w: w, palette: pal, dither: dither, amount: amount, transparent: transparent) }
        return try quantizeGPU(&px, w, pal, dither, amount, transparent)
    }

    static func quantizeGPU(_ px: inout [SIMD4<Float>], _ w: Int, _ pal: [Rgb8], _ dither: Dither, _ amount: Float, _ transparent: Int?) throws -> [UInt8] {
        let gpu = try AlgoGPU.shared()
        let dev = gpu.device
        let n = px.count
        let palF: [SIMD4<Float>] = (pal.isEmpty ? [Rgb8(0, 0, 0)] : pal).map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 0) }
        guard let pxBuf = px.withUnsafeBytes({ dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let idxBuf = dev.makeBuffer(length: max(n, 16), options: .storageModeShared),
              let palBuf = palF.withUnsafeBytes({ dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
            throw FilterError.gpuUnavailable("quantize buffers")
        }
        memset(idxBuf.contents(), 0, max(n, 16))
        var p = QuantizeParams(width: UInt32(max(w, 1)), count: UInt32(n), dither: dither == .pattern ? 2 : dither == .noise ? 3 : 0,
                               transparent: Int32(transparent.map { Int(UInt8(truncatingIfNeeded: $0)) } ?? -1),
                               spread: spread(pal.count, amount), palCount: UInt32(pal.count))
        let pipeline = try gpu.pipeline("pca_tone_quantize")
        try gpu.metal.run(label: "Indexed Color") { cb in
            guard let enc = cb.makeComputeCommandEncoder() else { throw FilterError.gpuUnavailable("encoder") }
            enc.setComputePipelineState(pipeline)
            enc.setBytes(&p, length: MemoryLayout<QuantizeParams>.stride, index: 0)
            enc.setBuffer(pxBuf, offset: 0, index: 1)
            enc.setBuffer(idxBuf, offset: 0, index: 2)
            enc.setBuffer(palBuf, offset: 0, index: 3)
            enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            enc.endEncoding()
        }
        px.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: pxBuf.contents(), count: n * 16)) }
        return Array(UnsafeBufferPointer(start: idxBuf.contents().assumingMemoryBound(to: UInt8.self), count: n))
    }

    /// `toBitmap` on the CPU or the GPU. Diffusion runs on the CPU (`.gpu` throws for it).
    public static func toBitmap(_ gray: inout [Float], w: Int, method: BitmapMethod, on backend: Backend) throws {
        let gpu: Bool
        switch backend {
        case .cpu: gpu = false
        case .gpu:
            if method == .diffusion { throw FilterError.gpuUnsupported("error diffusion is serial") }
            gpu = true
        case .auto: gpu = method != .diffusion && AlgoGPU.isAvailable && gray.count >= 1 << 14
        }
        if !gpu || gray.isEmpty { toBitmap(&gray, w: w, method: method); return }
        let g = try AlgoGPU.shared()
        let dev = g.device
        var p = BitmapParams(width: UInt32(max(w, 1)), count: UInt32(gray.count), method: 0, shape: 0, cell: 0, sin: 0, cos: 0, pad0: 0)
        var table: [Float] = [0]
        switch method {
        case .threshold: p.method = 0
        case .pattern: p.method = 1
        case .diffusion: return
        case .halftone(let cell, let angle, let shape):
            p.method = 3
            p.cell = Float.maximum(cell, 2)
            let rad = PCAMath.radians(angle)
            p.sin = sinf(rad); p.cos = cosf(rad)
            p.shape = shape.code
            table = spotTable(shape)
        }
        guard let gb = gray.withUnsafeBytes({ dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let tb = table.withUnsafeBytes({ dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
            throw FilterError.gpuUnavailable("bitmap buffers")
        }
        let pipeline = try g.pipeline("pca_tone_bitmap")
        try g.metal.run(label: "Bitmap") { cb in
            guard let enc = cb.makeComputeCommandEncoder() else { throw FilterError.gpuUnavailable("encoder") }
            enc.setComputePipelineState(pipeline)
            enc.setBytes(&p, length: MemoryLayout<BitmapParams>.stride, index: 0)
            enc.setBuffer(gb, offset: 0, index: 1)
            enc.setBuffer(tb, offset: 0, index: 2)
            enc.dispatchThreads(MTLSize(width: gray.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            enc.endEncoding()
        }
        gray.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: gb.contents(), count: $0.count)) }
    }

    /// MSL `pca_tone_quantize_params`.
    struct QuantizeParams: BitwiseCopyable {
        var width: UInt32
        var count: UInt32
        var dither: UInt32        // 0 none, 2 pattern, 3 noise
        var transparent: Int32    // −1: none
        var spread: Float
        var palCount: UInt32
        var pad0: UInt32 = 0
        var pad1: UInt32 = 0
    }

    /// MSL `pca_tone_bitmap_params`.
    struct BitmapParams: BitwiseCopyable {
        var width: UInt32
        var count: UInt32
        var method: UInt32        // 0 threshold, 1 pattern, 3 halftone
        var shape: UInt32
        var cell: Float
        var sin: Float
        var cos: Float
        var pad0: Float
    }
}
