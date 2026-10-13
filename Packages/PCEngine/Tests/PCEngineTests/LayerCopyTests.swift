// Port of photocraft-engine (crates/engine/src/layer_copy_cmds/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCEngine
import PCFoundation
import Testing

@Suite struct LayerCopyTests {
    let cmd = "layer.copyToDocument"

    /// Document 0 (`w`×`h`, `depth`) with a red 10×10 square at (4, 6) on layer "paint" above the
    /// Background, and document 1 (60×50, `destDepth`-bit RGB). Document 0 is active.
    func twoDocs(_ w: Int, _ h: Int, _ depth: Int, destDepth: Int = 8) throws -> (Session, LayerId) {
        let s = Session()
        try s.execute("file.new", ["width": .int(w), "height": .int(h), "depth": .int(depth)])
        let paint = LayerId(try #require(try s.execute("layer.new.layer", ["name": "paint"])["layer"]?.uint64Value))
        try s.edit("fill") { doc, _ in
            let r = PixelRect(x0: 4, y0: 6, x1: 14, y1: 16)
            doc.withRaster(of: paint) { $0.writeRegion(r, PixelCodec.fromRGBA($0.format, rgba: [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 1), count: r.area))) }
        }
        try s.execute("file.new", ["width": 60, "height": 50, "depth": .int(destDepth)])
        _ = s.setActive(0)
        return (s, paint)
    }

    func doc(_ s: Session, _ i: Int) -> Document { s.documents[i].doc }
    func copied(_ r: JSONValue) throws -> LayerId { LayerId(try #require(r["layers"]?[0]?.uint64Value)) }
    func bounds(_ s: Session, _ i: Int, _ id: LayerId) -> PixelRect? { doc(s, i).layer(id).flatMap(LayerOps.layerBounds) }

    @Test func copiesTheSelectedLayersAboveTheDestinationsActiveLayerInOneStep() throws {
        let (s, paint) = try twoDocs(40, 30, 8)
        let sourceBefore = doc(s, 0)
        let r = try s.execute(cmd, ["document": 1])
        #expect(r["document"] == 1)
        #expect(s.activeIndex == 1, "the destination becomes the active document")
        let d = doc(s, 1)
        let id = try copied(r)
        #expect(id != paint, "a copy has its own id")
        #expect(d.layers.count == 2)
        #expect(d.layers[1].id == id, "above the Background, the destination's active layer")
        #expect(d.layers[1].name == "paint")
        #expect(s.active?.activeLayer == id)
        #expect(bounds(s, 1, id) == PixelRect(x0: 4, y0: 6, x1: 14, y1: 16), "same canvas position by default")
        #expect(d.layers[1].surface?.readRegion(PixelRect(x0: 5, y0: 7, x1: 6, y1: 8)) == [1, 0, 0, 1])
        #expect(doc(s, 0) == sourceBefore, "the source is untouched")
        // One history step in the destination.
        #expect(s.undo())
        #expect(doc(s, 1).layers.count == 1)
    }

    /// photocraft also converts the colour mode (Image › Mode › Grayscale destinations); that
    /// needs color_cmds' document conversion, not ported yet, so only depth is checked here.
    @Test func convertsToTheDestinationsDepth() throws {
        for depth in [8, 16, 32] {
            let (s, _) = try twoDocs(40, 30, depth, destDepth: 16)
            let r = try s.execute(cmd, ["document": 1])
            let surf = try #require(doc(s, 1).layer(try copied(r))?.surface)
            #expect(surf.format == PixelFormat(mode: .rgb, sample: .u16, alpha: true), "from \(depth)-bit RGB")
            let px = surf.readRegion(PixelRect(x0: 5, y0: 7, x1: 6, y1: 8))
            #expect(px == [1, 0, 0, 1], "\(px)")
        }
    }

    @Test func placesTheCopiesCentredOnTheCanvasOnAPointOrOffset() throws {
        let (s, paint) = try twoDocs(40, 30, 8)
        func place(_ p: JSONValue) throws -> PixelRect? {
            _ = s.setActive(0)
            let r = try s.execute(cmd, p.merging(["document": 1, "layers": [.id(paint)]]))
            return bounds(s, 1, try copied(r))
        }
        #expect(try place(["center": true]) == PixelRect(x0: 25, y0: 20, x1: 35, y1: 30))
        #expect(try place(["at": [10.0, 40.0]]) == PixelRect(x0: 5, y0: 35, x1: 15, y1: 45))
        #expect(try place(["offset": [-4, 20]]) == PixelRect(x0: 0, y0: 26, x1: 10, y1: 36))
        #expect(doc(s, 1).layers.count == 4)
    }

    @Test func aCopiedBackgroundIsAnOrdinaryLayerAndSeveralLayersKeepTheirOrder() throws {
        let (s, paint) = try twoDocs(40, 30, 8)
        let bg = doc(s, 0).layers[0].id
        let r = try s.execute(cmd, ["document": 1, "layers": [.id(paint), .id(bg)]])
        let d = doc(s, 1)
        #expect(d.layers.map(\.name) == ["Background", "Layer 1", "paint"])
        #expect(!d.layers[1].locks.transparency && !d.layers[1].locks.position)
        #expect(r["layers"]?.arrayValue?.count == 2)
        #expect(s.active?.selectedLayers.count == 2, "the copies are selected")
    }

    @Test func theSourcesPatternsComeAlongOnce() throws {
        let (s, _) = try twoDocs(40, 30, 8)
        var tile = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: true))
        tile.fill(PixelRect(x0: 0, y0: 0, x1: 2, y1: 2), with: [0, 1, 0, 1])
        let pat = Pattern(name: "dots", surface: tile, width: 2, height: 2)
        try s.edit("add pattern") { d, _ in d.patterns.append(pat) }
        try s.execute(cmd, ["document": 1])
        #expect(doc(s, 1).patterns.filter { $0.id == pat.id }.count == 1)
        _ = s.setActive(0)
        try s.execute(cmd, ["document": 1])
        #expect(doc(s, 1).patterns.filter { $0.id == pat.id }.count == 1, "not twice")
    }

