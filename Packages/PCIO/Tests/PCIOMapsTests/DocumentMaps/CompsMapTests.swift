// Tests for CompsMap. Port of photocraft-io (crates/io/src/comps_map.rs `#[cfg(test)]`, and the
// map-level parts of crates/io/tests/comps_artboards.rs and artboard_guide_order.rs), MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
@testable import PCIOMaps
import PCPSD
import Testing

@Suite struct CompsMapTests {
    static func shmd(_ items: [PSDMetadataItem]) -> [UInt8] { [UInt8](PSDMetadataItem.serialize(items)) }

    static func parseShmd(_ data: [UInt8]) throws -> [PSDMetadataItem] { try PSDMetadataItem.parse(Data(data)) }

    /// A raster layer whose content covers (4, 4)–(8, 8).
    static func layerA() -> Layer {
        var l = Layer.raster("A", format: .rgba8)
        l.withRaster { $0.fill(PixelRect(x0: 4, y0: 4, x1: 8, y1: 8), with: [1, 0, 0, 1]) }
        return l
    }

    @Test func artboardRoundtrip() throws {
        let a = Artboard(rect: PixelRect(x0: 10, y0: 20, x1: 110, y1: 220), background: .custom(.rgb(0.2, 0.4, 0.6)), preset: "Web")
        let b = CompsMap.writeArtboard(a, [0, 2])
        #expect(b.count % 2 == 0)
        let back = try #require(CompsMap.parseArtboard(b))
        #expect(back.rect == a.rect)
        #expect(back.preset == "Web")
        guard case let .custom(c) = back.background else {
            Issue.record("\(back)")
            return
        }
        #expect(abs(c.c[1] - 0.4) < 1e-3)
        for bg in [ArtboardBackground.white, .black, .transparent] {
            let a = Artboard(rect: PixelRect(x0: 0, y0: 0, x1: 4, y1: 4), background: bg)
            #expect(CompsMap.parseArtboard(CompsMap.writeArtboard(a, [])) == a)
        }
        #expect(CompsMap.parseArtboard([1, 2, 3]) == nil)
    }

    @Test func cmlsSettingRoundtripAndShmdMerge() throws {
        var d = Document.withBackground(name: "t", size: PixelSize(width: 32, height: 32), mode: .rgb, depth: .u8, fill: .white)
        let l = Self.layerA()
        let lid = l.id
        d.layers.append(l)
        d.layerComps.append(LayerComp(id: 7, name: "One", comment: "c", applyVisibility: true, applyPosition: true, applyAppearance: false,
                                      states: [CompLayerState(layer: lid, visible: false, position: SIMD2(10, 1), appearance: nil)]))
        d.lastAppliedComp = 7
        let res = try #require(CompsMap.writeCompsResource(d))
        // `list` is a length-4 string id, as Photoshop writes it, never a code.
        let listString: [UInt8] = [0, 0, 0, 4] + Array("list".utf8)
        let listCode: [UInt8] = [0, 0, 0, 0] + Array("list".utf8)
        #expect(Self.contains(res, listString))
        #expect(!Self.contains(res, listCode))
        let layer = try #require(d.layer(lid))
        let cm = try #require(CompsMap.writeCmls(d.layerComps, nil, layer, 3))
        // Attach as Photoshop would: shmd with cmls plus another item.
        var raw: RawBlocks = [("shmd", Self.shmd([PSDMetadataItem(key: "cust", data: Data([1, 2]))]))]
        CompsMap.setCmls(&raw, cm)
        #expect(try Self.parseShmd(raw[0].data).count == 2)
        let rawCopy = raw
        d.updateLayer(lid) { $0.psdBlocks = RawBlockList.toDocument(rawCopy) }
        d.metadata.psdResources.append(PSDResource(id: CompsMap.layerComps, name: "", data: res))
        let (comps, lastApplied, last) = CompsMap.compsFromPSD(d.metadata.psdResources.last?.data, d)
        #expect(comps == d.layerComps)
        #expect(lastApplied == 7)
        #expect(last == nil)
        #expect(CompsMap.compsUnchanged(d))
        // Moving the layer changes the decoded (relative) position: no longer unchanged.
        d.withRaster(of: lid) { $0.fill(PixelRect(x0: 0, y0: 0, x1: 2, y1: 2), with: [0, 0, 0, 1]) }
        #expect(!CompsMap.compsUnchanged(d))
        // Removing cmls keeps the other item; removing everything drops the block.
        CompsMap.setCmls(&raw, nil)
        #expect(try Self.parseShmd(raw[0].data).count == 1)
        var only: RawBlocks = [("shmd", Self.shmd([PSDMetadataItem(key: "cmls", data: Data([0, 0]))]))]
        CompsMap.setCmls(&only, nil)
        #expect(only.isEmpty)
    }

