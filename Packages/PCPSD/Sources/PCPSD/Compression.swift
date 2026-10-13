// Channel image data codecs: Raw, RLE (PackBits, 2-byte row counts in PSD and 4-byte in PSB), ZIP
// and ZIP with prediction (8/16-bit sample deltas, 32-bit byte-plane shuffle + delta).
// Port of photocraft-psd (crates/psd/src/compression.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors. Decode coverage cross-checked against PhotoDemon pdPSDLayer.cls
// (DecodeChannels), BSD-2-Clause, © Tanner Helland and contributors: PhotoDemon (following the
// MIT Paint.NET PsdPlugin) treats ZIP without prediction at 32 bits as ZIP with prediction, which is
// how Photoshop reads it; see `PlaneCodec`. PackBits loop shape cross-checked against Compositor
// IO/PSD/PSDChannelCoder.swift, MIT, © 2026 Wonder Assembly LLC (no code copied).
//
// Decoded data is planar big-endian samples: `planes × height × rowBytes`; depth 1 packs 8 pixels
// per byte, most significant bit first.

import Foundation

/// Safety limits shared by the parsers.
public enum PSDLimits {
    /// Most bytes one decode may produce: 8 GiB on 64-bit targets (a 30000² RGB merged image is
    /// 2.7 GB and a 33000² 16-bit channel 2.2 GB; photocraft #375).
    public static let maxDecodedBytes: UInt64 = 8 << 30
    /// ActionDescriptor nesting limit.
    public static let maxDescriptorDepth = 64
    /// Channels per layer accepted by the parser.
    public static let maxLayerChannels: UInt16 = 64
}

/// Compression method stored before channel and merged image data.
public enum PSDCompression: Hashable, Sendable, CustomStringConvertible {
    /// 0: uncompressed.
    case raw
    /// 1: PackBits RLE with a per-row byte-count table.
    case rle
    /// 2: zlib without prediction (read as predicted at 32 bits, as Photoshop does).
    case zip
    /// 3: zlib with horizontal delta prediction.
    case zipPrediction
    /// Unknown method; data is kept but cannot be decoded.
    case unknown(UInt16)

    public static let all: [PSDCompression] = [.raw, .rle, .zip, .zipPrediction]

    public init(code: UInt16) {
        switch code {
        case 0: self = .raw
        case 1: self = .rle
        case 2: self = .zip
        case 3: self = .zipPrediction
        default: self = .unknown(code)
        }
    }

    public var code: UInt16 {
        switch self {
        case .raw: 0
        case .rle: 1
        case .zip: 2
        case .zipPrediction: 3
        case let .unknown(v): v
        }
    }

    public var description: String {
        switch self {
        case .raw: "Raw"
        case .rle: "RLE"
        case .zip: "ZIP"
        case .zipPrediction: "ZIP+prediction"
        case let .unknown(v): "Unknown(\(v))"
        }
    }
}

/// PackBits (Apple/TIFF) run-length coding as used by Photoshop RLE.
public enum PackBits {
    /// Encodes one row, appending to `out`. Never emits the `-128` no-op.
    public static func encode(_ src: UnsafeRawBufferPointer, into out: inout [UInt8]) {
        let n = src.count
        var i = 0
        while i < n {
            var run = 1
            while i + run < n, run < 128, src[i + run] == src[i] { run += 1 }
            if run >= 2 {
                out.append(UInt8(bitPattern: Int8(1 - run)))
                out.append(src[i])
                i += run
                continue
            }
            let start = i
            var len = 0
            while i < n, len < 128 {
                if i + 2 < n, src[i] == src[i + 1], src[i] == src[i + 2] { break }
                i += 1
                len += 1
            }
            out.append(UInt8(len - 1))
            out.append(contentsOf: src[start ..< start + len])
        }
    }

    public static func encode(_ src: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(src.count + src.count / 128 + 1)
        src.withUnsafeBytes { encode($0, into: &out) }
        return out
    }

