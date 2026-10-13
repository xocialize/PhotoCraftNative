// Port of photocraft-affinity (crates/affinity/src/stream.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// The tagged object stream inside `doc.dat`: a self-describing tree of objects whose fields carry a
// type code and a four-character tag. Parsing needs no schema; unknown fields are kept, so the
// document mapping can name what it could not import.

extension Affinity {
    /// A four-character tag in its readable order (`Desc`, `Chld`); the stream stores it
    /// little-endian, so the bytes on disk read reversed (`cseD`).
    public struct Tag: Hashable, Comparable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, ExpressibleByStringLiteral {
        public var rawValue: UInt32

        public init(_ rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// The tag spelled by the first four bytes of `s` (shorter strings are zero-padded).
        public init(_ s: String) {
            var v: UInt32 = 0
            var bytes = Array(s.utf8.prefix(4))
            while bytes.count < 4 { bytes.append(0) }
            for b in bytes { v = v << 8 | UInt32(b) }
            rawValue = v
        }

        public init(stringLiteral value: String) {
            self.init(value)
        }

        /// The four bytes in readable order.
        public var bytes: [UInt8] {
            [UInt8(truncatingIfNeeded: rawValue >> 24), UInt8(truncatingIfNeeded: rawValue >> 16), UInt8(truncatingIfNeeded: rawValue >> 8), UInt8(truncatingIfNeeded: rawValue)]
        }

        public var description: String { Affinity.lossy(bytes) }
        public var debugDescription: String { description }

        public static func < (a: Tag, b: Tag) -> Bool { a.rawValue < b.rawValue }
    }

    /// Index of an object in `Stream.objects`.
    public typealias ObjID = Int

    /// A decoded field value.
    public enum Value: Equatable, Sendable {
        case int(Int64)
        case uint(UInt64)
        case float(Double)
        case bool(Bool)
        case enumeration(id: UInt16, version: UInt16)
        case str(String)
        /// Fixed-length vectors of i32 (points, rectangles).
        case ints([Int64])
        /// Fixed-length vectors of f32/f64 (points, rectangles, transforms).
        case floats([Double])
        /// Fixed-size record (curve nodes, ids) or fixed-size struct (colour components).
        case bytes([UInt8])
        case blob([UInt8])
        /// Name of another archive entry (raster tiles, embedded files).
        case entry(String)
        case flags(UInt64)
        /// `nil` is a null object.
        case obj(ObjID?)
        case array([Value])
    }

    public struct Field: Equatable, Sendable {
        public var tag: Tag
        public var value: Value

        public init(_ tag: Tag, _ value: Value) {
            self.tag = tag
            self.value = value
        }
    }

    public struct Object: Equatable, Sendable {
        public enum Kind: Sendable {
            case root
            /// Defined once and referenced by id elsewhere.
            case shared
            case inline
            /// Untagged fields identified by position (curve data).
            case positional
        }

        public var classTag: Tag
        public var kind: Kind
        /// Class chain, most derived first (`ShpN`, `VNod`, `Node`).
        public var chain: [Tag]
        /// Fields in stream order; positional fields have tag 0.
        public var fields: [Field]

        public init(classTag: Tag, kind: Kind, chain: [Tag], fields: [Field]) {
            self.classTag = classTag
            self.kind = kind
            self.chain = chain
            self.fields = fields
        }

        public func get(_ tag: Tag) -> Value? {
            fields.first { $0.tag == tag }?.value
        }
    }

    public struct Stream: Sendable {
        public var root: ObjID
        public var objects: [Object]

        /// Deepest object nesting accepted; real documents stay well below (each layer level adds three).
        public static let maxDepth = 384
        static let maxObjects = 8_000_000
        /// Most values (fields and array elements) one stream may decode. A value takes tens of bytes
        /// in memory however few it took in the file (a bool array packs eight in a byte), so the size
        /// of the input alone doesn't bound what parsing allocates: a small compressed entry could
        /// otherwise ask for tens of gigabytes. Real documents stay far below.
        public static let maxValues = 1 << 24

        /// Parse a stream (`00 FF 4B 53` header). Bytes after the root's terminator are ignored.
        public static func parse(_ bytes: [UInt8]) throws(AffinityError) -> Stream {
            var c = ByteCursor(bytes)
            guard try c.take(4).elementsEqual([0x00, 0xFF, 0x4B, 0x53]) else { throw .malformed("document stream signature") }
            let version = try c.u16()
            guard version <= 2 else { throw .unsupported("document stream version") }
            let cls = Tag(try c.u32())
            _ = try c.u16()
            if version == 2 { _ = try c.u32() }
            var p = StreamParser(c: c)
            let root = try p.push(Object(classTag: cls, kind: .root, chain: [cls], fields: []))
            let fields = try p.rootFields(cls)
            p.objects[root].fields = fields
            return Stream(root: root, objects: p.objects)
        }
    }

