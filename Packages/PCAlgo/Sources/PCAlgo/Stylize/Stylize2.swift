// Port of photocraft-algo (crates/algo/src/stylize2.rs, params_ext.rs, lib.rs halo_ext), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Stylize › Diffuse, Tiles and Trace Contour.

import PCFoundation

// MARK: - Diffuse

/// Diffuse mode (photocraft `DiffuseMode`).
public enum DiffuseMode: String, Codable, Sendable, Hashable, CaseIterable {
    case normal, darkenOnly, lightenOnly, anisotropic
}

/// Filter › Stylize › Diffuse: every pixel is swapped for a random neighbour (within 1 px);
/// Darken/Lighten Only accept it only when darker/lighter; Anisotropic moves half-way toward
/// the most similar neighbour.
public struct Diffuse: Filter, Hashable {
    public var mode: DiffuseMode
    public var seed: UInt32
    public init(mode: DiffuseMode = .normal, seed: UInt32 = 0) { self.mode = mode; self.seed = seed }
    public var label: String { "Diffuse" }
    public func halo(bounds: PixelRect) -> Halo { StylizeKit.reach(1) }
    /// Normal moves whole pixels by a channel-independent hash; the other modes compare luma.
    public var gpuChannels: GPUChannels { mode == .normal ? .perChannel : .joint }
    public func supportsGPU(_ ctx: FilterContext, channels: Int) -> Bool {
        mode == .normal || StylizeKit.supportsFxLuma(ctx, channels: channels)
    }

