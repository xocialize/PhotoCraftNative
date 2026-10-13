// Colour transforms with rendering intents, black-point compensation and soft-proof chains.
// Replaces photocraft-cms (crates/cms/src/{transform,pipeline,clut,curve,math}.rs) with ColorSync
// (`ColorSyncTransformCreate` / `ColorSyncTransformConvert`). Port of its API shape, MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft builds a float stage pipeline (curves, matrices, CLUTs, BPC) and samples device links
// for integer buffers. ColorSync does all of that natively: a transform here is a ColorSync profile
// sequence (source DeviceToPCS, destination PCSToDevice, with the intent), and
// `ColorSyncTransformConvert` converts 8/16-bit integer and 32-bit float buffers with straight alpha
// carried through. Black-point compensation and absolute colorimetric are applied at the PCS between
// two ColorSync legs (see `ColorTransform` for the measured reasons). Proof chains (photocraft
// `Transform::proof`) are two transforms applied in turn with the proof's device values clamped
// between them, as a real press would.

@preconcurrency import ColorSync
import Foundation
import PCFoundation
import Synchronization

/// ICC rendering intent (photocraft `Intent`).
public enum RenderingIntent: Int, CaseIterable, Sendable, Codable, Hashable {
    case perceptual = 0
    case relativeColorimetric = 1
    case saturation = 2
    case absoluteColorimetric = 3

    /// Parses `perceptual`, `relative`/`relativeColorimetric`, `saturation`,
    /// `absolute`/`absoluteColorimetric` or the ICC number (photocraft `Intent::parse`).
    public init?(parsing s: String) {
        switch s.lowercased().filter({ $0.isLetter || $0.isNumber }) {
        case "perceptual", "0": self = .perceptual
        case "relative", "relativecolorimetric", "colorimetric", "1": self = .relativeColorimetric
        case "saturation", "2": self = .saturation
        case "absolute", "absolutecolorimetric", "3": self = .absoluteColorimetric
        default: return nil
        }
    }

    public var id: String {
        switch self {
        case .perceptual: "perceptual"
        case .relativeColorimetric: "relative"
        case .saturation: "saturation"
        case .absoluteColorimetric: "absolute"
        }
    }

    var colorSyncValue: CFString {
        switch self {
        case .perceptual: kColorSyncRenderingIntentPerceptual.takeUnretainedValue()
        case .relativeColorimetric: kColorSyncRenderingIntentRelative.takeUnretainedValue()
        case .saturation: kColorSyncRenderingIntentSaturation.takeUnretainedValue()
        case .absoluteColorimetric: kColorSyncRenderingIntentAbsolute.takeUnretainedValue()
        }
    }
}

/// Transform settings (photocraft `TransformOptions`).
public struct TransformOptions: Sendable, Hashable {
    public var intent: RenderingIntent
    /// Black point compensation (Adobe's algorithm, ColorSync's implementation).
    public var blackPointCompensation: Bool
    /// Float data may leave 0…1 (HDR through matrix/TRC profiles).
    public var extendedRange: Bool

    public init(intent: RenderingIntent = .relativeColorimetric, blackPointCompensation: Bool = false, extendedRange: Bool = false) {
        self.intent = intent; self.blackPointCompensation = blackPointCompensation; self.extendedRange = extendedRange
    }

    /// Photoshop's default conversion: relative colorimetric with BPC.
    public static let photoshopDefault = TransformOptions(intent: .relativeColorimetric, blackPointCompensation: true)
}

/// How float Lab is encoded on the device side of a Lab profile.
public enum LabEncoding: Sendable {
    /// ColorSync 32-bit float with the Generic Lab profile: L/100 and (a − 0.5)·255 — measured on
    /// macOS 27.2 (sRGB red → 0.5429, 0.8169, 0.7741 = L*a*b* 54.29, 80.81, 69.90).
    case colorSync
    /// PCFoundation / PSD / photocraft (ICC v4 encoding): L/100, (a + 128)/255.
    case normalized

