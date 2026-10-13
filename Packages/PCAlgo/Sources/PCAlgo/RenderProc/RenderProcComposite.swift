// Port of photocraft-algo (crates/algo/src/render2.rs: `lerp4`, `raster_tile`, `CTILE`, `composite`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Rasterises primitives over a surface tile by tile, in straight sRGB converted to and from the
// surface's own colour model and depth, mixed by the selection. The rasterisation (`raster_tile`:
// every pixel blends the primitives covering it, in list order, into a premultiplied buffer) runs
// on the CPU or in Metal (MSL `pca_rp_raster`), with identical results; the mix with the surface
// (colour conversion, selection, depth) is shared CPU code.

import Foundation
import Metal
import PCFoundation

extension RenderProc {
    /// Size of the tiles `composite` works in (photocraft `CTILE`).
    static let ctile: Int32 = 128

    /// Draws `prims` over `surface` inside `clip`, mixed by the selection coverage (channel 0 of
    /// `selection`); returns the bounds of what was drawn (photocraft `composite`). `.auto` runs the
    /// rasterisation on the GPU when Metal is available.
    @discardableResult
    public static func composite(_ surface: inout Surface, _ prims: [Prim], clip: PixelRect, selection: Surface? = nil,
                                 on backend: Backend = .auto) throws -> PixelRect {
        var used = PixelRect.empty
        let bounds = prims.map { $0.bounds.intersect(clip) }
        for b in bounds where !b.isEmpty { used = used.isEmpty ? b : used.union(b) }
        if used.isEmpty { return used }
        // Bin primitives into tiles (order preserved within a tile).
        let ct = ctile
        let tx0 = RenderProcKit.divEuclid(used.x0, ct), ty0 = RenderProcKit.divEuclid(used.y0, ct)
        let tx1 = RenderProcKit.divEuclid(used.x1 - 1, ct), ty1 = RenderProcKit.divEuclid(used.y1 - 1, ct)
        let nx = Int(tx1 - tx0 + 1), ny = Int(ty1 - ty0 + 1)
        var bins = [[UInt32]](repeating: [], count: nx * ny)
        for (k, b) in bounds.enumerated() where !b.isEmpty {
            for ty in RenderProcKit.divEuclid(b.y0, ct)...RenderProcKit.divEuclid(b.y1 - 1, ct) {
                for tx in RenderProcKit.divEuclid(b.x0, ct)...RenderProcKit.divEuclid(b.x1 - 1, ct) {
                    bins[Int(ty - ty0) * nx + Int(tx - tx0)].append(UInt32(k))
                }
            }
        }
        var jobs: [(PixelRect, Int)] = []
        for (i, b) in bins.enumerated() where !b.isEmpty {
            let tx = tx0 + Int32(i % nx), ty = ty0 + Int32(i / nx)
            let r = PixelRect(x0: tx * ct, y0: ty * ct, x1: (tx + 1) * ct, y1: (ty + 1) * ct).intersect(clip)
            if !r.isEmpty { jobs.append((r, i)) }
        }
        let useGPU: Bool
        switch backend {
        case .cpu: useGPU = false
        case .gpu:
            guard AlgoGPU.isAvailable else { throw FilterError.gpuUnavailable("Metal") }
            useGPU = true
        case .auto: useGPU = AlgoGPU.isAvailable
        }
        let gpuPaint = useGPU ? try RenderProcKit.rasterGPU(prims, used: used, clip: clip) : nil
        let fmt = surface.format
        let ctx = FilterContext(bounds: clip, format: fmt)
        let n = fmt.channels
        let src = surface
        var results = [[Float]](repeating: [], count: jobs.count)
        results.withUnsafeMutableBufferPointer { rb in
            let rs = UnsafeSendable(rb)
            parallelFor(jobs.count) { j in
                let (t, bi) = jobs[j]
                let paint: [SIMD4<Float>]
                if let gp = gpuPaint {
                    paint = gp.tile(t)
                } else {
                    paint = RenderProcKit.rasterTile(prims, bins[bi], t)
                }
                var data = src.readRegion(t)
                let sel = selection.map { $0.readRegion(t) }
                let sn = selection?.channels ?? 1
                RenderProcKit.mix(&data, paint, sel, sn, n, ctx)
                rs.value[j] = data
            }
        }
        for (j, (t, _)) in jobs.enumerated() { surface.writeRegion(t, results[j]) }
        return used
    }
}

