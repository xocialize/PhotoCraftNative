// Port of photocraft-affinity (crates/affinity/src/synth.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Synthetic containers for tests and fuzz seeds (photocraft's cargo feature `synth`).
//
// These builders write the layout the reader accepts, so tests can describe documents in a few
// lines. They are **not** an Affinity exporter: nothing written here has been opened in Affinity.
// photocraft compresses with flate2 and ruzstd's encoder; here zlib goes through Apple's Compression
// framework and zstd frames are written as raw and RLE blocks (valid Zstandard, decodable by any
// zstd, and enough to make long runs of zeros tiny).

import Compression
import PCAffinity

public enum Synth {
    public typealias Tag = Affinity.Tag

    /// A field value to encode.
    public indirect enum F: Sendable {
        case u8(UInt8)
        case u32(UInt32)
        case i32(Int32)
        case f32(Float)
        case f64(Double)
        case bool(Bool)
        case enumeration(UInt16, UInt16)
        case str(String)
        /// f64 vector of 2...6 values (points, rectangles, transforms).
        case f64s([Double])
        /// Fixed-size struct (colour components), 1...64 bytes.
        case structure([UInt8])
        /// Array of fixed-size records, all `size` bytes.
        case records(UInt16, [[UInt8]])
        case u8s([UInt8])
        case entry(String)
        /// Shared object: `def` defines id with class chain and fields, `ref` links back.
        case def(UInt32, [Tag], [(Tag, F)])
        case ref(UInt32)
        case null
        /// Inline object.
        case obj(Tag, [(Tag, F)])
        /// Positional (untagged) object.
        case pos([F])
        /// Array of shared objects / links.
        case shared([F])
        /// Array of inline objects of one class.
        case objs(Tag, [[(Tag, F)]])
        /// Raw bytes appended verbatim (malformed-input tests).
        case raw([UInt8])
    }

    public static func tag(_ s: String) -> Tag {
        Tag(s)
    }

    private static func put(_ out: inout [UInt8], _ t: Tag) {
        le(&out, t.rawValue)
    }

    private static func le<T: FixedWidthInteger>(_ out: inout [UInt8], _ v: T) {
        withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
    }

    private static func code(_ f: F) -> UInt8 {
        switch f {
        case .u8: 0x01
        case .u32: 0x03
        case .i32: 0x07
        case .f32: 0x09
        case .f64: 0x0a
        case .bool: 0x29
        case .enumeration: 0x2a
        case .str: 0x2b
        case .f64s(let v): 0x22 &+ UInt8(truncatingIfNeeded: v.count)
        case .structure(let b): 0x34 &+ UInt8(truncatingIfNeeded: b.count)
        case .records: 0x80 | 0x2c
        case .u8s: 0x80 | 0x01
        case .entry: 0x33
        case .def, .ref, .null: 0x31
        case .obj: 0x32
        case .pos: 0x30
        case .shared: 0x80 | 0x31
        case .objs: 0x80 | 0x32
        case .raw: 0
        }
    }

