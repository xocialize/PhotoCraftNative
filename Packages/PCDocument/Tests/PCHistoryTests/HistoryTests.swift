// Port of photocraft-ops's tests (crates/ops/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.

import PCDocument
import PCFoundation
import Testing
@testable import PCHistory

func base() -> Document {
    Document.withBackground(name: "h", size: PixelSize(width: 64, height: 64), mode: .rgb, depth: .u8, fill: .white)
}

/// Apply an edit the way the engine does: snapshot, mutate the current document, record.
func edit(_ h: inout History, _ cur: inout Document, _ label: String, _ f: (inout Document) -> Void) {
    let before = cur
    f(&cur)
    h.record(label, before: before, layers: LayerTarget())
}

/// Paints one pixel of the bottom layer (the Background).
func paint(_ doc: inout Document, x: Int32, y: Int32, _ px: [Float]) {
    doc.updateLayer(at: [0]) { $0.withRaster { $0.setPixel(x: x, y: y, px) } }
}

func assertCounter(_ h: History, _ current: Document, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let counter = h.ledger else {
        Issue.record("budget initializes the counter", sourceLocation: sourceLocation)
        return
    }
    var seen = Set<UInt64>()
    let total = tileBytes(current, &seen) + h.uniqueBytes(current)
    #expect(counter.bytesWith(current) == total, sourceLocation: sourceLocation)
    #expect(h.pixelBytes(current) == total, sourceLocation: sourceLocation)
    var seen2 = Set<UInt64>()
    let retained = (h.undoStack + h.redoStack).reduce(0) { $0 + tileBytes($1.doc, &seen2) }
    let empty = Document(name: "empty", size: PixelSize(width: 1, height: 1), mode: .rgb, depth: .u8)
    #expect(counter.bytesWith(empty) == retained, sourceLocation: sourceLocation)
}

func videoDocument(_ depth: SampleType, _ frames: Int) -> Document {
    var doc = Document(name: "video", size: PixelSize(width: 64, height: 64), mode: .rgb, depth: depth)
    var layer = Layer.raster("Video", format: doc.pixelFormat)
    let footage: [Surface] = (0..<frames).map { i in
        var s = Surface(format: doc.pixelFormat)
        s.setPixel(x: 1, y: 1, [Float(i) / Float(frames), 0, 0, 1])
        return s
    }
    layer.content = .raster(footage[0])
    layer.video = VideoData(frames: footage, fps: 24)
    doc.layers.append(layer)
    return doc
}

struct HistoryTestError: Error {}

func undoOrThrow(_ h: inout History, _ cur: Document) throws -> (doc: Document, layers: LayerTarget) {
    guard let r = h.undo(cur) else { throw HistoryTestError() }
    return r
}

func redoOrThrow(_ h: inout History, _ cur: Document) throws -> (doc: Document, layers: LayerTarget) {
    guard let r = h.redo(cur) else { throw HistoryTestError() }
    return r
}

func restoreOrThrow(_ h: inout History, _ id: UInt64, current: Document) throws -> (doc: Document, layers: LayerTarget) {
    guard let r = h.restoreSnapshot(id, current: current) else { throw HistoryTestError() }
    return r
}

func firstTileBytes(_ doc: Document) -> Int {
    doc.layers[0].surface?.tile(TileCoord(tx: 0, ty: 0))?.bytes.count ?? 0
}