extension RenderProcKit {
    @inline(__always)
    static func lerp4(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        SIMD4(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, a.w + (b.w - a.w) * t)
    }

    /// Blends one primitive's contribution at coverage `cov` / colour position `ct` into `d`
    /// (photocraft `raster_tile`'s inner step).
    @inline(__always)
    static func blend(_ d: inout SIMD4<Float>, _ p: RenderProc.Prim, _ same: Bool, _ cov: Float, _ ct: Float) {
        if cov <= 0 { return }
        let c = same ? p.c0 : lerp4(p.c0, p.c1, ct)
        let a = clampf(c.w * cov, 0, 1)
        if a <= 0 { return }
        switch p.blend {
        case .add:
            d.x += c.x * a; d.y += c.y * a; d.z += c.z * a
            d.w += a * (1 - d.w)
        case .lighten:
            d.x = Float.maximum(d.x, c.x * a); d.y = Float.maximum(d.y, c.y * a); d.z = Float.maximum(d.z, c.z * a)
            d.w = Float.maximum(d.w, a)
        case .normal:
            let k = 1 - a
            d.x = c.x * a + d.x * k; d.y = c.y * a + d.y * k; d.z = c.z * a + d.z * k
            d.w = a + d.w * k
        }
    }

    /// Rasterises `prims[idx]` (in order) into a premultiplied RGBA buffer covering `t`
    /// (photocraft `raster_tile`).
    static func rasterTile(_ prims: [RenderProc.Prim], _ idx: [UInt32], _ t: PixelRect) -> [SIMD4<Float>] {
        let w = t.width
        var buf = [SIMD4<Float>](repeating: .zero, count: w * t.height)
        for k in idx {
            let p = prims[Int(k)]
            let r = p.bounds.intersect(t)
            if r.isEmpty { continue }
            let sc = p.sinCos
            let same = p.c0 == p.c1
            for y in r.y0..<r.y1 {
                let row = Int(y - t.y0) * w
                for x in r.x0..<r.x1 {
                    let (cov, ct) = p.eval(Float(x) + 0.5, Float(y) + 0.5, sc)
                    blend(&buf[row + Int(x - t.x0)], p, same, cov, ct)
                }
            }
        }
        return buf
    }

    /// photocraft `composite`'s per-pixel mix of the paint (premultiplied) over the surface
    /// samples `data` (`n` channels), through straight sRGB, by the selection coverage.
    static func mix(_ data: inout [Float], _ paint: [SIMD4<Float>], _ sel: [Float]?, _ sn: Int, _ n: Int, _ ctx: FilterContext) {
        let alpha = ctx.alpha
        data.withUnsafeMutableBufferPointer { db in
            for (i, s) in paint.enumerated() {
                let k: Float = sel.map { clampf($0[i * sn], 0, 1) } ?? 1
                let sa = clampf(s.w, 0, 1) * k
                if sa <= 0 { continue }
                let inv = 1 / Float.maximum(s.w, 1e-6)
                let sc = SIMD3(clampf(s.x * inv, 0, 1), clampf(s.y * inv, 0, 1), clampf(s.z * inv, 0, 1))
                let px = UnsafeMutableBufferPointer(rebasing: db[(i * n)..<((i + 1) * n)])
                let d = ctx.rgba(UnsafeBufferPointer(px))
                let da: Float = alpha ? d.w : 1
                let oa = sa + da * (1 - sa)
                @inline(__always) func m(_ sv: Float, _ dv: Float) -> Float { oa > 1e-7 ? (sv * sa + dv * da * (1 - sa)) / oa : 0 }
                ctx.setRGBA(px, SIMD4(m(sc.x, d.x), m(sc.y, d.y), m(sc.z, d.z), oa))
            }
        }
    }

