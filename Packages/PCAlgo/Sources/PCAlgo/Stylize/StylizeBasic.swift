// Port of photocraft-algo (crates/algo/src/stylize.rs, lib.rs kernel/halo entries), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Pixelate › Mosaic and Filter › Stylize › Emboss, Find Edges, Solarize, plus Invert
// and Desaturate (photocraft's per-pixel entries of the same module).

import Foundation
import PCFoundation

// MARK: - Mosaic

/// Filter › Pixelate › Mosaic: square cells anchored at the bounds' origin, each the
/// (premultiplied) average of its part inside the bounds. `cellSize` 2–200 px (photocraft
/// rounds it, minimum 1).
public struct Mosaic: Filter, Hashable {
    public var cellSize: Float
    public init(cellSize: Float = 10) { self.cellSize = cellSize }
    public var label: String { "Mosaic" }
    public func halo(bounds: PixelRect) -> Halo { StylizeKit.reach(StylizeKit.fmax(cellSize, 1)) }

    /// photocraft `cell.max(1.0).round() as i32` (capped at `StylizeKit.maxCell`).
    var cs: Int32 {
        StylizeKit.i32(StylizeKit.fmin(StylizeKit.fmax(cellSize, 1), StylizeKit.maxCell).rounded(.toNearestOrAwayFromZero))
    }

