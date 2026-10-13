// Port of photocraft-affinity (crates/affinity/src/container.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// The codecs photocraft takes from crates and this port implements: CRC-32, Adler-32, XXH64, zlib
// (Compression) and the Zstandard decoder. The zstd fixtures are frames written by the reference
// `zstd` 1.5.7 CLI over synthetic content (levels --fast=5 to --ultra -22, long mode, stdin streams
// without a content size, checksums on and off, several frames per entry); Fixtures/zstd/manifest.json
// holds each decoded size and CRC-32.

import Foundation
import Testing
@testable import PCAffinity
import PCAffinitySynth

@Suite struct ChecksumTests {
    @Test func knownVectors() {
        #expect(Checksum.crc32(ascii("123456789")) == 0xCBF4_3926)
        #expect(Checksum.crc32([]) == 0)
        #expect(Checksum.adler32(ascii("Wikipedia")) == 0x11E6_0398)
        #expect(Checksum.adler32([]) == 1)
        #expect(Checksum.xxh64([][...]) == 0xEF46_DB37_51D8_E999)
    }

    @Test func crc32SlicesAgreeWithTheBytewiseDefinition() {
        var rng = SeededRNG(seed: 4)
        for n in [1, 7, 8, 9, 63, 64, 65, 1000] {
            let b = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            var c: UInt32 = 0xFFFF_FFFF
            for x in b {
                c ^= UInt32(x)
                for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            }
            #expect(Checksum.crc32(b) == ~c, "\(n)")
        }
    }
}

@Suite struct ZlibTests {
    /// `zlib.compress(b"Affinity " * 40, 9)` from CPython (a fixed-Huffman block).
    static let reference: [UInt8] = [
        0x78, 0xDA, 0x73, 0x4C, 0x4B, 0xCB, 0xCC, 0xCB, 0x2C, 0xA9, 0x54, 0x70, 0x1C, 0x65, 0xD0, 0x92,
        0x01, 0x00, 0x94, 0x8A, 0x86, 0x11,
    ]

    @Test func decodesAnIndependentEncoder() throws {
        let out = try Zlib.inflate(Self.reference[...], size: 360)
        #expect(out == Array(String(repeating: "Affinity ", count: 40).utf8))
        // Dynamic-Huffman streams from CPython at levels 9 and 1 (Fixtures/zlib).
        let numbers = Array((0..<3000).map { String($0 * 7919 % 1000) }.joined(separator: " ").utf8)
        let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/zlib")
        for name in ["numbers.zlib", "numbers-fast.zlib"] {
            let stream = [UInt8](try Data(contentsOf: directory.appendingPathComponent(name)))
            #expect(stream[2] >> 1 & 3 == 2, "dynamic Huffman")
            #expect(try Zlib.inflate(stream[...], size: numbers.count) == numbers, "\(name)")
        }
    }

    @Test func roundTripsThroughTheSyntheticWriter() throws {
        var rng = SeededRNG(seed: 5)
        for n in [0, 1, 100, 70_000, 300_000] {
            let data = (0..<n).map { i in i % 3 == 0 ? UInt8.random(in: 0...255, using: &rng) : UInt8(i % 251) }
            #expect(try Zlib.inflate(Synth.zlib(data)[...], size: n) == data, "\(n)")
        }
    }

    @Test func rejectsBadWrappersAndTrailers() throws {
        let good = Synth.zlib(Array("hello zlib".utf8))
        var badCheck = good
        badCheck[1] ^= 1
        var dictionary = good
        dictionary[1] |= 0x20
        var badAdler = good
        badAdler[badAdler.count - 1] ^= 1
        for bad in [badCheck, dictionary, badAdler, [0x78], []] {
            #expect(failure { try Zlib.inflate(bad[...], size: 10) } == .malformed("corrupt compressed entry"))
        }
        // A truncated stream yields what it can; the archive's exact-size check reports it.
        let short = try? Zlib.inflate(good.dropLast(8)[...], size: 10)
        #expect(short.map { $0.count < 10 } ?? true)
        // Decoding stops one byte past the declared size.
        #expect(try Zlib.inflate(good[...], size: 4).count == 5)
    }
}

