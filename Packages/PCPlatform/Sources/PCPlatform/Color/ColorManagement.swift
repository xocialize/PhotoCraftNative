// The process-wide managed CMYK converter PCFoundation's `ColorConvert.cmyk` slot expects.
// Replaces photocraft-color's managed CMYK path (`photocraft_color::convert::with_cmyk_space`, backed
// by photocraft-cms) with ColorSync. Port of its API shape, MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.
//
// Two paths. The batch methods (`cmykToRGB(batch:)` / `rgbToCMYK(batch:)`, which PCFoundation's
// `Surface.readRGBA` uses for CMYK regions) run the whole batch through one ColorSync conversion:
// exact. The per-colour methods are called one pixel at a time, where a ColorSync call each would be
// far too slow, so they interpolate two grids filled once from one batched conversion each — CMYK →
// sRGB on 17⁴ nodes, sRGB → CMYK on 33³ — tetrahedrally (photocraft's own integer path samples
// device links the same way: 33³ / 17⁴). `exact*` call ColorSync for a single colour.

import Foundation
import PCFoundation
import simd

/// CMYK ⇄ sRGB through a CMYK profile, with grid interpolation.
public final class ColorSyncCMYKConverter: CMYKConverter, @unchecked Sendable {
    public let cmykProfile: ICCProfile
    public let rgbProfile: ICCProfile
    public let options: TransformOptions
    public let toRGB: ColorTransform
    public let toCMYK: ColorTransform
    let toRGBGrid: GridLUT
    let toCMYKGrid: GridLUT

    /// Grid sizes (photocraft `GRID_4D` / `GRID_3D`).
    public static let grid4D = 17
    public static let grid3D = 33

    /// `cmyk` must be a CMYK profile; `options` default to Photoshop's relative colorimetric + BPC.
    public init(cmyk: ICCProfile = BuiltinProfile.coatedCMYK.profile, rgb: ICCProfile = BuiltinProfile.srgb.profile,
                options: TransformOptions = .photoshopDefault, grid4D: Int = ColorSyncCMYKConverter.grid4D,
                grid3D: Int = ColorSyncCMYKConverter.grid3D) throws {
        guard cmyk.colorSpace == .cmyk else { throw PlatformError.invalidProfile("\(cmyk.profileDescription) is not a CMYK profile") }
        guard rgb.colorSpace == .rgb else { throw PlatformError.invalidProfile("\(rgb.profileDescription) is not an RGB profile") }
        cmykProfile = cmyk; rgbProfile = rgb; self.options = options
        let a = try ColorTransform(source: cmyk, destination: rgb, options: options)
        let b = try ColorTransform(source: rgb, destination: cmyk, options: options)
        toRGB = a; toCMYK = b
        toRGBGrid = GridLUT.sample(inputs: 4, size: grid4D, outputs: 3) { a.convert($0, pixelCount: $1) }
        toCMYKGrid = GridLUT.sample(inputs: 3, size: grid3D, outputs: 4) { b.convert($0, pixelCount: $1) }
    }

    public func cmykToRGB(_ c: SIMD4<Float>) -> SIMD3<Float> {
        let o = toRGBGrid.eval([c.x, c.y, c.z, c.w])
        return simd_clamp(SIMD3(o[0], o[1], o[2]), SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    public func rgbToCMYK(_ rgb: SIMD3<Float>) -> SIMD4<Float> {
        let o = toCMYKGrid.eval([rgb.x, rgb.y, rgb.z])
        return simd_clamp(SIMD4(o[0], o[1], o[2], o[3]), SIMD4(repeating: 0), SIMD4(repeating: 1))
    }

    /// A whole batch through one ColorSync conversion (exact; PCFoundation's `Surface.readRGBA`
    /// converts a CMYK region this way).
    public func cmykToRGB(batch: [SIMD4<Float>]) -> [SIMD3<Float>] {
        guard !batch.isEmpty else { return [] }
        var flat = [Float](repeating: 0, count: batch.count * 4)
        for (i, c) in batch.enumerated() { flat[i * 4] = c.x; flat[i * 4 + 1] = c.y; flat[i * 4 + 2] = c.z; flat[i * 4 + 3] = c.w }
        let o = toRGB.convert(flat, pixelCount: batch.count)
        return (0..<batch.count).map { i in
            simd_clamp(SIMD3(o[i * 3], o[i * 3 + 1], o[i * 3 + 2]), SIMD3(repeating: 0), SIMD3(repeating: 1))
        }
    }

    /// A whole batch through one ColorSync conversion (exact).
    public func rgbToCMYK(batch: [SIMD3<Float>]) -> [SIMD4<Float>] {
        guard !batch.isEmpty else { return [] }
        var flat = [Float](repeating: 0, count: batch.count * 3)
        for (i, c) in batch.enumerated() { flat[i * 3] = c.x; flat[i * 3 + 1] = c.y; flat[i * 3 + 2] = c.z }
        let o = toCMYK.convert(flat, pixelCount: batch.count)
        return (0..<batch.count).map { i in
            simd_clamp(SIMD4(o[i * 4], o[i * 4 + 1], o[i * 4 + 2], o[i * 4 + 3]), SIMD4(repeating: 0), SIMD4(repeating: 1))
        }
    }

    /// ColorSync directly, no interpolation.
    public func exactCMYKToRGB(_ c: SIMD4<Float>) -> SIMD3<Float> {
        let o = toRGB.eval([c.x, c.y, c.z, c.w])
        return SIMD3(o[0], o[1], o[2])
    }

    public func exactRGBToCMYK(_ rgb: SIMD3<Float>) -> SIMD4<Float> {
        let o = toCMYK.eval([rgb.x, rgb.y, rgb.z])
        return SIMD4(o[0], o[1], o[2], o[3])
    }
}

/// Process-wide colour-management setup.
public enum ColorManagement {
    /// Installs a ColorSync-backed converter as PCFoundation's `ColorConvert.cmyk` (photocraft enters
    /// its managed CMYK space the same way). Returns the converter.
    @discardableResult
    public static func install(cmyk: ICCProfile = BuiltinProfile.coatedCMYK.profile, options: TransformOptions = .photoshopDefault) throws -> ColorSyncCMYKConverter {
        let c = try ColorSyncCMYKConverter(cmyk: cmyk, options: options)
        ColorConvert.cmyk = c
        return c
    }

    /// Back to the naive formulas.
    public static func uninstall() { ColorConvert.cmyk = nil }

    /// The installed converter, if it is PCPlatform's.
    public static var installed: ColorSyncCMYKConverter? { ColorConvert.cmyk as? ColorSyncCMYKConverter }
}
