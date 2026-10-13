// Port of photocraft-doc's lib.rs tests (crates/doc/src/lib.rs), MIT OR Apache-2.0, © ArtCraft
// Team and the PhotoCraft contributors. Plus the copy-on-write snapshot guarantees of the port.

import PCFoundation
import Testing
@testable import PCDocument

@Suite struct LabelColorTests {
    @Test func layerColorIdsAndExistingSerializedNamesStayStable() throws {
        let named: [(String, LabelColor)] = [
            ("None", .none), ("Red", .red), ("Orange", .orange), ("Yellow", .yellow),
            ("Green", .green), ("Blue", .blue), ("Violet", .violet), ("Gray", .gray),
        ]
        for (name, color) in named {
            #expect(try encodeJSON(color) == "\"\(name)\"")
            #expect(try decodeJSON(LabelColor.self, "\"\(name)\"") == color)
        }
        for c in LabelColor.all {
            #expect(LabelColor(id: c.id) == c)
            #expect(try roundTrip(c) == c)
        }
        for id in ["", "Red", "0", "unknown", "🔴"] { #expect(LabelColor(id: id) == nil) }
        #expect(throws: (any Error).self) { try decodeJSON(LabelColor.self, "\"Unknown\"") }
    }
}

@Suite struct DocumentTests {
    @Test func unusedLinkGroupNeverWraps() {
        var d = makeDoc()
        #expect(d.unusedLinkGroup() == 1)
        func with(_ groups: [UInt64]) {
            d.layers = Array(d.layers.prefix(1))
            for g in groups {
                var l = Layer.raster("l", format: .rgba8)
                l.linkGroup = g
                d.layers.append(l)
            }
        }
        with([3, 7])
        #expect(d.unusedLinkGroup() == 8)
        with([.max - 1])
        #expect(d.unusedLinkGroup() == .max)
        // A stored maximal id would wrap to 0: take the smallest free id instead.
        with([.max])
        #expect(d.unusedLinkGroup() == 1)
        with([0, 1, 2, 4, .max])
        #expect(d.unusedLinkGroup() == 3)
    }

    @Test func newDocumentHasLockedBackground() throws {
        let d = makeDoc()
        #expect(d.layers.count == 1)
        let bg = d.layers[0]
        #expect(bg.name == "Background")
        #expect(bg.locks.transparency)
        let s = try #require(bg.surface)
        #expect(s.pixel(x: 0, y: 0) == [1, 1, 1, 1])
        #expect(s.pixel(x: 99, y: 49) == [1, 1, 1, 1])
        #expect(s.pixel(x: 100, y: 0) == [0, 0, 0, 0])
    }

    /// The Background is the locked bottom pixel layer, whatever it is called.
    @Test func backgroundIsStructuralNotNamed() {
        var d = makeDoc()
        let id = d.layers[0].id
        #expect(d.isBackground(id))
        for name in ["Hintergrund", "背景", "Arrière-plan"] {
            d.layers[0].name = name
            #expect(d.background?.id == id, "\(name)")
        }
        // A layer called "Background" without the locks, or above the bottom, is not it.
        var top = Layer.raster("Background", format: d.pixelFormat)
        top.locks.transparency = true
        top.locks.position = true
        let topId = top.id
        d.layers.append(top)
        #expect(!d.isBackground(topId))
        d.layers[0].locks.position = false
        #expect(d.background == nil)
        d.layers[0].locks.position = true
        d.layers[0].clipped = true
        #expect(d.background == nil)
    }

    @Test func maxGroupDepthCountsNestingWithoutRecursing() {
        var d = makeDoc()
        let bg = d.layers[0].id
        var chain = Layer.raster("L", format: d.pixelFormat)
        for _ in 0..<3 { chain = Layer.group("G", [chain]) }
        d.insertAbove(bg, chain)
        #expect(d.maxGroupDepth == 3)
        // An unfilled group does not add a level (nothing lives inside it).
        d.insertAbove(bg, Layer.group("empty", []))
        #expect(d.maxGroupDepth == 3)
    }

    @Test func pixelFormatFollowsModeAndDepth() {
        let d = Document(name: "c", size: PixelSize(width: 1, height: 1), mode: .cmyk, depth: .u16)
        #expect(d.pixelFormat == PixelFormat(mode: .cmyk, sample: .u16, alpha: true))
        let b = Document(name: "b", size: PixelSize(width: 1, height: 1), mode: .bitmap, depth: .u8)
        #expect(b.pixelFormat.mode == .grayscale)
    }

