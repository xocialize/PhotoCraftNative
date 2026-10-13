// Port of photocraft-algo (crates/algo/src/selection.rs, selection_blur.rs, selection/distance.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Metal paths of the selection algorithms. Masks are plain arrays, not images, so these
// kernels work on shared buffers (binding: buffer(0) the params struct, buffer(1…) data) rather
// than through GPUPass/FilterEngine. Kernels: Shaders/Selection.metal (wand, ranges,
// anti-aliasing), SelectionBlur.metal (smooth, feather), SelectionDistance.metal (EDT).

import Foundation
import Metal
import PCFoundation

extension SelectionKit { enum GPU {
    /// Encodes kernels into one command buffer.
    final class Encoder {
        let gpu: AlgoGPU
        let cb: any MTLCommandBuffer
        init(gpu: AlgoGPU, cb: any MTLCommandBuffer) { self.gpu = gpu; self.cb = cb }

        /// Dispatches `kernel` over `w × h` threads.
        func dispatch<P: BitwiseCopyable>(_ kernel: String, _ params: P, _ buffers: [any MTLBuffer], _ w: Int, _ h: Int = 1) throws {
            if w <= 0 || h <= 0 { return }
            let p = try gpu.pipeline(kernel)
            guard let enc = cb.makeComputeCommandEncoder() else { throw FilterError.gpuUnavailable("encoder") }
            enc.label = kernel
            enc.setComputePipelineState(p)
            withUnsafeBytes(of: params) { b in enc.setBytes(b.baseAddress!, length: b.count, index: 0) }
            for (i, b) in buffers.enumerated() { enc.setBuffer(b, offset: 0, index: 1 + i) }
            var tw = h == 1 ? 64 : 16, th = h == 1 ? 1 : 16
            while tw * th > p.maxTotalThreadsPerThreadgroup { if th > 1 { th /= 2 } else { tw /= 2 } }
            enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
            enc.endEncoding()
        }
    }

    static func gpu() throws -> AlgoGPU { try AlgoGPU.shared() }

