// CGImage ⇄ Surface bridging for the fleet Kits (photocraft gap G15: the planned `ml` crate's image
// I/O). The Kits speak CGImage in RGB; documents hold tiled surfaces at any depth and colour model.
// Pixels go out through RGB at the document's depth (8-bit, 16-bit or 32-bit float components)
// tagged with the document's colour space, and come back into the document's own model. Masks are
// coverage, not colour: they are decoded raw, never colour-managed. Data model after photocraft-raster
// and photocraft-color, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import ImageIO
import PCDocument
import PCFoundation
import UniformTypeIdentifiers

/// What a bridged image does with the source's alpha channel.
public enum AlphaHandling: Sendable, Equatable {
    /// Straight (non-premultiplied) alpha travels with the image.
    case keep
    /// Alpha is dropped: colours as stored, the image is opaque.
    case opaque
    /// Colours are composited over a solid colour (encoded RGB, 0…1) and the image is opaque, for
    /// analysis Kits (segmentation) that must not see the colour hidden under transparency.
    case flatten(over: SIMD3<Float>)
}

/// A bridging failure: an image the bridge cannot build or read.
public struct KitBridgeError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Conversions between document surfaces and the CGImages the Kits consume and return.
public enum KitBridge {

    // MARK: Colour spaces

    /// The colour space a document's pixels are expressed in when they cross to a Kit.
    ///
    /// RGB-like documents keep their embedded profile (pixels go out as stored, so the Kit's own
    /// colour management sees the right primaries); without one they are sRGB, extended sRGB at 32
    /// bits so HDR values above 1 survive. Grayscale, CMYK and Lab documents go out as sRGB, because
    /// `Surface.readRGBA` converts them to encoded sRGB first.
    public static func colorSpace(for mode: ColorMode, sample: SampleType, iccProfile: [UInt8]?) -> CGColorSpace {
        if mode.isRGBLike, let icc = iccProfile, !icc.isEmpty,
           let cs = CGColorSpace(iccData: Data(icc) as CFData), cs.model == .rgb {
            return cs
        }
        return defaultColorSpace(sample: sample)
    }

    /// The bridge colour space for `document`'s pixels.
    public static func colorSpace(for document: Document) -> CGColorSpace {
        colorSpace(for: document.mode, sample: document.depth, iccProfile: document.iccProfile)
    }

    /// sRGB, or extended sRGB for 32-bit float.
    public static func defaultColorSpace(sample: SampleType) -> CGColorSpace {
        let name = sample == .f32 ? CGColorSpace.extendedSRGB : CGColorSpace.sRGB
        return CGColorSpace(name: name) ?? CGColorSpaceCreateDeviceRGB()
    }

    // MARK: Surface → CGImage

    /// The pixels of `rect` of `surface` as an RGB(A) image at the surface's depth.
    public static func image(from surface: Surface, rect: PixelRect, colorSpace: CGColorSpace,
                             alpha: AlphaHandling = .keep) throws -> CGImage {
        guard !rect.isEmpty else { throw KitBridgeError("cannot bridge an empty region") }
        return try image(fromRGBA: surface.readRGBA(rect), width: rect.width, height: rect.height,
                         sample: surface.format.sample, colorSpace: colorSpace, alpha: alpha)
    }