    // MARK: Metal

    /// MSL `pca_rp_prim`.
    struct GPUPrim: BitwiseCopyable {
        var kind: Int32      // 0 capsule, 1 ellipse
        var blend: Int32     // 0 normal, 1 add, 2 lighten
        var soft: Float
        var same: Int32      // c0 == c1
        var c0: SIMD4<Float>
        var c1: SIMD4<Float>
        var g0: SIMD4<Float> // capsule (ax, ay, bx, by) / ellipse (cx, cy, rx, ry)
        var g1: SIMD4<Float> // capsule (ra, rb) / ellipse (sin, cos)
        var bx0: Int32, by0: Int32, bx1: Int32, by1: Int32
    }

    /// MSL `pca_rp_params`.
    struct RasterParams: BitwiseCopyable {
        var origin: SIMD2<Int32>   // document origin of the paint buffer
        var size: SIMD2<Int32>
        var binOrigin: SIMD2<Int32>
        var bins: SIMD2<Int32>
        var binSize: Int32
        var pad0: Int32 = 0
        var pad1: Int32 = 0
        var pad2: Int32 = 0
    }

    static let gpuBin: Int32 = 32

    static func gpuPrim(_ p: RenderProc.Prim) -> GPUPrim {
        let b = p.bounds
        let blend: Int32 = switch p.blend { case .normal: 0; case .add: 1; case .lighten: 2 }
        switch p.shape {
        case .capsule(let a, let bb, let ra, let rb):
            return GPUPrim(kind: 0, blend: blend, soft: p.soft, same: p.c0 == p.c1 ? 1 : 0, c0: p.c0, c1: p.c1,
                           g0: SIMD4(a.x, a.y, bb.x, bb.y), g1: SIMD4(ra, rb, 0, 0), bx0: b.x0, by0: b.y0, bx1: b.x1, by1: b.y1)
        case .ellipse(let c, let rx, let ry, _):
            let (s, co) = p.sinCos
            return GPUPrim(kind: 1, blend: blend, soft: p.soft, same: p.c0 == p.c1 ? 1 : 0, c0: p.c0, c1: p.c1,
                           g0: SIMD4(c.x, c.y, rx, ry), g1: SIMD4(s, co, 0, 0), bx0: b.x0, by0: b.y0, bx1: b.x1, by1: b.y1)
        }
    }

    /// The GPU's paint: premultiplied RGBA of every non-empty 32 px bin (others are 0).
    struct GPUPaint {
        var used: PixelRect
        var bx0: Int32, by0: Int32, nbx: Int, nby: Int
        /// Slot of each bin in `paint` (−1: no primitive touches it).
        var slot: [Int32]
        var paint: [SIMD4<Float>]

        /// The paint covering `t` (0 outside `used` and in empty bins).
        func tile(_ t: PixelRect) -> [SIMD4<Float>] {
            var out = [SIMD4<Float>](repeating: .zero, count: t.area)
            let r = t.intersect(used)
            if r.isEmpty { return out }
            let bs = RenderProcKit.gpuBin
            for y in r.y0..<r.y1 {
                let by = Int(RenderProcKit.divEuclid(y, bs) - by0), ly = Int(y - RenderProcKit.divEuclid(y, bs) * bs)
                for x in r.x0..<r.x1 {
                    let bx = Int(RenderProcKit.divEuclid(x, bs) - bx0)
                    let sl = slot[by * nbx + bx]
                    if sl < 0 { continue }
                    let lx = Int(x - RenderProcKit.divEuclid(x, bs) * bs)
                    out[Int(y - t.y0) * t.width + Int(x - t.x0)] = paint[Int(sl) * Int(bs * bs) + ly * Int(bs) + lx]
                }
            }
            return out
        }
    }

