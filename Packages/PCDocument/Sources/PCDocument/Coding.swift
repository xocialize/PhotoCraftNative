// Codable plumbing that reproduces serde's JSON shapes, so a document fragment written by
// photocraft (serde_json) decodes here and the other way round: externally tagged enums
// (`"Unit"` / `{"Variant": payload}`), serde's field defaults, fixed-size arrays and tuples
// (encoded as JSON arrays), and `serde_json::Value`.
// Port support for photocraft-doc (crates/doc/src/*.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.

import Foundation

/// A coding key built from any string (enum tags, free-form maps).
struct TagKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// One decoded variant of an externally tagged enum: its tag and, for non-unit variants, the
/// container holding its payload under that tag.
struct TaggedVariant {
    let tag: String
    let container: KeyedDecodingContainer<TagKey>?
    let codingPath: [any CodingKey]

    /// Opens serde's externally tagged form: a bare string for a unit variant, else a one-key
    /// object `{tag: payload}`.
    init(from decoder: any Decoder) throws {
        codingPath = decoder.codingPath
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            tag = s
            container = nil
            return
        }
        let c = try decoder.container(keyedBy: TagKey.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "expected a one-key object naming the variant, got keys \(c.allKeys.map(\.stringValue))"))
        }
        tag = key.stringValue
        container = c
    }

    /// The payload of a non-unit variant.
    func payload<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        guard let container else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "variant \(tag) needs a payload"))
        }
        return try container.decode(T.self, forKey: TagKey(tag))
    }

    func unknown() -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "unknown variant \(tag)"))
    }
}

/// Encoders for serde's externally tagged form.
enum Tagged {
    static func unit(_ tag: String, to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(tag)
    }

    static func variant<T: Encodable>(_ tag: String, _ payload: T, to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: TagKey.self)
        try c.encode(payload, forKey: TagKey(tag))
    }
}

extension KeyedDecodingContainer {
    /// serde's `#[serde(default)]`: a missing (or null) key takes `fallback`.
    func decode<T: Decodable>(_ key: Key, or fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }

    /// A Rust fixed-size array (`[T; n]`): exactly `count` elements.
    func decodeFixed<T: Decodable>(_ type: [T].Type, forKey key: Key, count: Int) throws -> [T] {
        let v = try decode([T].self, forKey: key)
        guard v.count == count else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "expected \(count) elements, got \(v.count)")
        }
        return v
    }
}

// MARK: - serde_json::Value

/// A JSON value (`serde_json::Value`): smart-filter parameters, text-style attribute sets and other
/// schema-free data. Numbers are Doubles, as JSON has only one number type.
public enum JSONValue: Hashable, Sendable, Codable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        if let c = try? decoder.singleValueContainer() {
            if c.decodeNil() { self = .null; return }
            if let b = try? c.decode(Bool.self) { self = .bool(b); return }
            // Strings before numbers: the shared decoder reads "nan"/"inf" strings as floats.
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let n = try? c.decode(Double.self) { self = .number(n); return }
        }
        if var u = try? decoder.unkeyedContainer() {
            var out: [JSONValue] = []
            while !u.isAtEnd { out.append(try u.decode(JSONValue.self)) }
            self = .array(out)
            return
        }
        let k = try decoder.container(keyedBy: TagKey.self)
        var out: [String: JSONValue] = [:]
        for key in k.allKeys { out[key.stringValue] = try k.decode(JSONValue.self, forKey: key) }
        self = .object(out)
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer(); try c.encodeNil()
        case .bool(let b):
            var c = encoder.singleValueContainer(); try c.encode(b)
        case .number(let n):
            var c = encoder.singleValueContainer(); try c.encode(n)
        case .string(let s):
            var c = encoder.singleValueContainer(); try c.encode(s)
        case .array(let a):
            var c = encoder.unkeyedContainer()
            for v in a { try c.encode(v) }
        case .object(let o):
            var c = encoder.container(keyedBy: TagKey.self)
            for (k, v) in o { try c.encode(v, forKey: TagKey(k)) }
        }
    }

    /// The JSON form of any Encodable value (through `JSONEncoder`).
    public init<T: Encodable>(encoding value: T) throws {
        let data = try JSONValue.encoder.encode(value)
        self = try JSONValue.decoder.decode(JSONValue.self, from: data)
    }

    /// Decodes this JSON as `T` (through `JSONDecoder`).
    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        let data = try JSONValue.encoder.encode(self)
        return try JSONValue.decoder.decode(T.self, from: data)
    }

    /// Serialized JSON text (sorted keys).
    public var jsonString: String {
        guard let d = try? JSONValue.encoder.encode(self) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }

    public var description: String { jsonString }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var doubleValue: Double? { if case .number(let n) = self { n } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var isNull: Bool { self == .null }

    /// Shared coders: sorted keys for stable text; non-finite floats as strings so any model
    /// value converts.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }()
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
}

// MARK: - Raw byte keys

/// A four-byte PSD key or signature (`b"vmsk"`, `8BIM`), kept as bytes because PSD keys are
/// not guaranteed to be ASCII.
public struct PSDKey: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var bytes: SIMD4<UInt8>

    public init(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) { bytes = SIMD4(b0, b1, b2, b3) }

    /// The first four UTF-8 bytes of `s`, zero-padded.
    public init(_ s: String) {
        let u = Array(s.utf8)
        func at(_ i: Int) -> UInt8 { i < u.count ? u[i] : 0 }
        self.init(at(0), at(1), at(2), at(3))
    }

    public init(stringLiteral value: String) { self.init(value) }

    public var array: [UInt8] { [bytes[0], bytes[1], bytes[2], bytes[3]] }
    public var description: String { String(decoding: array, as: UTF8.self) }
}
