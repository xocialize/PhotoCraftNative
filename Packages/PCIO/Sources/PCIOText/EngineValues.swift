// EngineData access with photocraft's semantics, and photocraft's EngineData writer.
// Port of photocraft-text (crates/text/src/engine_data.rs: `Value::{get, path, set, as_*}`,
// `write`, `write_bare`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Parsing is PCPSD's (`PSDEngineData.parse`/`parseBare`). The accessors here follow photocraft
// exactly where PCPSD's convenience accessors differ: paths follow dictionary keys only (PCPSD's
// `path` also indexes arrays), `as_i64` saturates reals like Rust's `as` (PCPSD's `int` is nil
// out of range), and keys and strings compare by bytes (Swift's `==` is canonical equivalence).
//
// `EngineWriter` reproduces photocraft's `engine_data::write` byte for byte, which differs from
// PCPSD's `serialized()` (Photoshop's own layout): photocraft puts an array that holds containers
// on the line after its key (`/RunArray\n\t\t[`), PCPSD keeps it on the key's line
// (`/RunArray [`); and photocraft ends the document with a newline, PCPSD doesn't. PCIOText writes
// Photoshop's layout by default; this writer is `PSDText.EngineDataLayout.photocraft`.

import PCPSD

typealias E = PSDEngineData

// MARK: - Small helpers (Rust semantics)

/// Byte equality of two strings (Rust `==` on `str`).
@inline(__always) func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

@inline(__always) func same(_ a: String?, _ b: String) -> Bool { a.map { same($0, b) } ?? false }

/// Rust's saturating float → integer `as` cast (NaN → 0).
@inline(__always) func sat<T: FixedWidthInteger>(_ v: Double) -> T {
    if v.isNaN { return 0 }
    if v >= Double(T.max) { return .max }
    if v <= Double(T.min) { return .min }
    return T(v)
}

@inline(__always) func sat<T: FixedWidthInteger>(_ v: Float) -> T { sat(Double(v)) }

/// Rust `i64 as usize` for an index: a negative value wraps to a huge index that matches nothing.
@inline(__always) func usizeIndex(_ i: Int64) -> Int { i < 0 ? Int.max : Int(i) }

/// Rust `usize::saturating_add`.
@inline(__always) func satAdd(_ a: Int, _ b: Int) -> Int {
    let (s, o) = a.addingReportingOverflow(b)
    return o ? (b > 0 ? Int.max : Int.min) : s
}

/// Rust `usize::checked_add` (nil on overflow).
@inline(__always) func checkedAdd(_ a: Int, _ b: Int) -> Int? {
    let (s, o) = a.addingReportingOverflow(b)
    return o ? nil : s
}

@inline(__always) func utf8Len(_ c: Unicode.Scalar) -> Int {
    let v = c.value
    return v < 0x80 ? 1 : v < 0x800 ? 2 : v < 0x10000 ? 3 : 4
}

@inline(__always) func utf16Len(_ c: Unicode.Scalar) -> Int { c.value < 0x10000 ? 1 : 2 }

/// Rust `str::replace(from, to)` for single characters (per Unicode scalar, so `\r\n` is two).
func replacingScalar(_ s: String, _ from: Unicode.Scalar, _ to: Unicode.Scalar) -> String {
    guard s.unicodeScalars.contains(from) else { return s }
    var v = String.UnicodeScalarView()
    for c in s.unicodeScalars { v.append(c == from ? to : c) }
    return String(v)
}

/// `\n` → `\r` (the model's line breaks as EngineData's).
func toEngineBreaks(_ s: String) -> String { replacingScalar(s, "\n", "\r") }

/// `\r` → `\n`.
func toModelBreaks(_ s: String) -> String { replacingScalar(s, "\r", "\n") }

/// Rust `s.strip_suffix('\r').unwrap_or(s)`.
func strippingCR(_ s: String) -> String {
    guard s.unicodeScalars.last == "\r" else { return s }
    var v = s.unicodeScalars
    v.removeLast()
    return String(v)
}

/// Rust `str::trim` (Unicode White_Space on both ends).
func trimmedWhitespace(_ s: String) -> String {
    let v = s.unicodeScalars
    guard let a = v.firstIndex(where: { !$0.properties.isWhitespace }),
          let b = v.lastIndex(where: { !$0.properties.isWhitespace }) else { return "" }
    return String(v[a ... b])
}

