// The injection seam: one slot per capability. An empty slot runs the Kit's model-free tier
// (Vision, or a classical algorithm), or a built-in tier set under the slot (PCEngine's PatchMatch
// under inpaint), which emptying the slot leaves in place; a capability with none (colorize, upscale, face restore,
// scratch detection, generative fill, Image Size's enlarger) reports `unavailable(reason)` until the host registers a
// provider. The host app, which links ForgeCore (MLX), registers the engine-backed providers here in
// one statement each; this package never depends on ForgeCore (fleet rule: Category A never depends
// on Category B). Replaces the planned photocraft `ml` crate's model registry (docs/architecture.md
// §2), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import ColorizeKit
import EraseKit
import ExtractKit
import MaskKit
import RestoreTier2
import Synchronization

/// Thread-safe registry of injected providers. Safe to read and write from any task; a running
/// operation keeps the provider it resolved when it started.
public final class ProviderRegistry: Sendable {
    struct Entry: Sendable {
        let provider: any Sendable
        let tier: IntelligenceTier
        let name: String
    }

    private let slots = Mutex<[Capability: Entry]>([:])
    /// The model-free tiers a host supplies under the slots (PCEngine's PatchMatch under `inpaint`).
    private let builtIns = Mutex<[Capability: Entry]>([:])

    public init() {}

    // MARK: Registration (Kit seams)

    /// Select Subject and Remove Background (e.g. ForgeCore `EngineMatteProvider`, BiRefNet).
    public func register(matte provider: any MatteProvider, tier: IntelligenceTier = .model) {
        set(.subjectMatte, provider, tier, provider.name)
    }

    /// The Object Selection tool (e.g. ForgeCore `EnginePromptMaskProvider`, EdgeTAM / SAM 2.1).
    public func register(promptMask provider: any PromptMaskProvider, tier: IntelligenceTier = .model) {
        set(.promptMask, provider, tier, provider.name)
    }

    /// The Remove tool and Content-Aware Fill (e.g. ForgeCore `EngineInpaintProvider`, LaMa /
    /// MI-GAN; or a classical patch-based filler registered with `tier: .classical`). Also the
    /// Generative Fill stand-in while no generative provider is registered.
    public func register(inpaint provider: any InpaintProvider, tier: IntelligenceTier = .model) {
        set(.inpaint, provider, tier, provider.name)
    }

    /// Neural Filters ▸ Colorize (e.g. ForgeCore `EngineColorizeProvider`, DDColor).
    public func register(colorize provider: any ColorizeProvider, tier: IntelligenceTier = .model) {
        set(.colorize, provider, tier, provider.name)
    }

    /// Denoise and deblur jobs (e.g. ForgeCore `EngineFrameRestoreProvider`: NAFNet, SCUNet,
    /// Restormer). The receipt names the backer the provider reports for each job.
    public func register(restore provider: any FrameRestoreProvider, tier: IntelligenceTier = .model,
                         name: String = "FrameRestoreProvider") {
        set(.restore, provider, tier, name)
    }

    // MARK: Registration (PCIntelligence seams)

    /// Generative Fill.
    public func register(generativeFill provider: any GenerativeFillProvider, tier: IntelligenceTier = .model) {
        set(.generativeFill, provider, tier, provider.name)
    }

    /// Smart Portrait and Photo Restoration ▸ Enhance Face.
    public func register(faceRestore provider: any FaceRestoreProvider, tier: IntelligenceTier = .model) {
        set(.faceRestore, provider, tier, provider.name)
    }

    /// Photo Restoration ▸ Scratch Reduction's detector.
    public func register(scratchDetect provider: any DefectMaskProvider, tier: IntelligenceTier = .model) {
        set(.scratchDetect, provider, tier, provider.name)
    }

    /// Super Resolution and Preserve Details 2.0.
    public func register(upscale provider: any UpscaleProvider, tier: IntelligenceTier = .model) {
        set(.upscale, provider, tier, provider.name)
    }

    /// Auto White Balance (replaces LightTier0's estimate).
    public func register(whiteBalance provider: any WhiteBalanceProvider, tier: IntelligenceTier = .model) {
        set(.whiteBalance, provider, tier, provider.name)
    }

    /// SDR → HDR (replaces LightTier0's expansion).
    public func register(hdrExpansion provider: any HDRExpansionProvider, tier: IntelligenceTier = .model) {
        set(.hdrExpansion, provider, tier, provider.name)
    }

    /// Image Size's enlarger method: a whole-image ×2 (`image.imageSize` with `"enlarger"`; e.g. anime4k-metal's
    /// `Anime4KUpscaler` through `CGImageEnlarger`). A provider whose `availability` says it can't run (no Metal
    /// device) reports unavailable; so does an empty slot, and Image Size then runs its Resample alone.
    public func register(enlarger provider: any ImageEnlarger, tier: IntelligenceTier = .model) {
        set(.enlarge, provider, tier, provider.name)
    }

    // MARK: Built-in tiers

    /// The classical tier under the inpaint slot, in place of EraseKit's diffusion: what the Remove tool, Content-Aware
    /// Fill and Scratch Reduction run while no provider is registered (PCEngine puts PCAlgo's PatchMatch here). It isn't
    /// injected: `unregister(.inpaint)` and `removeAll()` leave it, so a host that empties the slot when its model isn't
    /// ready falls back to it. Registering a provider in the slot still overrides it.
    public func setBuiltIn(inpaint provider: any InpaintProvider) {
        builtIns.withLock { $0[.inpaint] = Entry(provider: provider, tier: .classical, name: provider.name) }
    }