    /// Decodes `src` into exactly `expected` bytes at `dst`. Errors when the input ends early or a
    /// packet overflows the row; input after the row is complete is ignored. With `lenient`, an
    /// overflowing packet is clipped and a short row is zero-filled (salvage mode). Returns the
    /// number of input bytes consumed.
    @discardableResult
    static func decode(_ src: UnsafeRawBufferPointer, expected: Int, into dst: UnsafeMutableRawBufferPointer, lenient: Bool = false) throws -> Int {
        var i = 0
        var o = 0
        let n = src.count
        while o < expected {
            guard i < n else {
                if lenient {
                    for k in o ..< expected { dst[k] = 0 }
                    return i
                }
                throw PSDError.decompress("PackBits row ended early")
            }
            let h = Int8(bitPattern: src[i])
            i += 1
            if h >= 0 {
                var len = Int(h) + 1
                if i + len > n {
                    guard lenient else { throw PSDError.decompress("PackBits literal truncated") }
                    len = n - i
                }
                if o + len > expected {
                    guard lenient else { throw PSDError.decompress("PackBits literal overflows row") }
                    len = expected - o
                }
                dst.baseAddress!.advanced(by: o).copyMemory(from: src.baseAddress!.advanced(by: i), byteCount: len)
                o += len
                i += Int(h) + 1
            } else if h != -128 {
                var len = 1 - Int(h)
                guard i < n else {
                    if lenient { continue }
                    throw PSDError.decompress("PackBits run truncated")
                }
                let b = src[i]
                i += 1
                if o + len > expected {
                    guard lenient else { throw PSDError.decompress("PackBits run overflows row") }
                    len = expected - o
                }
                dst.baseAddress!.advanced(by: o).initializeMemory(as: UInt8.self, repeating: b, count: len)
                o += len
            }
        }
        return min(i, n)
    }

    /// Decodes into a new array of exactly `expected` bytes.
    public static func decode(_ src: [UInt8], expected: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: expected)
        try src.withUnsafeBytes { s in
            try out.withUnsafeMutableBytes { d in _ = try decode(s, expected: expected, into: d) }
        }
        return out
    }
}

/// Geometry of a set of planes to encode or decode.
public struct PlaneLayout: Hashable, Sendable {
    /// Number of planes (1 for a layer channel, the channel count for the merged image).
    public var planes: Int
    public var width: Int
    public var height: Int
    /// Bits per sample (1, 8, 16, 32).
    public var depth: UInt16
    /// PSD or PSB (RLE count width).
    public var version: PSDVersion

    public init(planes: Int, width: Int, height: Int, depth: UInt16, version: PSDVersion) {
        self.planes = planes
        self.width = width
        self.height = height
        self.depth = depth
        self.version = version
    }

    public var rowBytes: Int { PSDHeader.rowBytes(width: width, depth: depth) }

    /// Total rows over all planes.
    public func rows() throws -> Int {
        let (v, o) = planes.multipliedReportingOverflow(by: height)
        guard !o, planes >= 0, height >= 0 else { throw PSDError.limitExceeded("row count overflow") }
        return v
    }

    /// Total decoded bytes without the `maxDecodedBytes` cap.
    public func totalBytes() throws -> UInt64 {
        guard planes >= 0, width >= 0, height >= 0 else { throw PSDError.limitExceeded("decoded size overflow") }
        let (a, o1) = UInt64(planes).multipliedReportingOverflow(by: UInt64(height))
        let (b, o2) = a.multipliedReportingOverflow(by: UInt64(rowBytes))
        guard !o1, !o2 else { throw PSDError.limitExceeded("decoded size overflow") }
        return b
    }

    /// Total decoded bytes, checked against `PSDLimits.maxDecodedBytes`.
    public func decodedLength() throws -> Int {
        let t = try totalBytes()
        guard t <= PSDLimits.maxDecodedBytes else { throw PSDError.limitExceeded("decoded channel data exceeds maxDecodedBytes") }
        guard t <= UInt64(Int.max) else { throw PSDError.limitExceeded("decoded size exceeds address space") }
        return Int(t)
    }

    var countSize: Int { version.isPSB ? 4 : 2 }
}

/// Encoders and decoders for planar channel data (the bytes after the 2-byte compression field).
public enum PlaneCodec {
    // MARK: Decode

    /// Decodes planar data. `lenient` salvages damaged RLE (wrong row counts, overflowing packets)
    /// and ZIP streams with a bad or missing Adler-32 instead of failing.
    public static func decode(_ compression: PSDCompression, _ data: Data, layout: PlaneLayout, lenient: Bool = false) throws -> [UInt8] {
        try data.withUnsafeBytes { try decode(compression, $0, layout: layout, lenient: lenient) }
    }

