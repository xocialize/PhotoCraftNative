// Provider seams for the capabilities no fleet Kit names yet. Where a Kit owns the seam (MaskKit's
// `PromptMaskProvider`, ExtractKit's `MatteProvider`, EraseKit's `InpaintProvider`, ColorizeKit's
// `ColorizeProvider`, RestoreTier2's `FrameRestoreProvider`) the registry takes the Kit's protocol
// as is, so ForgeCore's engine adapters register unchanged. The protocols here cover the rest:
// generative fill, face restoration, scratch detection, upscaling, and model tiers for white balance
// and SDR → HDR. They follow the Kits' shape (CGImage in, CGImage out, `name` for the receipt), and
// each has a closure adapter so a host wires an engine call in one statement. Part of the AI tier
// for photocraft gap G15, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import EraseKit

/// What EraseKit's `InpaintProvider.inpaint(_:mask:quality:)` has no parameter for: Content-Aware
/// Fill's sampling area and adaptation settings (photocraft `content_aware::FillOptions`, plus the
/// dialog's sampling choice). PCIntelligence passes them on to providers that adopt
/// `OptionsInpaintProvider` (PCEngine's PatchMatch); model providers (LaMa, MI-GAN) and EraseKit's
/// classical fill take none and ignore them. The defaults are the Remove tool's.
public struct InpaintOptions: Sendable, Equatable {
    /// Which pixels of the window the fill may copy from.
    public enum Sampling: Sendable, Equatable {
        /// Everything in the window outside the hole.
        case window
        /// Content-Aware Fill's Auto: only what looks like the hole's surroundings.
        case auto
        /// Only window pixels where this mask is set (window-sized, row-major).
        case mask([Bool])
    }

    /// Color Adaptation (photocraft's `colorAdaptation` values).
    public enum ColorAdaptation: String, Sendable, CaseIterable {
        case none, `default`, high, veryHigh
    }

    /// Rotation Adaptation (photocraft's `rotationAdaptation` values).
    public enum RotationAdaptation: String, Sendable, CaseIterable {
        case none, low, medium, high, full
    }

    public var sampling: Sampling
    public var colorAdaptation: ColorAdaptation
    public var rotationAdaptation: RotationAdaptation
    /// Also copy from downscaled and upscaled versions of the source.
    public var scale: Bool
    /// Also copy from a mirrored version of the source.
    public var mirror: Bool
    public var seed: UInt64

    public init(sampling: Sampling = .window, colorAdaptation: ColorAdaptation = .default, rotationAdaptation: RotationAdaptation = .none,
                scale: Bool = false, mirror: Bool = false, seed: UInt64 = 1) {
        self.sampling = sampling; self.colorAdaptation = colorAdaptation; self.rotationAdaptation = rotationAdaptation
        self.scale = scale; self.mirror = mirror; self.seed = seed
    }
}

/// An inpaint provider that takes `InpaintOptions`: the options parameter the Kit seam lacks.
/// Adopters implement only the options form; the plain EraseKit requirement runs it with the
/// default options, so the provider still registers and runs anywhere an `InpaintProvider` does.
public protocol OptionsInpaintProvider: InpaintProvider {
    func inpaint(_ image: CGImage, mask: CGImage, quality: InpaintQuality, options: InpaintOptions) async throws -> CGImage
}

extension OptionsInpaintProvider {
    public func inpaint(_ image: CGImage, mask: CGImage, quality: InpaintQuality) async throws -> CGImage {
        try await inpaint(image, mask: mask, quality: quality, options: InpaintOptions())
    }
}

/// `provider` with `options` bound, as a plain `InpaintProvider` for EraseKit's `Eraser`
/// (unchanged when it takes no options).
func bindingOptions(_ provider: any InpaintProvider, _ options: InpaintOptions) -> any InpaintProvider {
    guard let p = provider as? any OptionsInpaintProvider else { return provider }
    return OptionsBoundInpaint(base: p, options: options)
}

struct OptionsBoundInpaint: InpaintProvider {
    let base: any OptionsInpaintProvider
    let options: InpaintOptions
    var name: String { base.name }
    func engineName(for quality: InpaintQuality) -> String { base.engineName(for: quality) }
    func inpaint(_ image: CGImage, mask: CGImage, quality: InpaintQuality) async throws -> CGImage {
        try await base.inpaint(image, mask: mask, quality: quality, options: options)
    }
}

/// Fills a masked area from a text prompt (Generative Fill). `mask` is grayscale, white = generate,
/// at the image's size; the result is the whole image at the same size (the caller composites it
/// through the selection).
public protocol GenerativeFillProvider: Sendable {
    var name: String { get }
    func fill(_ image: CGImage, mask: CGImage, prompt: String) async throws -> CGImage
}

