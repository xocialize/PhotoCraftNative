// The encoder settings read back from a lossy file (photocraft-codecs `source_settings.rs` tests
// and photocraft-io `file_encoding`). MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.

import Foundation
import ImageIO
import PCDocument
import Testing
import UniformTypeIdentifiers
@testable import PCIOCore

@Suite struct SourceEncodingTests {
    @Test func scalingMatchesThePublishedCurve() {
        // Quality 50 is the Annex K table itself; 100 is all ones; 75 halves it.
        #expect(SourceEncoding.scaled(16, 50, wide: false) == 16)
        #expect(SourceEncoding.scaled(121, 100, wide: false) == 1)
        #expect(SourceEncoding.scaled(16, 75, wide: false) == 8)
        #expect(SourceEncoding.scaled(121, 1, wide: false) == 255)
        #expect(SourceEncoding.scaled(121, 1, wide: true) == 6050)
        #expect(Set(SourceEncoding.zigzag).count == 64)
    }

    /// A JPEG header whose DQT holds the Annex K tables scaled to IJG quality `q` (8-bit, zig-zag).
    static func jpegHeader(_ q: UInt8, wide: Bool = false) -> [UInt8] {
        var out: [UInt8] = [0xFF, 0xD8]
        for (slot, base) in [SourceEncoding.annexKLuma, SourceEncoding.annexKChroma].enumerated() {
            var table: [UInt8] = [UInt8((wide ? 0x10 : 0) | slot)]
            for natural in SourceEncoding.zigzag {
                let v = SourceEncoding.scaled(base[natural], q, wide: wide)
                table += wide ? [UInt8(v >> 8), UInt8(v & 0xFF)] : [UInt8(v)]
            }
            out += [0xFF, 0xDB, UInt8((table.count + 2) >> 8), UInt8((table.count + 2) & 0xFF)] + table
        }
        return out + [0xFF, 0xDA, 0, 2, 0xFF, 0xD9]
    }

    @Test(arguments: [1, 10, 49, 50, 75, 85, 92, 100] as [UInt8]) func ijgTablesGiveTheirQuality(_ q: UInt8) {
        #expect(SourceEncoding.jpegQuality(Self.jpegHeader(q)) == q)
        #expect(SourceEncoding.jpegQuality(Self.jpegHeader(q, wide: true)) == q)
        #expect(SourceEncoding.fileEncoding(Self.jpegHeader(q)) == FileEncoding(jpegQuality: q))
    }

    @Test func hostileJPEGsGiveNothing() {
        #expect(SourceEncoding.jpegQuality([]) == nil)
        #expect(SourceEncoding.jpegQuality([0xFF, 0xD8, 0xFF, 0xDB, 0xFF, 0xFF]) == nil)
        #expect(SourceEncoding.jpegQuality(Array(Self.jpegHeader(80).prefix(40))) == nil)
        #expect(SourceEncoding.jpegQuality([0xFF, 0xD8, 0xFF, 0xDB, 0, 3, 0x20]) == nil, "precision 2 is not a table")
    }

    @Test func anImageIOJPEGHasAQuality() throws {
        let px = [UInt8](repeating: 0x80, count: 16 * 16 * 3)
        let jpg = try #require(CodecKit.encode(px, width: 16, height: 16, bpc: 8, gray: false, alpha: false, type: .jpeg,
                                               properties: [kCGImageDestinationLossyCompressionQuality: 0.9]))
        let q = try #require(SourceEncoding.fileEncoding(jpg).jpegQuality)
        #expect((1 ... 100).contains(q))
        #expect(SourceEncoding.fileEncoding(CodecKit.encode(px, width: 16, height: 16, bpc: 8, gray: false, alpha: false) ?? []).isEmpty, "PNG")
    }

    static func riff(_ chunks: [(String, [UInt8])]) -> [UInt8] {
        func le(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        var body = Array("WEBP".utf8)
        for (k, d) in chunks { body += Array(k.utf8) + le(d.count) + d + (d.count % 2 == 1 ? [0] : []) }
        return Array("RIFF".utf8) + le(body.count) + body
    }

    @Test func webpEncodingFromItsImageChunk() {
        #expect(SourceEncoding.fileEncoding(Self.riff([("VP8L", [0x2F, 1, 2])])) == FileEncoding(webpLossless: true))
        #expect(SourceEncoding.fileEncoding(Self.riff([("VP8X", [UInt8](repeating: 0, count: 10)), ("VP8 ", [1, 2, 3])]))
            == FileEncoding(webpLossless: false, webpQuality: 75))
        // Animated: inside the first frame (a 16-byte frame header, then its chunks).
        let frame = [UInt8](repeating: 0, count: 16) + Array("VP8L".utf8) + [1, 0, 0, 0, 0x2F, 0]
        #expect(SourceEncoding.webpIsLossless(Self.riff([("ANIM", [0, 0, 0, 0, 0, 0]), ("ANMF", frame)])) == true)
        #expect(SourceEncoding.webpIsLossless(Self.riff([("ALPH", [1])])) == nil)
        #expect(SourceEncoding.webpIsLossless(Array("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8L".utf8) + [0x40, 0, 0, 0, 0x2F]) == true, "a truncated chunk still holds its header")
        #expect(SourceEncoding.webpIsLossless(Array("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8L".utf8)) == nil, "no chunk header")
        #expect(SourceEncoding.webpIsLossless(Array("RIFF".utf8)) == nil)
    }
}