    public static func decode(_ compression: PSDCompression, _ src: UnsafeRawBufferPointer, layout: PlaneLayout, lenient: Bool = false) throws -> [UInt8] {
        let total = try layout.decodedLength()
        switch compression {
        case .raw:
            guard src.count >= total else { throw PSDError.unexpectedEOF(offset: src.count, needed: total - src.count) }
            return Array(src[0 ..< total])
        case .rle:
            return try decodeRLE(src, layout: layout, total: total, lenient: lenient)
        case .zip:
            var v = try Zlib.inflate(src, expected: total, verifyChecksum: !lenient)
            if layout.depth == 32 {
                // Photoshop reads code 2 at 32 bits as predicted (PsdPlugin / PhotoDemon). Files from
                // writers that stored plain floats are recognised and kept as they are.
                let plain = v
                try unpredict(&v, layout: layout)
                if !floatsPlausible(v, allowNonFinite: false, bound: 1e6), floatsPlausible(plain, allowNonFinite: false, bound: 1e6) {
                    return plain
                }
            }
            return v
        case .zipPrediction:
            var v = try Zlib.inflate(src, expected: total, verifyChecksum: !lenient)
            try unpredict(&v, layout: layout)
            return v
        case let .unknown(c):
            throw PSDError.unsupported("compression method \(c)")
        }
    }

