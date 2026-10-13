// Port of photocraft-algo (crates/algo/src/other2.rs: hsb_hsl, rgb_to_hsb, rgb_to_hsl, hsb_to_rgb, hsl_to_rgb), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Other › HSB/HSL: reinterprets the three colour channels — encodes RGB as H, S, B/L in
// the R, G, B channels, or decodes such channels back to RGB. The HSB/HSL conversions live in
// `ToneKit` (Replace Color uses them too).

import PCFoundation

/// Colour encodings for Filter › Other › HSB/HSL (photocraft `HsbModel`).
public enum HsbModel: String, Codable, Sendable, Hashable, CaseIterable {
    case rgb
    case hsb
    case hsl
}

/// Shared maths of the tone/colour area (photocraft's `other2` colour conversions, `tone`'s luma).
public enum ToneKit {
    /// RGB → HSB (hue, saturation, brightness), all 0–1 (photocraft `rgb_to_hsb`).
    public static func rgbToHSB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let mx = Float.maximum(Float.maximum(c.x, c.y), c.z), mn = Float.minimum(Float.minimum(c.x, c.y), c.z)
        let d = mx - mn
        let h = hue(c, mx, d)
        return SIMD3(h, mx > 0 ? d / mx : 0, mx)
    }

    /// RGB → HSL, all 0–1 (photocraft `rgb_to_hsl`).
    public static func rgbToHSL(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let mx = Float.maximum(Float.maximum(c.x, c.y), c.z), mn = Float.minimum(Float.minimum(c.x, c.y), c.z)
        let d = mx - mn
        let l = (mx + mn) / 2
        let s: Float = d <= 0 ? 0 : d / Float.maximum(1 - abs(2 * l - 1), 1e-7)
        return SIMD3(hue(c, mx, d), clampf(s, 0, 1), l)
    }

    @inline(__always)
    static func hue(_ c: SIMD3<Float>, _ mx: Float, _ d: Float) -> Float {
        if d <= 0 { return 0 }
        let h: Float
        if mx == c.x { h = euclidMod((c.y - c.z) / d, 6) }
        else if mx == c.y { h = (c.z - c.x) / d + 2 }
        else { h = (c.x - c.y) / d + 4 }
        return h / 6
    }

    /// RGB from hue, chroma and the value to add (photocraft `from_hcm`).
    @inline(__always)
    static func fromHCM(_ h: Float, _ chroma: Float, _ m: Float) -> SIMD3<Float> {
        let hp = euclidMod(h, 1) * 6
        let x = chroma * (1 - abs(euclidMod(hp, 2) - 1))
        let rgb: SIMD3<Float>
        switch hp.isFinite ? Int32(clamping: Int64(hp.rounded(.towardZero))) : 0 {
        case 0: rgb = SIMD3(chroma, x, 0)
        case 1: rgb = SIMD3(x, chroma, 0)
        case 2: rgb = SIMD3(0, chroma, x)
        case 3: rgb = SIMD3(0, x, chroma)
        case 4: rgb = SIMD3(x, 0, chroma)
        default: rgb = SIMD3(chroma, 0, x)
        }
        return SIMD3(rgb.x + m, rgb.y + m, rgb.z + m)
    }

    /// HSB → RGB (photocraft `hsb_to_rgb`).
    public static func hsbToRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let chroma = c.z * c.y
        return fromHCM(c.x, chroma, c.z - chroma)
    }

    /// HSL → RGB (photocraft `hsl_to_rgb`).
    public static func hslToRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let chroma = (1 - abs(2 * c.z - 1)) * c.y
        return fromHCM(c.x, chroma, c.z - chroma / 2)
    }

    /// Rec. 601 luma of straight RGB (photocraft `tone::luma`).
    @inline(__always)
    public static func luma(_ c: SIMD3<Float>) -> Float { 0.299 * c.x + 0.587 * c.y + 0.114 * c.z }
}

/// Filter › Other › HSB/HSL: decodes the colour channels from `input` to RGB, then encodes them
/// as `output` (H, S, B/L stored in the R, G, B channels). Values are clamped to 0–1 first; other
/// colour models go through sRGB.
public struct HsbHsl: Filter, Hashable {
    public var input: HsbModel
    public var output: HsbModel

    /// photocraft-engine's dialog defaults: Input Mode RGB, Row Order HSB.
    public init(input: HsbModel = .rgb, output: HsbModel = .hsb) {
        self.input = input; self.output = output
    }

    public var label: String { "HSB/HSL" }
    public func halo(bounds: PixelRect) -> Halo { .radius(0) }
    public var gpuChannels: GPUChannels { .joint }

    static func convert(_ c: SIMD3<Float>, _ input: HsbModel, _ output: HsbModel) -> SIMD3<Float> {
        let rgb: SIMD3<Float>
        switch input {
        case .rgb: rgb = c
        case .hsb: rgb = ToneKit.hsbToRGB(c)
        case .hsl: rgb = ToneKit.hslToRGB(c)
        }
        switch output {
        case .rgb: return rgb
        case .hsb: return ToneKit.rgbToHSB(rgb)
        case .hsl: return ToneKit.rgbToHSL(rgb)
        }
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        var res = src.crop(out)
        if input == output { return res }
        let n = src.channels
        let native = ctx.mode == .rgb
        let (input, output) = (self.input, self.output)
        res.data.withUnsafeMutableBufferPointer { buf in
            let b = UnsafeSendable(buf)
            parallelChunks(out.area, minChunk: 4096) { r in
                for i in r {
                    let px = UnsafeMutableBufferPointer(rebasing: b.value[(i * n)..<(i * n + n)])
                    let c4: SIMD4<Float> = native ? SIMD4(px[0], px[1], px[2], 1) : ctx.rgba(UnsafeBufferPointer(px))
                    let c = SIMD3(clampf(c4.x, 0, 1), clampf(c4.y, 0, 1), clampf(c4.z, 0, 1))
                    let o = Self.convert(c, input, output)
                    if native { px[0] = o.x; px[1] = o.y; px[2] = o.z }
                    else { ctx.setRGBA(px, SIMD4(o, c4.w)) }
                }
            }
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        if input == output {
            try pass.dispatchOut("pca_copy", params: NoParams())
            return
        }
        try pass.dispatchOut("pca_tone_hsbhsl", params: ToneKit.HsbParams(input: input.code, output: output.code))
    }
}

extension HsbModel {
    /// MSL code: 0 RGB, 1 HSB, 2 HSL.
    var code: UInt32 {
        switch self {
        case .rgb: 0
        case .hsb: 1
        case .hsl: 2
        }
    }
}

extension ToneKit {
    /// MSL `pca_tone_hsb_params`.
    struct HsbParams: BitwiseCopyable {
        var input: UInt32
        var output: UInt32
        var pad0: UInt32 = 0
        var pad1: UInt32 = 0
    }
}