/// Rust `str::ends_with` (bytes).
func endsWith(_ s: String, _ suffix: String) -> Bool {
    let a = Array(s.utf8), b = Array(suffix.utf8)
    return a.count >= b.count && a[(a.count - b.count)...].elementsEqual(b)
}

/// Rust `str::contains(&str)` (bytes).
func containsBytes(_ s: String, _ needle: String) -> Bool {
    let a = Array(s.utf8), b = Array(needle.utf8)
    if b.isEmpty { return true }
    guard a.count >= b.count else { return false }
    for i in 0 ... (a.count - b.count) where a[i] == b[0] && a[i ..< i + b.count].elementsEqual(b) { return true }
    return false
}

/// UTF-16 length of a string (Rust `encode_utf16().count()`).
@inline(__always) func utf16Count(_ s: String) -> Int { s.utf16.count }

extension Array {
    /// Rust `slice.get(i)`.
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}

// MARK: - photocraft `Value` accessors

extension PSDEngineData {
    /// An empty dictionary (photocraft `Value::dict()`).
    static var emptyDict: PSDEngineData { .dict([]) }

    /// A dictionary from `(key, value)` pairs, in order.
    static func d(_ items: [(String, PSDEngineData)]) -> PSDEngineData { .dict(items.map { Entry($0.0, $0.1) }) }

    /// photocraft `Value::get`: the first entry named `key` of a dictionary.
    func get(_ key: String) -> PSDEngineData? {
        guard case let .dict(items) = self else { return nil }
        return items.first { same($0.key, key) }?.value
    }

    /// photocraft `Value::path`: follows dictionary keys only.
    func at(_ keys: String...) -> PSDEngineData? {
        var v: PSDEngineData? = self
        for k in keys { v = v?.get(k) }
        return v
    }

    /// photocraft `Value::set`: replaces the first entry named `key` or appends one; no-op on
    /// anything but a dictionary.
    mutating func put(_ key: String, _ value: PSDEngineData) {
        guard case var .dict(items) = self else { return }
        if let i = items.firstIndex(where: { same($0.key, key) }) { items[i].value = value } else { items.append(Entry(key, value)) }
        self = .dict(items)
    }

    /// photocraft `Value::get_mut` followed by an edit: mutates the first entry named `key` in place.
    /// Returns nil (and does nothing) when there is no such entry.
    @discardableResult
    mutating func update<R>(_ key: String, _ body: (inout PSDEngineData) -> R) -> R? {
        guard case var .dict(items) = self, let i = items.firstIndex(where: { same($0.key, key) }) else { return nil }
        self = .null
        let r = body(&items[i].value)
        self = .dict(items)
        return r
    }

    /// Removes every entry named `key` (photocraft `retain`).
    mutating func removeAll(_ key: String) {
        guard case var .dict(items) = self else { return }
        items.removeAll { same($0.key, key) }
        self = .dict(items)
    }

    var isDict: Bool { if case .dict = self { true } else { false } }

    /// `as_f64`.
    var f64: Double? {
        switch self {
        case let .int(i): Double(i)
        case let .real(r): r
        default: nil
        }
    }

    /// `as_i64` (reals saturate, NaN → 0, as Rust's `as`).
    var i64: Int64? {
        switch self {
        case let .int(i): i
        case let .real(r): sat(r) as Int64
        default: nil
        }
    }

    /// `as_bool`.
    var flag: Bool? {
        switch self {
        case let .bool(b): b
        case let .int(i): i != 0
        default: nil
        }
    }

    /// `as_str`.
    var str: String? {
        switch self {
        case let .string(s), let .name(s): s
        default: nil
        }
    }

    /// `as_array`.
    var arr: [PSDEngineData]? { if case let .array(a) = self { a } else { nil } }

    /// Structural equality with byte-compared strings and keys (Rust's derived `PartialEq`).
    func sameValue(_ o: PSDEngineData) -> Bool {
        switch (self, o) {
        case let (.dict(a), .dict(b)):
            a.count == b.count && zip(a, b).allSatisfy { same($0.key, $1.key) && $0.value.sameValue($1.value) }
        case let (.array(a), .array(b)): a.count == b.count && zip(a, b).allSatisfy { $0.sameValue($1) }
        case let (.string(a), .string(b)), let (.name(a), .name(b)): same(a, b)
        case let (.int(a), .int(b)): a == b
        case let (.real(a), .real(b)): a == b
        case let (.bool(a), .bool(b)): a == b
        case (.null, .null): true
        case let (.hex(a), .hex(b)): a == b
        default: false
        }
    }
}

