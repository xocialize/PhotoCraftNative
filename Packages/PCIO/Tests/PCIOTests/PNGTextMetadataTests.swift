// Port of photocraft-io (crates/io/tests/png_text_metadata.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// PNG text survives open, native save/reopen and PNG save without a false loss warning. The
// source PNGs are ImageIO PNGs with photocraft's text chunks added by hand (tEXt for Latin-1
// values, iTXt otherwise, XMP as iTXt). photocraft's Metadata: None (`XmpEmbed::None`) and
// `embed_metadata: false` halves have no PCIO option to express them and are left out.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIO

@Suite struct PNGTextMetadataTests {
    init() { ExportSweep.install() }
    typealias Kit = FlatKit

    static let text: [MetadataText] = [
        MetadataText("Creation Time", "Fri, 09 Oct 2026 07:00:00 GMT"),
        MetadataText("Author", "Synthetic author"),
        MetadataText("Description", "Synthetic description é"),
        MetadataText("Title", "Unicode 雪"),
        MetadataText("Comment", "first"),
        MetadataText("Comment", "second"),
    ]
    static let xmp = "<x:xmpmeta xmlns:x='adobe:ns:meta/'/>"

    /// A text chunk: tEXt when the value is Latin-1, iTXt otherwise.
    static func textChunk(_ t: MetadataText) -> [UInt8] {
        let latin1 = t.value.unicodeScalars.allSatisfy { $0.value < 256 }
        if latin1 { return Kit.chunk("tEXt", Array(t.key.utf8) + [0] + t.value.unicodeScalars.map { UInt8($0.value) }) }
        return Kit.chunk("iTXt", Array(t.key.utf8) + [0, 0, 0, 0, 0] + Array(t.value.utf8))
    }

    /// The 1×1 source image (31, 127, 223) at `sample` depth, with the text and XMP.
    static func source(_ sample: SampleType) throws -> [UInt8] {
        let px: [UInt8] = [31, 127, 223]
        let png = try #require(sample == .u8 ? Kit.imageIO(px, width: 1, height: 1, bpc: 8, alpha: false)
            : Kit.imageIO(Kit.be16(px.map { UInt16($0) * 257 }), width: 1, height: 1, bpc: 16, alpha: false))
        let xmpChunk = Kit.chunk("iTXt", Array(FlatMetadata.xmpKeyword.utf8) + [0, 0, 0, 0, 0] + Array(xmp.utf8))
        return Kit.inserting(png, text.map(textChunk) + [xmpChunk])
    }

    @Test(arguments: [SampleType.u8, .u16]) func pngTextSurvivesNativeAndPNGSavesAtBothDepths(_ sample: SampleType) throws {
        let png = try Self.source(sample)
        let original = try ImageIOCodec().decode(png)
        let opened = try Kit.importFile("synthetic.png", png)
        #expect(opened.warnings.isEmpty, "\(opened.warnings)")
        let native = try Kit.export(opened.document, "pcraft")
        let reopened = try Kit.importFile("synthetic.pcraft", native.bytes)
        let saved = try Kit.export(reopened.document, "png")
        #expect(saved.warnings.isEmpty, "\(saved.warnings)")
        let back = try ImageIOCodec().decode(saved.bytes)
        #expect(back.text == original.text, "duplicates and Unicode must survive: \(back.text)")
        #expect(back.xmp == original.xmp)
        #expect(back.surface.format.sample == sample)
        let rect = PixelRect(x0: 0, y0: 0, x1: 1, y1: 1)
        #expect(Array(back.surface.readRegion(rect).prefix(3)) == Array(original.surface.readRegion(rect).prefix(3)), "pixels must not change")
    }

    @Test func defaultSaveKeepsPNGText() throws {
        let png = try Self.source(.u8)
        let doc = try Kit.importFile("synthetic.png", png).document
        let saved = try Kit.export(doc, "png")
        #expect(try ImageIOCodec().decode(saved.bytes).text == ImageIOCodec().decode(png).text)
    }

    @Test func formatsWithoutTextSupportReportTheLossOnExport() throws {
        let doc = try Kit.importFile("synthetic.png", try Self.source(.u8)).document
        for ext in ["jpg", "psd", "psb"] {
            let saved = try Kit.export(doc, ext)
            if ext == "jpg" { #expect(saved.warnings.contains { $0.contains("text metadata") }, "\(ext): \(saved.warnings)") }
        }
    }

    @Test func palettePNGReportsUnsupportedTextWhenEmbedding() throws {
        var doc = try Kit.importFile("synthetic.png", try Self.source(.u8)).document
        doc.mode = .indexed
        doc.colorTable = ColorTable(colors: [SIMD3(31, 127, 223)])
        let saved = try Kit.export(doc, "png")
        #expect(saved.warnings.contains { $0.contains("text metadata") }, "\(saved.warnings)")
    }

    @Test(arguments: [false, true]) func tiffTextSurvivesFlatAndLayeredSaves(_ tiffLayers: Bool) throws {
        var doc = try Kit.importFile("synthetic.png", try Self.source(.u16)).document
        // TIFF's supported ASCII tag names, rather than arbitrary PNG keywords.
        doc.metadata.text = [MetadataText("Description", "Synthetic description"), MetadataText("Artist", "Synthetic author")]
        var overlay = doc.layers[0]
        overlay.id = .fresh()
        doc.layers.append(overlay)
        let saved = try Kit.export(doc, "tif", options: Kit.options(tiffLayers: tiffLayers))
        let opened = try Kit.importFile("synthetic.tif", saved.bytes)
        if tiffLayers { #expect(opened.document.metadata.text == doc.metadata.text, "\(opened.document.metadata.text)") }
        #expect(!opened.warnings.contains { $0.contains("text metadata") }, "\(opened.warnings)")
        #expect(doc.metadata.text.count == 2, "export must not mutate the document")
    }
}
