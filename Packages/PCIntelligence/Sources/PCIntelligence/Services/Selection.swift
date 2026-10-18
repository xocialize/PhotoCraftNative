// Select ▸ Subject, the Object Selection tool (click, box) and its hover preview (Object Finder),
// and Remove Background (photocraft gap G15: "ML Select Subject"). The model-free tiers are Apple
// Vision through ExtractKit (`ForegroundExtractor`, Tier 1) and Vision's foreground instances behind
// MaskKit's promptable seam; the registry swaps in BiRefNet / EdgeTAM. Result semantics follow
// photocraft-engine's `select.subject`, `select.object` (crates/engine/src/smartselect_cmds.rs) and
// `layer.removeBackground` (crates/engine/src/cutout_cmds.rs): the canvas is analysed, the found
// region combines with the selection by mode, finding nothing leaves the selection alone, and
// Remove Background adds a layer mask, turning the Background into "Layer 0" first.
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import CoreImage
import ExtractKit
import Foundation
import MaskKit
import PCDocument
import PCFoundation
import PCHistory

/// One click of the Object Selection tool, in document pixels. `include == false` subtracts.
public struct ObjectPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var include: Bool
    public init(x: Double, y: Double, include: Bool = true) { self.x = x; self.y = y; self.include = include }
}

/// What the Object Selection tool points at: clicks and/or a box, in document pixels.
public struct ObjectPrompt: Sendable, Equatable {
    public var points: [ObjectPoint]
    public var box: PixelRect?

    public init(points: [ObjectPoint] = [], box: PixelRect? = nil) { self.points = points; self.box = box }

    /// A single click.
    public static func click(x: Double, y: Double) -> ObjectPrompt { ObjectPrompt(points: [ObjectPoint(x: x, y: y)]) }

    /// A dragged box `[x, y, w, h]`; negative sizes (dragging up or left) are normalised, as
    /// photocraft's `rect_param` does.
    public static func box(x: Double, y: Double, width: Double, height: Double) -> ObjectPrompt {
        let (x0, x1) = (min(x, x + width), max(x, x + width))
        let (y0, y1) = (min(y, y + height), max(y, y + height))
        return ObjectPrompt(box: PixelRect(x0: Int32(clamping: Int(x0.rounded(.down))), y0: Int32(clamping: Int(y0.rounded(.down))),
                                           x1: Int32(clamping: Int(x1.rounded(.up))), y1: Int32(clamping: Int(y1.rounded(.up)))))
    }

    public var isEmpty: Bool { points.isEmpty && (box?.isEmpty ?? true) }

    /// The MaskKit prompt in the pixels of an image whose top-left is `origin`.
    func maskPrompt(origin: PixelRect) -> MaskPrompt {
        let ox = Double(origin.x0), oy = Double(origin.y0)
        return MaskPrompt(points: points.map { MaskPoint(x: CGFloat($0.x - ox), y: CGFloat($0.y - oy), include: $0.include) },
                          box: box.flatMap { $0.isEmpty ? nil : CGRect(x: Double($0.x0) - ox, y: Double($0.y0) - oy, width: Double($0.width), height: Double($0.height)) })
    }
}

/// Select Subject / Remove Background options.
public struct SubjectOptions: Sendable, Equatable {
    /// How the found subject combines with the current selection.
    public var mode: SelectionMode
    /// Depth of the resulting Gray coverage surface (photocraft stores selections as GRAY8).
    public var maskSample: SampleType
    /// The quality an injected matte provider runs (BiRefNet fast / best); Vision ignores it.
    public var quality: ExtractQuality

    public init(mode: SelectionMode = .replace, maskSample: SampleType = .u8, quality: ExtractQuality = .fast) {
        self.mode = mode; self.maskSample = maskSample; self.quality = quality
    }
}

/// The detected objects of an image, computed once for the Object Selection tool's hover preview:
/// moving the pointer looks up the object under it without running Vision again.
public struct ObjectFinder: Sendable {
    /// One detected object.
    public struct Object: Sendable, Equatable {
        public var index: Int
        /// Tight bounds in document space.
        public var bounds: PixelRect
        /// Its coverage in document space.
        public var mask: CoverageMask
    }

    /// The analysed area (the canvas), in document space.
    public let rect: PixelRect
    public let objects: [Object]
    public let receipt: TierReceipt
    let analysis: VisionInstanceAnalysis

    /// The object under document pixel (x, y): what the hover preview highlights.
    public func object(atX x: Double, y: Double) -> Object? {
        guard let inst = analysis.instance(atX: x - Double(rect.x0), y: y - Double(rect.y0)) else { return nil }
        return objects.first { $0.index == inst.index }
    }

