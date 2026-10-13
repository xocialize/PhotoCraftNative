// Filter ▸ Neural Filters (photocraft gap G15: "no Neural Filters"): Colorize through ColorizeKit,
// Photo Restoration (scratch reduction → noise reduction → face enhancement), JPEG Artifacts Removal
// and Smart Portrait's face restoration, through RestoreTier0 / RestoreTier2 and the face and defect
// slots. Each filter runs on a pixel layer within the canvas and the layer's content, limited and
// blended by the selection like photocraft's selection-aware filters (FloatImage.mixed: original ×
// (1 − coverage) + filtered × coverage), and preserves the layer's alpha. Filter-command conventions
// after photocraft-engine (crates/engine/src/filters.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import ColorizeKit
import CoreGraphics
import EraseKit
import PCDocument
import PCFoundation
import PCHistory
import RestoreTier2

/// Colorize options.
public struct ColorizeOptions: Sendable, Equatable {
    /// The provider's variant (DDColor fast / best / artistic).
    public var variant: ColorizeVariant
    public var output: FilterOutput
    public init(variant: ColorizeVariant = .best, output: FilterOutput = .currentLayer) { self.variant = variant; self.output = output }
}

/// Photo Restoration's sliders (each 0…1; 0 skips the stage).
public struct PhotoRestorationOptions: Sendable, Equatable {
    /// Scratch Reduction: detect damage (scratch slot) and fill it (inpaint slot).
    public var scratchReduction: Float
    /// Noise reduction (restore slot's denoise job, else RestoreTier0).
    public var noiseReduction: Float
    /// Enhance Face (face slot).
    public var enhanceFace: Float
    public var output: FilterOutput

    public init(scratchReduction: Float = 0.5, noiseReduction: Float = 0.5, enhanceFace: Float = 0.5, output: FilterOutput = .currentLayer) {
        self.scratchReduction = scratchReduction; self.noiseReduction = noiseReduction; self.enhanceFace = enhanceFace; self.output = output
    }
}

/// JPEG Artifacts Removal strength (Photoshop's Low / Medium / High).
public enum ArtifactStrength: String, Sendable, Codable, CaseIterable {
    case low, medium, high
    var value: Float { self == .low ? 0.33 : self == .medium ? 0.66 : 1 }
}

/// The pixels a layer filter works on.
struct FilterInput {
    var rect: PixelRect
    var rgba: [SIMD4<Float>]
    var colorSpace: CGColorSpace
    var sample: SampleType
    var width: Int { rect.width }
    var height: Int { rect.height }

    /// The region as an opaque image for a Kit.
    func image() throws -> CGImage {
        try KitBridge.image(fromRGBA: rgba, width: width, height: height, sample: sample, colorSpace: colorSpace, alpha: .opaque)
    }

    /// A Kit's result as RGBA over the region, keeping the source alpha.
    func decode(_ img: CGImage) throws -> [SIMD4<Float>] {
        var out = try KitBridge.rgba(from: img, colorSpace: colorSpace, sample: sample, width: width, height: height)
        for i in out.indices { out[i].w = rgba[i].w }
        return out
    }
}

extension PCIntelligence {

    // MARK: The shared layer filter

    /// Runs `body` on the filterable region of pixel layer `id` and turns its result into an edit.
    func filterLayer(_ doc: Document, layer id: LayerId, output: FilterOutput, label: String, stage: Stage,
                     _ body: (FilterInput) async throws -> ([SIMD4<Float>], [TierReceipt])) async throws -> PixelEditOutcome {
        let (layer, surface) = try editablePixelLayer(doc, id)
        var rect = doc.bounds.intersect(surface.contentBounds)
        let selection = doc.selection
        if let sel = selection { rect = rect.intersect(sel.contentBounds) }
        guard !rect.isEmpty else {
            throw IntelligenceError.emptyMask(selection == nil ? "the layer has no pixels on the canvas" : "the selection holds none of the layer's pixels")
        }
        let input = FilterInput(rect: rect, rgba: surface.readRGBA(rect), colorSpace: KitBridge.colorSpace(for: doc), sample: surface.format.sample)
        let (out, receipts) = try await body(input)
        try stage.report(0.95, "Applying")
        var result = out
        for i in result.indices { result[i].w = input.rgba[i].w }
        let w = PixelWrite(rect: rect, original: surface.readRegion(rect), result: KitBridge.native(result, format: surface.format),
                           coverage: selectionCoverage(doc, rect)?.values)
        let (tx, target, changed) = try PCIntelligence.commit(w, doc: doc, layer: layer, surface: surface,
                                                              target: PCIntelligence.target(output, newName: doc.copyName(layer.name)), label: label)
        try stage.report(1, "Done")
        let main = receipts.max { $0.tier < $1.tier } ?? receipts.first ?? TierReceipt(capability: .restore, tier: .classical, engine: "none")
        return PixelEditOutcome(layer: target, changedRect: changed, transaction: tx, receipt: main, stages: receipts)
    }

