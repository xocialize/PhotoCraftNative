// The object codec: BLAKE3 names, XXH64 checksums, the zstd encoder and the bounded decoder,
// against reference vectors and (when installed) the zstd command-line tool.
// Tests of the port of photocraft-format (crates/format/src/store.rs codec), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCAffinity
@testable import PCFormat
import PCIOCore
import Testing

@Suite struct CodecTests {
    /// The text the reference frames were made from: an LCG over a 16-word vocabulary.
    static func words(_ n: Int) -> [UInt8] {
        let vocabulary = ["alpha", "beta", "gamma", "delta", "tile", "layer", "mask", "pixel", "blend", "group", "smart", "text", "zstd", "frame",
                          "huff", "fse"].map { Array($0.utf8) + [0x20] }
        var s: UInt32 = 12345
        var out: [UInt8] = []
        while out.count < n {
            s = (s &* 1_103_515_245 &+ 12345) & 0x7FFF_FFFF
            out += vocabulary[Int((s >> 16) & 15)]
        }
        return Array(out.prefix(n))
    }

    static func repeated(_ unit: [UInt8], _ n: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(n)
        while out.count < n { out += unit.prefix(n - out.count) }
        return out
    }

    /// Inputs covering the encoder's paths: empty and tiny inputs, RLE blocks, incompressible
    /// data (raw blocks), Huffman literals with direct and FSE-coded weights, long codes, matches
    /// across blocks, and RGBA pixel data.
    static func samples() -> [(String, [UInt8])] {
        var rng = Rng(42)
        let random = (0 ..< 200_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        var skewed: [UInt8] = []
        for _ in 0 ..< 100_000 {
            let r = rng.f()
            skewed.append(r < 0.5 ? 0 : r < 0.75 ? 1 : rng.f() < 0.01 ? UInt8(truncatingIfNeeded: rng.next()) : UInt8(2 + rng.next() % 6))
        }
        var geometric: [UInt8] = []
        for _ in 0 ..< 100_000 {
            var k: UInt8 = 0
            while rng.f() < 0.5 && k < 255 { k += 1 }
            geometric.append(k)
        }
        var tile: [UInt8] = []
        for _ in 0 ..< 256 {
            for x in 0 ..< 256 {
                if x < 128 {
                    let v = UInt8(clamping: Int(128 + 60 * sin(Double(x) / 20)) + Int(rng.next() % 9) - 4)
                    tile += [v, v / 4 * 3, v / 2, 255]
                } else {
                    tile += [30, 60, 90, 255]
                }
            }
        }
        return [
            ("empty", []), ("one", [42]), ("small", Array("hello hello hello world, hello world!\n".utf8)),
            ("uniform", [UInt8](repeating: 7, count: 300_000)), ("random", random), ("words", words(343_604)),
            ("skewed", skewed), ("geometric", geometric), ("tile", tile), ("lowAlphabet", (0 ..< 5000).map { UInt8($0 % 3) }),
            ("periodic", repeated(words(6000), 400_000)),
        ]
    }

    @Test func xxh64MatchesTheReference() {
        #expect(XXH64.hash([]) == 0xEF46_DB37_51D8_E999)
        #expect(XXH64.hash(Array("abc".utf8)) == 0x44BC_2CF5_AD77_0999)
        #expect(XXH64.hash(Array("Nobody inspects the spammish repetition".utf8)) == 0xFBCE_A83C_8A37_8BF1)
        // The low 32 bits libzstd stores as the content checksum of 0...255 repeated three times.
        let bytes = (0 ..< 768).map { UInt8($0 % 256) }
        #expect(UInt32(truncatingIfNeeded: XXH64.hash(bytes)) == 0xC596_036F)
    }

    @Test func blake3MatchesTheReferenceImplementation() {
        for (n, hex) in CodecVectors.blake3 {
            let input = (0 ..< n).map { UInt8($0 % 251) }
            #expect(PcraftCodec.hash(input) == hex, "\(n) bytes")
        }
    }

    @Test func libzstdFramesDecode() throws {
        let unit = CodecTests.words(6000)
        for (name, n, b64) in CodecVectors.zstdFrames {
            let frame = [UInt8](try #require(Data(base64Encoded: b64)))
            let expected = CodecTests.repeated(unit, n)
            #expect(try PCAffinity.ZstdDecoder.decompress(frame, maxSize: 1 << 20) == expected, "\(name)")
            #expect(try PCAffinity.ZstdDecoder.decompress(frame, expectedSize: n) == expected, "\(name)")
            // The bound holds: one byte less is a limit error, not a truncated result.
            #expect(throws: PCAffinity.ZstdDecoder.Failure.sizeMismatch, "\(name)") { try PCAffinity.ZstdDecoder.decompress(frame, maxSize: n - 1) }
        }
    }

    @Test func encoderRoundTripsThroughBothDecoders() throws {
        for (name, data) in CodecTests.samples() {
            let frame = ZstdEncoder.compress(data)
            // The blob path: PCAffinity's bounded decode, and the empty frame it refuses (Affinity never
            // stores one) recognised from its header.
            #expect(try PcraftCodec.decompressBounded(frame, max: data.count, exact: nil, what: name) == data, "\(name)")
            if !data.isEmpty { #expect(try PCAffinity.ZstdDecoder.decompress(frame, expectedSize: data.count) == data, "\(name)") }
            if data.count > 1000 && name != "random" { #expect(frame.count < data.count / 2, "\(name): \(frame.count) bytes") }
            if name == "random" { #expect(frame.count <= data.count + 32, "stored, not expanded") }
            if name == "uniform" { #expect(frame.count < 40, "RLE blocks") }
        }
    }

    /// Empty blobs: PCAffinity refuses an empty frame, so the codec recognises one from its header
    /// (with and without checksum or declared size, single segment or not) and nothing else.
    @Test func emptyFramesAreRecognisedFromTheHeader() throws {
        let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
        let checksum: [UInt8] = [0x99, 0xE9, 0xD8, 0x51]
        let empties: [[UInt8]] = [
            ZstdEncoder.compress([]), ZstdEncoder.compress([], checksum: false),
            magic + [0x20, 0, 1, 0, 0],                       // single segment, FCS 0, raw block
            magic + [0x00, 0x00, 1, 0, 0],                    // window descriptor, no FCS
            magic + [0x04, 0x00, 1, 0, 0] + checksum,         // window descriptor, checksum
            magic + [0x20, 0, 3, 0, 0, 0x41],                 // single segment, empty RLE block
        ]
        for f in empties {
            #expect(PcraftCodec.isEmptyFrame(f), "\(f)")
            #expect(try PcraftCodec.decompressBounded(f, max: 16, exact: nil, what: "blob") == [], "\(f)")
        }
        for f in [ZstdEncoder.compress([1]), magic + [0x20, 1, 1, 0, 0], magic + [0x24, 0, 1, 0, 0] + [0, 0, 0, 0],
                  magic + [0x20, 0, 1, 0], magic + [0x60, 0, 0, 0, 0, 1, 0, 0]] {
            #expect(!PcraftCodec.isEmptyFrame(f), "\(f)")
        }
        #expect(throws: (any Error).self) { try PcraftCodec.decompressBounded(magic + [0x20, 0, 1, 0], max: 16, exact: nil, what: "blob") }
    }

    /// Inputs past the single-segment limit use an 8 MiB window; matches never reach further.
    @Test func largeInputsUseABoundedWindow() throws {
        let data = CodecTests.repeated(CodecTests.words(343_604), ZstdEncoder.singleSegmentMax + 300_000)
        let frame = ZstdEncoder.compress(data)
        #expect(frame[4] & 0x20 == 0, "not single segment")
        #expect(frame[5] == UInt8((ZstdEncoder.windowLog - 10) << 3), "8 MiB window descriptor")
        #expect(try PCAffinity.ZstdDecoder.decompress(frame, maxSize: data.count) == data)
    }

    /// Damaged frames fail cleanly in both decoders (never trap, never over-produce).
    @Test func damagedFramesNeverTrap() throws {
        var rng = Rng(7)
        var frames = CodecTests.samples().filter { $0.1.count > 100 }.map { ZstdEncoder.compress($0.1) }
        frames += try CodecVectors.zstdFrames.map { [UInt8](try #require(Data(base64Encoded: $0.2))) }
        for frame in frames {
            for _ in 0 ..< 150 {
                var m = frame
                for _ in 0 ..< 1 + Int(rng.next() % 3) {
                    switch rng.next() % 3 {
                    case 0: m[Int(rng.next() % UInt64(m.count))] ^= UInt8(1 << (rng.next() % 8))
                    case 1: m[Int(rng.next() % UInt64(m.count))] = UInt8(truncatingIfNeeded: rng.next())
                    default: m.removeLast(Int(rng.next() % UInt64(max(1, m.count / 2))))
                    }
                    if m.isEmpty { break }
                }
                if let out = try? PcraftCodec.decompressBounded(m, max: 1 << 20, exact: nil, what: "damaged") { #expect(out.count <= 1 << 20) }
                _ = try? PCAffinity.ZstdDecoder.decompress(m, expectedSize: 4096)
            }
        }
    }

    // MARK: Cross-checks with the zstd tool (skipped when it is not installed)

    static let zstdTool: String? = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"].first { FileManager.default.isExecutableFile(atPath: $0) }

    static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Frames this encoder writes decode with the reference decoder (libzstd), byte for byte.
    @Test(.enabled(if: zstdTool != nil, "the zstd tool is not installed"))
    func referenceDecoderReadsOurFrames() throws {
        let tool = try #require(CodecTests.zstdTool)
        let dir = tempDir("zstd-cli")
        for (name, data) in CodecTests.samples() {
            let src = dir.appendingPathComponent("\(name).zst"), out = dir.appendingPathComponent("\(name).out")
            try Data(ZstdEncoder.compress(data)).write(to: src)
            #expect(try CodecTests.run(tool, ["-q", "-d", "-f", src.path, "-o", out.path]) == 0, "\(name)")
            #expect((try? Data(contentsOf: out)) == Data(data), "\(name)")
        }
        remove(dir)
    }

    /// Frames from the reference encoder at every strategy decode here, byte for byte.
    @Test(.enabled(if: zstdTool != nil, "the zstd tool is not installed"))
    func ourDecodersReadReferenceFrames() throws {
        let tool = try #require(CodecTests.zstdTool)
        let dir = tempDir("zstd-cli-ref")
        let options = [["-1"], ["-3"], ["-9"], ["-19"], ["--ultra", "-22"], ["--fast=5"], ["-3", "--no-check"], ["-19", "--long=24"],
                       ["-1", "--no-content-size"], ["-12", "--no-content-size"]]
        for (name, data) in CodecTests.samples() where data.count > 100 {
            let src = dir.appendingPathComponent("\(name).bin")
            try Data(data).write(to: src)
            for opt in options {
                let z = dir.appendingPathComponent("\(name).zst")
                #expect(try CodecTests.run(tool, ["-q", "-f"] + opt + [src.path, "-o", z.path]) == 0)
                let frame = [UInt8](try Data(contentsOf: z))
                #expect(try PCAffinity.ZstdDecoder.decompress(frame, maxSize: data.count) == data, "\(name) \(opt)")
                #expect(try PCAffinity.ZstdDecoder.decompress(frame, expectedSize: data.count) == data, "\(name) \(opt)")
            }
        }
        remove(dir)
    }
}
