// Port of photocraft-io (crates/io/tests/heif.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// HEIC photos (#355) open as documents through the same import File › Open uses, upright, with
// their EXIF and XMP, and an export never turns them a second time. photocraft reads its fixtures
// from `corpus/heif`; here ImageIO writes equivalent HEICs (the 2048×1536 photo is 64×48, the
// 10-bit RGBA file 29×100).

import CoreGraphics
import Foundation
import ImageIO
import PCDocument
import PCFoundation
import PCIOCore
import Testing
import UniformTypeIdentifiers
@testable import PCIO

@Suite struct HEIFTests {
    init() { ExportSweep.install() }
    typealias Kit = FlatKit

    /// A HEIC of `w`×`h` 8- or 16-bit RGB(A) stripes, with EXIF and XMP when given.
    static func heic(_ w: Int, _ h: Int, bpc: Int = 8, alpha: Bool = false, exif: [CFString: Any]? = nil, xmp: String? = nil) throws -> [UInt8] {
        let ch = alpha ? 4 : 3
        var samples: [UInt16] = []
        for y in 0 ..< h {
            for x in 0 ..< w {
                let v: UInt16 = (x / 8) % 2 == 0 ? 220 : 40
                samples += [v, UInt16((y * 7) % 256), 255 - v] + (alpha ? [UInt16(128 + (x % 2) * 127)] : [])
            }
        }
        let bytes = bpc == 8 ? samples.map { UInt8($0) } : Kit.be16(samples.map { $0 * 257 })
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var info = alpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.none.rawValue
        if bpc == 16 { info |= CGBitmapInfo.byteOrder16Big.rawValue }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let img = try #require(CGImage(width: w, height: h, bitsPerComponent: bpc, bitsPerPixel: bpc * ch, bytesPerRow: w * ch * bpc / 8, space: space,
                                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let out = NSMutableData()
        let dst = try #require(CGImageDestinationCreateWithData(out as CFMutableData, UTType.heic.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if let exif { props[kCGImagePropertyExifDictionary] = exif }
        if let xmp, let meta = CGImageMetadataCreateFromXMPData(Data(xmp.utf8) as CFData) {
            CGImageDestinationAddImageAndMetadata(dst, img, meta, props as CFDictionary)
        } else {
            CGImageDestinationAddImage(dst, img, props as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(dst))
        return [UInt8](out as Data)
    }

    static func strips() throws -> [UInt8] { try heic(96, 32) }

    @Test func heicOpensAsAn8BitRGBDocument() throws {
        let r = try Kit.importFile("IMG_0001.HEIC", try Self.strips())
        let d = r.document
        #expect(d.size == PixelSize(width: 96, height: 32))
        #expect(d.mode == .rgb && d.depth == .u8)
        #expect(d.layers.count == 1)
        #expect(r.warnings.isEmpty, "\(r.warnings)")
    }

    @Test func tenBitHEICOpensAsA16BitDocumentWithTransparency() throws {
        let bytes = try Self.heic(29, 100, bpc: 16, alpha: true)
        let src = try #require(CGImageSourceCreateWithData(Data(bytes) as CFData, nil))
        let depth = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyDepth] as? Int
        try #require((depth ?? 0) > 8, "ImageIO wrote a \(String(describing: depth))-bit HEIC")
        let d = try Kit.importFile("hdr.heic", bytes).document
        #expect(d.size == PixelSize(width: 29, height: 100))
        #expect(d.mode == .rgb && d.depth == .u16)
        #expect(d.layers.first?.locks.transparency == false, "an image with alpha opens as an unlocked layer")
    }

    @Test func heicMetadataReachesTheDocumentAndExportsUpright() throws {
        let xmp = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:format>image/heic</dc:format></rdf:Description></rdf:RDF></x:xmpmeta>"
        let bytes = try Self.heic(64, 48, exif: [kCGImagePropertyExifUserComment: "fixture"], xmp: xmp)
        let r = try Kit.importFile("photo.heic", bytes)
        let d = r.document
        #expect(d.size == PixelSize(width: 64, height: 48))
        // HEIC's container isn't parsed by FlatMetadata: ImageIO's properties and metadata supply them.
        #expect(d.metadata.exif != nil && d.metadata.xmp?.contains("x:xmpmeta") == true)
        #expect(d.metadata.xmp?.contains("image/heic") == true, "the file's own XMP")
        // HEIC is read-only: save the photo as a JPEG, which keeps the EXIF with Orientation 1.
        let out = try Kit.export(d, "photo.jpg")
        #expect(out.bytes.starts(with: [0xFF, 0xD8, 0xFF]))
        let back = try Kit.decode(out.bytes)
        #expect(back.width == 64 && back.height == 48)
        #expect(back.exif.map(Kit.exifOrientation) == 1)
    }

    @Test func heicCannotBeWrittenAndSaysSo() throws {
        let d = try Kit.importFile("x.heic", try Self.strips()).document
        #expect(throws: (any Error).self) { try Kit.export(d, "x.heic") }
    }

    @Test func brokenHEICIsAnErrorNotACrash() throws {
        let strips = try Self.strips()
        for cut in [0, 12, 40, strips.count / 2, strips.count - 1] {
            withKnownIssue("ImageIO decodes a HEIC that is one byte short without an error (photocraft's decoder refuses it)") {
                #expect(throws: (any Error).self, "cut at \(cut)") { try Kit.importFile("x.heic", Array(strips[..<cut])) }
            } when: { cut == strips.count - 1 }
        }
    }
}
