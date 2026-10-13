// Codec unit tests: PackBits, plane codecs, prediction, zlib, byte IO, header.
// Port of the inline tests of photocraft-psd (crates/psd/src/compression.rs, io.rs, header.rs) and
// the codec proptests (tests/proptests.rs, as seeded loops), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCPSD

@Suite struct CodecTests {
    func pb(_ src: [UInt8]) throws -> [UInt8] {
        let enc = PackBits.encode(src)
        #expect(try PackBits.decode(enc, expected: src.count) == src, "encoded \(enc)")
        return enc
    }

    @Test func packbitsVectors() throws {
        #expect(try pb([]).isEmpty)
        #expect(try pb([7]) == [0, 7])
        #expect(try pb([5, 5]) == [0xFF, 5])
        #expect(try pb([UInt8](repeating: 9, count: 128)) == [0x81, 9])
        #expect(try pb([UInt8](repeating: 9, count: 129)) == [0x81, 9, 0, 9])
        _ = try pb([UInt8](repeating: 1, count: 130))
        #expect(try pb([UInt8](repeating: 1, count: 256)) == [0x81, 1, 0x81, 1])
        let lit128 = try pb((0 ..< 128).map { UInt8($0) })
        #expect(lit128[0] == 127 && lit128.count == 129)
        let lit129 = try pb((0 ..< 129).map { UInt8($0) })
        #expect(lit129[0] == 127 && lit129[129] == 0 && lit129.count == 131)
        _ = try pb([1, 2, 3, 3, 3, 3, 4, 5])
        _ = try pb([1, 1, 2, 2, 3, 3])
        _ = try pb([1, 2, 2, 3])
        _ = try pb([0, 0, 0, 1, 0, 0, 0])
        #expect(try pb([1, 2, 3, 3, 3]) == [1, 1, 2, 0xFE, 3])
    }

    @Test func packbitsNeverEmitsNoop() throws {
        for n in 0 ..< 300 {
            let enc = try pb((0 ..< n).map { UInt8(($0 / 3) % 5) })
            var i = 0
            while i < enc.count {
                let h = Int8(bitPattern: enc[i])
                #expect(h != -128)
                i += h >= 0 ? Int(h) + 2 : 2
            }
        }
    }

    @Test func packbitsDecodeEdgeCases() throws {
        #expect(try PackBits.decode([0x80, 0, 42], expected: 1) == [42])
        #expect(try PackBits.decode([0xFF, 1], expected: 0) == [])
        for bad: [UInt8] in [[], [2, 1, 2], [0xFE], [0xFD, 1], [3, 1, 2, 3, 4]] {
            #expect(throws: PSDError.self) { try PackBits.decode(bad, expected: bad == [] ? 1 : 3) }
        }
    }

    @Test func packbitsSeededRoundTrips() throws {
        var rng = SeededRandom(42)
        for _ in 0 ..< 200 {
            let data = rng.bytes(rng.int(0 ..< 600))
            let enc = try pb(data)
            #expect(enc.count <= data.count + (data.count + 127) / 128)
            var runs: [UInt8] = []
            for _ in 0 ..< rng.int(0 ..< 20) { runs += [UInt8](repeating: rng.byte(), count: rng.int(1 ..< 300)) }
            _ = try pb(runs)
            _ = try? PackBits.decode(rng.bytes(rng.int(0 ..< 64)), expected: rng.int(0 ..< 512))
        }
    }

