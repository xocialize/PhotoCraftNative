// Tests of the layer-tree index, navigation and structural edits the port adds on top of
// photocraft-doc's tree helpers (crates/doc/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.

import PCFoundation
import Testing
@testable import PCDocument

@Suite struct TreeTests {
    /// Background, A(group: a0, B(group: b0), a1), top.
    func tree() -> (Document, [String: LayerId]) {
        var d = makeDoc()
        let f = d.pixelFormat
        let a0 = Layer.raster("a0", format: f), b0 = Layer.raster("b0", format: f), a1 = Layer.raster("a1", format: f)
        let b = Layer.group("B", [b0])
        let a = Layer.group("A", [a0, b, a1])
        let top = Layer.raster("top", format: f)
        d.insertAbove(nil, a)
        d.insertAbove(nil, top)
        let ids = ["bg": d.layers[0].id, "A": a.id, "a0": a0.id, "B": b.id, "b0": b0.id, "a1": a1.id, "top": top.id]
        return (d, ids)
    }

    @Test func navigation() {
        let (d, id) = tree()
        #expect(d.parent(of: id["b0"]!) == id["B"])
        #expect(d.parent(of: id["A"]!) == nil)
        #expect(d.children(of: nil)?.map(\.name) == ["Background", "A", "top"])
        #expect(d.children(of: id["A"]!)?.map(\.name) == ["a0", "B", "a1"])
        #expect(d.children(of: id["a0"]!) == nil)
        #expect(d.siblings(of: id["B"]!)?.count == 3)
        #expect(d.indexInParent(id["a1"]!) == 2)
        #expect(d.depth(of: id["b0"]!) == 2)
        #expect(d.ancestors(of: id["b0"]!) == [id["B"]!, id["A"]!])
        #expect(d.ancestors(of: id["top"]!).isEmpty)
        #expect(d.isDescendant(id["b0"]!, of: id["A"]!))
        #expect(!d.isDescendant(id["A"]!, of: id["A"]!))
        #expect(!d.isDescendant(id["top"]!, of: id["A"]!))
        #expect(d.descendants(of: id["A"]!) == [id["a0"]!, id["B"]!, id["b0"]!, id["a1"]!])
        #expect(d.sibling(of: id["B"]!, offset: 1) == id["a1"])
        #expect(d.sibling(of: id["B"]!, offset: -1) == id["a0"])
        #expect(d.sibling(of: id["a1"]!, offset: 1) == nil)
        #expect(d.allLayerIds.count == 7 && d.layerCount == 7)
    }

    @Test func indexSurvivesInPlaceEditsAndFollowsStructuralOnes() throws {
        var (d, id) = tree()
        _ = d.path(of: id["b0"]!)
        let index = d.index
        // Painting and renaming keep the shape: the index is kept.
        d.withRaster(of: id["b0"]!) { $0.setPixel(x: 0, y: 0, [1, 0, 0, 1]) }
        d.updateLayer(id["A"]!) { $0.name = "A!" }
        #expect(d.index === index)
        // Reordering children inside an update changes the shape: rebuilt.
        d.updateLayer(id["A"]!) { $0.withChildren { $0.reverse() } }
        #expect(d.index !== index)
        #expect(d.path(of: id["a1"]!) == [1, 0])
        #expect(d.path(of: id["b0"]!) == [1, 1, 0])
        // Nesting changes with the same pre-order are detected too.
        d.updateLayer(id["A"]!) { a in
            a.withChildren { ch in
                let a0 = ch.remove(at: 2)
                ch[1].withChildren { $0.append(a0) }
            }
        }
        #expect(d.path(of: id["a0"]!) == [1, 1, 1])
        // Direct edits through `layers` drop the index.
        let i2 = d.index
        d.layers.reverse()
        #expect(d.index !== i2)
        #expect(d.path(of: id["top"]!) == [0])
        #expect(d.layer(id["b0"]!)?.surface?.pixel(x: 0, y: 0) == [1, 0, 0, 1])
    }

    @Test func copiesShareTheIndexUntilOneChangesItsTree() {
        var (d, id) = tree()
        _ = d.path(of: id["a0"]!)
        let snap = d
        #expect(snap.index === d.index)
        d.remove(id["top"]!)
        #expect(snap.index !== d.index)
        #expect(snap.path(of: id["top"]!) == [2])
        #expect(d.path(of: id["top"]!) == nil)
    }

    @Test func insertAtPlacements() throws {
        var (d, id) = tree()
        let f = d.pixelFormat
        let x = try d.insert(Layer.raster("x", format: f), at: .above(id["a0"]!))
        #expect(d.path(of: x) == [1, 1])
        let y = try d.insert(Layer.raster("y", format: f), at: .below(id["a0"]!))
        #expect(d.path(of: y) == [1, 0])
        let z = try d.insert(Layer.raster("z", format: f), at: .top(of: id["B"]!))
        #expect(d.path(of: z) == [1, 3, 1])
        let w = try d.insert(Layer.raster("w", format: f), at: .bottom(of: nil))
        #expect(d.path(of: w) == [0])
        let v = try d.insert(Layer.raster("v", format: f), at: .at(index: 1, in: id["B"]!))
        #expect(d.path(of: v) == [2, 3, 1])
        #expect(throws: DocumentError.self) { try d.insert(Layer.raster("bad", format: f), at: .top(of: id["a0"]!)) }
        #expect(throws: DocumentError.self) { try d.insert(Layer.raster("bad", format: f), at: .at(index: 9, in: nil)) }
        #expect(throws: DocumentError.self) { try d.insert(Layer.raster("bad", format: f), at: .above(LayerId(.max))) }
        // An id already in the document is refused (it would make lookups ambiguous).
        let dup = try #require(d.layer(id["a0"]!))
        #expect(throws: DocumentError.self) { try d.insert(dup, at: .top(of: nil)) }
    }

