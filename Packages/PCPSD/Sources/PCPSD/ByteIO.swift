// Bounds-checked big-endian reader over raw buffers, an in-memory writer with length back-patching,
// and the output sinks the file writer streams into.
// Port of photocraft-psd (crates/psd/src/io.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. Native substitution: reads go through `UnsafeRawBufferPointer`
// (`loadUnaligned`) instead of slice indexing, and stored payloads are zero-copy `Data` slices of
// the file buffer (so a memory-mapped PSB is never copied on open).

import Foundation

/// Bounds-checked cursor over a byte buffer. Integers are big-endian. Every read throws
/// `PSDError.unexpectedEOF` instead of trapping.
struct ByteReader {
    let buf: UnsafeRawBufferPointer
    /// The `Data` whose bytes `buf` points into, for zero-copy slicing; `nil` copies instead.
    let owner: Data?
    /// Offset of `buf[0]` from `owner.startIndex`.
    let ownerOffset: Int
    private(set) var pos: Int = 0

    init(_ buf: UnsafeRawBufferPointer, owner: Data? = nil, ownerOffset: Int = 0) {
        self.buf = buf
        self.owner = owner
        self.ownerOffset = ownerOffset
    }

    var count: Int { buf.count }
    var remaining: Int { buf.count - pos }
    var isAtEnd: Bool { pos >= buf.count }

    @inline(__always)
    private func need(_ n: Int) throws {
        guard n >= 0 else { throw PSDError.invalid("negative length") }
        if n > remaining { throw PSDError.unexpectedEOF(offset: pos, needed: n - remaining) }
    }

    /// The next `n` bytes as a raw buffer (valid as long as `buf`).
    mutating func raw(_ n: Int) throws -> UnsafeRawBufferPointer {
        try need(n)
        let s = UnsafeRawBufferPointer(rebasing: buf[pos ..< pos + n])
        pos += n
        return s
    }

    /// The next `n` bytes as `Data`: a zero-copy slice of the owner when there is one.
    mutating func data(_ n: Int) throws -> Data {
        try need(n)
        defer { pos += n }
        if let owner {
            let start = owner.startIndex + ownerOffset + pos
            return owner[start ..< start + n]
        }
        return Data(UnsafeRawBufferPointer(rebasing: buf[pos ..< pos + n]))
    }

    /// `data(_:)` for a 64-bit length field.
    mutating func data(u64 n: UInt64) throws -> Data {
        guard n <= UInt64(Int.max) else { throw PSDError.limitExceeded("length exceeds address space") }
        return try data(Int(n))
    }

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        Array(try raw(n))
    }

    mutating func skip(_ n: Int) throws {
        try need(n)
        pos += n
    }

    /// A reader over the next `n` bytes (sharing the owner for slicing).
    mutating func sub(_ n: Int) throws -> ByteReader {
        try need(n)
        let r = ByteReader(UnsafeRawBufferPointer(rebasing: buf[pos ..< pos + n]), owner: owner, ownerOffset: ownerOffset + pos)
        pos += n
        return r
    }

    mutating func sub(u64 n: UInt64) throws -> ByteReader {
        guard n <= UInt64(Int.max) else { throw PSDError.limitExceeded("length exceeds address space") }
        return try sub(Int(n))
    }

    /// The unread bytes, without consuming them.
    var rest: UnsafeRawBufferPointer { UnsafeRawBufferPointer(rebasing: buf[pos...]) }

    func peekU8(at offset: Int = 0) -> UInt8? {
        let i = pos + offset
        return i >= 0 && i < buf.count ? buf[i] : nil
    }

    @inline(__always) mutating func u8() throws -> UInt8 {
        try need(1)
        defer { pos += 1 }
        return buf[pos]
    }

    @inline(__always) mutating func u16() throws -> UInt16 {
        try need(2)
        defer { pos += 2 }
        return UInt16(bigEndian: buf.loadUnaligned(fromByteOffset: pos, as: UInt16.self))
    }

    @inline(__always) mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

    @inline(__always) mutating func u32() throws -> UInt32 {
        try need(4)
        defer { pos += 4 }
        return UInt32(bigEndian: buf.loadUnaligned(fromByteOffset: pos, as: UInt32.self))
    }

    @inline(__always) mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    @inline(__always) mutating func u64() throws -> UInt64 {
        try need(8)
        defer { pos += 8 }
        return UInt64(bigEndian: buf.loadUnaligned(fromByteOffset: pos, as: UInt64.self))
    }

    mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

    mutating func fourCC() throws -> FourCC { FourCC(rawValue: try u32()) }

    /// A length field that is 4 bytes, or 8 when `long`.
    mutating func lengthField(long: Bool) throws -> UInt64 {
        long ? try u64() : UInt64(try u32())
    }

    /// Fails unless `count × minItemSize` bytes remain: validates file-declared counts before any
    /// allocation is sized from them.
    func checkCount(_ count: UInt64, minItemSize: UInt64) throws {
        let (need, overflow) = count.multipliedReportingOverflow(by: minItemSize)
        if overflow || need > UInt64(remaining) {
            let missing = overflow ? UInt64(Int.max) : need - UInt64(remaining)
            throw PSDError.unexpectedEOF(offset: pos, needed: Int(clamping: missing))
        }
    }

    /// Pascal string (length byte + bytes) whose total size is padded to a multiple of `align`.
    mutating func pascal(align: Int) throws -> [UInt8] {
        let n = Int(try u8())
        let name = try bytes(n)
        let total = 1 + n
        try skip((align - total % align) % align)
        return name
    }

    /// Photoshop Unicode string: u32 code-unit count + UTF-16BE units.
    mutating func unicodeUnits() throws -> [UInt16] {
        let n = UInt64(try u32())
        try checkCount(n, minItemSize: 2)
        var v = [UInt16]()
        v.reserveCapacity(Int(n))
        for _ in 0 ..< n { v.append(try u16()) }
        return v
    }
}

