// The Remove tool, Edit ▸ Content-Aware Fill and Edit ▸ Generative Fill (photocraft gap G15), through
// EraseKit: its Tier-0 classical diffusion fill by default, the injected `InpaintProvider` (LaMa /
// MI-GAN) when registered, and a `GenerativeFillProvider` slot whose stand-in is the inpaint
// provider. What gets filled follows photocraft-engine: Content-Aware Fill fills the selection
// (coverage > 0) from Photoshop's sampling window and blends the fill in by the selection's coverage
// (crates/engine/src/edit_menu_cmds.rs, crates/algo/src/content_aware.rs `sampling_window`); Remove
// fills a hole grown by 2 px from a margin around it, limited by the selection, optionally onto a new
// layer (crates/engine/src/retouch_cmds/remove.rs). MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import CoreGraphics
import EraseKit
import PCDocument
import PCFoundation
import PCHistory

/// Content-Aware Fill options: the window and output here; photocraft's colour/rotation
/// adaptation, scale, mirror, seed and source area go to the inpaint provider as `inpaint` (PCAlgo's
/// PatchMatch through PCEngine honours them; a Kit fill or a model ignores them).
public struct ContentAwareFillOptions: Sendable, Equatable {
    /// Where the fill samples from.
    public enum Sampling: Sendable, Equatable {
        /// Photoshop's window around the selection.
        case auto
        /// A rectangle `margin` pixels around the selection (nil = Photoshop's window).
        case rectangular(margin: Int?)
        /// An explicit area (unioned with the selection, plus 4 px).
        case custom(PixelRect)
    }

    public var sampling: Sampling
    public var output: FillOutput
    /// The quality an injected inpaint provider runs (MI-GAN fast / LaMa best).
    public var quality: InpaintQuality
    /// Passed to an `OptionsInpaintProvider` (the window-relative source area and adaptation).
    public var inpaint: InpaintOptions

    public init(sampling: Sampling = .auto, output: FillOutput = .current, quality: InpaintQuality = .best,
                inpaint: InpaintOptions = InpaintOptions()) {
        self.sampling = sampling; self.output = output; self.quality = quality; self.inpaint = inpaint
    }
}

extension ContentAwareFillOptions.Sampling {
    /// The area a fill of a selection whose bounds are `hole` samples from on `canvas`.
    public func window(hole: PixelRect, canvas: PixelRect) -> PixelRect {
        switch self {
        case .auto, .rectangular(nil): PCIntelligence.samplingWindow(hole: hole, canvas: canvas)
        case .rectangular(let m?): hole.outset(by: Int32(clamping: min(max(m, 0), 100_000))).intersect(canvas)
        case .custom(let r): r.union(hole).outset(by: 4).intersect(canvas)
        }
    }
}

/// Remove tool options.
public struct RemoveOptions: Sendable, Equatable {
    /// The fill goes to a new layer above the target, which stays as it was.
    public var newLayer: Bool
    /// How far the hole grows beyond the stroke, in pixels (photocraft `GROW`).
    public var grow: Int
    public var quality: InpaintQuality

    public init(newLayer: Bool = false, grow: Int = 2, quality: InpaintQuality = .best) {
        self.newLayer = newLayer; self.grow = grow; self.quality = quality
    }
}

extension PCIntelligence {

    /// Photoshop's Content-Aware sampling window for a hole with bounding box `hole`: the square of
    /// side 4·√(max(w, 50)·max(h, 50)) centred on it, slid inside `canvas` (clipped only where the
    /// canvas is smaller). Mirrors photocraft-algo `content_aware::sampling_window` so a Kit fill
    /// sees the same surroundings PatchMatch does.
    public static func samplingWindow(hole: PixelRect, canvas: PixelRect) -> PixelRect {
        let hole = hole.intersect(canvas)
        if hole.isEmpty || canvas.isEmpty { return .empty }
        let w = Double(max(hole.width, 50)), h = Double(max(hole.height, 50))
        let side = Int64(min((4 * (w * h).squareRoot()).rounded(), Double(Int32.max)))
        func span(_ c2: Int64, _ extent: Int, _ lo: Int32, _ hi: Int32) -> (Int32, Int32) {
            let lo = Int64(lo), hi = Int64(hi)
            let side = max(side, Int64(extent))
            if side >= hi - lo { return (Int32(lo), Int32(hi)) }
            let a = min(max((c2 - side) / 2, lo), hi - side)
            return (Int32(a), Int32(a + side))
        }
        let (x0, x1) = span(Int64(hole.x0) + Int64(hole.x1), hole.width, canvas.x0, canvas.x1)
        let (y0, y1) = span(Int64(hole.y0) + Int64(hole.y1), hole.height, canvas.y0, canvas.y1)
        return PixelRect(x0: x0, y0: y0, x1: x1, y1: y1)
    }

