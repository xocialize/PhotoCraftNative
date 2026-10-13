// The codec registry entry points: decode to the native depth/model, encode with options, frames,
// fidelity warnings.
// Replaces photocraft-codecs (crates/codecs/src/{lib,options,fidelity}.rs and every codec under
// crates/codecs/src/codecs/) and photocraft-heif (crates/heif) with ImageIO; WebP writing goes through
// webp-swift (libwebp); camera raw through RawDeveloper; PDF through PDFDocumentIO. Port of its API
// shape (`decode`, `decode_as`, `encode`, `fidelity_warnings`, `Limits`, `EncodeOptions`), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import ImageBridge
import ImageIO
import MediaMeasure
import PCFoundation
import UniformTypeIdentifiers
import WebPSwift

/// Decompression-bomb guards, checked against the header before pixels are decoded (photocraft
/// `Limits`, same defaults: 2¹⁸ per side, 2³⁰ pixels, 8 GiB).
public struct DecodeLimits: Sendable, Equatable {
    public var maxWidth = 1 << 18
    public var maxHeight = 1 << 18
    public var maxPixels = 1 << 30
    public var maxBytes = 8 << 30
    public init() {}
    public static let none: DecodeLimits = { var l = DecodeLimits(); l.maxWidth = .max; l.maxHeight = .max; l.maxPixels = .max; l.maxBytes = .max; return l }()

    func check(width: Int, height: Int, bytesPerPixel: Int) throws {
        guard width > 0, height > 0 else { throw PlatformError.decodeFailed("zero-sized image \(width)×\(height)") }
        if width > maxWidth || height > maxHeight { throw PlatformError.limitExceeded("dimensions \(width)×\(height) exceed \(maxWidth)×\(maxHeight)") }
        let (px, o1) = width.multipliedReportingOverflow(by: height)
        if o1 || px > maxPixels { throw PlatformError.limitExceeded("\(width * height) pixels exceed \(maxPixels)") }
        let (bytes, o2) = px.multipliedReportingOverflow(by: bytesPerPixel)
        if o2 || bytes > maxBytes { throw PlatformError.limitExceeded("\(width)×\(height) at \(bytesPerPixel) B/px exceeds \(maxBytes) bytes") }
    }
}

public struct DecodeOptions: Sendable {
    public var limits = DecodeLimits()
    /// Keep the stored pixels instead of turning them upright (photocraft `keep_orientation`).
    public var keepOrientation = false
    /// The frame / page / image index to decode.
    public var frame = 0
    public init() {}
}

/// Something the decoder noticed that the pixels don't show (photocraft `DecodeWarning`).
public enum DecodeWarning: Sendable, Equatable, CustomStringConvertible {
    case moreFrames(total: Int)
    case morePages(total: Int)
    /// Samples were widened (half float → f32, 10-bit → 16-bit…).
    case depthWidened(from: CodecDepth, to: CodecDepth)
    /// A colour model PCFoundation cannot store was converted (e.g. XYZ → sRGB).
    case colorConverted(String)

    public var description: String {
        switch self {
        case .moreFrames(let n): "only one of \(n) frames was imported"
        case .morePages(let n): "only one of \(n) pages was imported"
        case .depthWidened(let a, let b): "\(a.name) samples were widened to \(b.name)"
        case .colorConverted(let s): "colours were converted: \(s)"
        }
    }
}

/// A decoded image (photocraft `Image` + its ICC + metadata + warnings).
public struct DecodedImage: Sendable {
    public var raster: RasterBuffer
    public var format: ImageFormat
    /// The embedded (or implied) profile; nil for untagged device data.
    public var profile: ICCProfile?
    public var metadata: ImageMetadata
    public var warnings: [DecodeWarning]
    public var frameCount: Int
    /// The depth the file stores (EXR half reads as f32 with `storedDepth == .f16`).
    public var storedDepth: CodecDepth

    /// The pixels as a surface at the origin.
    public var surface: Surface { raster.surface() }
    public var pixelFormat: PixelFormat { raster.format }
    public var size: PixelSize { PixelSize(width: raster.width, height: raster.height) }
}

