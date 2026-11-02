// Camera raw: open any raw Core Image supports, develop it with photocraft's parameters, render to a
// 16-bit or float raster, read the embedded preview and the metadata.
// Replaces photocraft-raw (crates/raw: clean-room TIFF/DNG/CR2/NEF/ARW/RW2/ORF/RAF/PEF decode, LJPEG,
// demosaic, colour, tone, look fitting) with Core Image's `CIRAWFilter` (Apple's RAW decoder: ~800
// bodies, CR3 included, decoder v9's neural demosaic + denoise). Port of its API shape (`develop`,
// `DevelopOptions`, `Developed`, `RawInfo`, `embedded_preview`), MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.
//
// media-bridge's ImageBridge already decodes raw through CIRAWFilter (`RawDecoderImpl`) with
// `RawDecodeOptions`; its decoder is internal and narrows to 8-bit display-referred BGRA (its P1), and
// its public factory takes no raw options. So this module reuses ImageBridge's public
// `RawDecodeOptions` as the shared knob set — applied the way ImageBridge applies it (only knobs the
// caller set; decoder version only when supported; NR off = colour NR zeroed) — and extends it with
// the rest of photocraft's develop parameters and a 16-bit / float render. The 8-bit faithful path is
// `ImageCodecs.decodeDisplay8(url:)`, which calls ImageBridge directly.

import CoreImage
import Foundation
import ImageBridge
import ImageIO
import PCFoundation

/// Camera Raw's Shadows/Highlights/Clarity/Texture/Dehaze, −100…100 (photocraft `Tone`).
public struct RawTone: Sendable, Equatable {
    public var shadows: Double = 0
    public var highlights: Double = 0
    public var clarity: Double = 0
    public var texture: Double = 0
    public var dehaze: Double = 0
    public init(shadows: Double = 0, highlights: Double = 0, clarity: Double = 0, texture: Double = 0, dehaze: Double = 0) {
        self.shadows = shadows; self.highlights = highlights; self.clarity = clarity; self.texture = texture; self.dehaze = dehaze
    }
    public static let neutral = RawTone()
    public var isNeutral: Bool { self == .neutral }
}

/// What the developed pixels are encoded in.
public enum RawOutput: Sendable, Equatable {
    /// 16-bit RGB in ROMM / ProPhoto RGB — photocraft's output.
    case proPhoto16
    /// 32-bit float ProPhoto RGB (gamma 1.8).
    case proPhotoFloat
    /// 32-bit float scene-linear sRGB primaries, unclipped, without the base tone curve (boost 0
    /// unless set) — a 32-bit HDR document.
    case linearFloat
    case sRGB16
    case displayP3_16
}

/// Development settings (photocraft `DevelopOptions` on top of ImageBridge's `RawDecodeOptions`).
public struct RawDevelopSettings: Sendable, Equatable {
    /// media-bridge's knobs: decoder version, exposure (EV), boost, white-balance temperature (K)
    /// and tint, raw noise reduction on/off.
    public var decode: RawDecodeOptions = .faithful
    /// Apply the file's orientation (photocraft `orient`).
    public var orient = true
    public var tone = RawTone.neutral
    /// 0…1 amounts; nil leaves the decoder's camera default.
    public var luminanceNoiseReduction: Double?
    public var colorNoiseReduction: Double?
    public var sharpness: Double?
    public var contrast: Double?
    public var detail: Double?
    public var moireReduction: Double?
    /// Local tone mapping (CIRAWFilter's), 0…1.
    public var localToneMap: Double?
    /// Lens correction (distortion/vignetting from the file's lens profile); nil = decoder default.
    public var lensCorrection: Bool?
    public var gamutMapping: Bool?
    /// Extended dynamic range headroom amount, 0…1 (`linearFloat` output keeps values above 1).
    public var extendedDynamicRange: Double?
    /// Draft scale (e.g. 0.5 renders half size).
    public var scale: Double = 1
    public var output: RawOutput = .proPhoto16

    public init() {}

    /// photocraft-style settings: exposure compensation, an explicit white balance and tone.
    public init(exposure: Double, temperature: Double? = nil, tint: Double? = nil, tone: RawTone = .neutral) {
        decode = RawDecodeOptions(exposureEV: Float(exposure), neutralTemperature: temperature.map(Float.init), neutralTint: tint.map(Float.init))
        self.tone = tone
    }
}

