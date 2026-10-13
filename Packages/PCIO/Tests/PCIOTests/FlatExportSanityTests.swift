// Flat export through the default codec: transparency, CMYK, metadata and resolution (photocraft
// `flat::export_flat` semantics), read back through `DocumentIO.importFile`.
// Port of photocraft-io's flat export behaviour (crates/io/src/flat.rs), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIO

@Suite struct FlatExportSanityTests {
    init() { ExportSweep.install() }
    static func doc(_ mode: ColorMode = .rgb, alpha: Float) -> Document {
        var d = Document(name: "f", size: PixelSize(width: 4, height: 2), mode: mode, depth: .u8)
        var l = Layer.raster("a", format: d.pixelFormat)
        l.withRaster { $0.fill(PixelRect(x0: 0, y0: 0, x1: 4, y1: 2), with: d.pixelFormat.components(fromRGBA: SIMD4(1, 0, 0, alpha))) }
        d.layers = [l]
        d.resolutionDpi = 300
        return d
    }

    @Test func jpegMattesTransparencyOverWhite() throws {
        let r = try DocumentIO.export(Self.doc(alpha: 0.5), as: "x.jpg", options: IOOptions(compositor: StoredPixelsCompositor()))
        #expect(r.warnings.contains("transparency composited over white for Jpeg"), "\(r.warnings)")
        let back = try DocumentIO.importFile(name: "x.jpg", bytes: r.bytes).document
        let px = try #require(back.layers.first?.surface).readRGBA(back.bounds)[0]
        // Red at 50 % over white: (1, 0.5, 0.5), within JPEG error.
        #expect(abs(px.x - 1) < 0.03 && abs(px.y - 0.5) < 0.03 && abs(px.z - 0.5) < 0.03, "\(px)")
        #expect(back.layers.first?.name == "Background")
        #expect(abs(back.resolutionDpi - 300) < 0.5)
    }

    @Test func opaquePNGDropsAlphaAndTransparentKeepsIt() throws {
        let opaque = try DocumentIO.export(Self.doc(alpha: 1), as: "x.png", options: IOOptions(compositor: StoredPixelsCompositor()))
        let reopened = try DocumentIO.importFile(name: "x.png", bytes: opaque.bytes).document
        #expect(reopened.layers.first?.name == "Background")
        // No metadata appears that the document didn't have.
        #expect(reopened.metadata.exif == nil && reopened.metadata.xmp == nil && reopened.metadata.text.isEmpty, "\(reopened.metadata)")
        for ext in ["jpg", "tif"] {
            let r = try DocumentIO.export(Self.doc(alpha: 1), as: "x.\(ext)", options: IOOptions(compositor: StoredPixelsCompositor()))
            let m = try DocumentIO.importFile(name: "x.\(ext)", bytes: r.bytes).document.metadata
            #expect(m.exif == nil && m.text.isEmpty, "\(ext): \(m)")
        }
        let clear = try DocumentIO.export(Self.doc(alpha: 0.25), as: "x.png", options: IOOptions(compositor: StoredPixelsCompositor()))
        let back = try DocumentIO.importFile(name: "x.png", bytes: clear.bytes).document
        #expect(back.layers.first?.name == "Layer 0")
        let px = try #require(back.layers.first?.surface).readRGBA(back.bounds)[0]
        #expect(px == SIMD4(1, 0, 0, Float(64) / 255), "straight alpha kept exactly: \(px)")
    }

    @Test func pngCarriesExifXmpTextAndResolution() throws {
        var d = Self.doc(alpha: 1)
        // A minimal big-endian EXIF with Orientation 6: written upright (1).
        d.metadata.exif = [0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 6, 0, 0, 0, 0, 0, 0, 0, 0]
        d.metadata.xmp = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"/></x:xmpmeta>"
        d.metadata.text = [MetadataText("Author", "Jörg"), MetadataText("Title", "日本")]
        let r = try DocumentIO.export(d, as: "x.png", options: IOOptions(compositor: StoredPixelsCompositor()))
        let back = try DocumentIO.importFile(name: "x.png", bytes: r.bytes).document
        #expect(back.metadata.text == d.metadata.text)
        #expect(back.metadata.xmp?.contains("adobe:ns:meta/") == true)
        let exif = try #require(back.metadata.exif)
        #expect(exif.starts(with: [0x4D, 0x4D, 0, 42]))
        #expect(exif[19] == 1, "orientation written upright")
        #expect(abs(back.resolutionDpi - 300) < 0.5)
    }

    @Test func cmykBecomesSRGBInPNG() throws {
        let r = try DocumentIO.export(Self.doc(.cmyk, alpha: 1), as: "x.png", options: IOOptions(compositor: StoredPixelsCompositor()))
        #expect(r.warnings.contains("CMYK converted to sRGB for Png through the document's colour profile"), "\(r.warnings)")
        let back = try DocumentIO.importFile(name: "x.png", bytes: r.bytes).document
        #expect(back.mode == .rgb)
    }

    @Test func removingLayeredOnlyXMPElements() {
        let x = "<a><photoshop:TextLayers><rdf:Bag><rdf:li>t</rdf:li></rdf:Bag></photoshop:TextLayers><xmpMM:DocumentAncestors/><b:TextLayersX>k</b:TextLayersX></a>"
        let out = FlatMetadata.layeredOnlyXMP.reduce(x) { FlatMetadata.removingXMPElement($0, $1) }
        #expect(out == "<a><b:TextLayersX>k</b:TextLayersX></a>")
    }
}