    /// The stream grammar is recursive (objects hold field lists that hold objects); photocraft parses
    /// it with recursive descent. Here the nesting lives on an explicit stack instead of the call
    /// stack, so a document nested to `Stream.maxDepth` costs the same few bytes per level in debug
    /// and release builds, on any thread. Reads, value budgets, object ids and errors happen in the
    /// same order as photocraft's recursion.
    struct StreamParser {
        var c: ByteCursor
        var objects: [Object] = []
        /// Shared ids, defined at first use and referenced backwards.
        var shared: [UInt32: ObjID] = [:]
        var depth = 0
        /// Values decoded so far, against `Stream.maxValues`.
        var values = 0
        private var stack: [Frame] = []

        /// Work waiting for a value or a field list.
        private enum Frame {
            /// A field list, waiting for the value of the field tagged `tag`.
            case list(tagged: Bool, cls: Tag, fields: [Field], tag: Tag)
            /// An array of objects, waiting for `remaining` more elements (`inlineClass`: inline
            /// objects of one class, else elements of type `code`).
            case array(code: UInt8, cls: Tag, inlineClass: Tag?, remaining: Int, values: [Value])
            /// Objects waiting for their field list.
            case positional(Tag)
            case inline(Tag)
            case sharedChain(id: ObjID, chain: [Tag], fields: [Field])
            case sharedTail(id: ObjID, chain: [Tag], fields: [Field])
        }

        private enum Step {
            case startList(tagged: Bool, cls: Tag)
            case nextField
            case nextElement
            case value(Value)
            case list([Field])
            case chain(id: ObjID, chain: [Tag], fields: [Field])
        }

        init(c: ByteCursor) {
            self.c = c
        }

        mutating func push(_ o: Object) throws(AffinityError) -> ObjID {
            guard objects.count < Stream.maxObjects else { throw .limit("too many objects") }
            objects.append(o)
            return objects.count - 1
        }

        /// Counts `n` more values against `Stream.maxValues`, before anything is allocated for them.
        mutating func spend(_ n: Int) throws(AffinityError) {
            let (v, overflow) = values.addingReportingOverflow(n)
            guard !overflow, v <= Stream.maxValues else { throw .limit("too many values in the document stream") }
            values = v
        }

        /// An empty array with room for `n` values, paid for first.
        mutating func vec(_ n: Int) throws(AffinityError) -> [Value] {
            try spend(n)
            var v: [Value] = []
            v.reserveCapacity(n)
            return v
        }

        /// Element count of an array: each element takes at least `min` bytes, so a count the
        /// remaining input cannot hold is rejected before anything is allocated.
        mutating func count(_ min: Int) throws(AffinityError) -> Int {
            let n = Int(try c.u32())
            let (bytes, overflow) = n.multipliedReportingOverflow(by: Swift.max(min, 1))
            guard !overflow, bytes <= c.remaining else { throw .malformed("array longer than its data") }
            return n
        }