extension Data {
    /// Runs `body` with a reader over the bytes; slices taken from it share this `Data`'s storage.
    @discardableResult
    func withByteReader<T>(_ body: (inout ByteReader) throws -> T) throws -> T {
        try withUnsafeBytes { raw in
            var r = ByteReader(raw, owner: self, ownerOffset: 0)
            return try body(&r)
        }
    }

    /// The bytes as an array (for small payloads).
    var byteArray: [UInt8] { [UInt8](self) }
}

extension Array where Element == UInt8 {
    @discardableResult
    func withByteReader<T>(_ body: (inout ByteReader) throws -> T) throws -> T {
        try withUnsafeBytes { raw in
            var r = ByteReader(raw)
            return try body(&r)
        }
    }
}

// MARK: - In-memory writer

/// Big-endian writer into a growable byte array, with length back-patching. Used for block payloads
/// and other small structures; the file writer streams into a `ByteSink` instead.
struct ByteWriter {
    var bytes: [UInt8] = []

    init(capacity: Int = 0) { bytes.reserveCapacity(capacity) }

    var count: Int { bytes.count }
    var data: Data { Data(bytes) }

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v >> 8)); bytes.append(UInt8(v & 0xFF)) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(v >> 24)); bytes.append(UInt8(v >> 16 & 0xFF))
        bytes.append(UInt8(v >> 8 & 0xFF)); bytes.append(UInt8(v & 0xFF))
    }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xFFFF_FFFF)) }
    mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func fourCC(_ c: FourCC) { u32(c.rawValue) }
    mutating func put(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    mutating func put(_ d: Data) { bytes.append(contentsOf: d) }
    mutating func put(_ r: UnsafeRawBufferPointer) { bytes.append(contentsOf: r) }
    mutating func zeros(_ n: Int) { if n > 0 { bytes.append(contentsOf: repeatElement(0, count: n)) } }

    mutating func length(_ v: UInt64, long: Bool) throws {
        if long {
            u64(v)
        } else {
            guard v <= UInt64(UInt32.max) else { throw PSDError.limitExceeded("section too large for a 32-bit length (use PSB)") }
            u32(UInt32(v))
        }
    }

    /// Reserves a length placeholder and returns its position.
    mutating func beginLength(long: Bool) -> Int {
        let at = bytes.count
        zeros(long ? 8 : 4)
        return at
    }

    /// Back-patches a placeholder with the number of bytes written since it.
    mutating func endLength(_ at: Int, long: Bool) throws {
        let header = long ? 8 : 4
        let n = UInt64(bytes.count - at - header)
        if long {
            for i in 0 ..< 8 { bytes[at + i] = UInt8(n >> (56 - 8 * UInt64(i)) & 0xFF) }
        } else {
            guard n <= UInt64(UInt32.max) else { throw PSDError.limitExceeded("section too large for a 32-bit length (use PSB)") }
            for i in 0 ..< 4 { bytes[at + i] = UInt8(n >> (24 - 8 * UInt64(i)) & 0xFF) }
        }
    }

    /// Pascal string padded so length byte + text is a multiple of `align`; pad bytes are zero.
    mutating func pascal(_ name: [UInt8], align: Int) {
        let n = min(name.count, 255)
        u8(UInt8(n))
        put(Array(name.prefix(n)))
        zeros((align - (1 + n) % align) % align)
    }

    mutating func unicodeUnits(_ units: [UInt16]) {
        u32(UInt32(units.count))
        for u in units { u16(u) }
    }
}

// MARK: - Sinks (file writer output)

/// Destination of the file writer. The writer measures sections with `CountingSink` before writing
/// their length fields, so no output has to be back-patched and a PSB can stream to disk.
public protocol ByteSink {
    /// Bytes written so far.
    var written: Int { get }
    mutating func write(_ raw: UnsafeRawBufferPointer) throws
    mutating func write(_ data: Data) throws
}

