// Port of photocraft-engine (crates/engine/src/layer_multi_cmds.rs, `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Multi-layer selection, Align / Distribute, Link / Merge / Group / Reverse / Lock Layers and the
// damage (recomposite area) of moves, inserts and their undo — ported one for one, driven through
// `s.execute` as the Rust tests are. photocraft's `step_damage` is PCEngine's
// `TransactionBuilder.damage` of the step's transaction; `photocraft_compose::render` is the
// session's `EngineRenderer`.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCRender
import Testing

/// A 100×80 document of `depth` bits per channel.
fileprivate func session(_ depth: Int) throws -> Session {
    let s = Session()
    try s.execute("file.new", ["width": 100, "height": 80, "depth": .int(depth)])
    return s
}

fileprivate func doc(_ s: Session) throws -> Document { try #require(s.active).doc }

fileprivate func rect(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> PixelRect { PixelRect(x0: x0, y0: y0, x1: x1, y1: y1) }

/// New pixel layer with an opaque red rectangle.
fileprivate func rectLayer(_ s: Session, _ r: PixelRect) throws -> LayerId {
    let id = try layerResult(try s.execute("layer.new.layer"))
    try fill(s, id, r, [1, 0, 0, 1])
    return id
}

/// Fills `r` of layer `id`'s pixels with the raw components `c`, as one step.
fileprivate func fill(_ s: Session, _ id: LayerId, _ r: PixelRect, _ c: [Float], label: String = "paint") throws {
    try s.edit(label) { doc, _ in
        guard doc.withRaster(of: id, { $0.fill(r, with: c) }) != nil else { throw EngineError.noLayer(id) }
    }
}

fileprivate func bounds(_ s: Session, _ id: LayerId) throws -> PixelRect? { LayerOps.layerBounds(try #require(try doc(s).layer(id))) }

fileprivate func sel(_ s: Session) -> [LayerId] { LayerMulti.selected(s) }

/// The active document's last damage (nil = recomposite everything).
fileprivate func damage(_ s: Session) -> PixelRect? {
    guard let st = s.active else {
        Issue.record("no document")
        return nil
    }
    return st.lastDamage
}

fileprivate func render(_ s: Session, _ d: Document) throws -> RGBABuffer { try s.services.renderer.render(d, region: d.bounds) }

fileprivate func composite(_ s: Session) throws -> RGBABuffer { try render(s, try doc(s)) }

/// photocraft `step_damage(a, b)`: the damage of the step turning `a` into `b`.
fileprivate func stepDamage(_ a: Document, _ b: Document) -> PixelRect? {
    TransactionBuilder.damage(TransactionBuilder.transaction("step", from: a, to: b), before: a, after: b)
}

/// The composite of `after` equals `before`'s outside `damage`.
fileprivate func unchangedOutside(_ s: Session, _ before: Document, _ after: Document, _ damage: PixelRect) throws -> Bool {
    let (x, y) = (try render(s, before), try render(s, after))
    let w = before.bounds.width
    return zip(x.px, y.px).enumerated().allSatisfy { i, pq in pq.0 == pq.1 || damage.contains(x: Int32(i % w), y: Int32(i / w)) }
}

fileprivate func selectAll(_ s: Session, _ ids: [LayerId]) throws {
    try s.execute("layer.select", ["layer": .id(ids[0])])
    for id in ids.dropFirst() { try s.execute("layer.select", ["layer": .id(id), "mode": "toggle"]) }
}

/// Plain layers carrying stored link groups, as a loaded `.pcraft` or PSD can hold (#961).
fileprivate func storedGroups(_ s: Session, _ groups: [UInt64?]) throws -> [LayerId] {
    let ids = try groups.map { _ in try rectLayer(s, rect(0, 0, 4, 4)) }
    try s.edit("load groups") { doc, _ in
        for (id, g) in zip(ids, groups) { _ = doc.updateLayer(id) { $0.linkGroup = g } }
    }
    return ids
}

fileprivate func group(_ s: Session, _ id: LayerId) throws -> UInt64? { try #require(try doc(s).layer(id)).linkGroup }

/// Links `ids`, then checks they share one group no other layer uses (#961).
fileprivate func linkFresh(_ s: Session, _ ids: [LayerId]) throws -> UInt64 {
    try selectAll(s, ids)
    let past = pastCount(s)
    #expect(try s.execute("layer.linkLayers")["linked"] == true)
    #expect(pastCount(s) == past + 1)
    let g = try #require(try group(s, ids[0]), "linked")
    #expect(try ids.allSatisfy { try group(s, $0) == g })
    let members = try doc(s).walk().filter { $0.layer.linkGroup == g }.count
    #expect(members == ids.count, "group \(g) is shared with unselected layers")
    return g
}

/// The tiles of layer `id`'s surface: coordinate and the address of their (copy-on-write) bytes.
fileprivate func tiles(_ s: Session, _ id: LayerId) throws -> [String] {
    let surf = try #require(try doc(s).layer(id)?.surface)
    return surf.tileCoords.map { c in
        let addr = surf.tile(c)?.bytes.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) } ?? 0
        return "\(c.tx),\(c.ty)@\(addr)"
    }
}

@Suite struct LayerMultiTests {
    @Test func duplicatesAreNumberedNotStacked() throws {
        let s = Session()
        try s.execute("file.new", ["width": 20, "height": 20])
        try s.execute("layer.new.layer", ["name": "Layer 1"])
        func name() throws -> String {
            let st = try #require(s.active)
            let id = try #require(st.activeLayer)
            return try #require(st.doc.layer(id)).name
        }
        try s.execute("layer.duplicate")
        #expect(try name() == "Layer 1 copy")
        // Duplicating the copy (the active layer) numbers it rather than adding "copy" again.
        try s.execute("layer.duplicate")
        #expect(try name() == "Layer 1 copy 2")
        try s.execute("layer.duplicate")
        #expect(try name() == "Layer 1 copy 3")
        let d = try doc(s)
        #expect(d.copyName("Layer 1") == "Layer 1 copy 4")
        // Names that merely contain "copy" keep it.
        #expect(d.copyName("Copywriting") == "Copywriting copy")
        #expect(d.copyName("A copyedit") == "A copyedit copy")
    }

    /// A layer with a reveal-nothing mask holding a white square at (12, 12)–(18, 18).
    private func maskedLayer(_ s: Session) throws -> LayerId {
        let a = try rectLayer(s, rect(10, 10, 20, 20))
        try s.execute("layer.select", ["layer": .id(a)])
        try s.execute("layer.layerMask.hideAll")
        try s.edit("mask") { doc, _ in
            _ = try doc.updateLayer(a) { l in
                guard var m = l.mask else { throw EngineError.other("no mask") }
                m.surface.fill(rect(12, 12, 18, 18), with: [1])
                l.mask = m
            }
        }
        return a
    }

    private func mval(_ s: Session, _ a: LayerId, _ x: Int32, _ y: Int32) throws -> Float {
        try #require(try doc(s).layer(a)?.mask).surface.sampleChannel(x: x, y: y, 0)
    }

    /// A mask with its chain off stays put while the layer moves; a linked one moves along.
    @Test func translateLeavesAnUnlinkedMaskInPlace() throws {
        for depth in [8, 16] {
            let s = try session(depth)
            let a = try maskedLayer(s)
            try s.execute("layer.layerMask.linked", ["linked": false])
            try s.execute("layer.translate", ["dx": 30, "dy": 0])
            #expect(try mval(s, a, 14, 14) > 0.9, "\(depth)-bit: unlinked mask stays")
            #expect(try mval(s, a, 44, 14) < 0.1)
            try s.execute("edit.undo")
            try s.execute("layer.layerMask.linked", ["linked": true])
            try s.execute("layer.translate", ["dx": 30, "dy": 0])
            #expect(try mval(s, a, 44, 14) > 0.9, "\(depth)-bit: linked mask moves")
        }
    }

    /// Aimed at the mask, a move shifts an unlinked mask alone and leaves a linked one with its layer.
    @Test func translateWithTheMaskTargetedMovesAnUnlinkedMaskAlone() throws {
        for depth in [8, 16] {
            let s = try session(depth)
            let a = try maskedLayer(s)
            // Linked: the layer and its mask move together.
            try s.execute("layer.translate", ["dx": 30, "dy": 0, "target": "mask"])
            #expect(try bounds(s, a) == rect(40, 10, 50, 20), "\(depth)-bit")
            #expect(try mval(s, a, 44, 14) > 0.9)
            try s.execute("layer.layerMask.linked", ["linked": false])
            try s.execute("layer.translate", ["dx": -30, "dy": 0, "target": "mask"])
            #expect(try bounds(s, a) == rect(40, 10, 50, 20), "\(depth)-bit: the layer stays")
            #expect(try mval(s, a, 14, 14) > 0.9, "the mask moved")
            #expect(try mval(s, a, 44, 14) < 0.1)
            try s.execute("edit.undo")
            #expect(try mval(s, a, 44, 14) > 0.9, "undo puts the mask back")
        }
    }

    @Test func movesAndLayerPropsReportOnlyTheirArea() throws {
        let s = try session(8)
        let a = try rectLayer(s, rect(10, 10, 20, 20))
        try s.execute("layer.select", ["layer": .id(a)])
        try s.execute("layer.translate", ["dx": 5, "dy": -3])
        #expect(damage(s) == rect(10, 7, 25, 20), "where the layer was and is")
        try s.execute("layer.setProps", ["layer": .id(a), "visible": false])
        #expect(damage(s) == rect(15, 7, 25, 17))
        try s.execute("layer.setProps", ["layer": .id(a), "opacity": 0.5, "blend": "Multiply"])
        #expect(damage(s) == rect(15, 7, 25, 17))
        // Clipping changes reach the layers around: everything.
        try s.execute("layer.setProps", ["layer": .id(a), "clipped": true])
        #expect(damage(s) == nil)
        // An adjustment layer changes everything beneath it.
        let adj = try layerResult(try s.execute("layer.newAdjustmentLayer.invert"))
        try s.execute("layer.setProps", ["layer": .id(adj), "visible": false])
        #expect(damage(s) == nil)
        // The Background (opaque everywhere): everything.
        let bg = try doc(s).layers[0].id
        try s.execute("layer.setProps", ["layer": .id(bg), "opacity": 0.5])
        let all = try doc(s).bounds
        let d = damage(s)
        #expect(d.map { $0.contains(all) } ?? true, "\(String(describing: d))")
        // Bad params still fail cleanly.
        #expect(throws: (any Error).self) { try s.execute("layer.setProps", ["layer": 999_999, "visible": true]) }
        #expect(throws: (any Error).self) { try s.execute("layer.translate", ["layer": 999_999, "dx": 1]) }
    }

    /// #1771: a new empty layer or group changes no pixels, so it (and undoing or redoing it)
    /// must not make the canvas recomposite every layer of the document.
    @Test func newEmptyLayersAndGroupsDamageNothing() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let a = try rectLayer(s, rect(10, 10, 20, 20))
            let shown = try composite(s)
            try s.execute("layer.new.layer")
            #expect(damage(s) == PixelRect.empty, "\(depth)-bit new layer")
            #expect(try composite(s) == shown, "an empty layer changes no pixels")
            try s.execute("edit.undo")
            #expect(damage(s) == PixelRect.empty, "\(depth)-bit undo New Layer")
            try s.execute("edit.redo")
            #expect(damage(s) == PixelRect.empty, "\(depth)-bit redo New Layer")
            try s.execute("layer.new.group")
            #expect(damage(s) == PixelRect.empty, "\(depth)-bit new group")
            // Inside a group too.
            let child = try layerResult(try s.execute("layer.new.layer"))
            let g = try layerResult(try s.execute("layer.groupLayers"))
            try s.execute("layer.select", ["layer": .id(child)])
            try s.execute("layer.new.layer")
            #expect(damage(s) == PixelRect.empty, "\(depth)-bit new layer in a group")
            #expect(try doc(s).layer(g)?.children?.count == 2)
            try s.execute("edit.undo")
            #expect(damage(s) == PixelRect.empty)
            // Undoing a step that painted still reports that area, not nothing.
            try s.execute("layer.select", ["layer": .id(a)])
            try s.execute("layer.translate", ["dx": 5, "dy": 0])
            try s.execute("edit.undo")
            #expect(damage(s) == rect(10, 10, 25, 20))
        }
    }

    @Test func newLayersThatChangeClippingRecompositeEverything() throws {
        let s = try session(8)
        let base = try rectLayer(s, rect(10, 10, 20, 20))
        let clipped = try rectLayer(s, rect(0, 0, 100, 80))
        try fill(s, clipped, rect(0, 0, 100, 80), [0, 1, 0, 1], label: "green")
        try s.execute("layer.setProps", ["layer": .id(clipped), "clipped": true])
        // New Layer between a clipping base and its clipped layer joins their clip group (#2203),
        // so it draws nothing; an empty layer there that stayed unclipped would become their base.
        try s.execute("layer.select", ["layer": .id(base)])
        let shown = try composite(s)
        var before = try doc(s)
        try s.execute("layer.new.layer")
        #expect(damage(s) == PixelRect.empty)
        #expect(try composite(s) == shown)
        var split = before
        _ = split.insertAbove(base, Layer.raster("split", format: split.pixelFormat))
        #expect(try render(s, split) != shown)
        #expect(stepDamage(before, split) == nil)
        #expect(stepDamage(split, before) == nil)
        try s.execute("edit.undo")
        // A step that adds a layer with pixels (Layer via Copy, paste…) changes where it draws.
        before = try doc(s)
        var after = before
        var l = Layer.raster("painted", format: after.pixelFormat)
        _ = l.withRaster { $0.fill(rect(1, 1, 2, 2), with: [0, 1, 0, 1]) }
        _ = after.insertAbove(nil, l)
        #expect(stepDamage(before, after) == rect(1, 1, 2, 2))
        #expect(stepDamage(after, before) == rect(1, 1, 2, 2))
        // Unless it becomes the base of clipped layers above it.
        var based = before
        var b = Layer.raster("base", format: based.pixelFormat)
        _ = b.withRaster { $0.fill(rect(1, 1, 2, 2), with: [0, 1, 0, 1]) }
        let under = try #require(based.layers.firstIndex { $0.id == clipped })
        based.layers.insert(b, at: under)
        #expect(stepDamage(before, based) == nil)
        #expect(stepDamage(based, before) == nil)
        // An adjustment reaches every pixel below it.
        var adjusted = before
        _ = adjusted.insertAbove(nil, Layer(name: "inv", content: .adjustment(.invert)))
        #expect(stepDamage(before, adjusted) == nil)
        #expect(stepDamage(adjusted, before) == nil)
        // Empty layers draw nothing, in any blend mode.
        var styled = before
        var m = Layer.raster("styled", format: styled.pixelFormat)
        m.blend = .multiply
        _ = styled.insertAbove(nil, m)
        #expect(stepDamage(before, styled) == PixelRect.empty)
        var plain = before
        _ = plain.insertAbove(nil, Layer.raster("plain", format: plain.pixelFormat))
        #expect(stepDamage(before, plain) == PixelRect.empty)
        #expect(stepDamage(plain, before) == PixelRect.empty)
    }

    /// #2883 (P8/P9): a duplicate shares the source's tiles (no pixel copy) and recomposites only
    /// where it draws; undo brings back exactly the old pixels. A copy that becomes the clipping
    /// base of the layers above still recomposites everything.
    @Test func duplicateSharesTilesAndDamagesOnlyTheCopy() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let a = try rectLayer(s, rect(10, 10, 20, 20))
            try s.execute("layer.setProps", ["layer": .id(a), "opacity": 0.5])
            let shown = try composite(s)
            let copy = try layerResult(try s.execute("layer.duplicate", ["layer": .id(a)]))
            #expect(damage(s) == rect(10, 10, 20, 20), "\(depth)-bit: only where the copy draws")
            #expect(try !tiles(s, a).isEmpty)
            #expect(try tiles(s, copy) == tiles(s, a), "\(depth)-bit: the copy shares the source's tiles")
            let now = try composite(s)
            #expect(now != shown, "the half-transparent copy darkens its area")
            let w = shown.rect.width
            let outside = zip(shown.px, now.px).enumerated().filter { i, pq in
                !rect(10, 10, 20, 20).contains(x: Int32(i % w), y: Int32(i / w)) && pq.0 != pq.1
            }.map(\.offset)
            #expect(outside.isEmpty, "\(depth)-bit: pixels \(outside.prefix(8)) outside the damage changed")
            try s.execute("edit.undo")
            #expect(try doc(s).layer(copy) == nil)
            #expect(try composite(s) == shown)
            // A clipping base's copy goes between it and its clipped layer and becomes their base.
            let clipped = try rectLayer(s, rect(0, 0, 50, 50))
            try s.execute("layer.setProps", ["layer": .id(clipped), "clipped": true])
            try s.execute("layer.duplicate", ["layer": .id(a)])
            #expect(damage(s) == nil, "\(depth)-bit: a new clipping base")
        }
    }

    /// Duplicate, paste and delete, and their undo and redo, recomposite only where the layer
    /// draws; undoing a duplicate used to recomposite the whole document.
    @Test func duplicatePasteAndDeleteReportWhereTheLayerDraws() throws {
        let s = try session(8)
        let a = try rectLayer(s, rect(10, 10, 20, 20))
        let full = try doc(s).bounds
        func step(_ id: String, _ p: JSONValue) throws {
            let before = try doc(s)
            try s.execute(id, p)
            let d = try #require(damage(s), "\(id): unbounded damage")
            #expect(d.width < full.width, "\(id): \(d)")
            #expect(try unchangedOutside(s, before, doc(s), d), "\(id): pixels changed outside \(d)")
            try s.execute("edit.undo")
            #expect(damage(s) == d, "undo \(id)")
            try s.execute("edit.redo")
            #expect(damage(s) == d, "redo \(id)")
        }
        try step("layer.duplicate", ["layer": .id(a)])
        try s.execute("layer.select", ["layer": .id(a)])
        try s.execute("select.rect", ["x": 12, "y": 12, "width": 4, "height": 4])
        try s.execute("edit.copy")
        try s.execute("select.deselect")
        try step("edit.paste", [:])
        try step("layer.delete", ["layer": .id(a)])
    }

    @Test func theMovePreviewMatchesTheMove() throws {
        let s = try session(8)
        let a = try rectLayer(s, rect(10, 10, 20, 20))
        let before = try doc(s)
        let ids = LayerMulti.moveTargets(before, [a])
        let shown = try LayerMulti.moved(before, ids, 7, 4)
        try s.execute("layer.translate", ["layer": .id(a), "dx": 7, "dy": 4])
        let want = try bounds(s, a)
        #expect(shown.layer(a).flatMap(LayerOps.layerBounds) == want)
        // Locked layers don't move in the preview either.
        var locked = before
        _ = locked.updateLayer(a) { $0.locks.position = true }
        #expect(throws: (any Error).self) { try LayerMulti.moved(locked, ids, 1, 1) }
        #expect(throws: (any Error).self) { try LayerMulti.moved(before, [LayerId(999_999)], 1, 1) }
    }

    @Test func toggleAndRangeSelection() throws {
        let s = try session(8)
        let a = try rectLayer(s, rect(0, 0, 5, 5))
        let b = try rectLayer(s, rect(0, 0, 5, 5))
        let c = try rectLayer(s, rect(0, 0, 5, 5))
        let d = try rectLayer(s, rect(0, 0, 5, 5))
        #expect(sel(s) == [d])
        try s.execute("layer.select", ["layer": .id(b), "mode": "toggle"])
        #expect(sel(s) == [b, d])
        #expect(s.active?.activeLayer == b)
        // Toggling the active layer off hands "active" to a remaining member.
        try s.execute("layer.select", ["layer": .id(b), "mode": "toggle"])
        #expect(sel(s) == [d])
        #expect(s.active?.activeLayer == d)
        // The last selected layer can't be toggled off.
        try s.execute("layer.select", ["layer": .id(d), "mode": "toggle"])
        #expect(sel(s) == [d])
        // Range from the anchor (a) to c.
        try s.execute("layer.select", ["layer": .id(a)])
        try s.execute("layer.select", ["layer": .id(c), "mode": "range"])
        #expect(sel(s) == [a, b, c])
        // A second ⇧-click re-ranges from the same anchor.
        try s.execute("layer.select", ["layer": .id(b), "mode": "range"])
        #expect(sel(s) == [a, b])
        #expect(throws: (any Error).self) { try s.execute("layer.select", ["layer": .id(b), "mode": "bogus"]) }
        // Selection changes are not edits.
        let history = try #require(s.active).history.entries.count
        try s.execute("select.allLayers")
        #expect(sel(s) == [a, b, c, d], "Select All Layers skips the locked Background")
        try s.execute("select.deselectLayers")
        #expect(sel(s).isEmpty)
        #expect(s.active?.history.entries.count == history)
        // Nothing selected: a no-op, not an error (#2457).
        try s.execute("select.deselectLayers")
        #expect(s.active?.history.entries.count == history)
        // An explicit layer needs no active layer.
        try s.execute("layer.hideLayers", ["layer": .id(a)])
        #expect(try doc(s).layer(a)?.visible == false)
        try s.execute("layer.renameLayer", ["layer": .id(a), "name": "x"])
        #expect(try doc(s).layer(a)?.name == "x")
        try s.execute("layer.showLayers", ["layer": .id(a)])
        #expect(try doc(s).layer(a)?.visible == true)
        #expect(throws: (any Error).self) { try s.execute("layer.hideLayers", ["layer": 999_999]) }
        #expect(throws: (any Error).self) { try s.execute("layer.hideLayers") }
        #expect(!s.isEnabled("layer.align.topEdges"))
    }

    @Test func findLayersByName() throws {
        let s = try session(8)
        let a = try rectLayer(s, rect(0, 0, 5, 5))
        let b = try rectLayer(s, rect(0, 0, 5, 5))
        try s.execute("layer.renameLayer", ["layer": .id(a), "name": "Sky photo"])
        try s.execute("layer.renameLayer", ["layer": .id(b), "name": "Photo of sea"])
        #expect(try doc(s).layer(a)?.name == "Sky photo")
        let r = try s.execute("select.findLayers", ["name": "PHOTO"])
        #expect(r["selected"] == .ids([a, b]))
        #expect(throws: (any Error).self) { try s.execute("select.findLayers", ["name": "nothing"]) }
        #expect(throws: (any Error).self) { try s.execute("layer.renameLayer") }
    }

    @Test func renameLayerKeepsSurroundingSpaces() throws {
        let s = try session(8)
        let a = try rectLayer(s, rect(0, 0, 5, 5))
        try s.execute("layer.renameLayer", ["layer": .id(a), "name": " black skin bw "])
        #expect(try doc(s).layer(a)?.name == " black skin bw ")
        #expect(throws: (any Error).self) { try s.execute("layer.renameLayer", ["layer": .id(a), "name": "   "]) }
        #expect(try doc(s).layer(a)?.name == " black skin bw ")
    }

    @Test func alignEachEdge() throws {
        for depth in [8, 16, 32] {
            let cases: [(String, [PixelRect])] = [
                ("topEdges", [rect(10, 5, 20, 15), rect(40, 5, 50, 25)]),
                ("bottomEdges", [rect(10, 20, 20, 30), rect(40, 10, 50, 30)]),
                // Union 5..30: centre 17.5; half-pixel offsets round towards the top.
                ("verticalCenters", [rect(10, 12, 20, 22), rect(40, 7, 50, 27)]),
                ("leftEdges", [rect(10, 5, 20, 15), rect(10, 10, 50, 30)]),
                ("rightEdges", [rect(40, 5, 50, 15), rect(10, 10, 50, 30)]),
                ("horizontalCenters", [rect(25, 5, 35, 15), rect(10, 10, 50, 30)]),
            ]
            for (kind, want) in cases {
                let s = try session(depth)
                let a = try rectLayer(s, rect(10, 5, 20, 15))
                let b = try rectLayer(s, rect(40, 10, 50, 30))
                // For the horizontal cases make b wide so it defines the target bounds.
                if !["topEdges", "bottomEdges", "verticalCenters"].contains(kind) {
                    try fill(s, b, rect(10, 10, 50, 30), [0, 1, 0, 1], label: "wide")
                }
                try selectAll(s, [a, b])
                try s.execute("layer.align.\(kind)")
                #expect([try bounds(s, a), try bounds(s, b)] == want.map { Optional($0) }, "\(kind) at \(depth)-bit")
                // Pixels moved, not just bounds.
                let r = want[0]
                let surf = try #require(try doc(s).layer(a)?.surface)
                #expect(Array(surf.pixel(x: r.x0, y: r.y0).prefix(4)) == [1, 0, 0, 1])
                // One undo restores the original positions.
                s.undo()
                #expect(try bounds(s, a) == rect(10, 5, 20, 15))
            }
        }
    }

    @Test func alignSingleLayerToSelection() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let a = try rectLayer(s, rect(10, 10, 20, 20))
            #expect(s.isEnabled("layer.align.leftEdges"), "one layer aligns to the canvas")
            try s.execute("select.rect", ["x": 50, "y": 40, "width": 30, "height": 30])
            #expect(s.isEnabled("layer.align.leftEdges"))
            try s.execute("layer.align.rightEdges")
            #expect(try bounds(s, a) == rect(70, 10, 80, 20))
            try s.execute("layer.align.verticalCenters")
            #expect(try bounds(s, a) == rect(70, 50, 80, 60))
            try s.execute("layer.align.topEdges", ["to": "canvas"])
            #expect(try bounds(s, a) == rect(70, 0, 80, 10))
        }
    }

    @Test func alignSingleLayerToCanvas() throws {
        // Photoshop: a single selected layer with no active selection aligns to the canvas.
        let s = try session(8)   // 100 x 80
        let a = try rectLayer(s, rect(10, 10, 20, 20))   // 10 x 10
        #expect(s.isEnabled("layer.align.horizontalCenters"))
        try s.execute("layer.align.horizontalCenters")
        #expect(try bounds(s, a) == rect(45, 10, 55, 20), "centred on the 100px-wide canvas")
        try s.execute("layer.align.verticalCenters")
        #expect(try bounds(s, a) == rect(45, 35, 55, 45), "centred on the 80px-tall canvas")
        try s.execute("layer.align.leftEdges")
        #expect(try bounds(s, a) == rect(0, 35, 10, 45), "left edge to the canvas")
    }

    @Test func distributeUnevenLayers() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let a = try rectLayer(s, rect(0, 0, 10, 10))
            let b = try rectLayer(s, rect(12, 0, 32, 10))   // 20 wide
            let c = try rectLayer(s, rect(70, 0, 100, 10))   // 30 wide
            try selectAll(s, [a, b, c])
            // Undo targets the layers its state had when it was created (#495): reselect.
            #expect(s.isEnabled("layer.distribute.leftEdges"))
            try s.execute("layer.distribute.leftEdges")
            #expect(try bounds(s, b) == rect(35, 0, 55, 10), "left edges 0, 35, 70")
            s.undo()
            try selectAll(s, [a, b, c])
            try s.execute("layer.distribute.horizontalCenters")
            // centres 5 and 85 → middle centre 45
            #expect(try bounds(s, b) == rect(35, 0, 55, 10))
            s.undo()
            try selectAll(s, [a, b, c])
            try s.execute("layer.distribute.rightEdges")
            // right edges 10 and 100 → 55
            #expect(try bounds(s, b) == rect(35, 0, 55, 10))
            s.undo()
            try selectAll(s, [a, b, c])
            try s.execute("layer.distribute.horizontally")
            // span 100, widths 60 → gaps of 20: b at 30..50
            #expect(try bounds(s, b) == rect(30, 0, 50, 10))
            #expect(try bounds(s, a) == rect(0, 0, 10, 10))
            #expect(try bounds(s, c) == rect(70, 0, 100, 10))
            s.undo()
            #expect(try bounds(s, b) == rect(12, 0, 32, 10))
        }
        // Vertical: tall layers with uneven heights.
        let s = try session(8)
        let a = try rectLayer(s, rect(0, 0, 10, 10))
        let b = try rectLayer(s, rect(0, 50, 10, 54))
        let c = try rectLayer(s, rect(0, 60, 10, 80))
        try selectAll(s, [a, b, c])
        try s.execute("layer.distribute.vertically")
        // span 80, heights 34 → gaps 23: b at 33..37
        #expect(try bounds(s, b) == rect(0, 33, 10, 37))
        s.undo()
        try selectAll(s, [a, b, c])
        try s.execute("layer.distribute.topEdges")
        #expect(try bounds(s, b) == rect(0, 30, 10, 34))
        s.undo()
        try selectAll(s, [a, b, c])
        try s.execute("layer.distribute.bottomEdges")
        #expect(try bounds(s, b) == rect(0, 41, 10, 45))
        s.undo()
        try selectAll(s, [a, b, c])
        try s.execute("layer.distribute.verticalCenters")
        // centres 5 and 70 → 37.5, b is 4 tall → top 35.5 → rounds to 36 (35 for ties down)
        let y0 = try #require(try bounds(s, b)).y0
        #expect((35...36).contains(y0), "\(y0)")
        // Two layers can't be distributed.
        try selectAll(s, [a, b])
        #expect(!s.isEnabled("layer.distribute.leftEdges"))
    }

    @Test func mergeSelectedIntoTopMost() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let a = try rectLayer(s, rect(0, 0, 10, 10))
            let b = try rectLayer(s, rect(20, 0, 30, 10))
            let c = try rectLayer(s, rect(40, 0, 50, 10))
            try s.execute("layer.renameLayer", ["layer": .id(c), "name": "Top"])
            try selectAll(s, [a, c])
            let before = try doc(s).layerCount
            let m = try layerResult(try s.execute("layer.mergeLayers"))
            let d = try doc(s)
            #expect(d.layerCount == before - 1)
            let ml = try #require(d.layer(m))
            #expect(ml.name == "Top")
            #expect(LayerOps.layerBounds(ml) == rect(0, 0, 50, 10))
            let surf = try #require(ml.surface)
            #expect(Array(surf.pixel(x: 5, y: 5).prefix(4)) == [1, 0, 0, 1])
            #expect(surf.pixel(x: 25, y: 5)[3] == 0, "b was not merged")
            #expect(d.layer(b) != nil && d.layer(a) == nil)
            #expect(d.layers.last?.id == m, "merged layer sits where the top-most was")
            #expect(sel(s) == [m])
            s.undo()
            #expect(try doc(s).layerCount == before)
            #expect(sel(s) == [a, c], "undo selects the layers that were merged")
            // One layer selected: Merge Down.
            try s.execute("layer.select", ["layer": .id(c)])
            try s.execute("layer.mergeLayers")
            #expect(try doc(s).layerCount == before - 1)
        }
    }

    @Test func mergingGroupChildrenPreservesTheirComposite() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let lower = try rectLayer(s, rect(10, 12, 40, 42))
            let upper = try rectLayer(s, rect(25, 20, 55, 50))
            try selectAll(s, [lower, upper])
            let group = try layerResult(try s.execute("layer.groupLayers", ["name": "Merge test group"]))
            let docBefore = try doc(s)
            let expected = try render(s, docBefore)
            let children = try #require(docBefore.layer(group)?.children).map(\.id)

            try selectAll(s, children)
            try s.execute("layer.mergeLayers")
            let docAfter = try doc(s)
            let actual = try render(s, docAfter)
            #expect(actual == expected, "depth \(depth): group merge changed rendered pixels")
            #expect(docAfter.layer(group)?.children?.count == 1)
        }
    }

    @Test func mergingKeepsLayerEffectsOutsideThePixels() throws {
        // A drop shadow reaches past the layer's pixels; the merge must render that far.
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let lower = try rectLayer(s, rect(10, 10, 30, 30))
            let upper = try rectLayer(s, rect(40, 20, 60, 40))
            try s.execute("layer.layerStyle.dropShadow", ["layer": .id(upper), "blend": "normal", "distance": 12, "size": 4])
            let before = try composite(s)
            try selectAll(s, [lower, upper])
            try s.execute("layer.mergeLayers")
            let after = try composite(s)
            let worst = zip(before.px, after.px).map { (a, b) -> Float in
                let d = a - b
                return max(abs(d.x), abs(d.y), abs(d.z), abs(d.w))
            }.max() ?? 0
            #expect(worst <= 1.5 / 255, "depth \(depth): merge layers dropped the shadow (off by \(worst))")
        }
    }

    @Test func mergingAGroupDownPreservesTheComposite() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let lower = try rectLayer(s, rect(10, 12, 50, 52))
            let childA = try rectLayer(s, rect(24, 20, 64, 60))
            let childB = try rectLayer(s, rect(35, 28, 75, 68))
            try selectAll(s, [childA, childB])
            let group = try layerResult(try s.execute("layer.groupLayers", ["name": "Merge down group"]))
            let expected = try composite(s)

            try s.execute("layer.mergeDown", ["layer": .id(group)])
            let docAfter = try doc(s)
            let actual = try render(s, docAfter)
            #expect(actual == expected, "depth \(depth): group merge down changed rendered pixels")
            #expect(docAfter.layer(lower) != nil)
            #expect(docAfter.layer(group) == nil)
        }
    }

    @Test func aLockedGroupLocksItsContents() throws {
        let s = try session(8)
        let a = try rectLayer(s, rect(0, 0, 5, 5))
        let g = try layerResult(try s.execute("layer.new.groupFromLayers"))
        try s.execute("layer.setProps", ["layer": .id(g), "locked": true])
        try s.execute("layer.select", ["layer": .id(a)])
        let cases: [(String, JSONValue)] = [
            ("layer.translate", ["dx": 1]),
            ("paint.stroke", ["points": [[2, 2], [4, 4]]]),
            ("edit.fill", ["color": "#00ff00"]),
            ("edit.transform.flipHorizontal", [:]),
        ]
        for (cmd, p) in cases {
            #expect(throws: (any Error).self, "\(cmd) edited a layer in a locked group") { try s.execute(cmd, p) }
        }
        // Unlocking the group releases its contents.
        try s.execute("layer.setProps", ["layer": .id(g), "locked": false])
        try s.execute("layer.translate", ["dx": 1])
        #expect(try bounds(s, a) == rect(1, 0, 6, 5))
    }

    @Test func aLockedGroupKeepsAGroupedBackgroundLocked() throws {
        let s = try session(8)
        let bg = try doc(s).layers[0].id
        try s.execute("layer.select", ["layer": .id(bg)])
        let g = try layerResult(try s.execute("layer.new.groupFromLayers"))
        try s.execute("layer.setProps", ["layer": .id(g), "locked": true])
        try s.execute("layer.select", ["layer": .id(bg)])
        let cases: [(String, JSONValue)] = [
            ("edit.transform.flipHorizontal", [:]),
            ("edit.transform.warp", ["style": "flag", "bend": 50]),
            ("edit.puppetWarp", ["pins": [["src": [30, 25], "dst": [36, 29]]]]),
        ]
        for (cmd, p) in cases {
            do {
                try s.execute(cmd, p)
                Issue.record("\(cmd) edited the Background in a locked group")
            } catch {
                #expect("\(error)".contains("locked"), "\(cmd): \(error)")
            }
            #expect(try doc(s).layer(bg)?.name == "Background", "\(cmd)")
        }
    }

    @Test func groupFromLayersPreservesOrder() throws {
        let s = try session(8)
        let a = try rectLayer(s, rect(0, 0, 5, 5))
        let b = try rectLayer(s, rect(0, 0, 5, 5))
        let c = try rectLayer(s, rect(0, 0, 5, 5))
        let d = try rectLayer(s, rect(0, 0, 5, 5))
        try selectAll(s, [c, a])
        let g = try layerResult(try s.execute("layer.new.groupFromLayers", ["name": "Pair"]))
        let docu = try doc(s)
        let gl = try #require(docu.layer(g))
        #expect(gl.name == "Pair")
        #expect(gl.children?.map(\.id) == [a, c])
        // Root (bottom-to-top): Background, b, Pair (where c was), d.
        #expect(Array(docu.layers.map(\.id).dropFirst()) == [b, g, d])
        #expect(sel(s) == [g])
        s.undo()
        #expect(try doc(s).layers.count == 5)
        // ⌘G with several selected groups them too.
        try selectAll(s, [b, d])
        try s.execute("layer.groupLayers")
        #expect(try doc(s).layers.count == 4)
    }

    /// 100 nested groups: runs on a large stack (the debug build's recursive `Equatable`).
    @Test func groupingIsCappedAtTheDocumentNestingLimit() throws { try onLargeStack(Self.groupingCapBody) }

    static func groupingCapBody() throws {
        let s = try session(8)
        let a = try rectLayer(s, rect(0, 0, 5, 5))
        try selectAll(s, [a])
        for _ in 0..<maxGroupDepthLimit { try s.execute("layer.groupLayers") }
        #expect(try doc(s).maxGroupDepth == maxGroupDepthLimit)
        // One more wrapping group would pass the cap: rejected, document untouched.
        do {
            try s.execute("layer.groupLayers")
            Issue.record("grouped past the cap")
        } catch { #expect("\(error)".contains("deeper than 100"), "\(error)") }
        #expect(try doc(s).maxGroupDepth == maxGroupDepthLimit)
        // The rejected call recorded no history step: undo still lands one grouping earlier.
        s.undo()
        #expect(try doc(s).maxGroupDepth == maxGroupDepthLimit - 1)
    }

    @Test func selectLinkedLayersExcludesAnUnlinkedActiveLayer() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let a = try rectLayer(s, rect(0, 0, 10, 10))
            let b = try rectLayer(s, rect(20, 20, 30, 30))
            let other = try rectLayer(s, rect(50, 50, 60, 60))
            try selectAll(s, [a, b])
            try s.execute("layer.linkLayers")
            try s.execute("layer.select", ["layer": .id(a)])
            try s.execute("layer.select", ["layer": .id(other), "mode": "toggle"])
            #expect(sel(s) == [a, other])
            #expect(s.active?.activeLayer == other)
            let past = pastCount(s)
            let dirty = try #require(s.active).isDirty

            let result = try s.execute("layer.selectLinkedLayers")
            #expect(sel(s) == [a, b])
            #expect(result["selected"] == .int(sel(s).count))
            #expect(s.active?.activeLayer == b)
            #expect(s.active?.layerAnchor == b)
            #expect(pastCount(s) == past)
            #expect(s.active?.isDirty == dirty)

            // A following multi-layer delete must leave the unrelated layer intact.
            try s.execute("layer.delete")
            #expect(try doc(s).layer(a) == nil && doc(s).layer(b) == nil)
            #expect(try doc(s).layer(other) != nil)
            s.undo()
            #expect(try doc(s).layer(a) != nil && doc(s).layer(b) != nil)
            #expect(try doc(s).layer(other) != nil)
        }
    }

    @Test func selectLinkedLayersPreservesALinkedActiveLayer() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let a = try rectLayer(s, rect(0, 0, 10, 10))
            let b = try rectLayer(s, rect(20, 20, 30, 30))
            try selectAll(s, [a, b])
            try s.execute("layer.linkLayers")
            for active in [a, b] {
                try s.execute("layer.select", ["layer": .id(active)])
                try s.updateActive { $0.savedRevision = $0.revision }
                let past = pastCount(s)
                for _ in 0..<2 {
                    let result = try s.execute("layer.selectLinkedLayers")
                    #expect(sel(s) == [a, b])
                    #expect(result["selected"] == .int(sel(s).count))
                    #expect(s.active?.activeLayer == active)
                    #expect(s.active?.layerAnchor == active)
                    #expect(pastCount(s) == past)
                    #expect(s.active?.isDirty == false)
                }
            }
        }
    }

    @Test func selectLinkedLayersRequiresALinkedSelection() throws {
        let empty = Session()
        #expect(!empty.isEnabled("layer.selectLinkedLayers"))
        #expect(throws: (any Error).self) { try empty.execute("layer.selectLinkedLayers") }
        let s = try session(8)
        let before = sel(s)
        #expect(!s.isEnabled("layer.selectLinkedLayers"))
        #expect(throws: (any Error).self) { try s.execute("layer.selectLinkedLayers") }
        #expect(sel(s) == before)
    }

    @Test func translateRejectsOffsetsThatWouldWrap() throws {
        let s = try session(8)
        let a = try rectLayer(s, rect(0, 0, 5, 5))
        try selectAll(s, [a])
        // 2^32 + 50 wrapped to `dx = 50` and 3e9 to a negative offset through `as i32`.
        for dx: Int64 in [4_294_967_346, 3_000_000_000] {
            do {
                try s.execute("layer.translate", ["dx": .int(dx), "dy": 0])
                Issue.record("dx \(dx) was accepted")
            } catch { #expect("\(error)".contains("32-bit"), "\(error)") }
        }
        #expect(try bounds(s, a) == rect(0, 0, 5, 5), "the layer never moved")
        // Large in-range offsets still work.
        try s.execute("layer.translate", ["dx": -200_000, "dy": 200_000])
    }

    @Test func linkLayersNeverReusesAGroupWhenTheLargestIdIsU64Max() throws {
        let s = try session(8)
        let a = try rectLayer(s, rect(0, 0, 10, 10))
        let b = try rectLayer(s, rect(20, 20, 30, 30))
        let c = try rectLayer(s, rect(50, 50, 60, 60))
        let d = try rectLayer(s, rect(70, 70, 80, 80))
        // A stored document can carry any id; `max + 1` once overflowed here.
        try s.updateActive { st in
            for id in [c, d] { _ = st.doc.updateLayer(id) { $0.linkGroup = .max } }
        }
        try selectAll(s, [a, b])
        #expect(try s.execute("layer.linkLayers")["linked"] == true)
        let g = try group(s, a)
        #expect(g == 1)
        #expect(try group(s, b) == g)
        for id in [c, d] {
            #expect(try group(s, id) == .max, "the existing group is untouched")
        }
    }

    @Test func undoAndRedoReportOnlyTheEditedArea() throws {
        let s = try session(8)
        let a = try rectLayer(s, rect(10, 10, 20, 20))
        try selectAll(s, [a])
        // A pixel edit on one layer is bounded by that layer's extent on both sides.
        try fill(s, a, rect(12, 12, 14, 14), [0, 0, 1, 1])
        s.undo()
        #expect(damage(s) == rect(10, 10, 20, 20))
        s.redo()
        #expect(damage(s) == rect(10, 10, 20, 20))
        // A move reports where the layer was and where it landed.
        try s.execute("layer.translate", ["dx": 5, "dy": 0])
        s.undo()
        #expect(damage(s) == rect(10, 10, 25, 20), "union of where the layer was and is")
        s.redo()
        #expect(damage(s) == rect(10, 10, 25, 20))
    }

    @Test func undoOfDocumentWideStepsStillCompositesEverything() throws {
        let s = try session(8)
        _ = try rectLayer(s, rect(10, 10, 20, 20))
        // A canvas change has no bounded damage.
        try s.execute("image.crop", ["x": 0, "y": 0, "width": 30, "height": 25])
        #expect(try doc(s).size != PixelSize(width: 100, height: 80))
        s.undo()
        #expect(damage(s) == nil, "a size change recomposites the whole canvas")
        // A layer removed and restored changes only where it draws.
        let b = try rectLayer(s, rect(0, 0, 5, 5))
        try selectAll(s, [b])
        try s.execute("layer.delete")
        s.undo()
        #expect(damage(s) == rect(0, 0, 5, 5))
    }

    @Test func undoOfCompositorReadDocumentFieldsCompositesEverything() throws {
        let s = try session(8)
        _ = try rectLayer(s, rect(10, 10, 20, 20))
        // Global Light changes every effect's angle across the document.
        try s.execute("layer.layerStyle.globalLight", ["angle": 90.0])
        s.undo()
        #expect(damage(s) == nil, "a global-light change recomposites everything")
        // A mode change that keeps the pixel format (RGB → Indexed maps to RGB) neither.
        try s.execute("image.mode.indexedColor")
        s.undo()
        #expect(damage(s) == nil, "a mode change recomposites everything")
    }

    @Test func undoOfClippingOrChannelExclusionCompositesEverything() throws {
        let s = try session(8)
        _ = try rectLayer(s, rect(10, 10, 20, 20))
        let b = try rectLayer(s, rect(12, 12, 30, 30))
        try selectAll(s, [b])
        // Clipping reaches the layers clipped above, outside this layer's bounds.
        try s.execute("layer.setProps", ["clipped": true])
        s.undo()
        #expect(damage(s) == nil, "a clipping change recomposites everything")
        try s.execute("layer.setProps", ["channels": [true, false, true]])
        s.undo()
        #expect(damage(s) == nil, "an excluded-channel change recomposites everything")
    }

    @Test func linkedLayersMoveTogetherAndUndo() throws {
        for depth in [8, 16, 32] {
            let s = try session(depth)
            let a = try rectLayer(s, rect(0, 0, 10, 10))
            let b = try rectLayer(s, rect(20, 20, 30, 30))
            let c = try rectLayer(s, rect(50, 50, 60, 60))
            #expect(!s.isEnabled("layer.linkLayers"))
            try selectAll(s, [a, b])
            #expect(try s.execute("layer.linkLayers")["linked"] == true)
            let g = try group(s, a)
            #expect(try g != nil && group(s, b) == g)
            // Move only a: b follows, c stays.
            try s.execute("layer.select", ["layer": .id(a)])
            try s.execute("layer.translate", ["dx": 5, "dy": 3])
            #expect(try bounds(s, a) == rect(5, 3, 15, 13))
            #expect(try bounds(s, b) == rect(25, 23, 35, 33))
            #expect(try bounds(s, c) == rect(50, 50, 60, 60))
            s.undo()
            #expect(try bounds(s, a) == rect(0, 0, 10, 10))
            #expect(try bounds(s, b) == rect(20, 20, 30, 30))
            // Select Linked Layers from just a.
            try s.execute("layer.selectLinkedLayers")
            #expect(sel(s) == [a, b])
            // Multi-selection translate moves all selected (c added, unlinked).
            try s.execute("layer.select", ["layer": .id(c), "mode": "toggle"])
            try s.execute("layer.translate", ["dx": -1, "dy": 0])
            #expect(try bounds(s, c) == rect(49, 50, 59, 60))
            #expect(try bounds(s, a) == rect(-1, 0, 9, 10))
            // Toggle: linking the same group again unlinks.
            try selectAll(s, [a, b])
            #expect(try s.execute("layer.linkLayers")["linked"] == false)
            #expect(try group(s, a) == nil)
        }
    }

    @Test func linkLayersBesideAMaximalStoredGroup() throws {
        // The issue's repro: one layer stored at u64::MAX, link it with an unlinked one.
        do {
            let s = try session(8)
            let ids = try storedGroups(s, [.max, nil])
            #expect(try linkFresh(s, ids) != .max)
            // Unlink and relink the pair: with no groups left, numbering starts over at 1.
            #expect(try s.execute("layer.linkLayers")["linked"] == false)
            #expect(try ids.allSatisfy { try group(s, $0) == nil })
            #expect(try linkFresh(s, ids) == 1)
        }
        // Two other layers linked beside an untouched maximal pair.
        let s = try session(8)
        let ids = try storedGroups(s, [.max, .max, nil, nil])
        let g = try linkFresh(s, Array(ids[2...]))
        #expect(g != .max)
        #expect(try group(s, ids[0]) == .max && group(s, ids[1]) == .max)
    }

    @Test func unlinkAMaximalStoredGroup() throws {
        let s = try session(8)
        let ids = try storedGroups(s, [.max, .max, nil])
        try selectAll(s, Array(ids[..<2]))
        #expect(try s.execute("layer.linkLayers")["linked"] == false)
        #expect(try ids.allSatisfy { try group(s, $0) == nil })
        s.undo()
        #expect(try group(s, ids[0]) == .max && group(s, ids[1]) == .max)
        // Relinking all three gets a working group.
        _ = try linkFresh(s, ids)
    }

    @Test func linkLayersWhenEveryGroupIsHuge() throws {
        // Unselected groups at the top of the range, including the 0 a wrapped id would join.
        let top: [UInt64] = [.max, .max - 1, .max - 2, 0, 1, 2]
        let stored: [UInt64?] = top.flatMap { [Optional($0), Optional($0)] } + [nil, nil, nil, nil]
        let s = try session(8)
        let ids = try storedGroups(s, stored)
        let n = top.count * 2
        let g = try linkFresh(s, Array(ids[n..<n + 2]))
        #expect(!top.contains(g), "\(g) collides with a stored group")
        // A second link gets yet another group, and existing groups never change.
        let h = try linkFresh(s, Array(ids[(n + 2)...]))
        #expect(!top.contains(h) && h != g)
        for (i, t) in top.enumerated() {
            #expect(try group(s, ids[2 * i]) == t && group(s, ids[2 * i + 1]) == t)
        }
        // Moving a newly linked layer leaves the group-0 pair alone.
        #expect(LayerMulti.withLinks(try doc(s), [ids[n]]) == [ids[n], ids[n + 1]])
    }

    @Test func linkLayersNearTheMaximum() throws {
        // max + 1 still fits: the new group is u64::MAX itself.
        let s = try session(8)
        let ids = try storedGroups(s, [.max - 1, .max - 1, nil, nil, nil, nil])
        #expect(try linkFresh(s, Array(ids[2..<4])) == .max)
        // The next link no longer fits above the maximum and takes a free id instead.
        let g = try linkFresh(s, Array(ids[4...]))
        #expect(g != .max && g != .max - 1)
    }

    @Test func linkLayersAssignsWorkingGroups() throws {
        // Control: ordinary documents keep getting max + 1, starting at 1.
        let s = try session(8)
        let ids = try storedGroups(s, [nil, nil, nil, nil])
        #expect(try linkFresh(s, Array(ids[..<2])) == 1)
        #expect(try linkFresh(s, Array(ids[2...])) == 2)
        #expect(try s.execute("layer.linkLayers")["linked"] == false)
        #expect(try group(s, ids[2]) == nil && group(s, ids[3]) == nil)
        #expect(try group(s, ids[0]) == 1 && group(s, ids[1]) == 1)
    }

    @Test func selectionPrunedAfterDeleteAndUndo() throws {
        let s = try session(8)
        let a = try rectLayer(s, rect(0, 0, 5, 5))
        _ = try rectLayer(s, rect(0, 0, 5, 5))
        let c = try rectLayer(s, rect(0, 0, 5, 5))
        try selectAll(s, [a, c])
        // Deleting one layer explicitly prunes it from the set.
        try s.execute("layer.delete", ["layer": .id(a)])
        #expect(sel(s) == [c])
        s.undo()
        #expect(try sel(s).allSatisfy { try doc(s).layer($0) != nil })
        // Deleting with several selected removes them all, then selects the layer below.
        try selectAll(s, [a, c])
        try s.execute("layer.delete")
        #expect(try doc(s).layer(a) == nil && doc(s).layer(c) == nil)
        #expect(try doc(s).layerCount == 2)
        #expect(sel(s).count == 1)
        let stored = try #require(s.active).selectedLayerIds
        #expect(try stored.allSatisfy { try doc(s).layer($0) != nil })
        s.undo()
        #expect(try doc(s).layerCount == 4)
        // Redo then undo again keeps the set valid.
        s.redo()
        #expect(try sel(s).allSatisfy { try doc(s).layer($0) != nil })
    }

    @Test func duplicateHideLockAndReverseSelected() throws {
        let s = try session(8)
        let a = try rectLayer(s, rect(0, 0, 5, 5))
        let b = try rectLayer(s, rect(0, 0, 5, 5))
        let c = try rectLayer(s, rect(0, 0, 5, 5))
        try selectAll(s, [a, c])
        let r = try s.execute("layer.duplicate")
        #expect(r["layers"]?.arrayValue?.count == 2)
        #expect(try doc(s).layerCount == 6)
        #expect(sel(s).count == 2)
        #expect(sel(s).allSatisfy { $0 != a && $0 != c })
        s.undo()
        try selectAll(s, [a, b])
        try s.execute("layer.hideLayers")
        let d = try doc(s)
        #expect(d.layer(a)?.visible == false && d.layer(b)?.visible == false && d.layer(c)?.visible == true)
        try s.execute("layer.showLayers")
        #expect(try doc(s).layer(a)?.visible == true)
        try s.execute("layer.lockLayers")
        #expect(try doc(s).layer(a)?.locks.all == true && doc(s).layer(b)?.locks.all == true)
        #expect(throws: (any Error).self, "locked layers don't move") { try s.execute("layer.translate", ["dx": 1]) }
        try s.execute("layer.lockLayers")
        #expect(try doc(s).layer(a)?.locks.all == false)
        try s.execute("layer.lockLayers", ["position": true])
        #expect(try doc(s).layer(b)?.locks.position == true && doc(s).layer(c)?.locks.position == false)
        // Reverse a, b, c.
        try selectAll(s, [a, b, c])
        try s.execute("layer.arrange.reverse")
        #expect(Array(try doc(s).layers.map(\.id).dropFirst()) == [c, b, a])
        #expect(s.active?.history.entries.last == "Reverse")
    }

    @Test func inspectReportsSelection() throws {
        let s = try session(8)
        let a = try rectLayer(s, rect(0, 0, 5, 5))
        let b = try rectLayer(s, rect(0, 0, 5, 5))
        try selectAll(s, [a, b])
        let v = try s.execute("document.inspect")
        #expect(v["selectedLayers"] == .ids([a, b]))
        #expect(v["layers"]?[0]?["selected"] == true)
    }
}