        /// The fields of the root object (photocraft's `fields(true, class)` on the root).
        mutating func rootFields(_ cls: Tag) throws(AffinityError) -> [Field] {
            let broken = AffinityError.malformed("document stream state")
            var step = Step.startList(tagged: true, cls: cls)
            while true {
                switch step {
                case .startList(let tagged, let cls):
                    depth += 1
                    guard depth <= Stream.maxDepth else { throw .limit("objects nested too deeply") }
                    stack.append(.list(tagged: tagged, cls: cls, fields: [], tag: Tag(0)))
                    step = .nextField

                case .nextField:
                    guard case .list(let tagged, let cls, let fields, _)? = stack.popLast() else { throw broken }
                    let t = try c.u8()
                    let code = t & 0x7F
                    if code == 0 {
                        depth -= 1
                        step = .list(fields)
                        continue
                    }
                    try spend(1)
                    let tag = tagged ? Tag(try c.u32()) : Tag(0)
                    stack.append(.list(tagged: tagged, cls: cls, fields: fields, tag: tag))
                    step = t & 0x80 != 0 ? try array(code, cls) : try scalar(code, tagged: tagged, cls)

                case .nextElement:
                    guard case .array(let code, let cls, let inlineClass, let remaining, let values)? = stack.popLast() else { throw broken }
                    if remaining == 0 {
                        step = .value(.array(values))
                        continue
                    }
                    stack.append(.array(code: code, cls: cls, inlineClass: inlineClass, remaining: remaining - 1, values: values))
                    if let inlineClass {
                        step = try inline(inlineClass)
                    } else {
                        step = try scalar(code, tagged: true, cls)
                    }

                case .value(let v):
                    switch stack.popLast() {
                    case .list(let tagged, let cls, var fields, let tag)?:
                        fields.append(Field(tag, v))
                        stack.append(.list(tagged: tagged, cls: cls, fields: fields, tag: tag))
                        step = .nextField
                    case .array(let code, let cls, let inlineClass, let remaining, var values)?:
                        values.append(v)
                        stack.append(.array(code: code, cls: cls, inlineClass: inlineClass, remaining: remaining, values: values))
                        step = .nextElement
                    default:
                        throw broken
                    }

                case .list(let fields):
                    switch stack.popLast() {
                    case nil:
                        return fields
                    case .positional(let cls)?:
                        step = .value(.obj(try push(Object(classTag: cls, kind: .positional, chain: [], fields: fields))))
                    case .inline(let cls)?:
                        step = .value(.obj(try push(Object(classTag: cls, kind: .inline, chain: [cls], fields: fields))))
                    case .sharedChain(let id, let chain, var collected)?:
                        collected.append(contentsOf: fields)
                        guard chain.count <= 64 else { throw .limit("object class chain too long") }
                        step = .chain(id: id, chain: chain, fields: collected)
                    case .sharedTail(let id, let chain, var collected)?:
                        collected.append(contentsOf: fields)
                        objects[id] = Object(classTag: chain.first ?? Tag(0), kind: .shared, chain: chain, fields: collected)
                        step = .value(.obj(id))
                    default:
                        throw broken
                    }

                case .chain(let id, var chain, let fields):
                    switch try c.u8() {
                    case 0:
                        let tag = Tag(try c.u32())
                        _ = try c.u16()
                        chain.append(tag)
                        stack.append(.sharedChain(id: id, chain: chain, fields: fields))
                        step = .startList(tagged: true, cls: tag)
                        continue
                    case 1:
                        chain.append(Tag(try c.u32()))
                    case 2:
                        break
                    default:
                        throw .malformed("object class chain")
                    }
                    let cls = chain.first ?? Tag(0)
                    stack.append(.sharedTail(id: id, chain: chain, fields: fields))
                    step = .startList(tagged: true, cls: cls)
                }
            }
        }

        mutating func string() throws(AffinityError) -> String {
            let n = Int(try c.u32())
            return Affinity.lossy(try c.take(n))
        }

        mutating func floats(_ n: Int, wide: Bool) throws(AffinityError) -> Value {
            var v: [Double] = []
            v.reserveCapacity(n)
            for _ in 0..<n {
                v.append(wide ? Double(bitPattern: try c.u64()) : Double(Float(bitPattern: try c.u32())))
            }
            return .floats(v)
        }

        /// A scalar field: objects start a nested field list, everything else is read at once.
        private mutating func scalar(_ code: UInt8, tagged: Bool, _ cls: Tag) throws(AffinityError) -> Step {
            switch code {
            case 0x30:
                stack.append(.positional(cls))
                return .startList(tagged: false, cls: cls)
            case 0x31 where !tagged, 0x32 where !tagged:
                throw .malformed("object without a field tag")
            case 0x31:
                return try sharedObject()
            case 0x32:
                return try inline(nil)
            default:
                return .value(try leaf(code))
            }
        }

        mutating func leaf(_ code: UInt8) throws(AffinityError) -> Value {
            switch code {
            case 0x01: return .uint(UInt64(try c.u8()))
            case 0x02: return .uint(UInt64(try c.u16()))
            case 0x03, 0x2f, 0x34: return .uint(UInt64(try c.u32()))
            case 0x04: return .uint(try c.u64())
            case 0x05: return .int(Int64(Int8(bitPattern: try c.u8())))
            case 0x06: return .int(Int64(Int16(bitPattern: try c.u16())))
            case 0x07: return .int(Int64(Int32(bitPattern: try c.u32())))
            case 0x08: return .int(Int64(bitPattern: try c.u64()))
            case 0x09: return .float(Double(Float(bitPattern: try c.u32())))
            case 0x0a: return .float(Double(bitPattern: try c.u64()))
            case 0x15...0x19:
                let n = Int(code - 0x13)
                var v: [Int64] = []
                for _ in 0..<n { v.append(Int64(Int32(bitPattern: try c.u32()))) }
                return .ints(v)
            case 0x1f...0x23: return try floats(Int(code - 0x1d), wide: false)
            case 0x24...0x28: return try floats(Int(code - 0x22), wide: true)
            case 0x29: return .bool(try c.u8() != 0)
            case 0x2a: return .enumeration(id: try c.u16(), version: try c.u16())
            case 0x2b, 0x2e: return .str(try string())
            case 0x2c:
                let n = Int(try c.u16())
                return .bytes(Array(try c.take(n)))
            case 0x35...0x74: return .bytes(Array(try c.take(Int(code - 0x34))))
            case 0x2d:
                let n = Int(try c.u32())
                return .blob(Array(try c.take(n)))
            case 0x33:
                _ = try c.u32()
                let n = Int(try c.u32())
                return .entry(Affinity.lossy(try c.take(n)))
            case 0x75:
                _ = try c.u16()
                let n = Int(try c.u8())
                guard n <= 8 else { throw .malformed("flags wider than 64 bits") }
                var v: UInt64 = 0
                for (i, b) in try c.take(n).enumerated() { v |= UInt64(b) << UInt64(8 * i) }
                return .flags(v)
            default:
                throw .unsupported("unknown field type in document stream")
            }
        }