    /// Straight RGBA samples (row-major, top row first) as an image with `sample`-sized components.
    /// Integer depths quantise as PCFoundation does (clamped, rounded half up), so a round trip
    /// through `rgba(from:colorSpace:sample:)` returns the stored values exactly.
    public static func image(fromRGBA px: [SIMD4<Float>], width: Int, height: Int, sample: SampleType,
                             colorSpace: CGColorSpace, alpha: AlphaHandling = .keep) throws -> CGImage {
        guard width > 0, height > 0, px.count == width * height else {
            throw KitBridgeError("RGBA buffer of \(px.count) pixels does not fill \(width)×\(height)")
        }
        let keepAlpha = alpha == .keep
        var pixels = px
        if case .flatten(let bg) = alpha {
            for i in pixels.indices {
                let p = pixels[i]
                let a = min(max(p.w, 0), 1)
                pixels[i] = SIMD4(SIMD3(p.x, p.y, p.z) * a + bg * (1 - a), 1)
            }
        }
        let alphaInfo: CGImageAlphaInfo = keepAlpha ? .last : .noneSkipLast
        let n = width * height
        let data: Data
        let bpc: Int
        var info = alphaInfo.rawValue
        switch sample {
        case .u8:
            bpc = 8
            var b = [UInt8](repeating: 0, count: n * 4)
            for i in 0..<n {
                let p = pixels[i]
                b[i * 4] = q8(p.x); b[i * 4 + 1] = q8(p.y); b[i * 4 + 2] = q8(p.z)
                b[i * 4 + 3] = keepAlpha ? q8(p.w) : 255
            }
            data = Data(b)
        case .u16:
            bpc = 16
            info |= CGBitmapInfo.byteOrder16Little.rawValue
            var b = [UInt16](repeating: 0, count: n * 4)
            for i in 0..<n {
                let p = pixels[i]
                b[i * 4] = q16(p.x).littleEndian; b[i * 4 + 1] = q16(p.y).littleEndian; b[i * 4 + 2] = q16(p.z).littleEndian
                b[i * 4 + 3] = (keepAlpha ? q16(p.w) : 65535).littleEndian
            }
            data = b.withUnsafeBytes { Data($0) }
        case .f32:
            bpc = 32
            info |= CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            var b = [Float](repeating: 0, count: n * 4)
            for i in 0..<n {
                let p = pixels[i]
                b[i * 4] = p.x; b[i * 4 + 1] = p.y; b[i * 4 + 2] = p.z
                b[i * 4 + 3] = keepAlpha ? p.w : 1
            }
            data = b.withUnsafeBytes { Data($0) }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: bpc, bitsPerPixel: bpc * 4,
                                bytesPerRow: width * 4 * bpc / 8, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: info),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw KitBridgeError("CGImage creation failed for a \(width)×\(height) \(bpc)-bit image") }
        return img
    }

    // MARK: CGImage → RGBA

    /// Straight RGBA samples of `image` in `colorSpace` (row-major, top row first).
    ///
    /// An image in the bridge's own layouts (RGB(A/X) 8/16/32-bit, either premultiplication, in
    /// `colorSpace`) is read raw, so nothing is colour-converted or requantised; anything else is
    /// drawn into an RGBA context of `sample` depth in `colorSpace` (CoreGraphics converts it).
    public static func rgba(from image: CGImage, colorSpace: CGColorSpace, sample: SampleType) throws -> [SIMD4<Float>] {
        if let cs = image.colorSpace, cs == colorSpace || cs.name == colorSpace.name && cs.name != nil,
           let px = RawLayout(image)?.readRGBA(image) {
            return px
        }
        return try drawRGBA(image, colorSpace: colorSpace, sample: sample)
    }

    /// Straight RGBA samples of `image` at `width × height`: read as `rgba(from:colorSpace:sample:)`
    /// when the sizes match, else drawn scaled (a provider that returned another size).
    public static func rgba(from image: CGImage, colorSpace: CGColorSpace, sample: SampleType,
                            width: Int, height: Int) throws -> [SIMD4<Float>] {
        if image.width == width && image.height == height { return try rgba(from: image, colorSpace: colorSpace, sample: sample) }
        return try drawRGBA(image, colorSpace: colorSpace, sample: sample, width: width, height: height)
    }

    /// `image` drawn into a premultiplied RGBA context (scaled to `width × height` when given), then
    /// unpremultiplied.
    static func drawRGBA(_ image: CGImage, colorSpace: CGColorSpace, sample: SampleType,
                         width: Int? = nil, height: Int? = nil) throws -> [SIMD4<Float>] {
        let w = width ?? image.width, h = height ?? image.height, n = w * h
        guard n > 0 else { return [] }
        var out = [SIMD4<Float>](repeating: .zero, count: n)
        func finish(_ get: (Int) -> SIMD4<Float>) {
            for i in 0..<n {
                let p = get(i)
                out[i] = p.w > 0 ? SIMD4(p.x / p.w, p.y / p.w, p.z / p.w, p.w) : .zero
            }
        }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        switch sample {
        case .u8:
            var b = [UInt8](repeating: 0, count: n * 4)
            let ok = b.withUnsafeMutableBytes { p -> Bool in
                guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.interpolationQuality = .high
                ctx.draw(image, in: rect)
                return true
            }
            guard ok else { throw KitBridgeError("no 8-bit RGBA context in \(colorSpace.name.map { $0 as String } ?? "colour space")") }
            finish { i in SIMD4(Float(b[i * 4]), Float(b[i * 4 + 1]), Float(b[i * 4 + 2]), Float(b[i * 4 + 3])) / 255 }
        case .u16:
            var b = [UInt16](repeating: 0, count: n * 4)
            let ok = b.withUnsafeMutableBytes { p -> Bool in
                guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) else { return false }
                ctx.interpolationQuality = .high
                ctx.draw(image, in: rect)
                return true
            }
            guard ok else { throw KitBridgeError("no 16-bit RGBA context in this colour space") }
            finish { i in
                SIMD4(Float(UInt16(littleEndian: b[i * 4])), Float(UInt16(littleEndian: b[i * 4 + 1])),
                      Float(UInt16(littleEndian: b[i * 4 + 2])), Float(UInt16(littleEndian: b[i * 4 + 3]))) / 65535
            }
        case .f32:
            var b = [Float](repeating: 0, count: n * 4)
            let ok = b.withUnsafeMutableBytes { p -> Bool in
                guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
                ctx.interpolationQuality = .high
                ctx.draw(image, in: rect)
                return true
            }
            guard ok else { throw KitBridgeError("no float RGBA context in this colour space") }
            finish { i in SIMD4(b[i * 4], b[i * 4 + 1], b[i * 4 + 2], b[i * 4 + 3]) }
        }
        return out
    }

    // MARK: Model conversion

    /// Native interleaved samples of `format` for straight RGBA (encoded sRGB for non-RGB models),
    /// as `PixelFormat.components(fromRGBA:)` computes them, without a per-pixel allocation.
    public static func native(_ px: [SIMD4<Float>], format: PixelFormat) -> [Float] {
        let ch = format.channels, cc = format.mode.colorChannels
        var out = [Float](repeating: 0, count: px.count * ch)
        out.withUnsafeMutableBufferPointer { o in
            for (i, p) in px.enumerated() {
                let base = i * ch
                let rgb = SIMD3(p.x, p.y, p.z)
                switch format.mode {
                case .rgb, .indexed, .multichannel:
                    o[base] = p.x; o[base + 1] = p.y; o[base + 2] = p.z
                case .grayscale, .bitmap, .duotone:
                    o[base] = ColorConvert.rgbToGray(rgb)
                case .cmyk:
                    let c = ColorConvert.rgbToCMYK(rgb)
                    o[base] = c.x; o[base + 1] = c.y; o[base + 2] = c.z; o[base + 3] = c.w
                case .lab:
                    let l = ColorConvert.srgbToLab(rgb)
                    o[base] = l.x / 100; o[base + 1] = (l.y + 128) / 255; o[base + 2] = (l.z + 128) / 255
                }
                if format.alpha { o[base + cc] = p.w }
            }
        }
        return out
    }

    /// Writes straight RGBA (encoded in the bridge colour space) into `rect` of `surface`, in the
    /// surface's own model and depth.
    public static func write(rgba px: [SIMD4<Float>], into surface: inout Surface, rect: PixelRect) {
        surface.writeRegion(rect, native(px, format: surface.format))
    }

    /// A surface of `format` holding `image` with its top-left pixel at (`x`, `y`) in document space.
    public static func surface(from image: CGImage, format: PixelFormat, x: Int32, y: Int32,
                               colorSpace: CGColorSpace) throws -> Surface {
        let px = try rgba(from: image, colorSpace: colorSpace, sample: format.sample)
        var s = Surface(format: format)
        write(rgba: px, into: &s, rect: PixelRect(x: Int(x), y: Int(y), width: image.width, height: image.height))
        return s
    }

    // MARK: Masks

    /// The coverage (0…1, row-major, top row first) of a grayscale mask image, white = covered, at
    /// `width × height` (bilinear-resampled when the image has another size). Masks are coverage, not
    /// colour: values are read raw from the first channel (unpremultiplied), never colour-managed.
    public static func coverage(from mask: CGImage, width: Int, height: Int) throws -> [Float] {
        let native: [Float]
        if let layout = RawLayout(mask), let v = layout.readFirstChannel(mask) {
            native = v
        } else {
            native = try drawGray(mask)
        }
        let clamped = native.map { $0.isNaN ? 0 : min(max($0, 0), 1) }
        if mask.width == width && mask.height == height { return clamped }
        return resampleBilinear(clamped, from: (mask.width, mask.height), to: (width, height))
    }

    /// A grayscale mask image (DeviceGray, no colour management) of a coverage plane.
    public static func maskImage(_ coverage: [Float], width: Int, height: Int, sample: SampleType = .u8) throws -> CGImage {
        guard width > 0, height > 0, coverage.count == width * height else {
            throw KitBridgeError("coverage of \(coverage.count) values does not fill \(width)×\(height)")
        }
        let data: Data
        let bpc: Int
        var info = CGImageAlphaInfo.none.rawValue
        switch sample {
        case .u8:
            bpc = 8
            data = Data(coverage.map { q8($0) })
        case .u16:
            bpc = 16
            info |= CGBitmapInfo.byteOrder16Little.rawValue
            data = coverage.map { q16($0).littleEndian }.withUnsafeBytes { Data($0) }
        case .f32:
            bpc = 32
            info |= CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            data = coverage.map { min(max($0, 0), 1) }.withUnsafeBytes { Data($0) }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: bpc, bitsPerPixel: bpc, bytesPerRow: width * bpc / 8,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw KitBridgeError("mask CGImage creation failed") }
        return img
    }

    /// `image` drawn into a float gray context: in its own colour space when that is monochrome (no
    /// conversion), else device gray.
    static func drawGray(_ image: CGImage) throws -> [Float] {
        let w = image.width, h = image.height
        var out = [Float](repeating: 0, count: w * h)
        let space = image.colorSpace.flatMap { $0.model == .monochrome ? $0 : nil } ?? CGColorSpaceCreateDeviceGray()
        let ok = out.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw KitBridgeError("no gray context to read a \(w)×\(h) mask") }
        return out
    }

    /// Bilinear resampling of a single plane (pixel centres aligned).
    public static func resampleBilinear(_ src: [Float], from: (Int, Int), to: (Int, Int)) -> [Float] {
        let (sw, sh) = from, (dw, dh) = to
        guard sw > 0, sh > 0, dw > 0, dh > 0 else { return [Float](repeating: 0, count: max(0, dw * dh)) }
        var out = [Float](repeating: 0, count: dw * dh)
        let sx = Float(sw) / Float(dw), sy = Float(sh) / Float(dh)
        for y in 0..<dh {
            let fy = min(max((Float(y) + 0.5) * sy - 0.5, 0), Float(sh - 1))
            let y0 = Int(fy), y1 = min(y0 + 1, sh - 1), ty = fy - Float(y0)
            for x in 0..<dw {
                let fx = min(max((Float(x) + 0.5) * sx - 0.5, 0), Float(sw - 1))
                let x0 = Int(fx), x1 = min(x0 + 1, sw - 1), tx = fx - Float(x0)
                let a = src[y0 * sw + x0], b = src[y0 * sw + x1], c = src[y1 * sw + x0], d = src[y1 * sw + x1]
                out[y * dw + x] = (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
            }
        }
        return out
    }

    // MARK: Encoded frames (RestoreTier2's seam takes PNG/JPEG bytes)

    /// PNG bytes of `image` (16 bits per channel when the image is deeper than 8).
    public static func pngData(_ image: CGImage) throws -> Data {
        var source = image
        if image.bitsPerComponent == 32 {
            // PNG has no float samples: requantise to 16 bits, clamped.
            let px = try drawRGBA(image, colorSpace: image.colorSpace ?? defaultColorSpace(sample: .f32), sample: .f32)
            source = try self.image(fromRGBA: px, width: image.width, height: image.height, sample: .u16,
                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw KitBridgeError("no PNG encoder")
        }
        CGImageDestinationAddImage(dest, source, nil)
        guard CGImageDestinationFinalize(dest) else { throw KitBridgeError("PNG encoding failed") }
        return out as Data
    }

    /// The first image in encoded bytes (PNG, JPEG, …).
    public static func decodeImage(_ data: Data) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw KitBridgeError("undecodable image data") }
        return img
    }

    // MARK: Quantisation (PCFoundation's writeSample rule)

    @inline(__always) static func q8(_ v: Float) -> UInt8 { UInt8(min(max(v.isNaN ? 0 : v, 0), 1) * 255 + 0.5) }
    @inline(__always) static func q16(_ v: Float) -> UInt16 { UInt16(min(max(v.isNaN ? 0 : v, 0), 1) * 65535 + 0.5) }
}

