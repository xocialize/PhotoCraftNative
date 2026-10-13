// Port of photocraft-io (crates/io/tests/exif_resolution.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// #1691: the EXIF resolution of an imported photo becomes the document's, and a PSD save keeps
// its EXIF copy in step with the ResolutionInfo resource. photocraft's fixture is a WebP (a format
// without a resolution of its own); ImageIO cannot write WebP, so a PNG without a pHYs chunk and
// with the same EXIF in eXIf stands in for it.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIO

@Suite struct EXIFResolutionTests {
    init() { ExportSweep.install() }
    typealias Kit = FlatKit

    /// Big-endian EXIF: XResolution 300/1, YResolution 300/1, ResolutionUnit 2.
    static func cameraEXIF() -> [UInt8] {
        func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
        var v: [UInt8] = Array("MM\0*".utf8) + Kit.be32(8) + be16(3)
        let data = UInt32(8 + 2 + 3 * 12 + 4)
        for (tag, value) in [(UInt16(282), data), (283, data + 8)] { v += be16(tag) + be16(5) + Kit.be32(1) + Kit.be32(value) }
        v += be16(296) + be16(3) + Kit.be32(1) + [0, 2, 0, 0]
        v += Kit.be32(0)
        for _ in 0 ..< 2 { v += Kit.be32(300) + Kit.be32(1) }
        return v
    }

    @Test func photoWithEXIFResolutionImportsAtItAndPSDSaveFollowsTheDocument() throws {
        let plain = try #require(Kit.imageIO([UInt8](repeating: 50, count: 72), width: 6, height: 4, bpc: 8, alpha: false))
        let png = Kit.inserting(Kit.removingChunks(plain, "pHYs"), [Kit.chunk("eXIf", Self.cameraEXIF())])
        var doc = try Kit.importFile("photo.png", png).document
        #expect(doc.resolutionDpi == 300)

        doc.resolutionDpi = 240
        let psd = try Kit.export(doc, "photo.psd").bytes
        let back = try Kit.importFile("photo.psd", psd).document
        #expect(back.resolutionDpi == 240)
        let r = back.metadata.exif.flatMap(MetadataExport.exifResolution)
        #expect(r?.0 == 240 && r?.1 == 240, "\(String(describing: r))")
    }
}
