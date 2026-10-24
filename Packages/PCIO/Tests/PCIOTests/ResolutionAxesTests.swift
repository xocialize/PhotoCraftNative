// Port of photocraft-io (crates/io/tests/resolution_axes.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// A file whose horizontal and vertical resolutions differ opens at the horizontal one, and the
// import says the vertical one is not kept (#1018). Equal axes, the common case, open silently.
// The PNG fixtures are written by ImageIO, the PSDs by PCPSD's builder (photocraft
// `testgen::small`), the layered TIFFs re-encoded with `LayeredTIFF.write`.

import Foundation
import ImageIO
import PCDocument
import PCFoundation
import PCIOCore
import PCIOFormats
import PCPSD
import Testing
@testable import PCIO

@Suite struct ResolutionAxesTests {
    init() { ExportSweep.install() }
    typealias Kit = FlatKit

    static func resolutionNotes(_ r: ImportResult) -> [String] { r.warnings.filter { $0.contains("vertical resolution") } }

    static func png(_ dpi: (Double, Double)) throws -> [UInt8] {
        try #require(Kit.imageIO([UInt8](repeating: 10, count: 12), width: 2, height: 2, bpc: 8, alpha: false,
                                 properties: [kCGImagePropertyDPIWidth: dpi.0, kCGImagePropertyDPIHeight: dpi.1]))
    }

    @Test func pngWithUnequalAxesReportsTheDroppedVerticalResolution() throws {
        let png = try Self.png((300, 150))
        let r = try Kit.importFile("x.png", png)
        #expect(abs(r.document.resolutionDpi - 300) < 0.01, "\(r.document.resolutionDpi)")
        let notes = Self.resolutionNotes(r)
        #expect(notes.count == 1, "\(r.warnings)")
        // 150 ppi is stored as 5906 pixels per metre: 150.01 ppi, as in photocraft's fixture; it
        // opens at whole ppi, as in Photoshop (AB-D-0156).
        #expect(Self.pHYsY(png).map { String(format: "%.2f", $0) } == "150.01")
        #expect(notes.first.map { $0.contains("150.00") && $0.contains("300.00") } == true, "\(notes)")
    }

    /// The vertical resolution (ppi) of a PNG's pHYs chunk.
    static func pHYsY(_ png: [UInt8]) -> Double? {
        guard let at = png.indices.first(where: { png[$0...].starts(with: Array("pHYs".utf8)) }), at + 13 <= png.count else { return nil }
        let y = UInt32(png[at + 8]) << 24 | UInt32(png[at + 9]) << 16 | UInt32(png[at + 10]) << 8 | UInt32(png[at + 11])
        return png[at + 12] == 1 ? Double(y) * 0.0254 : nil
    }

    @Test func pngWithEqualAxesOpensSilently() throws {
        let r = try Kit.importFile("x.png", try Self.png((300, 300)))
        #expect(abs(r.document.resolutionDpi - 300) < 0.01, "\(r.document.resolutionDpi)")
        #expect(r.warnings.isEmpty, "\(r.warnings)")
    }

    /// A small raw-compressed PSD with `ri` as its ResolutionInfo.
    static func psd(_ ri: PSDResolutionInfo) throws -> [UInt8] {
        var b = PSDBuilder(width: 4, height: 4)
        b.compression = .raw
        b.mergedCompression = .raw
        b.resources = [PSDImageResource(id: PSDResourceID.resolutionInfo, data: ri.serialized())]
        b.pushLayer(PSDLayerSpec(name: "Layer 1", left: 0, top: 0, width: 2, height: 2, pixels: .u8([UInt8](repeating: 200, count: 16))))
        return [UInt8](try b.serialized())
    }

    @Test func psdWithUnequalAxesReportsTheDroppedVerticalResolution() throws {
        var ri = PSDResolutionInfo(dpi: 300)
        ri.vResFixed = PSDResolutionInfo(dpi: 150).vResFixed
        let r = try Kit.importFile("x.psd", try Self.psd(ri))
        #expect(abs(r.document.resolutionDpi - 300) < 1e-3, "\(r.document.resolutionDpi)")
        let notes = Self.resolutionNotes(r)
        #expect(notes.count == 1, "\(r.warnings)")
        #expect(notes.first.map { $0.contains("150.00") && $0.contains("300.00") } == true, "\(notes)")
    }

    @Test func psdWithEqualAxesOpensSilently() throws {
        let r = try Kit.importFile("x.psd", try Self.psd(PSDResolutionInfo(dpi: 300)))
        #expect(abs(r.document.resolutionDpi - 300) < 1e-3, "\(r.document.resolutionDpi)")
        #expect(Self.resolutionNotes(r).isEmpty, "\(r.warnings)")
        // Each axis is read in its own unit: 100 pixels per centimetre on both is 254 ppi on both.
        var cm = PSDResolutionInfo(dpi: 100)
        cm.hResUnit = 2
        cm.vResUnit = 2
        let r2 = try Kit.importFile("x.psd", try Self.psd(cm))
        #expect(abs(r2.document.resolutionDpi - 254) < 1e-3, "\(r2.document.resolutionDpi)")
        #expect(Self.resolutionNotes(r2).isEmpty, "\(r2.warnings)")
    }

    /// A layered TIFF (which opens through the PSD importer) with the TIFF's own resolution tags
    /// set to `dpi`.
    static func layeredTIFF(_ dpi: (Double, Double)) throws -> [UInt8] {
        let out = try Kit.export(genDoc(.rgb, .u8, .pixels), "x.tif", options: Kit.options(tiffLayers: true))
        #expect(Kit.tags(out.bytes).layers != nil, "layer data")
        return try Kit.rewriteTIFF(out.bytes, dpi: (dpi.0, dpi.1))
    }

    @Test func layeredTIFFWithUnequalAxesReportsTheDroppedVerticalResolution() throws {
        let r = try Kit.importFile("x.tif", try Self.layeredTIFF((300, 150)))
        #expect(r.document.layers.count > 1, "opened with its layers")
        #expect(abs(r.document.resolutionDpi - 300) < 1e-3, "\(r.document.resolutionDpi)")
        let notes = Self.resolutionNotes(r)
        #expect(notes.count == 1, "\(r.warnings)")
        #expect(notes.first.map { $0.contains("150.00") && $0.contains("300.00") } == true, "\(notes)")
        // Equal axes: no note.
        let r2 = try Kit.importFile("x.tif", try Self.layeredTIFF((300, 300)))
        #expect(Self.resolutionNotes(r2).isEmpty, "\(r2.warnings)")
    }
}