extension ByteSink {
    mutating func write(_ bytes: [UInt8]) throws { try bytes.withUnsafeBytes { try write($0) } }
    mutating func u8(_ v: UInt8) throws { try withUnsafeBytes(of: v) { try write($0) } }
    mutating func u16(_ v: UInt16) throws { try withUnsafeBytes(of: v.bigEndian) { try write($0) } }
    mutating func i16(_ v: Int16) throws { try u16(UInt16(bitPattern: v)) }
    mutating func u32(_ v: UInt32) throws { try withUnsafeBytes(of: v.bigEndian) { try write($0) } }
    mutating func i32(_ v: Int32) throws { try u32(UInt32(bitPattern: v)) }
    mutating func u64(_ v: UInt64) throws { try withUnsafeBytes(of: v.bigEndian) { try write($0) } }
    mutating func fourCC(_ c: FourCC) throws { try u32(c.rawValue) }
    mutating func zeros(_ n: Int) throws {
        guard n > 0 else { return }
        let z = [UInt8](repeating: 0, count: min(n, 65536))
        var left = n
        while left > 0 {
            let k = min(left, z.count)
            try z.withUnsafeBytes { try write(UnsafeRawBufferPointer(rebasing: $0[0 ..< k])) }
            left -= k
        }
    }

    mutating func length(_ v: UInt64, long: Bool) throws {
        if long {
            try u64(v)
        } else {
            guard v <= UInt64(UInt32.max) else { throw PSDError.limitExceeded("section too large for a 32-bit length (use PSB)") }
            try u32(UInt32(v))
        }
    }
}

/// Counts bytes without storing them (used to size length fields).
public struct CountingSink: ByteSink {
    public private(set) var written = 0
    public init() {}
    public mutating func write(_ raw: UnsafeRawBufferPointer) throws { written += raw.count }
    public mutating func write(_ data: Data) throws { written += data.count }
}

/// Collects the output in memory.
public struct MemorySink: ByteSink {
    public private(set) var data = Data()
    public init(capacity: Int = 0) { data.reserveCapacity(capacity) }
    public var written: Int { data.count }
    public mutating func write(_ raw: UnsafeRawBufferPointer) throws { data.append(contentsOf: raw) }
    public mutating func write(_ d: Data) throws { data.append(d) }
}

/// Streams the output to a file through a 4 MiB buffer (large PSBs never sit in memory twice).
public final class FileSink: ByteSink {
    private let handle: FileHandle
    private var buffer = Data()
    private let chunk = 4 << 20
    public private(set) var written = 0

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        buffer.reserveCapacity(chunk)
    }

    public func write(_ raw: UnsafeRawBufferPointer) throws {
        written += raw.count
        if raw.count >= chunk {
            try flush()
            try handle.write(contentsOf: Data(raw))
            return
        }
        buffer.append(contentsOf: raw)
        if buffer.count >= chunk { try flush() }
    }

    public func write(_ d: Data) throws {
        if d.count >= chunk {
            written += d.count
            try flush()
            try handle.write(contentsOf: d)
            return
        }
        try d.withUnsafeBytes { try write($0) }
    }

    public func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    public func close() throws {
        try flush()
        try handle.close()
    }
}

/// Size in bytes of what `body` writes.
func measure(_ body: (inout CountingSink) throws -> Void) rethrows -> Int {
    var c = CountingSink()
    try body(&c)
    return c.written
}

// MARK: - Names

/// Legacy (Pascal) names: UTF-8 when valid, otherwise Latin-1 (photocraft's rule).
/// Double → Int32, rounded and saturating; NaN → 0 (fixed-point fields never trap on bad input).
@inline(__always) func saturatingInt32(_ v: Double) -> Int32 {
    v.isNaN ? 0 : Int32(max(Double(Int32.min), min(Double(Int32.max), v.rounded())))
}

func decodeLegacyName(_ b: [UInt8]) -> String {
    if let s = String(validating: b, as: UTF8.self) { return s }
    return String(b.map { Character(Unicode.Scalar($0)) })
}

/// A legacy Pascal field: printable ASCII kept, everything else becomes `?`, at most 255 bytes.
func encodeLegacyName(_ s: String) -> [UInt8] {
    Array(s.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F ? UInt8($0.value) : UInt8(ascii: "?") }.prefix(255))
}

/// A name as UTF-16 code units, capped at `max` without splitting a surrogate pair.
func utf16Units(_ name: String, max: Int) -> [UInt16] {
    var units: [UInt16] = []
    for scalar in name.unicodeScalars {
        let enc = Array(String(scalar).utf16)
        if units.count + enc.count > max { break }
        units.append(contentsOf: enc)
    }
    return units
}
