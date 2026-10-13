// Port of photocraft-algo (crates/algo/src/pixelate.rs, pixelate/{facet,screen,reference}.rs, params_ext.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Pixelate: Color Halftone, Crystallize, Facet, Fragment, Mezzotint, Pointillize.
// Cell layouts are anchored at the reference bounds' origin and random choices hash document
// coordinates, so output does not depend on tiling. Following docs/pixelate-performance.md,
// per-cell work is done once per cell: halftone dot radii per screen cell, Crystallize cell
// averages per Voronoi cell, Facet quadrant statistics per 3×3 quadrant.

import Foundation
import Metal
import PCFoundation

// MARK: - Color Halftone

/// Filter › Pixelate › Color Halftone: each channel screened at its own angle into dots whose
/// area follows the channel's ink (1 − value in additive models). `maxRadius` 4–127 px; screen
/// angles per channel in degrees.
public struct ColorHalftone: Filter, Hashable {
    public var maxRadius: Float
    public var angles: SIMD4<Float>
    public init(maxRadius: Float = 8, angles: SIMD4<Float> = SIMD4(108, 162, 90, 45)) {
        self.maxRadius = maxRadius; self.angles = angles
    }
    public var label: String { "Color Halftone" }
    public func halo(bounds: PixelRect) -> Halo { StylizeKit.reach(maxRadius * 3) }
    /// Lab is screened through its RGB conversion (CPU only).
    public func supportsGPU(_ ctx: FilterContext, channels: Int) -> Bool { ctx.mode != .lab }

    static let fracPi4: Float = 0.785_398_16
    static let frac1Sqrt2: Float = 0.707_106_77

    /// Cell side such that a full-size dot just covers the cell's corners.
    var rmaxCell: (Float, Float) {
        let rmax = StylizeKit.fmax(maxRadius, 1)
        return (rmax, rmax * Float(2).squareRoot())
    }

    /// (sin, cos) of each channel's screen angle (photocraft `rot`).
    func rotations(_ count: Int) -> [(Float, Float)] {
        (0..<max(count, 3)).map { c in
            let r = StylizeKit.radians(angles[min(c, 3)])
            return (sinf(r), cosf(r))
        }
    }

    /// photocraft `screen::Screen` bounds: the rotated screen cells around `out`, or nil when the
    /// table would be unsuitable (the dot radii are then computed directly).
    struct Screen {
        var x0: Int32, y0: Int32, width: Int, height: Int

        init?(_ out: PixelRect, _ origin: (Float, Float), _ rot: (Float, Float), _ cell: Float) {
            if out.isEmpty || !cell.isFinite || cell < 1 { return nil }
            let (s, co) = rot
            var lo = (Float.infinity, Float.infinity), hi = (-Float.infinity, -Float.infinity)
            for y in [out.y0, out.y1 - 1] {
                for x in [out.x0, out.x1 - 1] {
                    let fx = Float(x) + 0.5 - origin.0, fy = Float(y) + 0.5 - origin.1
                    let u = (fx * co + fy * s) / cell, v = (-fx * s + fy * co) / cell
                    if !u.isFinite || !v.isFinite || abs(u) > 4_000_000 || abs(v) > 4_000_000 { return nil }
                    lo = (Swift.min(lo.0, u), Swift.min(lo.1, v)); hi = (Swift.max(hi.0, u), Swift.max(hi.1, v))
                }
            }
            x0 = StylizeKit.i32(lo.0.rounded(.down)) - 2
            y0 = StylizeKit.i32(lo.1.rounded(.down)) - 2
            let w = Int(StylizeKit.i32(hi.0.rounded(.down))) + 3 - Int(x0)
            let h = Int(StylizeKit.i32(hi.1.rounded(.down))) + 3 - Int(y0)
            // At most 256 Ki dots per channel, as in photocraft.
            if w < 0 || h < 0 || w * h > 256 * 1024 { return nil }
            width = w; height = h
        }

        /// Table slot of screen cell key (x, y), or nil (photocraft `Screen::radius` key rules).
        @inline(__always)
        func slot(_ x: Float, _ y: Float) -> Int? {
            guard x.isFinite && y.isFinite && abs(x) <= 4_000_001 && abs(y) <= 4_000_001 else { return nil }
            let cx = Int(Int32(x)) - Int(x0), cy = Int(Int32(y)) - Int(y0)
            guard cx >= 0 && cy >= 0 && cx < width && cy < height else { return nil }
            return cy * width + cx
        }
    }