    @Test func textRunsWithMaximalLengthsNormalizeToTextLength() {
        var t = TextLayer(text: "ab")
        var big = CharStyle()
        big.sizePt = 24
        t.runs = [TextRun(len: 1, style: CharStyle()), TextRun(len: .max, style: big)]
        t.paragraphs = [ParagraphRun(len: 1, style: ParagraphStyle()), ParagraphRun(len: .max, style: ParagraphStyle(align: .center))]

        let chars = t.charRuns()
        #expect(chars.reduce(0) { $0 + $1.len } == t.text.utf8.count)
        #expect(chars.count == 2)
        #expect(chars[1].len == 1)
        #expect(chars[1].style.sizePt == 24)

        let paragraphs = t.paragraphRuns()
        #expect(paragraphs.reduce(0) { $0 + $1.len } == t.text.utf8.count)
        #expect(paragraphs.count == 2)
        #expect(paragraphs[1].len == 1)
        #expect(paragraphs[1].style.align == .center)
    }

    @Test func insertRemoveShift() throws {
        var d = makeDoc()
        let bg = d.layers[0].id
        let a = d.insertAbove(bg, Layer.raster("A", format: d.pixelFormat))
        let b = d.insertAbove(bg, Layer.raster("B", format: d.pixelFormat))
        // order bottom->top: bg, B, A
        #expect(d.layers.map(\.name) == ["Background", "B", "A"])
        let up = d.shift(b, by: 1)
        #expect(up)
        #expect(d.layers[2].id == b)
        let past = d.shift(b, by: 1)
        #expect(!past)
        let removed = d.remove(a)
        #expect(removed?.name == "A")
        #expect(d.layer(a) == nil)
    }

    @Test func groupsWalkAndPaths() throws {
        var d = makeDoc()
        let inner = Layer.raster("inner", format: d.pixelFormat)
        let innerId = inner.id
        let g = Layer.group("G", [inner])
        let gid = d.insertAbove(nil, g)
        let walk = d.walk().map { "\($0.path)|\($0.depth)|\($0.layer.name)" }
        #expect(walk == ["[0]|0|Background", "[1]|0|G", "[1, 0]|1|inner"])
        #expect(d.path(of: innerId) == [1, 0])
        #expect(d.layer(gid)?.blend == .passThrough)
        // insert above a nested layer stays inside the group
        let n = d.insertAbove(innerId, Layer.raster("n", format: d.pixelFormat))
        #expect(d.path(of: n) == [1, 1])
        #expect(d.layerCount == 4)
    }

    /// `layer` and `path(of:)` must agree with `walk` at every depth, and miss cleanly.
    @Test func layerLookupAgreesWithWalk() {
        var d = makeDoc()
        let format = d.pixelFormat
        func leaf(_ n: String) -> Layer { Layer.raster(n, format: format) }
        let deep = Layer.group("A", [leaf("a0"), Layer.group("B", [leaf("b0"), Layer.group("C", [leaf("c0")]), leaf("b2")]), leaf("a2")])
        d.insertAbove(nil, deep)
        d.insertAbove(nil, leaf("top"))
        let walk = d.walk().map { ($0.path, $0.layer.id) }
        #expect(walk.count == 10)
        for (path, id) in walk {
            #expect(d.path(of: id) == path)
            #expect(d.layer(id)?.id == id)
            let viaUpdate = d.updateLayer(id) { $0.id }
            #expect(viaUpdate == id)
        }
        let missing = Layer.raster("elsewhere", format: d.pixelFormat).id
        let missingUpdate = d.updateLayer(missing) { $0.id }
        #expect(d.path(of: missing) == nil && d.layer(missing) == nil && missingUpdate == nil)
    }

    @Test func aLockedGroupLocksItsContents() {
        var d = makeDoc()
        let inner = Layer.raster("inner", format: d.pixelFormat)
        let innerId = inner.id
        var g = Layer.group("G", [Layer.group("H", [inner])])
        g.locks.position = true
        let gid = d.insertAbove(nil, g)
        d.updateLayer(innerId) { $0.locks.pixels = true }
        let k = d.effectiveLocks(innerId)
        #expect(k.position && k.pixels && !k.all)
        #expect(!d.effectiveLocks(gid).pixels, "a child's lock doesn't lock its group")
        #expect(d.effectiveLocks(LayerId(.max)) == Locks())
    }

    @Test func duplicateAssignsFreshIdsRecursively() {
        let g = Layer.group("G", [Layer.raster("x", format: .rgba8)])
        let dup = g.duplicate()
        #expect(g.id != dup.id)
        #expect(g.children?[0].id != dup.children?[0].id)
        #expect(dup.children?[0].name == "x")
    }