    private static func payload(_ out: inout [UInt8], _ f: F) {
        switch f {
        case .u8(let v): out.append(v)
        case .u32(let v): le(&out, v)
        case .i32(let v): le(&out, v)
        case .f32(let v): le(&out, v.bitPattern)
        case .f64(let v): le(&out, v.bitPattern)
        case .bool(let v): out.append(v ? 1 : 0)
        case .enumeration(let id, let version):
            le(&out, id)
            le(&out, version)
        case .str(let s):
            le(&out, UInt32(s.utf8.count))
            out.append(contentsOf: s.utf8)
        case .f64s(let v):
            for x in v { le(&out, x.bitPattern) }
        case .structure(let b):
            out.append(contentsOf: b)
        case .records(let size, let recs):
            le(&out, UInt32(recs.count))
            le(&out, size)
            for r in recs { out.append(contentsOf: r) }
        case .u8s(let v):
            le(&out, UInt32(v.count))
            out.append(contentsOf: v)
        case .entry(let name):
            put(&out, tag("Data"))
            le(&out, UInt32(name.utf8.count))
            out.append(contentsOf: name.utf8)
        case .def(let id, let chain, let fields):
            out.append(1)
            le(&out, id)
            // Class chain: each level but the last carries no fields here; the last ends the chain.
            for t in chain.dropLast() {
                out.append(0)
                put(&out, t)
                le(&out, UInt16(0))
                out.append(0)
            }
            out.append(1)
            put(&out, chain.last ?? Tag(0))
            fieldsInto(&out, fields, tagged: true)
        case .ref(let id):
            out.append(2)
            le(&out, id)
        case .null:
            out.append(0)
        case .obj(let cls, let fields):
            out.append(1)
            put(&out, cls)
            le(&out, UInt16(0))
            fieldsInto(&out, fields, tagged: true)
        case .pos(let items):
            for f in items {
                out.append(code(f))
                payload(&out, f)
            }
            out.append(0)
        case .shared(let items):
            le(&out, UInt32(items.count))
            for f in items { payload(&out, f) }
        case .objs(let cls, let items):
            le(&out, UInt32(items.count))
            put(&out, cls)
            le(&out, UInt16(0))
            for fields in items {
                out.append(1)
                fieldsInto(&out, fields, tagged: true)
            }
        case .raw(let b):
            out.append(contentsOf: b)
        }
    }

    private static func fieldsInto(_ out: inout [UInt8], _ fields: [(Tag, F)], tagged: Bool) {
        for (t, f) in fields {
            if case .raw(let b) = f {
                out.append(contentsOf: b)
                continue
            }
            out.append(code(f))
            if tagged { put(&out, t) }
            payload(&out, f)
        }
        out.append(0)
    }

    /// A `doc.dat` stream with root class `Pers`.
    public static func stream(_ root: [(Tag, F)]) -> [UInt8] {
        var out: [UInt8] = [0x00, 0xFF, 0x4B, 0x53]
        le(&out, UInt16(2))
        put(&out, tag("Pers"))
        le(&out, UInt16(0))
        le(&out, UInt32(30))
        fieldsInto(&out, root, tagged: true)
        return out
    }

    /// How an entry is stored.
    public enum Method: Sendable, CaseIterable {
        case stored, zlib, zstd
    }