    static let ring: [(Int32, Int32)] = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        var res = src.crop(out)
        if out.isEmpty || n == 0 { return res }
        let ow = out.width, mode = self.mode, seed = self.seed, alpha = ctx.alpha
        src.data.withUnsafeBufferPointer { sb in
            let s = StyView(sb, src)
            res.withStyOut { d in
                parallelFor(out.height) { row in
                    withStyScratch(n) { nb in
                        let nbb = UnsafeBufferPointer(nb)
                        let y = out.y0 + Int32(row)
                        for i in 0..<ow {
                            let x = out.x0 + Int32(i)
                            let px = UnsafeMutableBufferPointer(start: d.value + (row * ow + i) * n, count: n)
                            switch mode {
                            case .anisotropic:
                                let me = ctx.luma(UnsafeBufferPointer(px))
                                var best: (Float, (Int32, Int32)) = (.greatestFiniteMagnitude, (0, 0))
                                // Random start so ties do not bias one direction.
                                let start = StylizeKit.usize(hash01(x, y, 3, seed) * 8)
                                for k in 0..<8 {
                                    let (dx, dy) = Diffuse.ring[(start + k) % 8]
                                    s.read(x + dx, y + dy, nb.baseAddress!)
                                    let dd = abs(ctx.luma(nbb) - me)
                                    if dd < best.0 { best = (dd, (dx, dy)) }
                                }
                                s.read(x + best.1.0, y + best.1.1, nb.baseAddress!)
                                for c in 0..<n { px[c] = 0.5 * (px[c] + nb[c]) }
                            default:
                                let dx = StylizeKit.i32(hash01(x, y, 1, seed) * 3) - 1
                                let dy = StylizeKit.i32(hash01(x, y, 2, seed) * 3) - 1
                                s.read(x + dx, y + dy, nb.baseAddress!)
                                if alpha && nb[n - 1] <= 0 && px[n - 1] > 0 && mode != .normal { continue }
                                let take: Bool
                                switch mode {
                                case .darkenOnly: take = ctx.luma(nbb) < ctx.luma(UnsafeBufferPointer(px))
                                case .lightenOnly: take = ctx.luma(nbb) > ctx.luma(UnsafeBufferPointer(px))
                                default: take = true
                                }
                                if take { for c in 0..<n { px[c] = nb[c] } }
                            }
                        }
                    }
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let modeCode: Int32 = switch mode { case .normal: 0; case .darkenOnly: 1; case .lightenOnly: 2; case .anisotropic: 3 }
        let p = DiffuseParams(seed: seed, mode: modeCode, luma: StylizeKit.fxLumaCode(pass.ctx) ?? 1)
        try pass.dispatchOut("pca_sty_diffuse", params: p)
    }
}

/// MSL `pca_sty_diffuse_params`.
private struct DiffuseParams: BitwiseCopyable {
    var seed: UInt32
    var mode: Int32
    var luma: Int32
    var pad0: Int32 = 0
}

// MARK: - Tiles

/// What Tiles puts in the gaps between tiles (photocraft `TileFill`).
public enum TileFill: String, Codable, Sendable, Hashable, CaseIterable {
    case background, foreground, inverse, unaltered
}

/// Filter › Stylize › Tiles: the bounds cut into square tiles (`count` along the shorter side,
/// 1–99), each shifted randomly by up to `maxOffset` % of its size (1–99); later tiles overlap
/// earlier ones and gaps get `fill`. Colours are straight sRGB RGBA.
public struct Tiles: Filter, Hashable {
    public var count: UInt32
    public var maxOffset: Float
    public var fill: TileFill
    public var foreground: SIMD4<Float>
    public var background: SIMD4<Float>
    public var seed: UInt32
    public init(count: UInt32 = 10, maxOffset: Float = 10, fill: TileFill = .background,
                foreground: SIMD4<Float> = SIMD4(0, 0, 0, 1), background: SIMD4<Float> = SIMD4(1, 1, 1, 1), seed: UInt32 = 0) {
        self.count = count; self.maxOffset = maxOffset; self.fill = fill
        self.foreground = foreground; self.background = background; self.seed = seed
    }
    public var label: String { "Tiles" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }

    /// Tile size and max offset (photocraft `ts`, `m`).
    func geometry(_ b: PixelRect) -> (Float, Float) {
        let ts = StylizeKit.fmax(Float(min(b.width, b.height)) / Float(min(max(count, 1), 99)), 1)
        return (ts, clampf(maxOffset, 0, 99) / 100 * ts)
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels, cc = ctx.colorChannels(n)
        var res = src.crop(out)
        if out.isEmpty || n == 0 { return res }
        let b = ctx.bounds
        let (ts, m) = geometry(b)
        let fg = ctx.native(foreground, channels: n), bg = ctx.native(background, channels: n)
        let ow = out.width, seed = self.seed, fill = self.fill
        let bw = Float(b.width), bh = Float(b.height)
        src.data.withUnsafeBufferPointer { sb in
            let s = StyView(sb, src)
            res.withStyOut { d in
                parallelFor(out.height) { row in
                    let y = out.y0 + Int32(row)
                    for i in 0..<ow {
                        let x = out.x0 + Int32(i)
                        if !b.contains(x: x, y: y) { continue }
                        let o = (row * ow + i) * n
                        if let (ox, oy) = Tiles.topmost(x, y, b, ts, m, seed, bw, bh) {
                            let sx = min(max(StylizeKit.i32((Float(x) + 0.5 - ox).rounded(.down)), b.x0), b.x1 - 1)
                            let sy = min(max(StylizeKit.i32((Float(y) + 0.5 - oy).rounded(.down)), b.y0), b.y1 - 1)
                            s.read(sx, sy, d.value + o)
                        } else {
                            switch fill {
                            case .background: for c in 0..<n { d.value[o + c] = bg[c] }
                            case .foreground: for c in 0..<n { d.value[o + c] = fg[c] }
                            case .inverse: for c in 0..<cc { d.value[o + c] = 1 - d.value[o + c] }
                            case .unaltered: break
                            }
                        }
                    }
                }
            }
        }
        return res
    }

    /// The offset of the topmost tile (drawn last = highest row-major index) covering pixel
    /// (x, y), or nil in a gap.
    @inline(__always)
    static func topmost(_ x: Int32, _ y: Int32, _ b: PixelRect, _ ts: Float, _ m: Float, _ seed: UInt32, _ bw: Float, _ bh: Float) -> (Float, Float)? {
        let fx = Float(x) + 0.5 - Float(b.x0), fy = Float(y) + 0.5 - Float(b.y0)
        let gx = StylizeKit.i32((fx / ts).rounded(.down)), gy = StylizeKit.i32((fy / ts).rounded(.down))
        var hit: ((Int32, Int32), Float, Float)?
        for dy: Int32 in -1...1 {
            for dx: Int32 in -1...1 {
                let cx = gx &+ dx, cy = gy &+ dy
                let ox = (hash01(cx, cy, 31, seed) * 2 - 1) * m, oy = (hash01(cx, cy, 32, seed) * 2 - 1) * m
                let u = fx - ox - Float(cx) * ts, v = fy - oy - Float(cy) * ts
                if u >= 0 && v >= 0 && u < ts && v < ts && Float(cx) * ts < bw && Float(cy) * ts < bh && cx >= 0 && cy >= 0 {
                    if hit == nil || (cy, cx) > hit!.0 { hit = ((cy, cx), ox, oy) }
                }
            }
        }
        return hit.map { ($0.1, $0.2) }
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let b = pass.ctx.bounds
        let total = StylizeKit.imageChannels(pass)
        let (ts, m) = geometry(b)
        let fill: Int32 = switch self.fill { case .background: 0; case .foreground: 1; case .inverse: 2; case .unaltered: 3 }
        let p = TilesParams(fg: StylizeKit.planeColor(pass.ctx.native(foreground, channels: total), pass: pass),
                            bg: StylizeKit.planeColor(pass.ctx.native(background, channels: total), pass: pass),
                            bOrigin: SIMD2(b.x0, b.y0), bSize: SIMD2(Int32(b.width), Int32(b.height)),
                            ts: ts, m: m, seed: seed, fill: fill)
        try pass.dispatchOut("pca_sty_tiles", params: p)
    }
}

/// MSL `pca_sty_tiles_params`.
private struct TilesParams: BitwiseCopyable {
    var fg: SIMD4<Float>
    var bg: SIMD4<Float>
    var bOrigin: SIMD2<Int32>
    var bSize: SIMD2<Int32>
    var ts: Float
    var m: Float
    var seed: UInt32
    var fill: Int32
}

// MARK: - Trace Contour

/// Filter › Stylize › Trace Contour: per channel, a 1 px line where values cross `level`
/// (0–255) on the side above it (`upper`) or below, dark on white (inverted for ink models).
public struct TraceContour: Filter, Hashable {
    public var level: Float
    public var upper: Bool
    public init(level: Float = 128, upper: Bool = false) { self.level = level; self.upper = upper }
    public var label: String { "Trace Contour" }
    public func halo(bounds: PixelRect) -> Halo { StylizeKit.reach(1) }

    /// The repeated-edge area: the bounds inside the source, else the source.
    static func area(_ src: PixelRect, _ ctx: FilterContext) -> PixelRect {
        let bi = ctx.bounds.intersect(src)
        return bi.isEmpty ? src : bi
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels, cc = ctx.colorChannels(n)
        var res = src.crop(out)
        if out.isEmpty || n == 0 { return res }
        let sub = ctx.subtractive, area = Self.area(src.rect, ctx), upper = self.upper
        let t = clampf(level, 0, 255) / 255
        let ow = out.width
        src.data.withUnsafeBufferPointer { sb in
            let s = StyView(sb, src)
            res.withStyOut { d in
                parallelFor(out.height) { row in
                    let y = out.y0 + Int32(row)
                    for i in 0..<ow {
                        let x = out.x0 + Int32(i)
                        for c in 0..<cc {
                            @inline(__always) func bright(_ xx: Int32, _ yy: Int32) -> Float {
                                let v = s.getEdge(xx, yy, c, .repeatEdge, area)
                                return sub ? 1 - v : v
                            }
                            let me = bright(x, y) > t
                            let line = me == upper && ((bright(x + 1, y) > t) != me || (bright(x - 1, y) > t) != me
                                || (bright(x, y + 1) > t) != me || (bright(x, y - 1) > t) != me)
                            let paper: Float = line ? 0 : 1
                            d.value[(row * ow + i) * n + c] = sub ? 1 - paper : paper
                        }
                    }
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let a = Self.area(pass.srcRect, pass.ctx)
        let p = TraceParams(areaOrigin: SIMD2(a.x0, a.y0), areaSize: SIMD2(Int32(a.width), Int32(a.height)),
                            t: clampf(level, 0, 255) / 255, upper: upper ? 1 : 0, sub: pass.ctx.subtractive ? 1 : 0)
        try pass.dispatchOut("pca_sty_trace_contour", params: p)
    }
}

/// MSL `pca_sty_trace_params`.
private struct TraceParams: BitwiseCopyable {
    var areaOrigin: SIMD2<Int32>
    var areaSize: SIMD2<Int32>
    var t: Float
    var upper: Int32
    var sub: Int32
    var pad0: Int32 = 0
}
