// Colour values and model conversions.
// Port of photocraft-color (crates/color/src/{lib,convert}.rs), MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors. photocraft's managed CMYK path runs its own pure-Rust ICC engine
// (photocraft-cms); here it runs through ColorSync (CGColorSpace / CGColorConversionInfo), which
// PCPlatform installs as the process-wide `ColorConvert.cmyk` converter. The naive formulas below
// are the fallback, as in photocraft. A document's own CMYK profile replaces the process-wide one
// inside `ColorConvert.withCMYK(_:_:)` (photocraft `with_cmyk_space`): a task-local scope instead of
// photocraft's thread-local one, so it follows the task (and its child tasks) across threads.

import CoreGraphics
import Foundation
import simd
import Synchronization

/// Converts CMYK ⇄ sRGB through a colour-managed transform.
public protocol CMYKConverter: Sendable {
    func cmykToRGB(_ c: SIMD4<Float>) -> SIMD3<Float>
    func rgbToCMYK(_ rgb: SIMD3<Float>) -> SIMD4<Float>
    /// A whole buffer in one transform (a ColorSync conversion per tile instead of per pixel).
    func cmykToRGB(batch: [SIMD4<Float>]) -> [SIMD3<Float>]
    func rgbToCMYK(batch: [SIMD3<Float>]) -> [SIMD4<Float>]
}

extension CMYKConverter {
    public func cmykToRGB(batch: [SIMD4<Float>]) -> [SIMD3<Float>] { batch.map { cmykToRGB($0) } }
    public func rgbToCMYK(batch: [SIMD3<Float>]) -> [SIMD4<Float>] { batch.map { rgbToCMYK($0) } }
}

public enum ColorConvert {
    private static let converter = Mutex<(any CMYKConverter)?>(nil)

    /// The process-wide managed CMYK converter (ColorSync-backed, installed by PCPlatform).
    /// `nil` falls back to the naive formulas. A scoped converter (`withCMYK`) takes precedence.
    public static var cmyk: (any CMYKConverter)? {
        get { converter.withLock { $0 } }
        set { converter.withLock { $0 = newValue } }
    }

    /// The converter of the innermost `withCMYK` scope of the current task, if any.
    @TaskLocal static var scoped: (any CMYKConverter)?

    /// The converter the CMYK conversions use here: the scoped one (`withCMYK`), else the
    /// process-wide `cmyk`, else nil (the naive formulas).
    public static var activeCMYK: (any CMYKConverter)? { scoped ?? cmyk }

    /// Runs `body` with `converter` as the CMYK profile of every CMYK conversion it makes on this
    /// task and its child tasks (photocraft `with_cmyk_space`: a document's own CMYK profile for its
    /// strokes, fills and reads). `nil` restores the process-wide converter inside the scope.
    /// Work handed to threads outside the task tree (a `DispatchQueue`, `Task.detached`) must
    /// enter the scope itself, as photocraft's parallel workers do.
    public static func withCMYK<R>(_ converter: (any CMYKConverter)?, _ body: () throws -> R) rethrows -> R {
        try $scoped.withValue(converter, operation: body)
    }

    /// `withCMYK` for asynchronous work (runs on the caller's executor).
    public nonisolated(nonsending) static func withCMYK<R>(_ converter: (any CMYKConverter)?,
                                                          _ body: nonisolated(nonsending) () async throws -> R) async rethrows -> R {
        try await $scoped.withValue(converter, operation: body)
    }

    /// The D50 white point. photocraft's value (CIE/ASTM E308 Z = 0.82521), kept for parity; the ICC
    /// PCS illuminant that ColorSync uses has Z = 0.8249 (measured difference ΔE 0.002).
    public static let d50 = SIMD3<Float>(0.96422, 1.0, 0.82521)

    /// Linear sRGB → D50 XYZ (Bradford-adapted, as in the ICC sRGB profile). Rows.
    public static let srgbToXYZD50: [SIMD3<Float>] = [
        SIMD3(0.436074, 0.385064, 0.143080), SIMD3(0.222504, 0.716878, 0.060618), SIMD3(0.013932, 0.097104, 0.714173),
    ]
    /// D50 XYZ → linear sRGB. Rows.
    public static let xyzD50ToSRGB: [SIMD3<Float>] = [
        SIMD3(3.133856, -1.616867, -0.490615), SIMD3(-0.978768, 1.916142, 0.033454), SIMD3(0.071945, -0.228991, 1.405243),
    ]

