// Port of photocraft-io (crates/io/src/pdn/nrbf.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Data-only subset of MS-NRBF used by PDN3. References stay as ids; no .NET types are executed.
// https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-nrbf/

import PCIOCore

extension PaintDotNet {
    /// The MS-NRBF object graph reader.
    enum NRBF {
        static let maxItems = 1_000_000
        static let maxStrings = 64 << 20
        static let maxDepth = 64

        /// A cursor over the document bytes.
        struct Reader {
            let bytes: [UInt8]
            var pos: Int

            init(_ bytes: [UInt8], pos: Int = 0) {
                self.bytes = bytes
                self.pos = pos
            }

            mutating func take(_ len: Int) throws -> ArraySlice<UInt8> {
                let (end, overflow) = pos.addingReportingOverflow(len)
                guard !overflow, len >= 0 else { throw invalid("length overflow") }
                guard end <= bytes.count else { throw invalid("truncated document") }
                defer { pos = end }
                return bytes[pos ..< end]
            }

            mutating func byte() throws -> UInt8 {
                try take(1).first ?? 0
            }

            mutating func leI32() throws -> Int32 {
                let b = try take(4)
                let s = b.startIndex
                return Int32(bitPattern: UInt32(b[s]) | UInt32(b[s + 1]) << 8 | UInt32(b[s + 2]) << 16 | UInt32(b[s + 3]) << 24)
            }

            mutating func beU32() throws -> Int {
                let b = try take(4)
                let s = b.startIndex
                return Int(UInt32(b[s]) << 24 | UInt32(b[s + 1]) << 16 | UInt32(b[s + 2]) << 8 | UInt32(b[s + 3]))
            }

            mutating func count() throws -> Int {
                let v = try leI32()
                guard v >= 0 else { throw invalid("negative count") }
                let n = Int(v)
                if n > NRBF.maxItems { throw invalid("serialized array or class is too large") }
                return n
            }
        }

        /// Class metadata: name, member names and member primitive types (nil = a record).
        final class ClassInfo {
            let name: String
            let names: [String]
            let primitives: [UInt8?]

            init(name: String, names: [String], primitives: [UInt8?]) {
                self.name = name
                self.names = names
                self.primitives = primitives
            }
        }

        indirect enum Value {
            case null
            case bool(Bool)
            case int(Int64)
            case string(String)
            case ref(Int32)
            case array([Value])
            case object(ClassInfo, [Value])
        }

        struct Graph {
            var root: Value
            var objects: [Int32: Value] = [:]
            var order: [Int32] = []

            /// Objects of class `name`, in the order their records appeared.
            func objects(ofClass name: String) -> [(id: Int32, value: Value)] {
                order.compactMap { id in
                    guard let v = objects[id], case .object(let c, _) = v, c.name == name else { return nil }
                    return (id, v)
                }
            }

            func resolve(_ value: Value) throws -> Value {
                var v = value
                for _ in 0 ..< NRBF.maxDepth {
                    guard case .ref(let id) = v else { return v }
                    guard let next = objects[id] else { throw invalid("missing object reference") }
                    v = next
                }
                throw invalid("cyclic or excessively deep object reference")
            }

            func className(_ value: Value) throws -> String {
                guard case .object(let c, _) = try resolve(value) else { throw invalid("expected a serialized object") }
                return c.name
            }

            func field(_ value: Value, _ name: String) throws -> Value {
                guard let v = try optionalField(value, name) else { throw invalid("missing field \(name)") }
                return v
            }

            func optionalField(_ value: Value, _ name: String) throws -> Value? {
                guard case .object(let c, let members) = try resolve(value) else { throw invalid("expected a serialized object") }
                guard let i = c.names.firstIndex(of: name), i < members.count else { return nil }
                return members[i]
            }

            func integer(_ value: Value) throws -> Int64 {
                guard case .int(let n) = try resolve(value) else { throw invalid("expected an integer") }
                return n
            }

            func boolean(_ value: Value) throws -> Bool {
                guard case .bool(let b) = try resolve(value) else { throw invalid("expected a boolean") }
                return b
            }

            func string(_ value: Value) throws -> String {
                guard case .string(let s) = try resolve(value) else { throw invalid("expected a string") }
                return s
            }

            func array(_ value: Value) throws -> [Value] {
                guard case .array(let a) = try resolve(value) else { throw invalid("expected an array") }
                return a
            }
        }

