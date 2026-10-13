// Big-endian byte reading and writing for the PSD block mappings (PCPSD keeps its own reader
// internal). Every read is bounds-checked and throws instead of trapping.
// Port support for photocraft-io (crates/io/src/*_map.rs, which read with slices and
// `from_be_bytes`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCPSD

/// A cursor over big-endian bytes.
public struct BEReader: Sendable {
    public let bytes: [UInt8]
    public private(set) var pos: Int

    public init(_ bytes: [UInt8], at pos: Int = 0) {
        self.bytes = bytes
        self.pos = max(0, pos)
    }

    public var remaining: Int { max(0, bytes.count - pos) }
    public var isAtEnd: Bool { pos >= bytes.count }
    public var rest: [UInt8] { pos < bytes.count ? Array(bytes[pos...]) : [] }

    private mutating func need(_ n: Int) throws {
        guard n >= 0, n <= remaining else { throw PCIOError.corrupt("unexpected end of data at offset \(pos) (needed \(n) bytes)") }
    }

    public mutating func u8() throws -> UInt8 {
        try need(1)
        defer { pos += 1 }
        return bytes[pos]
    }

    public mutating func u16() throws -> UInt16 {
        try need(2)
        defer { pos += 2 }
        return UInt16(bytes[pos]) << 8 | UInt16(bytes[pos + 1])
    }

    public mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

    public mutating func u32() throws -> UInt32 {
        try need(4)
        defer { pos += 4 }
        return UInt32(bytes[pos]) << 24 | UInt32(bytes[pos + 1]) << 16 | UInt32(bytes[pos + 2]) << 8 | UInt32(bytes[pos + 3])
    }

    public mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    public mutating func u64() throws -> UInt64 { UInt64(try u32()) << 32 | UInt64(try u32()) }

    public mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }

    public mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

    public mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

    public mutating func bytes(_ n: Int) throws -> [UInt8] {
        try need(n)
        defer { pos += n }
        return Array(bytes[pos ..< pos + n])
    }

    public mutating func skip(_ n: Int) throws {
        try need(n)
        pos += n
    }

    public mutating func fourCC() throws -> FourCC { FourCC(bytes: try bytes(4)) }

    /// A Photoshop Unicode string: u32 count of UTF-16 code units, then the units.
    public mutating func unicodeUnits() throws -> [UInt16] {
        let n = Int(try u32())
        try need(n.multipliedReportingOverflow(by: 2).overflow ? Int.max : n * 2)
        var out = [UInt16]()
        out.reserveCapacity(n)
        for _ in 0 ..< n { out.append(try u16()) }
        return out
    }

    /// `unicodeUnits` as a string with trailing NULs dropped.
    public mutating func unicodeString() throws -> String { PSDUnicodeString(units: try unicodeUnits()).string }

    /// A Pascal string (length byte + bytes), the total padded to a multiple of `align`.
    public mutating func pascal(align: Int = 1) throws -> [UInt8] {
        let n = Int(try u8())
        let s = try bytes(n)
        let total = n + 1
        let pad = align > 1 ? (align - total % align) % align : 0
        try skip(min(pad, remaining))
        return s
    }
}

/// Big-endian byte writer.
public struct BEWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public var count: Int { bytes.count }

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(v & 0xFF)] }
    public mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    public mutating func u32(_ v: UInt32) { bytes += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    public mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    public mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xFFFF_FFFF)) }
    public mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func f64(_ v: Double) { u64(v.bitPattern) }
    public mutating func put(_ b: [UInt8]) { bytes += b }
    public mutating func put(_ d: Data) { bytes += [UInt8](d) }
    public mutating func fourCC(_ c: FourCC) { u32(c.rawValue) }
    public mutating func zeros(_ n: Int) { if n > 0 { bytes += [UInt8](repeating: 0, count: n) } }

    /// u32 count of UTF-16 units, then the units (Photoshop Unicode string).
    public mutating func unicodeUnits(_ units: [UInt16]) {
        u32(UInt32(units.count))
        for u in units { u16(u) }
    }

    /// A Pascal string padded so the total (length byte included) is a multiple of `align`.
    public mutating func pascal(_ s: [UInt8], align: Int = 1) {
        let b = Array(s.prefix(255))
        u8(UInt8(b.count))
        put(b)
        let total = b.count + 1
        if align > 1 { zeros((align - total % align) % align) }
    }
}

// MARK: - Saturating float → integer casts (Rust's `as`)

/// Rust's saturating `f as T`: NaN → 0, out-of-range values clamp to the type's bounds.
@inline(__always) public func satCast<T: FixedWidthInteger>(_ v: Double) -> T {
    if v.isNaN { return 0 }
    if v <= Double(T.min) { return T.min }
    if v >= Double(T.max) { return T.max }
    return T(v.rounded(.towardZero))
}

/// `satCast` for Float input.
@inline(__always) public func satCast<T: FixedWidthInteger>(_ v: Float) -> T { satCast(Double(v)) }

/// Rust's `f.round() as T` (round half away from zero, then saturate).
@inline(__always) public func roundCast<T: FixedWidthInteger>(_ v: Double) -> T { satCast(v.rounded(.toNearestOrAwayFromZero)) }

@inline(__always) public func roundCast<T: FixedWidthInteger>(_ v: Float) -> T { satCast(Double(v.rounded(.toNearestOrAwayFromZero))) }

// MARK: - Keys

extension FourCC {
    /// The PCDocument form of this key.
    public var psdKey: PSDKey {
        let b = bytes
        return PSDKey(b[0], b[1], b[2], b[3])
    }

    /// From PCDocument's key form.
    public init(_ key: PSDKey) { self.init(bytes: key.array) }
}
