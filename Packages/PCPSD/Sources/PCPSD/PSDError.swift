// Error type for every fallible operation of the package, and the four-character code type used
// for signatures and keys.
// Port of photocraft-psd (crates/psd/src/error.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

/// Errors produced while parsing, decoding, encoding or writing PSD/PSB data. Parsers never trap
/// on malformed input; every failure is reported through this type.
public enum PSDError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The input ended before a structure was complete.
    case unexpectedEOF(offset: Int, needed: Int)
    /// A four-byte signature did not match.
    case invalidSignature(expected: String, found: FourCC)
    /// Header version is neither 1 (PSD) nor 2 (PSB).
    case unsupportedVersion(UInt16)
    /// A dimension, count or allocation exceeded the safety limits.
    case limitExceeded(String)
    /// Structurally invalid data.
    case invalid(String)
    /// A compressed stream could not be decoded.
    case decompress(String)
    /// An operation is not supported for this data (e.g. an unknown compression method).
    case unsupported(String)

    public var description: String {
        switch self {
        case let .unexpectedEOF(offset, needed):
            "unexpected end of data at offset \(offset) (needed \(needed) more bytes)"
        case let .invalidSignature(expected, found):
            "invalid signature \(found), expected \(expected)"
        case let .unsupportedVersion(v): "unsupported file version \(v)"
        case let .limitExceeded(m): "limit exceeded: \(m)"
        case let .invalid(m): "invalid data: \(m)"
        case let .decompress(m): "decompression failed: \(m)"
        case let .unsupported(m): "unsupported: \(m)"
        }
    }
}

/// A four-byte code as stored in the file: signatures (`8BIM`), tagged block keys (`luni`), blend
/// mode keys (`mul `), descriptor OSTypes and unit codes. Compare with string literals:
/// `block.key == "luni"`.
public struct FourCC: Hashable, Sendable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    /// The four bytes, big-endian (first byte most significant).
    public var rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// From four bytes; missing bytes are spaces, extra bytes ignored.
    public init(bytes: some Sequence<UInt8>) {
        var v: UInt32 = 0
        var n = 0
        for b in bytes.prefix(4) {
            v = v << 8 | UInt32(b)
            n += 1
        }
        while n < 4 {
            v = v << 8 | 0x20
            n += 1
        }
        rawValue = v
    }

    /// From an ASCII string such as `"8BIM"`; shorter strings are space padded.
    public init(_ string: String) { self.init(bytes: Array(string.utf8)) }
    public init(stringLiteral value: String) { self.init(value) }

    public var bytes: [UInt8] {
        [UInt8(rawValue >> 24), UInt8(rawValue >> 16 & 0xFF), UInt8(rawValue >> 8 & 0xFF), UInt8(rawValue & 0xFF)]
    }

    /// Printable form (non-ASCII bytes as `?`).
    public var string: String {
        String(decoding: bytes.map { $0 >= 0x20 && $0 < 0x7F ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
    }

    public var description: String { string }
    public static func < (a: FourCC, b: FourCC) -> Bool { a.rawValue < b.rawValue }
}
