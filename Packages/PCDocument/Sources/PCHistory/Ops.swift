// Reversible operations and transactions (architecture §6): every mutation can be expressed as a
// `DocumentOp` whose application returns its inverse, and a command's ops form one labelled
// `EditTransaction`. Ops address layers by id, so a transaction computed from an older snapshot
// (a background job) re-targets the same layers on the current document, or fails cleanly when
// they are gone ("rebase or report a conflict").
// Design from photocraft docs/architecture.md §6 (photocraft-ops itself records whole-document
// snapshots, which `History` keeps doing); MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.
//
// Pixel ops work at tile granularity through PCFoundation's `takeTiles`/`putTiles`: a patch swaps
// whole copy-on-write tiles, so before/after states cost only the tiles that changed and undoing
// swaps tiles back without copying pixels.
//
// Document-level fields with no pixels (guides, the Paths panel, slices, notes, the canvas size)
// change through `setDocumentProperties`, which replaces just the fields it carries: like
// `setLayerProperties` for one layer, it re-applies onto a newer document without touching the
// layers, selection or the other fields edited meanwhile.

import PCDocument
import PCFoundation

/// A pixel surface of a document that ops can address.
public enum SurfaceRef: Hashable, Sendable {
    /// A pixel layer's content.
    case layer(LayerId)
    /// A layer's raster mask.
    case layerMask(LayerId)
    /// Alpha/spot channel `index` of `Document.channels`.
    case channel(Int)
    /// The Quick Mask channel.
    case quickMask
    /// The selection mask.
    case selection
}

/// One tile of a surface after an edit: the tile to put at `coord`, or nil to clear it (back to
/// the surface's default pixel).
public struct TilePatch: Equatable, Sendable {
    public var coord: TileCoord
    public var tile: Tile?

    public init(coord: TileCoord, tile: Tile?) { self.coord = coord; self.tile = tile }

    /// The patches that turn `old` into `new` (the same surface before and after an edit): tiles
    /// added, removed or changed. Tiles shared by both (same generation) are skipped, so this is
    /// exact and cheap for a copy that was edited in place.
    public static func changes(from old: Surface, to new: Surface) -> [TilePatch] {
        var out: [TilePatch] = []
        let coords = Set(old.tileCoords).union(new.tileCoords).sorted()
        for c in coords {
            let (a, b) = (old.tile(c), new.tile(c))
            if a?.generation != b?.generation { out.append(TilePatch(coord: c, tile: b)) }
        }
        return out
    }
}

/// A reversible document mutation. `apply` performs it and returns the op that undoes it.
public enum DocumentOp: Sendable {
    /// Swap tiles of a surface (brush strokes, filters on a region): `PaintTiles` of §6.
    case paintTiles(SurfaceRef, [TilePatch])
    /// Replace a whole surface (whole-layer filters, depth changes).
    case replaceSurface(SurfaceRef, Surface)
    /// Set or clear the selection.
    case setSelection(Surface?)
    /// Set a layer's pixel-free properties: `SetLayerProps` of §6.
    case setLayerProperties(LayerId, LayerProperties)
    /// Set, replace or remove a layer's raster mask (Add Layer Mask, Remove Background).
    case setLayerMask(LayerId, LayerMask?)
    /// Replace a layer node (and its subtree) by a layer with the same id.
    case replaceLayer(Layer)
    /// Insert a layer (with its children): `AddLayer` of §6.
    case insertLayer(Layer, LayerPlacement)
    /// Remove a layer (with its children).
    case removeLayer(LayerId)
    /// Move a layer (with its children): `MoveLayer` of §6.
    case moveLayer(LayerId, LayerPlacement)
    /// Replace the whole document (image size, mode conversion, flatten…); cheap with
    /// copy-on-write.
    case replaceDocument(Document)
    /// Set pixel-free document fields (guides, paths, slices, notes, canvas size): only the fields
    /// the value carries change. Rebaseable, unlike `replaceDocument`.
    case setDocumentProperties(DocumentProperties)

