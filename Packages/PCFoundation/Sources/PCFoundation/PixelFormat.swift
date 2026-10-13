// Pixel formats and colour models. Bit depth and colour model are runtime data: nothing in the
// engine assumes 8-bit or RGB (photocraft architecture §1.1).
// Port of photocraft-color (crates/color/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

/// Storage type of one channel sample.
public enum SampleType: UInt8, CaseIterable, Sendable, Codable {
    case u8, u16, f32

    public var bytes: Int {
        switch self { case .u8: 1; case .u16: 2; case .f32: 4 }
    }
    public var bits: Int { bytes * 8 }
    /// 32-bit float documents are HDR: values above 1 are valid light.
    public var isHDR: Bool { self == .f32 }
}

/// Document colour model (Photoshop Image ▸ Mode).
public enum ColorMode: UInt8, CaseIterable, Sendable, Codable {
    case bitmap, grayscale, indexed, rgb, cmyk, lab, multichannel, duotone

    /// Colour (non-alpha) channels used for pixel storage. Indexed and Bitmap documents are stored
    /// expanded (RGB / Gray) for editing; Multichannel carries its count separately (default 3).
    public var colorChannels: Int {
        switch self {
        case .bitmap, .grayscale, .duotone: 1
        case .indexed, .rgb, .lab, .multichannel: 3
        case .cmyk: 4
        }
    }

    /// The PSD header's colour-mode code.
    public var psdCode: UInt16 {
        switch self {
        case .bitmap: 0; case .grayscale: 1; case .indexed: 2; case .rgb: 3
        case .cmyk: 4; case .multichannel: 7; case .duotone: 8; case .lab: 9
        }
    }

    public init?(psdCode: UInt16) {
        switch psdCode {
        case 0: self = .bitmap; case 1: self = .grayscale; case 2: self = .indexed; case 3: self = .rgb
        case 4: self = .cmyk; case 7: self = .multichannel; case 8: self = .duotone; case 9: self = .lab
        default: return nil
        }
    }

    /// Modes whose stored channels are RGB.
    public var isRGBLike: Bool { self == .rgb || self == .indexed || self == .multichannel }
    /// Modes whose stored channel is a single grey.
    public var isGrayLike: Bool { self == .grayscale || self == .bitmap || self == .duotone }
}

/// `PixelFormat` disambiguated from Accelerate's type of the same name.
public typealias PCPixelFormat = PixelFormat

/// Layout of a pixel: colour model, sample type, and whether an alpha channel follows the colour
/// channels. Samples are interleaved, alpha last.
public struct PixelFormat: Hashable, Sendable, Codable {
    public var mode: ColorMode
    public var sample: SampleType
    public var alpha: Bool

    public init(mode: ColorMode, sample: SampleType, alpha: Bool) {
        self.mode = mode; self.sample = sample; self.alpha = alpha
    }

    public static let rgba8 = PixelFormat(mode: .rgb, sample: .u8, alpha: true)
    public static let rgba16 = PixelFormat(mode: .rgb, sample: .u16, alpha: true)
    public static let rgba32f = PixelFormat(mode: .rgb, sample: .f32, alpha: true)
    public static let gray8 = PixelFormat(mode: .grayscale, sample: .u8, alpha: false)
    public static let graya8 = PixelFormat(mode: .grayscale, sample: .u8, alpha: true)
    public static let gray16 = PixelFormat(mode: .grayscale, sample: .u16, alpha: false)
    public static let gray32f = PixelFormat(mode: .grayscale, sample: .f32, alpha: false)
    public static let cmyka8 = PixelFormat(mode: .cmyk, sample: .u8, alpha: true)

    public var channels: Int { mode.colorChannels + (alpha ? 1 : 0) }
    public var bytesPerPixel: Int { channels * sample.bytes }
    public func with(sample: SampleType) -> PixelFormat { PixelFormat(mode: mode, sample: sample, alpha: alpha) }
    public func with(alpha: Bool) -> PixelFormat { PixelFormat(mode: mode, sample: sample, alpha: alpha) }
}

