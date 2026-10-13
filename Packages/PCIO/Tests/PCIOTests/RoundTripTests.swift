// Document → PSD → Document round trips.
// Port of photocraft-io (crates/io/tests/roundtrip.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors. photocraft's tests run with photocraft's record shape
// (`photoshopRecordConventions: false`); `PhotoshopConventionTests` checks the default shape.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCIOMaps
import PCPSD
import Testing
@testable import PCIO

/// photocraft's options: its record shape, PCRender for the merged image.
func photocraftOptions() -> IOOptions {
    var o = IOOptions()
    o.photoshopRecordConventions = false
    return o
}

func exportPSD(_ d: Document, _ name: String = "x.psd", options: IOOptions = photocraftOptions()) throws -> ExportResult {
    try DocumentIO.export(d, as: name, options: options)
}

func importPSD(_ bytes: [UInt8], _ name: String = "x.psd") throws -> Document {
    try DocumentIO.importFile(name: name, bytes: bytes, options: photocraftOptions()).document
}

/// photocraft `roundtrip`: written files are byte-stable through PCPSD.
func roundtrip(_ doc: Document, options: IOOptions = photocraftOptions()) throws -> Document {
    let r = try exportPSD(doc, options: options)
    let file = try PSDFile(bytes: r.bytes)
    #expect([UInt8](try file.serialized()) == r.bytes)
    return try DocumentIO.importFile(name: "x.psd", bytes: r.bytes, options: options).document
}

func expectDocsEqual(_ a: Document, _ b: Document, _ ctx: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    let d = DocDiff.of(a, b)
    #expect(d.isEmpty, "\(ctx): \(d.prefix(6))", sourceLocation: sourceLocation)
}

func record(_ f: PSDFile, _ name: String) -> PSDLayerRecord? { f.layers.first { $0.displayName == name } }

func psdFile(_ d: Document, options: IOOptions = photocraftOptions()) -> PSDFile {
    PSDExport.file(d, options: options.psdExportOptions(forcePSB: false, interrupt: .none)).file
}

@Suite struct RoundTripTests {
    init() { ExportSweep.install() }
    static let cases: [(ColorMode, SampleType, Bool)] = [
        (.rgb, .u8, true), (.rgb, .u16, true), (.rgb, .f32, true), (.grayscale, .u8, true), (.grayscale, .u16, true), (.grayscale, .f32, true),
        (.cmyk, .u8, true), (.cmyk, .u16, true), (.lab, .u8, true), (.lab, .u16, true), (.rgb, .u8, false), (.grayscale, .u16, false), (.cmyk, .u8, false),
    ]

    @Test(arguments: cases.indices) func rtCase(_ i: Int) throws {
        let (mode, depth, all) = RoundTripTests.cases[i]
        let d = genDoc(mode, depth, all ? .all : .pixels)
        expectDocsEqual(d, try roundtrip(d), "\(mode) \(depth)")
        // The default (Photoshop record conventions) round-trips the same model.
        expectDocsEqual(d, try roundtrip(d, options: IOOptions()), "\(mode) \(depth) conventions")
    }

    @Test func psbRoundtrip() throws {
        let d = genDoc(.rgb, .u8, .all)
        let r = try exportPSD(d, "x.psb")
        #expect(r.bytes[5] == 2)
        expectDocsEqual(d, try importPSD(r.bytes, "x.psb"))
    }

    @Test func forcePSBOption() throws {
        var o = photocraftOptions()
        o.forcePSB = true
        #expect(try exportPSD(genDoc(.rgb, .u8, .pixels), options: o).bytes[5] == 2)
    }

    @Test func importSetsName() throws {
        let r = try exportPSD(genDoc(.rgb, .u8, .pixels), "psd")
        #expect(try DocumentIO.importFile(name: "hello.psd", bytes: r.bytes).document.name == "hello.psd")
    }

    @Test func emptyDocument() throws {
        let d = Document(name: "e", size: PixelSize(width: 4, height: 3), mode: .rgb, depth: .u8)
        let back = try roundtrip(d)
        // A flattened, fully transparent file comes back as one background layer.
        #expect(back.layers.count <= 1)
        #expect(back.size == d.size)
    }