/// One frame of an animation or page of a multi-page file.
public struct FrameInfo: Sendable, Equatable {
    public var index: Int
    public var width: Int
    public var height: Int
    /// Display duration in seconds (GIF/APNG/HEICS/WebP), nil for pages.
    public var delay: Double?
}

public enum PNGFilter: Int, Sendable { case none = 0x08, sub = 0x10, up = 0x20, average = 0x40, paeth = 0x80, adaptive = 0xF8 }

/// TIFF compression (photocraft `TiffCompression`; values are the TIFF tag codes ImageIO honours).
public enum TIFFCompression: Int, Sendable { case none = 1, lzw = 5, packBits = 32773, deflate = 8 }

/// OpenEXR compression (OpenEXR's codes, which AppleEXR uses).
public enum EXRCompression: Int, Sendable { case none = 0, rle = 1, zips = 2, zip = 3, piz = 4 }

public enum EXRPrecision: Sendable { case half, float }

/// Encode settings (photocraft `EncodeOptions`).
public struct EncodeOptions: Sendable {
    /// JPEG quality on the IJG 1–100 scale (photocraft's and Photoshop's Save As), mapped onto
    /// ImageIO's 0…1 by `SourceSettings.imageIOQuality(forIJG:)`.
    public var jpegQuality = 90
    public var jpegProgressive = false
    public var pngInterlaced = false
    public var pngFilter: PNGFilter?
    public var tiffCompression: TIFFCompression = .lzw
    public var exrPrecision: EXRPrecision = .float
    public var exrCompression: EXRCompression = .zip
    /// HEIC / AVIF / JPEG 2000 / HEICS quality 0…1.
    public var lossyQuality = 0.9
    /// WebP: lossless (VP8L) or lossy at `webpQuality` (0–100) — photocraft's defaults.
    public var webpLossless = true
    public var webpQuality = 80
    public var embedICC = true
    public var embedMetadata = true
    public init() {}
}

/// Something an encode will lose or alter (photocraft `FidelityWarning`).
public enum FidelityWarning: Sendable, Equatable, CustomStringConvertible {
    case writeUnsupported(ImageFormat)
    case depthReduced(from: CodecDepth, to: CodecDepth)
    case rangeClipped
    case alphaDiscarded
    case alphaBinarized
    case modelConverted(from: ColorMode, to: ColorMode)
    case paletteQuantized
    case lossyCompression
    case iccDropped
    case metadataDropped
    case dimensionsExceeded(maxWidth: Int, maxHeight: Int)

    public var isFatal: Bool {
        switch self { case .writeUnsupported, .dimensionsExceeded: true; default: false }
    }

    public var description: String {
        switch self {
        case .writeUnsupported(let f): "\(f.name) cannot be written"
        case .depthReduced(let a, let b): "\(a.name) will be reduced to \(b.name)"
        case .rangeClipped: "values outside 0…1 will be clipped"
        case .alphaDiscarded: "transparency will be discarded"
        case .alphaBinarized: "transparency will be reduced to on/off"
        case .modelConverted(let a, let b): "\(a) colours will be converted to \(b)"
        case .paletteQuantized: "colours will be reduced to a 256-colour palette"
        case .lossyCompression: "the format's compression is lossy"
        case .iccDropped: "the colour profile will not be embedded"
        case .metadataDropped: "EXIF/XMP metadata will not be kept"
        case .dimensionsExceeded(let w, let h): "the image exceeds the format's \(w)×\(h) limit"
        }
    }
}

public enum ImageCodecs {
    // MARK: Decode

    /// Detects the format and decodes (photocraft `decode_with`).
    public static func decode(_ data: Data, options: DecodeOptions = DecodeOptions()) throws -> DecodedImage {
        guard let f = ImageFormat.detect(data) else { throw PlatformError.decodeFailed("unrecognized format") }
        return try decode(data, as: f, options: options)
    }

    public static func decode(contentsOf url: URL, options: DecodeOptions = DecodeOptions()) throws -> DecodedImage {
        try decode(try Data(contentsOf: url, options: .mappedIfSafe), options: options)
    }

