// Port of photocraft architecture §6 (every mutation an op, a command's ops one labelled transaction) and photocraft-engine's `step_damage` (crates/engine/src/layer_multi_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Commands edit a copy of the document (photocraft's `Session::edit` closure); the engine then
// expresses the change as PCHistory `DocumentOp`s — tile patches for pixels, layer properties,
// masks, the selection, inserted or removed layers — and commits that transaction. Ops address
// layers by id, which is what lets a background job's edit rebase onto a newer document. Guides,
// paths, slices, notes and the canvas size go through `setDocumentProperties` (only the fields that
// changed), so they rebase too. A change the ops can't express (reordering, a mode or profile
// change, comps, metadata…) is committed as one `replaceDocument` op, which is exact but not
// rebaseable.
//
// The ops also give the step's damage: tile patches and layer bounds bound what the canvas must
// recomposite; a selection, a name or a guide changes no pixels.

import Foundation
import PCDocument
import PCFoundation
import PCHistory
import PCRender

public enum TransactionBuilder {
    /// The transaction turning `before` into `after`, labelled `label`. Applying it to `before`
    /// gives `after` exactly (checked; anything else falls back to `replaceDocument`).
    public static func transaction(_ label: String, from before: Document, to after: Document) -> EditTransaction {
        if let ops = ops(from: before, to: after) {
            var check = before
            if (try? EditTransaction(label, ops).apply(to: &check)) != nil, check == after {
                return EditTransaction(label, ops)
            }
        }
        return EditTransaction(label, [.replaceDocument(after)])
    }

    /// Fine-grained ops, or nil when only `replaceDocument` can express the change.
    static func ops(from a: Document, to b: Document) -> [DocumentOp]? {
        guard sameDocumentFields(a, b) else { return nil }
        var ops: [DocumentOp] = []
        // Extra channels: same list, only pixels changed.
        if a.channels.count != b.channels.count { return nil }
        for i in a.channels.indices where a.channels[i] != b.channels[i] {
            var x = a.channels[i], y = b.channels[i]
            if x.surface.format != y.surface.format { return nil }
            x.surface = y.surface
            guard x == y else { return nil }
            ops.append(.paintTiles(.channel(i), TilePatch.changes(from: a.channels[i].surface, to: b.channels[i].surface)))
        }
        switch (a.quickMask, b.quickMask) {
        case (nil, nil): break
        case (let x?, let y?) where x != y:
            var xx = x
            xx.surface = y.surface
            guard xx == y, x.surface.format == y.surface.format else { return nil }
            ops.append(.paintTiles(.quickMask, TilePatch.changes(from: x.surface, to: y.surface)))
        case (.some, .some): break
        default: return nil
        }
        if a.selection != b.selection { ops.append(.setSelection(b.selection)) }
        let props = DocumentProperties.changes(from: a, to: b)
        if !props.isEmpty { ops.append(.setDocumentProperties(props)) }
        guard let layerOps = layerOps(from: a, to: b) else { return nil }
        return layerOps + ops
    }

