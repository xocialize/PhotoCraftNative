// Capabilities, tiers and receipts: the vocabulary of the AI tier photocraft planned as its `ml`
// crate (docs/architecture.md §2; gap G15) and never built. Every operation names the capability
// it used and the tier that actually ran, so a UI and an agent can tell a classical fill from a
// model's. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

/// Which kind of backer ran an operation.
public enum IntelligenceTier: String, Sendable, Codable, CaseIterable, Comparable {
    /// A classical algorithm, no model and no OS ML (EraseKit's diffusion fill, RestoreTier0,
    /// LightTier0).
    case classical
    /// Apple Vision on-device (no weights, no download).
    case vision
    /// A learned model injected by the host (ForgeCore's engine providers, or another provider).
    case model

    private var order: Int { self == .classical ? 0 : self == .vision ? 1 : 2 }
    public static func < (a: IntelligenceTier, b: IntelligenceTier) -> Bool { a.order < b.order }
}

/// One registry slot: a job the AI tier can do, whatever backs it.
public enum Capability: String, Sendable, Codable, CaseIterable {
    /// A soft subject matte of the whole image: Select ▸ Subject, Remove Background.
    case subjectMatte
    /// Click/box → mask: the Object Selection tool.
    case promptMask
    /// Fill a masked hole from its surroundings: the Remove tool, Content-Aware Fill.
    case inpaint
    /// Fill a masked area from a text prompt: Generative Fill.
    case generativeFill
    /// Grayscale → colour: Neural Filters ▸ Colorize.
    case colorize
    /// Same-size restoration jobs (denoise, motion and defocus deblur): JPEG Artifacts Removal,
    /// Photo Restoration's noise stage.
    case restore
    /// Face restoration: Smart Portrait, Photo Restoration ▸ Enhance Face.
    case faceRestore
    /// Scratch and dust detection: Photo Restoration ▸ Scratch Reduction.
    case scratchDetect
    /// Super-resolution: Super Resolution, Image Size ▸ Preserve Details 2.0.
    case upscale
    /// Illuminant estimate and correction: Auto White Balance.
    case whiteBalance
    /// SDR → HDR inverse tone mapping.
    case hdrExpansion

    /// A short human-readable name.
    public var label: String {
        switch self {
        case .subjectMatte: "Subject matte"
        case .promptMask: "Object selection"
        case .inpaint: "Inpaint"
        case .generativeFill: "Generative fill"
        case .colorize: "Colorize"
        case .restore: "Restore"
        case .faceRestore: "Face restore"
        case .scratchDetect: "Scratch detection"
        case .upscale: "Super resolution"
        case .whiteBalance: "White balance"
        case .hdrExpansion: "SDR → HDR"
        }
    }
}

/// Whether a capability can run now, and on what.
public enum CapabilityStatus: Sendable, Equatable {
    /// It runs on `engine` at `tier`. `injected` is true when the host registered the provider,
    /// false for the Kit's built-in model-free tier.
    case available(tier: IntelligenceTier, engine: String, injected: Bool)
    /// It cannot run until a provider is registered; `reason` says why, for a disabled menu item.
    case unavailable(reason: String)

    public var isAvailable: Bool { if case .available = self { true } else { false } }
    public var tier: IntelligenceTier? { if case .available(let t, _, _) = self { t } else { nil } }
    public var engine: String? { if case .available(_, let e, _) = self { e } else { nil } }
    public var reason: String? { if case .unavailable(let r) = self { r } else { nil } }
}

/// What actually ran for one stage of an operation: the receipt a UI shows and an agent reads.
public struct TierReceipt: Sendable, Equatable {
    public var capability: Capability
    public var tier: IntelligenceTier
    /// The backer that did the work ("Apple Vision", "EraseKit ClassicalInpainter", "LaMa / MI-GAN").
    public var engine: String
    /// Facts about the run ("prompt ignored: inpaint stand-in", "scratch stage skipped: …").
    public var notes: [String]
    /// Measured or applied values ("noiseSigma", "kelvin", "appliedScale", …).
    public var metrics: [String: Double]

    public init(capability: Capability, tier: IntelligenceTier, engine: String, notes: [String] = [], metrics: [String: Double] = [:]) {
        self.capability = capability; self.tier = tier; self.engine = engine; self.notes = notes; self.metrics = metrics
    }
}

/// An operation's progress: a fraction in 0…1 and the stage running.
public struct IntelligenceProgress: Sendable, Equatable {
    public var fraction: Double
    public var stage: String
    public init(fraction: Double, stage: String) { self.fraction = fraction; self.stage = stage }
}

/// Receives progress; called on the operation's task.
public typealias ProgressHandler = @Sendable (IntelligenceProgress) -> Void

/// A recoverable failure of an AI operation, with a message a user or agent can act on. The
/// operations never leave the document half-edited: they return data, and nothing is applied
/// until the caller commits the transaction.
public enum IntelligenceError: Error, Equatable, CustomStringConvertible {
    /// The capability has no model-free tier and no provider is registered.
    case unavailable(Capability, String)
    /// The layer does not exist.
    case noLayer(UInt64)
    /// The layer cannot take the edit (not a pixel layer, locked, …): Photoshop's message.
    case refused(String)
    /// The operation needs a selection.
    case noSelection
    /// The mask or hole is empty.
    case emptyMask(String)
    /// The Kit found nothing (no subject, no object at the prompt).
    case nothingFound(String)
    /// `PixelSource.composite` needs a compositor (PCRender) for this document.
    case compositeUnavailable(String)
    /// A parameter is out of range or malformed.
    case badParameter(String)
    /// The provider or Kit threw.
    case providerFailed(Capability, String)
    /// The image could not cross the bridge.
    case bridge(String)

    public var description: String {
        switch self {
        case .unavailable(let c, let r): "\(c.label) is unavailable: \(r)"
        case .noLayer(let id): "no layer L\(id)"
        case .refused(let m): m
        case .noSelection: "make a selection first"
        case .emptyMask(let m): m
        case .nothingFound(let m): m
        case .compositeUnavailable(let m): m
        case .badParameter(let m): m
        case .providerFailed(let c, let m): "\(c.label) failed: \(m)"
        case .bridge(let m): "image bridge: \(m)"
        }
    }
}