    /// `m` (rows) × `v`.
    @inlinable public static func mul(_ m: [SIMD3<Float>], _ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3((m[0] * v).sum(), (m[1] * v).sum(), (m[2] * v).sum())
    }

    /// sRGB transfer function: encoded → linear.
    @inlinable public static func srgbToLinear(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
    }

    /// sRGB transfer function: linear → encoded.
    @inlinable public static func linearToSRGB(_ v: Float) -> Float {
        v <= 0.0031308 ? v * 12.92 : 1.055 * powf(v, 1 / 2.4) - 0.055
    }

    /// Naive CMYK → RGB (no profile): `(1 − c)(1 − k)`.
    public static func cmykToRGBNaive(_ c: SIMD4<Float>) -> SIMD3<Float> {
        let k = 1 - c.w
        return SIMD3((1 - c.x) * k, (1 - c.y) * k, (1 - c.z) * k)
    }

    /// Naive RGB → CMYK with full GCR.
    public static func rgbToCMYKNaive(_ rgb: SIMD3<Float>) -> SIMD4<Float> {
        let k = 1 - rgb.max()
        if k >= 1 - 1e-6 { return SIMD4(0, 0, 0, 1) }
        let d = 1 - k
        return SIMD4((1 - rgb.x - k) / d, (1 - rgb.y - k) / d, (1 - rgb.z - k) / d, k)
    }

    /// Colour-managed CMYK → sRGB (the scoped or installed converter, else naive).
    public static func cmykToRGB(_ c: SIMD4<Float>) -> SIMD3<Float> {
        if let conv = activeCMYK { return conv.cmykToRGB(c) }
        return cmykToRGBNaive(c)
    }

    /// Colour-managed CMYK → sRGB for a whole buffer.
    public static func cmykToRGB(batch: [SIMD4<Float>]) -> [SIMD3<Float>] {
        if let conv = activeCMYK { return conv.cmykToRGB(batch: batch) }
        return batch.map(cmykToRGBNaive)
    }

    /// Colour-managed sRGB → CMYK for a whole buffer.
    public static func rgbToCMYK(batch: [SIMD3<Float>]) -> [SIMD4<Float>] {
        let clamped = batch.map { simd_clamp($0, SIMD3(repeating: 0), SIMD3(repeating: 1)) }
        if let conv = activeCMYK { return conv.rgbToCMYK(batch: clamped) }
        return clamped.map(rgbToCMYKNaive)
    }

    /// Colour-managed sRGB → CMYK (the scoped or installed converter, else naive).
    public static func rgbToCMYK(_ rgb: SIMD3<Float>) -> SIMD4<Float> {
        let v = simd_clamp(rgb, SIMD3(repeating: 0), SIMD3(repeating: 1))
        if let conv = activeCMYK { return conv.rgbToCMYK(v) }
        return rgbToCMYKNaive(v)
    }

    /// CIE L*a*b* (D50; L 0…100, a/b −128…127) → encoded sRGB.
    public static func labToSRGB(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let fy = (lab.x + 16) / 116
        let fx = fy + lab.y / 500
        let fz = fy - lab.z / 200
        let e: Float = 6.0 / 29.0
        func finv(_ t: Float) -> Float { t > e ? t * t * t : 3 * e * e * (t - 4.0 / 29.0) }
        let xyz = SIMD3(finv(fx), finv(fy), finv(fz)) * d50
        let lin = mul(xyzD50ToSRGB, xyz)
        return SIMD3(linearToSRGB(min(max(lin.x, 0), 1)), linearToSRGB(min(max(lin.y, 0), 1)), linearToSRGB(min(max(lin.z, 0), 1)))
    }

