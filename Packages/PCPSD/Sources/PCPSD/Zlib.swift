// zlib (RFC 1950) streams on top of Apple's Compression framework.
// Native substitution for photocraft-psd's use of flate2 (crates/psd/src/compression.rs:
// `inflate_checked`, `zip_compress`, `zip_decompress`), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// PSD ZIP data is zlib-wrapped: a 2-byte header, raw deflate (RFC 1951) and a big-endian Adler-32 of
// the decompressed bytes. `COMPRESSION_ZLIB` is raw deflate only, so the header and checksum are
// handled here.

import Compression
import Foundation

enum Zlib {
    /// Most bytes a stream may produce past its declared size (padding tolerance, as photocraft).
    static let surplusAllowance = 1 << 20

    // MARK: Adler-32

    static func adler32(_ buf: UnsafeRawBufferPointer, start: UInt32 = 1) -> UInt32 {
        var a = start & 0xFFFF
        var b = start >> 16
        let mod: UInt32 = 65521
        var i = 0
        let n = buf.count
        while i < n {
            let end = min(n, i + 5552)
            while i < end {
                a &+= UInt32(buf[i])
                b &+= a
                i += 1
            }
            a %= mod
            b %= mod
        }
        return b << 16 | a
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 { bytes.withUnsafeBytes { adler32($0) } }

    // MARK: Header

    /// Validates the 2-byte zlib header (deflate method, window ≤ 32K, check bits, no preset dictionary).
    static func checkHeader(_ src: UnsafeRawBufferPointer) throws {
        guard src.count >= 2 else { throw PSDError.decompress("zlib stream shorter than its header") }
        let cmf = src[0], flg = src[1]
        guard cmf & 0x0F == 8, cmf >> 4 <= 7 else { throw PSDError.decompress("not a deflate zlib stream") }
        guard (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 else { throw PSDError.decompress("bad zlib header check bits") }
        guard flg & 0x20 == 0 else { throw PSDError.decompress("zlib preset dictionaries are not supported") }
    }

    // MARK: Inflate

    /// Inflates a complete zlib stream that must produce at least `expected` bytes; returns exactly
    /// `expected` bytes (or none when `keep` is false: validation only). The trailer is verified
    /// unless `verifyChecksum` is false; a stream that runs more than `surplusAllowance` past
    /// `expected` is rejected (decompression bombs).
    static func inflate(_ src: UnsafeRawBufferPointer, expected: Int, keep: Bool = true, verifyChecksum: Bool = true) throws -> [UInt8] {
        try checkHeader(src)
        guard let base = src.baseAddress else { throw PSDError.decompress("empty zlib stream") }
        let body = UnsafeRawBufferPointer(start: base + 2, count: src.count - 2)

        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw PSDError.decompress("could not initialise the deflate decoder")
        }
        defer { compression_stream_destroy(&stream) }
        stream.src_ptr = body.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer<UInt8>(bitPattern: 1)!
        stream.src_size = body.count

        var out = [UInt8]()
        var adler: UInt32 = 1
        var total = 0
        let scratchSize = max(8192, min(1 << 20, expected + 1))
        var scratch = [UInt8](repeating: 0, count: scratchSize)
        if keep {
            do {
                out = try allocate(expected)
            }
        }
        var status = COMPRESSION_STATUS_OK
        // Phase 1: straight into the output buffer.
        if keep && expected > 0 {
            try out.withUnsafeMutableBytes { dst in
                stream.dst_ptr = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
                stream.dst_size = expected
                while stream.dst_size > 0 {
                    let beforeIn = stream.src_size, beforeOut = stream.dst_size
                    status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    if status == COMPRESSION_STATUS_ERROR { throw PSDError.decompress("corrupt deflate data") }
                    if status == COMPRESSION_STATUS_END { break }
                    if beforeIn == stream.src_size, beforeOut == stream.dst_size { throw PSDError.decompress("incomplete zlib stream") }
                }
                total = expected - stream.dst_size
                if verifyChecksum { adler = adler32(UnsafeRawBufferPointer(rebasing: dst[0 ..< total])) }
            }
        }
        // Phase 2: drain into scratch (validation, surplus, or keep == false).
        while status != COMPRESSION_STATUS_END {
            try scratch.withUnsafeMutableBytes { dst in
                stream.dst_ptr = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
                stream.dst_size = dst.count
                let beforeIn = stream.src_size
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                if status == COMPRESSION_STATUS_ERROR { throw PSDError.decompress("corrupt deflate data") }
                let got = dst.count - stream.dst_size
                if verifyChecksum { adler = adler32(UnsafeRawBufferPointer(rebasing: dst[0 ..< got]), start: adler) }
                if keep && total < expected {
                    // Only reachable when expected == 0 (phase 1 skipped).
                    let take = min(got, expected - total)
                    out.replaceSubrange(total ..< total + take, with: dst[0 ..< take])
                }
                total += got
                if status != COMPRESSION_STATUS_END, beforeIn == stream.src_size, got == 0 {
                    throw PSDError.decompress("incomplete zlib stream")
                }
            }
            if total > expected + surplusAllowance {
                throw PSDError.limitExceeded("zlib output exceeds the declared size and padding allowance")
            }
        }
        if total < expected { throw PSDError.decompress("zlib stream produced \(total) of \(expected) bytes") }
        if verifyChecksum {
            // Apple's decoder consumes its whole input and does not report where the deflate data
            // ended, so the trailer is located from the end: the last four bytes, or (padding
            // tolerance) the last four before up to three zero bytes.
            var found = false
            for k in 0 ... 3 where src.count >= 2 + 4 + k {
                let t = src.count - 4 - k
                if k > 0, !src[(src.count - k)...].allSatisfy({ $0 == 0 }) { break }
                let stored = UInt32(src[t]) << 24 | UInt32(src[t + 1]) << 16 | UInt32(src[t + 2]) << 8 | UInt32(src[t + 3])
                if stored == adler { found = true; break }
            }
            guard found else {
                throw PSDError.decompress(src.count < 6 ? "zlib stream is missing its Adler-32 trailer" : "zlib Adler-32 mismatch")
            }
        }
        return out
    }

    static func allocate(_ n: Int) throws -> [UInt8] {
        guard n >= 0, UInt64(n) <= PSDLimits.maxDecodedBytes else { throw PSDError.limitExceeded("not enough memory for the decoded channel data") }
        return [UInt8](repeating: 0, count: n)
    }

    // MARK: Deflate

    /// zlib-compresses `src` (header `78 9C`, Apple's default deflate level, Adler-32 trailer).
    static func compress(_ src: UnsafeRawBufferPointer) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x9C]
        out.reserveCapacity(src.count / 2 + 64)
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return storedZlib(src)
        }
        defer { compression_stream_destroy(&stream) }
        stream.src_ptr = src.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? UnsafePointer<UInt8>(bitPattern: 1)!
        stream.src_size = src.count
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        var status = COMPRESSION_STATUS_OK
        while status == COMPRESSION_STATUS_OK {
            chunk.withUnsafeMutableBytes { dst in
                stream.dst_ptr = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
                stream.dst_size = dst.count
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(contentsOf: dst[0 ..< dst.count - stream.dst_size])
            }
        }
        if status == COMPRESSION_STATUS_ERROR { return storedZlib(src) }
        let a = adler32(src)
        out.append(contentsOf: [UInt8(a >> 24), UInt8(a >> 16 & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a & 0xFF)])
        return out
    }

    static func compress(_ bytes: [UInt8]) -> [UInt8] { bytes.withUnsafeBytes { compress($0) } }

    /// A valid zlib stream of stored (uncompressed) deflate blocks; fallback only.
    static func storedZlib(_ src: UnsafeRawBufferPointer) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65535, src.count - i)
            let last: UInt8 = i + n >= src.count ? 1 : 0
            out.append(last)
            out.append(UInt8(n & 0xFF)); out.append(UInt8(n >> 8))
            out.append(UInt8(~n & 0xFF)); out.append(UInt8((~n >> 8) & 0xFF))
            out.append(contentsOf: src[i ..< i + n])
            i += n
        } while i < src.count
        let a = adler32(src)
        out.append(contentsOf: [UInt8(a >> 24), UInt8(a >> 16 & 0xFF), UInt8(a >> 8 & 0xFF), UInt8(a & 0xFF)])
        return out
    }
}
