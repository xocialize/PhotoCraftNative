// The AI tier's service object: Photoshop-named async operations (Select Subject, Object
// Selection, Remove Background, Remove, Content-Aware Fill, Generative Fill, Neural Filters, Super
// Resolution, Auto White Balance, SDR → HDR) over the provider registry. Operations read a document
// snapshot and return data — a selection, a layer mask, pixels, a new document — plus the
// `EditTransaction` that applies it, so the engine commits one undoable step (photocraft's job model:
// crates/engine/src/jobs.rs, a background job against a snapshot that applies in one step). They
// support cancellation (Swift task cancellation, checked between stages) and report progress and the
// tier that ran. Fills the gap photocraft's planned `ml` crate left (docs/architecture.md §2, gap
// G15); MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import PCDocument
import PCFoundation
import PCHistory

/// Renders the visible composite of `rect` of a document (PCRender's job). PCIntelligence never
/// composites; a host or the engine injects this for the "Sample All Layers" sources.
public typealias Compositor = @Sendable (Document, PixelRect) async throws -> Surface

/// Which pixels an operation analyses or fills from.
public enum PixelSource: Sendable, Equatable {
    /// A layer's pixels: a pixel layer's surface, or the rendered cache of a type, shape or smart
    /// object layer (photocraft `Layer::surface`).
    case layer(LayerId)
    /// The visible composite ("Sample All Layers"), through the injected `Compositor`. Without one,
    /// a document whose only visible layer is a plain pixel layer uses that layer.
    case composite
    /// Pixels the caller already has in document space (e.g. a composite it rendered).
    case surface(Surface)
}

/// The AI tier. Thread-safe and `Sendable`: share one per app.
public final class PCIntelligence: Sendable {
    /// The injection seam: one slot per capability.
    public let registry: ProviderRegistry
    /// Renders composites for `PixelSource.composite`.
    public let compositor: Compositor?

    public init(registry: ProviderRegistry = ProviderRegistry(), compositor: Compositor? = nil) {
        self.registry = registry
        self.compositor = compositor
    }

    /// Whether `capability` can run now, and on what.
    public func status(of capability: Capability) -> CapabilityStatus { registry.status(of: capability) }

    // MARK: Shared plumbing

    /// The pixels of `source` covering `rect`.
    func pixels(_ source: PixelSource, in doc: Document, rect: PixelRect) async throws -> Surface {
        switch source {
        case .surface(let s):
            return s
        case .layer(let id):
            guard let l = doc.layer(id) else { throw IntelligenceError.noLayer(id.rawValue) }
            guard let s = l.surface else {
                throw IntelligenceError.refused("the layer \"\(l.name)\" is \(l.content.article) \(l.content.kindName) layer without pixels")
            }
            return s
        case .composite:
            if let compositor { return try await compositor(doc, rect) }
            if let only = PCIntelligence.soleVisiblePixelLayer(doc), let s = only.surface { return s }
            throw IntelligenceError.compositeUnavailable(
                "sampling all layers needs a compositor for this document (several visible layers); pass PCIntelligence(compositor:) or a .surface source")
        }
    }

    /// The document's only visible layer when it is a plain pixel layer whose pixels are the composite
    /// (normal blending, full opacity, no mask, no visible effects, not clipped).
    static func soleVisiblePixelLayer(_ doc: Document) -> Layer? {
        var visible: [Layer] = []
        func walk(_ ls: [Layer]) {
            for l in ls where l.visible {
                if let ch = l.children { walk(ch) } else { visible.append(l) }
            }
        }
        walk(doc.layers)
        guard visible.count == 1, let l = visible.first, case .raster = l.content,
              l.opacity >= 1, l.fillOpacity >= 1, l.blend == .normal, l.mask == nil, l.vectorMask == nil,
              !l.clipped, !l.effects.hasVisibleEffects else { return nil }
        if let p = doc.path(of: l.id), p.count > 1 {
            for n in 1..<p.count {
                guard let g = doc.layer(at: Array(p.prefix(n))), g.opacity >= 1, g.mask == nil, g.vectorMask == nil,
                      g.blend == .passThrough || g.blend == .normal else { return nil }
            }
        }
        return l
    }