    @Test func duplicateClearsPsdIdButKeepsBlocks() {
        var l = Layer.raster("x", format: .rgba8)
        l.psdId = 7
        l.psdBlocks.append(PSDLayerBlock(key: "vmsk", data: [1]))
        let d = l.duplicate()
        #expect(d.psdId == nil)
        #expect(d.psdBlocks == l.psdBlocks)
    }

    @Test func layerNamesIncrement() {
        var d = makeDoc()
        #expect(d.nextLayerName("Layer") == "Layer 1")
        d.insertAbove(nil, Layer.raster("Layer 1", format: d.pixelFormat))
        #expect(d.nextLayerName("Layer") == "Layer 2")
    }

    @Test func copyNamesNumberFromTheRoot() {
        var d = makeDoc()
        #expect(d.copyName("Layer 1") == "Layer 1 copy")
        d.insertAbove(nil, Layer.raster("Layer 1 copy", format: d.pixelFormat))
        #expect(d.copyName("Layer 1") == "Layer 1 copy 2")
        #expect(d.copyName("Layer 1 copy") == "Layer 1 copy 2")
        d.insertAbove(nil, Layer.raster("Layer 1 copy 2", format: d.pixelFormat))
        #expect(d.copyName("Layer 1 copy 2") == "Layer 1 copy 3")
        #expect(d.copyName("Photo copyright") == "Photo copyright copy")
    }

    @Test func maskDensity() {
        var m = LayerMask.hideAll()
        #expect(m.value(x: 5, y: 5) == 0)
        m.density = 0.5
        #expect(abs(m.value(x: 5, y: 5) - 0.5) < 1e-6)
        var vals: [Float] = []
        m.values(PixelRect(x0: 0, y0: 0, x1: 3, y1: 2), into: &vals)
        #expect(vals == [Float](repeating: 0.5, count: 6))
        m.enabled = false
        #expect(m.value(x: 5, y: 5) == 1)
        m.values(PixelRect(x0: 0, y0: 0, x1: 2, y1: 2), into: &vals)
        #expect(vals == [1, 1, 1, 1])
    }

    @Test func snapshotCloneIsIndependent() throws {
        var d = makeDoc()
        let snap = d
        let bg = d.layers[0].id
        d.withRaster(of: bg) { $0.setPixel(x: 0, y: 0, [0, 0, 0, 1]) }
        #expect(try #require(snap.layers[0].surface).pixel(x: 0, y: 0) == [1, 1, 1, 1])
        #expect(try #require(d.layers[0].surface).pixel(x: 0, y: 0) == [0, 0, 0, 1])
    }

    @Test func layerContentArticleAndKindName() {
        #expect(LayerContent.adjustment(.invert).article == "an")
        #expect(LayerContent.adjustment(.invert).kindName == "Adjustment")
        #expect(LayerContent.raster(Surface(format: .rgba8)).article == "a")
        #expect(LayerContent.group(LayerGroup()).article == "a")
    }

    @Test func ensureIdsAboveAdvancesCounter() {
        let far = LayerId.fresh().rawValue + 1000
        ensureIdsAbove(far)
        #expect(LayerId.fresh().rawValue > far)
        ensureIdsAbove(3) // never moves backwards
        #expect(DocId.fresh().rawValue > far)
    }

    @Test func withBackgroundFillsInTheDocumentsModel() throws {
        for (mode, expected) in [(ColorMode.grayscale, [Float(1), 1]), (.cmyk, [0, 0, 0, 0, 1])] {
            let d = Document.withBackground(name: "m", size: PixelSize(width: 4, height: 4), mode: mode, depth: .u16, fill: .white)
            let px = try #require(d.layers[0].surface).pixel(x: 1, y: 1)
            #expect(px.count == expected.count)
            for (a, b) in zip(px, expected) { #expect(abs(a - b) < 1e-3, "\(mode): \(px)") }
        }
    }
}

/// A document copy is the snapshot: O(1), every tile shared until written.
@Suite struct SnapshotTests {
    func bigDoc() -> Document {
        var d = Document.withBackground(name: "big", size: PixelSize(width: 700, height: 600), mode: .rgb, depth: .u8, fill: .white)
        var l = Layer.raster("paint", format: d.pixelFormat)
        l.withRaster { $0.fill(PixelRect(x0: 0, y0: 0, x1: 700, y1: 600), with: [1, 0, 0, 1]) }
        l.mask = LayerMask.revealAll()
        l.mask?.surface.setPixel(x: 3, y: 3, [0])
        d.layers.append(l)
        d.selection = Surface(format: .gray8)
        d.selection?.setPixel(x: 10, y: 10, [1])
        return d
    }