    // MARK: Content-Aware Fill

    /// Edit ▸ Content-Aware Fill: fills the selected pixels of a pixel layer from their surroundings
    /// and blends the fill in by the selection's coverage. Needs a selection on the canvas.
    public func contentAwareFill(_ doc: Document, layer id: LayerId, options: ContentAwareFillOptions = .init(),
                                 progress: ProgressHandler? = nil) async throws -> PixelEditOutcome {
        let stage = Stage(handler: progress)
        let (layer, surface) = try editablePixelLayer(doc, id)
        guard let sel = doc.selection else { throw IntelligenceError.noSelection }
        let canvas = doc.bounds
        let hb = sel.contentBounds.intersect(canvas)
        guard !hb.isEmpty else { throw IntelligenceError.emptyMask("make a selection around what to remove") }
        let window = options.sampling.window(hole: hb, canvas: canvas)
        try stage.report(0.05, "Content-Aware Fill")
        let coverage = CoverageMask(surface: sel, rect: window)
        let (filled, receipt) = try await inpaintWindow(doc, source: surface, window: window, hole: coverage.binarized(),
                                                        engine: .inpaint(options.quality), dilation: 0, stage: stage, options: options.inpaint)
        try stage.report(0.9, "Applying")
        var notes = receipt.notes
        if case .auto = options.sampling { notes.append("auto sampling: the whole window (Kit fills take no source mask)") }
        let w = PixelWrite(rect: window, original: surface.readRegion(window), result: KitBridge.native(filled, format: surface.format),
                           coverage: coverage.values)
        let (tx, target, changed) = try PCIntelligence.commit(w, doc: doc, layer: layer, surface: surface,
                                                              target: PCIntelligence.target(options.output, newName: doc.nextLayerName("Content-Aware Fill")),
                                                              label: "Content-Aware Fill")
        try stage.report(1, "Done")
        var r = receipt
        r.notes = notes
        return PixelEditOutcome(layer: target, changedRect: changed, transaction: tx, receipt: r, stages: [r])
    }

    // MARK: Remove tool

