// Port of photocraft-algo (crates/algo/src/stylize2.rs `extrude`/`extrude_direct`, stylize2/extrude.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Stylize › Extrude. The reference semantics are photocraft's per-pixel candidate search
// (`extrude_direct`; its swept rasteriser `extrude::blocks` reproduces it bit for bit): every
// pixel takes the highest block whose swept square covers it, ties going to the first block in
// row-major cell order. Cell colours/heights are computed once per cell, and each pixel only
// visits the cells whose sweep can reach it — a superset derived from the largest possible
// front-face offset, filtered by photocraft's exact interval test, so the result is unchanged.

import Foundation
import PCFoundation

/// Extrude geometry (photocraft `ExtrudeType`).
public enum ExtrudeType: String, Codable, Sendable, Hashable, CaseIterable {
    case blocks, pyramids
}

/// Filter › Stylize › Extrude: the bounds cut into square cells of `size` px (2–255). Blocks are
/// pushed toward the viewer (front faces shift away from the bounds' centre with shaded sides);
/// Pyramids raise four shaded faces. Heights are random or follow the cell's brightness
/// (`levelBased`); `depth` 1–255.
public struct Extrude: Filter, Hashable {
    public var kind: ExtrudeType
    public var size: Float
    public var depth: Float
    public var levelBased: Bool
    public var solidFront: Bool
    public var maskIncomplete: Bool
    public var seed: UInt32
    public init(kind: ExtrudeType = .blocks, size: Float = 30, depth: Float = 30, levelBased: Bool = false,
                solidFront: Bool = false, maskIncomplete: Bool = false, seed: UInt32 = 0) {
        self.kind = kind; self.size = size; self.depth = depth; self.levelBased = levelBased
        self.solidFront = solidFront; self.maskIncomplete = maskIncomplete; self.seed = seed
    }
    public var label: String { "Extrude" }

    /// Max on-screen displacement of a block's front face, px (photocraft `extrude_reach`).
    static func reach(_ depth: Float) -> Float { clampf(depth, 0, 255) * 0.25 }

    /// photocraft `r(extrude_reach(depth) + size.clamp(2, 255) * 3 + 1)`.
    public func halo(bounds: PixelRect) -> Halo {
        StylizeKit.reach(Self.reach(depth) + clampf(size, 2, 255) * 3 + 1)
    }
    /// Random heights are channel-independent; level-based heights need the cell's luma.
    public var gpuChannels: GPUChannels { levelBased ? .joint : .perChannel }
    public func supportsGPU(_ ctx: FilterContext, channels: Int) -> Bool {
        !levelBased || StylizeKit.supportsFxLuma(ctx, channels: channels)
    }

    /// Everything the per-pixel searches share.
    struct Geo {
        var cs: Int32
        var b: PixelRect
        var bcx: Float, bcy: Float
        var halfDiag: Float
        var reach: Float
        var k: Int32
        var half: Float
        /// Valid cell indices: 0…maxCX, 0…maxCY.
        var maxCX: Int32, maxCY: Int32
        /// Cells stored in the info tables (`c0` … `c0 + nc − 1`).
        var c0x: Int32, c0y: Int32, ncx: Int, ncy: Int
        var empty: Bool
    }

    func geo(_ out: PixelRect, _ b: PixelRect) -> Geo {
        let cs = StylizeKit.i32(clampf(size, 2, 255).rounded(.toNearestOrAwayFromZero))
        let reach = Self.reach(depth)
        let k = StylizeKit.i32((reach / Float(cs)).rounded(.up)) + 1
        let area = out.intersect(b)
        var g = Geo(cs: cs, b: b, bcx: Float(b.x0 &+ b.x1) / 2, bcy: Float(b.y0 &+ b.y1) / 2,
                    halfDiag: StylizeKit.fmax(hypotf(Float(b.width), Float(b.height)) / 2, 1), reach: reach, k: k,
                    half: Float(cs) / 2, maxCX: (Int32(b.width) - 1) / cs, maxCY: (Int32(b.height) - 1) / cs,
                    c0x: 0, c0y: 0, ncx: 0, ncy: 0, empty: area.isEmpty)
        if area.isEmpty { return g }
        let gx0 = StylizeKit.divEuclid(area.x0 - b.x0, cs), gy0 = StylizeKit.divEuclid(area.y0 - b.y0, cs)
        let gx1 = StylizeKit.divEuclid(area.x1 - 1 - b.x0, cs), gy1 = StylizeKit.divEuclid(area.y1 - 1 - b.y0, cs)
        let kk = kind == .blocks ? k : 0
        let cx0 = max(gx0 - kk, 0), cy0 = max(gy0 - kk, 0)
        let cx1 = min(gx1 + kk, g.maxCX), cy1 = min(gy1 + kk, g.maxCY)
        g.c0x = cx0; g.c0y = cy0
        g.ncx = max(Int(cx1) - Int(cx0) + 1, 0); g.ncy = max(Int(cy1) - Int(cy0) + 1, 0)
        return g
    }

