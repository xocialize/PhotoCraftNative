// Port of photocraft-engine (crates/engine/src/float_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCEngine
import PCFoundation
import Testing

@Suite struct FloatCommandsTests {
    static func rect(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> PixelRect { PixelRect(x0: x0, y0: y0, x1: x1, y1: y1) }

    /// An 80×60 transparent document whose layer is painted red over (10..30)²; (10..30)² selected.
    func session(depth: Int = 8) throws -> (Session, LayerId) {
        let s = Session()
        try s.execute("file.new", ["width": 80, "height": 60, "background": "transparent", "depth": .int(depth)])
        let id = try #require(s.active?.activeLayer)
        try s.edit("paint") { doc, _ in doc.withRaster(of: id) { $0.fill(Self.rect(10, 10, 30, 30), with: $0.format.components(fromRGBA: SIMD4(1, 0, 0, 1))) } }
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 20, "height": 20])
        return (s, id)
    }

    func alpha(_ d: Document, _ id: LayerId, _ x: Int32, _ y: Int32) -> Float { d.layer(id)!.surface!.rgba(x: x, y: y).w }

    @Test func floatMovesACutPieceWithoutTouchingTheDocumentUntilDropped() throws {
        let (s, id) = try session()
        let steps = s.active!.history.pastCount
        #expect(try s.execute("select.float", ["dx": 15, "dy": 0])["offset"] == [15, 0])
        // Moving it again doesn't cut anything new.
        try s.execute("select.float", ["dx": 0, "dy": 10])
        var st = s.active!
        #expect(FloatCommands.floating(st)?.offset == SIMD2(15, 10))
        #expect(alpha(st.doc, id, 12, 12) == 1, "the document is untouched while floating")
        #expect(st.history.pastCount == steps)
        let shown = try #require(FloatCommands.displayed(st))
        #expect(alpha(shown, id, 12, 12) == 0 && alpha(shown, id, 27, 22) == 1, "shown cut and moved")
        // Drop: one history step, pixels and selection where they were shown.
        try s.execute("select.drop")
        st = s.active!
        #expect(FloatCommands.floating(st) == nil)
        #expect(st.history.pastCount == steps + 1)
        for (x, y) in [(Int32(12), Int32(12)), (27, 22), (44, 39), (40, 40)] {
            #expect(alpha(st.doc, id, x, y) == alpha(shown, id, x, y), "dropped as shown at (\(x), \(y))")
        }
        #expect(st.doc.selection?.contentBounds == Self.rect(25, 20, 45, 40))
        // Undo takes the whole move back.
        s.undo()
        #expect(alpha(s.active!.doc, id, 12, 12) == 1)
    }

    @Test func anyOtherCommandDropsItAndUndoPutsItBack() throws {
        let (s, id) = try session()
        let steps = s.active!.history.pastCount
        try s.execute("select.float", ["dx": 20, "dy": 0])
        // Undo while floating: the piece goes back; nothing in the document or history changed.
        #expect(try s.execute("edit.undo")["floating"] == "returned")
        var st = s.active!
        #expect(FloatCommands.floating(st) == nil && alpha(st.doc, id, 12, 12) == 1 && st.history.pastCount == steps)
        // Float again, then deselect: dropped first (where it was shown), then deselected.
        try s.execute("select.float", ["dx": 20, "dy": 0])
        try s.execute("select.deselect")
        st = s.active!
        #expect(st.doc.selection == nil && FloatCommands.floating(st) == nil)
        #expect(alpha(st.doc, id, 12, 12) == 0 && alpha(st.doc, id, 35, 20) == 1)
    }

    @Test func needsASelectionAndAnUnlockedPixelLayer() throws {
        let s = Session()
        try s.execute("file.new", ["width": 20, "height": 20])
        #expect(!s.isEnabled("select.float"), "no selection")
        try s.execute("select.all")
        #expect(s.isEnabled("select.float"), "the Background's selected pixels move")
        try s.execute("layer.new.layer")
        #expect(s.isEnabled("select.float"))
        try s.execute("layer.lockLayers", ["position": true])
        #expect(!s.isEnabled("select.float"), "a position-locked layer")
    }

    /// On the Background, which can't hold transparency, the hole takes the background colour.
    @Test func onTheBackgroundTheHoleTakesTheBackgroundColour() throws {
        let s = Session()
        try s.execute("file.new", ["width": 40, "height": 40])
        s.tools.background = SIMD4(0, 0, 1, 1)
        let id = try #require(s.active?.activeLayer)
        try s.execute("select.rect", ["x": 10, "y": 10, "width": 10, "height": 10])
        try s.execute("select.float", ["dx": 15, "dy": 0])
        try s.execute("select.drop")
        func px(_ x: Int32, _ y: Int32) -> SIMD4<Float> { s.active!.doc.layer(id)!.surface!.rgba(x: x, y: y) }
        #expect(px(12, 12) == SIMD4(0, 0, 1, 1), "the hole")
        #expect(px(27, 12) == SIMD4(1, 1, 1, 1), "the moved pixels")
        #expect(px(5, 5) == SIMD4(1, 1, 1, 1), "the rest")
    }

    /// Copying leaves the original pixels, at every depth; the move is one undo step.
    @Test func aCopyLeavesTheOriginalAtEveryDepthInOneUndoStep() throws {
        for depth in [8, 16, 32] {
            let (s, id) = try session(depth: depth)
            let steps = s.active!.history.pastCount
            try s.execute("select.float", ["dx": 30, "dy": 0, "copy": true])
            try s.execute("select.drop")
            var st = s.active!
            #expect(alpha(st.doc, id, 12, 12) == 1 && alpha(st.doc, id, 42, 12) == 1, "\(depth)-bit: both")
            #expect(st.history.pastCount == steps + 1 && st.history.undoLabel == "Move", "\(depth)-bit")
            s.undo()
            st = s.active!
            #expect(alpha(st.doc, id, 12, 12) == 1 && alpha(st.doc, id, 42, 12) == 0, "\(depth)-bit: undone")
        }
    }

    @Test func copyFloatsADuplicateAndLeavesTheOriginal() throws {
        let (s, id) = try session()
        try s.execute("select.float", ["dx": 30, "dy": 0, "copy": true])
        let shown = try #require(FloatCommands.displayed(s.active!))
        #expect(alpha(shown, id, 12, 12) == 1 && alpha(shown, id, 42, 12) == 1, "original kept, copy shown")
        try s.execute("select.drop")
        let doc = s.active!.doc
        #expect(alpha(doc, id, 12, 12) == 1 && alpha(doc, id, 42, 12) == 1, "dropped: both")
    }

    @Test func floatWithTheMaskTargetMovesTheMaskNotTheLayer() throws {
        let (s, id) = try session()
        try s.edit("mask") { doc, _ in
            var m = LayerMask.revealAll()
            m.surface.fill(Self.rect(10, 10, 30, 30), with: [0])
            doc.updateLayer(id) { $0.mask = m }
        }
        func maskAt(_ x: Int32, _ y: Int32) -> Float { s.active!.doc.layer(id)!.mask!.surface.sampleChannel(x: x, y: y, 0) }
        try s.execute("select.float", ["dx": 25, "dy": 0, "copy": true, "target": "mask"])
        try s.execute("select.drop")
        #expect(maskAt(12, 12) == 0, "the copy leaves the mask where it was")
        #expect(maskAt(37, 12) == 0, "the mask's selected part moved")
        #expect(maskAt(60, 12) == 1)
        #expect(alpha(s.active!.doc, id, 37, 12) == 0, "the layer's pixels did not move")
        #expect(alpha(s.active!.doc, id, 12, 12) == 1)
    }

    @Test func cuttingAnUntouchedPartOfTheMaskMovesItAndLeavesTheBackgroundColour() throws {
        let (s, id) = try session()
        try s.edit("mask") { doc, _ in
            var m = LayerMask.hideAll()
            m.surface.fill(Self.rect(50, 10, 70, 30), with: [1])
            doc.updateLayer(id) { $0.mask = m }
        }
        s.tools.background = SIMD4(0.5, 0.5, 0.5, 1)
        func maskAt(_ x: Int32, _ y: Int32) -> Float { s.active!.doc.layer(id)!.mask!.surface.sampleChannel(x: x, y: y, 0) }
        // (10..30)² is the mask's untouched black; it moves over the white at (50..70, 10..30).
        try s.execute("select.float", ["dx": 40, "dy": 0, "target": "mask"])
        try s.execute("select.drop")
        #expect(maskAt(55, 12) == 0, "the untouched black moved")
        #expect(abs(maskAt(12, 12) - 0.5) < 0.01, "the hole takes the background colour")
        #expect(maskAt(40, 12) == 0)
    }
}

// Skipped: `float_drag_bench` (an #[ignore]d benchmark).