    /// Whether every 32-bit sample is finite (and, with `bound`, no larger than it in magnitude).
    static func floatsPlausible(_ v: [UInt8], allowNonFinite: Bool, bound: Float = .infinity) -> Bool {
        v.withUnsafeBytes { raw in
            let n = raw.count / 4
            for i in 0 ..< n {
                let f = Float(bitPattern: UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
                if !f.isFinite { if !allowNonFinite { return false } else { continue } }
                if abs(f) > bound { return false }
            }
            return true
        }
    }

    static func readCount(_ src: UnsafeRawBufferPointer, at i: Int, psb: Bool) -> Int {
        psb ? Int(UInt32(bigEndian: src.loadUnaligned(fromByteOffset: i, as: UInt32.self)))
            : Int(UInt16(bigEndian: src.loadUnaligned(fromByteOffset: i, as: UInt16.self)))
    }

    static func decodeRLE(_ src: UnsafeRawBufferPointer, layout: PlaneLayout, total: Int, lenient: Bool) throws -> [UInt8] {
        let rows = try layout.rows()
        let rb = layout.rowBytes
        let cs = layout.countSize
        guard rows.multipliedReportingOverflow(by: cs).partialValue <= src.count, rows <= src.count else {
            throw PSDError.unexpectedEOF(offset: src.count, needed: rows * cs - src.count)
        }
        let tableEnd = rows * cs
        // PackBits expands at most 64x (2 input bytes -> 128 output bytes).
        if !lenient, UInt64(total) > UInt64(src.count - tableEnd) * 64 {
            throw PSDError.decompress("RLE data too short for the declared size")
        }
        var offsets = [Int](repeating: 0, count: rows + 1)
        var at = tableEnd
        for row in 0 ..< rows {
            offsets[row] = at
            at += readCount(src, at: row * cs, psb: layout.version.isPSB)
        }
        offsets[rows] = at
        var out = try Zlib.allocate(total)
        if offsets[rows] > src.count && !lenient {
            throw PSDError.unexpectedEOF(offset: src.count, needed: offsets[rows] - src.count)
        }
        if rb == 0 { return out }
        do {
            try out.withUnsafeMutableBytes { dstBuf in
                let dst = UncheckedSendable(dstBuf), srcBox = UncheckedSendable(src)
                let offsets = offsets
                let body: @Sendable (Int) throws -> Void = { plane in
                    let src = srcBox.value
                    for y in 0 ..< layout.height {
                        let row = plane * layout.height + y
                        let s = offsets[row], e = min(offsets[row + 1], src.count)
                        guard s <= e else { throw PSDError.unexpectedEOF(offset: s, needed: 1) }
                        let d = UnsafeMutableRawBufferPointer(rebasing: dst.value[row * rb ..< (row + 1) * rb])
                        try PackBits.decode(UnsafeRawBufferPointer(rebasing: src[s ..< e]), expected: rb, into: d, lenient: lenient)
                    }
                }
                if layout.planes > 1, total >= 1 << 20 {
                    // Planes decode independently: their rows start at offsets known from the count table.
                    let errors = ErrorBox()
                    DispatchQueue.concurrentPerform(iterations: layout.planes) { p in
                        do { try body(p) } catch { errors.set(error) }
                    }
                    if let e = errors.error { throw e }
                } else {
                    for p in 0 ..< layout.planes { try body(p) }
                }
            }
        } catch where lenient {
            // Salvage: ignore the count table and decode the rows as one continuous PackBits stream.
            out = try Zlib.allocate(total)
            try out.withUnsafeMutableBytes { dst in
                var i = tableEnd
                for row in 0 ..< rows {
                    let d = UnsafeMutableRawBufferPointer(rebasing: dst[row * rb ..< (row + 1) * rb])
                    let s = UnsafeRawBufferPointer(rebasing: src[min(i, src.count)...])
                    i += try PackBits.decode(s, expected: rb, into: d, lenient: true)
                }
            }
        }
        return out
    }

    // MARK: Encode

    /// Encodes planar data. ZIP at 32 bits is written predicted (what Photoshop reads for code 2);
    /// `PSDChannel.encode` stores such channels as code 3 so every reader agrees.
    public static func encode(_ compression: PSDCompression, _ decoded: [UInt8], layout: PlaneLayout) throws -> [UInt8] {
        let total = try layout.decodedLength()
        guard decoded.count == total else {
            throw PSDError.invalid("decoded buffer has \(decoded.count) bytes, layout requires \(total)")
        }
        switch compression {
        case .raw:
            return decoded
        case .rle:
            return try encodeRLE(decoded, layout: layout)
        case .zip:
            if layout.depth == 32 {
                var v = decoded
                try predict(&v, layout: layout)
                return Zlib.compress(v)
            }
            return Zlib.compress(decoded)
        case .zipPrediction:
            var v = decoded
            try predict(&v, layout: layout)
            return Zlib.compress(v)
        case let .unknown(c):
            throw PSDError.unsupported("compression method \(c)")
        }
    }

    static func encodeRLE(_ decoded: [UInt8], layout: PlaneLayout) throws -> [UInt8] {
        let rows = try layout.rows()
        let rb = layout.rowBytes
        let cs = layout.countSize
        var table = [UInt8](repeating: 0, count: rows * cs)
        var body = [UInt8]()
        body.reserveCapacity(decoded.count / 2)
        try decoded.withUnsafeBytes { src in
            for row in 0 ..< rows {
                let start = body.count
                PackBits.encode(UnsafeRawBufferPointer(rebasing: src[row * rb ..< (row + 1) * rb]), into: &body)
                let n = body.count - start
                if cs == 2 {
                    guard n <= Int(UInt16.max) else { throw PSDError.limitExceeded("RLE row exceeds 65535 bytes (use PSB)") }
                    table[row * 2] = UInt8(n >> 8)
                    table[row * 2 + 1] = UInt8(n & 0xFF)
                } else {
                    guard n <= Int(UInt32.max) else { throw PSDError.limitExceeded("RLE row too large") }
                    for k in 0 ..< 4 { table[row * 4 + k] = UInt8(n >> (24 - 8 * k) & 0xFF) }
                }
            }
        }
        return table + body
    }

    // MARK: Validation

    /// Checks encoded sizes (and for ZIP the whole stream and its checksum) without keeping the
    /// output. ZIP streams declaring more than `maxDecodedBytes` are not inflated (photocraft #2926):
    /// decoding refuses that layout anyway, so the bytes are kept like an unknown method.
    static func validate(_ compression: PSDCompression, _ src: UnsafeRawBufferPointer, layout: PlaneLayout) throws {
        let total = try layout.totalBytes()
        switch compression {
        case .raw:
            if UInt64(src.count) < total {
                throw PSDError.unexpectedEOF(offset: src.count, needed: Int(clamping: total - UInt64(src.count)))
            }
        case .rle:
            let rows = try layout.rows()
            var r = ByteReader(src)
            try r.checkCount(UInt64(rows), minItemSize: UInt64(layout.countSize))
            var sum: UInt64 = 0
            for _ in 0 ..< rows { sum += layout.version.isPSB ? UInt64(try r.u32()) : UInt64(try r.u16()) }
            if sum > UInt64(r.remaining) {
                throw PSDError.unexpectedEOF(offset: src.count, needed: Int(clamping: sum - UInt64(r.remaining)))
            }
        case .zip, .zipPrediction:
            if total > PSDLimits.maxDecodedBytes { return }
            _ = try Zlib.inflate(src, expected: Int(total), keep: false)
        case .unknown:
            return
        }
    }

    // MARK: Prediction

    /// Applies horizontal delta prediction in place (encoder side): 1/8-bit byte deltas, 16-bit
    /// big-endian sample deltas, 32-bit rows split into four byte planes (most significant first)
    /// then byte-delta coded, as Photoshop does.
    public static func predict(_ buf: inout [UInt8], layout: PlaneLayout) throws {
        let rb = layout.rowBytes
        guard rb > 0 else { return }
        let w = layout.width
        guard [1, 8, 16, 32].contains(layout.depth) else { throw PSDError.unsupported("prediction for depth \(layout.depth)") }
        var scratch = [UInt8](repeating: 0, count: layout.depth == 32 ? rb : 0)
        buf.withUnsafeMutableBytes { all in
            let rows = all.count / rb
            for r in 0 ..< rows {
                let row = UnsafeMutableRawBufferPointer(rebasing: all[r * rb ..< (r + 1) * rb])
                switch layout.depth {
                case 16:
                    var i = w - 1
                    while i >= 1 {
                        let a = UInt16(row[2 * i]) << 8 | UInt16(row[2 * i + 1])
                        let b = UInt16(row[2 * i - 2]) << 8 | UInt16(row[2 * i - 1])
                        let d = a &- b
                        row[2 * i] = UInt8(d >> 8)
                        row[2 * i + 1] = UInt8(d & 0xFF)
                        i -= 1
                    }
                case 32:
                    for i in 0 ..< w { for k in 0 ..< 4 { scratch[k * w + i] = row[4 * i + k] } }
                    var i = rb - 1
                    while i >= 1 {
                        scratch[i] = scratch[i] &- scratch[i - 1]
                        i -= 1
                    }
                    for i in 0 ..< rb { row[i] = scratch[i] }
                default:
                    var i = rb - 1
                    while i >= 1 {
                        row[i] = row[i] &- row[i - 1]
                        i -= 1
                    }
                }
            }
        }
    }

    /// Reverses `predict` in place (decoder side).
    public static func unpredict(_ buf: inout [UInt8], layout: PlaneLayout) throws {
        let rb = layout.rowBytes
        guard rb > 0 else { return }
        let w = layout.width
        guard [1, 8, 16, 32].contains(layout.depth) else { throw PSDError.unsupported("prediction for depth \(layout.depth)") }
        var scratch = [UInt8](repeating: 0, count: layout.depth == 32 ? rb : 0)
        buf.withUnsafeMutableBytes { all in
            let rows = all.count / rb
            for r in 0 ..< rows {
                let row = UnsafeMutableRawBufferPointer(rebasing: all[r * rb ..< (r + 1) * rb])
                switch layout.depth {
                case 16:
                    if w > 1 {
                        for i in 1 ..< w {
                            let a = UInt16(row[2 * i]) << 8 | UInt16(row[2 * i + 1])
                            let b = UInt16(row[2 * i - 2]) << 8 | UInt16(row[2 * i - 1])
                            let s = a &+ b
                            row[2 * i] = UInt8(s >> 8)
                            row[2 * i + 1] = UInt8(s & 0xFF)
                        }
                    }
                case 32:
                    if rb > 1 { for i in 1 ..< rb { row[i] = row[i] &+ row[i - 1] } }
                    for i in 0 ..< rb { scratch[i] = row[i] }
                    for i in 0 ..< w { for k in 0 ..< 4 { row[4 * i + k] = scratch[k * w + i] } }
                default:
                    if rb > 1 { for i in 1 ..< rb { row[i] = row[i] &+ row[i - 1] } }
                }
            }
        }
    }
}

/// Wraps a value (raw buffers) handed to concurrent workers that touch disjoint parts of it.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Collects the first error thrown by concurrent workers.
final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    var error: Error? { lock.withLock { stored } }
    func set(_ e: Error) { lock.withLock { if stored == nil { stored = e } } }
}
