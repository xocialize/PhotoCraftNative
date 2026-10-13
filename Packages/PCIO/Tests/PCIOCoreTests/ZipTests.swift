// Tests ported from photocraft-format (crates/format/src/zip.rs), MIT OR Apache-2.0, © ArtCraft
// Team and the PhotoCraft contributors; plus deflate/zlib/gzip round trips.

import Foundation
import Testing
@testable import PCIOCore

@Suite struct ZipTests {
    @Test func crcKnownValue() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func roundtrip() throws {
        var w = ZipWriter()
        try w.add("a.txt", Array("hello".utf8))
        try w.add("dir/b.bin", [0, 1, 2, 3])
        try w.add("empty", [])
        let bytes = try w.finish()
        let r = try ZipReader(bytes)
        #expect(r.entries.count == 3)
        #expect(try r.read(named: "a.txt", max: 100) == Array("hello".utf8))
        #expect(try r.read(named: "dir/b.bin", max: 100) == [0, 1, 2, 3])
        #expect(try r.read(named: "empty", max: 0).isEmpty)
        #expect(throws: PCIOError.limitExceeded("zip entry `a.txt` is 5 bytes (max 3)")) { try r.read(named: "a.txt", max: 3) }
    }

    @Test func crcMatchesBitwiseReference() {
        func reference(_ data: ArraySlice<UInt8>) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for b in data {
                c ^= UInt32(b)
                for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            }
            return ~c
        }
        let data: [UInt8] = (0 ..< 1000).map { UInt8(truncatingIfNeeded: (UInt32($0) &* 2_654_435_761) >> 13) }
        for len in [0, 1, 7, 15, 16, 17, 63, 64, 65, 255, 256, 1000] {
            #expect(CRC32.checksum(Array(data[..<len])) == reference(data[..<len]))
        }
    }

    @Test func findLocatesEveryEntryInALargeArchive() throws {
        var w = ZipWriter()
        let n: UInt32 = 3000
        for i in 0 ..< n { try w.add(String(format: "tiles/%05d.zst", i), withUnsafeBytes(of: i.littleEndian) { Array($0) }) }
        let r = try ZipReader(try w.finish())
        #expect(r.entries.count == Int(n))
        for i in (0 ..< n).reversed() {
            let name = String(format: "tiles/%05d.zst", i)
            let e = try #require(r.find(name))
            #expect(e.name == name)
            #expect(try r.read(e, max: 4) == withUnsafeBytes(of: i.littleEndian) { Array($0) })
        }
        #expect(r.find("tiles/missing.zst") == nil)
        #expect(r.find("") == nil)
    }

    @Test func duplicateNamesResolveToTheFirstEntry() throws {
        var w = ZipWriter()
        try w.add("a", Array("first".utf8))
        try w.add("b", Array("other".utf8))
        try w.add("a", Array("second".utf8))
        let r = try ZipReader(try w.finish())
        #expect(r.entries.count == 3)
        #expect(try r.read(named: "a", max: 100) == Array("first".utf8))
        #expect(try r.read(named: "b", max: 100) == Array("other".utf8))
    }

    @Test func crcMismatchDetected() throws {
        var w = ZipWriter()
        try w.add("a", Array("hello".utf8))
        var bytes = try w.finish()
        let pos = try #require((0 ..< bytes.count - 5).first { Array(bytes[$0 ..< $0 + 5]) == Array("hello".utf8) })
        bytes[pos] = UInt8(ascii: "j")
        let r = try ZipReader(bytes)
        #expect(throws: PCIOError.self) { try r.read(named: "a", max: 100) }
    }

    @Test func deflatedEntryWithUnboundedLimitRoundTrips() throws {
        let content = Array("DEFLATE-compressed PhotoCraft project content, with a valid CRC.".utf8)
        let compressed = try Deflate.deflate(content)
        var writer = ZipWriter()
        try writer.add("manifest.json", compressed)
        var bytes = try writer.finish()
        let eocd = bytes.count - 22
        let central = try ZipReader.u32(bytes, eocd + 16)
        let crc = CRC32.checksum(content)
        func put16(_ at: Int, _ v: UInt16) { bytes[at] = UInt8(v & 0xFF); bytes[at + 1] = UInt8(v >> 8) }
        func put32(_ at: Int, _ v: UInt32) { for k in 0 ..< 4 { bytes[at + k] = UInt8(v >> (8 * UInt32(k)) & 0xFF) } }
        put16(8, 8); put32(14, crc); put32(22, UInt32(content.count))
        put16(central + 10, 8); put32(central + 16, crc); put32(central + 24, UInt32(content.count))
        let archive = try ZipReader(bytes)
        #expect(try archive.read(named: "manifest.json", max: .max) == content)
        #expect(try archive.read(named: "manifest.json", max: content.count) == content)
        #expect(throws: PCIOError.self) { try archive.read(named: "manifest.json", max: content.count - 1) }
        // A forged 4 GiB size is rejected without allocating it.
        put32(22, UInt32.max); put32(central + 24, UInt32.max)
        let forged = try ZipReader(bytes)
        #expect(throws: PCIOError.self) { try forged.read(named: "manifest.json", max: .max) }
    }

    @Test func anEntryFromAnotherArchiveIsAnErrorNotACrash() throws {
        var big = ZipWriter()
        try big.add("a", [UInt8](repeating: 7, count: 4096))
        let foreign = try ZipReader(try big.finish()).entries[0]
        var small = ZipWriter()
        try small.add("a", Array("x".utf8))
        let r = try ZipReader(try small.finish())
        #expect(throws: PCIOError.self) { try r.read(foreign, max: .max) }
    }

    @Test func offsetAccessRejectsOverflow() {
        #expect(throws: PCIOError.self) { try ZipReader.u16([], Int.max) }
        #expect(throws: PCIOError.self) { try ZipReader.u32([], Int.max - 3) }
    }

    @Test func deflateZlibGzipRoundTrip() throws {
        let data: [UInt8] = (0 ..< 200_000).map { UInt8(truncatingIfNeeded: $0 * 7 / 13) }
        #expect(try Deflate.inflate(try Deflate.deflate(data)) == data)
        #expect(try Deflate.zlibInflate(try Deflate.zlibDeflate(data)) == data)
        #expect(try Deflate.gunzip(try Deflate.gzip(data)) == data)
        #expect(try Deflate.inflate(try Deflate.deflate([])) == [])
        #expect(throws: PCIOError.self) { try Deflate.inflate(try Deflate.deflate(data), limit: 1000) }
        var bad = try Deflate.zlibDeflate(data)
        bad[bad.count - 1] ^= 1
        #expect(throws: PCIOError.self) { try Deflate.zlibInflate(bad) }
        let truncated = Array(try Deflate.deflate(data).prefix(100))
        #expect(throws: PCIOError.self) { try Deflate.inflate(truncated) }
    }

    @Test func storedAndDeflatedEntriesMix() throws {
        var w = ZipWriter()
        try w.add("mimetype", Array("image/openraster".utf8))
        try w.add("stack.xml", [UInt8](repeating: 65, count: 10_000), compress: true)
        let bytes = try w.finish()
        #expect(ZipReader.mimetype(bytes) == Array("image/openraster".utf8))
        let r = try ZipReader(bytes)
        #expect(r.find("stack.xml")?.method == 8)
        #expect(try r.read(named: "stack.xml", max: 10_000) == [UInt8](repeating: 65, count: 10_000))
    }
}
