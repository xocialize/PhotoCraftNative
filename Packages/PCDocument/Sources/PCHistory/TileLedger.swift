// Tile references owned by history snapshots: which pixel tiles history keeps alive and how many
// bytes they hold.
// Port of photocraft-ops (crates/ops/src/tiles.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// photocraft identifies a shared tile by its `Arc` address. A PCFoundation tile's bytes are a
// copy-on-write Swift array stamped with a generation that changes on every mutation and is copied
// with the tile, so equal generations mean the same shared allocation: the generation is the key
// here. Occurrences are counted (including aliases within one document), so removing a state
// releases a tile only after its last reference.

import PCDocument
import PCFoundation

/// Every pixel surface of `doc` that history accounts for: layer content (pixels or rendered
/// caches), layer masks, smart-filter masks, fill caches, video frames (and original footage),
/// alpha channels, the Quick Mask, the selection and stored patterns.
func visitSurfaces(_ doc: Document, _ visit: (Surface) -> Void) {
    doc.forEachLayer { _, _, layer in
        if let s = layer.surface { visit(s) }
        if let m = layer.mask { visit(m.surface) }
        if case .smart(let so) = layer.content, let fm = so.filterMask { visit(fm.surface) }
        if let fc = layer.fillCache { visit(fc.surface) }
        if let video = layer.video {
            // Undo retains the whole clip, not only the displayed frame. Visit aliases too: the
            // ledger tracks every owner and counts their shared allocations only once.
            for f in video.frames { visit(f) }
            for f in video.originalFrames ?? [] { visit(f) }
        }
    }
    for c in doc.channels { visit(c.surface) }
    if let q = doc.quickMask { visit(q.surface) }
    if let s = doc.selection { visit(s) }
    for p in doc.patterns { visit(p.surface) }
}

/// Calls `body` with the identity (generation) and byte size of every tile of `s`.
func forEachTile(_ s: Surface, _ body: (UInt64, Int) -> Void) {
    for c in s.tileCoords {
        if let t = s.tile(c) { body(t.generation, t.bytes.count) }
    }
}

/// Bytes of the pixel tiles of `doc` not already in `seen` (which collects them).
func tileBytes(_ doc: Document, _ seen: inout Set<UInt64>) -> Int {
    var n = 0
    visitSurfaces(doc) { s in
        forEachTile(s) { key, bytes in
            if seen.insert(key).inserted { n = n.addingSaturating(bytes) }
        }
    }
    return n
}

/// Reference counts of the tiles held by history states, with their total size.
struct TileLedger: Sendable {
    /// Tile key → (references, bytes).
    private(set) var refs: [UInt64: (count: Int, bytes: Int)] = [:]
    private(set) var bytes: Int = 0

    mutating func add(_ doc: Document) {
        visitSurfaces(doc) { s in
            forEachTile(s) { key, size in
                if let e = refs[key] {
                    refs[key] = (e.count + 1, e.bytes)
                } else {
                    refs[key] = (1, size)
                    bytes = bytes.addingSaturating(size)
                }
            }
        }
    }

    mutating func remove(_ doc: Document) {
        visitSurfaces(doc) { s in
            forEachTile(s) { key, _ in
                guard let e = refs[key] else { return }
                if e.count <= 1 {
                    bytes -= e.bytes
                    refs[key] = nil
                } else {
                    refs[key] = (e.count - 1, e.bytes)
                }
            }
        }
    }

    /// Retained bytes are incremental; only current tiles need examining below the limit. Current
    /// can change without recording (coalescing), and tile transfers can carry a different byte
    /// length, so a tile-count estimate must not underestimate its memory.
    func fits(_ current: Document, budget: Int) -> Bool {
        bytes <= budget && bytesWith(current) <= budget
    }

    /// Retained bytes plus the tiles of `current` history doesn't hold.
    func bytesWith(_ current: Document) -> Int {
        var total = bytes
        var seen = Set<UInt64>()
        visitSurfaces(current) { s in
            forEachTile(s) { key, size in
                if refs[key] == nil, seen.insert(key).inserted { total = total.addingSaturating(size) }
            }
        }
        return total
    }
}

extension Int {
    func addingSaturating(_ o: Int) -> Int {
        let (r, overflow) = addingReportingOverflow(o)
        return overflow ? (o > 0 ? .max : .min) : r
    }
}
