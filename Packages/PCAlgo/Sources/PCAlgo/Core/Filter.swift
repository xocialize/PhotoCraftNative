// Port of photocraft-algo (crates/algo/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The filter contract: every filter is depth-agnostic (normalised floats, HDR above 1 kept),
// tile/region aware (it declares a halo: how far outside an output rectangle it reads) and
// selection aware (the engine mixes its output with the original by the selection coverage).

import PCFoundation

/// How far outside an output rectangle a filter reads (photocraft `Halo`).
public enum Halo: Hashable, Sendable {
    /// A margin of this many pixels.
    case radius(Int32)
    /// The whole reference bounds (distortions, radial blur, tiles…).
    case bounds

    /// photocraft's `|v| Halo::Radius(v.max(0).ceil() + 1)`.
    static func reach(_ v: Float) -> Halo { .radius(Halo.plusOne(PCAMath.i32(PCAMath.pos(v).rounded(.up)))) }
    /// photocraft's Gaussian halo: `ceil(3σ) + 1`.
    static func gaussian(_ sigma: Float) -> Halo { .radius(Halo.plusOne(PCAMath.i32((PCAMath.pos(sigma) * 3).rounded(.up)))) }
    /// Saturating `+ 1`: a wrapping add turns a saturated reach into a negative margin (photocraft #8946).
    static func plusOne(_ v: Int32) -> Int32 { v == .max ? .max : v + 1 }
}

/// The context a filter runs in (photocraft `Ctx`).
public struct FilterContext: Hashable, Sendable, Codable {
    /// Reference area: distortions are centred on it and sample within it (Photoshop uses the
    /// selection bounds, else the canvas).
    public var bounds: PixelRect
    /// Colour model of the samples.
    public var mode: ColorMode
    /// Whether the last channel is alpha.
    public var alpha: Bool
    /// The storage depth of the document the samples came from, when known (filters that clip at
    /// integer depths as photocraft does read it; `nil` = unknown, treated as float).
    public var sample: SampleType?

    public init(bounds: PixelRect, mode: ColorMode, alpha: Bool, sample: SampleType? = nil) {
        self.bounds = bounds; self.mode = mode; self.alpha = alpha; self.sample = sample
    }

    public init(bounds: PixelRect, format: PixelFormat) {
        self.init(bounds: bounds, mode: format.mode, alpha: format.alpha, sample: format.sample)
    }

    /// A context guessed from a channel count: 1 Gray, 2 Gray+A, 3 RGB, 4 RGBA, 5 CMYK+A.
    public static func inferred(channels: Int, bounds: PixelRect) -> FilterContext {
        switch channels {
        case 1: FilterContext(bounds: bounds, mode: .grayscale, alpha: false)
        case 2: FilterContext(bounds: bounds, mode: .grayscale, alpha: true)
        case 3: FilterContext(bounds: bounds, mode: .rgb, alpha: false)
        case 4: FilterContext(bounds: bounds, mode: .rgb, alpha: true)
        default: FilterContext(bounds: bounds, mode: .cmyk, alpha: channels > 4)
        }
    }

    /// Colour (non-alpha) channels of an `n`-channel pixel.
    @inlinable public func colorChannels(_ n: Int) -> Int { alpha ? n - 1 : n }
}

/// Where a filter runs.
public enum Backend: Sendable, Hashable {
    /// The Swift reference.
    case cpu
    /// The Metal kernels; throws when the filter cannot run on the GPU for this input.
    case gpu
    /// The GPU when the filter supports this input there, else the CPU.
    case auto
}

/// How a filter's Metal path treats channels. The GPU works on float4 planes: up to three colour
/// channels plus alpha in `.w` (or four colour channels without alpha); wider pixels (CMYK + alpha,
/// multichannel) are split into several planes, each carrying alpha.
public enum GPUChannels: Sendable, Hashable {
    /// Channels are processed independently (alpha may weight them): any channel count.
    case perChannel
    /// The colour channels are used together (luma, hue…): one plane of a Gray- or RGB-like model.
    case joint
    /// No Metal path.
    case none
}

public enum FilterError: Error, CustomStringConvertible, Sendable {
    case gpuUnavailable(String)
    case gpuUnsupported(String)
    case invalidInput(String)

    public var description: String {
        switch self {
        case .gpuUnavailable(let s): "GPU unavailable: \(s)"
        case .gpuUnsupported(let s): "not supported on the GPU: \(s)"
        case .invalidInput(let s): "invalid input: \(s)"
        }
    }
}

/// A Filter-menu filter: Codable parameters mirroring photocraft's `FilterParams` variant, a
/// halo, a CPU reference on `FloatImage`, and a Metal path that must match it.
public protocol Filter: Codable, Sendable {
    /// Photoshop's menu name.
    var label: String { get }

    /// Pixels read outside an output rectangle, for the reference `bounds`.
    func halo(bounds: PixelRect) -> Halo

    /// The CPU reference: the output for `out` from `src`, which covers `out` grown by the halo
    /// (or the bounds, for global filters). Samples outside `src` read as 0 (transparent).
    func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage

    /// How the Metal path treats channels.
    var gpuChannels: GPUChannels { get }

    /// Whether the Metal path handles this input (defaults from `gpuChannels`).
    func supportsGPU(_ ctx: FilterContext, channels: Int) -> Bool

    /// Encodes the Metal path for one plane of the image (see `GPUPass`).
    func encodeGPU(_ pass: GPUPass) throws

    /// Whether the Surface-level runner should filter the whole area in one piece rather than in
    /// tiles (photocraft runs its running-sum box blurs over the whole area — `apply_box_blur` —
    /// because float running sums depend on where a row starts).
    var processesWholeArea: Bool { get }

    /// Whether the CPU reference reads and writes pixels only as straight sRGB (`ctx.rgba` in,
    /// `ctx.setRGBA` out) — so a CMYK or Lab document gives the same numbers as its sRGB
    /// conversion filtered as RGB and converted back. The engine then runs such documents on the
    /// GPU that way (the conversions on the CPU, through the same functions the reference calls).
    var rgbaEquivalent: Bool { get }
}

extension Filter {
    public var gpuChannels: GPUChannels { .perChannel }

    public func supportsGPU(_ ctx: FilterContext, channels: Int) -> Bool {
        switch gpuChannels {
        case .perChannel: return true
        case .none: return false
        case .joint:
            let cc = ctx.colorChannels(channels)
            return (ctx.mode.isGrayLike || ctx.mode.isRGBLike) && cc <= (ctx.alpha ? 3 : 4)
        }
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        throw FilterError.gpuUnsupported(label)
    }

    public var processesWholeArea: Bool { false }
    public var rgbaEquivalent: Bool { false }

    /// Whether the filter moves pixels around the reference bounds (photocraft `is_global`).
    public func isGlobal(bounds: PixelRect) -> Bool { halo(bounds: bounds) == .bounds }
}