    /// Ops for the layer tree: removals, insertions, then per-layer changes.
    static func layerOps(from a: Document, to b: Document) -> [DocumentOp]? {
        if a.layers == b.layers { return [] }
        var ops: [DocumentOp] = []
        var work = a
        let aIds = Set(a.allLayerIds), bIds = Set(b.allLayerIds)
        if aIds.count != a.layerCount || bIds.count != b.layerCount { return nil }   // duplicate ids
        // Removed subtrees (their roots: layers whose parent survives).
        for id in a.allLayerIds where !bIds.contains(id) {
            if let p = a.parent(of: id), !bIds.contains(p) { continue }
            ops.append(.removeLayer(id))
            work.remove(id)
        }
        // Inserted subtrees, bottom to top in walk order so indices stay valid.
        var inserted: [(Layer, LayerPlacement)] = []
        for e in b.walk() where !aIds.contains(e.layer.id) {
            if let p = b.parent(of: e.layer.id), !aIds.contains(p) { continue }
            inserted.append((e.layer, .at(index: e.path.last ?? 0, in: b.parent(of: e.layer.id))))
        }
        // The surviving layers must keep their shape; reorders fall back to replaceDocument.
        var stripped = b
        for (l, _) in inserted { stripped.remove(l.id) }
        guard sameShape(work.layers, stripped.layers) else { return nil }
        for (l, place) in inserted {
            ops.append(.insertLayer(l, place))
            guard (try? work.insert(l, at: place)) != nil else { return nil }
        }
        guard sameShape(work.layers, b.layers) else { return nil }
        // Per-layer changes on the surviving layers.
        var changed: [DocumentOp] = []
        var skip = Set<LayerId>()
        for e in work.walk() {
            let id = e.layer.id
            if skip.contains(id) { continue }
            guard let y = b.layer(id) else { return nil }
            let x = e.layer
            if x == y { if x.isGroup { skip.formUnion(work.descendants(of: id)) }; continue }
            if x.isGroup {
                // Group node itself (properties, expanded, artboard) vs its children.
                var xs = x, ys = y
                xs.withChildren { $0 = [] }
                ys.withChildren { $0 = [] }
                if xs != ys {
                    if let o = nodeOps(xs, ys) { changed += o } else {
                        changed.append(.replaceLayer(y))
                        skip.formUnion(work.descendants(of: id))
                    }
                }
                continue
            }
            if aIds.contains(id) == false { continue }   // freshly inserted: already in its op
            guard let o = nodeOps(x, y) else {
                changed.append(.replaceLayer(y))
                continue
            }
            changed += o
        }
        return ops + changed
    }

    /// Ops turning one layer node into another with the same id (children ignored).
    static func nodeOps(_ x: Layer, _ y: Layer) -> [DocumentOp]? {
        var ops: [DocumentOp] = []
        var probe = x
        if x.content != y.content {
            guard case .raster(let sx) = x.content, case .raster(let sy) = y.content, sx.format == sy.format, sx.defaultPixelValue == sy.defaultPixelValue
            else { return nil }
            ops.append(.paintTiles(.layer(x.id), TilePatch.changes(from: sx, to: sy)))
            probe.content = y.content
        }
        if x.mask != y.mask {
            if let mx = x.mask, let my = y.mask, mx.surface.format == my.surface.format, mx.surface.defaultPixelValue == my.surface.defaultPixelValue,
               mx.enabled == my.enabled, mx.linked == my.linked, mx.density == my.density, mx.feather == my.feather {
                ops.append(.paintTiles(.layerMask(x.id), TilePatch.changes(from: mx.surface, to: my.surface)))
            } else {
                ops.append(.setLayerMask(x.id, y.mask))
            }
            probe.mask = y.mask
        }
        if x.properties != y.properties {
            ops.append(.setLayerProperties(x.id, y.properties))
            probe.properties = y.properties
        }
        // Anything else (PSD blocks, fill caches, video) is not an op: replace the node.
        return probe == y ? ops : nil
    }

    /// Same ids at the same places (children included).
    static func sameShape(_ a: [Layer], _ b: [Layer]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where !x.hasSameTreeShape(as: y) { return false }
        return true
    }

    /// Every document field except the layer tree, selection, channels, Quick Mask and the fields
    /// `setDocumentProperties` carries (size, guides, paths, slices, notes).
    static func sameDocumentFields(_ a: Document, _ b: Document) -> Bool {
        a.id == b.id && a.name == b.name && a.resolutionDpi == b.resolutionDpi && a.mode == b.mode && a.depth == b.depth
            && a.iccProfile == b.iccProfile && a.metadata == b.metadata && a.globalLight == b.globalLight
            && a.quickMaskUnselected == b.quickMaskUnselected && a.patterns == b.patterns && a.colorTable == b.colorTable
            && a.duotone == b.duotone && a.layerComps == b.layerComps && a.lastAppliedComp == b.lastAppliedComp
            && a.lastDocumentState == b.lastDocumentState && a.measurement == b.measurement
            && a.textStyles == b.textStyles && a.variables == b.variables && a.timeline == b.timeline
            && a.fileEncoding == b.fileEncoding
    }

