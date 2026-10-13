// Surface ⇄ CGImage at the native depth and colour model, straight alpha, plus EXIF orientation.
// Replaces photocraft-codecs' flat `Image` buffer plumbing (crates/codecs/src/image.rs) and its
// `orientation` module (crates/codecs/src/orientation.rs) with vImage + CoreGraphics. Port of its API
// shape, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Conventions (photocraft's, kept): samples are interleaved, row-major, top-to-bottom, native byte
// order; alpha is straight (not premultiplied) and last; CMYK samples are ink amounts (1 = full ink).
// CoreGraphics draws only premultiplied alpha, so every CGImage → bytes conversion goes through
// vImage's converter (`vImage_Buffer(cgImage:format:)`), which un-premultiplies and changes byte
// order and depth without touching the colour space. Half-float sources widen to f32 (PCFoundation's
// `SampleType` has no f16). `PCPixelFormat` is PCFoundation's `PixelFormat` (Accelerate has its own).

import Accelerate
import CoreGraphics
import Foundation
import PCFoundation

/// A flat interleaved raster (photocraft-codecs `Image`): `width × height × format.bytesPerPixel`
/// bytes, native byte order, straight alpha.
public struct RasterBuffer: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var format: PCPixelFormat
    public var bytes: [UInt8]

    public init(width: Int, height: Int, format: PCPixelFormat, bytes: [UInt8]) {
        precondition(bytes.count == width * height * format.bytesPerPixel, "RasterBuffer: byte count mismatch")
        self.width = width; self.height = height; self.format = format; self.bytes = bytes
    }

    /// A zero-filled raster.
    public init(width: Int, height: Int, format: PCPixelFormat) {
        self.init(width: width, height: height, format: format,
                  bytes: [UInt8](repeating: 0, count: width * height * format.bytesPerPixel))
    }

    /// The pixels of `rect` of a surface.
    public init(surface: Surface, rect: PixelRect) {
        self.init(width: rect.width, height: rect.height, format: surface.format, bytes: surface.readInterleaved(rect))
    }

    public var rect: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }

    /// A surface holding these pixels at `origin`.
    public func surface(origin: (x: Int, y: Int) = (0, 0)) -> Surface {
        var s = Surface(format: format)
        if width > 0 && height > 0 {
            s.writeInterleaved(PixelRect(x: origin.x, y: origin.y, width: width, height: height), bytes)
        }
        return s
    }

    /// Normalised float samples (`width × height × channels`).
    public func floats() -> [Float] {
        let n = width * height * format.channels
        var out = [Float](repeating: 0, count: n)
        bytes.withUnsafeBytes { b in for i in 0..<n { out[i] = readSample(b, format.sample, i) } }
        return out
    }

    /// A raster from normalised float samples (integer targets are clamped and rounded).
    public init(width: Int, height: Int, format: PCPixelFormat, floats: [Float]) {
        var b = [UInt8](repeating: 0, count: width * height * format.bytesPerPixel)
        let n = width * height * format.channels
        precondition(floats.count >= n, "RasterBuffer: float count mismatch")
        b.withUnsafeMutableBytes { p in for i in 0..<n { writeSample(p, format.sample, i, floats[i]) } }
        self.init(width: width, height: height, format: format, bytes: b)
    }

    /// The same pixels at another sample type (same model and alpha).
    public func converted(to sample: SampleType) -> RasterBuffer {
        if sample == format.sample { return self }
        return RasterBuffer(width: width, height: height, format: format.with(sample: sample), floats: floats())
    }
}

/// Conversions between PCFoundation pixel data and CoreGraphics images.
public enum SurfaceBridge {

    // MARK: Colour spaces

    /// The colour space a document of `mode` is tagged with when it carries no profile: sRGB,
    /// Gray Gamma 2.2, Generic CMYK, CIE Lab D50 (photocraft's defaults except gray, where
    /// photocraft's own "sGray" is `BuiltinProfile.sGray`).
    public static func defaultColorSpace(for mode: ColorMode) -> CGColorSpace {
        switch mode {
        case .rgb, .indexed, .multichannel: CGColorSpace(name: CGColorSpace.sRGB)!
        case .grayscale, .bitmap, .duotone: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        case .cmyk: CGColorSpace(name: CGColorSpace.genericCMYK)!
        case .lab: labD50
        }
    }