@Suite struct HistoryTests {
    @Test func undoRedoCycle() throws {
        var h = History()
        var cur = base()
        edit(&h, &cur, "New Layer") { d in d.insertAbove(nil, Layer.raster("L", format: d.pixelFormat)) }
        #expect(cur.layers.count == 2)
        #expect(h.undoLabel == "New Layer")
        cur = try undoOrThrow(&h, cur).doc
        #expect(cur.layers.count == 1)
        #expect(h.redoLabel == "New Layer")
        cur = try redoOrThrow(&h, cur).doc
        #expect(cur.layers.count == 2)
        do { let none = h.redo(cur); #expect(none == nil) }
    }

    @Test func undoAndRedoReturnTheLayersEachStateTargetedWhenCreated() throws {
        var h = History()
        let open = base()
        let bg = open.layers[0].id
        h.setCurrentLayers(.single(bg))
        // New Layer targets the new layer; the background is then selected (not a step) and filled.
        var d = open
        let new = d.insertAbove(nil, Layer.raster("L", format: d.pixelFormat))
        let layered = d
        h.record("New Layer", before: open, layers: .single(new))
        d = layered
        d.name = "filled"
        h.record("Fill", before: layered, layers: .single(bg))
        var (doc, layers) = try undoOrThrow(&h, d)
        #expect(layers == .single(new), "New Layer's state targeted the new layer when created")
        (doc, layers) = try undoOrThrow(&h, doc)
        #expect(layers == .single(bg), "the opened document's target")
        (doc, layers) = try redoOrThrow(&h, doc)
        #expect(layers == .single(new))
        (_, layers) = try redoOrThrow(&h, doc)
        #expect(layers == .single(bg), "Fill's state targeted the background")
    }

    @Test func stateAccessorMatchesEntries() throws {
        var h = History()
        var cur = base()
        let open = cur
        edit(&h, &cur, "A") { $0.name = "a" }
        edit(&h, &cur, "B") { $0.name = "b" }
        #expect(h.entries.count == h.pastCount + 1)
        #expect(h.state(0) == open)
        #expect(h.state(1)?.name == "a")
        #expect(h.state(2) == nil, "the current document is not held")
        cur = try undoOrThrow(&h, cur).doc
        _ = try undoOrThrow(&h, cur)
        #expect(h.redoLabels == ["A", "B"], "next redo first")
    }

    @Test func newEditClearsRedo() throws {
        var h = History()
        var cur = base()
        edit(&h, &cur, "A") { $0.name = "a" }
        cur = try undoOrThrow(&h, cur).doc
        edit(&h, &cur, "B") { $0.name = "b" }
        #expect(!h.canRedo)
        #expect(h.entries == ["Open", "B"])
    }

    @Test func maxStatesBound() {
        var h = History(maxStates: 3)
        var cur = base()
        for i in 0..<10 { edit(&h, &cur, "step \(i)") { $0.name = "\(i)" } }
        var n = 0
        while let (d, _) = h.undo(cur) {
            cur = d
            n += 1
        }
        #expect(n == 3)
        #expect(cur.name == "6")
    }

    @Test func byteBudgetDropsOldestStatesButKeepsOne() {
        var h = History(maxStates: 50)
        var cur = base()
        let tile = 256 * 256 * 4
        // Each step repaints the background's tile: one unique tile per state.
        for i in 0..<6 { edit(&h, &cur, "paint \(i)") { paint(&$0, x: 1, y: 1, [Float(i) / 8, 0, 0, 1]) } }
        do { let dropped = h.trim(cur); #expect(dropped == 0, "unlimited by default") }
        #expect(h.pastCount == 6)
        // The current tile plus three history tiles fit.
        h.maxBytes = 4 * tile
        do { let dropped = h.trim(cur); #expect(dropped == 3) }
        #expect(h.pastCount == 3)
        #expect(h.uniqueBytes(cur) == 3 * tile)
        #expect(h.pixelBytes(cur) == 4 * tile, "the current tile plus history's")
        #expect(h.entries[0] == "paint 2")
        // A budget smaller than one state still keeps the last step undoable.
        h.maxBytes = 1
        h.trim(cur)
        #expect(h.pastCount == 1)
        do { let some = h.undo(cur); #expect(some != nil) }
    }

    @Test func historySharesUntouchedTiles() {
        var h = History()
        var cur = base()
        #expect(h.uniqueBytes(cur) == 0)
        // rename only: no pixel changes, history holds no unique tiles
        edit(&h, &cur, "Rename") { $0.name = "x" }
        #expect(h.uniqueBytes(cur) == 0)
        // paint one pixel: exactly one tile becomes unique to history
        edit(&h, &cur, "Paint") { paint(&$0, x: 1, y: 1, [0, 0, 0, 1]) }
        #expect(h.uniqueBytes(cur) == 256 * 256 * 4)
    }

    @Test(arguments: SampleType.allCases)
    func selectionTilesCountCurrentAndHistoryWithoutDoubleCounting(depth: SampleType) throws {
        var doc = Document(name: "selection", size: PixelSize(width: 300, height: 64), mode: .rgb, depth: depth)
        var selection = Surface(format: PixelFormat(mode: .grayscale, sample: depth, alpha: false))
        selection.setPixel(x: 1, y: 1, [1])
        selection.setPixel(x: 257, y: 1, [1])
        doc.selection = selection
        var cur = doc
        let tile = 65_536 * depth.bytes
        var h = History()
        h.maxBytes = .max
        #expect(h.pixelBytes(cur) == 2 * tile, "current selection counts without any history")
        #expect(h.uniqueBytes(cur) == 0)
        edit(&h, &cur, "Rename") { $0.name = "renamed" }
        #expect(h.pixelBytes(cur) == 2 * tile, "the shared selection tiles count once")
        edit(&h, &cur, "Selection") { $0.selection?.setPixel(x: 1, y: 1, [0.5]) }
        #expect(h.pixelBytes(cur) == 3 * tile, "only the changed selection tile is copied")
        #expect(h.uniqueBytes(cur) == tile)
        h.trim(cur)
        assertCounter(h, cur)
        let selectedValue = try #require(cur.selection).pixel(x: 1, y: 1)[0]
        edit(&h, &cur, "Deselect") { $0.selection = nil }
        #expect(h.pixelBytes(cur) == 3 * tile, "deselecting leaves the previous masks in history")
        #expect(h.uniqueBytes(cur) == 3 * tile)
        assertCounter(h, cur)
        cur = try undoOrThrow(&h, cur).doc
        #expect(try #require(cur.selection).pixel(x: 1, y: 1)[0] == selectedValue)
        #expect(h.pixelBytes(cur) == 3 * tile)
        #expect(h.uniqueBytes(cur) == tile)
        assertCounter(h, cur)
        // Coalescing can change the current mask without recording another state.
        cur.selection?.setPixel(x: 257, y: 1, [0.25])
        #expect(h.pixelBytes(cur) == 4 * tile)
        do { let dropped = h.trim(cur); #expect(dropped == 0) }
        assertCounter(h, cur)
        cur = try redoOrThrow(&h, cur).doc
        #expect(cur.selection == nil)
        #expect(h.pixelBytes(cur) == 4 * tile)
        assertCounter(h, cur)
    }

    @Test(arguments: SampleType.allCases)
    func selectionByteBudgetDropsOldMasksAndKeepsTheLastUndo(depth: SampleType) throws {
        var doc = Document(name: "selection", size: PixelSize(width: 64, height: 64), mode: .rgb, depth: depth)
        doc.selection = Surface(format: PixelFormat(mode: .grayscale, sample: depth, alpha: false))
        var cur = doc
        let tile = 256 * 256 * depth.bytes
        var h = History()
        for i in 1...6 { edit(&h, &cur, "Selection") { $0.selection?.setPixel(x: 1, y: 1, [Float(i) / 8]) } }
        #expect(h.pixelBytes(cur) == 6 * tile)
        h.maxBytes = 3 * tile
        do { let dropped = h.trim(cur); #expect(dropped == 4) }
        #expect(h.pastCount == 2)
        #expect(h.pixelBytes(cur) == 3 * tile)
        #expect(h.uniqueBytes(cur) == 2 * tile)
        assertCounter(h, cur)
        h.maxBytes = 1
        do { let dropped = h.trim(cur); #expect(dropped == 1) }
        #expect(h.pastCount == 1, "the most recent undo survives even below one mask's size")
        #expect(h.pixelBytes(cur) == 2 * tile)
        cur = try undoOrThrow(&h, cur).doc
        assertCounter(h, cur)
    }

    @Test(arguments: SampleType.allCases)
    func videoMemoryCountsOriginalsAndDeduplicatesDisplayedFrames(depth: SampleType) throws {
        var doc = videoDocument(depth, 3)
        let tile = firstTileBytes(doc)
        let frames = doc.layers[0].video?.frames
        doc.layers[0].video?.originalFrames = frames
        // Original footage and the displayed frame alias the stack, except this painted frame.
        doc.layers[0].video?.frames[2].setPixel(x: 1, y: 1, [0, 1, 0, 1])
        var cur = doc
        var h = History()
        h.maxBytes = .max
        #expect(h.pixelBytes(cur) == 4 * tile)
        for name in ["A", "B"] {
            edit(&h, &cur, "Rename") { $0.name = name }
            h.trim(cur)
        }
        assertCounter(h, cur)
        #expect(h.pixelBytes(cur) == 4 * tile)
        #expect(h.uniqueBytes(cur) == 0)
        // Rasterizing keeps the displayed frame; the rest of the clip survives only in undo.
        edit(&h, &cur, "Rasterize") { $0.layers[0].video = nil }
        #expect(h.uniqueBytes(cur) == 3 * tile)
        #expect(h.pixelBytes(cur) == 4 * tile)
        assertCounter(h, cur)
        cur = try undoOrThrow(&h, cur).doc
        #expect(h.uniqueBytes(cur) == 0)
        assertCounter(h, cur)
        cur = try redoOrThrow(&h, cur).doc
        #expect(h.uniqueBytes(cur) == 3 * tile)
        assertCounter(h, cur)
        h.clear()
        #expect(h.pixelBytes(cur) == tile)
    }

    @Test(arguments: SampleType.allCases)
    func videoMemoryBudgetEvictsDeletedOffPlayheadFrames(depth: SampleType) throws {
        var cur = videoDocument(depth, 6)
        let tile = firstTileBytes(cur)
        var h = History()
        for _ in 0..<4 { edit(&h, &cur, "Delete Frame") { _ = $0.layers[0].video?.frames.remove(at: 1) } }
        #expect(h.pixelBytes(cur) == 6 * tile)
        #expect(h.uniqueBytes(cur) == 4 * tile)
        h.maxBytes = 3 * tile
        do { let dropped = h.trim(cur); #expect(dropped == 3) }
        #expect(h.pastCount == 1)
        #expect(h.pixelBytes(cur) == 3 * tile)
        #expect(h.uniqueBytes(cur) == tile)
        assertCounter(h, cur)
        cur = try undoOrThrow(&h, cur).doc
        #expect(cur.layers[0].video?.frames.count == 3)
        assertCounter(h, cur)
        cur = try redoOrThrow(&h, cur).doc
        #expect(cur.layers[0].video?.frames.count == 2)
        assertCounter(h, cur)
        // A budget below the remaining clip still keeps the latest step undoable.
        h.maxBytes = 1
        do { let dropped = h.trim(cur); #expect(dropped == 0) }
        #expect(h.canUndo)
    }

    @Test(arguments: SampleType.allCases)
    func counterTracksEvictionUndoRedoBranchingPurgeAndClones(depth: SampleType) throws {
        var cur = Document.withBackground(name: "h", size: PixelSize(width: 300, height: 64), mode: .rgb, depth: depth, fill: .white)
        cur.selection = Surface(format: .gray8)
        var h = History(maxStates: 4)
        h.maxBytes = .max
        for i in 0..<8 {
            edit(&h, &cur, "Paint") { doc in
                paint(&doc, x: 1, y: 1, [Float(i) / 10, 0, 0, 1])
                doc.selection?.setPixel(x: 1, y: 1, [Float(i) / 10])
            }
            h.trim(cur)
            if i >= 1 { assertCounter(h, cur) }
        }
        cur = try undoOrThrow(&h, cur).doc
        assertCounter(h, cur)
        cur = try undoOrThrow(&h, cur).doc
        assertCounter(h, cur)
        cur = try redoOrThrow(&h, cur).doc
        assertCounter(h, cur)
        let copy = h
        edit(&h, &cur, "Branch") { $0.name = "branch" }
        #expect(!h.canRedo)
        assertCounter(h, cur)
        assertCounter(copy, cur)
        cur = try undoOrThrow(&h, cur).doc
        h.clearRedo()
        assertCounter(h, cur)
        h.purgeLast()
        assertCounter(h, cur)
        h.clear()
        #expect(h.ledger == nil)
        var seen = Set<UInt64>()
        #expect(h.pixelBytes(cur) == tileBytes(cur, &seen))
    }

    @Test func sharedMasksChannelsAndRepeatedSnapshotReferencesCountOnce() throws {
        var doc = base()
        var gray = Surface(format: .gray8)
        gray.setPixel(x: 1, y: 1, [1])
        var mask = LayerMask.revealAll()
        mask.surface = gray
        doc.layers[0].mask = mask
        doc.channels.append(AlphaChannel(name: "alpha", surface: gray))
        doc.selection = gray
        doc.quickMask = AlphaChannel(name: "quick", surface: gray)
        doc.layers.append(doc.layers[0])
        var cur = doc
        var seen = Set<UInt64>()
        let bytes = tileBytes(cur, &seen)
        var h = History(maxStates: 50)
        // Counting current separately would double count its tiles; the exact union fits.
        h.maxBytes = bytes
        for _ in 0..<6 {
            h.record("Same", before: cur, layers: LayerTarget())
            do { let dropped = h.trim(cur); #expect(dropped == 0) }
        }
        assertCounter(h, cur)
        for _ in 0..<3 {
            cur = try undoOrThrow(&h, cur).doc
            assertCounter(h, cur)
        }
        h.clearRedo()
        h.purgeLast()
        assertCounter(h, cur)
        #expect(h.pixelBytes(cur) == bytes)
    }

    @Test func thresholdRechecksCoalescedCurrentAndChangedBudget() throws {
        var h = History(maxStates: 50)
        var cur = base()
        h.maxBytes = .max
        for i in 0..<6 {
            edit(&h, &cur, "Paint") { paint(&$0, x: 1, y: 1, [Float(i) / 10, 0, 0, 1]) }
            h.trim(cur)
        }
        // A coalesced edit may change current without recording another history state.
        paint(&cur, x: 300, y: 1, [1, 1, 1, 1])
        let tile = 256 * 256 * 4
        h.maxBytes = 4 * tile
        do { let dropped = h.trim(cur); #expect(dropped == 4) }
        #expect(h.pastCount == 2)
        assertCounter(h, cur)
        cur = try undoOrThrow(&h, cur).doc
        assertCounter(h, cur)
        h.maxBytes = 0
        edit(&h, &cur, "Unlimited") { $0.name = "u" }
        #expect(h.ledger == nil)
        h.maxBytes = 1
        h.trim(cur)
        #expect(h.pastCount == 1, "always retain the most recent undo")
        assertCounter(h, cur)
    }

    @Test func transferredTilesCannotMakeTheBudgetCheckUnderestimateCurrent() {
        let before = base()
        var current = before
        var large = Surface(format: PixelFormat(mode: .cmyk, sample: .f32, alpha: true))
        large.setPixel(x: 256, y: 0, [1, 1, 1, 1, 1])
        let moved = large.takeTiles(PixelRect.xywh(256, 0, 1, 1))
        current.updateLayer(at: [0]) { $0.withRaster { $0.putTiles(moved) } }
        var h = History(maxStates: 50)
        var seen = Set<UInt64>()
        h.maxBytes = tileBytes(current, &seen) - 1
        h.record("A", before: before, layers: LayerTarget())
        h.record("B", before: before, layers: LayerTarget())
        do { let dropped = h.trim(current); #expect(dropped == 1, "current alone exceeds the budget; only the mandatory undo survives") }
        assertCounter(h, current)
    }
}

@Suite struct SnapshotHistoryTests {
    @Test func snapshotsAreNamedAndRestoreAsAnUndoableState() throws {
        var h = History()
        var cur = base()
        let bg = cur.layers[0].id
        let snap = h.takeSnapshot(doc: cur, layers: .single(bg))
        #expect(snap.name == "Snapshot 1")
        let named = h.takeSnapshot(name: "  Before paint ", doc: cur, layers: .single(bg))
        #expect(named.name == "Before paint" && named.id == 2)
        edit(&h, &cur, "Paint") { paint(&$0, x: 1, y: 1, [0, 0, 0, 1]) }
        cur.name = "tab name"
        let renamed = h.renameSnapshot(1, to: "First")
        let blank = h.renameSnapshot(1, to: "   ")
        let missing = h.renameSnapshot(9, to: "x")
        #expect(renamed && !blank && !missing)
        let (restored, layers) = try restoreOrThrow(&h, 2, current: cur)
        #expect(restored.layers[0].surface?.pixel(x: 1, y: 1) == [1, 1, 1, 1])
        #expect(restored.id == cur.id && restored.name == "tab name")
        #expect(layers == .single(bg))
        #expect(h.entries == ["Open", "Paint", "Before paint"])
        // The restore is one undoable step back to the painted document.
        let back = try undoOrThrow(&h, restored).doc
        #expect(back.layers[0].surface?.pixel(x: 1, y: 1) == [0, 0, 0, 1])
        let deleted = h.deleteSnapshot(1)
        #expect(deleted?.name == "First")
        #expect(h.snapshots.map(\.id) == [2])
        // Ids are never reused.
        let third = h.takeSnapshot(doc: back, layers: LayerTarget())
        #expect(third.id == 3)
        let gone = h.restoreSnapshot(1, current: back)
        #expect(gone == nil)
    }

    @Test func restoringASnapshotWhoseActiveLayerIsGoneTargetsTheTopLayer() throws {
        var h = History()
        var cur = base()
        let extra = cur.insertAbove(nil, Layer.raster("extra", format: cur.pixelFormat))
        var snapDoc = cur
        snapDoc.remove(extra)
        h.takeSnapshot(doc: snapDoc, layers: .single(extra))
        let (_, layers) = try restoreOrThrow(&h, 1, current: cur)
        #expect(layers == .single(cur.layers[0].id))
    }
}
