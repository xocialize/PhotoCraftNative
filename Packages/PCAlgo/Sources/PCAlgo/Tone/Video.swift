// Port of photocraft-algo (crates/algo/src/video.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Video: De-Interlace and NTSC Colors.

import PCFoundation

/// Filter › Video › De-Interlace: removes one field (odd = lines 1, 3, 5… counted from the bounds'
/// top, i.e. even offsets) and rebuilds it from the neighbouring kept lines by duplication or
/// (premultiplied) interpolation.
public struct DeInterlace: Filter, Hashable {
    /// Eliminate the even lines (else the odd ones).
    public var eliminateEven: Bool
    /// Rebuild by interpolation (else duplication).
    public var interpolate: Bool

    /// photocraft-engine's dialog defaults: eliminate Odd Fields, create by Interpolation.
    public init(eliminateEven: Bool = false, interpolate: Bool = true) {
        self.eliminateEven = eliminateEven; self.interpolate = interpolate
    }

    public var label: String { "De-Interlace" }
    public func halo(bounds: PixelRect) -> Halo { .reach(1) }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        var res = src.crop(out)
        let n = src.channels, b = ctx.bounds, alpha = ctx.alpha
        let (eliminateEven, interpolate) = (self.eliminateEven, self.interpolate)
        res.data.withUnsafeMutableBufferPointer { buf in
            let rb = UnsafeSendable(buf)
            parallelChunks(out.height, minChunk: 8) { rows in
                var acc = [Float](repeating: 0, count: n)
                for oy in rows {
                    let y = out.y0 + Int32(oy)
                    if y < b.y0 || y >= b.y1 { continue }
                    // 1-based line number parity: offset 0 is line 1 (odd).
                    let oddLine = (y - b.y0) % 2 == 0
                    if oddLine == eliminateEven { continue }
                    let above: Int32? = y > b.y0 ? y - 1 : nil
                    let below: Int32? = y + 1 < b.y1 ? y + 1 : nil
                    let rows: [Int32]
                    if interpolate, let a = above, let c = below { rows = [a, c] }
                    else if let a = above { rows = [a] }
                    else if let c = below { rows = [c] }
                    else { continue }
                    let k = 1 / Float(rows.count)
                    for ox in 0..<out.width {
                        let x = out.x0 + Int32(ox)
                        if x < b.x0 || x >= b.x1 { continue }
                        for c in 0..<n { acc[c] = 0 }
                        for yy in rows {
                            let a: Float = alpha ? src.get(x, yy, n - 1) : 1
                            for c in 0..<n {
                                let s = src.get(x, yy, c)
                                acc[c] += (alpha && c < n - 1 ? s * a : s) * k
                            }
                        }
                        FxUtil.unpremulPx(&acc, alpha)
                        let d = (oy * out.width + ox) * n
                        for c in 0..<n { rb.value[d + c] = acc[c] }
                    }
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        try pass.dispatchOut("pca_tone_deinterlace",
                             params: ToneKit.DeinterlaceParams(eliminateEven: eliminateEven ? 1 : 0, interpolate: interpolate ? 1 : 0))
    }
}

/// Filter › Video › NTSC Colors: scales chroma (in YIQ) so the composite signal Y ± C stays within
/// broadcast limits (−20…120 IRE); hue and luma are kept.
public struct NTSCColors: Filter, Hashable {
    public init() {}
    public var label: String { "NTSC Colors" }
    public func halo(bounds: PixelRect) -> Halo { .radius(0) }
    public var gpuChannels: GPUChannels { .joint }

    /// Composite-signal limits (fractions of the 7.5–100 IRE luma range).
    static let ntscMax: Float = (120.0 - 7.5) / 92.5
    static let ntscMin: Float = (-20.0 - 7.5) / 92.5

    /// The broadcast-safe RGB of `c`, or nil when it is already safe (photocraft `ntsc`'s body).
    @inline(__always)
    static func limit(_ c: SIMD3<Float>) -> SIMD3<Float>? {
        let yy = 0.299 * c.x + 0.587 * c.y + 0.114 * c.z
        let ii = 0.595_716 * c.x - 0.274_453 * c.y - 0.321_263 * c.z
        let qq = 0.211_456 * c.x - 0.522_591 * c.y + 0.311_135 * c.z
        let chroma = (ii * ii + qq * qq).squareRoot()
        if chroma <= 1e-7 { return nil }
        var k: Float = 1
        if yy + chroma > ntscMax { k = Float.minimum(k, Float.maximum((ntscMax - yy) / chroma, 0)) }
        if yy - chroma < ntscMin { k = Float.minimum(k, Float.maximum((yy - ntscMin) / chroma, 0)) }
        if k >= 1 { return nil }
        let i2 = ii * k, q2 = qq * k
        return SIMD3(yy + 0.956_3 * i2 + 0.621_0 * q2, yy - 0.272_1 * i2 - 0.647_4 * q2, yy - 1.107_0 * i2 + 1.704_6 * q2)
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        var res = src.crop(out)
        let n = src.channels
        let native = ctx.mode == .rgb
        res.data.withUnsafeMutableBufferPointer { buf in
            let b = UnsafeSendable(buf)
            parallelChunks(out.area, minChunk: 4096) { r in
                for i in r {
                    let px = UnsafeMutableBufferPointer(rebasing: b.value[(i * n)..<(i * n + n)])
                    let c: SIMD4<Float> = native ? SIMD4(px[0], px[1], px[2], 1) : ctx.rgba(UnsafeBufferPointer(px))
                    guard let rgb = Self.limit(SIMD3(c.x, c.y, c.z)) else { continue }
                    if native { px[0] = rgb.x; px[1] = rgb.y; px[2] = rgb.z }
                    else { ctx.setRGBA(px, SIMD4(rgb, c.w)) }
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        try pass.dispatchOut("pca_tone_ntsc", params: ToneKit.NtscParams(ntscMax: Self.ntscMax, ntscMin: Self.ntscMin))
    }
}

extension ToneKit {
    /// MSL `pca_tone_deinterlace_params`.
    struct DeinterlaceParams: BitwiseCopyable {
        var eliminateEven: UInt32
        var interpolate: UInt32
        var pad0: UInt32 = 0
        var pad1: UInt32 = 0
    }

    /// MSL `pca_tone_ntsc_params`.
    struct NtscParams: BitwiseCopyable {
        var ntscMax: Float
        var ntscMin: Float
        var pad0: UInt32 = 0
        var pad1: UInt32 = 0
    }
}
