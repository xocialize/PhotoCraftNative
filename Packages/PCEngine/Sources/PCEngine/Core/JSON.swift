// Port of photocraft-engine (crates/engine/src/commands.rs param helpers over `serde_json::Value`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Command params and results are JSON (PCDocument's `JSONValue`, the port of `serde_json::Value`).
// These helpers read them with photocraft's leniency (an integer field accepts `12.0` from a UI
// slider; out-of-range ids are errors, never wrapped), and build results.

import Foundation
import PCDocument
import PCFoundation

extension JSONValue {
    // MARK: Reading

    /// An integer: a whole JSON number, or any finite number rounded (UIs send `12.0`;
    /// photocraft `int`).
    public var intValue: Int? {
        guard case .number(let n) = self, n.isFinite else { return nil }
        let r = n.rounded()
        guard r >= -9.2e18, r <= 9.2e18 else { return nil }
        return Int(r)
    }

    /// A non-negative whole number (photocraft `as_u64`: fractions and negatives are not ids).
    public var uint64Value: UInt64? {
        guard case .number(let n) = self, n.isFinite, n >= 0, n == n.rounded(), n < 1.8e19 else { return nil }
        return UInt64(n)
    }

    public var floatValue: Float? { doubleValue.map { Float($0) } }

    /// The members of an object (empty for anything else).
    public var members: [String: JSONValue] { objectValue ?? [:] }

    /// Whether this object has `key` (null counts as absent, like serde's `Option` fields).
    public func has(_ key: String) -> Bool {
        if let v = self[key], v != .null { return true }
        return false
    }

    /// This object with `key` set (non-objects become objects).
    public func setting(_ key: String, _ value: JSONValue) -> JSONValue {
        var o = objectValue ?? [:]
        o[key] = value
        return .object(o)
    }

    /// This object without `key`.
    public func removing(_ key: String) -> JSONValue {
        var o = objectValue ?? [:]
        o[key] = nil
        return .object(o)
    }

    /// This object with `other`'s members merged over it.
    public func merging(_ other: JSONValue) -> JSONValue {
        var o = objectValue ?? [:]
        for (k, v) in other.members { o[k] = v }
        return .object(o)
    }

    // MARK: Building

    public static func int(_ v: Int) -> JSONValue { .number(Double(v)) }
    public static func int<T: BinaryInteger>(_ v: T) -> JSONValue { .number(Double(v)) }
    public static func float(_ v: Float) -> JSONValue { .number(Double(v)) }
    public static func id(_ l: LayerId) -> JSONValue { .number(Double(l.rawValue)) }
    public static func ids(_ ls: [LayerId]) -> JSONValue { .array(ls.map { .id($0) }) }
    public static func optional(_ v: JSONValue?) -> JSONValue { v ?? .null }
    public static func strings(_ v: [String]) -> JSONValue { .array(v.map { .string($0) }) }
    public static func floats(_ v: [Float]) -> JSONValue { .array(v.map { .float($0) }) }
    public static func doubles(_ v: [Double]) -> JSONValue { .array(v.map { .number($0) }) }

    /// `[x, y, width, height]`, photocraft's JSON form of a rectangle.
    public static func rect(_ r: PixelRect) -> JSONValue { [.int(Int(r.x0)), .int(Int(r.y0)), .int(r.width), .int(r.height)] }

    /// `[r, g, b, a]` floats.
    public static func rgba(_ c: SIMD4<Float>) -> JSONValue { [.float(c.x), .float(c.y), .float(c.z), .float(c.w)] }

    /// The JSON form of any Encodable value (null when it can't be encoded).
    public static func encoded<T: Encodable>(_ v: T) -> JSONValue { (try? JSONValue(encoding: v)) ?? .null }

    // MARK: Text

    /// Parses JSON text.
    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try d.decode(JSONValue.self, from: data)
    }

    /// Serialized JSON: compact with sorted keys (serde_json's map order), or pretty.
    public func serialized(pretty: Bool = false) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let d = try? e.encode(self) else { return "null" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Byte size of the compact serialization (transport budgets).
    public var encodedSize: Int { serialized().utf8.count }
}

// MARK: - photocraft param helpers

/// Reading command params the way photocraft's `commands.rs` helpers do.
public enum Params {
    /// photocraft `int`: an integer field that also accepts JSON floats (rounded).
    public static func int(_ p: JSONValue, _ key: String) -> Int? { p[key]?.intValue }

    /// photocraft `int_i32`: nil when absent; a bad-params error when the value doesn't fit a
    /// 32-bit coordinate (wrapping would silently relocate geometry).
    public static func i32(_ cmd: String, _ p: JSONValue, _ key: String) throws(EngineError) -> Int32? {
        guard let v = p[key], v != .null else { return nil }
        guard let n = v.intValue else { throw .bad(cmd, "`\(key)` must be a number") }
        guard let r = Int32(exactly: n) else { throw .bad(cmd, "`\(key)` = \(n) is outside the 32-bit coordinate range") }
        return r
    }

    /// A required 32-bit coordinate.
    public static func requiredI32(_ cmd: String, _ p: JSONValue, _ key: String) throws(EngineError) -> Int32 {
        guard let v = try i32(cmd, p, key) else { throw .bad(cmd, "missing `\(key)`") }
        return v
    }