    static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard hay.count >= needle.count else { return false }
        return (0 ... hay.count - needle.count).contains { Array(hay[$0 ..< $0 + needle.count]) == needle }
    }

    /// A layer at origin (4, 4) whose `shmd` carries a `cmls` item with one `layerSettings` entry
    /// for comp 1: visible, offset by `ofst`.
    static func docWithCmlsOffset(_ ofst: (DValue, DValue), visible: Bool = true, name: String = "")
        -> (doc: Document, layer: LayerId, resource: [UInt8])
    {
        var d = Document.withBackground(name: "t", size: PixelSize(width: 32, height: 32), mode: .rgb, depth: .u8, fill: .white)
        var l = layerA()
        #expect(l.compPosition == SIMD2(4, 4))
        let setting = CompsMap.obj("null")
            .with("enab", .boolean(visible))
            .with("compList", .list([.integer(1)]))
            .with("Ofst", .descriptor(CompsMap.obj("null").with("Hrzn", ofst.0).with("Vrtc", ofst.1)))
        let cmls = Blocks.versionedBytes(PSDDescriptor(classID: "null").with("layerSettings", .list([.descriptor(setting)])))
        l.psdBlocks = [PSDLayerBlock(key: "shmd", data: shmd([PSDMetadataItem(key: "cmls", data: Data(cmls))]))]
        let lid = l.id
        d.layers.append(l)
        let nm: DValue = name.isEmpty ? .text(CompsMap.nulName) : .text(.nulTerminated(name))
        let comp = PSDDescriptor(classID: "Comp").with("Nm  ", nm).with("compID", .integer(1)).with("capturedInfo", .integer(3))
        let res = Blocks.versionedBytes(PSDDescriptor(classID: "CompList").with("list", .list([.descriptor(comp)])))
        return (d, lid, res)
    }

    @Test func unrepresentableCompOffsetsAreDroppedNotWrapped() throws {
        // #1017: the layer origin plus a file-supplied offset left Int32 range and panicked on
        // import (wrapped in release builds). The position is dropped with a warning; the
        // visibility of the same entry is kept.
        for (h, v) in [(Int32.max, Int32(0)), (0, .max)] {
            let (d, lid, res) = Self.docWithCmlsOffset((.integer(h), .integer(v)))
            let r = CompsMap.decodeComps(res, d)
            let st = try #require(r.comps[0].state(lid))
            #expect(st.visible == true && st.position == nil, "(\(h), \(v))")
            #expect(r.warnings.count == 1, "\(r.warnings)")
            #expect(r.warnings[0].contains("layer comp position"), "\(r.warnings)")
            #expect(CompsMap.compsFromPSD(res, d).comps == r.comps)
        }
        // Offsets wider than Int32 (64-bit integers) are dropped too, not truncated.
        var (d, lid, res) = Self.docWithCmlsOffset((.largeInteger(Int64(UInt32.max) + 2), .integer(0)))
        var r = CompsMap.decodeComps(res, d)
        #expect(r.comps[0].state(lid)?.position == nil)
        #expect(r.warnings.count == 1, "\(r.warnings)")
        // Control: an ordinary offset still decodes to layer origin + offset, without warnings.
        (d, lid, res) = Self.docWithCmlsOffset((.integer(6), .integer(-3)))
        r = CompsMap.decodeComps(res, d)
        #expect(r.comps[0].state(lid)?.position == SIMD2(10, 1))
        #expect(r.warnings.isEmpty, "\(r.warnings)")
    }

    @Test func unrepresentableCompPositionsAreWrittenWithoutOffset() throws {
        // #1017: a stored position minus the layer origin left Int32 range and panicked on export.
        // The offset is omitted (the comp then records no position for that layer).
        let l = Self.layerA()
        func comp(_ position: SIMD2<Int32>?) -> LayerComp {
            LayerComp(id: 1, name: "One", comment: "", applyVisibility: true, applyPosition: true, applyAppearance: false,
                      states: [CompLayerState(layer: l.id, visible: false, position: position, appearance: nil)])
        }
        for p in [SIMD2<Int32>(.min, 0), SIMD2(0, .min)] {
            let cm = try #require(CompsMap.writeCmls([comp(p)], nil, l, 1))
            let s = try #require(CompsMap.parseCmls(cm))
            #expect(s[0] == CompsMap.Setting(comps: [1], visible: false, offset: nil), "\(p)")
        }
        // Control: an ordinary position is written as its offset from the layer origin.
        let cm = try #require(CompsMap.writeCmls([comp(SIMD2(10, 1))], nil, l, 1))
        #expect(try #require(CompsMap.parseCmls(cm))[0].offset == SIMD2(6, -3))
    }

    // MARK: Map-level parts of tests/comps_artboards.rs and artboard_guide_order.rs

    /// `out_of_range_comp_offsets_import_and_export_without_panic`, decode half: the position is
    /// dropped with a warning, the rest of the comp survives, and the decoded comps still count as
    /// unchanged (so the file data is written back verbatim).
    @Test func outOfRangeCompOffsetsDecodeWithoutPanic() throws {
        let made = Self.docWithCmlsOffset((.integer(.max), .integer(0)), visible: false, name: "One")
        var src = made.doc
        let res = made.resource
        src.metadata.psdResources.append(PSDResource(id: CompsMap.layerComps, name: "", data: res))
        let r = CompsMap.decodeComps(res, src)
        #expect(r.warnings.contains { $0.contains("layer comp position") }, "\(r.warnings)")
        let c = r.comps[0]
        #expect(c.name == "One" && c.states.count == 1)
        #expect(c.states[0].visible == false && c.states[0].position == nil)
        (src.layerComps, src.lastAppliedComp, src.lastDocumentState) = (r.comps, r.lastApplied, r.lastDocumentState)
        #expect(CompsMap.compsUnchanged(src))
        // Control: an ordinary offset decodes as layer origin + offset, without a warning.
        let ok = Self.docWithCmlsOffset((.integer(6), .integer(0)), visible: false, name: "One")
        let r2 = CompsMap.decodeComps(ok.resource, ok.doc)
        #expect(r2.warnings.isEmpty)
        #expect(r2.comps[0].states[0].position == SIMD2(10, 4))
    }

    /// Comp id 0 entries build the Last Document State; unknown comp ids are ignored.
    @Test func lastDocumentStateAndUnknownComps() throws {
        let l = Self.layerA()
        let comps = [LayerComp(id: 5, name: "Five", applyAppearance: false, states: [CompLayerState(layer: l.id, visible: true)])]
        let last = LayerComp(id: 0, name: "Last Document State", applyAppearance: false,
                             states: [CompLayerState(layer: l.id, visible: false, position: SIMD2(5, 6))])
        let cm = try #require(CompsMap.writeCmls(comps, last, l, 9))
        var raw: RawBlocks = []
        CompsMap.setCmls(&raw, cm)
        var d = Document(name: "d", size: PixelSize(width: 16, height: 16), mode: .rgb, depth: .u8)
        var withBlocks = l
        withBlocks.psdBlocks = RawBlockList.toDocument(raw)
        d.layers = [withBlocks]
        d.layerComps = comps
        let res = try #require(CompsMap.writeCompsResource(d))
        let r = CompsMap.compsFromPSD(res, d)
        #expect(r.comps == comps)
        #expect(r.lastApplied == nil)
        #expect(r.lastDocumentState == last)
        #expect(CompsMap.writeCmls([], nil, l, 1) == nil)
        #expect(CompsMap.writeCompsResource(Document(name: "e", size: PixelSize(width: 1, height: 1), mode: .rgb, depth: .u8)) == nil)
        // A lastAppliedComp naming no comp is dropped.
        var d2 = d
        d2.lastAppliedComp = 77
        #expect(CompsMap.compsFromPSD(CompsMap.writeCompsResource(d2), d2).lastApplied == nil)
        #expect(CompsMap.compsFromPSD(nil, d).comps.isEmpty && CompsMap.compsFromPSD([0, 1], d).comps.isEmpty)
    }

    /// Issue #722: `guideIndeces` names guides in resource 1032's own order, vertical first.
    @Test func guidesInNumbersVerticalFirstLikeResource1032() {
        // One vertical guide at x=20 inside the rect, one horizontal at y=90 outside it.
        let g = Guides(horizontal: [90], vertical: [20])
        #expect(CompsMap.guidesIn(g, PixelRect(x0: 10, y0: 0, x1: 30, y1: 50)) == [0], "the vertical guide is 1032 index 0")
        // Both inside: vertical (1032 index 0) before horizontal (1032 index 1).
        let g2 = Guides(horizontal: [50], vertical: [50])
        #expect(CompsMap.guidesIn(g2, PixelRect(x0: 0, y0: 0, x1: 100, y1: 100)) == [0, 1], "vertical must be numbered before horizontal")
    }

    /// `exported_artboard_indices_match_guides_resource`, block half: the regenerated `artb` lists
    /// the vertical guide inside the board as index 0.
    @Test func artboardBlockKeepsRegeneratesAndRemoves() throws {
        let guides = Guides(horizontal: [90], vertical: [20])
        var board = Layer.group("Board", [Self.layerA()])
        board.artboard = Artboard(rect: PixelRect(x0: 10, y0: 0, x1: 30, y1: 50))
        var raw: RawBlocks = []
        CompsMap.artboardBlock(guides, board, &raw)
        #expect(raw.map(\.key) == ["artb"])
        let d = try #require(Blocks.parsePrefixVersioned(raw[0].data))
        guard case let .list(idx)? = d["guideIndeces"] else {
            Issue.record("no guideIndeces")
            return
        }
        #expect(idx == [.integer(0)], "the inside guide is the vertical one, 1032 index 0")
        // Unchanged: an older key with the same board is kept as is.
        let artd: RawBlocks = [("artd", raw[0].data), ("lsct", [0])]
        var kept = artd
        CompsMap.artboardBlock(guides, board, &kept)
        #expect(kept.map(\.key) == artd.map(\.key) && kept.map(\.data) == artd.map(\.data))
        // Changed: regenerated in place as `artb`.
        board.artboard?.background = .black
        CompsMap.artboardBlock(guides, board, &kept)
        #expect(kept.map(\.key) == ["artb", "lsct"])
        #expect(CompsMap.parseArtboard(kept[0].data) == board.artboard)
        // Removed: every artboard key goes.
        board.artboard = nil
        var all: RawBlocks = [("artb", [1]), ("abdd", [2]), ("lsct", [0])]
        CompsMap.artboardBlock(guides, board, &all)
        #expect(all.map(\.key) == ["lsct"])
    }
}