    /// Applies the op to `doc` and returns its inverse. On failure `doc` is unchanged.
    public func apply(to doc: inout Document) throws(DocumentError) -> DocumentOp {
        switch self {
        case .paintTiles(let ref, let patches):
            let bpp = try doc.surfaceFormat(ref).bytesPerPixel
            let tileBytes = Int(tileSize) * Int(tileSize) * bpp
            for p in patches {
                if let t = p.tile, t.bytes.count != tileBytes {
                    throw DocumentError("tile \(p.coord.tx),\(p.coord.ty) has \(t.bytes.count) bytes, the surface needs \(tileBytes)")
                }
            }
            var inverse: [TilePatch] = []
            try doc.withSurface(ref) { s in
                for p in patches {
                    let old = s.takeTiles(p.coord.rect).first { $0.0 == p.coord }?.1
                    if let t = p.tile { s.putTiles([(p.coord, t)]) }
                    inverse.append(TilePatch(coord: p.coord, tile: old))
                }
            }
            return .paintTiles(ref, inverse.reversed())

        case .replaceSurface(let ref, let new):
            var old: Surface?
            try doc.withSurface(ref) { s in
                old = s
                s = new
            }
            guard let old else { throw DocumentError("no surface \(ref)") }
            return .replaceSurface(ref, old)

        case .setSelection(let s):
            let old = doc.selection
            doc.selection = s
            return .setSelection(old)

        case .setLayerProperties(let id, let props):
            guard let old = doc.updateLayer(id, { l -> LayerProperties in
                let o = l.properties
                l.properties = props
                return o
            }) else { throw DocumentError("no layer \(id)") }
            return .setLayerProperties(id, old)

        case .setLayerMask(let id, let mask):
            guard let old = doc.updateLayer(id, { l -> LayerMask? in
                let o = l.mask
                l.mask = mask
                return o
            }) else { throw DocumentError("no layer \(id)") }
            return .setLayerMask(id, old)

        case .replaceLayer(let new):
            guard let p = doc.path(of: new.id), let old = doc.layer(at: p) else { throw DocumentError("no layer \(new.id)") }
            if !new.hasSameTreeShape(as: old) {
                // The subtree changes shape: go through remove + insert so the id checks apply.
                let before = doc
                guard let parentIndex = p.last else { throw DocumentError("no layer \(new.id)") }
                let parent = doc.parent(of: new.id)
                doc.remove(new.id)
                do {
                    try doc.insert(new, at: .at(index: parentIndex, in: parent))
                } catch {
                    doc = before
                    throw error
                }
            } else {
                doc.updateLayer(at: p) { $0 = new }
            }
            return .replaceLayer(old)

        case .insertLayer(let layer, let placement):
            try doc.insert(layer, at: placement)
            return .removeLayer(layer.id)

        case .removeLayer(let id):
            guard let index = doc.indexInParent(id) else { throw DocumentError("no layer \(id)") }
            let parent = doc.parent(of: id)
            guard let removed = doc.remove(id) else { throw DocumentError("no layer \(id)") }
            return .insertLayer(removed, .at(index: index, in: parent))

        case .moveLayer(let id, let placement):
            guard let index = doc.indexInParent(id) else { throw DocumentError("no layer \(id)") }
            let parent = doc.parent(of: id)
            try doc.move(id, to: placement)
            return .moveLayer(id, .at(index: index, in: parent))

        case .replaceDocument(let new):
            let old = doc
            doc = new
            return .replaceDocument(old)

        case .setDocumentProperties(let props):
            let old = props.current(in: doc)
            props.apply(to: &doc)
            return .setDocumentProperties(old)
        }
    }
}

/// The Paths panel's state: saved paths, the work path and the clipping path (one field of
/// `DocumentProperties`, since a path edit can touch all three).
public struct DocumentPaths: Equatable, Sendable {
    public var paths: [NamedPath]
    public var workPath: VectorPath?
    public var clippingPath: ClippingPath?

    public init(paths: [NamedPath] = [], workPath: VectorPath? = nil, clippingPath: ClippingPath? = nil) {
        self.paths = paths; self.workPath = workPath; self.clippingPath = clippingPath
    }

    /// A document's Paths panel.
    public init(_ doc: Document) { self.init(paths: doc.paths, workPath: doc.workPath, clippingPath: doc.clippingPath) }
}

/// Pixel-free document fields `DocumentOp.setDocumentProperties` sets. A nil field is left as it
/// is, so an op carries only what its command changed and re-applies onto a newer document
/// without undoing other edits.
public struct DocumentProperties: Equatable, Sendable {
    /// The canvas size (Image › Canvas Size, Reveal All, a crop's canvas).
    public var size: PixelSize?
    public var guides: Guides?
    public var paths: DocumentPaths?
    public var slices: Slices?
    public var notes: [Note]?

    public init(size: PixelSize? = nil, guides: Guides? = nil, paths: DocumentPaths? = nil, slices: Slices? = nil, notes: [Note]? = nil) {
        self.size = size; self.guides = guides; self.paths = paths; self.slices = slices; self.notes = notes
    }

    /// No field set: applying it changes nothing.
    public var isEmpty: Bool { self == DocumentProperties() }