        private mutating func array(_ code: UInt8, _ cls: Tag) throws(AffinityError) -> Step {
            let min: Int
            switch code {
            case 0x01, 0x05, 0x29: min = 1
            case 0x02, 0x06: min = 2
            case 0x03, 0x07, 0x09, 0x2f, 0x34: min = 4
            case 0x04, 0x08, 0x0a: min = 8
            case 0x15...0x19: min = 4 * Int(code - 0x13)
            case 0x1f...0x23: min = 4 * Int(code - 0x1d)
            case 0x24...0x28: min = 8 * Int(code - 0x22)
            case 0x35...0x74: min = Int(code - 0x34)
            default: min = 1
            }
            switch code {
            case 0x29:
                let n = Int(try c.u32())
                let bits = try c.take((n + 7) / 8)
                var v = try vec(n)
                let base = bits.startIndex
                for i in 0..<n { v.append(.bool(bits[base + i / 8] >> UInt8(i % 8) & 1 != 0)) }
                return .value(.array(v))
            case 0x2a:
                let n = try count(2)
                let version = try c.u16()
                var v = try vec(n)
                for _ in 0..<n { v.append(.enumeration(id: try c.u16(), version: version)) }
                return .value(.array(v))
            case 0x2b, 0x2e:
                _ = try c.u32()
                let n = try count(4)
                var v = try vec(n)
                for _ in 0..<n { v.append(.str(try string())) }
                return .value(.array(v))
            case 0x2c:
                let n = Int(try c.u32())
                let size = Int(try c.u16())
                let (bytes, overflow) = n.multipliedReportingOverflow(by: size)
                guard !overflow, bytes <= c.remaining else { throw .malformed("array longer than its data") }
                var v = try vec(n)
                for _ in 0..<n { v.append(.bytes(Array(try c.take(size)))) }
                return .value(.array(v))
            case 0x32:
                let n = try count(1)
                let inlineClass = Tag(try c.u32())
                _ = try c.u16()
                let v = try vec(n)
                stack.append(.array(code: code, cls: cls, inlineClass: inlineClass, remaining: n, values: v))
                return .nextElement
            case 0x2d, 0x33, 0x75:
                throw .malformed("array of an unarrayable type")
            case 0x30, 0x31:
                let n = try count(min)
                let v = try vec(n)
                stack.append(.array(code: code, cls: cls, inlineClass: nil, remaining: n, values: v))
                return .nextElement
            default:
                let n = try count(min)
                var v = try vec(n)
                for _ in 0..<n { v.append(try leaf(code)) }
                return .value(.array(v))
            }
        }

        /// Inline object; `given` is the class stated once for a whole array of them.
        private mutating func inline(_ given: Tag?) throws(AffinityError) -> Step {
            switch try c.u8() {
            case 0: return .value(.obj(nil))
            case 1: break
            default: throw .malformed("object marker")
            }
            let cls: Tag
            if let given {
                cls = given
            } else {
                cls = Tag(try c.u32())
                _ = try c.u16()
            }
            stack.append(.inline(cls))
            return .startList(tagged: true, cls: cls)
        }

        private mutating func sharedObject() throws(AffinityError) -> Step {
            let flag = try c.u8()
            if flag == 0 { return .value(.obj(nil)) }
            let key = try c.u32()
            switch flag {
            case 2:
                guard let id = shared[key] else { throw .malformed("reference to an undefined object") }
                return .value(.obj(id))
            case 1:
                break
            default:
                throw .malformed("object marker")
            }
            guard shared[key] == nil else { throw .malformed("object defined twice") }
            // Register before the fields: an object's own fields may refer back to it.
            let id = try push(Object(classTag: Tag(0), kind: .shared, chain: [], fields: []))
            shared[key] = id
            return .chain(id: id, chain: [], fields: [])
        }
    }
}