    /// A header declaring a zero width or height is corrupt: opening fails, and a zero-sized
    /// document is never written.
    @Test func zeroSizedPSDIsRejected() throws {
        let good = try exportPSD(genDoc(.rgb, .u8, .pixels)).bytes
        for range in [14 ..< 18, 18 ..< 22, 14 ..< 22] {
            var b = good
            for k in range { b[k] = 0 }
            #expect(throws: (any Error).self) { try importPSD(b, "z.psd") }
        }
        let empty = Document(name: "e", size: PixelSize(width: 0, height: 3), mode: .rgb, depth: .u8)
        #expect(throws: (any Error).self) { try exportPSD(empty) }
    }

    @Test(arguments: [false, true]) func roundTripReachesAFixedPoint(_ conventions: Bool) throws {
        // The first export renders fill layers itself; after import they carry those pixels as
        // their fill cache, so from the second generation on the bytes are identical.
        var o = photocraftOptions()
        o.photoshopRecordConventions = conventions
        let d = genDoc(.rgb, .u16, .all)
        let a = try exportPSD(d, "a.psd", options: o).bytes
        let b = try exportPSD(try DocumentIO.importFile(name: "a.psd", bytes: a, options: o).document, "a.psd", options: o).bytes
        let c = try exportPSD(try DocumentIO.importFile(name: "b.psd", bytes: b, options: o).document, "a.psd", options: o).bytes
        #expect(b == c, "export(import(x)) == x for x = export(import(export(d)))")
        // Layer records are already stable in the first generation.
        #expect(try PSDFile(bytes: a).layers == (try PSDFile(bytes: b).layers))
    }

    @Test func textShapeSmartRawBlocksSurvive() throws {
        var d = genDoc(.rgb, .u8, .pixels)
        let fmt = d.pixelFormat
        let cache = pattern(fmt, rect(1, 1, 6, 4), 42, true)
        // A parseable legacy `PlLd` (a CS2-era placed layer): a stand-in that doesn't parse is
        // dropped on export now (Photoshop refuses the file with it; PCPSD
        // `placedLayerDataUnreadable`, see `unreadablePlacedDataIsDropped`).
        let placed = PSDBlockLayoutTests.plld("6d0f3a51-0c2e-4f6b-9a77-3c1b2d4e5f60")
        var so = SmartObject(source: .linked(path: ""), transform: .identity, cache: cache)
        so.psdRaw = placed
        var smart = Layer(name: "Smart", content: .smart(so))
        smart.psdBlocks = [PSDLayerBlock(key: "PlLd", data: [0, 0, 0, 0]), PSDLayerBlock(key: "vmsk", data: [UInt8](repeating: 5, count: 8)),
                           PSDLayerBlock(key: "luni", data: [UInt8](repeating: 0, count: 8))]
        // The typed vector mask (as import produces it) keeps the raw block while unchanged.
        smart.vectorMask = VectorMap.vectorMaskFromBlock([UInt8](repeating: 5, count: 8), UInt32(d.size.width), UInt32(d.size.height))
        d.layers.append(smart)
        var sh = ShapeLayer(fill: nil, cache: cache, psdRaw: nil)
        sh.path = try #require(VectorMap.pathFromVmsk([UInt8](repeating: 7, count: 8), UInt32(d.size.width), UInt32(d.size.height))).path
        var shape = Layer(name: "Shape", content: .shape(sh))
        shape.psdBlocks = [PSDLayerBlock(key: "vscg", data: [1, 2, 3, 4]), PSDLayerBlock(key: "vmsk", data: [UInt8](repeating: 7, count: 8))]
        d.layers.append(shape)
        // The stand-in vmsk/vscg bytes are not Photoshop data: not part of the acceptance set.
        let back = try ExportSweep.excluded { try roundtrip(d) }
        let n = back.layers.count
        let (bs, bsh) = (back.layers[n - 2], back.layers[n - 1])
        guard case let .smart(s) = bs.content, case let .shape(shp) = bsh.content else { Issue.record("kinds"); return }
        // psdRaw overrides the PlLd entry; the stale luni is regenerated, not kept.
        #expect(bs.psdBlocks.contains(PSDLayerBlock(key: "PlLd", data: placed)))
        #expect(bs.psdBlocks.contains { $0.key == "vmsk" })
        #expect(!bs.psdBlocks.contains { $0.key == "luni" })
        #expect(s.psdRaw == placed)
        #expect(shp.psdRaw == [UInt8](repeating: 7, count: 8))
        #expect(bsh.psdBlocks == d.layers[n - 1].psdBlocks)
    }

