// Port of photocraft-engine (crates/engine/src/clip_group.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Clip groups follow layers as they are added, moved and deleted, as in Photoshop (#2203). A
// clipped layer clips to the nearest unclipped layer below it (its base); a base and the run of
// clipped layers directly above it form a clip group. Rules (Photoshop 27.11):
//
// 1. A layer added or moved joins the clip group it lands in: it is clipped when the layer directly
//    above its new slot is clipped (unless that layer travels with it in its own group).
// 2. A clipped layer moved stays clipped while it still sits on a clip group.
// 3. When a base is moved away or deleted, the layers clipped to it are released.
// 4. A clipped layer with nothing below it to clip to is released.

import PCDocument

public enum ClipGroup {
    /// The sibling list holding the layer at `path`, and its index.
    static func siblings(_ doc: Document, _ path: LayerPath) -> ([Layer], Int)? {
        guard let idx = path.last else { return nil }
        let parent = Array(path.dropLast())
        let list = parent.isEmpty ? doc.layers : (doc.layer(at: parent)?.children ?? [])
        return (list, idx)
    }

    /// The layer `delta` slots above (+) or below (−) `id` among its siblings.
    static func neighbour(_ doc: Document, _ id: LayerId, _ delta: Int) -> Layer? {
        guard let path = doc.path(of: id), let (list, idx) = siblings(doc, path) else { return nil }
        let j = idx + delta
        return j >= 0 && j < list.count ? list[j] : nil
    }

    /// The clip group `id` belongs to, base first (empty when it has none).
    public static func groupOf(_ doc: Document, _ id: LayerId) -> [LayerId] {
        guard let path = doc.path(of: id), let (list, idx) = siblings(doc, path) else { return [] }
        guard let base = list.prefix(idx + 1).lastIndex(where: { !$0.clipped }) else { return [] }
        var group: [LayerId] = []
        for (i, l) in list[base...].enumerated() {
            if i > 0 && !l.clipped { break }
            group.append(l.id)
        }
        return group.count > 1 ? group : []
    }

    /// The layers clipped to `id` (the clipped run directly above it).
    public static func clippedTo(_ doc: Document, _ id: LayerId) -> [LayerId] {
        let g = groupOf(doc, id)
        guard let first = g.first, first == id else { return [] }
        return Array(g.dropFirst())
    }

    /// The clipped run directly above `id`, whether `id` is the base or clipped itself: what Release
    /// Clipping Mask takes out with it.
    public static func clippedAbove(_ doc: Document, _ id: LayerId) -> [LayerId] {
        guard let path = doc.path(of: id), let (list, idx) = siblings(doc, path) else { return [] }
        return list[(idx + 1)...].prefix { $0.clipped }.map(\.id)
    }

    /// The clip groups of layers about to move or be deleted, read before they leave their slots.
    public struct Before: Sendable {
        var moving: [LayerId] = []
        var clipped: [LayerId] = []
        var groups: [(LayerId, [LayerId])] = []
        var left: [LayerId] = []

        public init() {}

        public static func read(_ doc: Document, _ moving: [LayerId]) -> Before {
            var b = Before()
            b.moving = moving
            b.clipped = moving.filter { doc.layer($0)?.clipped == true }
            b.groups = moving.map { ($0, groupOf(doc, $0)) }.filter { !$0.1.isEmpty }
            var left: [LayerId] = []
            for id in moving { for c in clippedTo(doc, id) where !moving.contains(c) && left.last != c { left.append(c) } }
            b.left = left
            return b
        }

        func group(_ id: LayerId) -> [LayerId] { groups.first { $0.0 == id }?.1 ?? [] }
    }

    static func setClipped(_ doc: inout Document, _ id: LayerId, _ v: Bool) {
        doc.updateLayer(id) { $0.clipped = v }
    }

    /// After `placed` were added or moved (`before` read before they moved; empty for new layers):
    /// each placed layer joins or leaves clip groups by rules 1–2 (topmost first), or is clipped
    /// anyway when `force` (New Layer's Use Previous Layer to Create Clipping Mask). Then the layers
    /// that lost their base are released (rule 3), and orphans (rule 4).
    public static func settle(_ doc: inout Document, placed: [LayerId], before: Before = Before(), force: Bool = false) {
        var order: [(LayerPath, LayerId)] = placed.compactMap { id in doc.path(of: id).map { ($0, id) } }
        order.sort { $0.0.lexicographicallyPrecedes($1.0) }
        for (_, id) in order.reversed() {
            let group = before.group(id)
            let travelling = { (n: LayerId) in before.moving.contains(n) && group.contains(n) }
            let joins = neighbour(doc, id, 1).map { $0.clipped && !travelling($0.id) } ?? false
            let stays = before.clipped.contains(id) && (neighbour(doc, id, -1).map { $0.clipped || group.contains($0.id) } ?? false)
            setClipped(&doc, id, force || joins || stays)
        }
        for id in before.left where !placed.contains(id) { setClipped(&doc, id, false) }
        releaseOrphans(&doc)
    }

    /// Rule 4: release the clipped layers at the bottom of every sibling list.
    public static func releaseOrphans(_ doc: inout Document) {
        func fix(_ list: inout [Layer]) {
            var i = 0
            while i < list.count, list[i].clipped {
                list[i].clipped = false
                i += 1
            }
            for j in list.indices { list[j].withChildren { fix(&$0) } }
        }
        // Only touch the tree when something needs releasing (keeps the id index).
        var needed = false
        func check(_ list: [Layer]) {
            if list.first?.clipped == true { needed = true; return }
            for l in list { if let c = l.children { check(c) }; if needed { return } }
        }
        check(doc.layers)
        if needed { fix(&doc.layers) }
    }
}
