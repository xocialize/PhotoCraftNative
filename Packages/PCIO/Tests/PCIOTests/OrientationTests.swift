// Port of photocraft-io (crates/io/tests/orientation.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// EXIF orientation through the document layer (#285): an iPhone-style JPEG (stored landscape,
// Orientation = 6) opens as an upright portrait document, and every export writes
// Orientation = 1 so it is never rotated twice. The JPEG fixtures are written with ImageIO. WebP
// export and the camera-raw preview case (`raw_preview_is_turned_upright_exactly_once`) are
// PCPlatform's codec layer.

import Foundation
import ImageIO
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import Testing
import UniformTypeIdentifiers
@testable import PCIO

@Suite struct OrientationTests {
    init() { ExportSweep.install() }
    typealias Kit = FlatKit

    /// Upright 16×32 portrait: red top-left quarter, green top-right, blue bottom half.
    static func uprightColor(_ x: Int, _ y: Int) -> [UInt8] {
        switch (x < 8, y < 16) {
        case (true, true): [230, 20, 20]
        case (false, true): [20, 230, 20]
        default: [20, 20, 230]
        }
    }

    /// The same scene as a camera stores it for Orientation = 6 (32×16 landscape), as JPEG.
    static func storedOrientation6(quality: Double?) throws -> [UInt8] {
        let (w, h) = (16, 32)
        var px = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0 ..< h {
            for x in 0 ..< w {
                // Upright (x, y) sits at stored (y, w - 1 - x) in a 32-wide image.
                let (sx, sy) = (y, w - 1 - x)
                px.replaceSubrange((sy * h + sx) * 3 ..< (sy * h + sx) * 3 + 3, with: uprightColor(x, y))
            }
        }
        let props: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        return try #require(Kit.imageIO(px, width: h, height: w, bpc: 8, alpha: false, type: .jpeg, properties: props))
    }

    static func iphoneJPEG() throws -> [UInt8] { Kit.jpegWithExif(try storedOrientation6(quality: 1), Kit.exif(orientation: 6)) }

    static func expectUpright(_ img: DecodedImage, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(img.width == 16 && img.height == 32, "\(what)", sourceLocation: sourceLocation)
        guard img.width == 16, img.height == 32 else { return }
        for (x, y) in [(3, 4), (12, 4), (3, 28), (12, 28)] {
            let got = img.surface.rgba(x: Int32(x), y: Int32(y))
            let want = uprightColor(x, y)
            let ok = (0 ..< 3).allSatisfy { abs(Int((got[$0] * 255).rounded()) - Int(want[$0])) <= 12 }
            #expect(ok, "\(what) (\(x),\(y)): \(got) vs \(want)", sourceLocation: sourceLocation)
        }
    }

    @Test func rotatedJPEGOpensUprightAndExportsWithOrientation1() throws {
        let r = try Kit.importFile("IMG_0001.JPG", try Self.iphoneJPEG())
        let d = r.document
        #expect(d.size == PixelSize(width: 16, height: 32), "portrait, like Photoshop")
        #expect(Kit.exifOrientation(try #require(d.metadata.exif)) == 1, "the document's EXIF says upright")
        for ext in ["jpg", "png", "tif"] {
            let out = try Kit.export(d, ext).bytes
            #expect(Kit.exifOrientation(out) == 1, "\(ext): a TIFF file's own tag")
            let back = try Kit.decode(out)
            if let e = back.exif { #expect(Kit.exifOrientation(e) == 1, "\(ext)") }
            Self.expectUpright(back, ext)
            // Open → save → reopen: the same upright document.
            let again = try Kit.importFile("again.\(ext)", out).document
            #expect(again.size == PixelSize(width: 16, height: 32), "\(ext)")
        }
    }

    @Test func staleOrientationInDocumentMetadataIsNeverExported() throws {
        // A document whose EXIF still says 6 (a PSD from elsewhere, or rotated by hand as in #285).
        var d = try Kit.importFile("IMG_0001.JPG", try Self.iphoneJPEG()).document
        d.metadata.exif = Kit.exif(orientation: 6)
        d.metadata.xmp = #"<rdf:Description tiff:Orientation="6"/>"#
        // photocraft first exports with Metadata: None (`XmpEmbed::None`), which PCIO's IOOptions
        // can't express; the default export embeds both, the orientation rewritten upright.
        let jpg = try Kit.export(d, "jpg").bytes
        let back = try Kit.decode(jpg)
        #expect(back.exif.map(Kit.exifOrientation) == 1, "\(String(describing: back.exif))")
        #expect(back.xmp?.contains(#"tiff:Orientation="1""#) == true, "\(String(describing: back.xmp))")
        Self.expectUpright(back, "jpg")

        let psd = try Kit.export(d, "psd").bytes
        let file = try PSDFile(bytes: psd)
        let e = try #require(file.resource(1058), "EXIF resource")
        #expect(Kit.exifOrientation([UInt8](e.data)) == 1)
        let x = try #require(file.resource(1060), "XMP resource")
        #expect(String(decoding: x.data, as: UTF8.self).contains(#"tiff:Orientation="1""#))
    }

    @Test func malformedEXIFOpensWithoutTrapping() throws {
        let jpeg = try Self.storedOrientation6(quality: nil)
        var huge = Kit.exif(orientation: 6)
        huge.replaceSubrange(8 ..< 10, with: [0xFF, 0xFF])
        huge.removeLast(huge.count - 14)
        for e in [[], Array("MM\0*".utf8), Kit.exif(orientation: 0), Kit.exif(orientation: 9), Kit.exif(orientation: .max), huge] {
            let r = try Kit.importFile("x.jpg", Kit.jpegWithExif(jpeg, e))
            #expect(r.document.size == PixelSize(width: 32, height: 16), "\(e) reads as Orientation 1")
        }
    }
}