    /// Placed-layer data that doesn't parse (here a stand-in written as the smart object's `SoLd`;
    /// Photoshop refuses the whole file for such a `PlLd`/`SoLd`) is dropped on export, with a
    /// warning; the layer keeps its pixels.
    @Test func unreadablePlacedDataIsDropped() throws {
        var d = genDoc(.rgb, .u8, .pixels)
        var so = SmartObject(source: .linked(path: ""), transform: .identity, cache: pattern(d.pixelFormat, rect(1, 1, 6, 4), 42, true))
        so.psdRaw = [1, 2, 3, 4]
        d.layers.append(Layer(name: "Smart", content: .smart(so)))
        let r = try ExportSweep.excluded { try DocumentIO.export(d, as: "s.psd", options: photocraftOptions()) }
        #expect(r.warnings.contains { $0.contains("\"Smart\"") && $0.contains("placed-layer data could not be read") }, "\(r.warnings)")
        let f = try PSDFile(bytes: r.bytes)
        let rec = try #require(f.layers.last)
        #expect(rec.block("PlLd") == nil && rec.block("SoLd") == nil && !rec.rect.isEmpty)
        #expect(!f.compatibilityIssues().contains { $0.severity == .error }, "\(f.compatibilityIssues())")
    }

    @Test func rasterLayerBlocksPreserved() throws {
        var d = genDoc(.rgb, .u8, .pixels)
        let blocks = [PSDLayerBlock(key: "vmsk", data: [UInt8](repeating: 0, count: 12)), PSDLayerBlock(key: "clbl", data: [0, 0, 0, 0]),
                      PSDLayerBlock(key: "Zzzz", data: [1])]
        d.layers[1].psdBlocks = blocks
        // `clbl` is written from the field (in place), so the field agrees with the preserved block.
        d.layers[1].advanced = AdvancedBlending(blendClipped: false)
        d.layers[1].vectorMask = VectorMap.vectorMaskFromBlock([UInt8](repeating: 0, count: 12), UInt32(d.size.width), UInt32(d.size.height))
        // The stand-in `vmsk` (version 0, no path records) is kept byte for byte, but Photoshop
        // doesn't read it as a vector mask (oracle C′): the export keeps it rather than drop data
        // it was given, and the file stays out of the Photoshop acceptance set.
        let back = try ExportSweep.excluded { try roundtrip(d) }
        // An odd-length layer block comes back with its pad byte inside the length (#200).
        var expected = blocks
        expected[2].data = [1, 0]
        #expect(back.layers[1].psdBlocks == expected)
        #expect(try ExportSweep.excluded { try roundtrip(back) }.layers[1].psdBlocks == expected, "stable after the first save")
        #expect(back.layers[1].vectorMask == d.layers[1].vectorMask)
    }

    @Test func psdIdsAreKeptAndDeduplicated() throws {
        var d = genDoc(.rgb, .u8, .pixels)
        d.layers[0].psdId = 500
        d.layers[1].psdId = 500 // duplicate: second gets a fresh id
        d.layers[2].psdId = 3
        let back = try roundtrip(d)
        #expect(back.layers[0].psdId == 500)
        #expect(back.layers[1].psdId != 500)
        #expect(back.layers[2].psdId == 3)
        var ids: [UInt32] = []
        back.forEachLayer { _, _, l in if let i = l.psdId { ids.append(i) } }
        #expect(Set(ids).count == ids.count, "ids unique")
    }