    /// Cell colour (straight, `n` channels) and height (photocraft's `cell_info` closure).
    static func cellInfo(_ s: StyView, _ ctx: FilterContext, _ g: Geo, _ gx: Int32, _ gy: Int32, _ levelBased: Bool, _ seed: UInt32,
                         _ acc: UnsafeMutableBufferPointer<Float>) -> Float {
        let n = s.n, b = g.b, cs = g.cs, alpha = ctx.alpha
        let r = PixelRect(x0: b.x0 + gx * cs, y0: b.y0 + gy * cs, x1: b.x0 + (gx + 1) * cs, y1: b.y0 + (gy + 1) * cs).intersect(b)
        for c in 0..<n { acc[c] = 0 }
        var cnt: Float = 0
        // Sparse sampling keeps big cells cheap; the average only colours faces.
        let step = max(cs / 8, 1)
        var yy = r.y0
        while yy < r.y1 {
            var xx = r.x0
            while xx < r.x1 {
                let a: Float = alpha ? s.get(xx, yy, n - 1) : 1
                for c in 0..<n {
                    let v = s.get(xx, yy, c)
                    acc[c] += alpha && c < n - 1 ? v * a : v
                }
                cnt += 1
                xx += step
            }
            yy += step
        }
        if cnt > 0 { for c in 0..<n { acc[c] /= cnt } }
        if alpha {
            let a = acc[n - 1]
            for c in 0..<(n - 1) { acc[c] = a > 1e-7 ? acc[c] / a : 0 }
        }
        return levelBased ? clampf(ctx.luma(UnsafeBufferPointer(acc)), 0, 1) : hash01(gx, gy, 21, seed)
    }

    /// photocraft `interval`: the sweep parameters t ∈ [0, 1] putting `p` inside the square.
    @inline(__always)
    static func interval(_ p: Float, _ m: Float, _ o: Float, _ half: Float) -> (Float, Float)? {
        if abs(o) < 1e-6 { return abs(p - m) <= half ? (0, 1) : nil }
        let a = (p - m - half) / o, bb = (p - m + half) / o
        let lo = StylizeKit.fmax(StylizeKit.fmin(a, bb), 0), hi = StylizeKit.fmin(StylizeKit.fmax(a, bb), 1)
        return lo <= hi ? (lo, hi) : nil
    }