/// What was developed (photocraft `RawInfo`).
public struct RawInfo: Sendable, Equatable {
    public var make: String?
    public var model: String?
    public var lens: String?
    public var iso: Double?
    public var exposureTime: Double?
    public var fNumber: Double?
    public var focalLength: Double?
    /// Sensor-native size before scaling / orientation.
    public var nativeWidth: Int
    public var nativeHeight: Int
    public var orientation: Int
    /// The as-shot white balance the decoder reports.
    public var asShotTemperature: Double
    public var asShotTint: Double
    public var baselineExposure: Double
    public var decoderVersion: String
    public var supportedDecoderVersions: [String]
    public var supportsLensCorrection: Bool
    public var supportsNoiseReduction: Bool
}

/// A developed raw (photocraft `Developed`).
public struct DevelopedRaw: Sendable {
    public var raster: RasterBuffer
    public var profile: ICCProfile
    public var info: RawInfo
    public var metadata: ImageMetadata
    /// Settings that were approximated or not applied.
    public var warnings: [String]
}

public enum RawDeveloper {
    /// GPU-backed CIContext with half-float intermediates (thread-safe; shared).
    static let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

    /// Camera models Core Image's raw decoder lists (DNG from any camera is supported besides).
    public static var supportedCameraModels: [String] { CIRAWFilter.supportedCameraModels }

    /// Whether Core Image can develop these bytes.
    public static func isSupported(data: Data) -> Bool {
        guard let f = CIRAWFilter(imageData: data, identifierHint: nil) else { return false }
        return f.nativeSize.width > 0 && f.nativeSize.height > 0
    }

    public static func develop(url: URL, settings: RawDevelopSettings = RawDevelopSettings()) throws -> DevelopedRaw {
        try develop(data: try Data(contentsOf: url, options: .mappedIfSafe), settings: settings)
    }

