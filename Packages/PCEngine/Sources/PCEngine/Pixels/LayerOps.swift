// Port of photocraft-engine helpers shared by many commands: commands.rs (`translate_layer`, `layer_copy`, `selection_mask`, `mask_at_depth`, `paint_surface`, `check_pixels_unlocked`), background_cmds.rs (`background_id`, `keep_background_at_bottom`), extra_cmds.rs (`background_to_layer`), vector_cmds.rs (`translate_vectors`), artboard_cmds.rs (`place_copy`, `fit_canvas`) and image_cmds.rs (`translate_doc`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCRender

public enum LayerOps {
    // MARK: Locks and targets

    /// Refuses a layer whose pixels are locked (directly or through a group), with Photoshop's
    /// message.
    public static func checkPixelsUnlocked(_ doc: Document, _ id: LayerId) throws {
        guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
        let locks = doc.effectiveLocks(id)
        if locks.pixels || locks.all { throw EngineError.other("Could not complete your request because the layer \"\(l.name)\" is locked") }
    }

    public static func checkAllUnlocked(_ doc: Document, _ id: LayerId) throws {
        guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
        if doc.effectiveLocks(id).all { throw EngineError.other("Could not complete your request because the layer \"\(l.name)\" is locked") }
    }

    /// `"target":"mask"` in params.
    public static func isMaskTarget(_ p: JSONValue) -> Bool { p["target"]?.stringValue == "mask" }

    /// Mutates the surface a paint command writes to: the layer's pixels, or its mask with
    /// `"target":"mask"` (photocraft `paint_surface`).
    @discardableResult
    public static func withPaintSurface<R>(_ doc: inout Document, _ id: LayerId, _ p: JSONValue, _ body: (inout Surface) throws -> R) throws -> R {
        if isMaskTarget(p) { try checkAllUnlocked(doc, id) } else { try checkPixelsUnlocked(doc, id) }
        guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
        if isMaskTarget(p) {
            var result: R?
            var failure: (any Error)?
            doc.updateLayer(id) { l in
                guard var m = l.mask else { failure = EngineError.other("layer has no mask"); return }
                l.mask = nil
                do { result = try body(&m.surface) } catch { failure = error }
                l.mask = m
            }
            if let failure { throw failure }
            return result!
        }
        var result: R?
        var failure: (any Error)?
        let done: Void? = doc.withRaster(of: id) { s in
            do { result = try body(&s) } catch { failure = error }
        }
        if let failure { throw failure }
        guard done != nil, let result else { throw EngineError.other("not a pixel layer") }
        return result
    }

    // MARK: Masks

    /// New pixel masks use the document's depth (photocraft `mask_at_depth`).
    public static func maskAtDepth(_ mask: LayerMask, _ depth: SampleType) -> LayerMask {
        var m = mask
        let f = m.surface.format.with(sample: depth)
        if m.surface.format != f { m.surface = m.surface.convertedAny(to: f) }
        return m
    }

    /// The active selection as the mask of a layer being created (photocraft `selection_mask`).
    public static func selectionMask(_ doc: Document) -> LayerMask? {
        guard let sel = doc.selection else { return nil }
        var m = LayerMask.revealAll()
        m.surface = sel
        return maskAtDepth(m, doc.depth)
    }

    // MARK: Background

    public static func backgroundId(_ doc: Document) -> LayerId? { doc.background?.id }

    /// Refuses an edit that moved the Background off the bottom or put a layer below it.
    public static func keepBackgroundAtBottom(_ bg: LayerId?, _ doc: Document) throws {
        if let bg, doc.layers.first?.id != bg {
            throw EngineError.other("the Background layer stays at the bottom of the stack (Layer › New › Layer from Background makes it a normal layer)")
        }
    }

    /// Turns the Background into a normal layer ("Layer 0"), as Photoshop does before an edit the
    /// Background can't take (photocraft `background_to_layer`).
    public static func backgroundToLayer(_ doc: inout Document, _ id: LayerId) {
        guard doc.isBackground(id) else { return }
        doc.updateBackground { unlockBackground(&$0) }
    }

    /// photocraft `unlock_background`.
    public static func unlockBackground(_ l: inout Layer) {
        l.name = "Layer 0"
        l.locks.transparency = false
        l.locks.position = false
    }

    // MARK: Copies and moves

    /// A copy of layer `id` as Duplicate Layer makes it (fresh ids, "… copy"; a Background copy is
    /// an ordinary, unlocked layer).
    public static func layerCopy(_ doc: Document, _ id: LayerId) throws -> Layer {
        guard let src = doc.layer(id) else { throw EngineError.noLayer(id) }
        var dup = src.duplicate()
        dup.name = doc.copyName(dup.name)
        if doc.isBackground(id) { dup.locks = Locks() }
        return dup
    }