    /// Decodes as a specific format (photocraft `decode_as_with`).
    public static func decode(_ data: Data, as format: ImageFormat, options: DecodeOptions = DecodeOptions()) throws -> DecodedImage {
        switch format {
        case .qoi:
            let r = try PortedCodecs.decodeQOI(data)
            try options.limits.check(width: r.width, height: r.height, bytesPerPixel: r.format.bytesPerPixel)
            return DecodedImage(raster: r, format: .qoi, profile: BuiltinProfile.srgb.profile, metadata: ImageMetadata(), warnings: [], frameCount: 1, storedDepth: .u8)
        case .pcx:
            let (r, res) = try PortedCodecs.decodePCX(data)
            return DecodedImage(raster: r, format: .pcx, profile: nil, metadata: ImageMetadata(resolution: res), warnings: [], frameCount: 1, storedDepth: .u8)
        case .fits:
            let (r, text, w) = try PortedCodecs.decodeFITS(data)
            return DecodedImage(raster: r, format: .fits, profile: nil, metadata: ImageMetadata(text: text), warnings: w, frameCount: 1, storedDepth: CodecDepth(r.format.sample))
        case .pnm where data.count > 2 && data[data.startIndex + 1] == UInt8(ascii: "4"):
            let r = try PortedCodecs.decodePBM4(data)
            return DecodedImage(raster: r, format: .pnm, profile: nil, metadata: ImageMetadata(), warnings: [], frameCount: 1, storedDepth: .u8)
        case .cameraRaw:
            let dev = try RawDeveloper.develop(data: data)
            return DecodedImage(raster: dev.raster, format: .cameraRaw, profile: dev.profile, metadata: dev.metadata,
                                warnings: [], frameCount: 1, storedDepth: CodecDepth(dev.raster.format.sample))
        case .pdf:
            let page = try PDFDocumentIO.rasterize(data: data, page: options.frame, dpi: 150)
            let n = try PDFDocumentIO.pageCount(data: data)
            return DecodedImage(raster: page, format: .pdf, profile: BuiltinProfile.srgb.profile,
                                metadata: ImageMetadata(resolution: Resolution(x: 150, y: 150)),
                                warnings: n > 1 ? [.morePages(total: n)] : [], frameCount: n, storedDepth: .u8)
        default:
            return try decodeImageIO(data, format: format, options: options)
        }
    }