/// A CGImage memory layout the bridge reads without drawing: 8/16-bit integer or 32-bit float
/// components, 1–4 per pixel, alpha (or padding) first or last. 16- and 32-bit components are read
/// only with an explicit byte order; anything ambiguous is left to the drawing path.
struct RawLayout {
    let bpc: Int
    let comps: Int
    let littleEndian: Bool
    /// Index of the first colour component in logical order.
    let colorStart: Int
    /// 1 (gray) or 3 (RGB).
    let colorComps: Int
    /// Index of the alpha component in logical order, if the image has alpha.
    let alphaIndex: Int?
    let premultiplied: Bool
    /// The pixel's memory order is reversed (8-bit components in a 32-bit little-endian word).
    let reversed: Bool

    init?(_ image: CGImage) {
        let info = image.bitmapInfo
        let bpc = image.bitsPerComponent, bpp = image.bitsPerPixel
        guard [8, 16, 32].contains(bpc), bpp % bpc == 0 else { return nil }
        let comps = bpp / bpc
        guard (1...4).contains(comps) else { return nil }
        let isFloat = info.contains(.floatComponents)
        if isFloat != (bpc == 32) { return nil }
        let order = info.intersection(.byteOrderMask)
        let extra: Int          // alpha or padding component
        var alphaFirst = false
        var hasAlpha = false
        var premultiplied = false
        switch image.alphaInfo {
        case .none: extra = 0
        case .noneSkipFirst: extra = 1; alphaFirst = true
        case .noneSkipLast: extra = 1
        case .first: extra = 1; alphaFirst = true; hasAlpha = true
        case .last: extra = 1; hasAlpha = true
        case .premultipliedFirst: extra = 1; alphaFirst = true; hasAlpha = true; premultiplied = true
        case .premultipliedLast: extra = 1; hasAlpha = true; premultiplied = true
        default: return nil
        }
        let colorComps = comps - extra
        guard colorComps == 1 || colorComps == 3 else { return nil }
        switch bpc {
        case 8:
            if order == .byteOrder16Little || order == .byteOrder16Big { return nil }
            littleEndian = false
            // 8-bit components in a 32-bit little-endian word: memory order is reversed.
            reversed = order == .byteOrder32Little && comps == 4
            if order == .byteOrder32Little && comps != 4 { return nil }
        case 16:
            guard order == .byteOrder16Little || order == .byteOrder16Big else { return nil }
            littleEndian = order == .byteOrder16Little
            reversed = false
        default:
            guard order == .byteOrder32Little || order == .byteOrder32Big else { return nil }
            littleEndian = order == .byteOrder32Little
            reversed = false
        }
        self.bpc = bpc
        self.comps = comps
        self.colorComps = colorComps
        self.colorStart = alphaFirst ? extra : 0
        self.alphaIndex = hasAlpha ? (alphaFirst ? 0 : comps - 1) : nil
        self.premultiplied = premultiplied
    }