    /// CIE L*a*b* with the D50 white and the full ±128 a/b range.
    public static let labD50: CGColorSpace = CGColorSpace(
        labWhitePoint: [0.9642, 1.0, 0.8249], blackPoint: [0, 0, 0], range: [-128, 127, -128, 127])!

    /// The document colour model a colour space stores.
    public static func colorMode(for space: CGColorSpace) -> ColorMode? {
        switch space.model {
        case .monochrome: .grayscale
        case .rgb: .rgb
        case .cmyk: .cmyk
        case .lab: .lab
        default: nil
        }
    }

    // MARK: CGImage → pixels

    /// The pixel format a CGImage decodes to without colour conversion. Indexed images expand to
    /// their base model, 1/2/4-bit to 8-bit, 10/12-bit to 16-bit, half and 32-bit integer to f32.
    public static func pixelFormat(of image: CGImage) -> PCPixelFormat {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let base = space.model == .indexed ? (space.baseColorSpace ?? space) : space
        let mode = colorMode(for: base) ?? .rgb
        let alpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: alpha = false
        case .alphaOnly: alpha = false
        default: alpha = true
        }
        let isFloat = image.bitmapInfo.contains(.floatComponents)
        let sample: SampleType
        if isFloat || image.bitsPerComponent > 16 || mode == .lab { sample = .f32 }
        else if image.bitsPerComponent > 8 { sample = .u16 }
        else { sample = .u8 }
        return PCPixelFormat(mode: mode, sample: sample, alpha: alpha)
    }

    /// The colour space pixels of `image` are expressed in once decoded (indexed → base; models
    /// PCFoundation cannot store (XYZ, DeviceN…) → sRGB, converted).
    public static func storageColorSpace(of image: CGImage) -> CGColorSpace {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model == .indexed, let b = space.baseColorSpace { return b }
        if colorMode(for: space) == nil { return CGColorSpace(name: CGColorSpace.sRGB)! }
        return space
    }

    /// vImage's description of `format` in `space` (straight alpha last, native byte order).
    static func cgFormat(_ format: PCPixelFormat, space: CGColorSpace) -> vImage_CGImageFormat? {
        let bpc = format.sample.bits
        var info = CGBitmapInfo(rawValue: (format.alpha ? CGImageAlphaInfo.last : .none).rawValue)
        switch format.sample {
        case .u8: break
        case .u16: info.insert(.byteOrder16Little)
        case .f32: info.insert([.byteOrder32Little, .floatComponents])
        }
        return vImage_CGImageFormat(bitsPerComponent: bpc, bitsPerPixel: bpc * format.channels,
                                    colorSpace: space, bitmapInfo: info)
    }

    /// Decodes `image` to a flat raster at its native depth and model (see `pixelFormat(of:)`), or
    /// at `format` when given (depth/alpha changes only; the model must match). Lab is stored
    /// normalised as PCFoundation's `PCColor` stores it: L/100, (a+128)/255, (b+128)/255.
    public static func raster(from image: CGImage, as format: PCPixelFormat? = nil) throws -> RasterBuffer {
        let native = pixelFormat(of: image)
        var target = format ?? native
        if target.mode != native.mode { throw PlatformError.invalidArgument("raster(from:as:) cannot change the colour model") }
        let space = storageColorSpace(of: image)
        let isLab = target.mode == .lab
        if isLab { target = target.with(sample: .f32) }
        guard let fmt = cgFormat(target, space: space) else {
            throw PlatformError.decodeFailed("no vImage format for \(target)")
        }
        var buf: vImage_Buffer
        do { buf = try vImage_Buffer(cgImage: image, format: fmt) } catch {
            // vImage refuses some packed layouts ImageIO produces (e.g. HEIF's 10-bit RGB in 32-bit
            // words); CoreGraphics can still draw them.
            return try rasterByDrawing(image, as: target, space: space)
        }
        defer { buf.free() }
        let w = Int(buf.width), h = Int(buf.height), bpp = target.bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: w * h * bpp)
        bytes.withUnsafeMutableBytes { dst in
            for y in 0..<h {
                dst.baseAddress!.advanced(by: y * w * bpp)
                    .copyMemory(from: buf.data.advanced(by: y * buf.rowBytes), byteCount: w * bpp)
            }
        }
        var out = RasterBuffer(width: w, height: h, format: target, bytes: bytes)
        if isLab {
            // CoreGraphics float Lab is L 0…100, a/b in the space's range; normalise.
            var f = out.floats()
            let ch = target.channels
            for i in stride(from: 0, to: f.count, by: ch) {
                f[i] /= 100; f[i + 1] = (f[i + 1] + 128) / 255; f[i + 2] = (f[i + 2] + 128) / 255
            }
            out = RasterBuffer(width: w, height: h, format: target, floats: f)
            if let format, format.sample != .f32 { out = out.converted(to: format.sample) }
        }
        return out
    }

    /// Fallback decode: draw into a CGContext of the target depth (premultiplied, as CoreGraphics
    /// draws) and un-premultiply.
    static func rasterByDrawing(_ image: CGImage, as target: PCPixelFormat, space: CGColorSpace) throws -> RasterBuffer {
        let w = image.width, h = image.height
        let ch = target.channels, bps = target.sample.bytes
        var info = CGBitmapInfo(rawValue: (target.alpha ? CGImageAlphaInfo.premultipliedLast : .none).rawValue)
        switch target.sample {
        case .u8: break
        case .u16: info.insert(.byteOrder16Little)
        case .f32: info.insert([.byteOrder32Little, .floatComponents])
        }
        // CoreGraphics has no RGB/CMYK context without alpha at 16-bit float…; pad RGB to RGBX.
        let padded = !target.alpha && target.mode.colorChannels == 3
        let ctxCh = padded ? 4 : ch
        if padded { info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | (info.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue)) }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: target.sample.bits, bytesPerRow: w * ctxCh * bps,
                                  space: space, bitmapInfo: info.rawValue), let data = ctx.data else {
            throw PlatformError.decodeFailed("no CoreGraphics context for a \(image.bitsPerComponent)-bit \(space.model) image")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let raw = UnsafeRawBufferPointer(start: data, count: w * h * ctxCh * bps)
        var f = [Float](repeating: 0, count: w * h * ch)
        for i in 0..<(w * h) {
            for k in 0..<ch { f[i * ch + k] = readSample(raw, target.sample, i * ctxCh + k) }
            if target.alpha {
                let a = f[i * ch + ch - 1]
                for k in 0..<(ch - 1) { f[i * ch + k] = a > 0 ? f[i * ch + k] / a : 0 }
            }
        }
        return RasterBuffer(width: w, height: h, format: target, floats: f)
    }

    /// Decodes `image` into a surface at `origin`.
    public static func surface(from image: CGImage, origin: (x: Int, y: Int) = (0, 0)) throws -> Surface {
        try raster(from: image).surface(origin: origin)
    }

    // MARK: Pixels → CGImage

    /// A CGImage over a raster (straight alpha, native byte order) tagged with `space` (the mode's
    /// default when nil).
    public static func cgImage(_ raster: RasterBuffer, colorSpace: CGColorSpace? = nil) throws -> CGImage {
        var raster = raster
        let space: CGColorSpace
        if raster.format.mode == .lab {
            // Denormalise to CoreGraphics' float Lab.
            raster = raster.converted(to: .f32)
            var f = raster.floats()
            let ch = raster.format.channels
            for i in stride(from: 0, to: f.count, by: ch) {
                f[i] *= 100; f[i + 1] = f[i + 1] * 255 - 128; f[i + 2] = f[i + 2] * 255 - 128
            }
            raster = RasterBuffer(width: raster.width, height: raster.height, format: raster.format, floats: f)
            space = colorSpace ?? labD50
        } else {
            space = colorSpace ?? defaultColorSpace(for: raster.format.mode)
        }
        if space.numberOfComponents != raster.format.mode.colorChannels {
            throw PlatformError.invalidArgument("colour space has \(space.numberOfComponents) components, pixels \(raster.format.mode.colorChannels)")
        }
        guard let fmt = cgFormat(raster.format, space: space) else { throw PlatformError.encodeFailed("no CG format for \(raster.format)") }
        let data = Data(raster.bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let img = CGImage(width: raster.width, height: raster.height, bitsPerComponent: Int(fmt.bitsPerComponent),
                                bitsPerPixel: Int(fmt.bitsPerPixel), bytesPerRow: raster.width * raster.format.bytesPerPixel,
                                space: space, bitmapInfo: fmt.bitmapInfo, provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent)
        else { throw PlatformError.encodeFailed("CGImage(\(raster.width)×\(raster.height) \(raster.format))") }
        return img
    }

    /// A CGImage of `rect` of a surface.
    public static func cgImage(_ surface: Surface, rect: PixelRect, colorSpace: CGColorSpace? = nil) throws -> CGImage {
        try cgImage(RasterBuffer(surface: surface, rect: rect), colorSpace: colorSpace)
    }

    /// Renders any CGImage into an 8-bit straight RGBA sRGB raster (colour-managed by CoreGraphics),
    /// for consumers that only take 8-bit sRGB (webp-swift, Vision).
    public static func rgba8sRGB(_ image: CGImage) throws -> RasterBuffer {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let fmt = cgFormat(.rgba8, space: srgb) else { throw PlatformError.frameworkFailure("format") }
        var buf: vImage_Buffer
        do { buf = try vImage_Buffer(cgImage: image, format: fmt) } catch {
            throw PlatformError.decodeFailed("vImage → RGBA8: \(error)")
        }
        defer { buf.free() }
        let w = Int(buf.width), h = Int(buf.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { dst in
            for y in 0..<h {
                dst.baseAddress!.advanced(by: y * w * 4).copyMemory(from: buf.data.advanced(by: y * buf.rowBytes), byteCount: w * 4)
            }
        }
        return RasterBuffer(width: w, height: h, format: .rgba8, bytes: bytes)
    }

    // MARK: Orientation

    /// The pixels turned upright for EXIF/TIFF orientation `orientation` (1–8; anything else is
    /// treated as 1). Orientations 5–8 swap width and height. Pure index remapping: lossless at any
    /// depth (photocraft `Image::oriented`).
    public static func oriented(_ r: RasterBuffer, orientation: Int) -> RasterBuffer {
        guard (2...8).contains(orientation) else { return r }
        let w = r.width, h = r.height, bpp = r.format.bytesPerPixel
        let swap = orientation >= 5
        let ow = swap ? h : w, oh = swap ? w : h
        var out = [UInt8](repeating: 0, count: r.bytes.count)
        r.bytes.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                for v in 0..<oh {
                    for u in 0..<ow {
                        let (sx, sy): (Int, Int)
                        switch orientation {
                        case 2: (sx, sy) = (w - 1 - u, v)
                        case 3: (sx, sy) = (w - 1 - u, h - 1 - v)
                        case 4: (sx, sy) = (u, h - 1 - v)
                        case 5: (sx, sy) = (v, u)
                        case 6: (sx, sy) = (v, h - 1 - u)
                        case 7: (sx, sy) = (w - 1 - v, h - 1 - u)
                        default: (sx, sy) = (w - 1 - v, u)   // 8
                        }
                        dst.baseAddress!.advanced(by: (v * ow + u) * bpp)
                            .copyMemory(from: src.baseAddress!.advanced(by: (sy * w + sx) * bpp), byteCount: bpp)
                    }
                }
            }
        }
        return RasterBuffer(width: ow, height: oh, format: r.format, bytes: out)
    }
}