    static func source(_ data: Data, hint: ImageFormat?) throws -> CGImageSource {
        var opts: [CFString: Any] = [kCGImageSourceShouldAllowFloat: true]
        if let hint { opts[kCGImageSourceTypeIdentifierHint] = hint.uti }
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary) else {
            throw PlatformError.decodeFailed("ImageIO cannot open the data")
        }
        return src
    }

    static func decodeImageIO(_ data: Data, format: ImageFormat, options: DecodeOptions) throws -> DecodedImage {
        let src = try source(data, hint: format)
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { throw PlatformError.decodeFailed("\(format.name): ImageIO found no image") }
        let index = min(max(options.frame, 0), count - 1)
        let props = (CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [String: Any]) ?? [:]
        if let w = props[kCGImagePropertyPixelWidth as String] as? Int, let h = props[kCGImagePropertyPixelHeight as String] as? Int {
            try options.limits.check(width: w, height: h, bytesPerPixel: 5 * 4)
        }
        let decodeOpts: [CFString: Any] = [kCGImageSourceShouldAllowFloat: true, kCGImageSourceShouldCache: false]
        guard let cg = CGImageSourceCreateImageAtIndex(src, index, decodeOpts as CFDictionary) else {
            throw PlatformError.decodeFailed("\(format.name): ImageIO could not decode image \(index)")
        }
        try options.limits.check(width: cg.width, height: cg.height, bytesPerPixel: max(1, cg.bitsPerPixel / 8))
        var raster = try SurfaceBridge.raster(from: cg)
        // ImageIO hands some alpha-less files back with an opaque alpha (OpenEXR RGB); keep the
        // file's own layout.
        if raster.format.alpha, props[kCGImagePropertyHasAlpha as String] as? Bool == false
            || (format == .openEXR && exrChannels(data).map { !$0.contains("A") } == true) {
            raster = stripAlpha(raster)
        }
        var warnings: [DecodeWarning] = []
        let stored: CodecDepth = cg.bitmapInfo.contains(.floatComponents) ? (cg.bitsPerComponent == 16 ? .f16 : .f32)
            : (cg.bitsPerComponent > 8 ? .u16 : .u8)
        if stored == .f16 { warnings.append(.depthWidened(from: .f16, to: .f32)) }
        if let cs = cg.colorSpace, SurfaceBridge.colorMode(for: cs) == nil, cs.model != .indexed {
            warnings.append(.colorConverted("\(cs.model) → sRGB"))
        }
        if count > 1 {
            let animated = [ImageFormat.gif, .png, .webp, .heics, .avif].contains(format)
            warnings.append(animated ? .moreFrames(total: count) : .morePages(total: count))
        }
        let space = SurfaceBridge.storageColorSpace(of: cg)
        let profile = space.copyICCData().flatMap { try? ICCProfile(data: $0 as Data) }
        var meta = ImageMetadata.read(source: src, index: index)
        if !options.keepOrientation, meta.orientation != 1 {
            raster = SurfaceBridge.oriented(raster, orientation: meta.orientation)
            meta.orientation = 1
        }
        return DecodedImage(raster: raster, format: format, profile: profile, metadata: meta, warnings: warnings,
                            frameCount: count, storedDepth: stored)
    }

    /// Frames / pages without decoding pixels (photocraft `tiff_info` / GIF frame listing).
    public static func frames(_ data: Data) throws -> [FrameInfo] {
        let format = ImageFormat.detect(data)
        if format == .pdf { return try PDFDocumentIO.pageSizes(data: data, dpi: 72).enumerated().map { FrameInfo(index: $0, width: $1.width, height: $1.height, delay: nil) } }
        let src = try source(data, hint: format)
        return (0..<CGImageSourceGetCount(src)).map { i in
            let p = (CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any]) ?? [:]
            var delay: Double?
            for (group, unclamped, clamped) in [
                (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
                (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
                (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
                (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            ] {
                if let g = p[group as String] as? [String: Any], let d = (g[unclamped as String] as? Double) ?? (g[clamped as String] as? Double) {
                    delay = d
                }
            }
            return FrameInfo(index: i, width: p[kCGImagePropertyPixelWidth as String] as? Int ?? 0,
                             height: p[kCGImagePropertyPixelHeight as String] as? Int ?? 0, delay: delay)
        }
    }

    /// Decodes every frame (photocraft `decode_gif_frames`; also APNG, HEICS, animated WebP,
    /// TIFF pages).
    public static func decodeAllFrames(_ data: Data, options: DecodeOptions = DecodeOptions()) throws -> [DecodedImage] {
        try frames(data).map { f in
            var o = options
            o.frame = f.index
            return try decode(data, options: o)
        }
    }

    // MARK: ImageBridge (media-bridge) wrappers

    /// media-bridge's probe of a still on disk (format, size, bit depth, alpha mode, ICC, DPI, EXIF
    /// orientation, frame count and delays). Camera raw and PDF are probed the way ImageBridge
    /// decodes them.
    public static func probe(url: URL) throws -> StillMetadata {
        try ImageBridgeFactory.makeProbe().probe(url: url)
    }

    /// media-bridge's display-referred decode: every frame upright as 8-bit sRGB RGBA (ImageBridge
    /// renders through a CIContext pinned to sRGB and hands back BGRA `CVPixelBuffer`s; raw and PDF
    /// included). The fast thumbnail/preview path; `decode` keeps native depth and model.
    public static func decodeDisplay8(url: URL, pdfDPI: Double = 150) throws -> [RasterBuffer] {
        let (frames, _) = try ImageBridgeFactory.makeDecoder(pdfDPI: pdfDPI).decode(url: url)
        return frames.map(PixelBufferBridge.rgba8)
    }

    // MARK: Encode

    /// What the encoder will convert, shared by `encode` and `fidelityWarnings` so a warning is
    /// emitted exactly when something is transformed or dropped (photocraft `fidelity::plan`).
    struct Plan {
        var target: PixelFormat
        var warnings: [FidelityWarning]
    }

    static func plan(_ f: PixelFormat, format: ImageFormat, options: EncodeOptions, hasMetadata: Bool, hasProfile: Bool) -> Plan {
        let caps = format.caps
        var w: [FidelityWarning] = []
        guard caps.write else { return Plan(target: f, warnings: [.writeUnsupported(format)]) }
        var mode = f.mode
        // Model.
        let layoutsModels: Set<String> = Set(caps.layouts.map { l -> String in
            switch l { case .gray, .grayA: "gray"; case .rgb, .rgba: "rgb"; case .cmyk, .cmykA: "cmyk" }
        })
        let modelName = f.mode.isGrayLike ? "gray" : (f.mode == .cmyk ? "cmyk" : (f.mode == .lab ? "lab" : "rgb"))
        if !layoutsModels.contains(modelName) {
            let to: ColorMode = (modelName == "gray" && layoutsModels.contains("rgb")) ? .rgb : (layoutsModels.contains("rgb") ? .rgb : .grayscale)
            w.append(.modelConverted(from: f.mode, to: to))
            mode = to
        }
        if mode == .indexed || mode == .multichannel { mode = .rgb }
        if mode == .bitmap || mode == .duotone { mode = .grayscale }
        // Alpha.
        var alpha = f.alpha
        if alpha && !caps.alpha { w.append(.alphaDiscarded); alpha = false }
        if alpha && format == .gif { w.append(.alphaBinarized) }
        if format == .gif { w.append(.paletteQuantized) }
        // Depth.
        let have = CodecDepth(f.sample)
        var depth = have
        let wanted: [CodecDepth] = format == .openEXR ? [options.exrPrecision == .half ? .f16 : .f32] : caps.depths
        if !wanted.contains(have) {
            depth = wanted.filter { $0 <= have }.max() ?? wanted.min() ?? .u8
            if format == .openEXR { depth = wanted[0] }
            if depth < have { w.append(.depthReduced(from: have, to: depth)) }
            if have == .f32 && (depth == .u8 || depth == .u16) { w.append(.rangeClipped) }
        }
        if format == .openEXR && options.exrPrecision == .half && have == .f32 { /* reported above */ }
        if caps.lossy && !(format == .webp && options.webpLossless) { w.append(.lossyCompression) }
        if hasProfile && (!caps.icc || !options.embedICC) { w.append(.iccDropped) }
        if hasMetadata && (!(caps.exif || caps.xmp) || !options.embedMetadata) { w.append(.metadataDropped) }
        let sample: SampleType = depth == .u8 ? .u8 : (depth == .u16 ? .u16 : .f32)
        return Plan(target: PixelFormat(mode: mode, sample: sample, alpha: alpha), warnings: w)
    }

    /// What writing `pixelFormat` as `format` will lose (photocraft `fidelity_warnings_with`).
    public static func fidelityWarnings(for pixelFormat: PixelFormat, width: Int = 1, height: Int = 1, as format: ImageFormat,
                                        options: EncodeOptions = EncodeOptions(), hasMetadata: Bool = false, hasProfile: Bool = false) -> [FidelityWarning] {
        var w = plan(pixelFormat, format: format, options: options, hasMetadata: hasMetadata, hasProfile: hasProfile).warnings
        if let m = format.maxDimensions, width > m.width || height > m.height { w.append(.dimensionsExceeded(maxWidth: m.width, maxHeight: m.height)) }
        return w
    }

    /// The channel names of an OpenEXR file's first part (its `channels` header attribute). ImageIO
    /// reports `HasAlpha` for every EXR and adds an opaque alpha to RGB files.
    static func exrChannels(_ data: Data) -> [String]? {
        let b = [UInt8](data.prefix(64 * 1024))
        guard b.count > 8, b[0] == 0x76, b[1] == 0x2F, b[2] == 0x31, b[3] == 0x01 else { return nil }
        var i = 8
        func cstr() -> String? {
            guard let end = b[i...].firstIndex(of: 0) else { return nil }
            defer { i = end + 1 }
            return String(decoding: b[i..<end], as: UTF8.self)
        }
        while i < b.count, b[i] != 0 {
            guard let name = cstr(), let type = cstr(), i + 4 <= b.count else { return nil }
            let size = Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
            i += 4
            if name == "channels" && type == "chlist" {
                var names: [String] = []
                var j = i
                while j < min(i + size, b.count), b[j] != 0 {
                    guard let end = b[j...].firstIndex(of: 0) else { break }
                    names.append(String(decoding: b[j..<end], as: UTF8.self))
                    j = end + 1 + 16
                }
                return names.map { $0.split(separator: ".").last.map(String.init) ?? $0 }
            }
            i += size
        }
        return nil
    }

    /// The raster without its alpha channel.
    static func stripAlpha(_ r: RasterBuffer) -> RasterBuffer {
        guard r.format.alpha else { return r }
        let ch = r.format.channels, keep = ch - 1, bps = r.format.sample.bytes
        var out = [UInt8](); out.reserveCapacity(r.width * r.height * keep * bps)
        for i in 0..<(r.width * r.height) { out += r.bytes[(i * ch * bps)..<(i * ch * bps + keep * bps)] }
        return RasterBuffer(width: r.width, height: r.height, format: r.format.with(alpha: false), bytes: out)
    }

    /// Converts a raster to `target` (model through `profile`, alpha dropped, depth changed).
    static func prepare(_ r: RasterBuffer, to target: PixelFormat, profile: ICCProfile?) throws -> (RasterBuffer, ICCProfile?) {
        var r = r, profile = profile
        if r.format.mode.colorChannels != target.mode.colorChannels || (r.format.mode == .lab) != (target.mode == .lab) {
            let src = profile.flatMap { $0.colorMode?.colorChannels == r.format.mode.colorChannels ? $0 : nil }
                ?? BuiltinProfile.defaultProfile(for: r.format.mode)
            let dst = BuiltinProfile.defaultProfile(for: target.mode)
            r = try ColorTransform(source: src, destination: dst, options: .photoshopDefault).convert(r, to: .f32)
            profile = dst
        }
        if r.format.alpha && !target.alpha { r = stripAlpha(r) }
        if r.format.sample != target.sample { r = r.converted(to: target.sample) }
        let mode = target.mode
        if r.format.mode != mode, r.format.mode.colorChannels == mode.colorChannels {
            r = RasterBuffer(width: r.width, height: r.height, format: PixelFormat(mode: mode, sample: r.format.sample, alpha: r.format.alpha), bytes: r.bytes)
        }
        return (r, profile)
    }

    /// Encodes a raster as `format` (photocraft `encode`). `profile` tags the pixels (the mode's
    /// default when nil); `metadata` is written where the format allows.
    public static func encode(_ raster: RasterBuffer, as format: ImageFormat, profile: ICCProfile? = nil, metadata: ImageMetadata? = nil,
                              options: EncodeOptions = EncodeOptions()) throws -> Data {
        guard raster.width > 0, raster.height > 0 else { throw PlatformError.encodeFailed("cannot encode an empty image") }
        if let m = format.maxDimensions, raster.width > m.width || raster.height > m.height {
            throw PlatformError.encodeFailed("\(format.name) dimensions exceed \(m.width)×\(m.height)")
        }
        let p = plan(raster.format, format: format, options: options, hasMetadata: metadata.map { !$0.isEmpty } ?? false, hasProfile: profile != nil)
        if let fatal = p.warnings.first(where: \.isFatal) { throw PlatformError.unsupported(fatal.description) }
        // Half-float EXR keeps an f32 raster until the CGImage is built.
        let (r, prof) = try prepare(raster, to: p.target, profile: profile)
        switch format {
        case .qoi: return try PortedCodecs.encodeQOI(r)
        case .pnm: return try PortedCodecs.encodePNM(r)
        case .hdr: return try PortedCodecs.encodeRadiance(r)
        case .fits: return try PortedCodecs.encodeFITS(r, text: metadata?.text ?? [])
        case .pdf: return try PDFDocumentIO.writeRaster(pages: [r], profile: prof, dpi: metadata?.resolution?.x ?? 72)
        case .webp:
            let cg = try SurfaceBridge.cgImage(r, colorSpace: prof?.cgColorSpace)
            let enc = WebPStillEncoder()
            return options.webpLossless ? try enc.encodeLossless(cg) : try enc.encode(cg, quality: Double(options.webpQuality) / 100)
        default:
            return try encodeImageIO([(r, nil)], format: format, profile: prof, metadata: metadata, options: options)
        }
    }

    /// Encodes `rect` of a surface.
    public static func encode(_ surface: Surface, rect: PixelRect, as format: ImageFormat, profile: ICCProfile? = nil,
                              metadata: ImageMetadata? = nil, options: EncodeOptions = EncodeOptions()) throws -> Data {
        try encode(RasterBuffer(surface: surface, rect: rect), as: format, profile: profile, metadata: metadata, options: options)
    }

    /// Writes several frames/pages: animated GIF, APNG, HEIF sequence, multi-page TIFF, PDF.
    /// `delay` is seconds per frame (ignored for pages).
    public static func encodeFrames(_ frames: [(raster: RasterBuffer, delay: Double?)], as format: ImageFormat, profile: ICCProfile? = nil,
                                    loopCount: Int = 0, options: EncodeOptions = EncodeOptions()) throws -> Data {
        guard !frames.isEmpty else { throw PlatformError.encodeFailed("no frames") }
        guard format.caps.animation else { throw PlatformError.unsupported("\(format.name) holds one image") }
        var prepared: [(RasterBuffer, Double?)] = []
        var prof = profile
        for f in frames {
            let p = plan(f.raster.format, format: format, options: options, hasMetadata: false, hasProfile: profile != nil)
            let (r, pr) = try prepare(f.raster, to: p.target, profile: profile)
            prepared.append((r, f.delay)); prof = pr
        }
        if format == .pdf { return try PDFDocumentIO.writeRaster(pages: prepared.map(\.0), profile: prof, dpi: 72) }
        return try encodeImageIO(prepared, format: format, profile: prof, metadata: nil, options: options, loopCount: loopCount)
    }

    static func encodeImageIO(_ frames: [(RasterBuffer, Double?)], format: ImageFormat, profile: ICCProfile?, metadata: ImageMetadata?,
                              options: EncodeOptions, loopCount: Int = 0) throws -> Data {
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, format.uti as CFString, frames.count, nil) else {
            throw PlatformError.unsupported("ImageIO has no \(format.name) writer")
        }
        // Container properties (loop count).
        switch format {
        case .gif: CGImageDestinationSetProperties(dst, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]] as CFDictionary)
        case .png where frames.count > 1: CGImageDestinationSetProperties(dst, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: loopCount]] as CFDictionary)
        case .heics: CGImageDestinationSetProperties(dst, [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSLoopCount: loopCount]] as CFDictionary)
        default: break
        }
        for (r, delay) in frames {
            var cgSpace: CGColorSpace? = nil
            if options.embedICC, let p = profile, p.colorMode?.colorChannels == r.format.mode.colorChannels, r.format.mode != .lab {
                cgSpace = p.cgColorSpace
            }
            if format == .openEXR {
                // OpenEXR is scene-linear: ImageIO linearises anything tagged with a curve. The
                // samples are written as they are (photocraft's EXR semantics), tagged linear.
                cgSpace = r.format.mode.isGrayLike ? CGColorSpace(name: CGColorSpace.extendedLinearGray)! : CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            }
            var img = try SurfaceBridge.cgImage(r, colorSpace: cgSpace)
            if format == .openEXR, options.exrPrecision == .half { img = try halfFloatImage(r, colorSpace: cgSpace) }
            var props = (metadata?.destinationProperties(includeGroups: options.embedMetadata)) ?? [:]
            if metadata == nil { props[kCGImagePropertyOrientation as String] = 1 }
            switch format {
            case .jpeg:
                props[kCGImageDestinationLossyCompressionQuality as String] = SourceSettings.imageIOQuality(forIJG: options.jpegQuality)
                if options.jpegProgressive { props[kCGImagePropertyJFIFDictionary as String] = [kCGImagePropertyJFIFIsProgressive: true] }
            case .heif, .avif, .jpeg2000, .heics:
                props[kCGImageDestinationLossyCompressionQuality as String] = options.lossyQuality
            case .png:
                var png = props[kCGImagePropertyPNGDictionary as String] as? [String: Any] ?? [:]
                if options.pngInterlaced { png[kCGImagePropertyPNGInterlaceType as String] = 1 }
                if let f = options.pngFilter { png[kCGImagePropertyPNGCompressionFilter as String] = f.rawValue }
                if let d = delay { png[kCGImagePropertyAPNGDelayTime as String] = d }
                props[kCGImagePropertyPNGDictionary as String] = png
            case .tiff:
                var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
                tiff[kCGImagePropertyTIFFCompression as String] = options.tiffCompression.rawValue
                props[kCGImagePropertyTIFFDictionary as String] = tiff
            case .openEXR:
                props[kCGImagePropertyOpenEXRCompression as String] = options.exrCompression.rawValue
            case .gif:
                if let d = delay { props[kCGImagePropertyGIFDictionary as String] = [kCGImagePropertyGIFDelayTime: d] }
            default: break
            }
            if format == .heics, let d = delay { props[kCGImagePropertyHEICSDictionary as String] = [kCGImagePropertyHEICSDelayTime: d] }
            if options.embedMetadata, let tree = metadata?.cgImageMetadata, frames.count == 1 {
                CGImageDestinationAddImageAndMetadata(dst, img, tree, props as CFDictionary)
            } else {
                CGImageDestinationAddImage(dst, img, props as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(dst) else { throw PlatformError.encodeFailed("ImageIO could not write \(format.name)") }
        return out as Data
    }

    /// A 16-bit-float CGImage (for half EXR / TIFF).
    static func halfFloatImage(_ r: RasterBuffer, colorSpace: CGColorSpace?) throws -> CGImage {
        let f = r.converted(to: .f32).floats()
        var bytes = [UInt8](); bytes.reserveCapacity(f.count * 2)
        for v in f { withUnsafeBytes(of: Float16(v).bitPattern.littleEndian) { bytes += $0 } }
        let space = colorSpace ?? (r.format.mode.isGrayLike ? CGColorSpace(name: CGColorSpace.extendedLinearGray)! : CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        let info = CGBitmapInfo(rawValue: (r.format.alpha ? CGImageAlphaInfo.last : .none).rawValue).union([.byteOrder16Little, .floatComponents])
        guard let img = CGImage(width: r.width, height: r.height, bitsPerComponent: 16, bitsPerPixel: 16 * r.format.channels,
                                bytesPerRow: r.width * r.format.channels * 2, space: space, bitmapInfo: info,
                                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw PlatformError.encodeFailed("half-float CGImage") }
        return img
    }

    // MARK: Quality-targeted export (media-bridge MediaMeasure)

    /// Encodes at the lowest lossy quality whose decoded result still scores ≥ `targetScore` on
    /// SSIMULACRA2 against the original (media-bridge `ImageQualityTarget`): JPEG, HEIF, AVIF or
    /// WebP. Returns the bytes, the ImageIO/libwebp quality chosen and the achieved score.
    public static func encodeToQualityTarget(_ raster: RasterBuffer, as format: ImageFormat, targetScore: Double, profile: ICCProfile? = nil,
                                             iterations: Int = 8) throws -> (data: Data, quality: Double, score: Double, metTarget: Bool) {
        let (r, prof) = try prepare(raster, to: plan(raster.format, format: format, options: EncodeOptions(), hasMetadata: false, hasProfile: false).target, profile: profile)
        let cg = try SurfaceBridge.cgImage(r, colorSpace: prof?.cgColorSpace)
        let result: ImageQualityTarget.Result
        switch format {
        case .webp:
            let enc = WebPStillEncoder()
            result = try ImageQualityTarget.encode(cg, targetScore: targetScore, iterations: iterations, codec: "webp", backend: .cpu) { try enc.encode($0, quality: $1) }
        case .jpeg, .heif, .avif:
            let uti = format.uti
            result = try ImageQualityTarget.encode(cg, targetScore: targetScore, iterations: iterations, codec: format.rawValue, backend: .cpu) { img, q in
                let d = NSMutableData()
                guard let dst = CGImageDestinationCreateWithData(d, uti as CFString, 1, nil) else { throw PlatformError.unsupported(uti) }
                CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
                guard CGImageDestinationFinalize(dst) else { throw PlatformError.encodeFailed(uti) }
                return d as Data
            }
        default:
            throw PlatformError.unsupported("quality targeting needs a lossy format")
        }
        return (result.data, result.quality, result.score, result.metTarget)
    }
}