@Suite struct ZstdTests {
    struct Fixture: Decodable {
        var file: String
        var size: Int
        var crc32: UInt32
    }

    static let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/zstd")

    static func load(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: directory.appendingPathComponent(name)))
    }

    static func fixtures() throws -> [Fixture] {
        try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }

    static func decode(_ b: [UInt8], size: Int) throws(AffinityError) -> [UInt8] {
        try Zstd.decompress(b[...], size: size, maxWindow: Affinity.maxZstdWindow)
    }

    @Test func referenceFramesDecodeExactly() throws {
        let all = try Self.fixtures()
        #expect(all.count >= 28)
        for f in all {
            let out = try Self.decode(try Self.load(f.file), size: f.size)
            #expect(out.count == f.size, "\(f.file)")
            #expect(Checksum.crc32(out) == f.crc32, "\(f.file)")
        }
        for name in ["small", "tile"] {
            let source = try Self.load(name)
            for level in ["fast5", "l1", "l3", "l19"] {
                #expect(try Self.decode(try Self.load("\(name).\(level).zst"), size: source.count) == source)
            }
        }
    }

    @Test func publicDecoderMatchesReferenceFramesAndMapsFailures() throws {
        for f in try Self.fixtures() {
            let out = try ZstdDecoder.decompress(try Self.load(f.file), expectedSize: f.size)
            #expect(Checksum.crc32(out) == f.crc32, "\(f.file)")
        }
        #expect(throws: ZstdDecoder.Failure.sizeMismatch) { try ZstdDecoder.decompress(Self.rleLiterals, expectedSize: 19) }
        #expect(try ZstdDecoder.decompress(Self.rleLiterals, maxSize: 1 << 20) == [UInt8](repeating: 0x71, count: 20))
        #expect(throws: ZstdDecoder.Failure.sizeMismatch) { try ZstdDecoder.decompress(Self.rleLiterals, maxSize: 19) }
        for f in try Self.fixtures() {
            #expect(Checksum.crc32(try ZstdDecoder.decompress(try Self.load(f.file), maxSize: f.size + 4096)) == f.crc32, "\(f.file)")
        }
        #expect(throws: ZstdDecoder.Failure.corrupt) { try ZstdDecoder.decompress([0x28, 0xB5, 0x2F, 0xFD, 0xFF], expectedSize: 20) }
    }

    @Test func syntheticRawAndRLEFramesRoundTrip() throws {
        var rng = SeededRNG(seed: 6)
        for n in [1, 63, 64, 200, (128 << 10) + 7, 600_000] {
            let data = (0..<n).map { i in (i / 1000) % 2 == 0 ? UInt8(9) : UInt8.random(in: 0...255, using: &rng) }
            #expect(try Self.decode(Synth.zstd(data), size: n) == data, "\(n)")
        }
    }

    /// One compressed block whose literals section is RLE (20 × "q") with no sequences: the
    /// reference decoder reads it as 20 bytes.
    static let rleLiterals: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x14, 0x1D, 0x00, 0x00, 0xA1, 0x71, 0x00]

    @Test func rleLiteralsWithoutSequences() throws {
        #expect(try Self.decode(Self.rleLiterals, size: 20) == [UInt8](repeating: 0x71, count: 20))
    }

    @Test func framingErrorsAreRejected() throws {
        let corrupt = AffinityError.malformed("corrupt compressed entry")
        let good = Self.rleLiterals
        // Skippable frame, dictionary id, reserved bit, unknown block type.
        let skippable: [UInt8] = [0x50, 0x2A, 0x4D, 0x18, 0, 0, 0, 0]
        var dictionary = good
        dictionary[4] = 0x21
        dictionary.insert(7, at: 5)
        var reserved = good
        reserved[4] |= 0x08
        var blockType = good
        blockType[6] = 0x1F
        // A window over 64 MiB (exponent 31) and a single-segment frame declaring more.
        let hugeWindow: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x00, 0xF8, 0x01, 0x00, 0x00]
        let bigSegment: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0xA0] + le(UInt32(65 << 20)) + [0x01, 0x00, 0x00]
        // Declared content size and content checksum must match.
        var wrongSize = good
        wrongSize[5] = 19
        var checksummed = Synth.zstd(ascii("abc"))
        checksummed[4] |= 0x04
        checksummed += le(UInt32(0xDEAD_BEEF))
        // Trailing bytes are another (bad) frame; an empty frame is an error.
        let trailing = good + [1, 2, 3]
        let empty = Synth.zstd([])
        for (name, bad, size) in [
            ("skippable", skippable, 20), ("dictionary", dictionary, 20), ("reserved", reserved, 20), ("block type", blockType, 20),
            ("window", hugeWindow, 20), ("segment", bigSegment, 20), ("content size", wrongSize, 20),
            ("checksum", checksummed, 3), ("trailing", trailing, 20), ("empty", empty, 0),
        ] {
            #expect(failure { try Self.decode(bad, size: size) } == corrupt, "\(name)")
        }
        // Output past the declared size is a size mismatch, not a truncation.
        #expect(failure { try Self.decode(good, size: 19) } == .malformed("archive entry size mismatch"))
        // (An empty entry decodes to nothing; the archive's size check rejects it.)
        for end in 1..<good.count {
            #expect(failure { try Self.decode(Array(good[..<end]), size: 20) } != nil, "\(end)")
        }
    }

    @Test func checksummedFramesVerifyTheirContent() throws {
        // A reference frame with a checksum decodes; flipping a checksum byte fails it.
        let frame = try Self.load("small.l3.zst")
        let size = try Self.load("small").count
        #expect(frame[4] & 0x04 != 0)
        var damaged = frame
        damaged[damaged.count - 1] ^= 0x10
        #expect(failure { try Self.decode(damaged, size: size) } == .malformed("corrupt compressed entry"))
    }

    @Test func everyTruncationOfAReferenceFrameFails() throws {
        let frame = try Self.load("text.l19.zst")
        let size = try Self.fixtures().first { $0.file == "text.l19.zst" }!.size
        for end in stride(from: 1, to: frame.count, by: 97) {
            #expect(failure { try Self.decode(Array(frame[..<end]), size: size) } != nil, "\(end)")
        }
    }

    /// Hostile frames: random edits to every reference frame must fail cleanly or decode, never trap.
    @Test func mutatedFramesNeverTrap() throws {
        var rng = SeededRNG(seed: 7)
        let frames = try Self.fixtures().filter { $0.size <= 80_000 }.map { (try Self.load($0.file), $0.size) }
        #expect(frames.count >= 10)
        for _ in 0..<60 {
            for (frame, size) in frames {
                var m = frame
                for _ in 0..<Int.random(in: 1...8, using: &rng) {
                    let at = Int.random(in: 0..<m.count, using: &rng)
                    switch Int.random(in: 0..<3, using: &rng) {
                    case 0: m[at] = UInt8.random(in: 0...255, using: &rng)
                    case 1: m[at] ^= 1 << UInt8.random(in: 0..<8, using: &rng)
                    default: m[at] = m[at] &+ 1
                    }
                }
                if Bool.random(using: &rng) { m = Array(m.prefix(Int.random(in: 0...m.count, using: &rng))) }
                _ = failure { try Self.decode(m, size: Bool.random(using: &rng) ? size : Int.random(in: 0...(size * 2), using: &rng)) }
            }
        }
    }
}
