// Port of photocraft-algo (crates/algo/src/fxutil.rs, noise.rs) and photocraft-raster's
// to_rgba/from_rgba (crates/raster/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Colour-model access for filters that work on RGB or luma whatever the document model, and the
// deterministic coordinate hash every noise-based filter uses (so results never depend on tiling,
// and the CPU and GPU agree bit for bit on the random numbers).

import PCFoundation
import simd

/// Deterministic hash → `[0, 1)` from document coordinates (photocraft `noise::hash01`).
/// `(h >> 8) / 2^24` is exact in Float, so the MSL twin (`pca_hash01`) matches bit for bit.
@inline(__always)
public func hash01(_ x: Int32, _ y: Int32, _ c: UInt32, _ seed: UInt32) -> Float {
    var h = UInt32(bitPattern: x) &* 0x8da6_b343 ^ UInt32(bitPattern: y) &* 0xd816_3841 ^ c &* 0xcb1a_b31f ^ seed &* 0x9e37_79b9
    h ^= h >> 16
    h = h &* 0x7feb_352d
    h ^= h >> 15
    h = h &* 0x846c_a68b
    h ^= h >> 16
    return Float(h >> 8) / Float(1 << 24)
}

extension FilterContext {
    /// Straight sRGB RGBA of a native pixel (photocraft `to_rgba`).
    func rgba(_ px: UnsafeBufferPointer<Float>) -> SIMD4<Float> {
        let n = mode.colorChannels
        let a: Float = alpha ? px[px.count - 1] : 1
        let rgb: SIMD3<Float>
        switch mode {
        case .grayscale, .bitmap, .duotone: rgb = SIMD3(repeating: px[0])
        case .cmyk: rgb = ColorConvert.cmykToRGB(SIMD4(px[0], px[1], px[2], px[3]))
        case .lab: rgb = ColorConvert.labToSRGB(SIMD3(px[0] * 100, px[1] * 255 - 128, px[2] * 255 - 128))
        default: rgb = n >= 3 ? SIMD3(px[0], px[1], px[2]) : SIMD3(repeating: px[0])
        }
        return SIMD4(rgb, a)
    }

    func rgba(_ px: [Float]) -> SIMD4<Float> { px.withUnsafeBufferPointer { rgba($0) } }

    /// Writes straight sRGB RGBA into a native pixel (photocraft `from_rgba_into`).
    func setRGBA(_ px: UnsafeMutableBufferPointer<Float>, _ c: SIMD4<Float>) {
        let rgb = SIMD3(c.x, c.y, c.z)
        var k = 0
        switch mode {
        case .grayscale, .bitmap, .duotone:
            px[0] = ColorConvert.rgbToGray(rgb); k = 1
        case .cmyk:
            let v = ColorConvert.rgbToCMYK(rgb)
            for i in 0..<min(4, px.count) { px[i] = v[i] }
            k = 4
        case .lab:
            let l = ColorConvert.srgbToLab(rgb)
            px[0] = l.x / 100; px[1] = (l.y + 128) / 255; px[2] = (l.z + 128) / 255; k = 3
        default:
            px[0] = rgb.x; px[1] = rgb.y; px[2] = rgb.z; k = 3
        }
        if alpha, k < px.count { px[px.count - 1] = c.w }
    }

    /// A straight sRGB RGBA colour in the native model (photocraft `fxutil::native`).
    func native(_ c: SIMD4<Float>, channels n: Int) -> [Float] {
        var v = [Float](repeating: 0, count: max(n, 5))
        v.withUnsafeMutableBufferPointer { b in
            setRGBA(UnsafeMutableBufferPointer(rebasing: b[0..<n]), c)
        }
        return Array(v[0..<n])
    }

    /// Rec. 601 luma of a native pixel through RGB (photocraft `stylize::luma`).
    func lumaViaRGB(_ px: UnsafeBufferPointer<Float>) -> Float {
        let c = rgba(px)
        return 0.299 * c.x + 0.587 * c.y + 0.114 * c.z
    }

    /// Rec. 601 luma of a native pixel (photocraft `fxutil::luma`: Lab uses L directly).
    func luma(_ px: UnsafeBufferPointer<Float>) -> Float {
        switch mode {
        case .grayscale, .bitmap, .duotone, .lab: return px[0]
        case .rgb: return 0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2]
        default: return lumaViaRGB(px)
        }
    }

    /// Whether channel values are ink amounts (photocraft `fxutil::subtractive`).
    var subtractive: Bool { mode == .cmyk }

    /// MSL `pca_frame.mode` code: 0 gray-like, 1 RGB-like, 2 other (CPU only for joint filters).
    var gpuModeCode: UInt32 {
        if mode.isGrayLike { return 0 }
        if mode.isRGBLike { return 1 }
        return 2
    }
}