    /// `raster_tile` on the GPU for every non-empty 32 px bin of `used`: each pixel blends the
    /// primitives of its bin — those whose bounds touch the bin, in list order, which are exactly
    /// the primitives `raster_tile` visits for that pixel.
    static func rasterGPU(_ prims: [RenderProc.Prim], used: PixelRect, clip: PixelRect) throws -> GPUPaint {
        let gpu = try AlgoGPU.shared()
        let bs = gpuBin
        let bx0 = divEuclid(used.x0, bs), by0 = divEuclid(used.y0, bs)
        let nbx = Int(divEuclid(used.x1 - 1, bs) - bx0 + 1), nby = Int(divEuclid(used.y1 - 1, bs) - by0 + 1)
        var counts = [UInt32](repeating: 0, count: nbx * nby)
        var clipped: [(Int, PixelRect)] = []
        for (k, p) in prims.enumerated() {
            let b = p.bounds.intersect(used)
            if b.isEmpty { continue }
            clipped.append((k, b))
            for y in divEuclid(b.y0, bs)...divEuclid(b.y1 - 1, bs) {
                for x in divEuclid(b.x0, bs)...divEuclid(b.x1 - 1, bs) { counts[Int(y - by0) * nbx + Int(x - bx0)] += 1 }
            }
        }
        // Active bins, their primitive lists (offsets) and slots.
        var slot = [Int32](repeating: -1, count: nbx * nby)
        var active: [Int32] = []
        var start: [UInt32] = [0]
        for (i, c) in counts.enumerated() where c > 0 {
            slot[i] = Int32(active.count)
            active.append(Int32(i))
            start.append(start.last! + c)
        }
        var fill = [UInt32](repeating: 0, count: active.count)
        for (sl, _) in active.enumerated() { fill[sl] = start[sl] }
        var idx = [UInt32](repeating: 0, count: Int(start.last ?? 0))
        for (k, b) in clipped {
            for y in divEuclid(b.y0, bs)...divEuclid(b.y1 - 1, bs) {
                for x in divEuclid(b.x0, bs)...divEuclid(b.x1 - 1, bs) {
                    let sl = Int(slot[Int(y - by0) * nbx + Int(x - bx0)])
                    idx[Int(fill[sl])] = UInt32(k)
                    fill[sl] += 1
                }
            }
        }
        var out = GPUPaint(used: used, bx0: bx0, by0: by0, nbx: nbx, nby: nby, slot: slot,
                           paint: [SIMD4<Float>](repeating: .zero, count: active.count * Int(bs * bs)))
        if active.isEmpty { return out }
        let gprims = prims.map(gpuPrim)
        // Batches of at most 16 Ki bins (64 MB of paint) per command buffer.
        let batch = 16384
        var first = 0
        while first < active.count {
            let n = min(batch, active.count - first)
            let bytes = n * Int(bs * bs) * 16
            let buf = try gpu.stagingBuffer(length: bytes)
            defer { gpu.returnStaging(buf) }
            try gpu.metal.run(label: "RenderProc raster") { cb in
                let pass = try GPUPass.synthetic(gpu, cb, rect: used)
                let p = RasterParams(origin: SIMD2(used.x0, used.y0), size: SIMD2(Int32(used.width), Int32(used.height)),
                                     binOrigin: SIMD2(bx0, by0), bins: SIMD2(Int32(nbx), Int32(n)), binSize: bs)
                let pb = try pass.buffer(gprims), ab = try pass.buffer(Array(active[first..<(first + n)]))
                let sb = try pass.buffer(Array(start[first...(first + n)])), ib = try pass.buffer(idx)
                try pass.dispatch("pca_rp_raster", params: p, textures: [], buffers: [pb, ab, sb, ib, buf],
                                  width: Int(bs * bs), height: n, threadgroup: (256, 1))
            }
            out.paint.withUnsafeMutableBytes { d in
                (d.baseAddress! + first * Int(bs * bs) * 16).copyMemory(from: buf.contents(), byteCount: bytes)
            }
            first += n
        }
        return out
    }
}