    /// The Remove tool: fills `hole` (the stroke's coverage in document space, any Gray surface, e.g.
    /// rendered by PCPaint; a stroke that closes a loop should arrive with its inside filled, as
    /// PCAlgo's `close_loops` does) from its surroundings. The hole grows by `options.grow` pixels; the
    /// selection, when there is one, limits what changes. `source` samples another image (the
    /// composite, for Sample All Layers).
    public func remove(_ doc: Document, layer id: LayerId, hole: Surface, source: PixelSource? = nil,
                       options: RemoveOptions = .init(), progress: ProgressHandler? = nil) async throws -> PixelEditOutcome {
        let stage = Stage(handler: progress)
        let (layer, surface) = try editablePixelLayer(doc, id)
        let canvas = doc.bounds
        let grow = Int32(clamping: min(max(options.grow, 0), 64))
        let hb = hole.contentBounds.intersect(canvas)
        guard !hb.isEmpty else { throw IntelligenceError.emptyMask("the Remove stroke is empty") }
        // The sampling margin: three quarters of the hole's larger side, 32…512 px.
        let margin = Int32(min(max(max(hb.width, hb.height) * 3 / 4, 32), 512))
        let window = hb.outset(by: margin + grow).intersect(canvas)
        try stage.report(0.05, "Remove")
        let sourceSurface = try await pixels(source ?? .layer(id), in: doc, rect: window)
        let tight = CoverageMask(surface: hole, rect: window).binarized()
        let (filled, receipt) = try await inpaintWindow(doc, source: sourceSurface, window: window, hole: tight,
                                                        engine: .inpaint(options.quality), dilation: Int(grow), stage: stage)
        // What changes: the grown hole (as the Kit filled it), limited by the selection.
        var weight = Int(grow) > 0 ? try CoverageMask(image: MaskOps.dilate(tight.image(), radius: Int(grow)), rect: window).binarized(threshold: 0.5) : tight
        if let sel = selectionCoverage(doc, window) { weight = weight.multiplied(by: sel) }
        try stage.report(0.9, "Applying")
        let w = PixelWrite(rect: window, original: surface.readRegion(window), result: KitBridge.native(filled, format: surface.format),
                           coverage: weight.values)
        let target: EditTarget = options.newLayer ? .newLayer(name: doc.nextLayerName("Layer"), masked: false) : .current
        let (tx, targetId, changed) = try PCIntelligence.commit(w, doc: doc, layer: layer, surface: surface, target: target, label: "Remove")
        try stage.report(1, "Done")
        return PixelEditOutcome(layer: targetId, changedRect: changed, transaction: tx, receipt: receipt, stages: [receipt])
    }

    // MARK: Generative Fill

    /// Edit ▸ Generative Fill: generates the selected area from `prompt` onto a new "Generative Layer"
    /// above `layer`, masked by the selection. Runs the injected generative provider; while there is
    /// none, an injected inpaint model stands in (the prompt is ignored and the receipt says so);
    /// with neither it is unavailable. `source` defaults to the composite.
    public func generativeFill(_ doc: Document, above layer: LayerId?, prompt: String, source: PixelSource = .composite,
                               progress: ProgressHandler? = nil) async throws -> PixelEditOutcome {
        let stage = Stage(handler: progress)
        let status = registry.status(of: .generativeFill)
        guard status.isAvailable else { throw IntelligenceError.unavailable(.generativeFill, status.reason ?? "") }
        guard let sel = doc.selection else { throw IntelligenceError.noSelection }
        let canvas = doc.bounds
        let hb = sel.contentBounds.intersect(canvas)
        guard !hb.isEmpty else { throw IntelligenceError.emptyMask("make a selection to fill") }
        let window = PCIntelligence.samplingWindow(hole: hb, canvas: canvas)
        try stage.report(0.05, "Generative Fill")
        let sourceSurface = try await pixels(source, in: doc, rect: window)
        let coverage = CoverageMask(surface: sel, rect: window)
        let (filled, receipt) = try await inpaintWindow(doc, source: sourceSurface, window: window, hole: coverage.binarized(),
                                                        engine: .generative(prompt), dilation: 0, stage: stage)
        try stage.report(0.9, "Applying")
        // A new layer of the document's format holding the generated pixels, masked by the selection.
        let format = doc.pixelFormat
        let rgba = filled.map { SIMD4($0.x, $0.y, $0.z, 1) }
        let w = PixelWrite(rect: window, original: [Float](repeating: 0, count: window.area * format.channels),
                           result: KitBridge.native(rgba, format: format), coverage: coverage.values)
        let anchor = Layer.raster("anchor", format: format)
        let name = doc.nextLayerName("Generative Layer")
        var (tx, newId, changed) = try PCIntelligence.commit(w, doc: doc, layer: anchor, surface: Surface(format: format),
                                                              target: .newLayer(name: name, masked: true), label: "Generative Fill")
        // Place it above `layer` (or at the top).
        if case .insertLayer(let l, _)? = tx.ops.first {
            let placement: LayerPlacement = layer.flatMap { doc.contains($0) ? .above($0) : nil } ?? .top(of: nil)
            tx = EditTransaction("Generative Fill", [.insertLayer(l, placement)])
            newId = l.id
        }
        try stage.report(1, "Done")
        return PixelEditOutcome(layer: newId, changedRect: changed, transaction: tx, receipt: receipt, stages: [receipt])
    }