    // MARK: Colorize

    /// Neural Filters ▸ Colorize. ColorizeKit has no model-free tier (macOS has no colorizer), so this
    /// is unavailable until a `ColorizeProvider` is registered.
    public func colorize(_ doc: Document, layer id: LayerId, options: ColorizeOptions = .init(),
                         progress: ProgressHandler? = nil) async throws -> PixelEditOutcome {
        guard let p = registry.provider(.colorize, as: (any ColorizeProvider).self) else {
            throw IntelligenceError.unavailable(.colorize, registry.status(of: .colorize).reason ?? "")
        }
        guard !doc.mode.isGrayLike else {
            throw IntelligenceError.refused("Colorize needs an RGB, CMYK or Lab document (Image ▸ Mode ▸ RGB Color)")
        }
        let stage = Stage(handler: progress)
        try stage.report(0, "Colorize")
        return try await filterLayer(doc, layer: id, output: options.output, label: "Colorize", stage: stage) { input in
            let colored = try await run(.colorize) { try await Colorizer.colorize(input.image(), provider: p.provider, variant: options.variant) }
            return (try input.decode(colored), [TierReceipt(capability: .colorize, tier: p.tier, engine: p.name, notes: ["variant: \(options.variant.rawValue)"])])
        }
    }

    // MARK: JPEG Artifacts Removal

    /// Neural Filters ▸ JPEG Artifacts Removal: the restore slot's denoise job when a provider is
    /// registered (NAFNet through ForgeCore), else RestoreTier0's guided-filter smoothing.
    public func jpegArtifactsRemoval(_ doc: Document, layer id: LayerId, strength: ArtifactStrength = .medium,
                                     output: FilterOutput = .currentLayer, progress: ProgressHandler? = nil) async throws -> PixelEditOutcome {
        let stage = Stage(handler: progress)
        try stage.report(0, "JPEG Artifacts Removal")
        return try await filterLayer(doc, layer: id, output: output, label: "JPEG Artifacts Removal", stage: stage) { input in
            let (px, r) = try await denoise(input, strength: strength.value)
            return (px, [r])
        }
    }

    /// The denoise job: the restore provider's backer for `.denoise`, else RestoreTier0.
    func denoise(_ input: FilterInput, strength: Float) async throws -> ([SIMD4<Float>], TierReceipt) {
        if case .available(let tier, let engine, true) = registry.status(of: RestoreJob.denoise),
           let p = registry.provider(.restore, as: (any FrameRestoreProvider).self) {
            let data = try KitBridge.pngData(input.image())
            let r = try await run(.restore) { try await p.provider.restore(imageData: data, job: .denoise, strength: strength) }
            let img = try KitBridge.decodeImage(r.imageData)
            var metrics: [String: Double] = [:]
            if let s = r.appliedStrength { metrics["appliedStrength"] = Double(s) }
            return (try input.decode(img), TierReceipt(capability: .restore, tier: tier, engine: r.engineName.isEmpty ? engine : r.engineName,
                                                       notes: r.appliedStrength == nil ? ["the backer has no strength dial"] : [], metrics: metrics))
        }
        let d = ClassicalDenoise.denoise(input.rgba, width: input.width, height: input.height, strength: strength)
        return (d.rgba, TierReceipt(capability: .restore, tier: .classical, engine: BuiltIn.classicalDenoise,
                                    metrics: ["noiseSigma": Double(d.sigmaBefore), "noiseSigmaAfter": Double(d.sigmaAfter), "strength": Double(strength)]))
    }

    // MARK: Smart Portrait (face restoration)