        /// Parses an NRBF stream from `reader`'s position up to and including its MessageEnd.
        static func parse(_ reader: inout Reader, _ ctl: Interrupt) throws -> Graph {
            if try reader.byte() != 0 {
                throw invalid("missing NRBF stream header")
            }
            let root = try reader.leI32()
            _ = try reader.leI32()
            if root == 0 {
                throw invalid("unsupported NRBF stream version")
            }
            let major = try reader.leI32()
            let minor = try reader.leI32()
            if major != 1 || minor != 0 {
                throw invalid("unsupported NRBF stream version")
            }
            var parser = Parser(reader: reader, ctl: ctl, graph: Graph(root: .ref(root)))
            while true {
                let tag = try parser.reader.byte()
                if tag == 11 { break }
                _ = try parser.record(tag, 0)
            }
            _ = try parser.graph.resolve(parser.graph.root)
            reader = parser.reader
            return parser.graph
        }

        private struct Parser {
            var reader: Reader
            let ctl: Interrupt
            var graph: Graph
            var classes: [Int32: ClassInfo] = [:]
            var items = 0
            var strings = 0

            init(reader: Reader, ctl: Interrupt, graph: Graph) {
                self.reader = reader
                self.ctl = ctl
                self.graph = graph
            }

            mutating func budget(_ n: Int) throws {
                let (sum, overflow) = items.addingReportingOverflow(n)
                guard !overflow else { throw invalid("object count overflow") }
                items = sum
                if items > NRBF.maxItems { throw invalid("too many serialized objects or members") }
            }

            /// A LengthPrefixedString: 7-bit variable-length size, then UTF-8.
            mutating func string() throws -> String {
                var len = 0
                for shift in stride(from: 0, to: 35, by: 7) {
                    let b = try reader.byte()
                    if shift == 28 && b > 7 { throw invalid("invalid string length") }
                    len |= Int(b & 127) << shift
                    if b & 128 == 0 {
                        let (sum, overflow) = strings.addingReportingOverflow(len)
                        guard !overflow else { throw invalid("string length overflow") }
                        strings = sum
                        if strings > NRBF.maxStrings { throw invalid("serialized strings are too large") }
                        guard let s = String(validating: try reader.take(len), as: UTF8.self) else { throw invalid("invalid UTF-8 string") }
                        return s
                    }
                }
                throw invalid("invalid string length")
            }

            mutating func le<T: FixedWidthInteger>(_: T.Type) throws -> T {
                let b = try reader.take(MemoryLayout<T>.size)
                var v: T = 0
                for (i, byte) in b.enumerated() { v |= T(truncatingIfNeeded: byte) << (8 * i) }
                return v
            }

            mutating func primitive(_ tag: UInt8) throws -> Value {
                switch tag {
                case 1:
                    switch try reader.byte() {
                    case 0: return .bool(false)
                    case 1: return .bool(true)
                    default: throw invalid("invalid boolean")
                    }
                case 2: return .int(Int64(try reader.byte()))
                case 3:
                    let first = try reader.byte()
                    let len: Int
                    switch first {
                    case 0 ... 0x7F: len = 1
                    case 0xC2 ... 0xDF: len = 2
                    case 0xE0 ... 0xEF: len = 3
                    default: throw invalid("invalid character")
                    }
                    let b = [first] + Array(try reader.take(len - 1))
                    guard let s = String(validating: b, as: UTF8.self) else { throw invalid("invalid character") }
                    return .string(s)
                case 5, 18: return .string(try string())
                case 6:
                    _ = try reader.take(8)
                    return .null
                case 7: return .int(Int64(try le(Int16.self)))
                case 8: return .int(Int64(try le(Int32.self)))
                case 9, 12: return .int(try le(Int64.self))
                case 10: return .int(Int64(Int8(bitPattern: try reader.byte())))
                case 11:
                    _ = try reader.take(4)
                    return .null
                case 13, 16:
                    // Metadata dates may use the high bits; their bit pattern stays intact.
                    return .int(Int64(bitPattern: try le(UInt64.self)))
                case 14: return .int(Int64(try le(UInt16.self)))
                case 15: return .int(Int64(try le(UInt32.self)))
                case 17: return .null
                default: throw invalid("unsupported primitive type \(tag)")
                }
            }

            mutating func typeInfo(_ tag: UInt8) throws -> UInt8? {
                switch tag {
                case 0: return try reader.byte()
                case 1, 2, 5, 6: return nil
                case 3:
                    _ = try string()
                    return nil
                case 4:
                    _ = try string()
                    _ = try reader.leI32()
                    return nil
                case 7:
                    _ = try reader.byte()
                    return nil
                default: throw invalid("unsupported binary type \(tag)")
                }
            }

            mutating func reserve(_ id: Int32) throws {
                if id == 0 || graph.objects.updateValue(.null, forKey: id) != nil {
                    throw invalid("duplicate or zero object id")
                }
                graph.order.append(id)
            }

