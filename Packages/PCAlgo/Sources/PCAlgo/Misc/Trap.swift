// Port of photocraft-algo (crates/algo/src/trap.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Image › Trap (prepress): every ink (channels 0…3 of a CMYK buffer) is spread by `width` px
// (square grayscale dilation, windows clipped at the buffer edge, floor 0) but only under pixels
// that already carry ink, so internal colour edges gain a trap band and paper stays paper. Alpha
// and spare channels are untouched. photocraft's prefix/suffix block maxima give the same values as
// the direct clipped fold this reference and the Metal kernels compute.

import Metal
import PCFoundation

public enum Trap {
    /// Direct clipped-window maximum from 0 (photocraft's left-to-right `f32::max` fold).
    @inline(__always)
    static func foldMax(_ lo: Int, _ hi: Int, _ get: (Int) -> Float) -> Float {
        var m: Float = 0
        var i = lo
        while i <= hi { m = Float.maximum(m, get(i)); i += 1 }
        return m
    }

    /// Traps an interleaved CMYK(+alpha) buffer of `w × h × ch` in place (photocraft `trap`).
    public static func trap(_ px: inout [Float], width w: Int, height h: Int, channels ch: Int, trapWidth r: Int, on backend: Backend = .auto) throws {
        if r == 0 || w == 0 || h == 0 || ch < 4 || w * h * ch != px.count { return }
        if backend != .cpu, let gpu = try? AlgoGPU.shared() { try trapGPU(gpu, &px, w, h, ch, r); return }
        if backend == .gpu { throw FilterError.gpuUnavailable("Trap") }
        let inks = 4
        var dil = [[Float]](repeating: [], count: inks)
        let src = px
        for c in 0..<inks {
            var tmp = [Float](repeating: 0, count: w * h)
            tmp.withUnsafeMutableBufferPointer { tb in
                let ts = UnsafeSendable(tb)
                parallelChunks(h, minChunk: 8) { rows in
                    for y in rows { for x in 0..<w { ts.value[y * w + x] = foldMax(max(x - r, 0), min(x + r, w - 1)) { src[(y * w + $0) * ch + c] } } }
                }
            }
            var out = [Float](repeating: 0, count: w * h)
            out.withUnsafeMutableBufferPointer { ob in
                let os = UnsafeSendable(ob)
                parallelChunks(h, minChunk: 8) { rows in
                    for y in rows { for x in 0..<w { os.value[y * w + x] = foldMax(max(y - r, 0), min(y + r, h - 1)) { tmp[$0 * w + x] } } }
                }
            }
            dil[c] = out
        }
        for i in 0..<(w * h) {
            let b = i * ch
            if !(0..<inks).contains(where: { px[b + $0] > 1e-4 }) { continue }
            for c in 0..<inks { px[b + c] = Float.maximum(px[b + c], dil[c][i]) }
        }
    }

    struct Params: BitwiseCopyable { var width: Int32; var height: Int32; var radius: Int32; var channels: Int32 }

    static func trapGPU(_ gpu: AlgoGPU, _ px: inout [Float], _ w: Int, _ h: Int, _ ch: Int, _ r: Int) throws {
        let bytes = px.count * 4
        let buf = try gpu.stagingBuffer(length: bytes), tmp = try gpu.stagingBuffer(length: w * h * 16), dil = try gpu.stagingBuffer(length: w * h * 16)
        defer { gpu.returnStaging(buf); gpu.returnStaging(tmp); gpu.returnStaging(dil) }
        px.withUnsafeBytes { buf.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        let p = Params(width: Int32(w), height: Int32(h), radius: Int32(min(r, max(w, h))), channels: Int32(ch))
        try gpu.metal.run(label: "Trap") { cb in
            let pass = try GPUPass.synthetic(gpu, cb, rect: PixelRect(x: 0, y: 0, width: w, height: h))
            try pass.dispatch("pca_misc_trap_h", params: p, textures: [], buffers: [buf, tmp], width: w, height: h)
            try pass.dispatch("pca_misc_trap_v", params: p, textures: [], buffers: [tmp, dil], width: w, height: h)
            try pass.dispatch("pca_misc_trap_apply", params: p, textures: [], buffers: [buf, dil], width: w, height: h)
        }
        px.withUnsafeMutableBytes { $0.baseAddress!.copyMemory(from: buf.contents(), byteCount: bytes) }
    }
}