/// Restores faces in an image (GFPGAN, RestoreFormer++). `strength` is 0…1; the result has the
/// image's size.
public protocol FaceRestoreProvider: Sendable {
    var name: String { get }
    func restoreFaces(_ image: CGImage, strength: Float) async throws -> CGImage
}

/// Detects physical damage (scratches, dust, tears; BOPBTL). Returns a grayscale mask, white =
/// defect, at the image's size; its canonical consumer is an inpainter.
public protocol DefectMaskProvider: Sendable {
    var name: String { get }
    func defectMask(_ image: CGImage) async throws -> CGImage
}

/// Super-resolves an image by an integer factor (NERVE, RealPLKSR, Real-ESRGAN). The result is
/// expected at `factor ×` the input size; another integer multiple is reported as the applied scale.
public protocol UpscaleProvider: Sendable {
    var name: String { get }
    func upscale(_ image: CGImage, factor: Int) async throws -> CGImage
}

/// Replaces the classical white balance (LightTier0) with another backer. The result has the image's
/// size and colour space.
public protocol WhiteBalanceProvider: Sendable {
    var name: String { get }
    func balance(_ image: CGImage) async throws -> CGImage
}

/// Replaces the classical SDR → HDR expansion (LightTier0). The input is SDR (encoded); the result
/// is a float image in linear light where 1.0 is the BT.2408 HDR reference white (203 cd/m²), with
/// SDR white placed at `diffuseWhiteNits`.
public protocol HDRExpansionProvider: Sendable {
    var name: String { get }
    func expand(_ image: CGImage, diffuseWhiteNits: Double) async throws -> CGImage
}

// MARK: - Closure adapters (one statement per registration)

/// A `GenerativeFillProvider` from a closure.
public struct GenerativeFillClosure: GenerativeFillProvider {
    public let name: String
    let body: @Sendable (CGImage, CGImage, String) async throws -> CGImage
    public init(_ name: String, _ body: @escaping @Sendable (_ image: CGImage, _ mask: CGImage, _ prompt: String) async throws -> CGImage) {
        self.name = name; self.body = body
    }
    public func fill(_ image: CGImage, mask: CGImage, prompt: String) async throws -> CGImage { try await body(image, mask, prompt) }
}

/// A `FaceRestoreProvider` from a closure.
public struct FaceRestoreClosure: FaceRestoreProvider {
    public let name: String
    let body: @Sendable (CGImage, Float) async throws -> CGImage
    public init(_ name: String, _ body: @escaping @Sendable (_ image: CGImage, _ strength: Float) async throws -> CGImage) {
        self.name = name; self.body = body
    }
    public func restoreFaces(_ image: CGImage, strength: Float) async throws -> CGImage { try await body(image, strength) }
}

/// A `DefectMaskProvider` from a closure.
public struct DefectMaskClosure: DefectMaskProvider {
    public let name: String
    let body: @Sendable (CGImage) async throws -> CGImage
    public init(_ name: String, _ body: @escaping @Sendable (_ image: CGImage) async throws -> CGImage) {
        self.name = name; self.body = body
    }
    public func defectMask(_ image: CGImage) async throws -> CGImage { try await body(image) }
}

/// An `UpscaleProvider` from a closure.
public struct UpscaleClosure: UpscaleProvider {
    public let name: String
    let body: @Sendable (CGImage, Int) async throws -> CGImage
    public init(_ name: String, _ body: @escaping @Sendable (_ image: CGImage, _ factor: Int) async throws -> CGImage) {
        self.name = name; self.body = body
    }
    public func upscale(_ image: CGImage, factor: Int) async throws -> CGImage { try await body(image, factor) }
}

/// A `WhiteBalanceProvider` from a closure.
public struct WhiteBalanceClosure: WhiteBalanceProvider {
    public let name: String
    let body: @Sendable (CGImage) async throws -> CGImage
    public init(_ name: String, _ body: @escaping @Sendable (_ image: CGImage) async throws -> CGImage) {
        self.name = name; self.body = body
    }
    public func balance(_ image: CGImage) async throws -> CGImage { try await body(image) }
}

/// An `HDRExpansionProvider` from a closure.
public struct HDRExpansionClosure: HDRExpansionProvider {
    public let name: String
    let body: @Sendable (CGImage, Double) async throws -> CGImage
    public init(_ name: String, _ body: @escaping @Sendable (_ image: CGImage, _ diffuseWhiteNits: Double) async throws -> CGImage) {
        self.name = name; self.body = body
    }
    public func expand(_ image: CGImage, diffuseWhiteNits: Double) async throws -> CGImage { try await body(image, diffuseWhiteNits) }
}
