// Port of photocraft-algo (crates/algo/src/sharpen.rs) and photocraft-engine's one-step presets
// (crates/engine/src/filters.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Unsharp Mask, Smart Sharpen (basic), High Pass: each pixel's colour against its exact Gaussian
// blur (`conv_sep` with the full ⌈3σ⌉ kernel, premultiplied), transparent pixels untouched.

import Metal
import PCFoundation

enum SharpenKit {
    enum Op: UInt32 { case unsharp = 0, smart = 1, highPass = 2 }

    /// photocraft `with_blur`: `f(original, blurred)` on the colour channels of visible pixels.
    static func withBlur(_ src: FloatImage, _ out: PixelRect, _ ctx: FilterContext, _ radius: Float, _ f: (Float, Float) -> Float) -> FloatImage {
        let k = BlurCore.gaussianKernel(radius)
        let blurred = BlurCore.convSep(src, out, k, k, ctx.alpha)
        var res = src.crop(out)
        let n = src.channels, cc = ctx.colorChannels(n)
        res.data.withUnsafeMutableBufferPointer { px in
            blurred.data.withUnsafeBufferPointer { bl in
                for i in 0..<out.area {
                    let b = i * n
                    if ctx.alpha && px[b + n - 1] <= 0 { continue }
                    for c in 0..<cc { px[b + c] = f(px[b + c], bl[b + c]) }
                }
            }
        }
        return res
    }

    static func unsharp(_ o: Float, _ b: Float, k: Float, t: Float) -> Float {
        let d = o - b
        return abs(d) + 1e-6 >= t ? o + k * d : o
    }

    static func smart(_ o: Float, _ b: Float, k: Float, nr: Float) -> Float {
        let d = o - b
        let keep = 1 - nr * expf(-(abs(d) * 40))
        return o + k * d * keep
    }

    struct Params: BitwiseCopyable {
        var op: UInt32
        var k: Float
        var t: Float
        var nr: Float
    }

    /// Blurs the pass source exactly (`conv_sep`) and combines it with the original.
    static func encode(_ pass: GPUPass, radius: Float, params: Params) throws {
        let blurred = try pass.texture(pass.out)
        let k = BlurCore.gaussianKernel(radius)
        try pass.encodeConvSep(input: pass.src, inRect: pass.srcRect, output: blurred, outRect: pass.out, kx: k, ky: k)
        try pass.dispatchOut("pca_sharpen_combine", params: params, textures: [pass.src, blurred, pass.dst])
    }
}

/// Filter › Sharpen › Unsharp Mask: amount %, radius px (σ), threshold levels.
public struct UnsharpMask: Filter, Hashable {
    public var amount: Float
    public var radius: Float
    public var threshold: Float
    public init(amount: Float = 100, radius: Float = 1, threshold: Float = 0) {
        self.amount = amount; self.radius = radius; self.threshold = threshold
    }
    public var label: String { "Unsharp Mask" }
    public func halo(bounds: PixelRect) -> Halo { .gaussian(radius) }
    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let k = amount / 100, t = threshold / 255
        return SharpenKit.withBlur(src, out, ctx, radius) { SharpenKit.unsharp($0, $1, k: k, t: t) }
    }
    public func encodeGPU(_ pass: GPUPass) throws {
        try SharpenKit.encode(pass, radius: radius, params: .init(op: SharpenKit.Op.unsharp.rawValue, k: amount / 100, t: threshold / 255, nr: 0))
    }
}

/// Filter › Sharpen › Smart Sharpen (photocraft's basic form): amount %, radius px, noise
/// reduction % suppressing noise-level differences.
public struct SmartSharpen: Filter, Hashable {
    public var amount: Float
    public var radius: Float
    public var reduceNoise: Float
    public init(amount: Float = 100, radius: Float = 1, reduceNoise: Float = 10) {
        self.amount = amount; self.radius = radius; self.reduceNoise = reduceNoise
    }
    public var label: String { "Smart Sharpen" }
    public func halo(bounds: PixelRect) -> Halo { .gaussian(radius) }
    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let k = amount / 100, nr = clampf(reduceNoise / 100, 0, 1)
        return SharpenKit.withBlur(src, out, ctx, radius) { SharpenKit.smart($0, $1, k: k, nr: nr) }
    }
    public func encodeGPU(_ pass: GPUPass) throws {
        try SharpenKit.encode(pass, radius: radius, params: .init(op: SharpenKit.Op.smart.rawValue, k: amount / 100, t: 0, nr: clampf(reduceNoise / 100, 0, 1)))
    }
}

/// Filter › Other › High Pass: `0.5 + (original − blur)`.
public struct HighPass: Filter, Hashable {
    public var radius: Float
    public init(radius: Float = 10) { self.radius = radius }
    public var label: String { "High Pass" }
    public func halo(bounds: PixelRect) -> Halo { .gaussian(radius) }
    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        SharpenKit.withBlur(src, out, ctx, radius) { 0.5 + ($0 - $1) }
    }
    public func encodeGPU(_ pass: GPUPass) throws {
        try SharpenKit.encode(pass, radius: radius, params: .init(op: SharpenKit.Op.highPass.rawValue, k: 0, t: 0, nr: 0))
    }
}

/// Filter › Sharpen › Sharpen / Sharpen More / Sharpen Edges: photocraft's one-step presets
/// (Unsharp Mask 60 %/0.5/0, 150 %/0.6/0, 100 %/0.8/6).
public struct SharpenPreset: Filter, Hashable {
    public enum Strength: String, Codable, Sendable, Hashable, CaseIterable {
        case sharpen, sharpenMore, sharpenEdges
    }
    public var strength: Strength
    public init(_ strength: Strength = .sharpen) { self.strength = strength }
    var unsharp: UnsharpMask {
        switch strength {
        case .sharpen: UnsharpMask(amount: 60, radius: 0.5, threshold: 0)
        case .sharpenMore: UnsharpMask(amount: 150, radius: 0.6, threshold: 0)
        case .sharpenEdges: UnsharpMask(amount: 100, radius: 0.8, threshold: 6)
        }
    }
    public var label: String {
        switch strength { case .sharpen: "Sharpen"; case .sharpenMore: "Sharpen More"; case .sharpenEdges: "Sharpen Edges" }
    }
    public func halo(bounds: PixelRect) -> Halo { unsharp.halo(bounds: bounds) }
    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage { unsharp.cpu(src, out: out, ctx: ctx) }
    public func encodeGPU(_ pass: GPUPass) throws { try unsharp.encodeGPU(pass) }
}