    /// A shared buffer holding `values`.
    static func buffer<T: BitwiseCopyable>(_ values: [T]) throws -> any MTLBuffer {
        let g = try gpu()
        let len = max(MemoryLayout<T>.stride * values.count, 16)
        let b: (any MTLBuffer)? = values.isEmpty ? g.device.makeBuffer(length: len, options: .storageModeShared)
            : values.withUnsafeBytes { g.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        guard let b else { throw FilterError.gpuUnavailable("makeBuffer \(len)") }
        return b
    }

    /// A zeroed shared buffer of `count` elements of `T`.
    static func zeros<T>(_ count: Int, of: T.Type) throws -> any MTLBuffer {
        let len = max(MemoryLayout<T>.stride * count, 16)
        guard let b = try gpu().device.makeBuffer(length: len, options: .storageModeShared) else { throw FilterError.gpuUnavailable("makeBuffer \(len)") }
        memset(b.contents(), 0, len)
        return b
    }

    static func read<T>(_ b: any MTLBuffer, _ count: Int, as: T.Type) -> [T] {
        let p = b.contents().assumingMemoryBound(to: T.self)
        return Array(UnsafeBufferPointer(start: p, count: count))
    }

    /// Encodes `body` into one command buffer, commits it and waits.
    static func run(_ label: String, _ body: (Encoder) throws -> Void) throws {
        let g = try gpu()
        try g.metal.run(label: label) { cb in try body(Encoder(gpu: g, cb: cb)) }
    }

    // MARK: Magic wand

    struct WandParams: BitwiseCopyable { var target: SIMD4<Float>; var t: Float; var n: UInt32; var seed: UInt32; var contiguous: UInt32 }
    struct GridParams: BitwiseCopyable { var w: UInt32; var h: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }

    /// The magic wand: similarity per pixel, then (contiguous) row and column propagation sweeps
    /// from the seed until nothing changes — the exact 4-connected component, as the CPU's flood
    /// fill — and the 3×3 anti-aliasing.
    static func magicWand(_ px: [SIMD4<Float>], w: Int, h: Int, seed: Int, tolerance: Float, contiguous: Bool, antiAlias: Bool) throws -> [Float] {
        let n = w * h
        let pxb = try buffer(Array(px[0..<n]))
        let sim = try zeros(n, of: UInt8.self), mark = try zeros(n, of: UInt8.self)
        let flag = try zeros(4, of: UInt32.self)
        let mask = try zeros(n, of: Float.self), out = try zeros(n, of: Float.self)
        let grid = GridParams(w: UInt32(w), h: UInt32(h))
        try run("magic wand") { e in
            try e.dispatch("pca_sel_wand_similar", WandParams(target: px[seed], t: tolerance + 1e-3, n: UInt32(n), seed: UInt32(seed),
                                                              contiguous: contiguous ? 1 : 0), [pxb, sim, mark], n)
        }
        if contiguous {
            // Each round sweeps every row both ways, then every column; a few rounds per command
            // buffer, until a whole batch changes nothing.
            while true {
                flag.contents().storeBytes(of: UInt32(0), as: UInt32.self)
                try run("magic wand flood") { e in
                    for _ in 0..<4 {
                        try e.dispatch("pca_sel_flood_rows", grid, [sim, mark, flag], h)
                        try e.dispatch("pca_sel_flood_cols", grid, [sim, mark, flag], w)
                    }
                }
                if flag.contents().load(as: UInt32.self) == 0 { break }
            }
        }
        try run("magic wand mask") { e in
            try e.dispatch("pca_sel_marks_to_mask", grid, [mark, mask], w, h)
            if antiAlias { try e.dispatch("pca_sel_antialias", grid, [mask, out], w, h) }
        }
        return read(antiAlias ? out : mask, n, as: Float.self)
    }

    // MARK: Ranges

    struct RangeParams: BitwiseCopyable { var f: Float; var samples: UInt32; var w: UInt32; var localized: UInt32; var radius: Float; var n: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }

    /// Color Range with samples (`colorRange` is one sample, not localized).
    static func colorRange(_ px: [SIMD4<Float>], samples: [RangeSample], w: Int, f: Float, localized: Float?) throws -> [Float] {
        let n = px.count
        if n == 0 { return [] }
        // Per sample: (r, g, b, has position), (x, y, 0, 0).
        var packed: [SIMD4<Float>] = []
        for s in samples {
            packed.append(SIMD4(s.color, s.at == nil ? 0 : 1))
            packed.append(SIMD4(s.at?.x ?? 0, s.at?.y ?? 0, 0, 0))
        }
        let pxb = try buffer(px), sb = try buffer(packed), out = try zeros(n, of: Float.self)
        let p = RangeParams(f: f, samples: UInt32(samples.count), w: UInt32(w), localized: localized == nil ? 0 : 1, radius: localized ?? 0, n: UInt32(n))
        try run("color range") { e in try e.dispatch("pca_sel_color_range", p, [pxb, sb, out], n) }
        return read(out, n, as: Float.self)
    }

    struct LabParams: BitwiseCopyable {
        var lo: SIMD4<Float>; var hi: SIMD4<Float>
        var fuzziness: Float; var grid8: UInt32; var w: UInt32; var nat: UInt32
        var radius: Float; var n: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0
    }

    static func colorRangeLab(_ lab: [SIMD4<Float>], w: Int, range: LabRange, fuzziness: Float, grid8: Bool,
                              localized: (radius: Float, at: [SIMD2<Float>])?) throws -> [Float] {
        let n = lab.count
        if n == 0 { return [] }
        let at = localized?.at ?? []
        let lb = try buffer(lab), ab = try buffer(at), out = try zeros(n, of: Float.self)
        let p = LabParams(lo: SIMD4(range.lo, 0), hi: SIMD4(range.hi, 0), fuzziness: fuzziness, grid8: grid8 ? 1 : 0, w: UInt32(w),
                          nat: UInt32(at.count), radius: localized?.radius ?? 0, n: UInt32(n))
        try run("color range lab") { e in try e.dispatch("pca_sel_color_range_lab", p, [lb, ab, out], n) }
        return read(out, n, as: Float.self)
    }

    struct HueParams: BitwiseCopyable { var center: Float; var n: UInt32; var pad0: UInt32 = 0; var pad1: UInt32 = 0 }
    struct ToneParams: BitwiseCopyable { var lo: Float; var hi: Float; var ramp: Float; var n: UInt32 }

    static func hueRange(_ px: [SIMD4<Float>], center: Float) throws -> [Float] {
        let n = px.count
        if n == 0 { return [] }
        let pxb = try buffer(px), out = try zeros(n, of: Float.self)
        try run("hue range") { e in try e.dispatch("pca_sel_hue_range", HueParams(center: center, n: UInt32(n)), [pxb, out], n) }
        return read(out, n, as: Float.self)
    }

    static func toneRange(_ px: [SIMD4<Float>], lo: Float, hi: Float, falloff: Float) throws -> [Float] {
        let n = px.count
        if n == 0 { return [] }
        let pxb = try buffer(px), out = try zeros(n, of: Float.self)
        try run("tone range") { e in
            try e.dispatch("pca_sel_tone_range", ToneParams(lo: lo, hi: hi, ramp: Float.maximum(falloff, 1e-3), n: UInt32(n)), [pxb, out], n)
        }
        return read(out, n, as: Float.self)
    }

    // MARK: Blurs

    struct WindowParams: BitwiseCopyable {
        var w: UInt32           // mask row width
        var bx0: UInt32; var by0: UInt32; var bh: UInt32   // the non-zero rows (window columns)
        var wx0: UInt32; var gw: UInt32; var gh: UInt32; var off: UInt32   // window
        var r: UInt32; var taps: UInt32; var segment: UInt32; var pad0: UInt32 = 0
    }

    /// Smooth's box passes over the window (Float running sums); returns the gw × gh averages.
    static func smoothWindow(_ m: [Float], w: Int, b: SelectionKit.Blur.Win, win: SelectionKit.Blur.Win, r: Int) throws -> [Float] {
        let gw = win.w, gh = win.h
        let mb = try buffer(m), tmp = try zeros(gw * b.h, of: Float.self), res = try zeros(gw * gh, of: Float.self)
        let seg = 256
        let p = WindowParams(w: UInt32(w), bx0: UInt32(b.x0), by0: UInt32(b.y0), bh: UInt32(b.h), wx0: UInt32(win.x0), gw: UInt32(gw),
                             gh: UInt32(gh), off: UInt32(b.y0 - win.y0), r: UInt32(r), taps: 0, segment: UInt32(seg))
        try run("smooth") { e in
            try e.dispatch("pca_sel_box_rows", p, [mb, tmp], b.h, (gw + seg - 1) / seg)
            try e.dispatch("pca_sel_box_cols", p, [tmp, res], gw, (gh + seg - 1) / seg)
        }
        return read(res, gw * gh, as: Float.self)
    }

    /// Feather's direct truncated-Gaussian passes over the window; returns the gw × gh result.
    static func featherWindow(_ m: [Float], w: Int, b: SelectionKit.Blur.Win, win: SelectionKit.Blur.Win, taps: ([Float], [Float])) throws -> [Float] {
        let gw = win.w, gh = win.h
        let mb = try buffer(m), th = try buffer(taps.0), tv = try buffer(taps.1)
        let tmp = try zeros(gw * b.h, of: Float.self), res = try zeros(gw * gh, of: Float.self)
        let p = WindowParams(w: UInt32(w), bx0: UInt32(b.x0), by0: UInt32(b.y0), bh: UInt32(b.h), wx0: UInt32(win.x0), gw: UInt32(gw),
                             gh: UInt32(gh), off: UInt32(b.y0 - win.y0), r: UInt32(taps.0.count / 2), taps: UInt32(taps.0.count), segment: 0)
        var pv = p
        pv.r = UInt32(taps.1.count / 2)
        pv.taps = UInt32(taps.1.count)
        try run("feather") { e in
            try e.dispatch("pca_sel_feather_rows", p, [mb, th, tmp], gw, b.h)
            try e.dispatch("pca_sel_feather_cols", pv, [tmp, tv, res], gw, gh)
        }
        return read(res, gw * gh, as: Float.self)
    }

    // MARK: Distance transform

    /// Whether the exact integer envelope fits 64-bit products (dimensions up to 2^17).
    static func edtFits(_ w: Int, _ h: Int) -> Bool { w <= 1 << 17 && h <= 1 << 17 }

    /// The EDT: nearest seeds along columns, then the parabola envelope along rows with exact
    /// rational boundaries and a correctly rounded square root of the integer squared distance.
    static func edt(_ inside: [Bool], w: Int, h: Int) throws -> [Float] {
        let n = w * h
        let ins = try buffer(inside.map { $0 ? UInt8(1) : 0 })
        let vertical = try zeros(n, of: UInt32.self), sites = try zeros(n, of: UInt32.self), out = try zeros(n, of: Float.self)
        let grid = GridParams(w: UInt32(w), h: UInt32(h))
        try run("edt") { e in
            try e.dispatch("pca_sel_edt_cols", grid, [ins, vertical], w)
            try e.dispatch("pca_sel_edt_rows", grid, [vertical, sites, out], h)
        }
        return read(out, n, as: Float.self)
    }
}
}