    /// Encoded sRGB → CIE L*a*b* (D50).
    public static func srgbToLab(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let lin = SIMD3(srgbToLinear(rgb.x), srgbToLinear(rgb.y), srgbToLinear(rgb.z))
        let xyz = mul(srgbToXYZD50, lin) / d50
        let e: Float = 6.0 / 29.0
        func f(_ t: Float) -> Float { t > e * e * e ? cbrtf(t) : t / (3 * e * e) + 4.0 / 29.0 }
        let (fx, fy, fz) = (f(xyz.x), f(xyz.y), f(xyz.z))
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// Rec.601 luma, Photoshop's default Grayscale conversion.
    @inlinable public static func rgbToGray(_ rgb: SIMD3<Float>) -> Float {
        0.299 * rgb.x + 0.587 * rgb.y + 0.114 * rgb.z
    }

    /// Per-pixel gradient dither noise in `[0, 1)` from a position hash (shared by the Gradient tool,
    /// Gradient Fill layers and the GPU compositor).
    @inlinable public static func ditherNoise(x: Int32, y: Int32) -> Float {
        var h = UInt32(bitPattern: x) &* 0x9E37_79B1 ^ UInt32(bitPattern: y) &* 0x85EB_CA77
        h ^= h >> 15
        h = h &* 0x2C1B_3C6D
        h ^= h >> 12
        return Float(UInt16(h & 0xFFFF)) / 65535
    }
}

/// A colour in a document's model with alpha, as normalised floats (photocraft `Color`).
/// Lab is stored normalised: L/100, (a+128)/255, (b+128)/255 — as PSD stores it.
public struct PCColor: Hashable, Sendable, Codable {
    public var mode: ColorMode
    /// Up to four colour components (unused ones are 0).
    public var c: SIMD4<Float>
    public var alpha: Float

    public init(mode: ColorMode, c: SIMD4<Float>, alpha: Float = 1) {
        self.mode = mode; self.c = c; self.alpha = alpha
    }

    public static func rgb(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) -> PCColor {
        PCColor(mode: .rgb, c: SIMD4(r, g, b, 0), alpha: a)
    }
    public static func gray(_ v: Float) -> PCColor { PCColor(mode: .grayscale, c: SIMD4(v, 0, 0, 0)) }

    public static let black = PCColor.rgb(0, 0, 0)
    public static let white = PCColor.rgb(1, 1, 1)
    public static let transparent = PCColor.rgb(0, 0, 0, 0)

    /// This colour as encoded sRGB (CMYK through the managed converter, Lab via D50 formulas).
    public var rgb: SIMD3<Float> {
        switch mode {
        case .rgb, .indexed, .multichannel: return SIMD3(c.x, c.y, c.z)
        case .grayscale, .bitmap, .duotone: return SIMD3(repeating: c.x)
        case .cmyk: return ColorConvert.cmykToRGB(c)
        case .lab: return ColorConvert.labToSRGB(SIMD3(c.x * 100, c.y * 255 - 128, c.z * 255 - 128))
        }
    }

    /// This colour in `target`'s model, through sRGB; unchanged when already there.
    public func converted(to target: ColorMode) -> PCColor {
        if mode == target || (mode.isRGBLike && target.isRGBLike) { return self }
        let v = rgb
        switch target {
        case .rgb, .indexed, .multichannel:
            return PCColor(mode: .rgb, c: SIMD4(v, 0), alpha: alpha)
        case .grayscale, .bitmap, .duotone:
            return PCColor(mode: target, c: SIMD4(ColorConvert.rgbToGray(v), 0, 0, 0), alpha: alpha)
        case .cmyk:
            return PCColor(mode: .cmyk, c: ColorConvert.rgbToCMYK(v), alpha: alpha)
        case .lab:
            let l = ColorConvert.srgbToLab(v)
            return PCColor(mode: .lab, c: SIMD4(l.x / 100, (l.y + 128) / 255, (l.z + 128) / 255, 0), alpha: alpha)
        }
    }

    public var rgba8: SIMD4<UInt8> {
        let v = rgb
        func q(_ x: Float) -> UInt8 { UInt8(min(max(x, 0), 1) * 255 + 0.5) }
        return SIMD4(q(v.x), q(v.y), q(v.z), q(alpha))
    }
}