    public func decode(_ v: SIMD3<Float>) -> SIMD3<Double> {
        switch self {
        case .colorSync: SIMD3(Double(v.x) * 100, (Double(v.y) - 0.5) * 255, (Double(v.z) - 0.5) * 255)
        case .normalized: SIMD3(Double(v.x) * 100, Double(v.y) * 255 - 128, Double(v.z) * 255 - 128)
        }
    }

    public func encode(_ lab: SIMD3<Double>) -> SIMD3<Float> {
        switch self {
        case .colorSync: SIMD3(Float(lab.x / 100), Float(lab.y / 255 + 0.5), Float(lab.z / 255 + 0.5))
        case .normalized: SIMD3(Float(lab.x / 100), Float((lab.y + 128) / 255), Float((lab.z + 128) / 255))
        }
    }
}

/// A colour transform between two profiles, or a proof chain (photocraft `Transform`).
///
/// Black-point compensation is applied here, not by ColorSync: measured on macOS 27.2, setting
/// `kColorSyncBlackPointCompensation` shifts neutrals strongly (sRGB 50 % gray → Generic CMYK lands at
/// b* −8.9, coated CMYK at b* −7.8, against ±0.6 without it), so the BPC flag instead splits the
/// transform at the PCS and applies Adobe's neutral (Y-only) black-point scaling in XYZ between the
/// two ColorSync legs — photocraft's own formulation (`transform::connection`).
public final class ColorTransform: @unchecked Sendable {
    public let source: ICCProfile
    public let destination: ICCProfile
    public let options: TransformOptions
    /// The legs, applied in order: ColorSync conversions, PCS adjustments (BPC), and the clamp a
    /// proof device imposes.
    private let legs: [Leg]
    public let inputChannels: Int
    public let outputChannels: Int

    private enum Leg {
        /// A ColorSync transform producing `outputChannels`; `clamp` limits the result to 0…1.
        case colorSync(ColorSyncTransform, extended: Bool, outputChannels: Int, clamp: Bool)
        /// An affine map in D50 XYZ applied to ColorSync-encoded float Lab (3 channels).
        case pcs(scale: SIMD3<Double>, offset: SIMD3<Double>)

        var outputChannels: Int {
            switch self {
            case .colorSync(_, _, let n, _): n
            case .pcs: 3
            }
        }
    }

    /// A transform from `source` to `destination` (photocraft `Transform::new` / `with_options`).
    public convenience init(source: ICCProfile, destination: ICCProfile, intent: RenderingIntent = .relativeColorimetric,
                            blackPointCompensation: Bool = false) throws {
        try self.init(source: source, destination: destination,
                      options: TransformOptions(intent: intent, blackPointCompensation: blackPointCompensation))
    }

    public init(source: ICCProfile, destination: ICCProfile, options: TransformOptions) throws {
        if options.intent == .absoluteColorimetric {
            for p in [source, destination] { try Self.checkMediaWhite(p) }
        }
        self.source = source
        self.destination = destination
        self.options = options
        legs = try Self.link(source, destination, options, clampLast: false)
        inputChannels = source.channels
        outputChannels = destination.channels
    }

    private init(source: ICCProfile, destination: ICCProfile, options: TransformOptions, legs: [Leg]) {
        self.source = source; self.destination = destination; self.options = options; self.legs = legs
        inputChannels = source.channels; outputChannels = destination.channels
    }

    private static func checkMediaWhite(_ p: ICCProfile) throws {
        if let w = p.mediaWhitePoint, !(w.x > 0 && w.y > 0 && w.z > 0 && w.x.isFinite && w.y.isFinite && w.z.isFinite) {
            // photocraft refuses a degenerate media white for absolute colorimetric (it would
            // divide by it); ColorSync would silently produce garbage.
            throw PlatformError.invalidProfile("absolute colorimetric needs a positive media white (\(p.profileDescription))")
        }
    }