    /// Develops raw bytes (photocraft `develop`).
    public static func develop(data: Data, settings: RawDevelopSettings = RawDevelopSettings()) throws -> DevelopedRaw {
        let hint = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }
        guard let filter = CIRAWFilter(imageData: data, identifierHint: hint), filter.nativeSize.width > 0 else {
            throw PlatformError.unsupported("Core Image's raw decoder does not support this file")
        }
        let asShotT = Double(filter.neutralTemperature), asShotTint = Double(filter.neutralTint)
        let fileOrientation = Int(filter.orientation.rawValue)
        var warnings: [String] = []
        apply(settings, to: filter, warnings: &warnings)
        guard var image = filter.outputImage, !image.extent.isEmpty, !image.extent.isInfinite else {
            throw PlatformError.unsupported("Core Image returned no image for this raw (camera not supported yet)")
        }
        image = applyTone(settings.tone, to: image, warnings: &warnings)
        let (space, sample, profile) = outputSpace(settings.output)
        let w = Int(image.extent.width.rounded()), h = Int(image.extent.height.rounded())
        let raster: RasterBuffer
        let origin = image.extent.origin
        let bounds = CGRect(x: origin.x, y: origin.y, width: CGFloat(w), height: CGFloat(h))
        if sample == .u16 {
            var buf = [UInt16](repeating: 0, count: w * h * 4)
            context.render(image, toBitmap: &buf, rowBytes: w * 8, bounds: bounds, format: .RGBA16, colorSpace: space)
            var rgb = [UInt8](repeating: 0, count: w * h * 6)
            rgb.withUnsafeMutableBytes { d in
                for i in 0..<(w * h) { for k in 0..<3 { d.storeBytes(of: buf[i * 4 + k], toByteOffset: (i * 3 + k) * 2, as: UInt16.self) } }
            }
            raster = RasterBuffer(width: w, height: h, format: PixelFormat(mode: .rgb, sample: .u16, alpha: false), bytes: rgb)
        } else {
            var buf = [Float](repeating: 0, count: w * h * 4)
            context.render(image, toBitmap: &buf, rowBytes: w * 16, bounds: bounds, format: .RGBAf, colorSpace: space)
            var rgb = [Float](repeating: 0, count: w * h * 3)
            for i in 0..<(w * h) { for k in 0..<3 { rgb[i * 3 + k] = buf[i * 4 + k] } }
            raster = RasterBuffer(width: w, height: h, format: PixelFormat(mode: .rgb, sample: .f32, alpha: false), floats: rgb)
        }
        var meta = ImageMetadata()
        var info = RawInfo(nativeWidth: Int(filter.nativeSize.width), nativeHeight: Int(filter.nativeSize.height), orientation: fileOrientation,
                           asShotTemperature: asShotT, asShotTint: asShotTint, baselineExposure: Double(filter.baselineExposure),
                           decoderVersion: filter.decoderVersion.rawValue, supportedDecoderVersions: filter.supportedDecoderVersions.map(\.rawValue),
                           supportsLensCorrection: filter.isLensCorrectionSupported,
                           supportsNoiseReduction: filter.isLuminanceNoiseReductionSupported || filter.isColorNoiseReductionSupported)
        if let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 {
            meta = ImageMetadata.read(source: src, index: 0)
            let p = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
            let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
            let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            let aux = p[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
            info.make = tiff[kCGImagePropertyTIFFMake as String] as? String
            info.model = tiff[kCGImagePropertyTIFFModel as String] as? String
            info.lens = (exif[kCGImagePropertyExifLensModel as String] as? String) ?? (aux[kCGImagePropertyExifAuxLensModel as String] as? String)
            info.iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Double])?.first
            info.exposureTime = exif[kCGImagePropertyExifExposureTime as String] as? Double
            info.fNumber = exif[kCGImagePropertyExifFNumber as String] as? Double
            info.focalLength = exif[kCGImagePropertyExifFocalLength as String] as? Double
        }
        // CIRAWFilter has applied the orientation (unless told not to): the pixels are upright.
        meta.orientation = settings.orient ? 1 : fileOrientation
        return DevelopedRaw(raster: raster, profile: profile, info: info, metadata: meta, warnings: warnings)
    }

    /// The camera's embedded preview (photocraft `embedded_preview`), as 8-bit RGBA sRGB, upright.
    public static func embeddedPreview(data: Data, maxPixelSize: Int? = nil) -> RasterBuffer? {
        if let f = CIRAWFilter(imageData: data, identifierHint: nil), let p = f.previewImage, !p.extent.isEmpty, !p.extent.isInfinite,
           let cg = context.createCGImage(p, from: p.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
            return try? SurfaceBridge.rgba8sRGB(cg)
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var opts: [CFString: Any] = [kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceCreateThumbnailFromImageIfAbsent: true]
        if let m = maxPixelSize { opts[kCGImageSourceThumbnailMaxPixelSize] = m }
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return try? SurfaceBridge.rgba8sRGB(cg)
    }

    // MARK: Mapping

    /// photocraft develop parameters → CIRAWFilter properties. ImageBridge's options are applied as
    /// ImageBridge applies them.
    static func apply(_ s: RawDevelopSettings, to f: CIRAWFilter, warnings: inout [String]) {
        let o = s.decode
        switch o.decoderVersion {
        case .osDefault: break
        case .version8: if f.supportedDecoderVersions.contains(.version8) { f.decoderVersion = .version8 } else { warnings.append("decoder version 8 unavailable") }
        // Version 9 is macOS 27's (AB-T-0419): before it, the OS default decodes, as for any version the filter lacks.
        case .version9:
            if #available(macOS 27.0, *), f.supportedDecoderVersions.contains(.version9) { f.decoderVersion = .version9 }
            else { warnings.append("decoder version 9 unavailable") }
        }
        if let ev = o.exposureEV { f.exposure = ev }
        if let b = o.boost { f.boostAmount = b } else if s.output == .linearFloat {
            // Scene-linear output: no base tone curve (boost), so exposure doubles light per EV.
            f.boostAmount = 0
        }
        if let t = o.neutralTemperature { f.neutralTemperature = t }
        if let t = o.neutralTint { f.neutralTint = t }
        if !o.enableRawNoiseReduction {
            if f.isColorNoiseReductionSupported { f.colorNoiseReductionAmount = 0 }
            if f.isLuminanceNoiseReductionSupported { f.luminanceNoiseReductionAmount = 0 }
        }
        func set(_ v: Double?, _ supported: Bool, _ name: String, _ assign: (Float) -> Void) {
            guard let v else { return }
            if supported { assign(Float(v)) } else { warnings.append("\(name) is not supported for this file / decoder version") }
        }
        set(s.luminanceNoiseReduction, f.isLuminanceNoiseReductionSupported, "luminance noise reduction") { f.luminanceNoiseReductionAmount = $0 }
        set(s.colorNoiseReduction, f.isColorNoiseReductionSupported, "colour noise reduction") { f.colorNoiseReductionAmount = $0 }
        set(s.sharpness, f.isSharpnessSupported, "sharpness") { f.sharpnessAmount = $0 }
        set(s.contrast, f.isContrastSupported, "contrast") { f.contrastAmount = $0 }
        set(s.detail, f.isDetailSupported, "detail") { f.detailAmount = $0 }
        set(s.moireReduction, f.isMoireReductionSupported, "moiré reduction") { f.moireReductionAmount = $0 }
        set(s.localToneMap, f.isLocalToneMapSupported, "local tone map") { f.localToneMapAmount = $0 }
        if let l = s.lensCorrection {
            if f.isLensCorrectionSupported { f.isLensCorrectionEnabled = l } else if l { warnings.append("no lens correction for this camera/lens") }
        }
        if let g = s.gamutMapping { f.isGamutMappingEnabled = g }
        if let e = s.extendedDynamicRange { f.extendedDynamicRangeAmount = Float(e) }
        if s.scale != 1 { f.scaleFactor = Float(s.scale) }
        if !s.orient { f.orientation = .up }
    }

    /// Camera Raw's Light/Presence sliders, approximated with Core Image filters after the decode
    /// (photocraft computes them in linear light with a guided-filter base layer).
    static func applyTone(_ t: RawTone, to image: CIImage, warnings: inout [String]) -> CIImage {
        var img = image
        if t.shadows != 0 || t.highlights != 0 {
            let f = CIFilter(name: "CIHighlightShadowAdjust")!
            f.setValue(img, forKey: kCIInputImageKey)
            // Shadows +100 → +1 lift, −100 → −1. Highlights −100 → 0 (full recovery); positive
            // highlights cannot brighten in this filter.
            f.setValue(t.shadows / 100, forKey: "inputShadowAmount")
            f.setValue(1 + min(t.highlights, 0) / 100, forKey: "inputHighlightAmount")
            if t.highlights > 0 { warnings.append("positive Highlights are not available natively (CIHighlightShadowAdjust only recovers)") }
            img = f.outputImage ?? img
        }
        let long = Double(max(image.extent.width, image.extent.height))
        if t.clarity != 0 {
            // Clarity: large-radius local contrast.
            let f = CIFilter(name: "CIUnsharpMask")!
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(max(long * 0.02, 4), forKey: kCIInputRadiusKey)
            f.setValue(t.clarity / 100 * 0.6, forKey: kCIInputIntensityKey)
            img = f.outputImage?.cropped(to: image.extent) ?? img
            warnings.append("Clarity approximated by a large-radius unsharp mask")
        }
        if t.texture != 0 {
            let f = CIFilter(name: "CIUnsharpMask")!
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(max(long * 0.003, 1.5), forKey: kCIInputRadiusKey)
            f.setValue(t.texture / 100 * 0.8, forKey: kCIInputIntensityKey)
            img = f.outputImage?.cropped(to: image.extent) ?? img
            warnings.append("Texture approximated by a medium-radius unsharp mask")
        }
        if t.dehaze != 0 { warnings.append("Dehaze has no Core Image equivalent; not applied") }
        return img
    }

    static func outputSpace(_ o: RawOutput) -> (CGColorSpace, SampleType, ICCProfile) {
        switch o {
        case .proPhoto16: (BuiltinProfile.proPhoto.profile.cgColorSpace!, .u16, BuiltinProfile.proPhoto.profile)
        case .proPhotoFloat: (BuiltinProfile.proPhoto.profile.cgColorSpace!, .f32, BuiltinProfile.proPhoto.profile)
        case .linearFloat: (CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .f32, BuiltinProfile.linearSRGB.profile)
        case .sRGB16: (CGColorSpace(name: CGColorSpace.sRGB)!, .u16, BuiltinProfile.srgb.profile)
        case .displayP3_16: (CGColorSpace(name: CGColorSpace.displayP3)!, .u16, BuiltinProfile.displayP3.profile)
        }
    }
}