    @Test func nestingDepthIsEnforced() throws {
        var d = makeDoc()
        var chain = Layer.raster("leaf", format: d.pixelFormat)
        for _ in 0..<maxGroupDepthLimit { chain = Layer.group("G", [chain]) }
        let top = try d.insert(chain, at: .top(of: nil))
        #expect(d.maxGroupDepth == maxGroupDepthLimit)
        // The innermost group's children sit at the deepest legal level; one more is refused.
        let innermost = try #require(d.descendants(of: top).dropLast().last)
        let sibling = try d.insert(Layer.raster("sibling", format: d.pixelFormat), at: .top(of: innermost))
        #expect(d.depth(of: sibling) == maxGroupDepthLimit)
        #expect(throws: DocumentError.self) { try d.insert(Layer.group("deeper", [Layer.raster("y", format: .rgba8)]), at: .top(of: innermost)) }
        #expect(throws: DocumentError.self) { try d.insert(Layer.group("wrap", [Layer.group("x", [Layer.raster("y", format: .rgba8)])]), at: .above(innermost)) }
        #expect(throws: DocumentError.self) { try d.move(top, to: .top(of: innermost)) }
    }

    @Test func moveAndItsGuards() throws {
        var (d, id) = tree()
        try d.move(id["top"]!, to: .bottom(of: id["B"]!))
        #expect(d.path(of: id["top"]!) == [1, 1, 0])
        try d.move(id["a0"]!, to: .above(id["a1"]!))
        #expect(d.children(of: id["A"]!)?.map(\.name) == ["B", "a1", "a0"])
        // Relative to itself: nothing happens.
        let before = d
        try d.move(id["a0"]!, to: .above(id["a0"]!))
        #expect(d == before)
        // Into itself or its own descendants: refused, unchanged.
        #expect(throws: DocumentError.self) { try d.move(id["A"]!, to: .top(of: id["B"]!)) }
        #expect(throws: DocumentError.self) { try d.move(id["A"]!, to: .above(id["b0"]!)) }
        #expect(throws: DocumentError.self) { try d.move(id["A"]!, to: .top(of: id["A"]!)) }
        #expect(d == before)
        #expect(throws: DocumentError.self) { try d.move(LayerId(.max), to: .top(of: nil)) }
    }

    @Test func groupAndUngroup() throws {
        var (d, id) = tree()
        // Grouping a0 (inside A) and top: the group goes where `top` was; layers keep stacking order.
        let g = try d.groupLayers([id["top"]!, id["a0"]!], name: "G")
        #expect(d.layers.map(\.name) == ["Background", "A", "G"])
        #expect(d.children(of: g)?.map(\.name) == ["a0", "top"])
        #expect(d.layer(g)?.blend == .passThrough)
        // A selected group carries its selected children with it.
        let h = try d.groupLayers([id["B"]!, id["b0"]!], name: "H")
        #expect(d.children(of: h)?.map(\.name) == ["B"])
        #expect(d.children(of: id["B"]!)?.map(\.name) == ["b0"])
        let freed = try d.ungroup(g)
        #expect(freed == [id["a0"]!, id["top"]!])
        #expect(d.layers.map(\.name) == ["Background", "A", "a0", "top"])
        #expect(throws: DocumentError.self) { try d.ungroup(id["a0"]!) }
        #expect(throws: DocumentError.self) { try d.groupLayers([], name: "none") }
    }

    @Test func reassignLayerIdsRemapsReferences() throws {
        var (d, id) = tree()
        d.layerComps.append(LayerComp(id: 1, name: "c", states: d.captureCompStates()))
        d.variables.defs.append(VariableDef(name: "v", layer: id["a0"]!, kind: .visibility))
        d.slices.list.append({ var s = Slice(id: 1, origin: .layer); s.layer = id["top"]; return s }())
        d.updateLayer(id["a0"]!) { $0.psdId = 4 }
        let map = d.reassignLayerIds()
        #expect(map.count == 7)
        let newA0 = try #require(map[id["a0"]!])
        #expect(d.layer(newA0)?.name == "a0")
        #expect(d.layer(newA0)?.psdId == nil)
        #expect(d.layer(id["a0"]!) == nil)
        #expect(d.layerComps[0].missingLayers(in: d).isEmpty)
        #expect(d.variables.defs[0].layer == newA0)
        #expect(d.slices.list[0].layer == map[id["top"]!])
    }

    @Test func forEachLayerMutVisitsParentsBeforeChildren() {
        var (d, _) = tree()
        var order: [String] = []
        d.forEachLayerMut { l in
            order.append(l.name)
            l.name += "!"
        }
        #expect(order == ["Background", "A", "a0", "B", "b0", "a1", "top"])
        #expect(d.walk().allSatisfy { $0.layer.name.hasSuffix("!") })
    }
}