// MARK: - Sample codec

/// Reads sample `index` (a sample index, not a byte index) as a normalised Float.
/// U8/U16 map to [0, 1]; F32 is returned as stored. Native byte order.
@inlinable
public func readSample(_ bytes: UnsafeRawBufferPointer, _ sample: SampleType, _ index: Int) -> Float {
    switch sample {
    case .u8: return Float(bytes[index]) / 255
    case .u16: return Float(bytes.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self)) / 65535
    case .f32: return bytes.loadUnaligned(fromByteOffset: index * 4, as: Float.self)
    }
}

/// Writes a normalised Float sample; integer types are clamped and rounded half up, and NaN
/// saturates to 0 (Rust's `as` cast, which photocraft relies on).
@inlinable
public func writeSample(_ bytes: UnsafeMutableRawBufferPointer, _ sample: SampleType, _ index: Int, _ v: Float) {
    // `v <= 0 ? 0 : (v > 1 ? 1 : v)` is `min(max(v, 0), 1)` for every non-NaN value, without the
    // generic calls a Debug build makes for `min`/`max`.
    switch sample {
    case .u8:
        bytes[index] = v.isNaN ? 0 : UInt8((v <= 0 ? 0 : (v > 1 ? 1 : v)) * 255 + 0.5)
    case .u16:
        bytes.storeBytes(of: v.isNaN ? 0 : UInt16((v <= 0 ? 0 : (v > 1 ? 1 : v)) * 65535 + 0.5), toByteOffset: index * 2, as: UInt16.self)
    case .f32:
        bytes.storeBytes(of: v, toByteOffset: index * 4, as: Float.self)
    }
}

/// Encodes one pixel of normalised floats into `format`'s bytes (missing channels encode 0).
public func encodePixel(_ format: PixelFormat, _ px: [Float]) -> [UInt8] {
    let ch = format.channels
    var src = px
    if src.count < ch { src += [Float](repeating: 0, count: ch - src.count) }
    var out = [UInt8](repeating: 0, count: format.bytesPerPixel)
    out.withUnsafeMutableBytes { b in
        src.withUnsafeBufferPointer { s in SampleRun.encode(s.baseAddress!, format.sample, b.baseAddress!, ch) }
    }
    return out
}

/// Decodes one pixel of `format`'s bytes into normalised floats.
public func decodePixel(_ format: PixelFormat, _ bytes: [UInt8]) -> [Float] {
    let ch = format.channels
    precondition(bytes.count >= format.bytesPerPixel, "decodePixel: too few bytes")
    return [Float](unsafeUninitializedCapacity: ch) { out, n in
        bytes.withUnsafeBytes { b in SampleRun.decode(b.baseAddress!, format.sample, out.baseAddress!, ch) }
        n = ch
    }
}

extension PixelFormat {
    /// The channel values of an RGBA colour (sRGB, 0...1) in this format's model, alpha last when
    /// the format has one (photocraft-raster `from_rgba`).
    public func components(fromRGBA rgba: SIMD4<Float>) -> [Float] {
        let rgb = SIMD3(rgba.x, rgba.y, rgba.z)
        var out: [Float]
        switch mode {
        case .grayscale, .bitmap, .duotone: out = [ColorConvert.rgbToGray(rgb)]
        case .cmyk:
            let c = ColorConvert.rgbToCMYK(rgb)
            out = [c.x, c.y, c.z, c.w]
        case .lab:
            let l = ColorConvert.srgbToLab(rgb)
            out = [l.x / 100, (l.y + 128) / 255, (l.z + 128) / 255]
        case .rgb, .indexed, .multichannel: out = [rgb.x, rgb.y, rgb.z]
        }
        if alpha { out.append(rgba.w) }
        return out
    }
}