    /// The name of the built-in tier set under `capability`'s slot, if any.
    public func builtInName(_ capability: Capability) -> String? { builtIns.withLock { $0[capability]?.name } }

    /// Empties a slot: the capability falls back to its model-free tier (a built-in one when set), or becomes
    /// unavailable.
    public func unregister(_ capability: Capability) {
        _ = slots.withLock { $0.removeValue(forKey: capability) }
    }

    /// Empties every slot. Built-in tiers stay.
    public func removeAll() { slots.withLock { $0.removeAll() } }

    /// The capabilities with an injected provider.
    public var injectedCapabilities: Set<Capability> { slots.withLock { Set($0.keys) } }

    private func set(_ c: Capability, _ p: any Sendable, _ tier: IntelligenceTier, _ name: String) {
        slots.withLock { $0[c] = Entry(provider: p, tier: tier, name: name) }
    }

    func entry(_ c: Capability) -> Entry? { slots.withLock { $0[c] } }

    // MARK: Status

    /// Whether `capability` can run now, and on what.
    public func status(of capability: Capability) -> CapabilityStatus {
        let e = entry(capability)
        if let e, capability == .enlarge, let p = e.provider as? any ImageEnlarger, case .unavailable(let why) = p.availability {
            return .unavailable(reason: "\(e.name) can't run: \(why)")
        }
        if let e { return .available(tier: e.tier, engine: e.name, injected: true) }
        if let b = builtIns.withLock({ $0[capability] }) { return .available(tier: b.tier, engine: b.name, injected: false) }
        switch capability {
        case .subjectMatte:
            return .available(tier: .vision, engine: BuiltIn.visionMatte, injected: false)
        case .promptMask:
            return .available(tier: .vision, engine: VisionInstanceMaskProvider.engineName, injected: false)
        case .inpaint:
            return .available(tier: .classical, engine: BuiltIn.classicalInpaint, injected: false)
        case .restore:
            return .available(tier: .classical, engine: BuiltIn.classicalDenoise, injected: false)
        case .whiteBalance:
            return .available(tier: .classical, engine: BuiltIn.whiteBalance, injected: false)
        case .hdrExpansion:
            return .available(tier: .classical, engine: BuiltIn.hdrExpansion, injected: false)
        case .generativeFill:
            if let inpaint = self.entry(.inpaint), inpaint.tier == .model {
                return .available(tier: .model, engine: "\(inpaint.name) (inpaint stand-in, prompt ignored)", injected: true)
            }
            return .unavailable(reason: "Generative Fill needs a generative model; register a GenerativeFillProvider, or an inpaint model (LaMa) as the stand-in")
        case .colorize:
            return .unavailable(reason: "macOS has no colorizer; register a ColorizeProvider (DDColor through ForgeCore's EngineColorizeProvider)")
        case .faceRestore:
            return .unavailable(reason: "face restoration needs a model; register a FaceRestoreProvider (GFPGAN or RestoreFormer++ through ForgeCore)")
        case .scratchDetect:
            return .unavailable(reason: "scratch detection needs a model; register a DefectMaskProvider (BOPBTL through ForgeCore)")
        case .upscale:
            return .unavailable(reason: "super resolution needs a model; register an UpscaleProvider (NERVE, RealPLKSR or Real-ESRGAN through ForgeCore)")
        case .enlarge:
            return .unavailable(reason: "Image Size's enlarger method needs a ×2 enlarger; register an ImageEnlarger (Anime4K through anime4k-metal). Without one, Image Size uses the chosen Resample alone")
        }
    }

    /// Status of one restore job. Denoise has a classical tier; the deblur jobs need a model. An
    /// injected provider that reports "unavailable" for a job (ForgeCore's adapter does when that
    /// job's backer did not register) leaves the job unavailable or classical.
    public func status(of job: RestoreJob) -> CapabilityStatus {
        if let e = entry(.restore), let p = e.provider as? any FrameRestoreProvider {
            let backer = p.engineName(for: job)
            if backer != "unavailable" && !backer.isEmpty { return .available(tier: e.tier, engine: backer, injected: true) }
        }
        if job == .denoise { return .available(tier: .classical, engine: BuiltIn.classicalDenoise, injected: false) }
        return .unavailable(reason: "\(job.rawValue) needs a model (Restormer through ForgeCore's EngineFrameRestoreProvider); sharpening is not deblurring")
    }

    /// Every capability's status, in declaration order.
    public var statuses: [(Capability, CapabilityStatus)] { Capability.allCases.map { ($0, status(of: $0)) } }

    // MARK: Typed resolution

    /// The injected provider, else the built-in tier.
    func provider<P>(_ c: Capability, as type: P.Type) -> (provider: P, tier: IntelligenceTier, name: String)? {
        guard let e = entry(c) ?? builtIns.withLock({ $0[c] }), let p = e.provider as? P else { return nil }
        return (p, e.tier, e.name)
    }
}

/// Names of the built-in (model-free) backers, as receipts print them.
public enum BuiltIn {
    public static let visionMatte = "Apple Vision foreground mask (ExtractKit Tier 1)"
    public static let classicalInpaint = "EraseKit ClassicalInpainter (Tier 0 diffusion)"
    public static let classicalDenoise = "RestoreTier0 guided filter (Immerkaer σ)"
    public static let whiteBalance = "LightTier0 shades-of-grey p=6 + Bradford"
    public static let hdrExpansion = "LightTier0 BT.2408 inverse tone mapping"
}