            mutating func value(_ depth: Int) throws -> Value {
                while true {
                    let tag = try reader.byte()
                    if tag == 12 {
                        _ = try record(tag, depth)
                    } else {
                        return try record(tag, depth)
                    }
                }
            }

            mutating func object(_ id: Int32, _ c: ClassInfo, _ depth: Int) throws -> Value {
                try reserve(id)
                try budget(c.names.count)
                var members: [Value] = []
                members.reserveCapacity(c.names.count)
                for p in c.primitives {
                    if let p {
                        members.append(try primitive(p))
                    } else {
                        members.append(try value(depth + 1))
                    }
                }
                graph.objects[id] = .object(c, members)
                return .ref(id)
            }

            mutating func array(_ id: Int32, _ len: Int, _ primitive: UInt8?, _ depth: Int) throws -> Value {
                try reserve(id)
                try budget(len)
                if primitive == 2 {
                    _ = try reader.take(len)
                    return .ref(id)
                }
                var values: [Value] = []
                values.reserveCapacity(min(len, 1 << 16))
                while values.count < len {
                    try ctl.check()
                    if let p = primitive {
                        values.append(try self.primitive(p))
                        continue
                    }
                    let tag = try reader.byte()
                    if tag == 13 || tag == 14 {
                        let count = tag == 13 ? Int(try reader.byte()) : try reader.count()
                        if count == 0 || count > len - values.count {
                            throw invalid("invalid array null run")
                        }
                        values.append(contentsOf: repeatElement(Value.null, count: count))
                    } else if tag == 12 {
                        _ = try record(tag, depth + 1)
                    } else {
                        values.append(try record(tag, depth + 1))
                    }
                }
                graph.objects[id] = .array(values)
                return .ref(id)
            }

            mutating func record(_ tag: UInt8, _ depth: Int) throws -> Value {
                try ctl.check()
                try budget(1)
                if depth > NRBF.maxDepth {
                    throw invalid("serialized objects nested too deeply")
                }
                switch tag {
                case 1:
                    let id = try reader.leI32()
                    let metadata = try reader.leI32()
                    guard let c = classes[metadata] else { throw invalid("missing class metadata") }
                    return try object(id, c, depth)
                case 2 ... 5:
                    let id = try reader.leI32()
                    let name = try string()
                    let count = try reader.count()
                    try budget(count)
                    var names: [String] = []
                    names.reserveCapacity(count)
                    for _ in 0 ..< count { names.append(try string()) }
                    var primitives: [UInt8?]
                    if tag >= 4 {
                        let types = Array(try reader.take(count))
                        primitives = []
                        primitives.reserveCapacity(count)
                        for t in types { primitives.append(try typeInfo(t)) }
                    } else {
                        primitives = [UInt8?](repeating: nil, count: count)
                    }
                    if tag == 3 || tag == 5 {
                        _ = try reader.leI32()
                    }
                    let c = ClassInfo(name: name, names: names, primitives: primitives)
                    if classes.updateValue(c, forKey: id) != nil {
                        throw invalid("duplicate class metadata")
                    }
                    return try object(id, c, depth)
                case 6:
                    let id = try reader.leI32()
                    try reserve(id)
                    let value = Value.string(try string())
                    graph.objects[id] = value
                    return .ref(id)
                case 7:
                    let id = try reader.leI32()
                    let kind = try reader.byte()
                    let rank = try reader.count()
                    if kind > 5 || rank == 0 || rank > 32 {
                        throw invalid("invalid array dimensions")
                    }
                    var len = 1
                    for _ in 0 ..< rank {
                        let (m, overflow) = len.multipliedReportingOverflow(by: try reader.count())
                        guard !overflow else { throw invalid("array size overflow") }
                        len = m
                    }
                    if kind >= 3 {
                        for _ in 0 ..< rank {
                            if try reader.leI32() != 0 { throw invalid("nonzero array lower bounds are unsupported") }
                        }
                    }
                    let t = try reader.byte()
                    let p = try typeInfo(t)
                    return try array(id, len, p, depth)
                case 8:
                    let p = try reader.byte()
                    return try primitive(p)
                case 9:
                    return .ref(try reader.leI32())
                case 10:
                    return .null
                case 12:
                    _ = try reader.leI32()
                    _ = try string()
                    return .null
                case 15 ... 17:
                    let id = try reader.leI32()
                    let len = try reader.count()
                    let p: UInt8? = tag == 15 ? try reader.byte() : nil
                    return try array(id, len, p, depth)
                default:
                    throw invalid("unsupported NRBF record \(tag)")
                }
            }
        }
    }
}
