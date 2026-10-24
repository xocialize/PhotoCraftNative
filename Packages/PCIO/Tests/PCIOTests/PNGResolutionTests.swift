// A PNG's pHYs resolution opens at whole ppi on each axis, as Photoshop 27.11 opens it
// (AB-D-0156; measured in AB-L-0305: 2835 px/m → 72, 2900 → 74, 11811 → 300). Writing is
// unchanged: 72 ppi is stored as 2835 px/m and reads back as 72. New in the port.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIO

@Suite struct PNGResolutionTests {
    init() { ExportSweep.install() }
    typealias Kit = FlatKit

    /// A 2 × 2 RGB PNG whose only resolution is `pHYs` (x, y) in pixels per metre, plus `xmp` in
    /// an iTXt chunk when given.
    static func png(ppm: (UInt32, UInt32)?, xmp: String? = nil) throws -> [UInt8] {
        let plain = try #require(Kit.imageIO([UInt8](repeating: 10, count: 12), width: 2, height: 2, bpc: 8, alpha: false))
        var chunks: [[UInt8]] = []
        if let p = ppm { chunks.append(Kit.chunk("pHYs", Kit.be32(p.0) + Kit.be32(p.1) + [1])) }
        if let x = xmp { chunks.append(Kit.chunk("iTXt", Array(FlatMetadata.xmpKeyword.utf8) + [0, 0, 0, 0, 0] + Array(x.utf8))) }
        return Kit.inserting(Kit.removingChunks(plain, "pHYs"), chunks)
    }

    /// The XMP Photoshop writes into a 72-ppi PNG's iTXt (AB-L-0305), cut to its resolution.
    static let photoshopXMP = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:tiff="http://ns.adobe.com/tiff/1.0/" tiff:XResolution="720000/10000" \
        tiff:YResolution="720000/10000" tiff:ResolutionUnit="2"/></rdf:RDF></x:xmpmeta>
        """

    @Test(arguments: [(UInt32(2835), Float(72)), (2900, 74), (11811, 300)])
    func pHYsOpensAtWholePPI(_ ppm: UInt32, _ ppi: Float) throws {
        let png = try Self.png(ppm: (ppm, ppm))
        #expect(FlatMetadata.read(png).dpi == SIMD2(repeating: Double(ppi)))
        let r = try Kit.importFile("x.png", png)
        #expect(r.document.resolutionDpi == ppi, "\(r.document.resolutionDpi)")
        #expect(r.warnings.isEmpty, "\(r.warnings)")
    }

    @Test func unequalAxesRoundIndependently() throws {
        let png = try Self.png(ppm: (11811, 2900))
        #expect(FlatMetadata.read(png).dpi == SIMD2(300, 74))
        let r = try Kit.importFile("x.png", png)
        #expect(r.document.resolutionDpi == 300)
        #expect(r.warnings.contains { $0.contains("74.00") && $0.contains("300.00") }, "\(r.warnings)")
    }

    @Test func belowHalfAPPIStaysExact() throws {
        #expect(FlatMetadata.pngPPI(10) == 10 * 0.0254)
        #expect(FlatMetadata.pngPPI(20) == 1)
    }

    @Test func seventyTwoPPIWritesItsPHYsAndReadsBackAs72() throws {
        var d = Document.withBackground(name: "x", size: PixelSize(width: 4, height: 2), mode: .rgb, depth: .u8, fill: .rgb(0.5, 0.5, 0.5, 1))
        d.resolutionDpi = 72
        let bytes = try Kit.export(d, "x.png").bytes
        let at = try #require(bytes.indices.first { bytes[$0...].starts(with: Array("pHYs".utf8)) })
        #expect(Array(bytes[at + 4 ..< at + 13]) == Kit.be32(2835) + Kit.be32(2835) + [1], "72 ppi is stored as 2835 px/m")
        #expect(try Kit.importFile("x.png", bytes).document.resolutionDpi == 72)
    }

    /// The XMP `tiff:` resolution counts only when the PNG has no `pHYs` (DocumentIO's order:
    /// the format's own resolution, then EXIF, then XMP); with one, `pHYs` wins.
    @Test func pHYsWinsOverXMPResolution() throws {
        #expect(MetadataExport.xmpResolution(Self.photoshopXMP).map { [$0.0, $0.1] } == [72, 72])
        // Photoshop's own 72-ppi PNG: pHYs 2835 + XMP 72.
        #expect(try Kit.importFile("x.png", try Self.png(ppm: (2835, 2835), xmp: Self.photoshopXMP)).document.resolutionDpi == 72)
        // pHYs and XMP disagree: pHYs.
        #expect(try Kit.importFile("x.png", try Self.png(ppm: (11811, 11811), xmp: Self.photoshopXMP)).document.resolutionDpi == 300)
        // No pHYs: the XMP's.
        #expect(try Kit.importFile("x.png", try Self.png(ppm: nil, xmp: Self.photoshopXMP)).document.resolutionDpi == 72)
    }
}
