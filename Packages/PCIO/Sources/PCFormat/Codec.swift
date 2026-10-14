// The object codec of `.pcraft` bundles: BLAKE3 names, zstd payloads.
// Port of photocraft-format (crates/format/src/store.rs: `compress`, `decompress_bounded`,
// `decompress`, `hash_bytes`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// # Codec decision
//
// photocraft names every tile and blob by the BLAKE3 hash of its uncompressed bytes
// (`tiles/<hex>.zst`), stores it as a zstd frame (ruzstd, `CompressionLevel::Fastest`) and
// verifies the hash on load. The SDK has neither (CryptoKit: SHA-2 only; Compression: LZ4, zlib,
// LZMA, LZFSE, Brotli). Requirement one is that a bundle saved by photocraft opens here, so this
// port reads zstd through PCAffinity's `ZstdDecoder` (tiles at their known size; blobs, whose size
// the manifest doesn't record, bounded by `LoadOptions.maxBlobBytes`) and hashes with PCIOCore's
// `BLAKE3`.
//
// For writing, the options were (a) photocraft-compatible zstd named by BLAKE3, (b) a native
// variant (e.g. LZFSE objects flagged in the manifest) only this port reads, (c) raw/RLE-only zstd
// frames. Chosen: (a) with a real compressor (`ZstdEncoder`: zstd's "fast" LZ77, Huffman literals,
// FSE sequences with fitted or predefined tables, RLE/raw blocks, XXH64 checksum). Bundles written
// here therefore open in photocraft unchanged (same layout, names, hashes and frame format), and
// one codec serves both directions.
//
// Measured (release build, Apple Silicon, 2026-10) on a 4096² RGBA8 layer — a photographic field
// with σ = 3 sensor noise, flat colour areas and a transparent area — as 256 tiles of 256², each
// its own frame:
//
//   codec                                  size        encode: 1 thread / all cores   decode, 1 thread
//   raw                                    64.00 MiB   —                              —
//   (c) raw + RLE blocks only              61.00 MiB   ≈ memcpy                       ≈ memcpy
//   (a) ZstdEncoder (chosen)               32.64 MiB   310–330 ms / 23–32 ms          450–460 ms (PCAffinity)
//       libzstd 1.5.7 level 1 (reference)  33.11 MiB   ≈ 270 ms
//       libzstd level 3                    28.65 MiB   ≈ 510 ms
//   (b) LZFSE (Compression framework)      28.50 MiB   ≈ 940 ms                       65–75 ms
//
// Whole document (that one layer): `.pcraft` ZIP 32.73 MiB; save 93–116 ms, incremental resave
// 63–88 ms, load 34–40 ms (tiles hashed, compressed and verified on all cores). A directory bundle
// saves in ≈ 1.1 s: one `F_FULLFSYNC` per object file, as photocraft does. BLAKE3 over the 64 MiB:
// 105–150 ms on one thread, 9–11 ms on all cores.
//
// The encoder matches libzstd level 1 (photocraft writes ruzstd's fastest level, a comparable fast
// LZ level); (c) saves almost nothing on photographic tiles; LZFSE's 13 % smaller files would cost
// photocraft compatibility and a 3× slower save.

import PCAffinity
import PCIOCore

enum PcraftCodec {
    /// A zstd frame of `data`, in an array no larger than it needs: the encoder reserves half the
    /// input for its output, and compressed objects are kept (a writer's cache, a save's batch), so
    /// a 64 KiB tile that compresses to 100 bytes must not hold 32 KiB.
    static func compress(_ data: [UInt8]) -> [UInt8] {
        let z = ZstdEncoder.compress(data)
        guard z.capacity > z.count + z.count / 8 + 64 else { return z }
        return [UInt8](unsafeUninitializedCapacity: z.count) { buf, n in
            z.withUnsafeBufferPointer { _ = buf.initialize(fromContentsOf: $0) }
            n = z.count
        }
    }

    /// The content address: lower-case hex BLAKE3 of the uncompressed bytes.
    static func hash(_ data: [UInt8]) -> Hash { Convert.hex(BLAKE3.hash(data)) }

    /// Decodes a zstd frame of at most `max` bytes (`limitExceeded` beyond). With `exact`, the
    /// decoded length must be exactly that (`corrupt` otherwise).
    static func decompressBounded(_ data: [UInt8], max: Int, exact: Int?, what: String) throws(FormatError) -> [UInt8] {
        if let n = exact {
            do throws(PCAffinity.ZstdDecoder.Failure) {
                return try PCAffinity.ZstdDecoder.decompress(data, expectedSize: n)
            } catch .sizeMismatch {
                throw .corrupt("\(what): expected \(n) bytes")
            } catch {
                throw .corrupt("\(what): zstd: corrupt frame")
            }
        }
        do throws(PCAffinity.ZstdDecoder.Failure) {
            return try PCAffinity.ZstdDecoder.decompress(data, maxSize: max)
        } catch .sizeMismatch {
            throw .limitExceeded("\(what) exceeds \(max) bytes")
        } catch {
            // PCAffinity refuses a frame with empty content (Affinity never stores one); an empty
            // blob is one (photocraft's ruzstd writes it so).
            if isEmptyFrame(data) { return [] }
            throw .corrupt("\(what): zstd: corrupt frame")
        }
    }

    /// Whether `d` starts with one zstd frame whose content is empty: the frame header (a declared
    /// content size, if any, of 0), a single last raw or RLE block of size 0 and the optional
    /// XXH64 checksum of nothing. Header parsing only; anything else is left to the decoder.
    static func isEmptyFrame(_ d: [UInt8]) -> Bool {
        guard d.count >= 8, d[0] == 0x28, d[1] == 0xB5, d[2] == 0x2F, d[3] == 0xFD else { return false }
        let fhd = d[4]
        guard fhd & 0x08 == 0 else { return false }
        let single = fhd & 0x20 != 0, checksum = fhd & 0x04 != 0
        var at = 5 + (single ? 0 : 1) + [0, 1, 2, 4][Int(fhd & 3)]
        let fcsFlag = Int(fhd >> 6)
        // The 2-byte field stores size − 256, so it can't say 0.
        if fcsFlag == 1 { return false }
        let fcsSize = fcsFlag == 0 ? (single ? 1 : 0) : [0, 2, 4, 8][fcsFlag]
        guard at + fcsSize + 3 <= d.count, d[at ..< at + fcsSize].allSatisfy({ $0 == 0 }) else { return false }
        at += fcsSize
        let bh = UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16
        let (last, type, size) = (bh & 1, (bh >> 1) & 3, bh >> 3)
        guard last == 1, size == 0, type == 0 || type == 1 else { return false }
        at += 3 + (type == 1 ? 1 : 0)
        guard checksum else { return at <= d.count }
        let c = UInt32(truncatingIfNeeded: XXH64.hash([UInt8]()))
        return at + 4 <= d.count && Array(d[at ..< at + 4]) == [UInt8(c & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c >> 16 & 0xFF), UInt8(c >> 24)]
    }

    static func decompress(_ data: [UInt8], expected: Int, what: String) throws(FormatError) -> [UInt8] {
        try decompressBounded(data, max: expected, exact: expected, what: what)
    }
}
