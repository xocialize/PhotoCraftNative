// Port of photocraft-io (crates/io/tests/comps_artboards.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Layer comps (resource 1065 + per-layer `cmls`) and artboards (`artb`) through PSD and
// `.pcraft`: byte-exact while unchanged, regenerated after edits. The map-level halves are
// PCIOMapsTests' CompsMapTests.
//
// Not ported: `corpus_layer_comps_import_and_verbatim_export` and
// `corpus_artboards_import_and_verbatim_export` (photocraft's external corpus files). Their
// "unchanged → written back byte for byte" assertion runs over the Photoshop corpus instead
// (`shmd`, `artb` and resource 1065 of every file that has them).

import Foundation
import PCDocument
import PCFormat
import PCFoundation
import PCIOCore
@testable import PCIOMaps
import PCPSD
import Testing
@testable import PCIO

@Suite struct CompsArtboardsTests {
    init() { ExportSweep.install() }
    static func toPSD(_ doc: Document, sourceLocation: SourceLocation = #_sourceLocation) throws -> [UInt8] {
        try MapsKit.export(doc, "x.psd", sourceLocation: sourceLocation).bytes
    }

    static func synthetic(_ depth: SampleType) -> Document {
        var d = Document(name: "s", size: PixelSize(width: 80, height: 40), mode: .rgb, depth: depth)
        let fmt = PixelFormat(mode: .rgb, sample: depth, alpha: true)
        var a = Layer.raster("A", format: fmt)
        a.withRaster { $0.fill(rect(4, 4, 20, 20), with: [1, 0, 0, 1]) }
        var b = Layer.raster("B", format: fmt)
        b.withRaster { $0.fill(rect(44, 4, 60, 20), with: [0, 0, 1, 1]) }
        var g1 = Layer.group("Board 1", [a])
        var g2 = Layer.group("Board 2", [b])
        g1.withGroup { $0.artboard = Artboard(rect: rect(0, 0, 40, 40), background: .white, preset: "Custom") }
        g2.withGroup { $0.artboard = Artboard(rect: rect(40, 0, 80, 40), background: .custom(.rgb(0, 1, 0)), preset: "") }
        d.layers = [g1, g2]
        let states = d.captureCompStates()
        d.layerComps.append(LayerComp(id: 11, name: "Both", comment: "all", applyVisibility: true, applyPosition: true, applyAppearance: false, states: states))
        d.layers[1].visible = false
        d.layers[0].withChildren { $0[0].blend = .multiply }
        let first = d.layers[0].id
        let some = d.captureCompStates().filter { $0.layer != first }
        d.layerComps.append(LayerComp(id: 12, name: "One", comment: "", applyVisibility: true, applyPosition: false, applyAppearance: true, states: some))
        d.lastAppliedComp = 12
        return d
    }

    /// A comp's states by layer name (layer ids differ after import), sorted.
    static func named(_ doc: Document, _ c: LayerComp) -> [String] {
        c.states.map { s in "\(doc.layer(s.layer)?.name ?? "?") \(String(describing: s.visible)) \(String(describing: s.position))" }.sorted()
    }

    @Test(arguments: [SampleType.u8, .u16, .f32]) func syntheticPSDRoundtripAllDepths(_ depth: SampleType) throws {
        let d = Self.synthetic(depth)
        let back = try MapsKit.importFile(Self.toPSD(d)).document
        let boards = back.artboards.map { "\($0.name) \($0.artboard)" }
        let want = d.artboards.map { "\($0.name) \($0.artboard)" }
        #expect(boards == want, "\(depth)")
        #expect(back.layerComps.count == 2)
        #expect(back.lastAppliedComp == 12)
        for (a, b) in zip(d.layerComps, back.layerComps) {
            #expect(a.id == b.id && a.name == b.name && a.comment == b.comment && a.capturedInfo == b.capturedInfo, "\(depth) comp \(a.name)")
            #expect(Self.named(d, a) == Self.named(back, b), "\(depth) comp \(a.name)")
        }
        // Re-exporting the imported document is byte-stable for comps and artboards.
        let f1 = try PSDFile(bytes: Self.toPSD(back))
        let f2 = try PSDFile(bytes: Self.toPSD(MapsKit.importFile(Self.toPSD(back)).document))
        #expect(f1.resource(CompsMap.layerComps)?.data == f2.resource(CompsMap.layerComps)?.data)
        for r in f1.layers {
            for key: FourCC in ["artb", "shmd"] {
                #expect(r.block(key).map { [UInt8]($0.data) } == MapsKit.layerBlock(f2, r.displayName, key), "\(r.displayName) \(key)")
            }
        }
    }