    /// The fields that differ between two versions of a document, with `after`'s values.
    public static func changes(from before: Document, to after: Document) -> DocumentProperties {
        var p = DocumentProperties()
        if before.size != after.size { p.size = after.size }
        if before.guides != after.guides { p.guides = after.guides }
        let (pa, pb) = (DocumentPaths(before), DocumentPaths(after))
        if pa != pb { p.paths = pb }
        if before.slices != after.slices { p.slices = after.slices }
        if before.notes != after.notes { p.notes = after.notes }
        return p
    }

    /// `doc`'s values for the fields set here (what applying this replaces: its inverse).
    public func current(in doc: Document) -> DocumentProperties {
        DocumentProperties(size: size.map { _ in doc.size }, guides: guides.map { _ in doc.guides },
                           paths: paths.map { _ in DocumentPaths(doc) }, slices: slices.map { _ in doc.slices },
                           notes: notes.map { _ in doc.notes })
    }

    /// Sets the fields carried here on `doc`.
    public func apply(to doc: inout Document) {
        if let size { doc.size = size }
        if let guides { doc.guides = guides }
        if let paths {
            doc.paths = paths.paths
            doc.workPath = paths.workPath
            doc.clippingPath = paths.clippingPath
        }
        if let slices { doc.slices = slices }
        if let notes { doc.notes = notes }
    }
}

/// A command's ops with a label ("Gaussian Blur"): one history step.
public struct EditTransaction: Sendable {
    public var label: String
    public var ops: [DocumentOp]

    public init(_ label: String, _ ops: [DocumentOp] = []) { self.label = label; self.ops = ops }

    public var isEmpty: Bool { ops.isEmpty }

    /// Adds an op (a brush stroke accumulates its dabs into one transaction).
    public mutating func append(_ op: DocumentOp) { ops.append(op) }

    /// Applies every op in order, atomically: on failure `doc` is unchanged. Returns the inverse
    /// transaction (same label, inverse ops in reverse order).
    @discardableResult
    public func apply(to doc: inout Document) throws(DocumentError) -> EditTransaction {
        let before = doc
        var inverses: [DocumentOp] = []
        do {
            for op in ops { inverses.append(try op.apply(to: &doc)) }
        } catch {
            doc = before
            throw error
        }
        return EditTransaction(label, inverses.reversed())
    }
}

extension History {
    /// Applies `transaction` to `doc` and records the document as it was before, as one step named
    /// after the transaction that left `layers` targeted. On failure nothing changes. Returns the
    /// inverse transaction.
    @discardableResult
    public mutating func commit(_ transaction: EditTransaction, to doc: inout Document, layers: LayerTarget) throws(DocumentError) -> EditTransaction {
        let before = doc
        let inverse = try transaction.apply(to: &doc)
        record(transaction.label, before: before, layers: layers)
        return inverse
    }
}

extension Document {
    /// The pixel format of a referenced surface.
    func surfaceFormat(_ ref: SurfaceRef) throws(DocumentError) -> PixelFormat {
        switch ref {
        case .layer(let id):
            guard let s = layer(id)?.rasterSurface else { throw DocumentError("layer \(id) is not a pixel layer") }
            return s.format
        case .layerMask(let id):
            guard let m = layer(id)?.mask else { throw DocumentError("layer \(id) has no mask") }
            return m.surface.format
        case .channel(let i):
            guard i >= 0, i < channels.count else { throw DocumentError("no channel \(i)") }
            return channels[i].surface.format
        case .quickMask:
            guard let q = quickMask else { throw DocumentError("Quick Mask is off") }
            return q.surface.format
        case .selection:
            guard let s = selection else { throw DocumentError("no selection") }
            return s.format
        }
    }

    /// Mutates a referenced surface in place (uniquely referenced, so only touched tiles copy).
    mutating func withSurface(_ ref: SurfaceRef, _ body: (inout Surface) -> Void) throws(DocumentError) {
        switch ref {
        case .layer(let id):
            guard withRaster(of: id, body) != nil else { throw DocumentError("layer \(id) is not a pixel layer") }
        case .layerMask(let id):
            let done = updateLayer(id) { l -> Bool in
                guard var m = l.mask else { return false }
                l.mask = nil
                body(&m.surface)
                l.mask = m
                return true
            } ?? false
            guard done else { throw DocumentError("layer \(id) has no mask") }
        case .channel(let i):
            guard i >= 0, i < channels.count else { throw DocumentError("no channel \(i)") }
            body(&channels[i].surface)
        case .quickMask:
            guard var q = quickMask else { throw DocumentError("Quick Mask is off") }
            quickMask = nil
            body(&q.surface)
            quickMask = q
        case .selection:
            guard var s = selection else { throw DocumentError("no selection") }
            selection = nil
            body(&s)
            selection = s
        }
    }
}
