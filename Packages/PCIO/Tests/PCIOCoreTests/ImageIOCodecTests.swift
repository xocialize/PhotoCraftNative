// ImageIOCodec decoding (straight alpha, Gray + alpha, 16-bit, half floats) and the container
// metadata reader. New in the port (photocraft-codecs' own decoder tests cover its decoders);
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import ImageIO
import PCDocument
import PCFoundation
import Testing
import UniformTypeIdentifiers
@testable import PCIOCore

enum CodecKit {
    /// Encodes raw interleaved big-endian samples with ImageIO.
    static func encode(_ samples: [UInt8], width: Int, height: Int, bpc: Int, gray: Bool, alpha: Bool, float: Bool = false,
                       type: UTType = .png, properties: [CFString: Any] = [:]) -> [UInt8]? {
        let comps = (gray ? 1 : 3) + (alpha ? 1 : 0)
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        var info = alpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.none.rawValue
        if float { info |= CGBitmapInfo.floatComponents.rawValue | (bpc == 16 ? CGBitmapInfo.byteOrder16Big.rawValue : CGBitmapInfo.byteOrder32Big.rawValue) }
        else if bpc == 16 { info |= CGBitmapInfo.byteOrder16Big.rawValue }
        guard let provider = CGDataProvider(data: Data(samples) as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: bpc, bitsPerPixel: bpc * comps, bytesPerRow: width * comps * bpc / 8,
                                space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, properties as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return [UInt8](out as Data)
    }

    /// A PNG chunk.
    static func chunk(_ kind: String, _ data: [UInt8]) -> [UInt8] {
        let n = UInt32(data.count)
        let body = Array(kind.utf8) + data
        let crc = CRC32.checksum(body)
        return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + body
            + [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
    }

    /// `png` with `chunks` inserted right after IHDR.
    static func inserting(_ png: [UInt8], _ chunks: [[UInt8]]) -> [UInt8] {
        let ihdrEnd = 8 + 8 + 13 + 4
        return Array(png[..<ihdrEnd]) + chunks.flatMap { $0 } + Array(png[ihdrEnd...])
    }
}

@Suite struct ImageIOCodecTests {
    @Test func eightBitStraightAlphaIsExact() throws {
        // Colour under low alpha is lost by premultiplied drawing: decode keeps it.
        let px: [UInt8] = [200, 100, 50, 10, 1, 2, 3, 0, 255, 255, 255, 255, 7, 8, 9, 128]
        let png = try #require(CodecKit.encode(px, width: 2, height: 2, bpc: 8, gray: false, alpha: true))
        let img = try ImageIOCodec().decode(png)
        #expect(img.hasAlpha && img.surface.format == PixelFormat(mode: .rgb, sample: .u8, alpha: true))
        let v = img.surface.readRegion(PixelRect(x0: 0, y0: 0, x1: 2, y1: 2))
        // Fully transparent pixels may have their colour dropped by the encoder.
        for i in [0, 2, 3] {
            for c in 0 ..< 4 { #expect(UInt8((v[i * 4 + c] * 255).rounded()) == px[i * 4 + c], "pixel \(i) channel \(c)") }
        }
        #expect(v[1 * 4 + 3] == 0)
    }

    @Test(arguments: [8, 16]) func grayAlphaDecodes(_ bpc: Int) throws {
        let vals: [UInt16] = [0, 65535, 30000, 1000, 65535, 0, 12345, 54321]
        let bytes: [UInt8] = bpc == 8 ? vals.map { UInt8($0 >> 8) } : vals.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        let png = try #require(CodecKit.encode(bytes, width: 2, height: 2, bpc: bpc, gray: true, alpha: true))
        let img = try ImageIOCodec().decode(png)
        #expect(img.hasAlpha)
        #expect(img.surface.format == PixelFormat(mode: .grayscale, sample: bpc == 8 ? .u8 : .u16, alpha: true))
        let v = img.surface.readRegion(PixelRect(x0: 0, y0: 0, x1: 2, y1: 2))
        let scale: Float = bpc == 8 ? 255 : 65535
        for i in [0, 1, 3] {
            let want = bpc == 8 ? [Float(vals[i * 2] >> 8), Float(vals[i * 2 + 1] >> 8)] : [Float(vals[i * 2]), Float(vals[i * 2 + 1])]
            #expect((v[i * 2] * scale).rounded() == want[0] && (v[i * 2 + 1] * scale).rounded() == want[1], "pixel \(i)")
        }
    }

    @Test func sixteenBitGrayDecodes() throws {
        let vals: [UInt16] = [0, 1, 32768, 65535]
        let png = try #require(CodecKit.encode(vals.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }, width: 2, height: 2, bpc: 16, gray: true, alpha: false))
        let img = try ImageIOCodec().decode(png)
        #expect(!img.hasAlpha && img.surface.format.sample == .u16 && img.surface.format.mode == .grayscale)
        let v = img.surface.readRegion(PixelRect(x0: 0, y0: 0, x1: 2, y1: 2))
        #expect((0 ..< 4).map { UInt16((v[$0 * 2] * 65535).rounded()) } == vals)
        #expect((0 ..< 4).allSatisfy { v[$0 * 2 + 1] == 1 })
    }

    @Test func sixteenBitRGBAIsExact() throws {
        let vals: [UInt16] = [65535, 1, 2, 3, 100, 200, 300, 65535]
        let png = try #require(CodecKit.encode(vals.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }, width: 2, height: 1, bpc: 16, gray: false, alpha: true))
        let img = try ImageIOCodec().decode(png)
        let v = img.surface.readRegion(PixelRect(x0: 0, y0: 0, x1: 2, y1: 1))
        #expect(v.map { UInt16(($0 * 65535).rounded()) } == vals)
    }

    @Test func floatTIFFKeepsValuesAboveOne() throws {
        let f: [Float] = [2.5, 0.25, -0.5, 1, 0.1, 0.2, 0.3, 0.5]
        let bytes = f.flatMap { v -> [UInt8] in let b = v.bitPattern; return [UInt8(b >> 24), UInt8(b >> 16 & 0xFF), UInt8(b >> 8 & 0xFF), UInt8(b & 0xFF)] }
        let tif = try #require(CodecKit.encode(bytes, width: 2, height: 1, bpc: 32, gray: false, alpha: true, float: true, type: .tiff))
        let img = try ImageIOCodec().decode(tif)
        #expect(img.surface.format.sample == .f32)
        let v = img.surface.readRegion(PixelRect(x0: 0, y0: 0, x1: 2, y1: 1))
        #expect(abs(v[0] - 2.5) < 1e-6 && abs(v[4] - 0.1) < 1e-6 && v[7] == 0.5)
    }

    @Test func jpegExifXmpAndOrientation() throws {
        let px = [UInt8](repeating: 128, count: 4 * 2 * 3)
        let props: [CFString: Any] = [kCGImagePropertyOrientation: 6,
                                      kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "hello"]]
        let jpg = try #require(CodecKit.encode(px, width: 4, height: 2, bpc: 8, gray: false, alpha: false, type: .jpeg, properties: props))
        let img = try ImageIOCodec().decode(jpg)
        #expect(img.orientation == 6)
        #expect(img.width == 4 && img.height == 2, "pixels stay as stored")
        let exif = try #require(img.exif)
        #expect(exif.starts(with: [0x4D, 0x4D, 0, 42]) || exif.starts(with: [0x49, 0x49, 42, 0]))
    }

    @Test func pngTextExifAndXmpChunks() throws {
        let png = try #require(CodecKit.encode([1, 2, 3], width: 1, height: 1, bpc: 8, gray: false, alpha: false))
        let xmp = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>"
        let itxt = Array("XML:com.adobe.xmp".utf8) + [0, 0, 0, 0, 0] + Array(xmp.utf8)
        let ztxt = Array("Comment".utf8) + [0, 0] + (try Deflate.zlibDeflate(Array("zipped ".utf8) + [0xE9])) // Latin-1
        let text = Array("Author".utf8) + [0] + [0x4A, 0xF6, 0x72, 0x67] // "Jörg" in Latin-1
        var bad = CodecKit.chunk("tEXt", Array("Bad".utf8) + [0, 0x41])
        bad[bad.count - 1] ^= 1 // CRC mismatch: skipped
        let exif: [UInt8] = [0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0, 0]
        let file = CodecKit.inserting(png, [CodecKit.chunk("iTXt", itxt), CodecKit.chunk("zTXt", ztxt), CodecKit.chunk("tEXt", text), bad,
                                            CodecKit.chunk("eXIf", exif)])
        let img = try ImageIOCodec().decode(file)
        #expect(img.xmp == xmp)
        #expect(img.exif == exif)
        // tEXt first, then zTXt (photocraft's grouping).
        #expect(img.text == [MetadataText("Author", "Jörg"), MetadataText("Comment", "zipped é")])
    }

    @Test func tiffTextTagsUsePhotocraftKeys() throws {
        let props: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: "A picture",
                                                                        kCGImagePropertyTIFFArtist: "Someone"]]
        let tif = try #require(CodecKit.encode([1, 2, 3], width: 1, height: 1, bpc: 8, gray: false, alpha: false, type: .tiff, properties: props))
        let m = FlatMetadata.read(tif)
        #expect(m.text.contains(MetadataText("Description", "A picture")))
        #expect(m.text.contains(MetadataText("Artist", "Someone")))
    }

    @Test func truncatedAndGarbageInputsNeverTrap() {
        let png = CodecKit.encode([1, 2, 3], width: 1, height: 1, bpc: 8, gray: false, alpha: false) ?? []
        for n in stride(from: 0, to: png.count, by: 3) { _ = FlatMetadata.read(Array(png.prefix(n))) }
        for seed in 0 ..< 200 {
            var g = SystemRandomNumberGenerator()
            _ = seed
            let head: [[UInt8]] = [[0xFF, 0xD8], [0x49, 0x49, 42, 0], [0x4D, 0x4D, 0, 43], Array("RIFF\0\0\0\0WEBP".utf8)]
            let b = head[seed % head.count] + (0 ..< 64).map { _ in UInt8.random(in: 0 ... 255, using: &g) }
            _ = FlatMetadata.read(b)
        }
    }
}
