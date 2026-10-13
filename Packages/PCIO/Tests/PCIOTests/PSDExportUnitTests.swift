// The inline unit tests of the PCIO-owned photocraft modules.
// Port of photocraft-io (crates/io/src/psd_export.rs, lib.rs, psd_thumbnail.rs and flat.rs
// `#[cfg(test)]` modules), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCIOMaps
import PCPSD
import Testing
@testable import PCIO

@Suite struct PSDExportUnitTests {
    init() { ExportSweep.install() }
    static func document(_ w: Int, _ h: Int) -> Document {
        Document(name: "size estimate", size: PixelSize(width: w, height: h), mode: .rgb, depth: .u8)
    }

    static func lint(_ bytes: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let errors = try PSDFile(bytes: bytes).compatibilityIssues(decodeChannels: true).filter { $0.severity == .error }
        #expect(errors.isEmpty, "\(errors)", sourceLocation: sourceLocation)
    }

    @Test func unreadableLr16WarnsOnImportAndIsNotSavedTwice() throws {
        // #2700: a 16-bit file whose Lr16 block claims five layers but holds none.
        let n = 8 * 6
        let header = PSDHeader(version: .psd, width: 8, height: 6, channels: 3, depth: 16, colorMode: .rgb)
        let file = PSDFile(header: header, globalLayerMask: PSDGlobalLayerMask(), globalBlocks: [PSDTaggedBlock(key: "Lr16", data: Data([0, 5, 0, 0]))],
                           imageData: PSDImageData(compression: .raw, data: Data(repeating: 0x80, count: n * 3 * 2)))
        let imported = try DocumentIO.importFile(name: "broken.psd", bytes: [UInt8](try file.serialized()))
        #expect(imported.warnings.contains { $0.contains("Lr16") && $0.contains("could not be read") }, "\(imported.warnings)")
        for conventions in [false, true] {
            var o = photocraftOptions()
            o.photoshopRecordConventions = conventions
            let saved = try PSDFile(bytes: try DocumentIO.export(imported.document, as: "x.psd", options: o).bytes)
            var ours = false
            if case let .globalBlock(_, _, key, _, _) = saved.layerInfoPlacement { ours = key == "Lr16" }
            #expect(ours && saved.globalBlocks.filter { $0.key == "Lr16" }.isEmpty, "exactly one Lr16 block: the document's own layers")
            #expect(saved.layers.count == 1)
        }
    }

    @Test func photoFilterPSDIsFourByteAlignedAndRoundTrips() throws {
        let color = SIMD3<Float>(60000, 30000, 0) / 65535
        let adjustment = Adjustment.photoFilter(.init(color: color, density: 0.14, preserveLuminosity: true))
        var doc = Document.withBackground(name: "Photo Filter PSD", size: PixelSize(width: 32, height: 24), mode: .rgb, depth: .u8, fill: .white)
        var layer = Layer(name: "Warming Filter", content: .adjustment(adjustment))
        doc.layers.append(layer)
        func assertPhfl(_ f: PSDFile, sourceLocation: SourceLocation = #_sourceLocation) {
            let data = f.layers.flatMap(\.blocks).first { $0.key == "phfl" }.map { [UInt8]($0.data) }
            #expect(data?.count == 20, "PSD layer block length includes four-byte padding", sourceLocation: sourceLocation)
            #expect(data.map { Array($0[0 ..< 2]) } == [0, 2], "version 2 RGB Photo Filter", sourceLocation: sourceLocation)
            #expect(data.map { Array($0[17...]) } == [0, 0, 0], "three padding bytes after the 17-byte payload", sourceLocation: sourceLocation)
        }
        let exported = psdFile(doc)
        assertPhfl(exported)
        let encoded = [UInt8](try exported.serialized())
        let parsed = try PSDFile(bytes: encoded)
        assertPhfl(parsed)
        try Self.lint(encoded)
        let restored = try PSDImport.document(parsed).document
        #expect(restored.layers.contains { $0.content == .adjustment(adjustment) })
        // A legacy 18-byte block still imports; saving it again repairs it even when the values
        // are unchanged (normally raw blocks are reused).
        var legacy = try #require(AdjustMap.write(adjustment).first).data
        legacy = Array(legacy.prefix(18))
        layer.psdBlocks = [PSDLayerBlock(key: "phfl", data: legacy)]
        doc.layers.removeLast()
        doc.layers.append(layer)
        let repaired = psdFile(doc)
        assertPhfl(repaired)
        assertPhfl(try PSDFile(bytes: [UInt8](try repaired.serialized())))
    }