    @Test func syntheticPcraftRoundtripKeepsEverything() throws {
        var d = Self.synthetic(.u16)
        d.lastDocumentState = LayerComp(id: 0, name: "Last Document State", comment: "", applyVisibility: true, applyPosition: true,
                                        applyAppearance: true, states: d.captureCompStates())
        let bytes = try PcraftFormat.save(d)
        let back = try PcraftFormat.load(bytes)
        #expect(back.layerComps == d.layerComps)
        #expect(back.lastAppliedComp == d.lastAppliedComp)
        #expect(back.lastDocumentState == d.lastDocumentState)
        #expect(back.artboards.count == 2)
        #expect(back.layers[1].artboard == d.layers[1].artboard)
        // Remapped ids still point at the same layers.
        let fresh = try PcraftFormat.load(bytes, options: LoadOptions(preserveIds: false))
        let c = try #require(fresh.layerComps.first)
        #expect(c.states.count == fresh.layerCount)
        #expect(c.states.allSatisfy { fresh.layer($0.layer) != nil })

        // Native identity is independent of ZIP entry order and the filename extension.
        let zip = try ZipReader(bytes)
        var reordered = ZipWriter()
        try reordered.add("extra.txt", Array("not the manifest".utf8))
        for entry in zip.entries { try reordered.add(entry.name, try zip.read(entry, max: bytes.count)) }
        let rebuilt = try reordered.finish()
        for name in ["x.PCRAFT", "no-extension"] {
            let imported = try MapsKit.importFile(rebuilt, name).document
            #expect(imported.layerComps == d.layerComps, "\(name)")
            #expect(imported.layers.count > 1 && imported.layers[1].artboard == d.layers[1].artboard, "\(name)")
        }

        let png = try MapsKit.export(d, "x.png").bytes
        #expect(throws: Never.self) { try MapsKit.importFile(png, "pcraft") }
        #expect {
            try MapsKit.importFile(Array("not a native bundle".utf8), "broken.pcraft")
        } throws: { e in
            if case .format("pcraft", _)? = e as? PCIOError { true } else { false }
        }
    }

    /// A layer at (4, 4) whose preserved `shmd` block offsets it by `(dx, 0)` in comp 1, plus the
    /// matching resource 1065: what a PSD with that comp data imports to before decoding comps.
    static func docWithRawCompOffset(_ dx: Int32) -> Document {
        var d = Document(name: "s", size: PixelSize(width: 32, height: 32), mode: .rgb, depth: .u8)
        var l = Layer.raster("A", format: .rgba8)
        l.withRaster { $0.fill(rect(4, 4, 8, 8), with: [1, 0, 0, 1]) }
        let setting = CompsMap.obj("null")
            .with("enab", .boolean(false))
            .with("compList", .list([.integer(1)]))
            .with("Ofst", .descriptor(CompsMap.obj("null").with("Hrzn", .integer(dx)).with("Vrtc", .integer(0))))
        let cmls = Blocks.versionedBytes(PSDDescriptor(classID: "null").with("layerSettings", .list([.descriptor(setting)])))
        l.psdBlocks = [PSDLayerBlock(key: "shmd", data: [UInt8](PSDMetadataItem.serialize([PSDMetadataItem(key: "cmls", data: Data(cmls))])))]
        d.layers.append(l)
        let comp = PSDDescriptor(classID: "Comp")
            .with("Nm  ", .text(.nulTerminated("One")))
            .with("compID", .integer(1))
            .with("capturedInfo", .integer(3))
        let res = Blocks.versionedBytes(PSDDescriptor(classID: "CompList").with("list", .list([.descriptor(comp)])))
        d.metadata.psdResources.append(PSDResource(id: CompsMap.layerComps, name: "", data: res))
        return d
    }

    @Test func outOfRangeCompOffsetsImportAndExportWithoutPanic() throws {
        // #1017: an `Ofst` that puts the layer past Int32 range trapped on import and on export
        // (the unchanged-comps check decodes the preserved data). The position is dropped with a
        // warning, the rest of the comp survives, and the file data is still written back verbatim.
        var src = Self.docWithRawCompOffset(.max)
        (src.layerComps, src.lastAppliedComp, src.lastDocumentState) = CompsMap.compsFromPSD(src.metadata.psdResources.last?.data, src)
        let bytes = try Self.toPSD(src)
        let imported = try MapsKit.importFile(bytes)
        #expect(imported.warnings.contains { $0.contains("layer comp position") }, "\(imported.warnings)")
        let c = try #require(imported.document.layerComps.first)
        #expect(c.name == "One" && c.states.count == 1)
        #expect(c.states.first?.visible == false && c.states.first?.position == nil)
        let a = try PSDFile(bytes: bytes)
        let b = try PSDFile(bytes: Self.toPSD(imported.document))
        #expect(MapsKit.layerBlock(a, "A", "shmd") == MapsKit.layerBlock(b, "A", "shmd"))

        // Export of a stored position whose offset from the layer is out of range (no preserved
        // data, so `cmls` is regenerated): the offset is left out and reads back as no position.
        var d = Document(name: "s", size: PixelSize(width: 32, height: 32), mode: .rgb, depth: .u8)
        var l = Layer.raster("A", format: .rgba8)
        l.withRaster { $0.fill(rect(4, 4, 8, 8), with: [1, 0, 0, 1]) }
        let st = CompLayerState(layer: l.id, visible: false, position: SIMD2(.min, 0), appearance: nil)
        d.layers.append(l)
        d.layerComps.append(LayerComp(id: 1, name: "One", comment: "", applyVisibility: true, applyPosition: true, applyAppearance: false, states: [st]))
        let back = try MapsKit.importFile(Self.toPSD(d)).document
        let s = try #require(back.layerComps.first?.states.first)
        #expect(s.visible == false && s.position == nil)

        // Control: an ordinary offset imports as layer origin + offset, without a warning.
        var ok = Self.docWithRawCompOffset(6)
        (ok.layerComps, ok.lastAppliedComp, ok.lastDocumentState) = CompsMap.compsFromPSD(ok.metadata.psdResources.last?.data, ok)
        let okImported = try MapsKit.importFile(Self.toPSD(ok))
        #expect(!okImported.warnings.contains { $0.contains("layer comp") }, "\(okImported.warnings)")
        #expect(okImported.document.layerComps.first?.states.first?.position == SIMD2(10, 4))
    }

    /// The unchanged-file half of the corpus tests on the Photoshop corpus: every layer's `shmd`
    /// (comp settings and other metadata) and `artb`, and resource 1065, are written back byte for
    /// byte by an export of the unedited import.
    @Test(.enabled(if: Corpus.available, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)")) func corpusCompsAndArtboardsVerbatimExport() throws {
        var checked = 0
        for url in Corpus.files {
            let bytes = [UInt8](try Data(contentsOf: url))
            let src = try PSDFile(bytes: bytes)
            let doc = try MapsKit.importFile(bytes, url.lastPathComponent, options: IOOptions(compositor: StoredPixelsCompositor(), renderer: MapsKit.Renderer())).document
            let out = try PSDFile(bytes: MapsKit.export(doc, url.lastPathComponent, options: IOOptions(compositor: MapsKit.compositor, renderer: MapsKit.Renderer())).bytes)
            #expect(out.resource(CompsMap.layerComps)?.data == src.resource(CompsMap.layerComps)?.data, "\(url.lastPathComponent)")
            // Records keep their order (names repeat in real files).
            #expect(out.layers.count == src.layers.count, "\(url.lastPathComponent)")
            for (r, o) in zip(src.layers, out.layers) {
                for key: FourCC in ["shmd", "artb"] {
                    guard let b = r.block(key) else { continue }
                    checked += 1
                    #expect(o.block(key).map { [UInt8]($0.data) } == [UInt8](b.data), "\(url.lastPathComponent): layer \(r.displayName) \(key)")
                }
            }
        }
        #expect(checked > 0)
    }
}
