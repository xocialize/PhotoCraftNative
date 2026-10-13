// Port of photocraft-paint (crates/paint/src/retouch.rs, plus photocraft-raster's to_rgba / from_rgba), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Native-channel pixel helpers every compositing path shares: the RGBA ⇄ native conversions of
// any colour model (through PCFoundation's ColorConvert), Normal-mode "over" in native channels,
// and Surface conveniences photocraft-raster has and PCFoundation spells differently.

import PCFoundation

/// Index of the alpha channel, if the format has one.
@inline(__always) public func alphaIndex(_ fmt: PixelFormat) -> Int? {
    fmt.alpha ? fmt.mode.colorChannels : nil
}

/// Straight RGBA of one native pixel (photocraft-raster `to_rgba`).
@inline(__always) public func toRGBA(_ fmt: PixelFormat, _ px: UnsafePointer<Float>) -> SIMD4<Float> {
    let n = fmt.mode.colorChannels
    let a: Float = fmt.alpha ? px[n] : 1
    switch fmt.mode {
    case .grayscale, .bitmap, .duotone: return SIMD4(px[0], px[0], px[0], a)
    case .cmyk: return SIMD4(ColorConvert.cmykToRGB(SIMD4(px[0], px[1], px[2], px[3])), a)
    case .lab: return SIMD4(ColorConvert.labToSRGB(SIMD3(px[0] * 100, px[1] * 255 - 128, px[2] * 255 - 128)), a)
    case .rgb, .indexed, .multichannel: return SIMD4(px[0], px[1], px[2], a)
    }
}

public func toRGBA(_ fmt: PixelFormat, _ px: [Float]) -> SIMD4<Float> {
    px.withUnsafeBufferPointer { toRGBA(fmt, $0.baseAddress!) }
}

/// Native channels of a straight RGBA colour, written to `out`; returns the channel count
/// (photocraft-raster `from_rgba_into`).
@inline(__always) @discardableResult
public func fromRGBA(_ fmt: PixelFormat, _ rgba: SIMD4<Float>, into out: UnsafeMutablePointer<Float>) -> Int {
    let rgb = SIMD3(rgba.x, rgba.y, rgba.z)
    let n: Int
    switch fmt.mode {
    case .grayscale, .bitmap, .duotone:
        out[0] = ColorConvert.rgbToGray(rgb)
        n = 1
    case .cmyk:
        let c = ColorConvert.rgbToCMYK(rgb)
        out[0] = c.x; out[1] = c.y; out[2] = c.z; out[3] = c.w
        n = 4
    case .lab:
        let l = ColorConvert.srgbToLab(rgb)
        out[0] = l.x / 100; out[1] = (l.y + 128) / 255; out[2] = (l.z + 128) / 255
        n = 3
    case .rgb, .indexed, .multichannel:
        out[0] = rgb.x; out[1] = rgb.y; out[2] = rgb.z
        n = 3
    }
    if fmt.alpha {
        out[n] = rgba.w
        return n + 1
    }
    return n
}

/// photocraft-raster `from_rgba`.
public func fromRGBA(_ fmt: PixelFormat, _ rgba: SIMD4<Float>) -> [Float] {
    var out = [Float](repeating: 0, count: 8)
    let n = out.withUnsafeMutableBufferPointer { fromRGBA(fmt, rgba, into: $0.baseAddress!) }
    return Array(out[0..<n])
}

/// Normal-mode "source over destination" at coverage `k`, in native channels (channel-agnostic, so
/// it works for RGB, Gray, CMYK, Lab… at any depth).
@inline(__always)
public func overNative(_ fmt: PixelFormat, _ dst: UnsafeMutablePointer<Float>, _ src: UnsafePointer<Float>, _ k: Float, _ lockTransparency: Bool) {
    if let a = alphaIndex(fmt) {
        let da = dst[a], sa = src[a] * k
        let oa = sa + da * (1 - sa)
        if oa > 0 {
            for c in 0..<a { dst[c] = (src[c] * sa + dst[c] * da * (1 - sa)) / oa }
        }
        if !lockTransparency { dst[a] = oa }
    } else {
        for c in 0..<fmt.channels { dst[c] += (src[c] - dst[c]) * k }
    }
}

public func overNative(_ fmt: PixelFormat, _ dst: inout [Float], _ src: [Float], _ k: Float, _ lockTransparency: Bool) {
    dst.withUnsafeMutableBufferPointer { d in
        src.withUnsafeBufferPointer { s in overNative(fmt, d.baseAddress!, s.baseAddress!, k, lockTransparency) }
    }
}

extension Surface {
    /// Composite-friendly RGBA read (converts from the surface's model).
    public func rgba(_ x: Int32, _ y: Int32) -> SIMD4<Float> { toRGBA(format, pixel(x: x, y: y)) }

    /// Fills `r` with `px` (photocraft `fill_rect`).
    public mutating func fillRect(_ r: PixelRect, _ px: [Float]) { fill(r, with: px) }

    /// `writeRegion` that cannot trap: integer formats store NaN as 0, as photocraft's saturating
    /// `as` cast does (PCFoundation's `writeSample` would trap converting NaN).
    public mutating func writeRegionSafe(_ r: PixelRect, _ data: inout [Float]) {
        if r.isEmpty { return }
        if format.sample != .f32 {
            data.withUnsafeMutableBufferPointer { d in
                for i in 0..<min(d.count, r.area * format.channels) where d[i].isNaN { d[i] = 0 }
            }
        }
        writeRegion(r, data)
    }

    /// `readRegion` into a reused buffer (resized to fit).
    public func readRegionReusing(_ r: PixelRect, _ out: inout [Float]) {
        let n = r.area * format.channels
        if out.count != n { out = [Float](repeating: 0, count: n) }
        if n > 0 { readRegion(r, into: &out) }
    }

    /// Channel 0 of `r` (selection masks), one value per pixel.
    public func readChannel0(_ r: PixelRect) -> [Float] {
        let ch = format.channels
        if r.isEmpty { return [] }
        let all = readRegion(r)
        if ch == 1 { return all }
        return (0..<r.area).map { all[$0 * ch] }
    }
}