/// `arr_f`: the numbers of an array (non-numbers skipped); empty when not an array.
func arrF(_ v: PSDEngineData?) -> [Double] { v?.arr?.compactMap(\.f64) ?? [] }

// MARK: - photocraft's writer

enum EngineWriter {
    /// photocraft `engine_data::write`: two newlines, the value, a newline.
    static func write(_ v: PSDEngineData) -> [UInt8] {
        var out: [UInt8] = [0x0A, 0x0A]
        writeValue(v, 0, &out)
        out.append(0x0A)
        return out
    }

    /// photocraft `engine_data::write_bare`: `/key value` pairs without an enclosing dictionary
    /// (the document `Txt2` layout).
    static func writeBare(_ items: [PSDEngineData.Entry]) -> [UInt8] {
        var out: [UInt8] = [0x0A, 0x0A]
        for e in items {
            out.append(UInt8(ascii: "/"))
            out += Array(e.key.utf8)
            if isContainer(e.value) {
                out.append(0x0A)
                indent(&out, 1)
            } else {
                out.append(0x20)
            }
            writeValue(e.value, 1, &out)
            out.append(0x0A)
        }
        return out
    }

    @inline(__always) static func indent(_ out: inout [UInt8], _ n: Int) {
        out.append(contentsOf: repeatElement(0x09, count: n))
    }

    static func isContainer(_ v: PSDEngineData) -> Bool {
        switch v {
        case .dict: true
        case let .array(a): a.contains { if case .dict = $0 { true } else if case .array = $0 { true } else { false } }
        default: false
        }
    }

    static func writeValue(_ v: PSDEngineData, _ depth: Int, _ out: inout [UInt8]) {
        switch v {
        case let .dict(items):
            out += Array("<<\n".utf8)
            for e in items {
                indent(&out, depth + 1)
                out.append(UInt8(ascii: "/"))
                out += Array(e.key.utf8)
                if isContainer(e.value) {
                    out.append(0x0A)
                    indent(&out, depth + 1)
                } else {
                    out.append(0x20)
                }
                writeValue(e.value, depth + 1, &out)
                out.append(0x0A)
            }
            indent(&out, depth)
            out += Array(">>".utf8)
        case let .array(items) where isContainer(v):
            out += Array("[\n".utf8)
            for x in items {
                indent(&out, depth)
                writeValue(x, depth, &out)
                out.append(0x0A)
            }
            indent(&out, depth)
            out.append(UInt8(ascii: "]"))
        case let .array(items):
            out.append(UInt8(ascii: "["))
            for x in items {
                out.append(0x20)
                writeValue(x, depth, &out)
            }
            out += Array(" ]".utf8)
        case let .string(s):
            out.append(UInt8(ascii: "("))
            var raw: [UInt8] = [0xFE, 0xFF]
            for u in s.utf16 {
                raw.append(UInt8(u >> 8))
                raw.append(UInt8(u & 0xFF))
            }
            for c in raw {
                if c == UInt8(ascii: "(") || c == UInt8(ascii: ")") || c == UInt8(ascii: "\\") { out.append(UInt8(ascii: "\\")) }
                out.append(c)
            }
            out.append(UInt8(ascii: ")"))
        case let .int(i): out += Array(String(i).utf8)
        case let .real(r): out += Array(PSDEngineData.formatReal(r).utf8)
        case let .bool(b): out += Array((b ? "true" : "false").utf8)
        case let .name(n):
            out.append(UInt8(ascii: "/"))
            out += Array(n.utf8)
        // Not in photocraft's model (its parser rejects them); written as PCPSD writes them.
        case .null: out += Array("null".utf8)
        case let .hex(bytes):
            let digits = Array("0123456789ABCDEF".utf8)
            out.append(UInt8(ascii: "<"))
            for x in bytes {
                out.append(digits[Int(x >> 4)])
                out.append(digits[Int(x & 0x0F)])
            }
            out.append(UInt8(ascii: ">"))
        }
    }
}