    @Test func badParamsAndStatesFailWithoutChangingAnything() throws {
        let (s, _) = try twoDocs(40, 30, 8)
        let bad: [JSONValue] = [
            [:], ["document": 0], ["document": 7], ["document": -1], ["document": "1"], ["document": 1, "source": 9],
            ["document": 1, "layers": [999_999]], ["document": 1, "layers": "all"], ["document": 1, "layers": []],
            ["document": 1, "at": [1.0]], ["document": 1, "at": [.number(Double.greatestFiniteMagnitude), 0.0]],
            ["document": 1, "offset": ["a", 2]], .null,
        ]
        for p in bad {
            #expect(throws: EngineError.self, "\(p)") { try s.execute(cmd, p) }
            #expect(s.activeIndex == 0, "\(p): the source stays active")
            #expect(doc(s, 1).layers.count == 1, "\(p)")
        }
        // An Indexed destination has no layers to add to.
        _ = s.setActive(1)
        try s.edit("indexed") { d, _ in d.mode = .indexed }
        _ = s.setActive(0)
        #expect(throws: EngineError.self) { try s.execute(cmd, ["document": 1]) }
        // A single open document: nothing to copy to.
        s.close(1)
        #expect(!s.isEnabled(cmd))
    }

    @Test func copyingLinkedLayersDoesNotJoinAnUnrelatedDestinationGroup() throws {
        let s = Session()
        func newLayer(_ name: String) throws -> LayerId {
            LayerId(try #require(try s.execute("layer.new.layer", ["name": .string(name)])["layer"]?.uint64Value))
        }
        try s.execute("file.new", ["width": 16, "height": 16])
        let srcA = try newLayer("Source A"), srcB = try newLayer("Source B")
        try s.edit("link source") { d, _ in
            d.updateLayer(srcA) { $0.linkGroup = 1 }
            d.updateLayer(srcB) { $0.linkGroup = 1 }
        }
        try s.execute("file.new", ["width": 16, "height": 16])
        let dstA = try newLayer("Destination A"), dstB = try newLayer("Destination B")
        try s.edit("link destination") { d, _ in
            d.updateLayer(dstA) { $0.linkGroup = 1 }
            d.updateLayer(dstB) { $0.linkGroup = 1 }
        }
        _ = s.setActive(0)
        let result = try s.execute(cmd, ["document": 1, "layers": [.id(srcA), .id(srcB)]])
        let ids = (result["layers"]?.arrayValue ?? []).compactMap { $0.uint64Value.map { LayerId($0) } }
        #expect(ids.count == 2)
        let d = doc(s, 1)
        #expect(d.layer(dstA)?.linkGroup == 1)
        #expect(d.layer(dstB)?.linkGroup == 1)
        let firstGroup = d.layer(ids[0])?.linkGroup
        #expect(firstGroup == d.layer(ids[1])?.linkGroup, "the copied pair stays linked")
        #expect(firstGroup != nil)
        #expect(firstGroup != 1, "copied links must not merge with existing ones")
        #expect(s.undo())
        #expect(doc(s, 1).layer(ids[0]) == nil)
        #expect(s.redo())
        #expect(doc(s, 1).layer(ids[0])?.linkGroup == firstGroup)
    }

    @Test func copiedLinkGroupsAreDistinctFromEachOtherAndDestination() throws {
        let s = Session()
        try s.execute("file.new", ["width": 16, "height": 16])
        let a = LayerId(try #require(try s.execute("layer.new.layer", [:])["layer"]?.uint64Value))
        let b = LayerId(try #require(try s.execute("layer.new.layer", [:])["layer"]?.uint64Value))
        try s.edit("link independent source groups") { d, _ in
            d.updateLayer(a) { $0.linkGroup = 1 }
            d.updateLayer(b) { $0.linkGroup = 2 }
        }
        try s.execute("file.new", ["width": 16, "height": 16])
        _ = s.setActive(0)
        let r = try s.execute(cmd, ["document": 1, "layers": [.id(a), .id(b)]])
        let ids = (r["layers"]?.arrayValue ?? []).compactMap { $0.uint64Value.map { LayerId($0) } }
        let first = doc(s, 1).layer(ids[0])?.linkGroup
        let second = doc(s, 1).layer(ids[1])?.linkGroup
        #expect(first != nil && second != nil)
        #expect(first != second)
    }

    @Test func aNamedDuplicateTakesTheNameInOneStep() throws {
        let (s, paint) = try twoDocs(40, 30, 8)
        let before = try #require(s.active?.history.pastCount)
        let same = LayerId(try #require(try s.execute("layer.duplicate", ["name": "Ink"])["layer"]?.uint64Value))
        #expect(doc(s, 0).layer(same)?.name == "Ink")
        #expect(s.active?.history.pastCount == before + 1)
        s.undo()
        try s.execute("layer.select", ["layer": .id(paint)])
        let r = try s.execute(cmd, ["document": 1, "name": "Ink"])
        #expect(doc(s, 1).layer(try copied(r))?.name == "Ink")
    }
}