    /// The legs from `src` to `dst`: one ColorSync transform, or src → Lab, a PCS map, Lab → dst
    /// when the PCS needs adjusting (BPC whose black points differ; absolute colorimetric whose
    /// media whites differ).
    ///
    /// Absolute colorimetric is likewise done here as relative colorimetric plus photocraft's
    /// media-white scaling (`transform::connection`), with display-class profiles' white taken as
    /// D50 (ICC v4 semantics, as photocraft and Photoshop treat v2 monitor profiles). ColorSync's own
    /// absolute intent uses a v2 display profile's D65 `wtpt`, which turns photocraft's coated paper
    /// (Lab 95/0/−2, slightly blue) yellow on an sRGB display (measured 0.99/0.93/0.83), and it
    /// refuses some profiles outright (ROMM RGB → Lab).
    private static func link(_ src: ICCProfile, _ dst: ICCProfile, _ o: TransformOptions, clampLast: Bool) throws -> [Leg] {
        let lab = BuiltinProfile.labD50.profile
        if o.intent == .absoluteColorimetric {
            let rel = TransformOptions(intent: .relativeColorimetric, blackPointCompensation: false, extendedRange: o.extendedRange)
            let ws = mediaWhite(src), wd = mediaWhite(dst)
            let scale = ws / wd
            let dev = scale - SIMD3<Double>(repeating: 1)
            if max(abs(dev.x), abs(dev.y), abs(dev.z)) < 1e-6 {
                return [.colorSync(try make(src, dst, rel), extended: o.extendedRange, outputChannels: dst.channels, clamp: clampLast)]
            }
            return [.colorSync(try make(src, lab, rel), extended: true, outputChannels: 3, clamp: false),
                    .pcs(scale: scale, offset: .zero),
                    .colorSync(try make(lab, dst, rel), extended: o.extendedRange, outputChannels: dst.channels, clamp: clampLast)]
        }
        let plain = TransformOptions(intent: o.intent, blackPointCompensation: false, extendedRange: o.extendedRange)
        if o.blackPointCompensation {
            let bs = try ColorMath.blackPoint(src, intent: o.intent)
            let bd = try ColorMath.blackPoint(dst, intent: o.intent)
            if abs(bs - bd) > 1e-6 {
                let w = ColorMath.d50
                let s = bs * w, d = bd * w
                let scale = (w - d) / (w - s)
                let offset = w * (SIMD3(repeating: 1) - scale)
                return [.colorSync(try make(src, lab, plain), extended: true, outputChannels: 3, clamp: false),
                        .pcs(scale: scale, offset: offset),
                        .colorSync(try make(lab, dst, plain), extended: o.extendedRange, outputChannels: dst.channels, clamp: clampLast)]
            }
        }
        return [.colorSync(try make(src, dst, plain), extended: o.extendedRange, outputChannels: dst.channels, clamp: clampLast)]
    }

    /// The media white used for absolute colorimetric: D50 for display-class, Lab/XYZ and
    /// white-less profiles, else `wtpt`.
    private static func mediaWhite(_ p: ICCProfile) -> SIMD3<Double> {
        if p.deviceClass == .display || p.colorSpace == .lab || p.colorSpace == .xyz { return ColorMath.d50 }
        return p.mediaWhitePoint ?? ColorMath.d50
    }

    /// A soft-proof chain: `source` → `proof` with `intent` (and BPC), the proof's device values
    /// clamped, then `proof` → `display` relative colorimetric with BPC, or absolute colorimetric
    /// without BPC when `simulatePaper` (Photoshop's View ▸ Proof Colors with Simulate Paper Color /
    /// Simulate Black Ink; photocraft `Transform::proof`).
    public static func proof(source: ICCProfile, proof: ICCProfile, display: ICCProfile,
                             intent: RenderingIntent = .relativeColorimetric, blackPointCompensation: Bool = true,
                             simulatePaper: Bool = false) throws -> ColorTransform {
        let first = TransformOptions(intent: intent, blackPointCompensation: blackPointCompensation)
        let second = TransformOptions(intent: simulatePaper ? .absoluteColorimetric : .relativeColorimetric,
                                      blackPointCompensation: !simulatePaper)
        if intent == .absoluteColorimetric { try checkMediaWhite(source) }
        if simulatePaper || intent == .absoluteColorimetric {
            try checkMediaWhite(proof)
            try checkMediaWhite(display)
        }
        let legs = try link(source, proof, first, clampLast: true) + link(proof, display, second, clampLast: false)
        return ColorTransform(source: source, destination: display, options: first, legs: legs)
    }