    @Test func editedAdjustmentRegeneratesBlockUneditedKeepsRaw() throws {
        var d = genDoc(.rgb, .u8, .pixels)
        var l = Layer(name: "lv", content: .adjustment(.levels(.init())))
        var t = d
        t.layers.append(l)
        var raw = [UInt8](try #require(record(psdFile(t), "lv")?.block("levl")).data)
        raw[2 + 5 * 10 + 1] = 7 // record 5 in_black = 7 (not modelled)
        l.psdBlocks = [PSDLayerBlock(key: "levl", data: raw)]
        d.layers.append(l)
        #expect([UInt8](try #require(record(psdFile(d), "lv")?.block("levl")).data) == raw, "unchanged: raw kept")
        d.updateLayer(at: [d.layers.count - 1]) { l in
            if case var .adjustment(.levels(lv)) = l.content {
                lv.master.inBlack = 10 / 255
                l.content = .adjustment(.levels(lv))
            }
        }
        let data = [UInt8](try #require(record(psdFile(d), "lv")?.block("levl")).data)
        #expect(data != raw, "edited: regenerated")
        #expect(data[3] == 10)
    }

    @Test func textLayerRoundtripWithTySh() throws {
        var w = BEWriter()
        w.u16(1)
        for v in [1.0, 0, 0, 1, 3, 4] { w.f64(v) }
        w.u16(50)
        w.put(Blocks.versionedBytes(PSDDescriptor(classID: "TxLr").with("Txt ", Blocks.text("Hello"))))
        w.u16(1)
        w.put(Blocks.versionedBytes(PSDDescriptor(classID: "warp")))
        w.zeros(16)
        var d = genDoc(.rgb, .u8, .pixels)
        var t = TextLayer(text: "Hello", fontFamily: "", sizePt: 0, color: .black)
        t.transform = PCAffine(m: [1, 0, 0, 1, 3, 4])
        t.cache = pattern(d.pixelFormat, rect(3, 4, 9, 8), 5, true)
        t.psdRaw = w.bytes
        d.layers.append(Layer(name: "Hello", content: .text(t)))
        // A 0 pt type layer is outside Photoshop's type sizes (0.01–1,296 pt; the oracle's
        // pre-screen): not part of the Photoshop acceptance set.
        let back = try ExportSweep.excluded { try roundtrip(d) }
        guard case let .text(tl)? = back.layers.last?.content else { Issue.record("not text"); return }
        #expect(tl.text == "Hello")
        #expect(tl.transform.m == [1, 0, 0, 1, 3, 4])
        // This TySh has no EngineData, which Photoshop can't open (it crashes): the export
        // rebuilds it complete, so only the raw block differs.
        #expect(try PSDTypeTool(bytes: Data(try #require(tl.psdRaw))).photoshopStructureGaps().isEmpty)
        var diff = DocDiff(compareTySh: false)
        diff.layers(d.layers[d.layers.count - 1], back.layers[back.layers.count - 1], "")
        #expect(diff.problems.isEmpty, "\(diff.problems)")
    }

    @Test func effectsRawRoundtrip() throws {
        var d = genDoc(.rgb, .u8, .pixels)
        var lfx = EffectsMap.writeLfx2(true, [Effect.defaultDropShadow()])
        // Even length, as Photoshop's (an odd block comes back with its pad byte, #200).
        if lfx.count % 2 == 1 { lfx.append(0) }
        // Typed items and the raw block must agree; the raw bytes are then kept.
        let (master, items) = try #require(EffectsMap.parseLfx2(lfx))
        d.layers[1].effects.enabled = master
        d.layers[1].effects.items = items
        d.layers[1].effects.psdRaw = lfx
        expectDocsEqual(d, try roundtrip(d))
    }

    @Test func gradientAndPatternFillsRoundtrip() throws {
        var d = genDoc(.rgb, .u8, .pixels)
        d.layers.append(Layer(name: "grad", content: .fill(.gradient(GradientFill(stops: [ColorStop(0, .rgb(1, 0, 0)), ColorStop(1, .rgb(0, 0, 1))],
                                                                                    angle: 30, scale: 1, style: .diamond, reverse: true)))))
        // The fill's pattern travels with the document (Photoshop refuses a pattern fill without it).
        let dots = Pattern(name: "Dots", surface: pattern(PixelFormat(mode: .rgb, sample: .u8, alpha: true), PixelRect(x0: 0, y0: 0, x1: 6, y1: 4), 3, true),
                           width: 6, height: 4)
        d.patterns.append(dots)
        d.layers.append(Layer(name: "pat", content: .fill(.pattern(PatternFill(name: "Dots", scale: 0.5, id: dots.id)))))
        let back = try roundtrip(d)
        // The import keeps the pattern block it read.
        #expect(back.metadata.psdGlobalBlocks.map(\.key) == ["Patt"])
        d.metadata.psdGlobalBlocks = back.metadata.psdGlobalBlocks
        expectDocsEqual(d, back)
    }

    /// A pattern fill or style whose pattern the document lacks: Photoshop 27.11 refuses the file,
    /// so the export writes a placeholder pattern of that name (with the reference's id, or one it
    /// gives the reference) and says so.
    @Test func missingPatternsAreWrittenAsPlaceholders() throws {
        var d = genDoc(.rgb, .u8, .pixels)
        d.layers.append(Layer(name: "fill", content: .fill(.pattern(PatternFill(name: "Dots", scale: 0.5)))))
        var styled = Layer.raster("styled", format: d.pixelFormat)
        styled.effects.items = [.patternOverlay(.init(common: FxCommon(.normal, 1), name: "Weave", id: "6f1c2a3b-0000-4000-8000-00000000abcd"))]
        d.layers.append(styled)
        let r = try DocumentIO.export(d, as: "p.psd", options: IOOptions(compositor: MapsKit.compositor))
        #expect(r.warnings.contains { $0.contains("\"Dots\", \"Weave\"") && $0.contains("placeholder") }, "\(r.warnings)")
        let file = try PSDFile(bytes: r.bytes)
        #expect(file.compatibilityIssues(decodeChannels: true).filter { $0.severity == .error }.isEmpty)
        let block = try #require(file.globalBlock("Patt"))
        let written = try PSDPattern.parseBlock(block.data)
        #expect(written.map(\.name) == ["Dots", "Weave"])
        #expect(written[1].id == "6f1c2a3b-0000-4000-8000-00000000abcd")
        let back = try DocumentIO.importFile(name: "p.psd", bytes: r.bytes, options: IOOptions(compositor: StoredPixelsCompositor())).document
        guard case let .fill(.pattern(p))? = back.layers.first(where: { $0.name == "fill" })?.content else { Issue.record("fill"); return }
        #expect(!p.id.isEmpty && p.id == written[0].id, "the reference names the placeholder")
        // The caller's document is not changed.
        #expect(d.patterns.isEmpty)
    }

    @Test func psdRawResourcesAndGlobalBlocksPreserved() throws {
        var d = genDoc(.rgb, .u8, .pixels)
        d.metadata.psdResources.append(PSDResource(id: 4001, name: "named", data: [1]))
        // Photoshop-shaped blocks (a damaged copy of a block Photoshop parses gets the file
        // refused): the empty `Patt` every Photoshop file carries, and a `FMsk` (10-byte colour
        // space + opacity) with the PSB signature.
        d.metadata.psdGlobalBlocks.append(PSDGlobalBlock(signature: "8BIM", key: "Patt", data: []))
        d.metadata.psdGlobalBlocks.append(PSDGlobalBlock(signature: "8B64", key: "FMsk", data: [0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 50]))
        let back = try roundtrip(d)
        // A PSD holds no `8B64` blocks (Photoshop refuses the file): a kept PSB block is written as `8BIM`.
        var expected = d.metadata
        expected.psdGlobalBlocks[1].signature = "8BIM"
        #expect(back.metadata == expected)
    }

    @Test func documentToPSDDirectAPI() throws {
        let d = genDoc(.rgb, .u8, .all)
        let f = psdFile(d)
        #expect(f.header.width == 24)
        let (d2, _) = try PSDImport.document(f)
        expectDocsEqual(d, d2)
    }

    @Test func bigDocumentGoesPSBWithWarning() {
        let d = Document(name: "big", size: PixelSize(width: 30_001, height: 1), mode: .grayscale, depth: .u8)
        let (f, w) = PSDExport.file(d, options: PSDExportOptions(compositor: MapsKit.compositor))
        #expect(f.header.version == .psb)
        #expect(w.contains { $0.contains("PSB") })
    }

    @Test func effectsRoundtripTypedAndRaw() throws {
        var d = genDoc(.rgb, .u8, .pixels)
        d.globalLight = GlobalLight(angle: 45, altitude: 25)
        d.layers[1].effects.items = [
            Effect.defaultDropShadow(),
            .stroke(StrokeFx(common: FxCommon(.normal, 1), size: 3, position: .center, paint: .color(.rgb(0, 1, 0)))),
            .stroke(StrokeFx(common: FxCommon(.normal, 0.5), size: 6, position: .outside, paint: .color(.rgb(0, 0, 1)))),
        ]
        let back = try roundtrip(d)
        #expect(back.globalLight == d.globalLight)
        let fx = back.layers[1].effects
        #expect(fx.items.count == 3)
        let raw = try #require(fx.psdRaw, "lfx2 kept")
        // Unchanged → the same lfx2 bytes are written again.
        #expect([UInt8](try #require(record(psdFile(back), back.layers[1].name)?.block("lfx2")).data) == raw)
        // Edited → regenerated.
        var edited = back
        edited.updateLayer(at: [1]) { l in
            if case var .dropShadow(s) = l.effects.items[0] { s.distance = 20; l.effects.items[0] = .dropShadow(s) }
        }
        let data = [UInt8](try #require(record(psdFile(edited), back.layers[1].name)?.block("lfx2")).data)
        #expect(data != raw)
        let (_, items) = try #require(EffectsMap.parseLfx2(data))
        if case let .dropShadow(s) = items[0] { #expect(s.distance == 20) } else { Issue.record("not a drop shadow") }
    }

    @Test func groupEffectsUseLfxs() throws {
        var d = genDoc(.rgb, .u8, .pixels)
        let n = try #require(d.layers.firstIndex { $0.isGroup })
        d.updateLayer(at: [n]) { $0.effects.items.append(.colorOverlay(.init(common: FxCommon(.normal, 1), color: .rgb(1, 0, 0)))) }
        let f = psdFile(d)
        let rec = try #require(f.layers.first { $0.displayName == d.layers[n].name && $0.sectionType.isFolder })
        #expect(rec.block("lfxs") != nil && rec.block("lfx2") == nil)
        #expect(try PSDImport.document(f).document.layers[n].effects.items.count == 1)
    }

    @Test func clearingEffectsDropsStaleBlocks() throws {
        var d = genDoc(.rgb, .u8, .pixels)
        d.updateLayer(at: [1]) { $0.effects.items.append(Effect.defaultDropShadow()) }
        var cleared = try roundtrip(d)
        cleared.updateLayer(at: [1]) { $0.effects = Effects(enabled: true) }
        #expect(record(psdFile(cleared), cleared.layers[1].name)?.block("lfx2") == nil)
    }

    @Test func linkGroupsAndEffectsReferenceRoundTrip() throws {
        var d = Document(name: "l", size: PixelSize(width: 8, height: 8), mode: .rgb, depth: .u8)
        let fmt = d.pixelFormat
        var a = Layer.raster("a", format: fmt)
        a.withRaster { $0.fill(rect(0, 0, 4, 4), with: [1, 0, 0, 1]) }
        a.linkGroup = 7
        a.effects.reference = SIMD2(-201, 47.5)
        var b = Layer.raster("b", format: fmt)
        b.linkGroup = 7
        var inner = Layer.raster("inner", format: fmt)
        inner.linkGroup = 3
        d.layers = [a, b, Layer.group("g", [inner])]
        let back = try roundtrip(d)
        #expect(back.layers[0].linkGroup == 7)
        #expect(back.layers[1].linkGroup == 7)
        #expect(back.layers[2].linkGroup == nil)
        #expect(back.layers[2].children?[0].linkGroup == 3)
        #expect(back.layers[0].effects.reference == SIMD2(-201, 47.5))
        #expect(back.layers[1].effects.reference == nil)
        func res(_ doc: Document) throws -> [UInt8]? { try PSDFile(bytes: try exportPSD(doc).bytes).resource(1026).map { [UInt8]($0.data) } }
        // Unchanged documents write the same resource bytes again.
        #expect(try res(back) == res(d))
        // One u16 per record: a, b, divider, inner, group (bottom first).
        #expect(try res(d) == [0, 7, 0, 7, 0, 0, 0, 3, 0, 0])
        // Large engine ids are renumbered by first appearance.
        var big = d
        big.updateLayer(at: [0]) { $0.linkGroup = 1 << 40 }
        big.updateLayer(at: [1]) { $0.linkGroup = 1 << 40 }
        #expect(try res(big) == [0, 1, 0, 1, 0, 0, 0, 2, 0, 0])
        // Unlinked documents write no 1026.
        var none = d
        none.updateLayer(at: [0]) { $0.linkGroup = nil }
        none.updateLayer(at: [1]) { $0.linkGroup = nil }
        none.updateLayer(at: [2, 0]) { $0.linkGroup = nil }
        #expect(try res(none) == nil)
    }

    @Test func channelRestrictionsRoundTripAsBrst() throws {
        var d = Document(name: "c", size: PixelSize(width: 8, height: 8), mode: .rgb, depth: .u8)
        var a = Layer.raster("a", format: d.pixelFormat)
        a.withRaster { $0.fill(rect(0, 0, 4, 4), with: [1, 0, 0, 1]) }
        a.excludedChannels = 0b110
        d.layers = [a, Layer.raster("b", format: d.pixelFormat)]
        let f = psdFile(d)
        #expect(record(f, "a")?.block("brst").map { [UInt8]($0.data) } == [0, 0, 0, 1, 0, 0, 0, 2])
        #expect(record(f, "b")?.block("brst") == nil)
        let back = try roundtrip(d)
        #expect(back.layers[0].excludedChannels == 0b110)
        #expect(back.layers[1].excludedChannels == 0)
        var cleared = back
        cleared.updateLayer(at: [0]) { $0.excludedChannels = 0 }
        #expect(record(psdFile(cleared), "a")?.block("brst") == nil)
    }

    /// Advanced Blending maps to `knko` / `infx` / `clbl` / `tsly` / `lmgm` / `vmgm` at every
    /// depth: non-default values are written, default layers gain no blocks, and imported blocks
    /// are rewritten in place.
    @Test(arguments: SampleType.allCases) func advancedBlendingRoundTripsAsTaggedBlocks(_ depth: SampleType) throws {
        var d = Document(name: "a", size: PixelSize(width: 8, height: 8), mode: .rgb, depth: depth)
        var a = Layer.raster("a", format: d.pixelFormat)
        a.withRaster { $0.fill(rect(0, 0, 4, 4), with: [1, 0, 0, 1]) }
        let adv = AdvancedBlending(knockout: .deep, blendInterior: true, blendClipped: false, transparencyShapes: false, layerMaskHidesEffects: true,
                                   vectorMaskHidesEffects: true)
        a.advanced = adv
        var g = Layer.group("g", [Layer.raster("c", format: d.pixelFormat)])
        g.advanced.knockout = .shallow
        g.fillOpacity = 128 / 255
        d.layers = [a, Layer.raster("b", format: d.pixelFormat), g]
        let f = psdFile(d)
        let ra = try #require(record(f, "a"))
        for (k, v) in [("knko", 2), ("infx", 1), ("clbl", 0), ("tsly", 0), ("lmgm", 1), ("vmgm", 1)] as [(FourCC, UInt8)] {
            #expect(ra.block(k).map { [UInt8]($0.data) } == [v, 0, 0, 0], "\(depth) \(k)")
        }
        for k in ["knko", "infx", "clbl", "tsly", "lmgm", "vmgm"] as [FourCC] { #expect(record(f, "b")?.block(k) == nil, "default layer gained \(k)") }
        #expect(record(f, "g")?.block("knko").map { [UInt8]($0.data) } == [1, 0, 0, 0])
        let back = try roundtrip(d)
        #expect(back.layers[0].advanced == adv)
        #expect(back.layers[1].advanced.isDefault)
        #expect(back.layers[2].advanced.knockout == .shallow)
        #expect(back.layers[2].fillOpacity == Float(128) / 255)
        // Reset to the defaults: the imported blocks stay (in place) with default values.
        var reset = back
        reset.updateLayer(at: [0]) { $0.advanced = AdvancedBlending() }
        let rr = try #require(record(psdFile(reset), "a"))
        #expect(rr.block("knko").map { [UInt8]($0.data) } == [0, 0, 0, 0])
        #expect(rr.block("clbl").map { [UInt8]($0.data) } == [1, 0, 0, 0])
        #expect(try roundtrip(reset).layers[0].advanced.isDefault)
    }

    @Test func blendIfRoundTripsAsBlendingRanges() throws {
        var d = Document(name: "b", size: PixelSize(width: 8, height: 8), mode: .rgb, depth: .u8)
        var a = Layer.raster("a", format: d.pixelFormat)
        a.withRaster { $0.fill(rect(0, 0, 4, 4), with: [1, 1, 1, 1]) }
        var bi = BlendIf()
        bi.set(0, BlendRangePair(BlendRange(black: SIMD2(0, 0), white: SIMD2(200, 230)), .full))
        bi.set(2, BlendRangePair(.full, BlendRange(black: SIMD2(64, 64), white: SIMD2(255, 255))))
        a.blendIf = bi
        var g = Layer.group("g", [Layer.raster("c", format: d.pixelFormat)])
        g.blendIf.set(1, BlendRangePair(BlendRange(black: SIMD2(1, 2), white: SIMD2(3, 4)), .full))
        d.layers = [a, Layer.raster("b", format: d.pixelFormat), g]
        let f = psdFile(d)
        let full: [UInt8] = [0, 0, 255, 255, 0, 0, 255, 255]
        let want: [UInt8] = [0, 0, 200, 230, 0, 0, 255, 255] + full + [0, 0, 255, 255, 64, 64, 255, 255] + full
        #expect(record(f, "a")?.blendingRanges.data == want)
        // Layers without Blend If keep full ranges for gray + R, G, B.
        #expect(record(f, "b")?.blendingRanges == .full(channels: 3))
        let back = try roundtrip(d)
        #expect(back.layers[0].blendIf == bi)
        #expect(back.layers[1].blendIf.isDefault)
        #expect(back.layers[2].blendIf.get(1).this == BlendRange(black: SIMD2(1, 2), white: SIMD2(3, 4)))
    }
}

/// The default record shape: Photoshop's (PCPSD's corpus-verified conventions).
@Suite struct PhotoshopConventionTests {
    init() { ExportSweep.install() }
    @Test func plainRecordsCarryPhotoshopsBlocksInItsOrder() throws {
        var d = Document(name: "c", size: PixelSize(width: 8, height: 8), mode: .rgb, depth: .u8)
        var a = Layer.raster("a", format: d.pixelFormat)
        a.withRaster { $0.fill(rect(1, 1, 4, 4), with: [1, 0, 0, 1]) }
        d.layers = [a, Layer.group("g", [Layer.raster("c", format: d.pixelFormat)])]
        let f = PSDExport.file(d, options: PSDExportOptions(compositor: MapsKit.compositor)).file
        #expect(record(f, "a")?.blocks.map(\.key.string) == ["luni", "lnsr", "lyid", "clbl", "infx", "knko", "lspf", "lclr", "fxrp"])
        #expect(record(f, "a")?.flags.rawValue == 0x08)
        #expect(record(f, "a")?.blendingRanges.data.count == 40)
        let g = try #require(f.layers.first { $0.displayName == "g" })
        #expect(g.blocks.map(\.key.string) == ["luni", "lnsr", "lyid", "lsct", "lspf", "lclr", "fxrp"])
        #expect(g.flags.rawValue == 0x18)
        #expect(g.block("lsct")?.data.count == 16)
        let divider = try #require(f.layers.first { $0.sectionType == .boundingDivider })
        #expect(divider.blocks.map(\.key.string) == ["luni", "lnsr", "lyid", "lsct", "lspf", "lclr", "fxrp"])
        // Every record shape occurs in Photoshop's own files: PCPSD's linter agrees.
        #expect(f.compatibilityIssues(decodeChannels: true).filter { $0.severity == .error }.isEmpty)
        // The default fxrp is the layer's top-left (what "no reference" means to the compositor).
        var r = BEReader([UInt8](try #require(record(f, "a")?.block("fxrp")).data))
        #expect(try r.f64() == 1 && r.f64() == 1)
    }
}
