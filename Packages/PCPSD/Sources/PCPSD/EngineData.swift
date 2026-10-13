// Photoshop's `EngineData`: the PostScript-like text engine document inside `TySh` (and the
// document-level `Txt2` block).
// Port of photocraft-text (crates/text/src/engine_data.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors. Tolerance for `null`, hex strings `<…>` and junk before the first
// `<<` cross-checked against Compositor IO/PSD/PSDText.swift (MIT, © 2026 Wonder Assembly LLC; no
// code copied).
//
// Syntax: dictionaries `<< /Key value … >>`, arrays `[ … ]`, strings `( … )` holding UTF-16BE with a
// `FE FF` mark (or Latin-1 bytes) where `\` escapes the next byte, numbers (`12`, `-1.5`, `.5`),
// `true`/`false`, `null` and `/Name` values. The writer reproduces Photoshop's layout (tab-indented,
// one key per line, reals as `1.0`, `.5`, `-.25`) and each dictionary value's literal encoding
// (UTF-16 with a mark, or 8-bit as in `Txt2`'s bit-flag strings).

import Foundation

public indirect enum PSDEngineData: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var key: String
        public var value: PSDEngineData
        /// How a string value was stored: `nil` (and `.utf16`) for UTF-16BE with a `FE FF` mark, as
        /// Photoshop stores text; `.eightBit` for a literal of raw bytes. Photoshop's `Txt2` has
        /// bit-flag strings such as `/2 (0100…)` in that form. The writer keeps it, so unmodified
        /// documents round-trip byte for byte. Not part of `==`.
        public var stringEncoding: StringEncoding?

        public init(_ key: String, _ value: PSDEngineData) {
            self.key = key
            self.value = value
        }

        public init(_ key: String, _ value: PSDEngineData, stringEncoding: StringEncoding?) {
            self.key = key
            self.value = value
            self.stringEncoding = stringEncoding
        }

        public static func == (a: Entry, b: Entry) -> Bool { a.key == b.key && a.value == b.value }
    }

    /// The byte form of a string literal.
    public enum StringEncoding: Hashable, Sendable {
        /// `FE FF` then UTF-16BE (the default).
        case utf16
        /// One byte per character (Latin-1); written as UTF-16 instead when a character does not fit.
        case eightBit
    }

    case dict([Entry])
    case array([PSDEngineData])
    case string(String)
    case int(Int64)
    case real(Double)
    case bool(Bool)
    case name(String)
    case null
    /// `<hex>` string, raw bytes.
    case hex([UInt8])

    public static let maxDepth = 64

    // MARK: Access

    public subscript(key: String) -> PSDEngineData? {
        if case let .dict(items) = self { return items.first { $0.key == key }?.value }
        return nil
    }

    /// Follows a path of dictionary keys (and array indices given as decimal strings).
    public func path(_ keys: String...) -> PSDEngineData? { path(keys) }

    public func path(_ keys: [String]) -> PSDEngineData? {
        var v: PSDEngineData? = self
        for k in keys {
            if case let .array(a)? = v, let i = Int(k) { v = i >= 0 && i < a.count ? a[i] : nil } else { v = v?[k] }
        }
        return v
    }

    public mutating func set(_ key: String, _ value: PSDEngineData) {
        guard case var .dict(items) = self else { return }
        if let i = items.firstIndex(where: { $0.key == key }) { items[i].value = value } else { items.append(Entry(key, value)) }
        self = .dict(items)
    }

    public var double: Double? {
        switch self {
        case let .int(i): Double(i)
        case let .real(r): r
        default: nil
        }
    }

    public var int: Int64? {
        switch self {
        case let .int(i): i
        case let .real(r): Int64(exactly: r.rounded(.towardZero))
        default: nil
        }
    }

    public var bool: Bool? {
        switch self {
        case let .bool(b): b
        case let .int(i): i != 0
        default: nil
        }
    }

    public var string: String? {
        switch self {
        case let .string(s), let .name(s): s
        default: nil
        }
    }

    public var array: [PSDEngineData]? { if case let .array(a) = self { a } else { nil } }
    public var entries: [Entry]? { if case let .dict(d) = self { d } else { nil } }

    // MARK: Parse

    /// Parses an EngineData document (its top-level dictionary). Bytes before the first `<<` are
    /// skipped (some writers prefix the dictionary with whitespace or a byte-order mark).
    public static func parse(_ data: Data) throws -> PSDEngineData {
        let b = [UInt8](data)
        var p = Parser(b: b, i: 0)
        p.ws()
        if !(p.i + 1 < b.count && b[p.i] == UInt8(ascii: "<") && b[p.i + 1] == UInt8(ascii: "<")) {
            if let start = (0 ..< max(0, b.count - 1)).first(where: { b[$0] == UInt8(ascii: "<") && b[$0 + 1] == UInt8(ascii: "<") }) {
                p.i = start
            }
        }
        return try p.value(0)
    }

    /// Parses the document `Txt2` block: a bare sequence of `/key value` pairs.
    public static func parseBare(_ data: Data) throws -> PSDEngineData {
        var wrapped = Data("<<".utf8)
        wrapped.append(data)
        wrapped.append(contentsOf: Array(">>".utf8))
        return try parse(wrapped)
    }

    struct Parser {
        let b: [UInt8]
        var i: Int
        /// Whether the string literal just parsed had no `FE FF` mark.
        var lastStringWasEightBit = false

        static func isDelimiter(_ c: UInt8) -> Bool {
            c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A || c == UInt8(ascii: "[") || c == UInt8(ascii: "]") || c == UInt8(ascii: "<")
                || c == UInt8(ascii: ">") || c == UInt8(ascii: "(") || c == UInt8(ascii: "/")
        }

        mutating func ws() {
            while i < b.count, [0x20, 0x09, 0x0D, 0x0A, 0x00].contains(b[i]) { i += 1 }
        }

        func err(_ m: String) -> PSDError { .invalid("EngineData: \(m) at byte \(i)") }

        mutating func name() -> String {
            i += 1
            let start = i
            while i < b.count, !Parser.isDelimiter(b[i]) { i += 1 }
            return String(decoding: b[start ..< i], as: UTF8.self)
        }

        mutating func value(_ depth: Int) throws -> PSDEngineData {
            guard depth <= PSDEngineData.maxDepth else { throw err("nesting too deep") }
            ws()
            guard i < b.count else { throw err("unexpected end") }
            let c = b[i]
            if c == UInt8(ascii: "<"), i + 1 < b.count, b[i + 1] == UInt8(ascii: "<") {
                i += 2
                var items: [Entry] = []
                while true {
                    ws()
                    guard i < b.count else { throw err("unterminated dictionary") }
                    if b[i] == UInt8(ascii: ">"), i + 1 < b.count, b[i + 1] == UInt8(ascii: ">") {
                        i += 2
                        return .dict(items)
                    }
                    guard b[i] == UInt8(ascii: "/") else { throw err("expected key") }
                    let k = name()
                    lastStringWasEightBit = false
                    let v = try value(depth + 1)
                    var isString = false
                    if case .string = v { isString = true }
                    items.append(Entry(k, v, stringEncoding: isString && lastStringWasEightBit ? .eightBit : nil))
                }
            }
            if c == UInt8(ascii: "<") {
                i += 1
                var nibbles: [UInt8] = []
                while i < b.count, b[i] != UInt8(ascii: ">") {
                    let h = b[i]
                    if let v = h >= 48 && h <= 57 ? h - 48 : h >= 97 && h <= 102 ? h - 87 : h >= 65 && h <= 70 ? h - 55 : nil { nibbles.append(v) }
                    i += 1
                }
                guard i < b.count else { throw err("unterminated hex string") }
                i += 1
                if nibbles.count % 2 == 1 { nibbles.append(0) }
                return .hex(stride(from: 0, to: nibbles.count, by: 2).map { nibbles[$0] << 4 | nibbles[$0 + 1] })
            }
            if c == UInt8(ascii: "[") {
                i += 1
                var items: [PSDEngineData] = []
                while true {
                    ws()
                    guard i < b.count else { throw err("unterminated array") }
                    if b[i] == UInt8(ascii: "]") {
                        i += 1
                        return .array(items)
                    }
                    items.append(try value(depth + 1))
                }
            }
            if c == UInt8(ascii: "(") {
                i += 1
                var raw: [UInt8] = []
                while true {
                    guard i < b.count else { throw err("unterminated string") }
                    let ch = b[i]
                    if ch == UInt8(ascii: "\\") {
                        if i + 1 < b.count { raw.append(b[i + 1]) }
                        i += 2
                    } else if ch == UInt8(ascii: ")") {
                        i += 1
                        break
                    } else {
                        raw.append(ch)
                        i += 1
                    }
                }
                lastStringWasEightBit = !(raw.count >= 2 && raw[0] == 0xFE && raw[1] == 0xFF)
                return .string(PSDEngineData.decodeString(raw))
            }
            if c == UInt8(ascii: "/") { return .name(name()) }
            let start = i
            while i < b.count, !Parser.isDelimiter(b[i]) { i += 1 }
            let tok = String(decoding: b[start ..< i], as: UTF8.self)
            switch tok {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            case "":
                i += 1
                throw err("unexpected byte")
            default:
                if tok.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) {
                    guard let r = Double(tok) else { throw err("bad number") }
                    return .real(r)
                }
                if let v = Int64(tok) { return .int(v) }
                if let r = Double(tok) { return .real(r) }
                throw err("bad token")
            }
        }
    }

    static func decodeString(_ raw: [UInt8]) -> String {
        if raw.count >= 2, raw[0] == 0xFE, raw[1] == 0xFF {
            let units = stride(from: 2, to: raw.count - 1, by: 2).map { UInt16(raw[$0]) << 8 | UInt16(raw[$0 + 1]) }
            return String(decoding: units, as: UTF16.self)
        }
        return String(raw.map { Character(Unicode.Scalar($0)) })
    }

    // MARK: Write

    /// Photoshop's layout: two newlines, then the value (no final newline).
    public func serialized() -> Data {
        var out: [UInt8] = [0x0A, 0x0A]
        PSDEngineData.write(self, depth: 0, &out)
        return Data(out)
    }

    /// `/key value` pairs without an enclosing dictionary (the `Txt2` layout).
    public func serializedBare() -> Data {
        var out: [UInt8] = [0x0A, 0x0A]
        for e in entries ?? [] {
            out.append(UInt8(ascii: "/"))
            out += Array(e.key.utf8)
            if case .dict = e.value {
                out.append(0x0A)
                out += [UInt8](repeating: 0x09, count: 1)
            } else {
                out.append(0x20)
            }
            PSDEngineData.write(e.value, depth: 1, &out, encoding: e.stringEncoding)
            out.append(0x0A)
        }
        return Data(out)
    }

    /// The compact single-line layout Photoshop uses for the document `Txt2` block:
    /// ` /key value` pairs, `<< /k v >>`, `[ v v ]`.
    public func serializedCompactBare() -> Data {
        var out: [UInt8] = []
        for e in entries ?? [] {
            out += Array(" /".utf8) + Array(e.key.utf8) + [0x20]
            PSDEngineData.writeCompact(e.value, &out, encoding: e.stringEncoding)
        }
        return Data(out)
    }

    static func writeCompact(_ v: PSDEngineData, _ out: inout [UInt8], encoding: StringEncoding? = nil) {
        switch v {
        case let .dict(items):
            out += Array("<<".utf8)
            for e in items {
                out += Array(" /".utf8) + Array(e.key.utf8) + [0x20]
                writeCompact(e.value, &out, encoding: e.stringEncoding)
            }
            out += Array(" >>".utf8)
        case let .array(items):
            out.append(UInt8(ascii: "["))
            for x in items {
                out.append(0x20)
                writeCompact(x, &out)
            }
            out += Array(" ]".utf8)
        default:
            write(v, depth: 0, &out, encoding: encoding)
        }
    }

    static func isContainer(_ v: PSDEngineData) -> Bool {
        switch v {
        case .dict: true
        case let .array(a): a.contains { if case .dict = $0 { true } else if case .array = $0 { true } else { false } }
        default: false
        }
    }

    static func write(_ v: PSDEngineData, depth: Int, _ out: inout [UInt8], encoding: StringEncoding? = nil) {
        func indent(_ n: Int) { out += [UInt8](repeating: 0x09, count: n) }
        switch v {
        case let .dict(items):
            out += Array("<<\n".utf8)
            for e in items {
                indent(depth + 1)
                out.append(UInt8(ascii: "/"))
                out += Array(e.key.utf8)
                // Dictionaries open on the next line; arrays (even of dictionaries) stay on the key's.
                if case .dict = e.value {
                    out.append(0x0A)
                    indent(depth + 1)
                } else {
                    out.append(0x20)
                }
                write(e.value, depth: depth + 1, &out, encoding: e.stringEncoding)
                out.append(0x0A)
            }
            indent(depth)
            out += Array(">>".utf8)
        case let .array(items) where isContainer(v):
            out += Array("[\n".utf8)
            for x in items {
                indent(depth)
                write(x, depth: depth, &out)
                out.append(0x0A)
            }
            indent(depth)
            out.append(UInt8(ascii: "]"))
        case let .array(items):
            out.append(UInt8(ascii: "["))
            for x in items {
                out.append(0x20)
                write(x, depth: depth, &out)
            }
            out += Array(" ]".utf8)
        case let .string(s):
            out.append(UInt8(ascii: "("))
            var raw: [UInt8]
            if encoding == .eightBit, s.unicodeScalars.allSatisfy({ $0.value <= 0xFF }) {
                raw = s.unicodeScalars.map { UInt8($0.value) }
            } else {
                raw = [0xFE, 0xFF]
                for u in s.utf16 { raw.append(UInt8(u >> 8)); raw.append(UInt8(u & 0xFF)) }
            }
            for c in raw {
                if c == UInt8(ascii: "(") || c == UInt8(ascii: ")") || c == UInt8(ascii: "\\") { out.append(UInt8(ascii: "\\")) }
                out.append(c)
            }
            out.append(UInt8(ascii: ")"))
        case let .int(i): out += Array(String(i).utf8)
        case let .real(r): out += Array(formatReal(r).utf8)
        case let .bool(b): out += Array((b ? "true" : "false").utf8)
        case let .name(n):
            out.append(UInt8(ascii: "/"))
            out += Array(n.utf8)
        case .null: out += Array("null".utf8)
        case let .hex(bytes):
            out.append(UInt8(ascii: "<"))
            for x in bytes { out += Array(String(format: "%02X", x).utf8) }
            out.append(UInt8(ascii: ">"))
        }
    }

    /// Photoshop style: `1.0`, `.5`, `-.25`, at most five decimals.
    public static func formatReal(_ r: Double) -> String {
        guard r.isFinite else { return "0.0" }
        if r.rounded(.towardZero) == r, abs(r) < 1e15 { return String(format: "%.1f", r) }
        var s = String(format: "%.5f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s == "0." || s == "-0." { return "0.0" }
        if s.hasPrefix("0.") { s.removeFirst() } else if s.hasPrefix("-0.") { s.remove(at: s.index(after: s.startIndex)) }
        return s
    }
}
