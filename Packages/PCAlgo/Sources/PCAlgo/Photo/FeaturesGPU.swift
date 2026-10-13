// Port of photocraft-algo (crates/algo/src/features.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Metal path of the Harris response (Shaders/PhotoFeatures.metal): Sobel products, the four
// running-sum box passes (one thread per line, bit-identical to the CPU's), the response, its
// peak and the candidate maxima. The candidates come back unordered; `Features.harris` sorts them
// by (score, y, x), a total order, so the corners are identical to the CPU's.

import Foundation
import Metal
import PCFoundation

enum FeaturesGPU {
    /// The Harris candidates `(x, y, response)` inside the margin `m` (unordered).
    static func candidates(_ w: Int, _ h: Int, _ img: [Float], _ m: Int) throws -> [(Int, Int, Float)] {
        try PyramidGPU.checkSize(w, h, 3, "Features.harris")
        let gpu = try AlgoGPU.shared()
        let n = w * h
        let src = try PhotoKit.sharedBuffer(gpu, img)
        let a = try PhotoKit.privateBuffer(gpu, count: n * 3), b = try PhotoKit.privateBuffer(gpu, count: n * 3)
        let r = try PhotoKit.privateBuffer(gpu, count: n)
        let cw = max(w - 2 * m, 0), chh = max(h - 2 * m, 0)
        guard let peak = gpu.device.makeBuffer(length: 16, options: .storageModeShared),
              let count = gpu.device.makeBuffer(length: 16, options: .storageModeShared),
              let list = gpu.device.makeBuffer(length: max(cw * chh * 12, 16), options: .storageModeShared) else {
            throw FilterError.gpuUnavailable("Features.harris buffers")
        }
        memset(peak.contents(), 0, 16)
        memset(count.contents(), 0, 16)
        try gpu.metal.run(label: "Features.harris") { cb in
            let e = try PyramidGPU.Encoder(gpu, cb, w, h)
            typealias D = PyramidGPU.Dims
            try e.run("pca_pho_sobel", D(dw: Int32(w), dh: Int32(h)), [src, a], w, h)
            // blur(blur(·, 1), 1): rows, columns, rows, columns.
            let rows = D(dw: Int32(w), dh: Int32(h), ch: 3, mode: 1, flags: 0), cols = D(dw: Int32(w), dh: Int32(h), ch: 3, mode: 1, flags: 1)
            try e.pass.dispatch("pca_pho_box_line", params: rows, textures: [], buffers: [a, b], width: h, height: 1, threadgroup: (64, 1))
            try e.pass.dispatch("pca_pho_box_line", params: cols, textures: [], buffers: [b, a], width: w, height: 1, threadgroup: (64, 1))
            try e.pass.dispatch("pca_pho_box_line", params: rows, textures: [], buffers: [a, b], width: h, height: 1, threadgroup: (64, 1))
            try e.pass.dispatch("pca_pho_box_line", params: cols, textures: [], buffers: [b, a], width: w, height: 1, threadgroup: (64, 1))
            try e.run("pca_pho_harris_response", D(dw: Int32(w), dh: Int32(h)), [a, r, peak], w, h)
            try e.run("pca_pho_harris_candidates", D(dw: Int32(w), dh: Int32(h), mode: UInt32(m)), [r, peak, count, list], cw, chh)
        }
        let k = Int(count.contents().load(as: UInt32.self))
        let l = list.contents().assumingMemoryBound(to: UInt32.self)
        return (0..<k).map { (Int(l[$0 * 3]), Int(l[$0 * 3 + 1]), Float(bitPattern: l[$0 * 3 + 2])) }
    }
}
