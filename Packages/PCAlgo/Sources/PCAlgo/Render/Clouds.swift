// Port of photocraft-engine (crates/engine/src/extra_cmds.rs: hash, clouds_value, clouds), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Render › Clouds and Difference Clouds. photocraft implements them in the engine (a
// session command over the active layer, with the session's foreground/background colours and
// the document size); here they are a Filter whose parameters carry those inputs. Value-noise fBm
// with the engine's own hash (not `hash01`), in straight sRGB, so the Metal path
// (Shaders/RenderClouds.metal) is `.joint`.

import Foundation
import PCFoundation

struct RenderCloudsGPU: BitwiseCopyable {
    var fg: SIMD4<Float>; var bg: SIMD4<Float>; var freq: Float; var seed: UInt32; var difference: UInt32; var pad0: Int32 = 0
}

/// Filter › Render › Clouds (fills with fBm clouds between the foreground and background
/// colours, opaque) or Difference Clouds (`difference`: |pixel − cloud colour| per RGB channel,
/// alpha kept). The noise scale follows the document size: base wavelength
/// `clamp(max(width, height) / 4, 16, 512)` px.
public struct Clouds: Filter, Hashable {
    /// The clouds' contrast at mid-grey: the slope of the octave sum's stretch there.
    static let contrast: Float = 2.2
    public var seed: UInt32
    public var difference: Bool
    /// Straight sRGB RGBA (photocraft's session foreground colour).
    public var foreground: SIMD4<Float>
    /// Straight sRGB RGBA (photocraft's session background colour).
    public var background: SIMD4<Float>
    /// The document size (photocraft uses 256 × 256 when no document is open).
    public var documentSize: PixelSize

    public init(seed: UInt32 = 0, difference: Bool = false, foreground: SIMD4<Float> = SIMD4(0, 0, 0, 1),
                background: SIMD4<Float> = SIMD4(1, 1, 1, 1), documentSize: PixelSize = PixelSize(width: 256, height: 256)) {
        self.seed = seed; self.difference = difference; self.foreground = foreground; self.background = background; self.documentSize = documentSize
    }

    public var label: String { difference ? "Difference Clouds" : "Clouds" }
    public func halo(bounds: PixelRect) -> Halo { .radius(0) }
    public var gpuChannels: GPUChannels { .joint }

    /// The base wavelength: `clamp(max(w, h) / 4, 16, 512)`.
    var base: Float { clampf(Float(max(documentSize.width, documentSize.height)) / 4, 16, 512) }

    /// photocraft-engine `hash` → [0, 1].
    @inline(__always)
    static func hash(_ x: Int32, _ y: Int32, _ seed: UInt32) -> Float {
        var h = UInt32(bitPattern: x) &* 0x8da6_b343 ^ UInt32(bitPattern: y) &* 0xd816_3841 ^ seed &* 0xcb1a_b31f
        h ^= h >> 13
        h = h &* 0x5bd1_e995
        h ^= h >> 15
        return Float(h & 0x00ff_ffff) / Float(0x00ff_ffff)
    }

    /// photocraft-engine `clouds_value`: eight octaves of smooth value noise, stretched to 0…1.
    static func value(_ x: Float, _ y: Float, _ base: Float, _ seed: UInt32) -> Float {
        var sum: Float = 0, amp: Float = 1, freq: Float = 1 / base, norm: Float = 0
        for o: UInt32 in 0..<8 {
            let fx = x * freq, fy = y * freq
            let ix = DistortKit.floorToInt(fx.rounded(.down)), iy = DistortKit.floorToInt(fy.rounded(.down))
            let tx = fx - Float(ix), ty = fy - Float(iy)
            let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
            let s = seed &+ o &* 7919
            let h00 = hash(ix, iy, s), h10 = hash(ix &+ 1, iy, s), h01 = hash(ix, iy &+ 1, s), h11 = hash(ix &+ 1, iy &+ 1, s)
            let top = h00 + (h10 - h00) * sx
            let bot = h01 + (h11 - h01) * sx
            sum += (top + (bot - top) * sy) * amp
            norm += amp
            amp *= 0.5
            freq *= 2
        }
        // Stretch the bell-shaped sum around mid-grey so the clouds use most of the
        // foreground→background range. A straight stretch clamped at 0 and 1 flattened its tails
        // into pure foreground and background; this S-curve, x/√(1+x²) scaled so it meets 0 and 1
        // only where the sum does, compresses them instead (photocraft #9959).
        let c = Clouds.contrast
        let h = (c * c - 1).squareRoot()
        let d = (sum / norm - 0.5) * 2 * h
        return clampf(0.5 + 0.5 * c / h * d / (1 + d * d).squareRoot(), 0, 1)
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let base = self.base, seed = self.seed, fg = foreground, bg = background, difference = self.difference
        var res = src.crop(out)
        RenderKit.forEachPixel(&res) { x, y, px in
            let t = Clouds.value(Float(x), Float(y), base, seed)
            let c = SIMD3(fg.x + (bg.x - fg.x) * t, fg.y + (bg.y - fg.y) * t, fg.z + (bg.z - fg.z) * t)
            var p: SIMD4<Float>
            if difference {
                p = ctx.rgba(UnsafeBufferPointer(px))
                p.x = abs(p.x - c.x); p.y = abs(p.y - c.y); p.z = abs(p.z - c.z)
            } else {
                p = SIMD4(c, 1)
            }
            ctx.setRGBA(px, p)
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        try pass.dispatchOut("pca_ren_clouds", params: RenderCloudsGPU(fg: foreground, bg: background, freq: 1 / base, seed: seed,
                                                                        difference: difference ? 1 : 0))
    }
}