    /// Moves a layer's pixels, linked mask, type and vectors by whole pixels (photocraft
    /// `translate_layer` + `vector_cmds::translate_vectors`).
    public static func translateLayer(_ doc: Document, _ l: inout Layer, _ dx: Int32, _ dy: Int32) {
        let a = PCAffine.translate(Double(dx), Double(dy))
        if let r = l.effects.reference { l.effects.reference = r + SIMD2(Double(dx), Double(dy)) }
        if var m = l.mask, m.linked { m.surface = m.surface.shifted(dx: dx, dy: dy); l.mask = m }
        if var vm = l.vectorMask, vm.linked { vm.path = vm.path.transform(a); l.vectorMask = vm }
        switch l.content {
        case .raster: l.withRaster { $0 = $0.shifted(dx: dx, dy: dy) }
        case .text:
            l.withText { t in
                t.transform = a.mul(t.transform)
                if let c = t.cache { t.cache = c.shifted(dx: dx, dy: dy) }
                t.psdRaw = nil
            }
        case .shape:
            let canvas = doc.bounds
            l.withShape { sh in
                let inside = sh.cache.map { c in
                    let b = c.contentBounds
                    return b.isEmpty || (b.x0 > canvas.x0 && b.y0 > canvas.y0 && b.x1 < canvas.x1 && b.y1 < canvas.y1)
                } ?? false
                CanvasGeometry.transformShape(&sh, a)
                if inside, let c = sh.cache { sh.cache = c.shifted(dx: dx, dy: dy) } else if sh.cache != nil { sh.cache = nil }
            }
        case .smart:
            l.withSmartObject { sm in
                CanvasGeometry.transformPlacement(&sm, a)
                if let c = sm.cache { sm.cache = c.shifted(dx: dx, dy: dy) }
                if var m = sm.filterMask { m.surface = m.surface.shifted(dx: dx, dy: dy); sm.filterMask = m }
            }
        case .group:
            l.withGroup { g in
                if var ab = g.artboard { ab.rect = ab.rect.offsetBy(dx: dx, dy: dy); g.artboard = ab }
                for i in g.children.indices { translateLayer(doc, &g.children[i], dx, dy) }
            }
        case .adjustment, .fill:
            break
        }
    }

    // MARK: Artboards

    /// Gap between an artboard and its copy placed beside it.
    public static let artboardGap: Int32 = 100

    /// Every artboard: (id, name, artboard), in walk order.
    public static func artboards(_ doc: Document) -> [(LayerId, String, Artboard)] {
        doc.layers.compactMap { l in l.artboard.map { (l.id, l.name, $0) } }
    }

    /// A duplicated artboard goes beside its original (photocraft `place_copy`).
    public static func placeCopy(_ doc: inout Document, _ id: LayerId) throws {
        guard let l = doc.layer(id), let r = l.artboard?.rect else { return }
        let boards = artboards(doc).filter { $0.0 != id }.map(\.2.rect)
        let (y0, y1, w) = (Int64(r.y0), Int64(r.y1), Int64(r.width))
        var x = Int64(r.x1) + Int64(artboardGap)
        for _ in 0...boards.count {
            let blocked = boards.filter { Int64($0.x0) < x + w && Int64($0.x1) > x && Int64($0.y0) < y1 && Int64($0.y1) > y0 }.map { Int64($0.x1) }.max()
            guard let edge = blocked else { break }
            x = edge + Int64(artboardGap)
        }
        guard x + w <= Int64(Int32.max), let dx = Int32(exactly: x - Int64(r.x0)) else {
            throw EngineError.other("no room for a copy of artboard \"\(l.name)\" right of it; duplicate it in place (\"inPlace\": true) and move it")
        }
        doc.size = PixelSize(width: Int(min(max(Int64(doc.size.width), x + w), 300_000)), height: doc.size.height)
        let snapshot = doc
        doc.updateLayer(id) { translateLayer(snapshot, &$0, dx, 0) }
        fitCanvas(&doc)
    }

    /// Grows the canvas to hold every artboard (photocraft `fit_canvas`).
    public static func fitCanvas(_ doc: inout Document) { ArtboardCommands.fitCanvas(&doc) }

    // MARK: Structure

    /// Refuses a document nested deeper than the model allows.
    public static func checkGroupDepth(_ doc: Document, _ what: String) throws {
        if doc.maxGroupDepth > maxGroupDepthLimit {
            throw EngineError.other("\(what) would nest layers deeper than \(maxGroupDepthLimit) groups")
        }
    }

    /// `doc.insert` refusing a placement nested too deep with photocraft's `check_group_depth`
    /// message (photocraft splices first and checks after; PCDocument checks while inserting).
    public static func insert(_ doc: inout Document, _ layer: Layer, at place: LayerPlacement, what: String) throws {
        do { try doc.insert(layer, at: place) } catch {
            if "\(error)".contains("groups deep") { throw EngineError.other("\(what) would nest layers deeper than \(maxGroupDepthLimit) groups") }
            throw EngineError.wrap(error)
        }
    }

    /// Content bounds used by Align/Distribute (photocraft `layer_bounds`).
    public static func layerBounds(_ l: Layer) -> PixelRect? {
        let r: PixelRect
        if let ch = l.children {
            r = ch.compactMap(layerBounds).reduce(PixelRect.empty) { $0.isEmpty ? $1 : $0.union($1) }
        } else {
            r = l.surface?.contentBounds ?? .empty
        }
        return r.isEmpty ? nil : r
    }

    /// Ids in `ids` with no ancestor also in `ids`, bottom-to-top (photocraft `top_level`).
    public static func topLevel(_ doc: Document, _ ids: [LayerId]) -> [LayerId] {
        let want = Set(ids)
        var out: [LayerId] = []
        doc.forEachLayer { _, _, l in
            if want.contains(l.id) && !doc.ancestors(of: l.id).contains(where: { want.contains($0) }) { out.append(l.id) }
        }
        return out
    }
}