    // MARK: The shared fill

    enum FillEngine {
        case inpaint(InpaintQuality)
        case generative(String)
    }

    /// Fills `hole` (binary, over `window`) of `source`'s pixels and returns straight RGBA over the
    /// window in the bridge colour space: the Kit's colours inside the hole, the source elsewhere.
    /// Alpha inside the hole is filled classically from the surrounding alpha (the Kits fill colour
    /// only); an opaque window stays opaque. `options` reach an `OptionsInpaintProvider`.
    func inpaintWindow(_ doc: Document, source: Surface, window: PixelRect, hole: CoverageMask, engine: FillEngine,
                       dilation: Int, stage: Stage, options: InpaintOptions = InpaintOptions()) async throws -> ([SIMD4<Float>], TierReceipt) {
        guard !window.isEmpty, !hole.isEmpty else { throw IntelligenceError.emptyMask("nothing to fill") }
        let cs = KitBridge.colorSpace(for: doc)
        let sample = source.format.sample
        let rgba = source.readRGBA(window)
        let (w, h) = (window.width, window.height)
        let image = try KitBridge.image(fromRGBA: rgba, width: w, height: h, sample: sample, colorSpace: cs, alpha: .opaque)
        let maskImage = try hole.image()
        try stage.report(0.1, "Filling")
        let filledImage: CGImage
        var receipt: TierReceipt
        switch engine {
        case .inpaint(let quality):
            let injected = registry.provider(.inpaint, as: (any InpaintProvider).self)
            receipt = injected.map { TierReceipt(capability: .inpaint, tier: $0.tier, engine: $0.provider.engineName(for: quality)) }
                ?? TierReceipt(capability: .inpaint, tier: .classical, engine: BuiltIn.classicalInpaint)
            let provider = injected.map { bindingOptions($0.provider, options) }
            filledImage = try await run(.inpaint) {
                try await Eraser.erase(image, mask: maskImage, provider: provider, quality: quality, maskDilation: dilation)
            }
        case .generative(let prompt):
            if let gen = registry.provider(.generativeFill, as: (any GenerativeFillProvider).self) {
                receipt = TierReceipt(capability: .generativeFill, tier: gen.tier, engine: gen.name, notes: prompt.isEmpty ? ["empty prompt"] : [])
                filledImage = try await run(.generativeFill) { try await gen.provider.fill(image, mask: maskImage, prompt: prompt) }
            } else if let inpaint = registry.provider(.inpaint, as: (any InpaintProvider).self), inpaint.tier == .model {
                receipt = TierReceipt(capability: .generativeFill, tier: inpaint.tier, engine: inpaint.provider.engineName(for: .best),
                                      notes: ["inpaint stand-in: no generative provider registered, prompt ignored"])
                filledImage = try await run(.generativeFill) {
                    try await Eraser.erase(image, mask: maskImage, provider: inpaint.provider, quality: .best, maskDilation: dilation)
                }
            } else {
                throw IntelligenceError.unavailable(.generativeFill, registry.status(of: .generativeFill).reason ?? "")
            }
        }
        try Task.checkCancellation()
        var filled = try KitBridge.rgba(from: filledImage, colorSpace: cs, sample: sample, width: w, height: h)
        // Alpha: the source's outside the hole; inside, filled from the surrounding alpha when the window
        // has any transparency, else opaque.
        let transparent = source.format.alpha && rgba.contains { $0.w < 1 }
        var alphaFill: [Float]? = nil
        if transparent {
            let alphaImage = try KitBridge.maskImage(rgba.map { $0.w }, width: w, height: h)
            let grown = dilation > 0 ? MaskOps.dilate(maskImage, radius: dilation) : maskImage
            alphaFill = try KitBridge.coverage(from: ClassicalInpainter.fill(alphaImage, mask: grown), width: w, height: h)
            receipt.notes.append("alpha filled classically")
        }
        // Outside the (grown) hole the callers' blend weights are 0, so only the hole's values matter.
        for i in filled.indices { filled[i].w = alphaFill?[i] ?? 1 }
        return (filled, receipt)
    }
}
