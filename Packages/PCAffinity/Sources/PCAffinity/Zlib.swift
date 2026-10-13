// Port of photocraft-affinity (crates/affinity/src/container.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// zlib archive entries (compression method 1). photocraft reads them with flate2's `ZlibDecoder`
// behind a `take(size + 1)`; here the zlib wrapper is checked in Swift and the raw DEFLATE data
// goes through Apple's Compression framework (`COMPRESSION_ZLIB` is raw RFC 1951), with the
// output capped at `size + 1` bytes so a stream that decodes past its declared size is caught
// without unbounded allocation.

import Compression

enum Zlib {
    /// Decode at most `size + 1` bytes of a zlib stream. A stream that ends early or decodes too much
    /// returns what it produced; the caller's exact-size check reports it, as in photocraft.
    static func inflate(_ data: ArraySlice<UInt8>, size: Int) throws(AffinityError) -> [UInt8] {
        let corrupt = AffinityError.malformed("corrupt compressed entry")
        let input = Array(data)
        // RFC 1950 header: deflate with a window of at most 32 KiB, a valid check value, no preset
        // dictionary (flate2 rejects one too).
        guard input.count >= 2 else { throw corrupt }
        let cmf = input[0]
        let flg = input[1]
        guard cmf & 0x0F == 8, cmf >> 4 <= 7, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0, flg & 0x20 == 0 else {
            throw corrupt
        }
        let cap = size == Int.max ? size : size + 1
        guard let (out, ended) = rawInflate(input, from: 2, cap: cap) else { throw corrupt }
        // The Adler-32 trailer of a complete stream must match (flate2 checks it too). Compression
        // consumes the whole input, so the trailer is taken as the last four bytes of the entry.
        if ended, out.count <= size, input.count >= 6 {
            let n = input.count
            let stored = UInt32(input[n - 4]) << 24 | UInt32(input[n - 3]) << 16 | UInt32(input[n - 2]) << 8 | UInt32(input[n - 1])
            guard stored == Checksum.adler32(out) else { throw corrupt }
        }
        return out
    }

    /// Raw DEFLATE through Compression, stopping after `cap` output bytes. Returns the output and
    /// whether the stream reached its end, or nil when Compression reports an error.
    private static func rawInflate(_ input: [UInt8], from start: Int, cap: Int) -> ([UInt8], Bool)? {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        var out: [UInt8] = []
        out.reserveCapacity(min(cap, 64 << 20))
        let chunkSize = 1 << 18
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var placeholder: UInt8 = 0
        return input.withUnsafeBufferPointer { src -> ([UInt8], Bool)? in
            withUnsafeMutablePointer(to: &placeholder) { empty -> ([UInt8], Bool)? in
                let base = src.baseAddress.map { $0 + start } ?? UnsafePointer(empty)
                stream.pointee.src_ptr = base
                stream.pointee.src_size = max(0, src.count - start)
                while true {
                    let want = min(chunkSize, cap - out.count)
                    if want <= 0 { return (out, false) }
                    let (status, produced) = chunk.withUnsafeMutableBufferPointer { dst -> (compression_status, Int) in
                        stream.pointee.dst_ptr = dst.baseAddress ?? empty
                        stream.pointee.dst_size = want
                        let status = compression_stream_process(stream, Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue))
                        return (status, want - stream.pointee.dst_size)
                    }
                    if status == COMPRESSION_STATUS_ERROR { return nil }
                    if produced > 0 { out.append(contentsOf: chunk[0..<produced]) }
                    if status == COMPRESSION_STATUS_END { return (out, true) }
                    // A truncated or damaged stream stops making progress: return what it gave.
                    if produced == 0 { return (out, false) }
                }
            }
        }
    }
}