    /// Clicking the highlighted object in auto-select mode: its selection combined with `existing`.
    public func select(_ object: Object, mode: SelectionMode = .replace, existing: Surface?,
                       maskSample: SampleType = .u8) -> SelectionOutcome {
        PCIntelligence.selectionOutcome(found: object.mask, existing: existing, mode: mode, sample: maskSample,
                                        label: "Object Selection", receipt: receipt)
    }
}

extension PCIntelligence {

    // MARK: Select ▸ Subject

    /// Select ▸ Subject: the main subject of the canvas, combined with the selection by
    /// `options.mode`. Runs the injected matte provider, else Apple Vision (ExtractKit Tier 1).
    /// Finding nothing returns `changed == false` and no transaction.
    public func selectSubject(_ doc: Document, source: PixelSource = .composite, options: SubjectOptions = .init(),
                              progress: ProgressHandler? = nil) async throws -> SelectionOutcome {
        let stage = Stage(handler: progress)
        try stage.report(0, "Finding subject")
        let (found, receipt) = try await subjectMatte(doc, source: source, quality: options.quality)
        try stage.report(0.9, "Selecting")
        let out = PCIntelligence.selectionOutcome(found: found, existing: doc.selection, mode: options.mode,
                                                  sample: options.maskSample, label: "Select Subject", receipt: receipt)
        try stage.report(1, "Done")
        return out
    }

    /// The subject matte of the canvas (nil when there is no subject) and the tier that ran.
    func subjectMatte(_ doc: Document, source: PixelSource, quality: ExtractQuality) async throws -> (CoverageMask?, TierReceipt) {
        let rect = doc.bounds
        guard !rect.isEmpty else { throw IntelligenceError.badParameter("the canvas is empty") }
        let surface = try await pixels(source, in: doc, rect: rect)
        let image = try KitBridge.image(from: surface, rect: rect, colorSpace: KitBridge.colorSpace(for: doc), alpha: .flatten(over: SIMD3(1, 1, 1)))
        // A mask is coverage, not colour: render it without colour management (EraseKit's MaskOps rule).
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let injected = registry.provider(.subjectMatte, as: (any MatteProvider).self)
        let receipt = injected.map { TierReceipt(capability: .subjectMatte, tier: $0.tier, engine: $0.name, notes: ["quality: \(quality.rawValue)"]) }
            ?? TierReceipt(capability: .subjectMatte, tier: .vision, engine: BuiltIn.visionMatte)
        let result: ExtractResult
        do {
            result = try await ForegroundExtractor.extract(image, provider: injected?.provider, quality: quality, context: context)
        } catch ExtractError.noForeground {
            return (nil, receipt)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IntelligenceError.providerFailed(.subjectMatte, String(describing: error))
        }
        let mask = try CoverageMask(image: result.mask, rect: rect)
        return (mask.isEmpty ? nil : mask, receipt)
    }

    /// The selection outcome of a found region (nil = nothing found).
    static func selectionOutcome(found: CoverageMask?, existing: Surface?, mode: SelectionMode, sample: SampleType,
                                 label: String, receipt: TierReceipt) -> SelectionOutcome {
        guard let found, !found.isEmpty else {
            return SelectionOutcome(selection: existing, changed: false, bounds: .empty, found: nil, transaction: nil, receipt: receipt)
        }
        let combined = CoverageMask.combine(found, with: existing, mode: mode, sample: sample)
        return SelectionOutcome(selection: combined, changed: true, bounds: found.bounds, found: found,
                                transaction: EditTransaction(label, [.setSelection(combined)]), receipt: receipt)
    }

    // MARK: Object Selection