    /// photocraft `u32_id`: a whole number in `UInt32` range.
    public static func u32Id(_ cmd: String, _ key: String, _ v: JSONValue) throws(EngineError) -> UInt32 {
        guard let n = v.uint64Value, let r = UInt32(exactly: n) else {
            throw .bad(cmd, "`\(key)` = \(v.serialized()) is not a valid id (0..=\(UInt32.max))")
        }
        return r
    }

    /// `u32Id` of `p[key]`, nil when absent.
    public static func u32Id(_ cmd: String, _ p: JSONValue, _ key: String) throws(EngineError) -> UInt32? {
        guard let v = p[key], v != .null else { return nil }
        return try u32Id(cmd, key, v)
    }

    /// photocraft `f32_or`.
    public static func float(_ p: JSONValue, _ key: String, _ fallback: Float) -> Float { p[key]?.floatValue ?? fallback }
    public static func double(_ p: JSONValue, _ key: String, _ fallback: Double) -> Double { p[key]?.doubleValue ?? fallback }
    public static func bool(_ p: JSONValue, _ key: String, _ fallback: Bool) -> Bool { p[key]?.boolValue ?? fallback }
    public static func string(_ p: JSONValue, _ key: String) -> String? { p[key]?.stringValue }
    public static func string(_ p: JSONValue, _ key: String, _ fallback: String) -> String { p[key]?.stringValue ?? fallback }

    /// A required string.
    public static func requiredString(_ cmd: String, _ p: JSONValue, _ key: String) throws(EngineError) -> String {
        guard let s = p[key]?.stringValue else { throw .bad(cmd, "missing `\(key)`") }
        return s
    }

    /// photocraft `color_param`: `[r,g,b(,a)]` floats 0…1 or `"#rrggbb(aa)"`, else `fallback`.
    public static func color(_ p: JSONValue, _ key: String, _ fallback: SIMD4<Float>) -> SIMD4<Float> {
        guard let v = p[key] else { return fallback }
        return color(v) ?? fallback
    }

    /// A colour value, or nil when it isn't one.
    public static func color(_ v: JSONValue) -> SIMD4<Float>? {
        switch v {
        case .array(let a) where a.count >= 3:
            let f = a.map { Float($0.doubleValue ?? 0) }
            return SIMD4(f[0], f[1], f[2], f.count > 3 ? f[3] : 1)
        case .string(let s):
            return parseHex(s)
        default:
            return nil
        }
    }

    /// photocraft `parse_hex`: `#rrggbb` or `#rrggbbaa`.
    public static func parseHex(_ s: String) -> SIMD4<Float>? {
        let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
        let b = Array(h.utf8)
        func byte(_ i: Int) -> Float? {
            guard i + 2 <= b.count, let v = UInt8(String(decoding: b[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            return Float(v) / 255
        }
        switch b.count {
        case 6:
            guard let r = byte(0), let g = byte(2), let bl = byte(4) else { return nil }
            return SIMD4(r, g, bl, 1)
        case 8:
            guard let r = byte(0), let g = byte(2), let bl = byte(4), let a = byte(6) else { return nil }
            return SIMD4(r, g, bl, a)
        default:
            return nil
        }
    }

    /// `#rrggbb` of a colour.
    public static func hex(_ c: SIMD4<Float>) -> String {
        func q(_ v: Float) -> Int { Int(min(max(v, 0), 1) * 255 + 0.5) }
        return String(format: "#%02x%02x%02x", q(c.x), q(c.y), q(c.z))
    }

    /// photocraft `blend_from_str`: a blend mode by label or variant name, ignoring case, spaces,
    /// underscores, hyphens and parentheses.
    public static func blendMode(_ s: String) -> BlendMode? {
        func norm(_ x: String) -> String {
            String(x.lowercased().unicodeScalars.filter { !" _-()".unicodeScalars.contains($0) })
        }
        let want = norm(s)
        return ([BlendMode.passThrough] + BlendMode.allLayerModes).first { norm($0.label) == want || norm("\($0)") == want }
    }

    /// A layer id param (`"layer"` by default).
    public static func layerId(_ p: JSONValue, _ key: String = "layer") -> LayerId? { p[key]?.uint64Value.map { LayerId($0) } }

    /// A list of layer ids (`"layers"`).
    public static func layerIds(_ p: JSONValue, _ key: String = "layers") -> [LayerId]? {
        p[key]?.arrayValue.map { $0.compactMap { $0.uint64Value.map { LayerId($0) } } }
    }

    /// `[x, y]` as a point.
    public static func point(_ v: JSONValue?) -> SIMD2<Double>? {
        guard let a = v?.arrayValue, a.count >= 2, let x = a[0].doubleValue, let y = a[1].doubleValue else { return nil }
        return SIMD2(x, y)
    }

    /// `[x, y, w, h]` as a rectangle.
    public static func rect(_ v: JSONValue?) -> PixelRect? {
        guard let a = v?.arrayValue, a.count >= 4 else { return nil }
        let n = a.prefix(4).compactMap(\.intValue)
        guard n.count == 4 else { return nil }
        return PixelRect(x: n[0], y: n[1], width: max(n[2], 0), height: max(n[3], 0))
    }
}
