// Turning computed pixels into an undoable edit: blend by coverage into the target layer (only the
// covered pixels change, at the layer's own depth), or put them on a new or duplicated layer.
// Output semantics after photocraft-engine's Content-Aware Fill apply step
// (crates/engine/src/edit_menu_cmds.rs `apply_content_aware_fill`: current | new | duplicate, the
// fill blended in by the selection's coverage, a new layer carrying alpha × coverage) and Photoshop's
// Neural Filters output menu. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCDocument
import PCFoundation
import PCHistory

/// Where a fill goes (photocraft Content-Aware Fill `output`).
public enum FillOutput: String, Sendable, Codable, CaseIterable {
    /// Into the target layer.
    case current
    /// Onto a new layer above it, only where filled (alpha × coverage).
    case new
    /// Into a duplicate of the target, above it.
    case duplicate
}

/// Where a neural filter's result goes (Photoshop's Neural Filters output menu, the layer subset).
public enum FilterOutput: String, Sendable, Codable, CaseIterable {
    /// Into the target layer.
    case currentLayer
    /// Onto a new layer above it, only where filtered (alpha × coverage).
    case newLayer
    /// Onto a new layer above it with the selection as its layer mask.
    case newLayerMasked
}

/// Computed pixels for `rect`, in the target layer's native format.
struct PixelWrite {
    var rect: PixelRect
    /// The layer's pixels over `rect` (native interleaved samples).
    var original: [Float]
    /// The result over `rect` (native interleaved samples).
    var result: [Float]
    /// Blend weight per pixel over `rect`; nil = 1 everywhere.
    var coverage: [Float]?

    /// Bounds of the pixels with weight > 0.
    var changedRect: PixelRect {
        guard let c = coverage else { return rect }
        return CoverageMask(rect: rect, values: c).bounds
    }
}

enum EditTarget {
    case current
    case newLayer(name: String, masked: Bool)
    case duplicate
}

extension PCIntelligence {

    /// The edit that writes `w` for layer `layer` (whose surface is `surface`) per `target`.
    static func commit(_ w: PixelWrite, doc: Document, layer: Layer, surface: Surface, target: EditTarget,
                       label: String) throws -> (EditTransaction, LayerId, PixelRect) {
        let format = surface.format
        let ch = format.channels
        let changed = w.changedRect
        guard !changed.isEmpty else { throw IntelligenceError.emptyMask("nothing to change: the mask is empty") }

        /// Blended native samples over `r` (a sub-rect of `w.rect`).
        func blended(_ r: PixelRect) -> [Float] {
            var out = [Float](repeating: 0, count: r.area * ch)
            for y in r.y0..<r.y1 {
                for x in r.x0..<r.x1 {
                    let i = Int(y - w.rect.y0) * w.rect.width + Int(x - w.rect.x0)
                    let o = (Int(y - r.y0) * r.width + Int(x - r.x0)) * ch
                    let c = w.coverage?[i] ?? 1
                    for k in 0..<ch {
                        let a = w.original[i * ch + k], b = w.result[i * ch + k]
                        out[o + k] = c >= 1 ? b : a + (b - a) * c
                    }
                }
            }
            return out
        }

        switch target {
        case .current:
            var edited = surface
            edited.writeRegion(changed, blended(changed))
            let patches = TilePatch.changes(from: surface, to: edited)
            return (EditTransaction(label, [.paintTiles(.layer(layer.id), patches)]), layer.id, changed)

        case .duplicate:
            var dup = layer.duplicate()
            dup.name = doc.copyName(layer.name)
            dup.withRaster { $0.writeRegion(changed, blended(changed)) }
            return (EditTransaction(label, [.insertLayer(dup, .above(layer.id))]), dup.id, changed)

        case .newLayer(let name, let masked):
            let lf = format.with(alpha: true)
            var s = Surface(format: lf)
            let lch = lf.channels
            var px = [Float](repeating: 0, count: changed.area * lch)
            for y in changed.y0..<changed.y1 {
                for x in changed.x0..<changed.x1 {
                    let i = Int(y - w.rect.y0) * w.rect.width + Int(x - w.rect.x0)
                    let o = (Int(y - changed.y0) * changed.width + Int(x - changed.x0)) * lch
                    let c = masked ? 1 : (w.coverage?[i] ?? 1)
                    guard c > 0 else { continue }
                    let cc = lf.mode.colorChannels
                    for k in 0..<cc { px[o + k] = w.result[i * ch + k] }
                    let alpha: Float = format.alpha ? w.result[i * ch + cc] : 1
                    px[o + cc] = alpha * c
                }
            }
            s.writeRegion(changed, px)
            s.prune()
            var l = Layer.raster(name, surface: s)
            if masked, let cov = w.coverage {
                let m = CoverageMask(rect: w.rect, values: cov).cropped(to: changed)
                l.mask = m.surface(sample: .u8).map { LayerMask(surface: $0) } ?? LayerMask.hideAll()
            }
            return (EditTransaction(label, [.insertLayer(l, .above(layer.id))]), l.id, changed)
        }
    }

    /// The target for a fill output.
    static func target(_ o: FillOutput, newName: String) -> EditTarget {
        switch o {
        case .current: .current
        case .new: .newLayer(name: newName, masked: false)
        case .duplicate: .duplicate
        }
    }

    /// The target for a filter output.
    static func target(_ o: FilterOutput, newName: String) -> EditTarget {
        switch o {
        case .currentLayer: .current
        case .newLayer: .newLayer(name: newName, masked: false)
        case .newLayerMasked: .newLayer(name: newName, masked: true)
        }
    }
}