    /// The Object Selection tool: the object at the clicks or inside the box, combined with the
    /// selection by `mode`. Runs the injected prompt-mask provider (EdgeTAM / SAM 2.1), else Vision's
    /// foreground instances. Finding nothing returns `changed == false`.
    public func selectObject(_ doc: Document, prompt: ObjectPrompt, source: PixelSource = .composite,
                             mode: SelectionMode = .replace, maskSample: SampleType = .u8,
                             progress: ProgressHandler? = nil) async throws -> SelectionOutcome {
        guard !prompt.isEmpty else { throw IntelligenceError.badParameter("Object Selection needs a click or a box") }
        let stage = Stage(handler: progress)
        try stage.report(0, "Finding object")
        let rect = doc.bounds
        let surface = try await pixels(source, in: doc, rect: rect)
        let image = try KitBridge.image(from: surface, rect: rect, colorSpace: KitBridge.colorSpace(for: doc), alpha: .flatten(over: SIMD3(1, 1, 1)))
        let injected = registry.provider(.promptMask, as: (any PromptMaskProvider).self)
        let provider: any PromptMaskProvider = injected?.provider ?? VisionInstanceMaskProvider()
        let receipt = TierReceipt(capability: .promptMask, tier: injected?.tier ?? .vision, engine: injected?.name ?? VisionInstanceMaskProvider.engineName)
        let maskImage: CGImage
        do {
            maskImage = try await provider.mask(image, prompt: prompt.maskPrompt(origin: rect))
        } catch let e as VisionInstanceError where e != .emptyPrompt {
            // Vision found nothing at the prompt: leave the selection alone.
            return PCIntelligence.selectionOutcome(found: nil, existing: doc.selection, mode: mode, sample: maskSample,
                                                   label: "Object Selection", receipt: receipt)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IntelligenceError.providerFailed(.promptMask, String(describing: error))
        }
        try stage.report(0.9, "Selecting")
        let found = try CoverageMask(image: maskImage, rect: rect)
        let out = PCIntelligence.selectionOutcome(found: found, existing: doc.selection, mode: mode, sample: maskSample,
                                                  label: "Object Selection", receipt: receipt)
        try stage.report(1, "Done")
        return out
    }

    /// The Object Selection tool's hover preview (Object Finder): every object Vision detects on the
    /// canvas, found once, then looked up per pointer move with `ObjectFinder.object(atX:y:)`. Always
    /// Vision (Tier 1): MaskKit's promptable seam has no "all objects" query for a model to answer.
    public func objectFinder(_ doc: Document, source: PixelSource = .composite,
                             progress: ProgressHandler? = nil) async throws -> ObjectFinder {
        let stage = Stage(handler: progress)
        try stage.report(0, "Finding objects")
        let rect = doc.bounds
        let surface = try await pixels(source, in: doc, rect: rect)
        let image = try KitBridge.image(from: surface, rect: rect, colorSpace: KitBridge.colorSpace(for: doc), alpha: .flatten(over: SIMD3(1, 1, 1)))
        let analysis = try await run(.promptMask) { try VisionInstanceAnalysis(image: image) }
        let objects = analysis.instances.compactMap { inst -> ObjectFinder.Object? in
            let mask = CoverageMask(rect: rect, values: inst.coverage)
            let b = mask.binarized(threshold: 0.5).bounds
            return b.isEmpty ? nil : ObjectFinder.Object(index: inst.index, bounds: b, mask: mask)
        }
        try stage.report(1, "Done")
        return ObjectFinder(rect: rect, objects: objects,
                            receipt: TierReceipt(capability: .promptMask, tier: .vision, engine: VisionInstanceMaskProvider.engineName,
                                                 metrics: ["objects": Double(objects.count)]),
                            analysis: analysis)
    }

    // MARK: Remove Background

    /// Remove Background (Properties ▸ Quick Actions): the subject of `layer` (or of `source`) becomes
    /// the layer's mask, non-destructively; the Background turns into "Layer 0" first and the
    /// selection is dropped. No subject is an error and nothing changes (photocraft
    /// `layer.removeBackground`). A smart object stays a smart object, as in Photoshop: its rendered
    /// placement (`SmartObject.cache`) is sampled, and only its mask changes.
    public func removeBackground(_ doc: Document, layer id: LayerId, source: PixelSource? = nil,
                                 options: SubjectOptions = .init(), progress: ProgressHandler? = nil) async throws -> LayerMaskOutcome {
        let stage = Stage(handler: progress)
        var layer = try maskableLayer(doc, id)
        try stage.report(0.1, "Finding subject")
        let (found, receipt) = try await subjectMatte(doc, source: source ?? .layer(id), quality: options.quality)
        guard let found, let surface = found.surface(sample: options.maskSample) else {
            throw IntelligenceError.nothingFound("no subject found")
        }
        try stage.report(0.9, "Masking")
        let mask = LayerMask(surface: surface)
        if doc.isBackground(id) {
            layer.locks.transparency = false
            layer.locks.position = false
            layer.name = "Layer 0"
        }
        layer.mask = mask
        let tx = EditTransaction("Remove Background", [.replaceLayer(layer), .setSelection(nil)])
        try stage.report(1, "Done")
        return LayerMaskOutcome(layer: id, mask: mask, bounds: found.bounds, transaction: tx, receipt: receipt)
    }
}