    // MARK: Damage

    /// The pixels `t` (applied to `before`, giving `after`) can have changed: nil = unbounded
    /// (recomposite everything), `.empty` = no pixels (a selection, a name, a guide).
    public static func damage(_ t: EditTransaction, before: Document, after: Document, pixelExact: Bool = true) -> PixelRect? {
        if before.size != after.size || before.mode != after.mode || before.depth != after.depth { return nil }
        var out = PixelRect.empty
        func add(_ r: PixelRect?) -> Bool {
            guard let r else { return false }
            if !r.isEmpty { out = out.isEmpty ? r : out.union(r) }
            return true
        }
        func layerBounds(_ id: LayerId) -> Bool {
            for d in [before, after] {
                guard let l = d.layer(id) else { continue }
                if !add(LayerGeometry.changeBounds(l, canvas: d.bounds)) { return false }
            }
            return true
        }
        for op in t.ops {
            switch op {
            case .paintTiles(let ref, let patches):
                switch ref {
                case .layer(let id), .layerMask(let id):
                    guard let l = after.layer(id) else { return nil }
                    // Undo/redo (photocraft `step_damage`): a layer whose pixels differ damages its change bounds on both sides.
                    if !pixelExact || l.effects.hasVisibleEffects || l.mask.map({ $0.feather > 0 }) ?? false || l.clipped {
                        if !layerBounds(id) { return nil }
                    } else {
                        let surfaces: (Surface?, Surface?)
                        if case .layer = ref {
                            surfaces = (before.layer(id)?.rasterSurface, l.rasterSurface)
                        } else {
                            surfaces = (before.layer(id)?.mask?.surface, l.mask?.surface)
                        }
                        for p in patches { _ = add(changedRect(p.coord, surfaces.0, surfaces.1)) }
                    }
                case .channel, .quickMask, .selection: break
                }
            case .replaceSurface(let ref, _):
                switch ref {
                case .layer(let id), .layerMask(let id): if !layerBounds(id) { return nil }
                default: break
                }
            case .setSelection: break
            case .setLayerProperties(let id, let p):
                guard let old = before.layer(id) else { return nil }
                if old.clipped != p.clipped || old.excludedChannels != p.excludedChannels { return nil }
                var probe = old.properties
                probe.name = p.name
                probe.label = p.label
                probe.linkGroup = p.linkGroup
                if probe == p { continue }   // only pixel-free fields changed
                if !layerBounds(id) { return nil }
            case .setLayerMask(let id, _):
                if !layerBounds(id) { return nil }
            case .replaceLayer(let l):
                if !layerBounds(l.id) { return nil }
            case .insertLayer(let l, _):
                if !add(oneSidedDamage(after, l.id)) { return nil }
            case .removeLayer(let id):
                if !add(oneSidedDamage(before, id)) { return nil }
            case .moveLayer, .replaceDocument:
                return nil
            case .setDocumentProperties:
                // Guides, paths, slices and notes draw no pixels; a size change returned nil above.
                break
            }
        }
        return out
    }