    @Test func photoFilterVersion3IsKeptUntilEdited() throws {
        // The #3777 block (Photoshop CS2, XYZ colour): saved back byte-exact while unchanged.
        let v3: [UInt8] = [0, 3, 0, 0, 0x5E, 0x7F, 0, 0, 0x61, 0xAA, 0, 0, 0x0E, 0xF3, 0, 0, 0, 0x3F, 1, 0]
        let adjustment = AdjustMap.parse("phfl", v3, nil, .rgb)
        guard case let .photoFilter(pf) = adjustment else { Issue.record("\(adjustment)"); return }
        var doc = Document.withBackground(name: "Photo Filter v3", size: PixelSize(width: 8, height: 8), mode: .rgb, depth: .u8, fill: .white)
        var layer = Layer(name: "Photo Filter 1", content: .adjustment(adjustment))
        layer.psdBlocks = [PSDLayerBlock(key: "phfl", data: v3)]
        doc.layers.append(layer)
        func phfl(_ d: Document) throws -> [UInt8] {
            let f = try PSDFile(bytes: [UInt8](try psdFile(d).serialized()))
            return try #require(f.layers.flatMap(\.blocks).first { $0.key == "phfl" }.map { [UInt8]($0.data) })
        }
        #expect(try phfl(doc) == v3)
        // Once edited it is written as version 2 (RGB), and the colour survives.
        let n = doc.layers.count - 1
        doc.updateLayer(at: [n]) { $0.content = .adjustment(.photoFilter(.init(color: pf.color, density: 0.5, preserveLuminosity: true))) }
        let saved = try phfl(doc)
        #expect(Array(saved[0 ..< 2]) == [0, 2])
        guard case let .photoFilter(back) = AdjustMap.parse("phfl", saved, nil, .rgb) else { Issue.record("not a photo filter"); return }
        for c in 0 ..< 3 { #expect(abs(back.color[c] - pf.color[c]) <= 1 / 65535, "\(back.color) vs \(pf.color)") }
        #expect(back.density == 0.5)
    }

    @Test func sizeLimitBoundaryKeepsLimitAndSwitchesAboveIt() {
        #expect(!PSDExport.exceedsPSDSizeLimit(PSDExport.psdMaxFileSize))
        #expect(PSDExport.exceedsPSDSizeLimit(PSDExport.psdMaxFileSize + 1))
        #expect(PSDExport.exceedsPSDSizeLimit(nil))
    }

    @Test func encodedSizeEstimatorRejectsArithmeticOverflow() {
        #expect(PSDExport.estimateEncodedSize(UInt64.max, 0, 0) == nil)
        #expect(PSDExport.estimateEncodedSize(0, UInt64.max, 0) == nil)
        #expect(PSDExport.estimateEncodedSize(0, 0, UInt64.max) == UInt64.max)
        #expect(PSDExport.exceedsPSDSizeLimit(PSDExport.estimatePSDSize(Self.document(Int(UInt32.max), Int(UInt32.max)))))
    }

    @Test func largeEncodedSizeSelectsPSBWithoutChangingExplicitChoice() {
        let large = Self.document(30_000, 30_000)
        #expect(PSDExport.estimatePSDSize(large).map { $0 > PSDExport.psdMaxFileSize } == true)
        #expect(PSDExport.psdVersion(large, forcePSB: false, sizeExceedsLimit: PSDExport.psdSizeExceedsLimit(large)) == .psb)
        let small = Self.document(1, 1)
        let smallExceeds = PSDExport.psdSizeExceedsLimit(small)
        #expect(PSDExport.psdVersion(small, forcePSB: false, sizeExceedsLimit: smallExceeds) == .psd)
        #expect(PSDExport.psdVersion(small, forcePSB: true, sizeExceedsLimit: smallExceeds) == .psb)
    }

    @Test func keptPSBBlocksAreWrittenAs8BIMInAPSD() throws {
        // Photoshop 27.11 refuses a PSD holding `8B64` blocks ("not compatible with this
        // version"); they came from re-saving a PSB as PSD with its global FMsk and cinf kept.
        var doc = Self.document(4, 4)
        doc.metadata.psdGlobalBlocks = [PSDGlobalBlock(signature: "8B64", key: "FMsk", data: [0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 50]),
                                        PSDGlobalBlock(signature: "8BIM", key: "Patt", data: [])]
        func signatures(_ forcePSB: Bool) throws -> [String] {
            var o = PSDExportOptions(compositor: MapsKit.compositor)
            o.forcePSB = forcePSB
            let bytes = [UInt8](try PSDExport.file(doc, options: o).file.serialized())
            if !forcePSB { try Self.lint(bytes) }
            return try PSDFile(bytes: bytes).globalBlocks.map { "\($0.signature.string)/\($0.key.string)" }
        }
        #expect(try signatures(false) == ["8BIM/FMsk", "8BIM/Patt"])
        #expect(try signatures(true) == ["8B64/FMsk", "8BIM/Patt"], "a PSB keeps 8B64")
    }

    /// A layered document with transparency in the merged image and an alpha channel: the name
    /// and DisplayInfo resources hold one entry per extra channel, the merged transparency first,
    /// as in every file Photoshop opens. The alpha channel keeps its name and options.
    @Test func alphaNamesCountTheMergedTransparency() throws {
        var doc = Self.document(8, 6)
        var layer = Layer.raster("Layer 1", format: doc.pixelFormat)
        layer.withRaster { $0.fill(PixelRect(x0: 1, y0: 1, x1: 2, y1: 2), with: [1, 0, 0, 1]) }
        doc.layers.append(layer)
        var a = AlphaChannel(name: "Alpha 1", surface: Surface(format: PixelFormat(mode: .grayscale, sample: .u8, alpha: false)))
        a.opacity = 0.5
        doc.channels.append(a)
        let file = psdFile(doc)
        let headerExtra = Int(file.header.channels) - 3
        let pascal = [UInt8](try #require(file.resource(1006)).data)
        var (count, i) = (0, 0)
        while i < pascal.count {
            count += 1
            i += 1 + Int(pascal[i])
        }
        #expect(headerExtra == 2 && count == 2, "transparency + Alpha 1")
        #expect(try #require(file.resource(ChannelMap.displayInfo)).data.count == 4 + 2 * 13)
        let bytes = [UInt8](try file.serialized())
        try Self.lint(bytes)
        let back = try DocumentIO.importFile(name: "a.psd", bytes: bytes).document
        #expect(back.channels.count == 1)
        #expect(back.channels.first?.name == "Alpha 1")
        #expect(abs((back.channels.first?.opacity ?? 0) - 0.5) < 1e-6)
    }

    @Test func svgExtensionDoesNotOverrideAnotherFormatSignature() {
        let webp = Array("RIFF".utf8) + [4, 0, 0, 0] + Array("WEBP".utf8)
        #expect(!DocumentIO.isSVGInput("Firefox_logo,_2019.svg", webp))
        #expect(DocumentIO.isSVGInput("drawing.svg", Array("<?xml version=\"1.0\"?><svg/>".utf8)))
        #expect(DocumentIO.isSVGInput("drawing.svgz", [0x1F, 0x8B, 0, 0]))
        #expect(!DocumentIO.isSVGInput("drawing.svgz", webp))
    }

    @Test func thumbnailHeaderFollowsTheSpec() throws {
        let b = try PSDThumbnail.thumbnailBytes(160, 90, [0xFF, 0xD8, 0xFF, 0xD9])
        func u(_ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
        #expect([u(0), u(4), u(8), u(12), u(16), u(20)] == [1, 160, 90, 480, 480 * 90, 4])
        #expect(Array(b[24 ..< 28]) == [0, 24, 0, 1])
        #expect(Array(b[28...]) == [0xFF, 0xD8, 0xFF, 0xD9])
        // Width bytes are padded to 4: 3 px × 3 bytes = 9 → 12.
        let odd = try PSDThumbnail.thumbnailBytes(3, 1, [])
        #expect(UInt32(odd[12]) << 24 | UInt32(odd[13]) << 16 | UInt32(odd[14]) << 8 | UInt32(odd[15]) == 12)
    }

    @Test func emptyCMYKImagesConvertWithoutTrapping() {
        // flat.rs `cmyk_image_to_srgb`: zero width or height.
        for (w, h) in [(0, 0), (0, 7), (7, 0)] {
            let s = Surface(format: PixelFormat(mode: .cmyk, sample: .u8, alpha: true))
            let out = DocumentIO.srgb(s, PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h)))
            #expect(out.format.mode == .rgb)
        }
    }

    @Test func bandedCMYKConversionCoversEveryRow() {
        // One colour everywhere converts to one colour everywhere, first row to last (over more
        // than one 256-row band).
        let (w, h) = (5, 600)
        var s = Surface(format: PixelFormat(mode: .cmyk, sample: .u8, alpha: true))
        let r = PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h))
        s.fill(r, with: [40, 90, 10, 20, 255].map { Float($0) / 255 })
        let out = DocumentIO.srgb(s, r).readRegion(r)
        let first = Array(out[0 ..< 4])
        #expect(stride(from: 0, to: out.count, by: 4).allSatisfy { Array(out[$0 ..< $0 + 4]) == first })
        #expect(first[3] == 1)
    }
}