    /// Calls `body(pixelIndex, components)` with each pixel's components in logical order.
    private func forEachPixel(_ image: CGImage, _ body: (Int, UnsafeBufferPointer<Float>) -> Void) -> Bool {
        guard let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { return false }
        let w = image.width, h = image.height, bpr = image.bytesPerRow
        let pixelBytes = comps * bpc / 8
        guard h > 0, w > 0, CFDataGetLength(data) >= bpr * (h - 1) + w * pixelBytes else { return false }
        var c = [Float](repeating: 0, count: comps)
        c.withUnsafeMutableBufferPointer { cp in
            for y in 0..<h {
                let row = base + y * bpr
                for x in 0..<w {
                    let px = row + x * pixelBytes
                    for k in 0..<comps {
                        let src = reversed ? comps - 1 - k : k
                        switch bpc {
                        case 8:
                            cp[k] = Float(px[src]) / 255
                        case 16:
                            var v: UInt16 = 0
                            memcpy(&v, px + src * 2, 2)
                            cp[k] = Float(littleEndian ? UInt16(littleEndian: v) : UInt16(bigEndian: v)) / 65535
                        default:
                            var bits: UInt32 = 0
                            memcpy(&bits, px + src * 4, 4)
                            cp[k] = Float(bitPattern: littleEndian ? UInt32(littleEndian: bits) : UInt32(bigEndian: bits))
                        }
                    }
                    body(y * w + x, UnsafeBufferPointer(cp))
                }
            }
        }
        return true
    }

    /// Straight colour and alpha of one pixel's logical components.
    @inline(__always) private func split(_ c: UnsafeBufferPointer<Float>) -> (color: SIMD3<Float>, alpha: Float) {
        let a = alphaIndex.map { c[$0] } ?? 1
        var rgb = colorComps == 3 ? SIMD3(c[colorStart], c[colorStart + 1], c[colorStart + 2]) : SIMD3(repeating: c[colorStart])
        if premultiplied { rgb = a > 0 ? rgb / a : .zero }
        return (rgb, a)
    }

    func readRGBA(_ image: CGImage) -> [SIMD4<Float>]? {
        var out = [SIMD4<Float>](repeating: .zero, count: image.width * image.height)
        let ok = forEachPixel(image) { i, c in
            let (rgb, a) = split(c)
            out[i] = SIMD4(rgb, a)
        }
        return ok ? out : nil
    }

    func readFirstChannel(_ image: CGImage) -> [Float]? {
        var out = [Float](repeating: 0, count: image.width * image.height)
        let ok = forEachPixel(image) { i, c in out[i] = split(c).color.x }
        return ok ? out : nil
    }
}