    @Test func compressionCodes() {
        for v: UInt16 in 0 ..< 6 { #expect(PSDCompression(code: v).code == v) }
        #expect(PSDCompression(code: 9) == .unknown(9))
    }

    func sampleData(_ l: PlaneLayout) throws -> [UInt8] {
        (0 ..< (try l.decodedLength())).map { UInt8(($0 * 7 + $0 / 5) % 251) }
    }

    @Test func allCodecsRoundTripAllDepths() throws {
        for version in PSDVersion.allCases {
            for depth: UInt16 in [1, 8, 16, 32] {
                for (w, h) in [(0, 0), (1, 1), (3, 2), (17, 5), (0, 3), (4, 0)] {
                    for planes in [1, 3] {
                        let l = PlaneLayout(planes: planes, width: w, height: h, depth: depth, version: version)
                        let data = try sampleData(l)
                        for c in PSDCompression.all {
                            let enc = try PlaneCodec.encode(c, data, layout: l)
                            try enc.withUnsafeBytes { try PlaneCodec.validate(c, $0, layout: l) }
                            #expect(try PlaneCodec.decode(c, Data(enc), layout: l) == data, "\(c) \(depth) \(w)x\(h) \(version)")
                        }
                    }
                }
            }
        }
    }

    @Test func seededChannelCodecsRoundTrip() throws {
        var rng = SeededRandom(7)
        for _ in 0 ..< 300 {
            let l = PlaneLayout(planes: rng.int(1 ..< 4), width: rng.int(0 ..< 40), height: rng.int(0 ..< 12),
                                depth: [1, 8, 16, 32][rng.int(0 ..< 4)], version: rng.bool() ? .psb : .psd)
            let data = (0 ..< (try l.decodedLength())).map { _ in rng.next() >> 62 == 0 ? 0 : rng.byte() }
            let c = PSDCompression.all[rng.int(0 ..< 4)]
            let enc = try PlaneCodec.encode(c, data, layout: l)
            #expect(try PlaneCodec.decode(c, Data(enc), layout: l) == data, "\(c) \(l)")
            _ = try? PlaneCodec.decode(PSDCompression(code: UInt16(rng.int(0 ..< 5))), Data(rng.bytes(rng.int(0 ..< 128))),
                                       layout: PlaneLayout(planes: 1, width: rng.int(0 ..< 20), height: rng.int(0 ..< 8), depth: 8, version: .psd))
        }
    }

    @Test func rleCountWidthPSDvsPSB() throws {
        let data = [UInt8](repeating: 0, count: 4)
        let psd = try PlaneCodec.encode(.rle, data, layout: PlaneLayout(planes: 1, width: 2, height: 2, depth: 8, version: .psd))
        let psb = try PlaneCodec.encode(.rle, data, layout: PlaneLayout(planes: 1, width: 2, height: 2, depth: 8, version: .psb))
        #expect(psd == [0, 2, 0, 2, 0xFF, 0, 0xFF, 0])
        #expect(psb == [0, 0, 0, 2, 0, 0, 0, 2, 0xFF, 0, 0xFF, 0])
        #expect(throws: PSDError.self) { try PlaneCodec.decode(.rle, Data(psd), layout: PlaneLayout(planes: 1, width: 2, height: 2, depth: 8, version: .psb)) }
    }

    @Test func rleTruncatedFails() throws {
        let l = PlaneLayout(planes: 1, width: 10, height: 10, depth: 8, version: .psd)
        let enc = try PlaneCodec.encode(.rle, try sampleData(l), layout: l)
        for cut in 0 ..< enc.count {
            #expect(throws: PSDError.self) { try PlaneCodec.decode(.rle, Data(enc[0 ..< cut]), layout: l) }
            #expect(throws: PSDError.self) { try enc[0 ..< cut].withUnsafeBytes { try PlaneCodec.validate(.rle, $0, layout: l) } }
        }
    }

    /// Salvage mode: a damaged count table no longer stops the decode.
    @Test func rleLenientIgnoresWrongCounts() throws {
        let l = PlaneLayout(planes: 2, width: 9, height: 4, depth: 8, version: .psd)
        let data = try sampleData(l)
        var enc = try PlaneCodec.encode(.rle, data, layout: l)
        enc[1] = 0; enc[3] = 200
        #expect(throws: PSDError.self) { try PlaneCodec.decode(.rle, Data(enc), layout: l) }
        #expect(try PlaneCodec.decode(.rle, Data(enc), layout: l, lenient: true) == data)
    }

    @Test func zipTruncatedAndCorruptFail() throws {
        let l = PlaneLayout(planes: 1, width: 3, height: 1, depth: 8, version: .psd)
        for c in [PSDCompression.zip, .zipPrediction] {
            let data = try PlaneCodec.encode(c, [1, 2, 3], layout: l)
            for cut in 0 ..< data.count {
                #expect(throws: PSDError.self) { try PlaneCodec.decode(c, Data(data[0 ..< cut]), layout: l) }
            }
            var corrupt = data
            corrupt[corrupt.count - 1] ^= 1
            #expect(throws: PSDError.self) { try PlaneCodec.decode(c, Data(corrupt), layout: l) }
            #expect(try PlaneCodec.decode(c, Data(corrupt), layout: l, lenient: true) == [1, 2, 3], "lenient ignores the checksum")
        }
        let padded = Zlib.compress([1, 2, 3, 0])
        #expect(try PlaneCodec.decode(.zip, Data(padded), layout: l) == [1, 2, 3])
        let bomb = Zlib.compress([UInt8](repeating: 0, count: (1 << 20) + 4))
        #expect(throws: PSDError.self) { try PlaneCodec.decode(.zip, Data(bomb), layout: l) }
    }

    @Test func zipOverBudgetIsNotInflatedAtParse() throws {
        let l = PlaneLayout(planes: 4, width: 300_000, height: 300_000, depth: 8, version: .psb)
        #expect(try l.totalBytes() > PSDLimits.maxDecodedBytes)
        let garbage: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3]
        for c in [PSDCompression.zip, .zipPrediction] {
            try garbage.withUnsafeBytes { try PlaneCodec.validate(c, $0, layout: l) }
            #expect(throws: PSDError.self) { try PlaneCodec.decode(c, Data(garbage), layout: l) }
        }
        #expect(throws: PSDError.self) {
            try garbage.withUnsafeBytes { try PlaneCodec.validate(.zip, $0, layout: PlaneLayout(planes: 1, width: 4, height: 4, depth: 8, version: .psd)) }
        }
    }

    @Test func rawShortFailsAndUnknownErrors() throws {
        let l = PlaneLayout(planes: 2, width: 3, height: 3, depth: 8, version: .psd)
        #expect(throws: PSDError.self) { try PlaneCodec.decode(.raw, Data(count: 17), layout: l) }
        _ = try PlaneCodec.decode(.raw, Data(count: 18), layout: l)
        let one = PlaneLayout(planes: 1, width: 1, height: 1, depth: 8, version: .psd)
        #expect(throws: PSDError.self) { try PlaneCodec.decode(.unknown(7), Data([0]), layout: one) }
        #expect(throws: PSDError.self) { try PlaneCodec.encode(.unknown(7), [0], layout: one) }
        #expect(throws: PSDError.self) { try PlaneCodec.encode(.raw, [0, 0, 0], layout: PlaneLayout(planes: 1, width: 2, height: 2, depth: 8, version: .psd)) }
    }

    @Test func decodedLengthLimits() throws {
        #expect(throws: PSDError.self) { try PlaneLayout(planes: 56, width: 300_000, height: 300_000, depth: 32, version: .psb).decodedLength() }
        #expect(try PlaneLayout(planes: 3, width: 30000, height: 30000, depth: 8, version: .psb).decodedLength() == 2_700_000_000)
        #expect(try PlaneLayout(planes: 1, width: 33000, height: 33000, depth: 16, version: .psb).decodedLength() == 2_178_000_000)
        #expect(throws: PSDError.self) { try PlaneLayout(planes: 4, width: 40000, height: 40000, depth: 16, version: .psb).decodedLength() }
    }

    @Test func predictionKnownVectors() throws {
        var v: [UInt8] = [10, 12, 11, 255]
        let l8 = PlaneLayout(planes: 1, width: 4, height: 1, depth: 8, version: .psd)
        try PlaneCodec.predict(&v, layout: l8)
        #expect(v == [10, 2, 255, 244])
        try PlaneCodec.unpredict(&v, layout: l8)
        #expect(v == [10, 12, 11, 255])
        var w: [UInt8] = [0x01, 0x00, 0x01, 0x05, 0x00, 0x00]
        let l16 = PlaneLayout(planes: 1, width: 3, height: 1, depth: 16, version: .psd)
        try PlaneCodec.predict(&w, layout: l16)
        #expect(w == [0x01, 0x00, 0x00, 0x05, 0xFE, 0xFB])
        try PlaneCodec.unpredict(&w, layout: l16)
        #expect(w == [0x01, 0x00, 0x01, 0x05, 0x00, 0x00])
        let orig: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33, 0x44]
        var x = orig
        let l32 = PlaneLayout(planes: 1, width: 2, height: 1, depth: 32, version: .psd)
        try PlaneCodec.predict(&x, layout: l32)
        var expect: [UInt8] = [0xAA, 0x11, 0xBB, 0x22, 0xCC, 0x33, 0xDD, 0x44]
        for i in stride(from: 7, through: 1, by: -1) { expect[i] = expect[i] &- expect[i - 1] }
        #expect(x == expect)
        try PlaneCodec.unpredict(&x, layout: l32)
        #expect(x == orig)
    }

    @Test func prediction32BitFloatsRoundTrip() throws {
        let l = PlaneLayout(planes: 1, width: 5, height: 2, depth: 32, version: .psd)
        let v = PSDSamples.bytes(f32: (0 ..< 10).map { Float($0) * 0.37 - 1 })
        #expect(try PlaneCodec.decode(.zipPrediction, Data(try PlaneCodec.encode(.zipPrediction, v, layout: l)), layout: l) == v)
    }

    /// Photoshop reads ZIP (code 2) at 32 bits as predicted (PsdPlugin, PhotoDemon); plain-zlib
    /// floats from other writers are still recognised.
    @Test func zip32BitPhotoshopSemantics() throws {
        let l = PlaneLayout(planes: 1, width: 6, height: 3, depth: 32, version: .psd)
        let v = PSDSamples.bytes(f32: (0 ..< 18).map { Float($0) / 17 })
        let enc = try PlaneCodec.encode(.zip, v, layout: l)
        var predicted = v
        try PlaneCodec.predict(&predicted, layout: l)
        #expect(try enc.withUnsafeBytes { try Zlib.inflate($0, expected: v.count) } == predicted, "code 2 at 32 bits is written predicted")
        #expect(try PlaneCodec.decode(.zip, Data(enc), layout: l) == v)
        let plain = Zlib.compress(v)
        #expect(try PlaneCodec.decode(.zip, Data(plain), layout: l) == v, "plain floats fall back")
        let ch = try PSDChannel.encode(id: 0, compression: .zip, decoded: v, width: 6, height: 3, depth: 32, version: .psd)
        #expect(ch.compression == .zipPrediction)
    }

    @Test func zlibAdler32KnownValue() {
        #expect(Zlib.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(Zlib.adler32([]) == 1)
        let big = (0 ..< 100_000).map { UInt8($0 % 251) }
        #expect(Zlib.compress(big).withUnsafeBytes { raw in (try? Zlib.inflate(raw, expected: big.count)) } == big)
        #expect(Zlib.storedZlib(UnsafeRawBufferPointer(start: nil, count: 0)).withUnsafeBytes { raw in (try? Zlib.inflate(raw, expected: 0)) } == [])
    }

    func readError(_ bytes: [UInt8], _ body: (inout ByteReader) throws -> Void) -> PSDError? {
        do {
            try bytes.withByteReader { r in try body(&r) }
            return nil
        } catch {
            return error as? PSDError
        }
    }

    @Test func readerBasics() throws {
        try [UInt8]([0, 1, 0xFF, 0xFE, 0, 0, 0, 2]).withByteReader { r in
            let a = try r.u16(), b = try r.i16(), c = try r.u32()
            #expect(a == 1 && b == -2 && c == 2)
            #expect(r.isAtEnd)
        }
        #expect(readError([1]) { r in try r.skip(1); _ = try r.u8() } == .unexpectedEOF(offset: 1, needed: 1))
        #expect(readError([1, 2]) { r in _ = try r.u32() } == .unexpectedEOF(offset: 0, needed: 2))
        #expect(readError([UInt8](repeating: 0, count: 8)) { r in try r.checkCount(UInt64.max, minItemSize: 4) } != nil)
        #expect(readError([UInt8](repeating: 0, count: 8)) { r in try r.checkCount(2, minItemSize: 4) } == nil)
        #expect(readError([UInt8](repeating: 0, count: 8)) { r in try r.checkCount(3, minItemSize: 4) } != nil)
    }

    @Test func writerLengthPatchAndPascal() throws {
        var w = ByteWriter()
        let at = w.beginLength(long: false)
        w.put([1, 2, 3])
        try w.endLength(at, long: false)
        #expect(w.bytes == [0, 0, 0, 3, 1, 2, 3])
        var w8 = ByteWriter()
        let at8 = w8.beginLength(long: true)
        w8.u8(9)
        try w8.endLength(at8, long: true)
        #expect(w8.bytes == [0, 0, 0, 0, 0, 0, 0, 1, 9])
        for (name, align, total) in [([UInt8](), 2, 2), ([97], 2, 2), ([97, 98], 2, 4), ([], 4, 4), ([97, 98, 99], 4, 4), ([97, 98, 99, 100], 4, 8)] {
            var p = ByteWriter()
            p.pascal(name, align: align)
            #expect(p.count == total)
            try p.bytes.withByteReader { r in
                let got = try r.pascal(align: align)
                #expect(got == name)
                #expect(r.isAtEnd)
            }
        }
    }

    @Test func legacyNamesAndUnicode() throws {
        #expect(decodeLegacyName(Array("Layer 1".utf8)) == "Layer 1")
        #expect(decodeLegacyName([0x41, 0xE9]) == "A\u{E9}")
        #expect(encodeLegacyName("h\u{E9}llo") == Array("h?llo".utf8))
        #expect(utf16Units("a😀b", max: 2) == [97])
        #expect(utf16Units("a😀b", max: 3) == [97, 0xD83D, 0xDE00])
        var w = ByteWriter()
        w.unicodeUnits([0x48, 0x69, 0])
        let units = try w.bytes.withByteReader { try $0.unicodeUnits() }
        #expect(units == [0x48, 0x69, 0])
        #expect(readError([0xFF, 0xFF, 0xFF, 0xFF]) { r in _ = try r.unicodeUnits() } != nil)
    }

    @Test func headerRoundTripAndLimits() throws {
        let h = PSDHeader(version: .psb, width: 1000, height: 20, channels: 4, depth: 16, colorMode: .cmyk)
        var s = MemorySink()
        try h.write(to: &s)
        #expect(s.data.count == 26)
        #expect(try s.data.withByteReader { try PSDHeader.read(&$0) } == h)
        for bad in [PSDHeader(version: .psd, width: 300_001, height: 1, channels: 1, depth: 8, colorMode: .rgb),
                    PSDHeader(version: .psd, width: 0, height: 1, channels: 1, depth: 8, colorMode: .rgb),
                    PSDHeader(version: .psd, width: 1, height: 1, channels: 0, depth: 8, colorMode: .rgb),
                    PSDHeader(version: .psd, width: 1, height: 1, channels: 57, depth: 8, colorMode: .rgb),
                    PSDHeader(version: .psd, width: 1, height: 1, channels: 3, depth: 12, colorMode: .rgb)] {
            #expect(throws: PSDError.self) { try bad.validate() }
        }
        for v: UInt16 in 0 ..< 20 { #expect(PSDColorMode(code: v).code == v) }
        #expect(PSDColorMode(code: 5) == .unknown(5))
        #expect(PSDColorMode.rgb.colorChannels == 3)
        #expect(PSDHeader.rowBytes(width: 9, depth: 1) == 2 && PSDHeader.rowBytes(width: 8, depth: 1) == 1)
        #expect(PSDHeader.rowBytes(width: 0, depth: 1) == 0 && PSDHeader.rowBytes(width: 3, depth: 8) == 3)
        #expect(PSDHeader.rowBytes(width: 3, depth: 16) == 6 && PSDHeader.rowBytes(width: 3, depth: 32) == 12)
    }

    @Test func blendModeKeys() {
        var keys = Set<FourCC>()
        for m in PSDBlendMode.all {
            #expect(PSDBlendMode(key: m.key) == m)
            #expect(keys.insert(m.key).inserted)
        }
        #expect(keys.count == 28)
        #expect(PSDBlendMode(key: "zzzz") == .unknown("zzzz"))
        #expect(PSDBlendMode.multiply.key == "mul ")
        #expect(PSDBlendMode(key: "smud") == .exclusion && PSDBlendMode(key: "idiv") == .colorBurn)
        for m in PSDBlendMode.all { #expect(PSDBlendMode(descriptorValue: m.descriptorValue!) == m) }
    }

    @Test func sampleConversions() throws {
        #expect(PSDSamples.u16([0x12, 0x34, 0xFF, 0xFF]) == [0x1234, 0xFFFF])
        #expect(PSDSamples.bytes(u16: [0x1234]) == [0x12, 0x34])
        #expect(PSDSamples.f32(PSDSamples.bytes(f32: [0.5, -1])) == [0.5, -1])
        #expect(try PSDSamples.unpackBits([0b1010_0000, 0b1000_0000], width: 3, height: 2) == [1, 0, 1, 1, 0, 0])
        #expect(try PSDSamples.planeToU8([0xFF, 0xFF, 0, 0, 0x80, 0], depth: 16, width: 3, height: 1) == [255, 0, 128])
        #expect(try PSDSamples.planeToU8(PSDSamples.bytes(f32: [0, 1, 2, -1, .nan]), depth: 32, width: 5, height: 1) == [0, 255, 255, 0, 0])
        #expect(try PSDSamples.planeToU8([0b1000_0000], depth: 1, width: 2, height: 1) == [0, 255])
        #expect(throws: PSDError.self) { try PSDSamples.planeToU8([], depth: 12, width: 0, height: 0) }
        #expect(throws: PSDError.self) { try PSDSamples.unpackBits([0], width: Int.max / 2, height: 4) }
    }
}