    /// A version-12 container with one `#FT4` table holding `entries`, then an optional thumbnail record.
    public static func container(_ entries: [(String, [UInt8], Method)], thumbnailPNG: [UInt8]? = nil) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 72)
        out.replaceSubrange(0..<4, with: Affinity.magic)
        out.replaceSubrange(4..<6, with: [12, 0])
        out.replaceSubrange(6..<8, with: [4, 0])
        out.replaceSubrange(8..<12, with: Array("nsrP".utf8))
        out.replaceSubrange(12..<16, with: Array("#Inf".utf8))
        out.replaceSubrange(64..<68, with: Array("Prot".utf8))
        var records: [[UInt8]] = []
        for (i, (name, data, method)) in entries.enumerated() {
            let packed: [UInt8]
            switch method {
            case .stored: packed = data
            case .zlib: packed = zlib(data)
            case .zstd: packed = zstd(data)
            }
            let offset = UInt64(out.count)
            out.append(contentsOf: Array("#Fil".utf8))
            out.append(contentsOf: packed)
            var r: [UInt8] = []
            le(&r, UInt32(i + 1))
            r.append(0)
            le(&r, offset)
            le(&r, UInt64(data.count))
            le(&r, UInt64(packed.count))
            le(&r, crc32(data))
            switch method {
            case .stored: r.append(0)
            case .zlib: r.append(1)
            case .zstd: r.append(2)
            }
            le(&r, UInt32(0))
            le(&r, UInt32(0))
            le(&r, UInt16(name.utf8.count))
            r.append(contentsOf: name.utf8)
            records.append(r)
        }
        let fat = UInt64(out.count)
        out.append(contentsOf: Array("#FT4".utf8))
        le(&out, UInt64(0))
        le(&out, UInt64(1_700_000_000))
        out.append(contentsOf: [UInt8](repeating: 0, count: 24))
        le(&out, UInt32(records.count))
        out.append(contentsOf: [UInt8](repeating: 0, count: 8))
        le(&out, UInt16(0))
        out.append(0)
        for r in records { out.append(contentsOf: r) }
        let thumb = UInt64(out.count)
        out.replaceSubrange(16..<24, with: bytesLE(fat))
        if let png = thumbnailPNG {
            out.replaceSubrange(24..<32, with: bytesLE(thumb))
            out.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF] + Array("Thmb".utf8))
            le(&out, UInt32(1))
            le(&out, UInt32(png.count + 13))
            le(&out, UInt32(29))
            le(&out, UInt32(0))
            le(&out, UInt32(png.count))
            out.append(1)
            out.append(contentsOf: png)
        }
        return out
    }

    /// Little-endian bytes of an integer.
    public static func bytesLE<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
        var out: [UInt8] = []
        le(&out, v)
        return out
    }

    /// Big-endian bytes of an integer (PNG fields).
    public static func bytesBE<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
        withUnsafeBytes(of: v.bigEndian) { Array($0) }
    }

    /// CRC-32 (IEEE), as `crc32fast::hash`.
    public static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        Checksum.crc32(Array(bytes))
    }

    // MARK: - Writers for the compressed methods

    /// A zlib stream (RFC 1950): header for the fastest level, raw DEFLATE from Compression, Adler-32.
    public static func zlib(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        out.append(contentsOf: deflate(data))
        out.append(contentsOf: bytesBE(Checksum.adler32(data)))
        return out
    }

    private static func deflate(_ data: [UInt8]) -> [UInt8] {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return [0x03, 0x00] }
        defer { compression_stream_destroy(stream) }
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        var placeholder: UInt8 = 0
        data.withUnsafeBufferPointer { src in
            withUnsafeMutablePointer(to: &placeholder) { empty in
                stream.pointee.src_ptr = src.baseAddress ?? UnsafePointer(empty)
                stream.pointee.src_size = src.count
                while true {
                    let (status, produced) = chunk.withUnsafeMutableBufferPointer { dst -> (compression_status, Int) in
                        stream.pointee.dst_ptr = dst.baseAddress ?? empty
                        stream.pointee.dst_size = dst.count
                        let status = compression_stream_process(stream, Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue))
                        return (status, dst.count - stream.pointee.dst_size)
                    }
                    out.append(contentsOf: chunk[0..<produced])
                    if status != COMPRESSION_STATUS_OK { break }
                }
            }
        }
        return out
    }

    /// One Zstandard frame of raw and RLE blocks, with an 8-byte content size and a 128 KiB window.
    public static func zstd(_ data: [UInt8]) -> [UInt8] {
        let maxBlock = 128 << 10
        var out: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0xC0, 0x38]
        le(&out, UInt64(data.count))
        var blocks: [(rle: Bool, start: Int, count: Int)] = []
        var pending = 0
        var i = 0
        func flushRaw(upTo end: Int) {
            var s = pending
            while s < end {
                let n = min(maxBlock, end - s)
                blocks.append((false, s, n))
                s += n
            }
        }
        while i < data.count {
            var j = i + 1
            while j < data.count, data[j] == data[i] { j += 1 }
            if j - i >= 64 {
                flushRaw(upTo: i)
                var s = i
                while s < j {
                    let n = min(maxBlock, j - s)
                    blocks.append((true, s, n))
                    s += n
                }
                pending = j
            }
            i = j
        }
        flushRaw(upTo: data.count)
        if blocks.isEmpty { blocks.append((false, 0, 0)) }
        for (k, b) in blocks.enumerated() {
            let last: UInt32 = k == blocks.count - 1 ? 1 : 0
            let header = last | (b.rle ? 1 : 0) << 1 | UInt32(b.count) << 3
            out.append(contentsOf: [UInt8(header & 0xFF), UInt8((header >> 8) & 0xFF), UInt8(header >> 16)])
            if b.rle {
                out.append(data[b.start])
            } else {
                out.append(contentsOf: data[b.start..<(b.start + b.count)])
            }
        }
        return out
    }
}