    /// Neural Filters ▸ Smart Portrait, face restoration only: unavailable until a
    /// `FaceRestoreProvider` is registered (GFPGAN / RestoreFormer++ through ForgeCore).
    public func restoreFaces(_ doc: Document, layer id: LayerId, strength: Float = 1, output: FilterOutput = .currentLayer,
                             progress: ProgressHandler? = nil) async throws -> PixelEditOutcome {
        guard let p = registry.provider(.faceRestore, as: (any FaceRestoreProvider).self) else {
            throw IntelligenceError.unavailable(.faceRestore, registry.status(of: .faceRestore).reason ?? "")
        }
        let stage = Stage(handler: progress)
        try stage.report(0, "Smart Portrait")
        let s = min(max(strength, 0), 1)
        return try await filterLayer(doc, layer: id, output: output, label: "Smart Portrait", stage: stage) { input in
            let img = try await run(.faceRestore) { try await p.provider.restoreFaces(input.image(), strength: s) }
            return (try input.decode(img), [TierReceipt(capability: .faceRestore, tier: p.tier, engine: p.name, metrics: ["strength": Double(s)])])
        }
    }

    // MARK: Photo Restoration

    /// Neural Filters ▸ Photo Restoration: scratch reduction (the scratch slot's defect mask filled
    /// through the inpaint slot), then noise reduction (restore slot or RestoreTier0), then face
    /// enhancement (face slot). A stage whose model is missing is skipped and named in the receipts;
    /// when no requested stage can run the filter is unavailable.
    public func photoRestoration(_ doc: Document, layer id: LayerId, options: PhotoRestorationOptions = .init(),
                                 progress: ProgressHandler? = nil) async throws -> PixelEditOutcome {
        let stage = Stage(handler: progress)
        let scratch = registry.provider(.scratchDetect, as: (any DefectMaskProvider).self)
        let face = registry.provider(.faceRestore, as: (any FaceRestoreProvider).self)
        let wantsScratch = options.scratchReduction > 0, wantsNoise = options.noiseReduction > 0, wantsFace = options.enhanceFace > 0
        guard (wantsScratch && scratch != nil) || wantsNoise || (wantsFace && face != nil) else {
            throw IntelligenceError.unavailable(.restore, "Photo Restoration has nothing to run: noise reduction is off, and scratch reduction and Enhance Face need models (register a DefectMaskProvider and a FaceRestoreProvider)")
        }
        try stage.report(0, "Photo Restoration")
        return try await filterLayer(doc, layer: id, output: options.output, label: "Photo Restoration", stage: stage) { input in
            var current = input
            var receipts: [TierReceipt] = []
            var skipped: [String] = []
            if wantsScratch {
                if let scratch {
                    try stage.report(0.1, "Scratch reduction")
                    let image = try current.image()
                    let maskImage = try await run(.scratchDetect) { try await scratch.provider.defectMask(image) }
                    let mask = try KitBridge.coverage(from: maskImage, width: current.width, height: current.height)
                    receipts.append(TierReceipt(capability: .scratchDetect, tier: scratch.tier, engine: scratch.name,
                                                metrics: ["defectFraction": Double(mask.filter { $0 > 0.5 }.count) / Double(max(mask.count, 1))]))
                    if mask.contains(where: { $0 > 0.5 }) {
                        let inpaint = registry.provider(.inpaint, as: (any InpaintProvider).self)
                        let binary = try KitBridge.maskImage(mask.map { $0 > 0.5 ? 1 : 0 }, width: current.width, height: current.height)
                        let dilation = 1 + Int((min(options.scratchReduction, 1) * 3).rounded())
                        let filled = try await run(.inpaint) {
                            try await Eraser.erase(image, mask: binary, provider: inpaint?.provider, quality: .best, maskDilation: dilation)
                        }
                        current.rgba = try current.decode(filled)
                        receipts.append(TierReceipt(capability: .inpaint, tier: inpaint?.tier ?? .classical,
                                                    engine: inpaint.map { $0.provider.engineName(for: .best) } ?? BuiltIn.classicalInpaint))
                    }
                } else {
                    skipped.append("scratch reduction skipped: no DefectMaskProvider registered")
                }
            }
            if wantsNoise {
                try stage.report(0.4, "Noise reduction")
                let (px, r) = try await denoise(current, strength: min(options.noiseReduction, 1))
                current.rgba = px
                receipts.append(r)
            }
            if wantsFace {
                if let face {
                    try stage.report(0.7, "Enhance face")
                    let s = min(options.enhanceFace, 1)
                    let img = try await run(.faceRestore) { try await face.provider.restoreFaces(current.image(), strength: s) }
                    current.rgba = try current.decode(img)
                    receipts.append(TierReceipt(capability: .faceRestore, tier: face.tier, engine: face.name, metrics: ["strength": Double(s)]))
                } else {
                    skipped.append("Enhance Face skipped: no FaceRestoreProvider registered")
                }
            }
            for i in receipts.indices { receipts[i].notes.append(contentsOf: skipped) }
            return (current.rgba, receipts)
        }
    }
}