    /// Cell indices along one axis whose sweep can reach pixel centre `p` (a superset: bounds
    /// from the largest offset `offMax`, 2 px and one cell of slack), clipped to `lo…hi`.
    @inline(__always)
    static func candidates(_ p: Float, _ origin: Int32, _ center: Float, _ g: Geo, _ offMax: Float, _ lo: Int32, _ hi: Int32) -> (Int32, Int32) {
        let eps: Float = 2
        let a = p + g.half + eps                                      // mx ≤ a when the face moves toward +
        let c = p - g.half - eps                                      // mx ≥ c when it moves toward −
        let bnd = center + (p - g.half - eps - center) / (1 + offMax)  // mx ≥ bnd (moving +)
        let dnd = center + (p + g.half + eps - center) / (1 + offMax)  // mx ≤ dnd (moving −)
        let mlo = min(bnd, c), mhi = max(a, dnd)
        let o = Float(origin) + g.half, cs = Float(g.cs)
        let l = StylizeKit.i32(((mlo - o) / cs).rounded(.down)) &- 1
        let h = StylizeKit.i32(((mhi - o) / cs).rounded(.up)) &+ 1
        return (max(l, lo), min(h, hi))
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        var res = src.crop(out)
        if out.isEmpty || n == 0 { return res }
        let b = ctx.bounds
        let g = geo(out, b)
        if g.empty || g.ncx == 0 || g.ncy == 0 { return res }
        let cs = g.cs, sub = ctx.subtractive, cc = ctx.colorChannels(n), alpha = ctx.alpha
        let levelBased = self.levelBased, seed = self.seed, kind = self.kind, solid = solidFront, mask = maskIncomplete
        let depthC = clampf(depth, 1, 255)
        // Per-cell colour and height, computed once.
        var cols = [Float](repeating: 0, count: g.ncx * g.ncy * n)
        var hs = [Float](repeating: 0, count: g.ncx * g.ncy)
        src.data.withUnsafeBufferPointer { sb in
            let s = StyView(sb, src)
            cols.withUnsafeMutableBufferPointer { cb in
                hs.withUnsafeMutableBufferPointer { hb in
                    let cbs = UnsafeSendable(cb), hbs = UnsafeSendable(hb)
                    parallelFor(g.ncy) { j in
                        for i in 0..<g.ncx {
                            let idx = j * g.ncx + i
                            let acc = UnsafeMutableBufferPointer(rebasing: cbs.value[(idx * n)..<((idx + 1) * n)])
                            hbs.value[idx] = Self.cellInfo(s, ctx, g, g.c0x + Int32(i), g.c0y + Int32(j), levelBased, seed, acc)
                        }
                    }
                }
            }
        }
        // Non-finite heights (NaN luma) hit every pixel in photocraft's search: no pruning then.
        let prune = hs.allSatisfy { $0.isFinite }
        let offMax = g.reach / g.halfDiag
        let ow = out.width
        src.data.withUnsafeBufferPointer { sb in
            let s = StyView(sb, src)
            cols.withUnsafeBufferPointer { colb in
                hs.withUnsafeBufferPointer { hb in
                    res.withStyOut { d in
                        @inline(__always) func shade(_ o: Int, _ ci: Int, _ k: Float) {
                            for c in 0..<cc {
                                let col = colb[ci * n + c]
                                d.value[o + c] = clampf(sub ? 1 - (1 - col) * k : col * k, 0, 1)
                            }
                            if alpha { d.value[o + n - 1] = colb[ci * n + n - 1] }
                        }
                        @inline(__always) func incomplete(_ cx: Int32, _ cy: Int32) -> Bool {
                            let r = PixelRect(x0: b.x0 + cx * cs, y0: b.y0 + cy * cs, x1: b.x0 + (cx + 1) * cs, y1: b.y0 + (cy + 1) * cs)
                            return r.intersect(b) != r
                        }
                        parallelFor(out.height) { row in
                            let y = out.y0 + Int32(row)
                            for i in 0..<ow {
                                let x = out.x0 + Int32(i)
                                if !b.contains(x: x, y: y) { continue }
                                let o = (row * ow + i) * n
                                let fx = Float(x) + 0.5, fy = Float(y) + 0.5
                                let gx = StylizeKit.divEuclid(x - b.x0, cs), gy = StylizeKit.divEuclid(y - b.y0, cs)
                                switch kind {
                                case .pyramids:
                                    if mask && incomplete(gx, gy) { continue }
                                    let ci = Int(gy - g.c0y) * g.ncx + Int(gx - g.c0x)
                                    let h = hb[ci]
                                    let rx0 = b.x0 + gx * cs, ry0 = b.y0 + gy * cs
                                    let u = fx - (Float(rx0) + Float(cs) / 2), v = fy - (Float(ry0) + Float(cs) / 2)
                                    // Face normals of a pyramid of height H over a cell of half-size s; light from the top-left.
                                    let hgt = h * depthC / 255 * Float(cs)
                                    let sh = Float(cs) / 2
                                    let (nx, ny): (Float, Float) = abs(u) >= abs(v) ? (StylizeKit.signum(u) * hgt, 0) : (0, StylizeKit.signum(v) * hgt)
                                    let norm = (nx * nx + ny * ny + sh * sh).squareRoot()
                                    let (lx, ly, lz): (Float, Float, Float) = (-0.5, -0.5, 0.70710677)
                                    let lambert = StylizeKit.fmax((nx * lx + ny * ly + sh * lz) / norm, 0)
                                    shade(o, ci, 0.35 + 0.9 * lambert)
                                case .blocks:
                                    var (cxl, cxh) = (max(gx - g.k, g.c0x), min(gx + g.k, g.c0x + Int32(g.ncx) - 1))
                                    var (cyl, cyh) = (max(gy - g.k, g.c0y), min(gy + g.k, g.c0y + Int32(g.ncy) - 1))
                                    if prune {
                                        (cxl, cxh) = Self.candidates(fx, b.x0, g.bcx, g, offMax, cxl, cxh)
                                        (cyl, cyh) = Self.candidates(fy, b.y0, g.bcy, g, offMax, cyl, cyh)
                                    }
                                    if cxl > cxh || cyl > cyh { continue }
                                    var best: (h: Float, ci: Int, cx: Int32, cy: Int32, face: Int)?
                                    for cy in cyl...cyh {
                                        for cx in cxl...cxh {
                                            if mask && incomplete(cx, cy) { continue }
                                            let ci = Int(cy - g.c0y) * g.ncx + Int(cx - g.c0x)
                                            let h = hb[ci]
                                            if let bb = best, bb.h >= h { continue }
                                            // Front face offset grows with height and distance from the centre.
                                            let mx = Float(b.x0 + cx * cs) + Float(cs) / 2, my = Float(b.y0 + cy * cs) + Float(cs) / 2
                                            let off = g.reach * h / g.halfDiag
                                            let ox = (mx - g.bcx) * off, oy = (my - g.bcy) * off
                                            guard let ix = Self.interval(fx, mx, ox, g.half), let iy = Self.interval(fy, my, oy, g.half) else { continue }
                                            let lo = max(ix.0, iy.0), hi = min(ix.1, iy.1)
                                            if lo > hi { continue }
                                            let face: Int
                                            if hi >= 1 { face = 0 } else if ix.1 < iy.1 { face = ox > 0 ? 1 : 2 } else if oy > 0 { face = 3 } else { face = 4 }
                                            best = (h, ci, cx, cy, face)
                                        }
                                    }
                                    guard let bb = best else { continue }
                                    if bb.face == 0 {
                                        if solid {
                                            shade(o, bb.ci, 1)
                                        } else {
                                            // Image texture shifted with the face.
                                            let rx0 = b.x0 + bb.cx * cs, ry0 = b.y0 + bb.cy * cs
                                            let mx = Float(rx0) + Float(cs) / 2, my = Float(ry0) + Float(cs) / 2
                                            let off = g.reach * bb.h / g.halfDiag
                                            let sx = StylizeKit.i32((fx - (mx - g.bcx) * off).rounded(.down))
                                            let sy = StylizeKit.i32((fy - (my - g.bcy) * off).rounded(.down))
                                            s.read(min(max(sx, rx0), rx0 + cs - 1), min(max(sy, ry0), ry0 + cs - 1), d.value + o)
                                        }
                                    } else {
                                        // Light from the top-left: the left/top sides are lit.
                                        let k: Float = switch bb.face { case 1: 0.85; case 2: 0.55; case 3: 0.95; default: 0.45 }
                                        shade(o, bb.ci, k)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let b = pass.ctx.bounds
        let g = geo(pass.out, b)
        if g.empty || g.ncx == 0 || g.ncy == 0 {
            try pass.dispatchOut("pca_copy", params: NoParams())
            return
        }
        let p = ExtrudeParams(bOrigin: SIMD2(b.x0, b.y0), bSize: SIMD2(Int32(b.width), Int32(b.height)),
                              c0: SIMD2(g.c0x, g.c0y), ncell: SIMD2(Int32(g.ncx), Int32(g.ncy)),
                              bc: SIMD2(g.bcx, g.bcy), cs: g.cs, k: g.k,
                              halfDiag: g.halfDiag, reach: g.reach, depth: clampf(depth, 1, 255), seed: seed,
                              levelBased: levelBased ? 1 : 0, solid: solidFront ? 1 : 0, mask: maskIncomplete ? 1 : 0,
                              sub: pass.ctx.subtractive ? 1 : 0, luma: StylizeKit.fxLumaCode(pass.ctx) ?? 1)
        let cols = try pass.texture(width: g.ncx, height: g.ncy)
        let info = try pass.texture(width: g.ncx, height: g.ncy)
        try pass.dispatch("pca_sty_extrude_cells", params: p, textures: [pass.src, cols, info], width: g.ncx, height: g.ncy)
        // Non-finite heights disable the candidate pruning (see `cpu`): one flag, set on the GPU.
        let flag = try pass.buffer([UInt32(1)])
        if kind == .blocks {
            try pass.dispatch("pca_sty_extrude_finite", params: p, textures: [info], buffers: [flag], width: g.ncx, height: g.ncy)
        }
        try pass.dispatchOut(kind == .blocks ? "pca_sty_extrude_blocks" : "pca_sty_extrude_pyramids", params: p,
                             textures: [pass.src, cols, info, pass.dst], buffers: [flag])
    }
}

/// MSL `pca_sty_extrude_params`.
private struct ExtrudeParams: BitwiseCopyable {
    var bOrigin: SIMD2<Int32>
    var bSize: SIMD2<Int32>
    var c0: SIMD2<Int32>
    var ncell: SIMD2<Int32>
    var bc: SIMD2<Float>
    var cs: Int32
    var k: Int32
    var halfDiag: Float
    var reach: Float
    var depth: Float
    var seed: UInt32
    var levelBased: Int32
    var solid: Int32
    var mask: Int32
    var sub: Int32
    var luma: Int32
    var pad0: Int32 = 0
    var pad1: Int32 = 0
    var pad2: Int32 = 0
}