    /// The pixel layer `id` and its surface, refused with Photoshop's message when it is not a pixel
    /// layer or its pixels are locked (photocraft `check_pixels_unlocked`).
    func editablePixelLayer(_ doc: Document, _ id: LayerId) throws -> (Layer, Surface) {
        guard let l = doc.layer(id) else { throw IntelligenceError.noLayer(id.rawValue) }
        guard case .raster(let s) = l.content else {
            throw IntelligenceError.refused("the layer \"\(l.name)\" is \(l.content.article) \(l.content.kindName) layer, not a pixel layer")
        }
        let locks = doc.effectiveLocks(id)
        if locks.pixels || locks.all {
            throw IntelligenceError.refused("Could not complete your request because the layer \"\(l.name)\" is locked")
        }
        return (l, s)
    }

    /// The layer `id` for a command that only writes its mask: a pixel layer or a smart object (which stays one;
    /// its rendered placement is what's read), refused with Photoshop's message when its pixels are locked.
    func maskableLayer(_ doc: Document, _ id: LayerId) throws -> Layer {
        guard let l = doc.layer(id) else { throw IntelligenceError.noLayer(id.rawValue) }
        switch l.content {
        case .raster, .smart: break
        default: throw IntelligenceError.refused("the layer \"\(l.name)\" is \(l.content.article) \(l.content.kindName) layer, not a pixel layer or a smart object")
        }
        let locks = doc.effectiveLocks(id)
        if locks.pixels || locks.all {
            throw IntelligenceError.refused("Could not complete your request because the layer \"\(l.name)\" is locked")
        }
        return l
    }

    /// The selection's coverage over `rect`, or nil without a selection.
    func selectionCoverage(_ doc: Document, _ rect: PixelRect) -> CoverageMask? {
        doc.selection.map { CoverageMask(surface: $0, rect: rect) }
    }

    /// Progress reporting and cancellation between stages.
    struct Stage {
        let handler: ProgressHandler?
        func report(_ fraction: Double, _ stage: String) throws {
            try Task.checkCancellation()
            handler?(IntelligenceProgress(fraction: fraction, stage: stage))
        }
    }

    /// Runs a Kit or provider call, mapping its failure (other than cancellation and our own errors)
    /// to `providerFailed`.
    func run<T>(_ capability: Capability, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let e as IntelligenceError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as KitBridgeError {
            throw IntelligenceError.bridge(e.message)
        } catch {
            throw IntelligenceError.providerFailed(capability, String(describing: error))
        }
    }
}

// MARK: - Outcomes

/// A selection operation's result.
public struct SelectionOutcome: Sendable {
    /// The document's selection after the operation (the found region combined by the mode); the
    /// current selection when nothing was found.
    public var selection: Surface?
    /// Whether the selection changed. Finding nothing never destroys work: the selection is left
    /// alone and `transaction` is nil (photocraft `smartselect_cmds::apply`).
    public var changed: Bool
    /// Bounds of the found region (empty when nothing was found).
    public var bounds: PixelRect
    /// The found region before combining.
    public var found: CoverageMask?
    /// `setSelection`, labelled for History; nil when nothing changed.
    public var transaction: EditTransaction?
    public var receipt: TierReceipt
}

/// Remove Background's result: the layer mask and the transaction that adds it.
public struct LayerMaskOutcome: Sendable {
    public var layer: LayerId
    public var mask: LayerMask
    /// Bounds of the subject.
    public var bounds: PixelRect
    /// Replaces the layer (Background → "Layer 0", unlocked) with the mask added, and deselects.
    public var transaction: EditTransaction
    public var receipt: TierReceipt
}

/// A pixel edit's result (fills, neural filters, white balance).
public struct PixelEditOutcome: Sendable {
    /// The layer holding the result: the target, or the new / duplicated layer.
    public var layer: LayerId
    /// Where pixels changed, in document space.
    public var changedRect: PixelRect
    /// `paintTiles` on the target, or `insertLayer` above it.
    public var transaction: EditTransaction
    /// The receipt of the main stage.
    public var receipt: TierReceipt
    /// Every stage's receipt, in order (Photo Restoration runs several).
    public var stages: [TierReceipt]
}

/// An operation that produces a new document (Super Resolution, SDR → HDR).
public struct DocumentOutcome: Sendable {
    public var document: Document
    public var receipt: TierReceipt
}

/// Pixels upscaled by a provider (the Preserve Details 2.0 primitive).
public struct UpscaleOutcome: Sendable {
    /// The upscaled pixels, with the source rect's top-left mapped to (x0·f, y0·f).
    public var surface: Surface
    /// The upscaled region.
    public var rect: PixelRect
    /// The integer factor the provider applied.
    public var appliedFactor: Int
    public var receipt: TierReceipt
}