    private static func make(_ src: ICCProfile, _ dst: ICCProfile, _ o: TransformOptions) throws -> ColorSyncTransform {
        let kProfile = kColorSyncProfile.takeUnretainedValue() as String
        let kIntent = kColorSyncRenderingIntent.takeUnretainedValue() as String
        let kTag = kColorSyncTransformTag.takeUnretainedValue() as String
        let seq: [[String: Any]] = [
            [kProfile: src.colorSyncProfile, kIntent: o.intent.colorSyncValue,
             kTag: kColorSyncTransformDeviceToPCS.takeUnretainedValue()],
            [kProfile: dst.colorSyncProfile, kIntent: o.intent.colorSyncValue,
             kTag: kColorSyncTransformPCSToDevice.takeUnretainedValue()],
        ]
        var opts: [String: Any] = [kColorSyncConvertQuality.takeUnretainedValue() as String: kColorSyncBestQuality.takeUnretainedValue()]
        if o.extendedRange { opts[kColorSyncExtendedRange.takeUnretainedValue() as String] = true }
        guard let t = ColorSyncTransformCreate(seq as CFArray, opts as CFDictionary)?.takeRetainedValue() else {
            throw PlatformError.invalidProfile("ColorSync cannot build \(src.profileDescription) → \(dst.profileDescription) (\(o.intent.id))")
        }
        return t
    }

    /// Whether this transform is one ColorSync call (its integer paths then run at native depth).
    public var isSingleColorSyncTransform: Bool {
        if legs.count == 1, case .colorSync(_, _, _, false) = legs[0] { return true }
        return false
    }

    // MARK: Cache

    private struct CacheKey: Hashable { let src: Data; let dst: Data; let options: TransformOptions }
    private static let cache = Mutex<[CacheKey: ColorTransform]>([:])

    /// A process-wide cached transform (photocraft `transform::cached`).
    public static func cached(source: ICCProfile, destination: ICCProfile, options: TransformOptions) throws -> ColorTransform {
        let key = CacheKey(src: source.md5, dst: destination.md5, options: options)
        if let t = cache.withLock({ $0[key] }) { return t }
        let t = try ColorTransform(source: source, destination: destination, options: options)
        cache.withLock { $0[key] = t }
        return t
    }

    // MARK: Conversion

    /// Converts one colour exactly (photocraft `Transform::eval`); `input` has `inputChannels`
    /// normalised values.
    public func eval(_ input: [Float]) -> [Float] {
        convert(Array(input.prefix(inputChannels)), pixelCount: 1)
    }

    /// Converts `pixelCount` interleaved float pixels (`inputChannels` each, plus one alpha when
    /// `alpha`, copied through) to `outputChannels` (+ alpha) each.
    public func convert(_ src: [Float], pixelCount: Int, alpha: Bool = false) -> [Float] {
        var data = src
        var ch = inputChannels + (alpha ? 1 : 0)
        for leg in legs {
            let outCh = leg.outputChannels + (alpha ? 1 : 0)
            switch leg {
            case .colorSync(let t, let extended, _, let clamp):
                var out = [Float](repeating: 0, count: pixelCount * outCh)
                let layout = UInt32(alpha ? kColorSyncAlphaLast.rawValue : kColorSyncAlphaNone.rawValue) | UInt32(kColorSyncByteOrder32Little)
                let ok = data.withUnsafeBytes { s in
                    out.withUnsafeMutableBytes { d in
                        ColorSyncTransformConvert(t, pixelCount, 1, d.baseAddress!, kColorSync32BitFloat, layout, pixelCount * outCh * 4,
                                                  s.baseAddress!, kColorSync32BitFloat, layout, pixelCount * ch * 4,
                                                  extended ? ([kColorSyncConvertUseExtendedRange.takeUnretainedValue() as String: true] as CFDictionary) : nil)
                    }
                }
                if !ok { out = [Float](repeating: .nan, count: out.count) }
                if clamp {
                    // A proof device cannot print outside its range.
                    for k in out.indices { out[k] = min(max(out[k], 0), 1) }
                }
                data = out
            case .pcs(let scale, let offset):
                for p in 0..<pixelCount {
                    let i = p * ch
                    let lab = LabEncoding.colorSync.decode(SIMD3(data[i], data[i + 1], data[i + 2]))
                    let xyz = ColorMath.labToXYZ(lab) * scale + offset
                    let e = LabEncoding.colorSync.encode(ColorMath.xyzToLab(xyz))
                    data[i] = e.x; data[i + 1] = e.y; data[i + 2] = e.z
                }
            }
            ch = outCh
        }
        return data
    }

