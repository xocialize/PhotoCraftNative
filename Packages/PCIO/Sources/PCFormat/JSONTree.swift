// A JSON tree for manifest migrations (photocraft's `serde_json::Value`): numbers keep their
// source text, so u64 layer ids and every float survive a migration step unchanged, and object
// members keep their order. Strict RFC 8259 parsing like serde_json: no comments, no trailing
// commas, nothing after the value. Parsing and writing use explicit stacks, so no nesting depth
// can exhaust the thread's stack.
// Port support for photocraft-format (crates/format/src/migrate.rs, store.rs), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

/// One `"key": value` of a JSON object.
struct JSONMember: Equatable {
    var key: String
    var value: JSONTree
}

indirect enum JSONTree: Equatable {
    case null
    case bool(Bool)
    /// The number as written (validated JSON number syntax).
    case number(String)
    case string(String)
    case array([JSONTree])
    case object([JSONMember])

    /// `self[key]` (null when absent, as serde_json's `Index`); setting it on null makes an object.
    subscript(key: String) -> JSONTree {
        get {
            if case .object(let m) = self, let v = m.first(where: { $0.key == key }) { return v.value }
            return .null
        }
        set {
            switch self {
            case .null:
                self = .object([JSONMember(key: key, value: newValue)])
            case .object(var m):
                if let i = m.firstIndex(where: { $0.key == key }) { m[i].value = newValue } else { m.append(JSONMember(key: key, value: newValue)) }
                self = .object(m)
            default:
                break
            }
        }
    }

    /// The member `key`, when present.
    func get(_ key: String) -> JSONTree? {
        if case .object(let m) = self { return m.first(where: { $0.key == key })?.value }
        return nil
    }

    /// serde_json's `as_u64`: a non-negative integer literal that fits.
    var asU64: UInt64? {
        guard case .number(let s) = self, !s.contains(where: { $0 == "." || $0 == "e" || $0 == "E" || $0 == "-" }) else { return nil }
        return UInt64(s)
    }

    /// The value, leaving null in its place (serde_json's `Value::take`).
    mutating func take() -> JSONTree {
        let v = self
        self = .null
        return v
    }

    // MARK: Serialization

    /// Compact JSON text.
    var bytes: [UInt8] {
        var out: [UInt8] = []
        render(&out, pretty: false)
        return out
    }

    func write(_ out: inout [UInt8]) { render(&out, pretty: false) }

    /// serde_json's `PrettyFormatter` style: two-space indent, `"key": value`, empty containers
    /// inline.
    func writePretty(_ out: inout [UInt8], indent: Int) { render(&out, pretty: true, indent: indent) }

    /// Writes the tree with an explicit stack (no recursion, whatever the nesting).
    func render(_ out: inout [UInt8], pretty: Bool, indent: Int = 0) {
        enum Task {
            case value(JSONTree, Int)
            case byte(UInt8)
            case newline(Int)
            case key(String)
        }
        var stack: [Task] = [.value(self, indent)]
        while let task = stack.popLast() {
            switch task {
            case .byte(let b): out.append(b)
            case .newline(let n):
                if pretty {
                    out.append(0x0A)
                    out += [UInt8](repeating: 0x20, count: 2 * n)
                }
            case .key(let k):
                JSONTree.writeString(k, &out)
                out.append(UInt8(ascii: ":"))
                if pretty { out.append(0x20) }
            case let .value(v, level):
                switch v {
                case .null: out += Array("null".utf8)
                case .bool(let b): out += Array((b ? "true" : "false").utf8)
                case .number(let n): out += Array(n.utf8)
                case .string(let str): JSONTree.writeString(str, &out)
                case .array(let a):
                    out.append(UInt8(ascii: "["))
                    if a.isEmpty {
                        out.append(UInt8(ascii: "]"))
                        continue
                    }
                    // Pushed in reverse: the stack pops the first element first.
                    stack.append(.byte(UInt8(ascii: "]")))
                    stack.append(.newline(level))
                    for (i, e) in a.enumerated().reversed() {
                        stack.append(.value(e, level + 1))
                        stack.append(.newline(level + 1))
                        if i > 0 { stack.append(.byte(UInt8(ascii: ","))) }
                    }
                case .object(let m):
                    out.append(UInt8(ascii: "{"))
                    if m.isEmpty {
                        out.append(UInt8(ascii: "}"))
                        continue
                    }
                    stack.append(.byte(UInt8(ascii: "}")))
                    stack.append(.newline(level))
                    for (i, e) in m.enumerated().reversed() {
                        stack.append(.value(e.value, level + 1))
                        stack.append(.key(e.key))
                        stack.append(.newline(level + 1))
                        if i > 0 { stack.append(.byte(UInt8(ascii: ","))) }
                    }
                }
            }
        }
    }

    static func writeString(_ s: String, _ out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "\""): out += [0x5C, 0x22]
            case UInt8(ascii: "\\"): out += [0x5C, 0x5C]
            case 0x0A: out += [0x5C, UInt8(ascii: "n")]
            case 0x0D: out += [0x5C, UInt8(ascii: "r")]
            case 0x09: out += [0x5C, UInt8(ascii: "t")]
            case 0 ..< 0x20:
                let hex = Array("0123456789abcdef".utf8)
                out += [0x5C, UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0"), hex[Int(b >> 4)], hex[Int(b & 15)]]
            default: out.append(b)
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    // MARK: Parsing

    struct ParseError: Error, CustomStringConvertible {
        var message: String
        var offset: Int
        var description: String { "\(message) at byte \(offset)" }
    }

    /// Parses one JSON document (iteratively: any nesting is safe for the stack).
    static func parse(_ bytes: [UInt8]) throws(ParseError) -> JSONTree {
        var p = Parser(bytes: bytes)
        p.skipSpace()
        let v = try p.value()
        p.skipSpace()
        guard p.pos == bytes.count else { throw ParseError(message: "trailing characters", offset: p.pos) }
        return v
    }

    struct Parser {
        let bytes: [UInt8]
        var pos = 0

        mutating func skipSpace() {
            while pos < bytes.count, bytes[pos] == 0x20 || bytes[pos] == 0x0A || bytes[pos] == 0x0D || bytes[pos] == 0x09 { pos += 1 }
        }

        func fail(_ m: String) -> ParseError { ParseError(message: m, offset: pos) }

        mutating func literal(_ s: String, _ v: JSONTree) throws(ParseError) -> JSONTree {
            let u = Array(s.utf8)
            guard pos + u.count <= bytes.count, Array(bytes[pos ..< pos + u.count]) == u else { throw fail("expected value") }
            pos += u.count
            return v
        }

        /// One container being filled while parsing.
        struct Open {
            var isArray: Bool
            var items: [JSONTree] = []
            var members: [JSONMember] = []
            var key = ""
        }

        /// A value, parsed with an explicit stack of open containers (no recursion, whatever
        /// the nesting).
        mutating func value() throws(ParseError) -> JSONTree {
            var stack: [Open] = []
            while true {
                // Parse the start of a value: open a container or read a scalar.
                skipSpace()
                guard pos < bytes.count else { throw fail("EOF while parsing a value") }
                var done: JSONTree
                switch bytes[pos] {
                case UInt8(ascii: "["):
                    pos += 1
                    skipSpace()
                    if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") {
                        pos += 1
                        done = .array([])
                    } else {
                        stack.append(Open(isArray: true))
                        continue
                    }
                case UInt8(ascii: "{"):
                    pos += 1
                    skipSpace()
                    if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") {
                        pos += 1
                        done = .object([])
                    } else {
                        var o = Open(isArray: false)
                        o.key = try key()
                        stack.append(o)
                        continue
                    }
                default:
                    done = try scalar()
                }
                // Fold the finished value into the open containers.
                while true {
                    guard var top = stack.popLast() else { return done }
                    if top.isArray { top.items.append(done) } else { top.members.append(JSONMember(key: top.key, value: done)) }
                    skipSpace()
                    guard pos < bytes.count else { throw fail(top.isArray ? "EOF while parsing a list" : "EOF while parsing an object") }
                    let c = bytes[pos]
                    if c == UInt8(ascii: ",") {
                        pos += 1
                        if !top.isArray { top.key = try key() }
                        stack.append(top)
                        break
                    }
                    if top.isArray && c == UInt8(ascii: "]") {
                        pos += 1
                        done = .array(top.items)
                        continue
                    }
                    if !top.isArray && c == UInt8(ascii: "}") {
                        pos += 1
                        done = .object(top.members)
                        continue
                    }
                    throw fail(top.isArray ? "expected `,` or `]`" : "expected `,` or `}`")
                }
            }
        }

        /// An object key and its colon.
        mutating func key() throws(ParseError) -> String {
            skipSpace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { throw fail("key must be a string") }
            let k = try string()
            skipSpace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { throw fail("expected `:`") }
            pos += 1
            return k
        }

        @inline(never)
        mutating func scalar() throws(ParseError) -> JSONTree {
            switch bytes[pos] {
            case UInt8(ascii: "n"): return try literal("null", .null)
            case UInt8(ascii: "t"): return try literal("true", .bool(true))
            case UInt8(ascii: "f"): return try literal("false", .bool(false))
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"): return .number(try number())
            default: throw fail("expected value")
            }
        }

        mutating func number() throws(ParseError) -> String {
            let start = pos
            func digit(_ i: Int) -> Bool { i < bytes.count && bytes[i] >= 0x30 && bytes[i] <= 0x39 }
            if bytes[pos] == UInt8(ascii: "-") { pos += 1 }
            guard digit(pos) else { throw fail("invalid number") }
            if bytes[pos] == UInt8(ascii: "0") {
                pos += 1
            } else {
                while digit(pos) { pos += 1 }
            }
            if pos < bytes.count, bytes[pos] == UInt8(ascii: ".") {
                pos += 1
                guard digit(pos) else { throw fail("invalid number") }
                while digit(pos) { pos += 1 }
            }
            if pos < bytes.count, bytes[pos] == UInt8(ascii: "e") || bytes[pos] == UInt8(ascii: "E") {
                pos += 1
                if pos < bytes.count, bytes[pos] == UInt8(ascii: "+") || bytes[pos] == UInt8(ascii: "-") { pos += 1 }
                guard digit(pos) else { throw fail("invalid number") }
                while digit(pos) { pos += 1 }
            }
            return String(decoding: bytes[start ..< pos], as: UTF8.self)
        }

        mutating func hex4() throws(ParseError) -> UInt32 {
            guard pos + 4 <= bytes.count else { throw fail("EOF while parsing a string") }
            var v: UInt32 = 0
            for _ in 0 ..< 4 {
                let b = bytes[pos]
                let d: UInt32
                switch b {
                case 0x30 ... 0x39: d = UInt32(b - 0x30)
                case 0x41 ... 0x46: d = UInt32(b - 0x41 + 10)
                case 0x61 ... 0x66: d = UInt32(b - 0x61 + 10)
                default: throw fail("invalid escape")
                }
                v = v << 4 | d
                pos += 1
            }
            return v
        }

        mutating func string() throws(ParseError) -> String {
            pos += 1 // opening quote
            var out: [UInt8] = []
            while true {
                guard pos < bytes.count else { throw fail("EOF while parsing a string") }
                let b = bytes[pos]
                pos += 1
                switch b {
                case UInt8(ascii: "\""):
                    // Invalid UTF-8 is rejected, as serde_json does for `&[u8]` input.
                    guard let s = String(validating: out, as: UTF8.self) else { throw fail("invalid UTF-8 in string") }
                    return s
                case UInt8(ascii: "\\"):
                    guard pos < bytes.count else { throw fail("EOF while parsing a string") }
                    let e = bytes[pos]
                    pos += 1
                    switch e {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var cp = try hex4()
                        if cp >= 0xD800 && cp < 0xDC00 {
                            guard pos + 2 <= bytes.count, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") else {
                                throw fail("lone leading surrogate")
                            }
                            pos += 2
                            let lo = try hex4()
                            guard lo >= 0xDC00 && lo < 0xE000 else { throw fail("invalid surrogate pair") }
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                        } else if cp >= 0xDC00 && cp < 0xE000 {
                            throw fail("lone trailing surrogate")
                        }
                        guard let scalar = Unicode.Scalar(cp) else { throw fail("invalid escape") }
                        out += Array(String(Character(scalar)).utf8)
                    default:
                        throw fail("invalid escape")
                    }
                case 0 ..< 0x20:
                    throw fail("control character in string")
                default:
                    out.append(b)
                }
            }
        }
    }
}
