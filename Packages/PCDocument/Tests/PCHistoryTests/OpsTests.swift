// Tests of the reversible operations and transactions (architecture §6 of photocraft's design),
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCDocument
import PCFoundation
import Testing
@testable import PCHistory

@Suite struct OpsTests {
    func doc() -> (Document, LayerId, LayerId) {
        var d = Document.withBackground(name: "ops", size: PixelSize(width: 600, height: 300), mode: .rgb, depth: .u8, fill: .white)
        let a = d.insertAbove(nil, Layer.raster("A", format: d.pixelFormat))
        let g = d.insertAbove(nil, Layer.group("G", []))
        return (d, a, g)
    }

    func apply(_ op: DocumentOp, _ d: inout Document) throws -> DocumentOp { try op.apply(to: &d) }

    @Test func setLayerMaskAddsReplacesRemovesAndInverts() throws {
        var (d, a, _) = doc()
        let original = d
        var mask = LayerMask.hideAll()
        mask.surface.setPixel(x: 4, y: 4, [1])
        let undoAdd = try apply(.setLayerMask(a, mask), &d)
        #expect(d.layer(a)?.mask == mask)
        let undoRemove = try apply(.setLayerMask(a, nil), &d)
        #expect(d.layer(a)?.mask == nil)
        _ = try apply(undoRemove, &d)
        #expect(d.layer(a)?.mask == mask)
        _ = try apply(undoAdd, &d)
        #expect(d == original)
        #expect(throws: DocumentError.self) { try apply(.setLayerMask(LayerId(999_999), nil), &d) }
    }

    @Test func paintTilesSwapsOnlyChangedTilesAndInverts() throws {
        var (d, _, _) = doc()
        let bg = d.layers[0].id
        let original = d
        // A tool paints into a copy of the surface, then commits the changed tiles.
        var edited = try #require(d.layer(bg)?.rasterSurface)
        let untouched = edited
        edited.setPixel(x: 300, y: 10, [1, 0, 0, 1])   // tile (1, 0)
        edited.setPixel(x: 10, y: 600, [0, 0, 1, 1])   // tile (0, 2): new (the canvas ends at y 300)
        let patches = TilePatch.changes(from: untouched, to: edited)
        #expect(patches.map(\.coord) == [TileCoord(tx: 1, ty: 0), TileCoord(tx: 0, ty: 2)])
        let inverse = try apply(.paintTiles(.layer(bg), patches), &d)
        #expect(d.layer(bg)?.surface?.pixel(x: 300, y: 10) == [1, 0, 0, 1])
        #expect(d.layer(bg)?.surface?.pixel(x: 10, y: 600) == [0, 0, 1, 1])
        // Tiles not in the patch are still shared with the original document.
        #expect(d.layer(bg)?.surface?.tile(TileCoord(tx: 0, ty: 0))?.generation == original.layer(bg)?.surface?.tile(TileCoord(tx: 0, ty: 0))?.generation)
        _ = try apply(inverse, &d)
        #expect(d == original)
        #expect(d.layer(bg)?.surface?.tile(TileCoord(tx: 0, ty: 2)) == nil, "the new tile is cleared again")
    }

    @Test func paintTilesRejectsMismatchedTilesAndMissingTargets() throws {
        var (d, a, g) = doc()
        var deep = Surface(format: .rgba16)
        deep.setPixel(x: 0, y: 0, [1, 1, 1, 1])
        let wrong = [TilePatch(coord: TileCoord(tx: 0, ty: 0), tile: deep.tile(TileCoord(tx: 0, ty: 0)))]
        let before = d
        #expect(throws: DocumentError.self) { _ = try apply(.paintTiles(.layer(a), wrong), &d) }
        #expect(throws: DocumentError.self) { _ = try apply(.paintTiles(.layer(g), []), &d) }
        #expect(throws: DocumentError.self) { _ = try apply(.paintTiles(.layerMask(a), []), &d) }
        #expect(throws: DocumentError.self) { _ = try apply(.paintTiles(.selection, []), &d) }
        #expect(throws: DocumentError.self) { _ = try apply(.paintTiles(.channel(0), []), &d) }
        #expect(d == before)
    }

    @Test func surfacesOfMasksChannelsAndSelection() throws {
        var (d, a, _) = doc()
        d.updateLayer(a) { $0.mask = .revealAll() }
        d.channels.append(AlphaChannel(name: "Alpha 1", surface: Surface(format: .gray8)))
        d.selection = Surface(format: .gray8)
        d.quickMask = AlphaChannel(name: "Quick Mask", surface: Surface(format: .gray8))
        let original = d
        var tx = EditTransaction("Paint masks")
        for ref in [SurfaceRef.layerMask(a), .channel(0), .selection, .quickMask] {
            var s = try #require(d.surfaceForTest(ref))
            let old = s
            s.setPixel(x: 5, y: 5, [0.5])
            tx.append(.paintTiles(ref, TilePatch.changes(from: old, to: s)))
        }
        let inverse = try tx.apply(to: &d)
        #expect(abs((d.layer(a)?.mask?.value(x: 5, y: 5) ?? 0) - 0.5) < 0.01)
        #expect(abs((d.selection?.pixel(x: 5, y: 5)[0] ?? 0) - 0.5) < 0.01)
        #expect(abs((d.channels[0].surface.pixel(x: 5, y: 5)[0]) - 0.5) < 0.01)
        #expect(abs((d.quickMask?.surface.pixel(x: 5, y: 5)[0] ?? 0) - 0.5) < 0.01)
        try inverse.apply(to: &d)
        #expect(d == original)
    }

