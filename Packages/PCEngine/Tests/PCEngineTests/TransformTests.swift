// Port of photocraft-engine (crates/engine/src/transform_cmds.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Every photocraft test is ported. Added: a smart object (built with a rendered cache, since
// Convert to Smart Object is smart_cmds') transforms by its placement and cached pixels (the
// "transformed smart object" case of extra_cmds' `rasterize_smart_object_layer`), and the ids
// match photocraft's metadata.

import Foundation
import PCAlgo
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct TransformTests {
    /// 100×100 document, a new layer with a red rectangle at (10,10)–(30,20).
    func session() throws -> Session {
        let s = Session()
        try s.execute("file.new", ["width": 100, "height": 100])
        try s.execute("layer.new.layer")
        try s.edit("paint") { doc, a in
            guard let id = a else { throw EngineError.other("no layer") }
            doc.withRaster(of: id) { $0.fill(PixelRect(x0: 10, y0: 10, x1: 30, y1: 20), with: [1, 0, 0, 1]) }
        }
        return s
    }

    func active(_ s: Session) -> Layer? { s.active.flatMap { st in st.activeLayer.flatMap { st.doc.layer($0) } } }

    func activeBounds(_ s: Session) -> PixelRect { active(s)?.surface?.contentBounds ?? .empty }

    func rect(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> PixelRect { PixelRect(x0: x0, y0: y0, x1: x1, y1: y1) }

    func lock(_ s: Session, _ id: LayerId, _ on: Bool) throws {
        try s.edit("lock") { doc, _ in doc.updateLayer(id) { $0.locks.position = on } }
    }

    @Test func scaleViaQuadAndUndo() throws {
        let s = try session()
        try s.execute("edit.transform", ["quad": [[10, 10], [50, 10], [50, 30], [10, 30]]])
        let b = activeBounds(s)
        #expect(abs(b.width - 40) <= 2 && abs(b.height - 20) <= 2, "\(b)")
        s.undo()
        #expect(activeBounds(s) == rect(10, 10, 30, 20))
    }

    @Test func affineMatrixAndPerspective() throws {
        let s = try session()
        // Translate by (40, 50).
        try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 40, 50]])
        #expect(activeBounds(s) == rect(50, 60, 70, 70))
        // Perspective: top edge narrower than the bottom.
        try s.execute("edit.transform", ["quad": [[55, 60], [65, 60], [75, 70], [45, 70]]])
        let b = activeBounds(s)
        #expect(b.x0 <= 46 && b.x1 >= 74, "\(b)")
        #expect(throws: (any Error).self) { try s.execute("edit.transform", ["quad": [[0, 0], [0, 0], [0, 0], [0, 0]]]) }
    }

    @Test func backgroundBecomesLayer0() throws {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 40])
        try s.execute("edit.transform", ["quad": [[0, 0], [20, 0], [20, 20], [0, 20]]])
        let l = try #require(s.active?.doc.layers.first)
        #expect(l.name == "Layer 0")
        let surf = try #require(l.surface)
        #expect(surf.format.alpha)
        #expect(surf.pixel(x: 30, y: 30)[3] == 0, "revealed area is transparent")
    }

    /// `lockedForTransform` (what Free Transform asks before its box opens, #2585) agrees with
    /// what `edit.transform` refuses at commit: a position lock, its own or a group's; never the
    /// Background's (it becomes Layer 0).
    @Test func lockedForTransformMatchesTheCommit() throws {
        let quad: JSONValue = ["quad": [[10, 10], [50, 10], [50, 30], [10, 30]]]
        let s = try session()
        let layer = try #require(s.active?.activeLayer)
        try lock(s, layer, true)
        #expect(TransformCommands.lockedForTransform(try #require(s.active?.doc), layer))
        #expect(throws: (any Error).self) { try s.execute("edit.transform", quad) }
        try lock(s, layer, false)
        let r = try s.execute("layer.groupLayers", ["layer": .id(layer)])
        let group = LayerId(try #require(r["layer"]?.uint64Value))
        try lock(s, group, true)
        try s.execute("layer.select", ["layer": .id(layer)])
        #expect(TransformCommands.lockedForTransform(try #require(s.active?.doc), layer), "the group's lock reaches the layer")
        #expect(throws: (any Error).self) { try s.execute("edit.transform", quad) }
        let bg = try #require(s.active?.doc.layers.first?.id)
        #expect(!TransformCommands.lockedForTransform(try #require(s.active?.doc), bg), "the Background transforms")
    }

    @Test func withSelectionOnlySelectedPixelsMove() throws {
        let s = try session()
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 10])
        try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 0, 50]])
        let surf = try #require(active(s)?.surface)
        #expect(surf.pixel(x: 15, y: 15)[3] == 0, "lifted area is cleared")
        #expect(surf.pixel(x: 25, y: 15)[3] == 1, "unselected part stays")
        #expect(surf.pixel(x: 15, y: 65)[3] == 1, "moved pixels land")
        let sel = try #require(s.active?.doc.selection).contentBounds
        #expect((sel.y0, sel.y1) == (60, 70), "selection moves too")
    }

    @Test func withSelectionBoundsDropTheVacatedArea() throws {
        // #1097: moving every pixel through a selection left transparent but coloured pixels
        // behind, so the layer bounds were the union of the old and new positions.
        let s = try session()
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 20, "height": 10])
        try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 50, 0]])
        #expect(activeBounds(s) == rect(60, 10, 80, 20))
    }

    @Test func typeLayersTransformAsVectors() throws {
        let s = try session()
        let r = try s.execute("type.create", ["x": 10, "y": 50, "text": "Hi", "size": 20])
        let id = try #require(r["layer"]?.uint64Value)
        let w0 = activeBounds(s).width
        try s.execute("edit.transform", ["layer": .number(Double(id)), "matrix": [2, 0, 0, 2, -10, -50]])
        let w1 = activeBounds(s).width
        #expect(Float(w1) > Float(w0) * 1.8, "\(w0) → \(w1)")
        guard case .text(let t)? = s.active?.doc.layer(LayerId(id))?.content else { Issue.record("type"); return }
        #expect(abs(t.transform.a - 2) < 1e-9)
        // Perspective on type is refused, like Photoshop.
        #expect(throws: (any Error).self) {
            try s.execute("edit.transform", ["layer": .number(Double(id)), "quad": [[0, 0], [10, 0], [12, 10], [-2, 10]]])
        }
    }

    @Test func shapesMoveAndTransformAsVectors() throws {
        let s = Session()
        try s.execute("file.new", ["width": 200, "height": 200])
        try s.execute("shape.create", ["kind": "rect", "rect": [10, 10, 40, 20], "fill": "#ff0000"])
        try s.execute("layer.translate", ["dx": 30, "dy": 5])
        #expect(activeBounds(s) == rect(40, 15, 80, 35))
        try s.execute("edit.transform", ["matrix": [2, 0, 0, 2, -40, -15]])
        #expect(activeBounds(s) == rect(40, 15, 120, 55))
        // Distort maps the path and keeps a live shape (#3009): the rectangle's corners go to the quad.
        let quad: [SIMD2<Double>] = [SIMD2(40, 15), SIMD2(120, 15), SIMD2(130, 55), SIMD2(30, 55)]
        try s.execute("edit.transform", ["quad": .array(quad.map { [.number($0.x), .number($0.y)] })])
        guard case .shape(let sh)? = active(s)?.content else { Issue.record("still a shape layer"); return }
        let order: (SIMD2<Double>, SIMD2<Double>) -> Bool = { ($0.x, $0.y) < ($1.x, $1.y) }
        let anchors = (sh.path.subpaths.first?.knots ?? []).map { SIMD2($0.anchor.x, $0.anchor.y) }.sorted(by: order)
        let want = quad.sorted(by: order)
        #expect(anchors.count == 4 && zip(anchors, want).allSatisfy { abs($0.x - $1.x) < 1e-6 && abs($0.y - $1.y) < 1e-6 }, "\(anchors)")
        #expect(sh.live == nil, "the live rectangle is now a path")
        #expect(activeBounds(s) == rect(30, 15, 130, 55))
        // Warp bends the path too: the arc adds anchors along the curved edges.
        try s.execute("edit.transform.warp", ["style": "arc", "bend": 50])
        guard case .shape(let bent)? = active(s)?.content else { Issue.record("still a shape layer"); return }
        #expect((bent.path.subpaths.first?.knots.count ?? 0) > 4)
        #expect(!activeBounds(s).isEmpty)
    }

    @Test func typeMovesWithTheMoveCommand() throws {
        let s = try session()
        try s.execute("type.create", ["x": 10, "y": 50, "text": "Hi", "size": 20])
        let b0 = activeBounds(s)
        try s.execute("layer.translate", ["dx": 20, "dy": 10])
        let b1 = activeBounds(s)
        #expect((b1.x0 - b0.x0, b1.y0 - b0.y0) == (20, 10))
    }

    // MARK: Layer masks and targets (#205)

    /// `session()` plus a reveal-all mask with `hide` painted black (linked unless `linked` is false).
    func masked(_ hide: [PixelRect], linked: Bool) throws -> Session {
        let s = try session()
        try s.execute("layer.layerMask.revealAll")
        try s.edit("mask") { doc, a in
            guard let id = a else { throw EngineError.other("no layer") }
            doc.updateLayer(id) { l in
                for r in hide { l.mask?.surface.fill(r, with: [0]) }
                l.mask?.linked = linked
            }
        }
        return s
    }

    func maskAt(_ s: Session, _ x: Int32, _ y: Int32) -> Float { active(s)?.mask?.surface.sampleChannel(x: x, y: y, 0) ?? -1 }

    func alphaAt(_ s: Session, _ x: Int32, _ y: Int32) -> Float { active(s)?.surface?.pixel(x: x, y: y)[3] ?? -1 }

    @Test func linkedRasterMaskMovesWithThePixels() throws {
        let s = try masked([rect(10, 10, 20, 20)], linked: true)
        try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 40, 50]])
        #expect(activeBounds(s) == rect(50, 60, 70, 70))
        #expect(maskAt(s, 55, 65) < 0.01, "the hidden half moved with the pixels")
        #expect(maskAt(s, 65, 65) > 0.99)
        #expect(maskAt(s, 15, 15) > 0.99, "nothing hidden left behind")
    }

    @Test func linkedMaskWithASelectionMovesOnlyTheSelectedRegion() throws {
        // The selection covers the left half of the red rect; the mask hides its left quarter
        // (selected) and its right quarter (not selected).
        let s = try masked([rect(10, 10, 15, 20), rect(25, 10, 30, 20)], linked: true)
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 10])
        try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 0, 50]])
        // Moved pixels and their mask line up.
        #expect(alphaAt(s, 12, 65) == 1)
        #expect(maskAt(s, 12, 65) < 0.01, "selected hidden quarter moved")
        #expect(maskAt(s, 17, 65) > 0.99, "selected visible quarter moved")
        // The vacated area reads as revealed (default), with transparent pixels.
        #expect(alphaAt(s, 12, 15) == 0)
        #expect(maskAt(s, 12, 15) > 0.99)
        // The unselected part of the mask stays, aligned with the unselected pixels.
        #expect(alphaAt(s, 27, 15) == 1)
        #expect(maskAt(s, 27, 15) < 0.01, "unselected mask stays put")
        #expect(maskAt(s, 27, 65) > 0.99, "and isn't copied along")
        // Every pixel's mask value is where it was relative to the pixel.
        for (x, y) in [(11, 61), (14, 69), (15, 61), (19, 69)] as [(Int32, Int32)] {
            let want: Float = x < 15 ? 0 : 1
            #expect(abs(maskAt(s, x, y) - want) < 0.01, "(\(x),\(y))")
        }
    }

    @Test func unlinkedMaskStaysPut() throws {
        var s = try masked([rect(10, 10, 20, 20)], linked: false)
        try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 40, 50]])
        #expect(activeBounds(s) == rect(50, 60, 70, 70))
        #expect(maskAt(s, 15, 15) < 0.01)
        #expect(maskAt(s, 55, 65) > 0.99)
        // With a selection too.
        s = try masked([rect(10, 10, 20, 20)], linked: false)
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 10])
        try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 0, 50]])
        #expect(maskAt(s, 15, 15) < 0.01 && maskAt(s, 15, 65) > 0.99)
    }

    @Test func targetedUnlinkedMaskTransformsAlone() throws {
        let s = try masked([rect(10, 10, 20, 20)], linked: false)
        try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 40, 50], "target": "mask"])
        #expect(activeBounds(s) == rect(10, 10, 30, 20), "pixels untouched")
        #expect(maskAt(s, 55, 65) < 0.01, "mask moved")
        #expect(maskAt(s, 15, 15) > 0.99, "vacated area reads as the default")
        s.undo()
        #expect(maskAt(s, 15, 15) < 0.01, "one undo step")
        // With a selection, only its part of the mask.
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 5, "height": 10])
        try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 0, 50], "target": "mask"])
        #expect(maskAt(s, 12, 65) < 0.01 && maskAt(s, 12, 15) > 0.99)
        #expect(maskAt(s, 17, 15) < 0.01, "unselected mask stays")
        #expect(activeBounds(s) == rect(10, 10, 30, 20), "pixels untouched")
    }

    @Test func targetedLinkedMaskMovesWithItsLayer() throws {
        // Photoshop: a linked mask can't move without its layer.
        let s = try masked([rect(10, 10, 20, 20)], linked: true)
        try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 40, 50], "target": "mask"])
        #expect(activeBounds(s) == rect(50, 60, 70, 70))
        #expect(maskAt(s, 55, 65) < 0.01)
    }

    @Test func targetedAlphaChannelTransformsAlone() throws {
        let s = try session()
        try s.execute("channel.new")
        try s.edit("paint channel") { doc, _ in doc.channels[0].surface.fill(rect(10, 10, 20, 20), with: [1]) }
        try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 40, 50], "target": ["channel": 0]])
        let ch = try #require(s.active?.doc.channels.first?.surface)
        #expect(ch.sampleChannel(x: 55, y: 65, 0) > 0.99 && ch.sampleChannel(x: 15, y: 15, 0) < 0.01)
        #expect(activeBounds(s) == rect(10, 10, 30, 20), "layer untouched")
    }

    /// The Channels panel targets an alpha channel: Edit › Transform › Flip Horizontal and a 50%
    /// `edit.transform` (no `target` param) work on the channel, not the layer (BUG-207-4).
    @Test func transformsFollowTheTargetedAlphaChannel() throws {
        let s = try session()
        try s.execute("channel.new")
        try s.edit("paint channel") { doc, _ in
            doc.channels[0].surface.fill(rect(10, 10, 20, 20), with: [1])
            doc.channels[0].surface.fill(rect(10, 10, 12, 20), with: [0.5])
        }
        try s.execute("channel.target", ["channel": 0])
        let full = rect(0, 0, 100, 100)
        func layer() -> [Float] { active(s)?.surface?.readRegion(full) ?? [] }
        let pixels = layer()
        let past = s.active?.history.pastCount ?? 0
        try s.execute("edit.transform.flipHorizontal")
        // 8-bit channel: 0.5 is stored as 128/255.
        func ch(_ x: Int32, _ y: Int32) -> Float { ((s.active?.doc.channels[0].surface.sampleChannel(x: x, y: y, 0) ?? -1) * 10).rounded() / 10 }
        #expect((ch(19, 15), ch(10, 15)) == (0.5, 1), "the channel flips within its frame")
        #expect(layer() == pixels, "the layer is untouched")
        #expect(s.active?.history.pastCount == past + 1, "one undo step")
        try s.execute("edit.transform", ["matrix": [0.5, 0, 0, 0.5, 0, 0], "interpolation": "nearest"])
        #expect((ch(7, 7), ch(15, 15)) == (1, 0), "the channel scales to 50%")
        #expect(layer() == pixels, "the layer is untouched")
        s.undo()
        s.undo()
        #expect((ch(10, 15), ch(19, 15)) == (0.5, 1))
    }

    @Test func transformTargetsFailGracefully() throws {
        var s = try session()
        let mtx: JSONValue = [1, 0, 0, 1, 5, 5]
        #expect(throws: (any Error).self, "no mask") { try s.execute("edit.transform", ["matrix": mtx, "target": "mask"]) }
        #expect(throws: (any Error).self) { try s.execute("edit.transform", ["matrix": mtx, "target": ["channel": 9]]) }
        #expect(throws: (any Error).self) { try s.execute("edit.transform", ["matrix": mtx, "target": "quickMask"]) }
        // Unknown target shapes fall back to the pixels.
        try s.execute("edit.transform", ["matrix": mtx, "target": 7])
        try s.execute("edit.transform", ["matrix": mtx, "target": ["channel": "x"]])
        // Selections that miss the mask entirely transform nothing, without trapping.
        s = try masked([rect(10, 10, 20, 20)], linked: false)
        try s.execute("select.rect", ["x": 80, "y": 80, "width": 5, "height": 5])
        _ = try? s.execute("edit.transform", ["matrix": [1e9, 0, 0, 1e9, 0, 0], "target": "mask"])
        _ = try? s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 1e12, 0], "target": "mask"])
    }

    @Test func splitGraySelectedRejectsNonGray() {
        let surf = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: true))
        var sel = Surface(format: PixelFormat(mode: .grayscale, sample: .u8, alpha: false))
        sel.fill(rect(0, 0, 4, 4), with: [1])
        #expect(TransformCommands.splitGraySelected(surf, sel) == nil)
    }

    /// #2630: type can't be partly transformed, so a selection doesn't narrow the frame: Free
    /// Transform (and the frame-based presets) act on the whole type layer.
    @Test func aSelectionDoesNotNarrowATypeLayersFrame() throws {
        var s = Session()
        try s.execute("file.new", ["width": 200, "height": 120])
        try s.execute("type.create", ["x": 20, "y": 60, "text": "Hello", "size": 36])
        let whole = activeBounds(s)
        try s.execute("select.rect", ["x": .int(Int(whole.x0)), "y": .int(Int(whole.y0)), "width": .int(whole.width / 2), "height": .int(whole.height)])
        let doc = try #require(s.active?.doc)
        #expect(TransformCommands.transformBounds(doc, try #require(active(s))) == whole, "the frame is the whole type layer")
        // Corners of the frame moved 10 px right: a pure translation of the whole text.
        let (x0, y0, x1, y1) = (Double(whole.x0) + 10, Double(whole.y0), Double(whole.x1) + 10, Double(whole.y1))
        try s.execute("edit.transform", ["quad": [[.number(x0), .number(y0)], [.number(x1), .number(y0)], [.number(x1), .number(y1)], [.number(x0), .number(y1)]]])
        let moved = activeBounds(s)
        #expect(abs(Int(moved.x0) - Int(whole.x0) - 10) <= 1 && abs(moved.width - whole.width) <= 1, "\(whole) -> \(moved)")
        // Rotate 180° turns it about its own centre, not the selection's.
        try s.execute("edit.transform.rotate180")
        let turned = activeBounds(s)
        #expect(abs(Int(turned.x0) - Int(moved.x0)) <= 2 && abs(Int(turned.x1) - Int(moved.x1)) <= 2, "\(moved) -> \(turned)")
        // A pixel layer still frames only the selected pixels.
        s = try session()
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 5, "height": 10])
        #expect(TransformCommands.transformBounds(try #require(s.active?.doc), try #require(active(s))) == rect(10, 10, 15, 20))
    }

    @Test func featheredSelectionIdentityTransformPreservesPixels() throws {
        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 16, "background": "transparent"])
        try s.execute("edit.fill", ["color": "#ff0000"])
        try s.execute("select.rect", ["x": 4, "y": 4, "width": 8, "height": 8])
        try s.execute("select.modify.feather", ["radius": 1])
        func all() throws -> [JSONValue] {
            var out: [JSONValue] = []
            for y in 0..<16 { for x in 0..<16 { out.append(try s.execute("document.pixel", ["x": .int(x), "y": .int(y)])) } }
            return out
        }
        let before = try all()
        try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 0, 0], "interpolation": "nearest"])
        #expect(try all() == before, "feathered selection identity transform must preserve all pixels")
        #expect(try s.execute("document.pixel", ["x": 4, "y": 8]) == [1.0, 0.0, 0.0, 1.0], "(4,8) must remain opaque red")
        // Undo restores the original document.
        try s.execute("edit.undo")
        #expect(try s.execute("document.pixel", ["x": 4, "y": 8]) == [1.0, 0.0, 0.0, 1.0])
        // A locked layer still refuses the transform, even an identity one.
        try s.execute("layer.setProps", ["locks": ["position": true]])
        #expect(throws: (any Error).self, "locked layer refuses identity transform") {
            try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 0, 0]])
        }
    }

    // MARK: Added

    /// A smart object keeps the transform in its placement; without a renderable source (no PCIO)
    /// its cached pixels move (extra_cmds' "transformed smart object" case: rasterized, the
    /// moved pixels stay).
    @Test func smartObjectsTransformByPlacementAndCache() throws {
        let s = try session()
        let id = try #require(s.active?.activeLayer)
        try s.edit("smart") { doc, _ in
            doc.updateLayer(id) { l in
                guard let surf = l.surface else { return }
                l.content = .smart(SmartObject(source: .embedded(fileName: "x.png", bytes: []), transform: .identity, cache: surf))
            }
        }
        try s.execute("edit.transform", ["matrix": [1, 0, 0, 1, 10, 10]])
        guard case .smart(let sm)? = active(s)?.content else { Issue.record("still a smart object"); return }
        #expect(sm.transform == PCAffine.translate(10, 10) && sm.perspective == nil)
        #expect(activeBounds(s) == rect(20, 20, 40, 30))
        // Distort keeps the projective map.
        try s.execute("edit.transform", ["quad": [[22, 20], [38, 20], [40, 30], [20, 30]]])
        guard case .smart(let sm2)? = active(s)?.content else { Issue.record("still a smart object"); return }
        #expect(sm2.perspective?.count == 9)
        try s.execute("layer.rasterize.smartObject")
        guard case .raster(let px)? = active(s)?.content else { Issue.record("rasterized"); return }
        #expect(px.pixel(x: 30, y: 25) == [1, 0, 0, 1])
    }

    @Test func idsMatchPhotocraft() throws {
        let s = Session()
        for id in ["edit.transform"] {
            let spec = try #require(s.registry.spec(id))
            let pc = try #require(PhotocraftCatalog.byId[id])
            #expect(spec.isAvailable)
            #expect(spec.module == pc.module && spec.label == pc.label && spec.menu == pc.menu && spec.shortcut == pc.shortcut && spec.params == pc.params, "\(id)")
        }
    }
}