    func generations(_ s: Surface) -> [TileCoord: UInt64] {
        Dictionary(uniqueKeysWithValues: s.tileCoords.map { ($0, s.tile($0)!.generation) })
    }

    @Test func copyingSharesEveryTile() throws {
        let d = bigDoc()
        let snap = d
        for (a, b) in zip(d.layers, snap.layers) {
            #expect(generations(try #require(a.surface)) == generations(try #require(b.surface)))
        }
        #expect(d == snap)
    }

    @Test func anEditCopiesOnlyTheTouchedTile() throws {
        var d = bigDoc()
        let snap = d
        let paint = d.layers[1].id
        let before = generations(try #require(d.layers[1].surface))
        #expect(before.count == 9) // 700 × 600 covers 3 × 3 tiles
        d.withRaster(of: paint) { $0.setPixel(x: 300, y: 300, [0, 1, 0, 1]) }
        let after = generations(try #require(d.layers[1].surface))
        let changed = before.keys.filter { before[$0] != after[$0] }
        #expect(changed == [TileCoord(tx: 1, ty: 1)])
        // The snapshot still has the old pixels and its tiles are untouched.
        #expect(generations(try #require(snap.layers[1].surface)) == before)
        #expect(try #require(snap.layers[1].surface).pixel(x: 300, y: 300) == [1, 0, 0, 1])
        // Other layers, the mask and the selection were not copied.
        #expect(generations(try #require(d.layers[0].surface)) == generations(try #require(snap.layers[0].surface)))
        #expect(generations(try #require(d.layers[1].mask).surface) == generations(try #require(snap.layers[1].mask).surface))
        #expect(generations(try #require(d.selection)) == generations(try #require(snap.selection)))
        #expect(d != snap)
    }

    /// Address of a tile's byte storage (identity of the allocation).
    func storage(_ s: Surface?, _ c: TileCoord) -> UInt? {
        s?.tile(c)?.bytes.withUnsafeBufferPointer { $0.baseAddress.map { UInt(bitPattern: $0) } }
    }

    /// Editing an unshared document mutates its tiles in place, at any depth of the tree: no
    /// copy of the tile, the surface or the layer arrays happens on the way down.
    @Test func editsOfAnUnsharedDocumentHappenInPlace() throws {
        var d = makeDoc()
        let leaf = Layer.raster("leaf", format: d.pixelFormat)
        let id = leaf.id
        d.insertAbove(nil, Layer.group("outer", [Layer.group("inner", [leaf])]))
        d.withRaster(of: id) { $0.setPixel(x: 1, y: 1, [1, 0, 0, 1]) }
        let c = TileCoord(tx: 0, ty: 0)
        let address = try #require(storage(d.layer(id)?.surface, c))
        let generation = d.layer(id)?.surface?.tile(c)?.generation
        d.withRaster(of: id) { $0.setPixel(x: 2, y: 2, [0, 1, 0, 1]) }
        d.updateLayer(id) { $0.withRaster { $0.setPixel(x: 3, y: 3, [0, 0, 1, 1]) } }
        #expect(storage(d.layer(id)?.surface, c) == address, "the tile was copied")
        #expect(d.layer(id)?.surface?.tile(c)?.generation != generation)
        // With a snapshot alive the first edit copies the tile, once.
        let snap = d
        d.withRaster(of: id) { $0.setPixel(x: 4, y: 4, [1, 1, 1, 1]) }
        let copied = try #require(storage(d.layer(id)?.surface, c))
        #expect(copied != address)
        #expect(storage(snap.layer(id)?.surface, c) == address)
        d.withRaster(of: id) { $0.setPixel(x: 5, y: 5, [1, 1, 1, 1]) }
        #expect(storage(d.layer(id)?.surface, c) == copied)
    }

    @Test func tileGenerationsTrackMutationAndCopies() throws {
        var s = Surface(format: .rgba8)
        s.setPixel(x: 1, y: 1, [1, 0, 0, 1])
        let g0 = try #require(s.tile(TileCoord(tx: 0, ty: 0))).generation
        let copy = s
        #expect(copy.tile(TileCoord(tx: 0, ty: 0))?.generation == g0)
        s.setPixel(x: 2, y: 2, [1, 0, 0, 1])
        #expect(s.tile(TileCoord(tx: 0, ty: 0))?.generation != g0)
        #expect(copy.tile(TileCoord(tx: 0, ty: 0))?.generation == g0)
    }
}