    /// Converts a raster whose model matches the source profile to the destination's model at
    /// `sample` (the raster's own depth when nil). Alpha is carried through. Integer rasters of a
    /// single leg go straight through ColorSync at their own depth; everything else through float.
    public func convert(_ r: RasterBuffer, to sample: SampleType? = nil) throws -> RasterBuffer {
        guard r.format.mode.colorChannels == inputChannels else {
            throw PlatformError.invalidArgument("raster has \(r.format.mode.colorChannels) colour channels, transform expects \(inputChannels)")
        }
        guard let outMode = destination.colorMode else { throw PlatformError.unsupported("destination \(destination.colorSpace) is not a document model") }
        let target = PixelFormat(mode: outMode, sample: sample ?? r.format.sample, alpha: r.format.alpha)
        let n = r.width * r.height
        if isSingleColorSyncTransform, case .colorSync(let t, _, _, _) = legs[0],
           target.sample == r.format.sample, r.format.sample != .f32, r.format.mode != .lab, outMode != .lab {
            var out = RasterBuffer(width: r.width, height: r.height, format: target)
            let depth = r.format.sample == .u8 ? kColorSync8BitInteger : kColorSync16BitInteger
            let order = r.format.sample == .u16 ? UInt32(kColorSyncByteOrder16Little) : 0
            let layout = UInt32(r.format.alpha ? kColorSyncAlphaLast.rawValue : kColorSyncAlphaNone.rawValue) | order
            let ok = r.bytes.withUnsafeBytes { s in
                out.bytes.withUnsafeMutableBytes { d in
                    ColorSyncTransformConvert(t, r.width, r.height, d.baseAddress!, depth, layout, r.width * target.bytesPerPixel,
                                              s.baseAddress!, depth, layout, r.width * r.format.bytesPerPixel, nil)
                }
            }
            if !ok { throw PlatformError.frameworkFailure("ColorSyncTransformConvert") }
            return out
        }
        // Float path; Lab sides switch between PCFoundation's and ColorSync's encodings.
        var f = r.floats()
        let ich = r.format.channels
        if r.format.mode == .lab {
            for i in stride(from: 0, to: f.count, by: ich) {
                let e = LabEncoding.colorSync.encode(LabEncoding.normalized.decode(SIMD3(f[i], f[i + 1], f[i + 2])))
                f[i] = e.x; f[i + 1] = e.y; f[i + 2] = e.z
            }
        }
        var o = convert(f, pixelCount: n, alpha: r.format.alpha)
        let och = target.channels
        if outMode == .lab {
            for i in stride(from: 0, to: o.count, by: och) {
                let e = LabEncoding.normalized.encode(LabEncoding.colorSync.decode(SIMD3(o[i], o[i + 1], o[i + 2])))
                o[i] = e.x; o[i + 1] = e.y; o[i + 2] = e.z
            }
        }
        return RasterBuffer(width: r.width, height: r.height, format: target, floats: o)
    }

    /// Converts every tile of a surface (photocraft's document Mode change through `convert_*`).
    /// The default pixel converts too.
    public func convert(_ s: Surface, to sample: SampleType? = nil) throws -> Surface {
        guard let outMode = destination.colorMode else { throw PlatformError.unsupported("destination is not a document model") }
        let target = PixelFormat(mode: outMode, sample: sample ?? s.format.sample, alpha: s.format.alpha)
        let def = RasterBuffer(width: 1, height: 1, format: s.format, floats: s.defaultPixelValue)
        let defOut = try convert(def, to: target.sample).floats()
        var out = Surface(format: target, defaultPixel: defOut)
        for c in s.tileCoords {
            let r = c.rect
            let conv = try convert(RasterBuffer(surface: s, rect: r), to: target.sample)
            out.writeInterleaved(r, conv.bytes)
        }
        return out
    }
}