    /// The pixels adding or removing layer `id` of `d` can change (photocraft `inert_at` +
    /// `one_sided_bounds`): `.empty` when it draws nothing wherever it sits, nil when unbounded —
    /// a new or lost clipping base of the clipped layers above it, or a video layer or excluded
    /// channels anywhere inside it.
    static func oneSidedDamage(_ d: Document, _ id: LayerId) -> PixelRect? {
        guard let sib = d.siblings(of: id), let k = sib.firstIndex(where: { $0.id == id }) else { return nil }
        let l = sib[k]
        let aboveClipped = k + 1 < sib.count && sib[k + 1].clipped
        let empty: Bool
        switch l.content {
        case .raster(let s): empty = s.tileCount == 0 && s.format.alpha && s.defaultPixel.allSatisfy { $0 == 0 }
        case .group(let g): empty = g.children.isEmpty && g.artboard == nil
        default: empty = false
        }
        if empty, l.blend == .normal || l.blend == .passThrough, l.mask == nil, l.vectorMask == nil, !l.effects.hasVisibleEffects,
           l.fillCache == nil, l.video == nil, l.advanced == AdvancedBlending(), l.clipped || !aboveClipped {
            return .empty
        }
        func contained(_ l: Layer, _ depth: Int) -> Bool {
            depth < 256 && l.video == nil && l.excludedChannels == 0 && (l.children ?? []).allSatisfy { contained($0, depth + 1) }
        }
        if (!l.clipped && aboveClipped) || !contained(l, 0) { return nil }
        return LayerGeometry.changeBounds(l, canvas: d.bounds)
    }

    /// The pixels of tile `c` that differ between two versions of a surface, compared row by row
    /// (a missing tile reads as its surface's default pixel). photocraft reports a stroke's own
    /// rectangle, also on undo; the tile patches alone would round it up to 256².
    static func changedRect(_ c: TileCoord, _ a: Surface?, _ b: Surface?) -> PixelRect {
        guard let a, let b, a.format == b.format else { return c.rect }
        let bpp = a.format.bytesPerPixel, ts = Int(tileSize), rowBytes = ts * bpp
        let ta = a.tile(c)?.bytes, tb = b.tile(c)?.bytes
        if ta == nil && tb == nil && a.defaultPixel == b.defaultPixel { return .empty }
        guard (ta?.count ?? rowBytes * ts) == rowBytes * ts, (tb?.count ?? rowBytes * ts) == rowBytes * ts else { return c.rect }
        let rowA = ta == nil ? Array([[UInt8]](repeating: a.defaultPixel, count: ts).joined()) : []
        let rowB = tb == nil ? Array([[UInt8]](repeating: b.defaultPixel, count: ts).joined()) : []
        guard rowA.isEmpty || rowA.count == rowBytes, rowB.isEmpty || rowB.count == rowBytes else { return c.rect }
        var (x0, x1, y0, y1) = (ts, 0, ts, 0)
        func scan(_ pa: UnsafeRawBufferPointer, _ pb: UnsafeRawBufferPointer, strideA: Int, strideB: Int) {
            for y in 0..<ts {
                let ra = pa.baseAddress! + y * strideA, rb = pb.baseAddress! + y * strideB
                if memcmp(ra, rb, rowBytes) == 0 { continue }
                y0 = min(y0, y); y1 = y + 1
                var l = 0
                while l < ts, memcmp(ra + l * bpp, rb + l * bpp, bpp) == 0 { l += 1 }
                var r = ts
                while r > l, memcmp(ra + (r - 1) * bpp, rb + (r - 1) * bpp, bpp) == 0 { r -= 1 }
                x0 = min(x0, l); x1 = max(x1, r)
            }
        }
        (ta ?? rowA).withUnsafeBytes { pa in
            (tb ?? rowB).withUnsafeBytes { pb in
                scan(pa, pb, strideA: ta == nil ? 0 : rowBytes, strideB: tb == nil ? 0 : rowBytes)
            }
        }
        if y1 == 0 { return .empty }
        let o = c.rect
        // Saturating, like the tile's own rect at the end of the coordinate range.
        return PixelRect(x0: Int32(clamping: Int(o.x0) + x0), y0: Int32(clamping: Int(o.y0) + y0),
                         x1: Int32(clamping: Int(o.x0) + x1), y1: Int32(clamping: Int(o.y0) + y1))
    }
}