    /// Cell index range covering `out` (photocraft `cx0…cy1`).
    func cellRange(_ out: PixelRect, _ b: PixelRect) -> (Int32, Int32, Int32, Int32) {
        let cs = self.cs
        return (StylizeKit.divEuclid(out.x0 - b.x0, cs), StylizeKit.divEuclid(out.y0 - b.y0, cs),
                StylizeKit.divEuclid(out.x1 - 1 - b.x0, cs), StylizeKit.divEuclid(out.y1 - 1 - b.y0, cs))
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        var res = FloatImage(rect: out, channels: n)
        if out.isEmpty || n == 0 { return res }
        let cs = self.cs, b = ctx.bounds, alpha = ctx.alpha
        let (cx0, cy0, cx1, cy1) = cellRange(out, b)
        let ncx = Int(cx1 - cx0 + 1), ncy = Int(cy1 - cy0 + 1)
        let ow = out.width
        src.data.withUnsafeBufferPointer { sb in
            let s = StyView(sb, src)
            res.withStyOut { d in
                // One task per cell row: cells write disjoint parts of `out`.
                parallelFor(ncy) { j in
                    let cy = cy0 + Int32(j)
                    withStyScratch(n) { acc in
                        for i in 0..<ncx {
                            let cx = cx0 + Int32(i)
                            let cell = PixelRect(x0: b.x0 + cx * cs, y0: b.y0 + cy * cs, x1: b.x0 + (cx + 1) * cs, y1: b.y0 + (cy + 1) * cs)
                            let r = cell.intersect(b)
                            for c in 0..<n { acc[c] = 0 }
                            var count: Float = 0
                            if !r.isEmpty {
                                for yy in r.y0..<r.y1 {
                                    for xx in r.x0..<r.x1 {
                                        let a: Float = alpha ? s.get(xx, yy, n - 1) : 1
                                        for c in 0..<n {
                                            let v = s.get(xx, yy, c)
                                            acc[c] += alpha && c < n - 1 ? v * a : v
                                        }
                                        count += 1
                                    }
                                }
                            }
                            if count > 0 { for c in 0..<n { acc[c] /= count } }
                            if alpha {
                                let a = acc[n - 1]
                                for c in 0..<(n - 1) { acc[c] = a > 1e-7 ? acc[c] / a : 0 }
                            }
                            // The full cell clips the write, keeping partial cells outside the bounds.
                            let wr = cell.intersect(out)
                            if wr.isEmpty { continue }
                            for y in wr.y0..<wr.y1 {
                                var o = (Int(y - out.y0) * ow + Int(wr.x0 - out.x0)) * n
                                for _ in wr.x0..<wr.x1 {
                                    for c in 0..<n { d.value[o + c] = acc[c] }
                                    o += n
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
        let b = pass.ctx.bounds, out = pass.out, cs = self.cs
        let (cx0, cy0, cx1, cy1) = cellRange(out, b)
        let ncx = Int(cx1 - cx0 + 1), ncy = Int(cy1 - cy0 + 1)
        // Rows of the cells, clipped to the bounds (cells only average inside them).
        let row0 = max(b.y0 &+ cy0 &* cs, b.y0), row1 = min(b.y0 &+ (cy1 + 1) &* cs, b.y1)
        let nrows = max(Int(row1) - Int(row0), 0)
        let p = MosaicParams(bOrigin: SIMD2(b.x0, b.y0), bSize: SIMD2(Int32(b.width), Int32(b.height)),
                             c0: SIMD2(cx0, cy0), ncell: SIMD2(Int32(ncx), Int32(ncy)), cs: cs, row0: row0, nrows: Int32(nrows))
        let rows = try pass.texture(width: ncx, height: max(nrows, 1))
        try pass.dispatch("pca_sty_mosaic_rows", params: p, textures: [pass.src, rows], width: ncx, height: nrows)
        let cells = try pass.texture(width: ncx, height: ncy)
        try pass.dispatch("pca_sty_mosaic_cells", params: p, textures: [rows, cells], width: ncx, height: ncy)
        try pass.dispatchOut("pca_sty_mosaic_out", params: p, textures: [cells, pass.dst])
    }
}

/// MSL `pca_sty_mosaic_params`.
private struct MosaicParams: BitwiseCopyable {
    var bOrigin: SIMD2<Int32>
    var bSize: SIMD2<Int32>
    var c0: SIMD2<Int32>
    var ncell: SIMD2<Int32>
    var cs: Int32
    var row0: Int32
    var nrows: Int32
    var pad0: Int32 = 0
}

// MARK: - Emboss

/// Filter › Stylize › Emboss: a gray relief from luminance differences along the light angle.
/// `angle` degrees (−180…180), `height` px (1–100), `amount` % (1–500).
public struct Emboss: Filter, Hashable {
    public var angle: Float
    public var height: Float
    public var amount: Float
    public init(angle: Float = 135, height: Float = 3, amount: Float = 100) {
        self.angle = angle; self.height = height; self.amount = amount
    }
    public var label: String { "Emboss" }
    /// photocraft `Halo::Radius(height.abs().ceil() as i32 + 2)`.
    public func halo(bounds: PixelRect) -> Halo {
        .radius(StylizeKit.i32(min(abs(height), StylizeKit.maxCell).rounded(.up)) + 2)
    }
    public var gpuChannels: GPUChannels { .joint }
    public func supportsGPU(_ ctx: FilterContext, channels: Int) -> Bool {
        StylizeKit.rgbLumaCode(ctx) != nil && StylizeKit.onePlane(ctx, channels: channels)
    }

    /// The light offset `(dx, dy)` and gain photocraft derives from the parameters.
    var geometry: (Int32, Int32, Float) {
        let r = StylizeKit.radians(angle)
        let (s, c) = (sinf(r), cosf(r))
        let h = min(StylizeKit.fmax(height, 1), StylizeKit.maxCell)
        return (StylizeKit.i32((c * h).rounded(.toNearestOrAwayFromZero)), StylizeKit.i32((-s * h).rounded(.toNearestOrAwayFromZero)), amount / 100)
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        var res = src.crop(out)
        if out.isEmpty || n == 0 { return res }
        let (dx, dy, k) = geometry
        let ow = out.width
        src.data.withUnsafeBufferPointer { sb in
            let s = StyView(sb, src)
            res.withStyOut { d in
                parallelFor(out.height) { row in
                    withStyScratch(n) { tmp in
                        let tb = UnsafeBufferPointer(tmp)
                        let y = out.y0 + Int32(row)
                        for i in 0..<ow {
                            let x = out.x0 + Int32(i)
                            s.read(x + dx, y + dy, tmp.baseAddress!)
                            let l1 = ctx.lumaViaRGB(tb)
                            s.read(x - dx, y - dy, tmp.baseAddress!)
                            let l2 = ctx.lumaViaRGB(tb)
                            let g = clampf(0.5 + k * (l1 - l2), 0, 1)
                            let o = (row * ow + i) * n
                            StylizeKit.setGray(ctx, UnsafeMutableBufferPointer(start: d.value + o, count: n), g)
                        }
                    }
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let (dx, dy, k) = geometry
        let p = EmbossParams(d: SIMD2(dx, dy), k: k, luma: StylizeKit.rgbLumaCode(pass.ctx) ?? 1)
        try pass.dispatchOut("pca_sty_emboss", params: p)
    }
}

/// MSL `pca_sty_emboss_params`.
private struct EmbossParams: BitwiseCopyable {
    var d: SIMD2<Int32>
    var k: Float
    var luma: Int32
}

extension StylizeKit {
    /// stylize `set_gray`: the colour replaced by gray `g` in the pixel's own model, alpha kept.
    @inline(__always)
    static func setGray(_ ctx: FilterContext, _ px: UnsafeMutableBufferPointer<Float>, _ g: Float) {
        let a: Float = ctx.alpha ? px[px.count - 1] : 1
        ctx.setRGBA(px, SIMD4(g, g, g, a))
    }
}

// MARK: - Find Edges

/// Filter › Stylize › Find Edges: Sobel magnitude per colour channel, dark edges on white.
public struct FindEdges: Filter, Hashable {
    public init() {}
    public var label: String { "Find Edges" }
    public func halo(bounds: PixelRect) -> Halo { .radius(1) }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels, cc = ctx.colorChannels(n), sub = ctx.subtractive
        var res = src.crop(out)
        if out.isEmpty || n == 0 { return res }
        let ow = out.width
        src.data.withUnsafeBufferPointer { sb in
            let s = StyView(sb, src)
            res.withStyOut { d in
                parallelFor(out.height) { row in
                    let y = out.y0 + Int32(row)
                    for i in 0..<ow {
                        let x = out.x0 + Int32(i)
                        let o = (row * ow + i) * n
                        for c in 0..<cc {
                            @inline(__always) func g(_ dx: Int32, _ dy: Int32) -> Float { s.get(x + dx, y + dy, c) }
                            let gx = (g(1, -1) + 2 * g(1, 0) + g(1, 1)) - (g(-1, -1) + 2 * g(-1, 0) + g(-1, 1))
                            let gy = (g(-1, 1) + 2 * g(0, 1) + g(1, 1)) - (g(-1, -1) + 2 * g(0, -1) + g(1, -1))
                            // CMYK samples are ink, so there the edge strength is the ink itself;
                            // `1 − edge` turned flat CMYK areas to full ink (photocraft #4222).
                            let e = clampf((gx * gx + gy * gy).squareRoot() / 4, 0, 1)
                            d.value[o + c] = sub ? e : 1 - e
                        }
                    }
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        try pass.dispatchOut("pca_sty_find_edges", params: PerPixelParams(op: pass.ctx.subtractive ? 1 : 0))
    }
}

// MARK: - Solarize, Invert

/// Filter › Stylize › Solarize: colour channels above ½ are inverted (alpha untouched).
public struct Solarize: Filter, Hashable {
    public init() {}
    public var label: String { "Solarize" }
    public func halo(bounds: PixelRect) -> Halo { .radius(0) }
    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        // Solarize inverts the highlights. CMYK samples are ink, so there the channels below 50 %
        // ink (the light ones) invert (photocraft #4222).
        ctx.subtractive ? StylizeKit.perPixel(src, out, ctx) { $0 < 0.5 ? 1 - $0 : $0 } : StylizeKit.perPixel(src, out, ctx) { $0 > 0.5 ? 1 - $0 : $0 }
    }
    public func encodeGPU(_ pass: GPUPass) throws {
        try pass.dispatchOut("pca_sty_per_pixel", params: PerPixelParams(op: pass.ctx.subtractive ? 2 : 1))
    }
}

/// Image › Adjustments › Invert as photocraft's filter entry: `1 − v` per colour channel.
public struct Invert: Filter, Hashable {
    public init() {}
    public var label: String { "Invert" }
    public func halo(bounds: PixelRect) -> Halo { .radius(0) }
    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        StylizeKit.perPixel(src, out, ctx) { 1 - $0 }
    }
    public func encodeGPU(_ pass: GPUPass) throws {
        try pass.dispatchOut("pca_sty_per_pixel", params: PerPixelParams(op: 0))
    }
}

/// MSL `pca_sty_per_pixel_params` (op 0 invert, 1 solarize).
private struct PerPixelParams: BitwiseCopyable {
    var op: Int32
    var pad0: Int32 = 0
    var pad1: Int32 = 0
    var pad2: Int32 = 0
}

extension StylizeKit {
    /// stylize `per_pixel`: colour channels through `f`, alpha untouched.
    static func perPixel(_ src: FloatImage, _ out: PixelRect, _ ctx: FilterContext, _ f: (Float) -> Float) -> FloatImage {
        let n = src.channels, cc = ctx.colorChannels(n)
        var res = src.crop(out)
        if n == 0 { return res }
        let count = out.area
        res.withStyOut { d in
            parallelChunks(count, minChunk: 1 << 14) { r in
                for i in r { for c in 0..<cc { d.value[i * n + c] = f(d.value[i * n + c]) } }
            }
        }
        return res
    }
}

// MARK: - Desaturate

/// Image › Adjustments › Desaturate as photocraft's filter entry: the colour replaced by its
/// Rec. 601 luma (through RGB) in the document's own model.
public struct Desaturate: Filter, Hashable {
    public init() {}
    public var label: String { "Desaturate" }
    public func halo(bounds: PixelRect) -> Halo { .radius(0) }
    public var gpuChannels: GPUChannels { .joint }
    public func supportsGPU(_ ctx: FilterContext, channels: Int) -> Bool {
        StylizeKit.rgbLumaCode(ctx) != nil && StylizeKit.onePlane(ctx, channels: channels)
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let n = src.channels
        var res = src.crop(out)
        if n == 0 { return res }
        let count = out.area
        res.withStyOut { d in
            parallelChunks(count, minChunk: 1 << 13) { r in
                for i in r {
                    let px = UnsafeMutableBufferPointer(start: d.value + i * n, count: n)
                    let g = ctx.lumaViaRGB(UnsafeBufferPointer(px))
                    StylizeKit.setGray(ctx, px, g)
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        try pass.dispatchOut("pca_sty_desaturate", params: EmbossParams(d: .zero, k: 0, luma: StylizeKit.rgbLumaCode(pass.ctx) ?? 1))
    }
}