    /// The five-tap channel value at a document point (photocraft `value`).
    @inline(__always)
    static func value(_ s: StyView, _ ctx: FilterContext, _ clip: PixelRect, _ cell: Float, _ x: Float, _ y: Float, _ c: Int,
                      _ rgb: Bool, _ px: UnsafeMutableBufferPointer<Float>) -> Float {
        let d = cell * 0.25
        var acc: Float = 0
        for (dx, dy) in [(Float(0), Float(0)), (-d, -d), (d, -d), (-d, d), (d, d)] {
            // Clamp to the bounds so cells straddling the edge read real pixels.
            let ix = min(max(StylizeKit.i32((x + dx).rounded(.down)), clip.x0), clip.x1 - 1)
            let iy = min(max(StylizeKit.i32((y + dy).rounded(.down)), clip.y0), clip.y1 - 1)
            if rgb {
                s.read(ix, iy, px.baseAddress!)
                acc += ctx.rgba(UnsafeBufferPointer(px))[c]
            } else {
                acc += s.get(ix, iy, c)
            }
        }
        return acc / 5
    }

    /// Dot radius from a channel value: area tracks ink until dots touch, then grows to cover
    /// the corners.
    @inline(__always)
    static func radius(_ value: Float, _ cell: Float, _ inkIsValue: Bool) -> Float {
        let raw = clampf(value, 0, 1)
        let ink = inkIsValue ? raw : 1 - raw
        let touch = fracPi4
        if ink <= touch { return cell * (ink / PCAMath.pi).squareRoot() }
        return cell * (0.5 + (ink - touch) / (1 - touch) * (frac1Sqrt2 - 0.5))
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels, cc = ctx.colorChannels(n)
        var res = src.crop(out)
        if out.isEmpty || n == 0 { return res }
        let (rmax, cell) = rmaxCell
        let sub = ctx.subtractive, rgb = ctx.mode == .lab
        let b = ctx.bounds
        let (ox, oy) = (Float(b.x0), Float(b.y0))
        let rot = rotations(cc)
        let clip = b.intersect(src.rect)
        if clip.isEmpty { return res }
        let chans = rgb ? 3 : cc
        let inkIsValue = sub && !rgb
        // Dot radii per screen cell, per channel (photocraft memoizes them; same values).
        var tables: [(Screen, [Float])?] = []
        src.data.withUnsafeBufferPointer { sb in
            let s = StyView(sb, src)
            for c in 0..<chans {
                guard let sc = Screen(out, (ox, oy), rot[c], cell) else { tables.append(nil); continue }
                var radii = [Float](repeating: 0, count: sc.width * sc.height)
                let (sn, co) = rot[c]
                radii.withUnsafeMutableBufferPointer { rb in
                    let rs = UnsafeSendable(rb)
                    parallelFor(sc.height) { j in
                        withStyScratch(n) { px in
                            for i in 0..<sc.width {
                                let cu = Float(sc.x0 + Int32(i)), cv = Float(sc.y0 + Int32(j))
                                let mu = (cu + 0.5) * cell, mv = (cv + 0.5) * cell
                                let dx = mu * co - mv * sn + ox, dy = mu * sn + mv * co + oy
                                rs.value[j * sc.width + i] = Self.radius(Self.value(s, ctx, clip, cell, dx, dy, c, rgb, px), cell, inkIsValue)
                            }
                        }
                    }
                }
                tables.append((sc, radii))
            }
        }
        let ow = out.width, alpha = ctx.alpha
        src.data.withUnsafeBufferPointer { sb in
            let s = StyView(sb, src)
            res.withStyOut { d in
                parallelFor(out.height) { row in
                    withStyScratch(n) { px in
                        var vals = [Float](repeating: 0, count: 4)
                        let y = out.y0 + Int32(row)
                        for i in 0..<ow {
                            let x = out.x0 + Int32(i)
                            let fx = Float(x) + 0.5 - ox, fy = Float(y) + 0.5 - oy
                            for c in 0..<chans {
                                let (sn, co) = rot[c]
                                // Rotate into screen space.
                                let u = fx * co + fy * sn, w2 = -fx * sn + fy * co
                                let cu = (u / cell).rounded(.down), cv = (w2 / cell).rounded(.down)
                                var cov: Float = 0
                                for dj: Float in [-1, 0, 1] {
                                    for di: Float in [-1, 0, 1] {
                                        let mu = (cu + di + 0.5) * cell, mv = (cv + dj + 0.5) * cell
                                        let dd = ((u - mu) * (u - mu) + (w2 - mv) * (w2 - mv)).squareRoot()
                                        if dd >= rmax + 0.5 { continue }
                                        let r: Float
                                        if let (sc, radii) = tables[c], let k = sc.slot(cu + di, cv + dj) {
                                            r = radii[k]
                                        } else {
                                            // Back to document space to read the cell's value.
                                            let dx = mu * co - mv * sn + ox, dy = mu * sn + mv * co + oy
                                            r = Self.radius(Self.value(s, ctx, clip, cell, dx, dy, c, rgb, px), cell, inkIsValue)
                                        }
                                        // Tiny dots cannot cover more than their own area.
                                        cov = StylizeKit.fmax(cov, StylizeKit.fmin(clampf(r - dd + 0.5, 0, 1), PCAMath.pi * r * r))
                                    }
                                }
                                vals[c % 4] = inkIsValue ? cov : 1 - cov
                                if !rgb { d.value[(row * ow + i) * n + c] = vals[c % 4] }
                            }
                            if rgb {
                                let p = UnsafeMutableBufferPointer(start: d.value + (row * ow + i) * n, count: n)
                                let a: Float = alpha ? p[n - 1] : 1
                                ctx.setRGBA(p, SIMD4(vals[0], vals[1], vals[2], a))
                            }
                        }
                    }
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let b = pass.ctx.bounds, out = pass.out
        let n = StylizeKit.imageChannels(pass)
        let cc = pass.ctx.colorChannels(n)
        let (rmax, cell) = rmaxCell
        let rot = rotations(cc)
        let clip = b.intersect(pass.srcRect)
        if clip.isEmpty {
            try pass.dispatchOut("pca_copy", params: NoParams())
            return
        }
        let origin = (Float(b.x0), Float(b.y0))
        var chans: [HalftoneChan] = []
        var tw = 1, th = 1
        for k in 0..<4 {
            let c = pass.planeChannels.count > k ? pass.planeChannels[k] : -1
            if c < 0 || c >= cc { chans.append(HalftoneChan(s: 0, c: 1, x0: 0, y0: 0, w: 0, h: 0, valid: 0)); continue }
            let (sn, co) = rot[c]
            if let sc = Screen(out, origin, rot[c], cell) {
                chans.append(HalftoneChan(s: sn, c: co, x0: sc.x0, y0: sc.y0, w: Int32(sc.width), h: Int32(sc.height), valid: 1))
                tw = max(tw, sc.width); th = max(th, sc.height)
            } else {
                chans.append(HalftoneChan(s: sn, c: co, x0: 0, y0: 0, w: 0, h: 0, valid: 1))
            }
        }
        let p = HalftoneParams(clipOrigin: SIMD2(clip.x0, clip.y0), clipSize: SIMD2(Int32(clip.width), Int32(clip.height)),
                               origin: SIMD2(origin.0, origin.1), table: SIMD2(Int32(tw), Int32(th)),
                               rmax: rmax, cell: cell, ink: pass.ctx.subtractive ? 1 : 0)
        let cb = try pass.buffer(chans)
        let table = try pass.texture(width: tw, height: th)
        try pass.dispatch("pca_sty_halftone_radii", params: p, textures: [pass.src, table], buffers: [cb], width: tw, height: th)
        try pass.dispatchOut("pca_sty_halftone", params: p, textures: [pass.src, table, pass.dst], buffers: [cb])
    }
}

/// MSL `pca_sty_halftone_chan` (one per plane component).
private struct HalftoneChan: BitwiseCopyable {
    var s: Float
    var c: Float
    var x0: Int32
    var y0: Int32
    var w: Int32
    var h: Int32
    var valid: Int32
    var pad0: Int32 = 0
}

/// MSL `pca_sty_halftone_params`.
private struct HalftoneParams: BitwiseCopyable {
    var clipOrigin: SIMD2<Int32>
    var clipSize: SIMD2<Int32>
    var origin: SIMD2<Float>
    var table: SIMD2<Int32>
    var rmax: Float
    var cell: Float
    var ink: Int32
    var pad0: Int32 = 0
}

// MARK: - Crystallize

/// Filter › Pixelate › Crystallize: Voronoi cells around jittered points (`cellSize` 3–300 px),
/// each filled with the (premultiplied) average colour of its pixels.
public struct Crystallize: Filter, Hashable {
    public var cellSize: Float
    public var seed: UInt32
    public init(cellSize: Float = 10, seed: UInt32 = 0) { self.cellSize = cellSize; self.seed = seed }
    public var label: String { "Crystallize" }
    public func halo(bounds: PixelRect) -> Halo { StylizeKit.reach(StylizeKit.fmax(cellSize, 1) * 3) }

    var cell: Float { StylizeKit.fmin(StylizeKit.fmax(cellSize, 2), StylizeKit.maxCell) }

    /// Cells whose territory can reach `out` (c0…c1) and the window holding their pixels.
    func layout(_ out: PixelRect, _ b: PixelRect, _ srcRect: PixelRect) -> (SIMD2<Int32>, SIMD2<Int32>, PixelRect) {
        let cell = self.cell
        let c0 = SIMD2(StylizeKit.i32((Float(out.x0 - b.x0) / cell).rounded(.down)) - 2, StylizeKit.i32((Float(out.y0 - b.y0) / cell).rounded(.down)) - 2)
        let c1 = SIMD2(StylizeKit.i32((Float(out.x1 - b.x0) / cell).rounded(.down)) + 2, StylizeKit.i32((Float(out.y1 - b.y0) / cell).rounded(.down)) + 2)
        let win = PixelRect(x0: b.x0 + StylizeKit.i32((Float(c0.x) * cell).rounded(.down)), y0: b.y0 + StylizeKit.i32((Float(c0.y) * cell).rounded(.down)),
                            x1: b.x0 + StylizeKit.i32((Float(c1.x + 1) * cell).rounded(.up)), y1: b.y0 + StylizeKit.i32((Float(c1.y + 1) * cell).rounded(.up)))
            .intersect(srcRect).intersect(b)
        return (c0, c1, win)
    }

    /// The Voronoi cell owning pixel (x, y) (nearest jittered point of the 3×3 neighbourhood).
    @inline(__always)
    static func owner(_ x: Int32, _ y: Int32, _ cell: Float, _ seed: UInt32, _ origin: (Float, Float)) -> (Int32, Int32) {
        let fx = Float(x) + 0.5, fy = Float(y) + 0.5
        let cx = StylizeKit.i32(((fx - origin.0) / cell).rounded(.down)), cy = StylizeKit.i32(((fy - origin.1) / cell).rounded(.down))
        var best: (Float, (Int32, Int32)) = (.greatestFiniteMagnitude, (cx, cy))
        for dy: Int32 in -1...1 {
            for dx: Int32 in -1...1 {
                let (px, py) = FxUtil.cellPoint(cx &+ dx, cy &+ dy, cell, seed, origin)
                let d = (px - fx) * (px - fx) + (py - fy) * (py - fy)
                if d < best.0 { best = (d, (cx &+ dx, cy &+ dy)) }
            }
        }
        return best.1
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        var res = src.crop(out)
        if out.isEmpty || n == 0 { return res }
        let cell = self.cell, seed = self.seed, b = ctx.bounds, alpha = ctx.alpha
        let origin = (Float(b.x0), Float(b.y0))
        let (c0, c1, win) = layout(out, b, src.rect)
        let gw = Int(c1.x - c0.x + 1), gh = Int(c1.y - c0.y + 1)
        // Owners of the window's pixels.
        var owners = [SIMD2<Int32>](repeating: .zero, count: win.area)
        owners.withUnsafeMutableBufferPointer { ob in
            let os = UnsafeSendable(ob)
            parallelFor(win.height) { j in
                let y = win.y0 + Int32(j)
                for i in 0..<win.width {
                    let (cx, cy) = Self.owner(win.x0 + Int32(i), y, cell, seed, origin)
                    os.value[j * win.width + i] = SIMD2(cx, cy)
                }
            }
        }
        // Per-cell premultiplied sums in photocraft's order (the window's rows top to bottom).
        // Each cell gathers its own pixels from the 3×3 cells around it, so cells run in parallel.
        var acc = [Float](repeating: 0, count: gw * gh * (n + 1))
        src.data.withUnsafeBufferPointer { sb in
            let s = StyView(sb, src)
            owners.withUnsafeBufferPointer { ob in
                acc.withUnsafeMutableBufferPointer { ab in
                    let a = UnsafeSendable(ab)
                    parallelFor(gh) { j in
                        for i in 0..<gw {
                            let cx = c0.x + Int32(i), cy = c0.y + Int32(j)
                            let k = (j * gw + i) * (n + 1)
                            let box = Self.territory(cx, cy, cell, b).intersect(win)
                            if box.isEmpty { continue }
                            for y in box.y0..<box.y1 {
                                for x in box.x0..<box.x1 {
                                    let o = ob[Int(y - win.y0) * win.width + Int(x - win.x0)]
                                    if o.x != cx || o.y != cy { continue }
                                    let al: Float = alpha ? s.get(x, y, n - 1) : 1
                                    for c in 0..<n {
                                        let v = s.get(x, y, c)
                                        a.value[k + c] += alpha && c < n - 1 ? v * al : v
                                    }
                                    a.value[k + n] += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        // Pixels of `out` outside the bounds keep their own value.
        let ow = out.width
        owners.withUnsafeBufferPointer { ob in
            acc.withUnsafeBufferPointer { ab in
                res.withStyOut { d in
                    parallelFor(out.height) { row in
                        let y = out.y0 + Int32(row)
                        for i in 0..<ow {
                            let x = out.x0 + Int32(i)
                            if !b.contains(x: x, y: y) { continue }
                            let (cx, cy): (Int32, Int32)
                            if win.contains(x: x, y: y) {
                                let o = ob[Int(y - win.y0) * win.width + Int(x - win.x0)]
                                (cx, cy) = (o.x, o.y)
                            } else {
                                (cx, cy) = Self.owner(x, y, cell, seed, origin)
                            }
                            if cx < c0.x || cy < c0.y || cx > c1.x || cy > c1.y { continue }
                            let k = (Int(cy - c0.y) * gw + Int(cx - c0.x)) * (n + 1)
                            let cnt = ab[k + n]
                            if cnt <= 0 { continue }
                            let o = (row * ow + i) * n
                            for c in 0..<n { d.value[o + c] = ab[k + c] / cnt }
                            if alpha {
                                let a = d.value[o + n - 1]
                                for c in 0..<(n - 1) { d.value[o + c] = a > 1e-7 ? d.value[o + c] / a : 0 }
                            }
                        }
                    }
                }
            }
        }
        return res
    }

    /// Pixels that can belong to cell (cx, cy): those whose own grid cell is within one of it
    /// (with a pixel of slack).
    static func territory(_ cx: Int32, _ cy: Int32, _ cell: Float, _ b: PixelRect) -> PixelRect {
        PixelRect(x0: b.x0 &+ StylizeKit.i32((Float(cx - 1) * cell).rounded(.down)) &- 1,
                  y0: b.y0 &+ StylizeKit.i32((Float(cy - 1) * cell).rounded(.down)) &- 1,
                  x1: b.x0 &+ StylizeKit.i32((Float(cx + 2) * cell).rounded(.up)) &+ 1,
                  y1: b.y0 &+ StylizeKit.i32((Float(cy + 2) * cell).rounded(.up)) &+ 1)
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let b = pass.ctx.bounds, out = pass.out
        let (c0, c1, win) = layout(out, b, pass.srcRect)
        let gw = Int(c1.x - c0.x + 1), gh = Int(c1.y - c0.y + 1)
        // A cell's box spans about 3 cells + 4 px; large boxes are gathered in 16-row chunks so
        // a few hundred big cells still fill the GPU (sums then associate per chunk: ≤ 1 ulp-level
        // differences from the reference's single running sum).
        let boxRows = Int(min(cell * 3 + 6, Float(win.height + 2)))
        let chunks = boxRows >= 64 ? (boxRows + 15) / 16 : 1
        let p = CrystalParams(bOrigin: SIMD2(b.x0, b.y0), bSize: SIMD2(Int32(b.width), Int32(b.height)),
                              winOrigin: SIMD2(win.x0, win.y0), winSize: SIMD2(Int32(win.width), Int32(win.height)),
                              c0: c0, c1: c1, origin: SIMD2(Float(b.x0), Float(b.y0)), cell: cell, seed: seed, chunks: Int32(chunks))
        let owners = try pass.texture(width: max(win.width, 1), height: max(win.height, 1))
        try pass.dispatch("pca_sty_crystal_owner", params: p, textures: [owners], width: win.width, height: win.height)
        let avg = try pass.texture(width: gw, height: gh), cnt = try pass.texture(width: gw, height: gh)
        if chunks > 1 {
            let part = try pass.scratchBuffer(length: gw * gh * chunks * 32)
            try pass.dispatch("pca_sty_crystal_partial", params: p, textures: [pass.src, owners], buffers: [part],
                              width: gw * gh, height: chunks, threadgroup: (64, 4))
            try pass.dispatch("pca_sty_crystal_reduce", params: p, textures: [avg, cnt], buffers: [part], width: gw, height: gh)
        } else {
            try pass.dispatch("pca_sty_crystal_cells", params: p, textures: [pass.src, owners, avg, cnt], width: gw, height: gh)
        }
        try pass.dispatchOut("pca_sty_crystal_out", params: p, textures: [pass.src, owners, avg, cnt, pass.dst])
    }
}

/// MSL `pca_sty_crystal_params`.
private struct CrystalParams: BitwiseCopyable {
    var bOrigin: SIMD2<Int32>
    var bSize: SIMD2<Int32>
    var winOrigin: SIMD2<Int32>
    var winSize: SIMD2<Int32>
    var c0: SIMD2<Int32>
    var c1: SIMD2<Int32>
    var origin: SIMD2<Float>
    var cell: Float
    var seed: UInt32
    var chunks: Int32 = 1
    var pad0: Int32 = 0
    var pad1: Int32 = 0
    var pad2: Int32 = 0
}

// MARK: - Facet

/// Filter › Pixelate › Facet: a Kuwahara filter (radius 2) — each pixel takes the mean of the
/// least-varied of its four overlapping 3×3 quadrants, clumping similar colours into facets.
public struct Facet: Filter, Hashable {
    public init() {}
    public var label: String { "Facet" }
    public func halo(bounds: PixelRect) -> Halo { StylizeKit.reach(3) }
    public var gpuChannels: GPUChannels { .joint }
    public func supportsGPU(_ ctx: FilterContext, channels: Int) -> Bool { StylizeKit.supportsFxLuma(ctx, channels: channels) }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        var res = FloatImage(rect: out, channels: n)
        if out.isEmpty || n == 0 { return res }
        // Quadrant statistics once per 3×3 quadrant (top-left corners over `out` grown by 2 up/left),
        // keeping the nine-sample addition order (photocraft `facet::run`).
        let q = PixelRect(x0: out.x0 - 2, y0: out.y0 - 2, x1: out.x1, y1: out.y1)
        let qw = q.width
        var means = [Float](repeating: 0, count: q.area * n)
        var vars = [Float](repeating: 0, count: q.area)
        let lumR = q.outset(by: 0).union(PixelRect(x0: q.x0, y0: q.y0, x1: q.x1 + 2, y1: q.y1 + 2))
        var lum = [Float](repeating: 0, count: lumR.area)
        src.data.withUnsafeBufferPointer { sb in
            let s = StyView(sb, src)
            lum.withUnsafeMutableBufferPointer { lb in
                let ls = UnsafeSendable(lb)
                parallelFor(lumR.height) { j in
                    withStyScratch(n) { px in
                        for i in 0..<lumR.width {
                            s.read(lumR.x0 + Int32(i), lumR.y0 + Int32(j), px.baseAddress!)
                            ls.value[j * lumR.width + i] = ctx.luma(UnsafeBufferPointer(px))
                        }
                    }
                }
            }
            lum.withUnsafeBufferPointer { lb in
                means.withUnsafeMutableBufferPointer { mb in
                    vars.withUnsafeMutableBufferPointer { vb in
                        let ms = UnsafeSendable(mb), vs = UnsafeSendable(vb)
                        parallelFor(q.height) { j in
                            withStyScratch(n) { sum in
                                for i in 0..<qw {
                                    for c in 0..<n { sum[c] = 0 }
                                    var sl: Float = 0, s2: Float = 0
                                    let x0 = q.x0 + Int32(i), y0 = q.y0 + Int32(j)
                                    for yy in y0...(y0 + 2) {
                                        for xx in x0...(x0 + 2) {
                                            for c in 0..<n { sum[c] += s.get(xx, yy, c) }
                                            let l = lb[Int(yy - lumR.y0) * lumR.width + Int(xx - lumR.x0)]
                                            sl += l
                                            s2 += l * l
                                        }
                                    }
                                    let o = j * qw + i
                                    for c in 0..<n { ms.value[o * n + c] = sum[c] / 9 }
                                    let m = sl / 9
                                    vs.value[o] = s2 / 9 - m * m
                                }
                            }
                        }
                    }
                }
            }
        }
        let ow = out.width
        means.withUnsafeBufferPointer { mb in
            vars.withUnsafeBufferPointer { vb in
                res.withStyOut { d in
                    parallelFor(out.height) { row in
                        for i in 0..<ow {
                            // Quadrants in photocraft's order, strict comparison (ties keep the first).
                            var best = Float.greatestFiniteMagnitude, bi = -1
                            for (qx, qy) in [(0, 0), (2, 0), (0, 2), (2, 2)] {
                                let k = (row + qy) * qw + i + qx
                                if vb[k] < best { best = vb[k]; bi = k }
                            }
                            let o = (row * ow + i) * n
                            for c in 0..<n { d.value[o + c] = bi < 0 ? 0 : mb[bi * n + c] }
                        }
                    }
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let out = pass.out
        let q = PixelRect(x0: out.x0 - 2, y0: out.y0 - 2, x1: out.x1, y1: out.y1)
        let p = FacetParams(qOrigin: SIMD2(q.x0, q.y0), qSize: SIMD2(Int32(q.width), Int32(q.height)), luma: StylizeKit.fxLumaCode(pass.ctx) ?? 1)
        let means = try pass.texture(q), vars = try pass.texture(q)
        try pass.dispatch("pca_sty_facet_quadrants", params: p, textures: [pass.src, means, vars], width: q.width, height: q.height)
        try pass.dispatchOut("pca_sty_facet", params: p, textures: [means, vars, pass.dst])
    }
}

/// MSL `pca_sty_facet_params`.
private struct FacetParams: BitwiseCopyable {
    var qOrigin: SIMD2<Int32>
    var qSize: SIMD2<Int32>
    var luma: Int32
    var pad0: Int32 = 0
    var pad1: Int32 = 0
    var pad2: Int32 = 0
}

// MARK: - Fragment

/// Filter › Pixelate › Fragment: the (premultiplied) average of four copies offset by 4 px.
public struct Fragment: Filter, Hashable {
    public init() {}
    public var label: String { "Fragment" }
    public func halo(bounds: PixelRect) -> Halo { StylizeKit.reach(4) }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        var res = FloatImage(rect: out, channels: n)
        if out.isEmpty || n == 0 { return res }
        let ow = out.width, alpha = ctx.alpha
        src.data.withUnsafeBufferPointer { sb in
            let s = StyView(sb, src)
            res.withStyOut { d in
                parallelFor(out.height) { row in
                    let y = out.y0 + Int32(row)
                    for i in 0..<ow {
                        let x = out.x0 + Int32(i)
                        let o = (row * ow + i) * n
                        for c in 0..<n { d.value[o + c] = 0 }
                        for (dx, dy): (Int32, Int32) in [(-4, 0), (4, 0), (0, -4), (0, 4)] {
                            let a: Float = alpha ? s.get(x + dx, y + dy, n - 1) : 1
                            for c in 0..<n {
                                let v = s.get(x + dx, y + dy, c)
                                d.value[o + c] += (alpha && c < n - 1 ? v * a : v) * 0.25
                            }
                        }
                        if alpha {
                            let a = d.value[o + n - 1]
                            for c in 0..<(n - 1) { d.value[o + c] = a > 1e-7 ? d.value[o + c] / a : 0 }
                        }
                    }
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        try pass.dispatchOut("pca_sty_fragment", params: NoParams())
    }
}

// MARK: - Mezzotint

/// Mezzotint pattern (photocraft `MezzotintType`).
public enum MezzotintType: String, Codable, Sendable, Hashable, CaseIterable {
    case fineDots, mediumDots, grainyDots, coarseDots, shortLines, mediumLines, longLines, shortStrokes, mediumStrokes, longStrokes

    var code: Int32 { Int32(Self.allCases.firstIndex(of: self)!) }
}

/// Filter › Pixelate › Mezzotint: every colour channel thresholded against a random pattern of
/// dots, lines or strokes (pure channel values).
public struct Mezzotint: Filter, Hashable {
    public var kind: MezzotintType
    public var seed: UInt32
    public init(kind: MezzotintType = .fineDots, seed: UInt32 = 0) { self.kind = kind; self.seed = seed }
    public var label: String { "Mezzotint" }
    public func halo(bounds: PixelRect) -> Halo { .radius(0) }
    /// Lab is thresholded through its RGB conversion (CPU only).
    public func supportsGPU(_ ctx: FilterContext, channels: Int) -> Bool { ctx.mode != .lab }

    /// photocraft `mezzo_threshold`.
    @inline(__always)
    static func threshold(_ kind: MezzotintType, _ x: Int32, _ y: Int32, _ c: UInt32, _ seed: UInt32) -> Float {
        func lines(_ len: Int32) -> Float {
            let phase = StylizeKit.i32(hash01(0, y, c &+ 40, seed) * Float(len))
            return hash01(StylizeKit.divEuclid(x &+ phase, len), y, c, seed)
        }
        func strokes(_ len: Int32) -> Float {
            let d = x &- y
            let phase = StylizeKit.i32(hash01(d, 0, c &+ 50, seed) * Float(len))
            return hash01(StylizeKit.divEuclid(x &+ y &+ phase, len), d, c &+ 60, seed)
        }
        switch kind {
        case .fineDots: return hash01(x, y, c, seed)
        case .mediumDots: return hash01(StylizeKit.divEuclid(x, 2), StylizeKit.divEuclid(y, 2), c, seed)
        case .grainyDots: return 0.5 * hash01(x, y, c, seed) + 0.5 * hash01(StylizeKit.divEuclid(x, 3), StylizeKit.divEuclid(y, 3), c &+ 7, seed)
        case .coarseDots: return hash01(StylizeKit.divEuclid(x, 3), StylizeKit.divEuclid(y, 3), c, seed)
        case .shortLines: return lines(6)
        case .mediumLines: return lines(14)
        case .longLines: return lines(32)
        case .shortStrokes: return strokes(5)
        case .mediumStrokes: return strokes(10)
        case .longStrokes: return strokes(20)
        }
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels, cc = ctx.colorChannels(n)
        var res = src.crop(out)
        if out.isEmpty || n == 0 { return res }
        let rgb = ctx.mode == .lab, kind = self.kind, seed = self.seed
        let ow = out.width
        res.withStyOut { d in
            parallelFor(out.height) { row in
                let y = out.y0 + Int32(row)
                for i in 0..<ow {
                    let x = out.x0 + Int32(i)
                    let px = UnsafeMutableBufferPointer(start: d.value + (row * ow + i) * n, count: n)
                    if rgb {
                        var c = ctx.rgba(UnsafeBufferPointer(px))
                        for k in 0..<3 { c[k] = c[k] > Self.threshold(kind, x, y, UInt32(k), seed) ? 1 : 0 }
                        ctx.setRGBA(px, c)
                    } else {
                        for k in 0..<cc { px[k] = px[k] > Self.threshold(kind, x, y, UInt32(k), seed) ? 1 : 0 }
                    }
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        try pass.dispatchOut("pca_sty_mezzotint", params: MezzoParams(kind: kind.code, seed: seed))
    }
}

/// MSL `pca_sty_mezzo_params`.
private struct MezzoParams: BitwiseCopyable {
    var kind: Int32
    var seed: UInt32
    var pad0: Int32 = 0
    var pad1: Int32 = 0
}

// MARK: - Pointillize

/// Filter › Pixelate › Pointillize: randomly sized dots (`cellSize` 3–300 px) coloured from the
/// image at their centre, on a canvas of `background` (straight sRGB RGBA).
public struct Pointillize: Filter, Hashable {
    public var cellSize: Float
    public var seed: UInt32
    public var background: SIMD4<Float>
    public init(cellSize: Float = 5, seed: UInt32 = 0, background: SIMD4<Float> = SIMD4(1, 1, 1, 1)) {
        self.cellSize = cellSize; self.seed = seed; self.background = background
    }
    public var label: String { "Pointillize" }
    public func halo(bounds: PixelRect) -> Halo { StylizeKit.reach(StylizeKit.fmax(cellSize, 1) * 2) }

    var cell: Float { StylizeKit.fmin(StylizeKit.fmax(cellSize, 2), StylizeKit.maxCell) }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels, cc = ctx.colorChannels(n)
        var res = src.crop(out)
        if out.isEmpty || n == 0 { return res }
        let cell = self.cell, seed = self.seed, b = ctx.bounds, alpha = ctx.alpha, sub = ctx.subtractive
        let origin = (Float(b.x0), Float(b.y0))
        let bg = ctx.native(background, channels: n)
        let ow = out.width
        src.data.withUnsafeBufferPointer { sb in
            let s = StyView(sb, src)
            res.withStyOut { d in
                parallelFor(out.height) { row in
                    withStyScratch(n) { dot in
                        withStyScratch(n) { canvas in
                            let y = out.y0 + Int32(row)
                            for i in 0..<ow {
                                let x = out.x0 + Int32(i)
                                let fx = Float(x) + 0.5, fy = Float(y) + 0.5
                                let cx = StylizeKit.i32(((fx - origin.0) / cell).rounded(.down)), cy = StylizeKit.i32(((fy - origin.1) / cell).rounded(.down))
                                // The dot whose edge the pixel is deepest inside wins.
                                var best: (Float, Int32, Int32, Float, Float)?
                                for dy: Int32 in -1...1 {
                                    for dx: Int32 in -1...1 {
                                        let gx = cx &+ dx, gy = cy &+ dy
                                        let (px0, py0) = FxUtil.cellPoint(gx, gy, cell, seed, origin)
                                        let rad = cell * (0.45 + 0.35 * hash01(gx, gy, 13, seed))
                                        let dd = ((px0 - fx) * (px0 - fx) + (py0 - fy) * (py0 - fy)).squareRoot()
                                        let depth = rad - dd
                                        if depth > -0.5 && (best == nil || depth > best!.0) { best = (depth, gx, gy, px0, py0) }
                                    }
                                }
                                let o = (row * ow + i) * n
                                let aOrig: Float = alpha ? d.value[o + n - 1] : 1
                                // Canvas first, then the dot over it with an anti-aliased edge.
                                for c in 0..<n { canvas[c] = bg[c] }
                                if alpha { canvas[n - 1] = StylizeKit.fmax(aOrig, StylizeKit.fmin(bg[n - 1], 1)) }
                                if let (depth, gx, gy, px0, py0) = best {
                                    s.read(StylizeKit.i32(px0.rounded(.down)), StylizeKit.i32(py0.rounded(.down)), dot.baseAddress!)
                                    // Slight per-dot brightness jitter, as in pointillist strokes.
                                    let j = (hash01(gx, gy, 17, seed) - 0.5) * 0.08
                                    for c in 0..<cc { dot[c] = clampf(dot[c] + (sub ? -j : j), 0, 1) }
                                    let k = clampf(depth + 0.5, 0, 1)
                                    for c in 0..<n { canvas[c] += (dot[c] - canvas[c]) * k }
                                }
                                for c in 0..<n { d.value[o + c] = canvas[c] }
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
        let bg = pass.ctx.native(background, channels: StylizeKit.imageChannels(pass))
        let p = PointParams(bg: StylizeKit.planeColor(bg, pass: pass), origin: SIMD2(Float(b.x0), Float(b.y0)),
                            cell: cell, seed: seed, sub: pass.ctx.subtractive ? 1 : 0, bgAlpha: pass.ctx.alpha ? bg.last ?? 1 : 1,
                            pad0: 0, pad1: 0)
        try pass.dispatchOut("pca_sty_pointillize", params: p)
    }
}

/// MSL `pca_sty_point_params`.
private struct PointParams: BitwiseCopyable {
    var bg: SIMD4<Float>
    var origin: SIMD2<Float>
    var cell: Float
    var seed: UInt32
    var sub: Int32
    var bgAlpha: Float
    var pad0: Int32
    var pad1: Int32
}
