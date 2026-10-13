// Port of photocraft-algo (crates/algo/src/color_to_alpha.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Other › Color to Alpha: removes a known colour from the pixels, turning it into
// transparency while keeping what was mixed with it. A pixel P that is a semi-transparent colour Q
// over a background C obeys P = a·Q + (1 − a)·C; the most transparent solution keeping Q in 0–1 is,
// per channel, a_i = (P_i − C_i)/(1 − C_i) where P_i > C_i, (C_i − P_i)/C_i where P_i < C_i, else 0,
// and a = max_i a_i; then Q = C + (P − C)/a and the layer's alpha is multiplied by a. The
// thresholds map a ≤ transparency → 0 and a ≥ opacity → 1, linear in between. The arithmetic runs
// on the stored channel values (encoded, any model, any depth).

import PCFoundation

/// Filter › Other › Color to Alpha (photocraft `FilterParams::ColorToAlpha`). Surfaces without
/// alpha are returned unchanged.
public struct ColorToAlpha: Filter, Hashable {
    /// The colour to remove, straight sRGB RGBA (alpha ignored), converted to the document model.
    public var color: SIMD4<Float>
    /// Opacities at or below this become 0 (0–1).
    public var transparencyThreshold: Float
    /// Opacities at or above this become 1 (0–1).
    public var opacityThreshold: Float

    /// photocraft-engine's defaults: white, thresholds 0 and 1.
    public init(color: SIMD4<Float> = SIMD4(1, 1, 1, 1), transparencyThreshold: Float = 0, opacityThreshold: Float = 1) {
        self.color = color; self.transparencyThreshold = transparencyThreshold; self.opacityThreshold = opacityThreshold
    }

    public var label: String { "Color to Alpha" }
    public func halo(bounds: PixelRect) -> Halo { .radius(0) }

    /// Whether the filter's job is to make pixels transparent (photocraft `makes_transparency`).
    public var makesTransparency: Bool { true }

    // MARK: photocraft's public maths

    /// The opacity a (0–1) a pixel needs to be a mix of some in-range colour and `key`.
    /// Out-of-range samples need full opacity; non-finite samples are ignored (photocraft `opacity`).
    public static func opacity(_ colour: [Float], key: [Float]) -> Float {
        var a: Float = 0
        for (p, c) in zip(colour, key) { a = accumulate(a, p, c) }
        return clampf(a, 0, 1)
    }

    @inline(__always)
    static func accumulate(_ a: Float, _ p: Float, _ c: Float) -> Float {
        let ai: Float
        if p > c { ai = c < 1 ? (p - c) / (1 - c) : 1 }
        else if p < c { ai = c > 0 ? (c - p) / c : 1 }
        else { ai = 0 }
        return ai.isFinite ? Float.maximum(a, ai) : a
    }

    /// The thresholds: a ≤ transparency → 0, a ≥ opacity → 1, linear in between (photocraft `remap`).
    public static func remap(_ a: Float, transparency: Float, opacity: Float) -> Float {
        if a <= transparency { return 0 }
        if a >= opacity { return 1 }
        return clampf((a - transparency) / (opacity - transparency), 0, 1)
    }

    /// Unmixes `key` from one pixel's colour channels in place and returns the factor its alpha is
    /// multiplied by (photocraft `unmix`). Fully opaque results keep the colour; fully transparent
    /// ones take the key colour.
    public static func unmix(_ colour: inout [Float], key: [Float], transparency: Float, opacityThreshold: Float) -> Float {
        colour.withUnsafeMutableBufferPointer { unmix($0, key, transparency, opacityThreshold) }
    }

    @inline(__always)
    static func unmix(_ colour: UnsafeMutableBufferPointer<Float>, _ key: [Float], _ transparency: Float, _ opacityThreshold: Float) -> Float {
        let m = min(colour.count, key.count)
        var a0: Float = 0
        for i in 0..<m { a0 = accumulate(a0, colour[i], key[i]) }
        let a = remap(clampf(a0, 0, 1), transparency: transparency, opacity: opacityThreshold)
        if a >= 1 { return 1 }
        for i in 0..<m {
            let c = key[i]
            colour[i] = a <= 0 ? c : clampf(c + (colour[i] - c) / a, 0, 1)
        }
        return Float.maximum(a, 0)
    }

    // MARK: Filter

    /// The key in the document's model (photocraft `native`).
    func nativeKey(_ ctx: FilterContext, channels n: Int) -> [Float] {
        let cc = min(ctx.colorChannels(n), FxUtil.maxChannels)
        let all = ctx.native(SIMD4(color.x, color.y, color.z, 1), channels: n)
        return Array(all[0..<min(cc, all.count)])
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        var res = src.crop(out)
        let n = src.channels
        if !ctx.alpha || n < 2 { return res }
        let key = nativeKey(ctx, channels: n)
        let (t, o) = (transparencyThreshold, opacityThreshold)
        res.data.withUnsafeMutableBufferPointer { buf in
            let b = UnsafeSendable(buf)
            parallelChunks(out.area, minChunk: 4096) { r in
                for i in r {
                    let colour = UnsafeMutableBufferPointer(rebasing: b.value[(i * n)..<(i * n + n - 1)])
                    let a = Self.unmix(colour, key, t, o)
                    b.value[i * n + n - 1] *= a
                }
            }
        }
        return res
    }

    /// The arithmetic is per stored channel, so any model whose colour channels fit one plane runs
    /// on the GPU (CMYK + alpha needs K and CMY together: CPU). Without alpha it is the identity.
    public var gpuChannels: GPUChannels { .joint }
    public func supportsGPU(_ ctx: FilterContext, channels: Int) -> Bool {
        !ctx.alpha || ctx.colorChannels(channels) <= 3
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        if !pass.ctx.alpha {
            try pass.dispatchOut("pca_copy", params: NoParams())
            return
        }
        // With alpha the colour channels fit this one plane: the image has them plus alpha.
        let key = nativeKey(pass.ctx, channels: pass.planeChannels.count + 1)
        var k = SIMD4<Float>(repeating: 0)
        for (i, v) in key.prefix(4).enumerated() { k[i] = v }
        try pass.dispatchOut("pca_tone_color_to_alpha",
                             params: ToneKit.ColorToAlphaParams(key: k, transparency: transparencyThreshold, opacity: opacityThreshold))
    }
}

extension ToneKit {
    /// MSL `pca_tone_c2a_params`.
    struct ColorToAlphaParams: BitwiseCopyable {
        var key: SIMD4<Float>
        var transparency: Float
        var opacity: Float
        var pad0: UInt32 = 0
        var pad1: UInt32 = 0
    }
}