    @Test func layerStructureOpsInvert() throws {
        var (d, a, g) = doc()
        let original = d
        var props = try #require(d.layer(a)).properties
        props.name = "Renamed"
        props.opacity = 0.5
        props.blend = .multiply
        let ops: [DocumentOp] = [
            .setLayerProperties(a, props),
            .insertLayer(Layer.raster("new", format: d.pixelFormat), .top(of: g)),
            .moveLayer(a, .bottom(of: g)),
            .removeLayer(d.layers[0].id),
        ]
        let tx = EditTransaction("Several", ops)
        let inverse = try tx.apply(to: &d)
        #expect(d.layer(a)?.name == "Renamed" && d.layer(a)?.blend == .multiply)
        #expect(d.parent(of: a) == g)
        #expect(d.children(of: g)?.map(\.name) == ["Renamed", "new"])
        #expect(d.layers.map(\.name) == ["G"])
        #expect(inverse.label == "Several" && inverse.ops.count == 4)
        try inverse.apply(to: &d)
        #expect(d == original)
    }

    @Test func replaceLayerAndDocument() throws {
        var (d, a, g) = doc()
        let original = d
        var newA = try #require(d.layer(a))
        newA.withRaster { $0.fill(PixelRect(x0: 0, y0: 0, x1: 4, y1: 4), with: [0, 1, 0, 1]) }
        newA.visible = false
        var newG = try #require(d.layer(g))
        newG.withChildren { $0.append(Layer.raster("inside", format: .rgba8)) }
        let tx = EditTransaction("Replace", [.replaceLayer(newA), .replaceLayer(newG)])
        let inverse = try tx.apply(to: &d)
        #expect(d.layer(a)?.visible == false)
        #expect(d.children(of: g)?.count == 1)
        try inverse.apply(to: &d)
        #expect(d == original)
        // A layer the document doesn't have can't be replaced.
        #expect(throws: DocumentError.self) { _ = try apply(.replaceLayer(Layer.raster("stranger", format: .rgba8)), &d) }
        // Whole-document replacement (image size, mode changes).
        var resized = d
        resized.size = PixelSize(width: 10, height: 10)
        let back = try apply(.replaceDocument(resized), &d)
        #expect(d.size.width == 10)
        _ = try apply(back, &d)
        #expect(d == original)
    }

    @Test func aFailingTransactionLeavesTheDocumentUnchanged() throws {
        var (d, a, _) = doc()
        let original = d
        let tx = EditTransaction("Broken", [
            .setLayerProperties(a, { var p = d.layer(a)!.properties; p.name = "changed"; return p }()),
            .removeLayer(LayerId(.max)),
        ])
        #expect(throws: DocumentError.self) { try tx.apply(to: &d) }
        #expect(d == original)
    }

    /// A background job computes from an old snapshot; its ops re-target the same layer ids on the
    /// current document (architecture §6 "rebase"), or fail cleanly when the layer is gone.
    @Test func transactionsRebaseOntoANewerDocumentById() throws {
        var (d, a, g) = doc()
        let snapshot = d
        // Meanwhile the user moves A into G and adds a layer below it.
        try d.move(a, to: .top(of: g))
        d.insertAbove(nil, Layer.raster("later", format: d.pixelFormat))
        // The job's result: tiles for A painted from the snapshot's pixels.
        var s = try #require(snapshot.layer(a)?.rasterSurface)
        let old = s
        s.fill(PixelRect(x0: 0, y0: 0, x1: 8, y1: 8), with: [1, 0, 1, 1])
        let job = EditTransaction("Filter", [.paintTiles(.layer(a), TilePatch.changes(from: old, to: s))])
        try job.apply(to: &d)
        #expect(d.layer(a)?.surface?.pixel(x: 3, y: 3) == [1, 0, 1, 1])
        #expect(d.parent(of: a) == g)
        // Conflict: the layer was deleted meanwhile.
        d.remove(a)
        #expect(throws: DocumentError.self) { try job.apply(to: &d) }
    }

    @Test func commitRecordsOneUndoableStep() throws {
        var (d, a, _) = doc()
        var h = History()
        let original = d
        var props = try #require(d.layer(a)).properties
        props.visible = false
        try h.commit(EditTransaction("Hide Layer", [.setLayerProperties(a, props)]), to: &d, layers: .single(a))
        #expect(h.entries == ["Open", "Hide Layer"])
        #expect(d.layer(a)?.visible == false)
        let undone = try undoOrThrow(&h, d)
        #expect(undone.doc == original)
        // A failing commit records nothing.
        d = undone.doc
        #expect(throws: DocumentError.self) { try h.commit(EditTransaction("Bad", [.removeLayer(LayerId(.max))]), to: &d, layers: LayerTarget()) }
        #expect(h.entries == ["Open"])
        #expect(d == original)
    }
}

extension Document {
    /// The referenced surface (test helper mirroring `withSurface`).
    func surfaceForTest(_ ref: SurfaceRef) -> Surface? {
        switch ref {
        case .layer(let id): layer(id)?.rasterSurface
        case .layerMask(let id): layer(id)?.mask?.surface
        case .channel(let i): i < channels.count ? channels[i].surface : nil
        case .quickMask: quickMask?.surface
        case .selection: selection
        }
    }
}
