// Port of photocraft-algo (crates/algo/src/blur.rs) and photocraft-engine's one-step presets
// (crates/engine/src/filters.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCFoundation

/// Filter › Blur › Gaussian Blur. `radius` is the Gaussian standard deviation in pixels
/// (0.1–1000): an exact kernel up to σ 4, three running-sum box passes above (Kovesi 2010).
public struct GaussianBlur: Filter, Hashable {
    public var radius: Float
    public init(radius: Float) { self.radius = radius }
    public var label: String { "Gaussian Blur" }
    public func halo(bounds: PixelRect) -> Halo { .gaussian(radius) }
    public var processesWholeArea: Bool { BlurCore.gaussianBoxes(radius) != nil }
    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        BlurCore.gaussian(src, out, ctx.alpha, radius)
    }
    public func encodeGPU(_ pass: GPUPass) throws {
        try pass.encodeGaussian(radius: radius, output: pass.dst, outRect: pass.out)
    }
}

/// Filter › Blur › Box Blur: a box of `2·radius + 1` pixels (running sums above radius 4).
public struct BoxBlur: Filter, Hashable {
    public var radius: Float
    public init(radius: Float) { self.radius = radius }
    public var label: String { "Box Blur" }
    public func halo(bounds: PixelRect) -> Halo { .reach(radius) }
    public var processesWholeArea: Bool { BlurCore.boxBoxes(radius) != nil }
    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        if let boxes = BlurCore.boxBoxes(radius) { return BlurCore.boxPasses(src, out, ctx.alpha, boxes) }
        let r = PCAMath.usize(PCAMath.pos(radius).rounded(.toNearestOrAwayFromZero))
        let k = [Float](repeating: 1 / Float(2 * r + 1), count: 2 * r + 1)
        return BlurCore.convSep(src, out, k, k, ctx.alpha)
    }
    public func encodeGPU(_ pass: GPUPass) throws {
        if let boxes = BlurCore.boxBoxes(radius) {
            try pass.encodeBoxPasses(input: pass.src, inRect: pass.srcRect, output: pass.dst, outRect: pass.out, boxes: boxes)
        } else {
            let r = PCAMath.usize(PCAMath.pos(radius).rounded(.toNearestOrAwayFromZero))
            let k = [Float](repeating: 1 / Float(2 * r + 1), count: 2 * r + 1)
            try pass.encodeConvSep(input: pass.src, inRect: pass.srcRect, output: pass.dst, outRect: pass.out, kx: k, ky: k)
        }
    }
}

/// Filter › Blur › Blur: photocraft's one-step preset, Gaussian σ 0.6.
public struct BlurPreset: Filter, Hashable {
    public enum Strength: String, Codable, Sendable, Hashable {
        /// Blur (σ 0.6).
        case blur
        /// Blur More (σ 1.4).
        case blurMore
    }
    public var strength: Strength
    public init(_ strength: Strength = .blur) { self.strength = strength }
    var gaussian: GaussianBlur { GaussianBlur(radius: strength == .blur ? 0.6 : 1.4) }
    public var label: String { strength == .blur ? "Blur" : "Blur More" }
    public func halo(bounds: PixelRect) -> Halo { gaussian.halo(bounds: bounds) }
    public var processesWholeArea: Bool { gaussian.processesWholeArea }
    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage { gaussian.cpu(src, out: out, ctx: ctx) }
    public func encodeGPU(_ pass: GPUPass) throws { try gaussian.encodeGPU(pass) }
}
