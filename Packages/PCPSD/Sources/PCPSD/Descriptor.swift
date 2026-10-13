// Photoshop ActionDescriptor structures (OSType-tagged key/value trees) used inside many tagged blocks
// (lfx2, SoCo, GdFl, PtFl, TySh, PlLd/SoLd, vogk, vstk, vibA, blwh, clrL, shmd/cmls, slices, …).
// Port of photocraft-psd (crates/psd/src/descriptor.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors. Parsing and writing are exact: `write(parse(b)) == b` for
// well-formed input (boolean bytes other than 0/1 are written back as 1, as photocraft does).

import Foundation

/// A Photoshop Unicode string: UTF-16 code units kept exactly (trailing NUL, unpaired surrogates).
public struct PSDUnicodeString: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var units: [UInt16]

    public init(units: [UInt16]) { self.units = units }
    /// UTF-16 without a trailing NUL.
    public init(_ s: String) { units = Array(s.utf16) }
    public init(stringLiteral value: String) { self.init(value) }
    /// UTF-16 followed by a NUL terminator (as Photoshop commonly writes in descriptors).
    public static func nulTerminated(_ s: String) -> PSDUnicodeString { PSDUnicodeString(units: Array(s.utf16) + [0]) }

    /// Lossy conversion, trailing NULs stripped.
    public var string: String {
        var end = units.count
        while end > 0, units[end - 1] == 0 { end -= 1 }
        return String(decoding: units[0 ..< end], as: UTF16.self)
    }

    public var description: String { string }

    static func read(_ r: inout ByteReader) throws -> PSDUnicodeString { PSDUnicodeString(units: try r.unicodeUnits()) }
    func write(_ w: inout ByteWriter) { w.unicodeUnits(units) }
}

/// An ActionDescriptor: class plus ordered key/value items.
public struct PSDDescriptor: Equatable, Sendable {
    /// Four-character names Photoshop always writes as length-4 strings, never as codes
    /// (`00000004 'warp'`); Photoshop treats the two forms as different keys.
    public static let stringIDs: Set<String> = ["warp", "list", "time"]

    /// A class / key / type identifier: a length-prefixed string where a stored length of 0 means a
    /// 4-character code follows.
    public enum ID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
        case code(FourCC)
        case string([UInt8])

        /// 4-byte names become codes, others strings (except `stringIDs`).
        public init(_ s: String) {
            let b = Array(s.utf8)
            if b.count == 4, !PSDDescriptor.stringIDs.contains(s) { self = .code(FourCC(bytes: b)) } else { self = .string(b) }
        }

        public init(stringLiteral value: String) { self.init(value) }

        public var bytes: [UInt8] {
            switch self {
            case let .code(c): c.bytes
            case let .string(s): s
            }
        }

        /// The identifier as text.
        public var name: String { String(decoding: bytes, as: UTF8.self) }
        public func `is`(_ s: String) -> Bool { bytes == Array(s.utf8) }
        public var description: String { name }

        static func read(_ r: inout ByteReader) throws -> ID {
            let n = try r.u32()
            if n == 0 { return .code(try r.fourCC()) }
            return .string(try r.bytes(Int(n)))
        }

        func write(_ w: inout ByteWriter) {
            switch self {
            case let .code(c):
                w.u32(0)
                w.fourCC(c)
            case let .string(s):
                w.u32(UInt32(s.count))
                w.put(s)
            }
        }
    }

    /// A class reference: display name + class id.
    public struct ClassRef: Hashable, Sendable {
        public var name: PSDUnicodeString
        public var classID: ID
        public init(name: PSDUnicodeString = PSDUnicodeString(units: []), classID: ID) {
            self.name = name
            self.classID = classID
        }

        static func read(_ r: inout ByteReader) throws -> ClassRef {
            ClassRef(name: try .read(&r), classID: try .read(&r))
        }

        func write(_ w: inout ByteWriter) {
            name.write(&w)
            classID.write(&w)
        }
    }

    /// One element of an `obj ` reference.
    public enum ReferenceItem: Hashable, Sendable {
        case property(ClassRef, key: ID)
        case classRef(ClassRef)
        case enumerated(ClassRef, type: ID, value: ID)
        case offset(ClassRef, Int32)
        case identifier(UInt32)
        case index(UInt32)
        case name(ClassRef, PSDUnicodeString)
    }

    /// `ObAr` object array (undocumented; read as a u32 prefix followed by a descriptor-shaped body
    /// whose values are usually `UnFl`, as photocraft does after ag-psd).
    public struct ObjectArray: Equatable, Sendable {
        public var prefix: UInt32
        public var body: PSDDescriptor
        public init(prefix: UInt32 = 16, body: PSDDescriptor) {
            self.prefix = prefix
            self.body = body
        }
    }

    /// A descriptor value, tagged by its OSType.
    public indirect enum Value: Equatable, Sendable {
        /// `obj `
        case reference([ReferenceItem])
        /// `Objc`
        case descriptor(PSDDescriptor)
        /// `GlbO`
        case globalObject(PSDDescriptor)
        /// `VlLs`
        case list([Value])
        /// `doub`
        case double(Double)
        /// `UntF`: unit (`#Ang`, `#Rsl`, `#Rlt`, `#Nne`, `#Prc`, `#Pxl`, …) + value.
        case unitFloat(unit: FourCC, value: Double)
        /// `UnFl`: unit + array of doubles (used in `ObAr`).
        case unitFloats(unit: FourCC, values: [Double])
        /// `TEXT`
        case text(PSDUnicodeString)
        /// `enum`
        case enumerated(type: ID, value: ID)
        /// `long`
        case integer(Int32)
        /// `comp`
        case largeInteger(Int64)
        /// `bool`
        case boolean(Bool)
        /// `type`
        case classType(ClassRef)
        /// `GlbC`
        case globalClass(ClassRef)
        /// `alis`: raw alias data.
        case alias(Data)
        /// `Pth `: raw file path data.
        case path(Data)
        /// `tdta`: raw data (EngineData, LUT files, …).
        case rawData(Data)
        /// `ObAr`
        case objectArray(ObjectArray)

        public var ostype: FourCC {
            switch self {
            case .reference: "obj "
            case .descriptor: "Objc"
            case .globalObject: "GlbO"
            case .list: "VlLs"
            case .double: "doub"
            case .unitFloat: "UntF"
            case .unitFloats: "UnFl"
            case .text: "TEXT"
            case .enumerated: "enum"
            case .integer: "long"
            case .largeInteger: "comp"
            case .boolean: "bool"
            case .classType: "type"
            case .globalClass: "GlbC"
            case .alias: "alis"
            case .path: "Pth "
            case .rawData: "tdta"
            case .objectArray: "ObAr"
            }
        }

        /// Numeric value of `doub`, `UntF`, `long` or `comp`.
        public var number: Double? {
            switch self {
            case let .double(v): v
            case let .unitFloat(_, v): v
            case let .integer(v): Double(v)
            case let .largeInteger(v): Double(v)
            default: nil
            }
        }

        public var bool: Bool? { if case let .boolean(b) = self { b } else { nil } }
        public var text: String? { if case let .text(t) = self { t.string } else { nil } }
        public var descriptor: PSDDescriptor? {
            switch self {
            case let .descriptor(d), let .globalObject(d): d
            default: nil
            }
        }
        public var list: [Value]? { if case let .list(l) = self { l } else { nil } }
        /// The value name of an `enum`.
        public var enumValue: String? { if case let .enumerated(_, v) = self { v.name } else { nil } }
        public var rawBytes: Data? {
            switch self {
            case let .rawData(d), let .alias(d), let .path(d): d
            default: nil
            }
        }
    }

    public struct Item: Equatable, Sendable {
        public var key: ID
        public var value: Value
        public init(_ key: ID, _ value: Value) {
            self.key = key
            self.value = value
        }
    }

    /// Display name of the class (often empty).
    public var name: PSDUnicodeString
    public var classID: ID
    /// Items in stored order.
    public var items: [Item]

    public init(classID: ID = "null", name: PSDUnicodeString = PSDUnicodeString(units: []), items: [Item] = []) {
        self.name = name
        self.classID = classID
        self.items = items
    }

    /// Builder-style append.
    public func with(_ key: String, _ value: Value) -> PSDDescriptor {
        var d = self
        d.items.append(Item(ID(key), value))
        return d
    }

    /// First item with key `key`.
    public subscript(key: String) -> Value? {
        let b = Array(key.utf8)
        return items.first { $0.key.bytes == b }?.value
    }

    /// Replaces the first item named `key`, or appends one.
    public mutating func set(_ key: String, _ value: Value) {
        let b = Array(key.utf8)
        if let i = items.firstIndex(where: { $0.key.bytes == b }) { items[i].value = value } else { items.append(Item(ID(key), value)) }
    }

    public func number(_ key: String) -> Double? { self[key]?.number }
    public func bool(_ key: String) -> Bool? { self[key]?.bool }
    public func text(_ key: String) -> String? { self[key]?.text }
    public func descriptor(_ key: String) -> PSDDescriptor? { self[key]?.descriptor }
    public func list(_ key: String) -> [Value]? { self[key]?.list }
    public func enumValue(_ key: String) -> String? { self[key]?.enumValue }

    // MARK: Bytes

    /// Parses a descriptor that must use all of `data`.
    public init(bytes data: Data) throws {
        self = try data.withByteReader { r in
            let d = try PSDDescriptor.read(&r, depth: 0)
            guard r.isAtEnd else { throw PSDError.invalid("trailing bytes after descriptor") }
            return d
        }
    }

    public init(bytes: [UInt8]) throws { try self.init(bytes: Data(bytes)) }

    public func serialized() -> Data { Data(serializedBytes()) }

    public func serializedBytes() -> [UInt8] {
        var w = ByteWriter()
        write(&w)
        return w.bytes
    }

    static let maxPrealloc = 4096

    static func read(_ r: inout ByteReader, depth: Int) throws -> PSDDescriptor {
        guard depth <= PSDLimits.maxDescriptorDepth else { throw PSDError.limitExceeded("descriptor nesting too deep") }
        let name = try PSDUnicodeString.read(&r)
        let classID = try ID.read(&r)
        let n = try r.u32()
        // Each item needs at least 5 (1-byte string key) + 4 (type) + 1 (bool).
        try r.checkCount(UInt64(n), minItemSize: 10)
        var items = [Item]()
        items.reserveCapacity(min(Int(n), maxPrealloc))
        for _ in 0 ..< n {
            let key = try ID.read(&r)
            items.append(Item(key, try readValue(&r, depth: depth + 1)))
        }
        return PSDDescriptor(classID: classID, name: name, items: items)
    }

    static func readValue(_ r: inout ByteReader, depth: Int) throws -> Value {
        guard depth <= PSDLimits.maxDescriptorDepth else { throw PSDError.limitExceeded("descriptor nesting too deep") }
        return try readTypedValue(&r, type: try r.fourCC(), depth: depth)
    }

    static func readTypedValue(_ r: inout ByteReader, type: FourCC, depth: Int) throws -> Value {
        switch type {
        case "obj ":
            let n = try r.u32()
            try r.checkCount(UInt64(n), minItemSize: 8)
            var items = [ReferenceItem]()
            items.reserveCapacity(min(Int(n), maxPrealloc))
            for _ in 0 ..< n { items.append(try readReferenceItem(&r)) }
            return .reference(items)
        case "Objc": return .descriptor(try read(&r, depth: depth + 1))
        case "GlbO": return .globalObject(try read(&r, depth: depth + 1))
        case "VlLs":
            let n = try r.u32()
            try r.checkCount(UInt64(n), minItemSize: 4)
            var items = [Value]()
            items.reserveCapacity(min(Int(n), maxPrealloc))
            for _ in 0 ..< n { items.append(try readValue(&r, depth: depth + 1)) }
            return .list(items)
        case "doub": return .double(try r.f64())
        case "UntF": return .unitFloat(unit: try r.fourCC(), value: try r.f64())
        case "UnFl":
            let unit = try r.fourCC()
            let n = try r.u32()
            try r.checkCount(UInt64(n), minItemSize: 8)
            var v = [Double]()
            v.reserveCapacity(Int(n))
            for _ in 0 ..< n { v.append(try r.f64()) }
            return .unitFloats(unit: unit, values: v)
        case "TEXT": return .text(try .read(&r))
        case "enum": return .enumerated(type: try .read(&r), value: try .read(&r))
        case "long": return .integer(try r.i32())
        case "comp": return .largeInteger(try r.i64())
        case "bool": return .boolean(try r.u8() != 0)
        case "type": return .classType(try .read(&r))
        case "GlbC": return .globalClass(try .read(&r))
        case "alis": return .alias(try r.data(Int(try r.u32())))
        case "Pth ": return .path(try r.data(Int(try r.u32())))
        case "tdta": return .rawData(try r.data(Int(try r.u32())))
        case "ObAr":
            let prefix = try r.u32()
            return .objectArray(ObjectArray(prefix: prefix, body: try read(&r, depth: depth + 1)))
        default:
            throw PSDError.unsupported("descriptor OSType \(type)")
        }
    }

    static func readReferenceItem(_ r: inout ByteReader) throws -> ReferenceItem {
        let t = try r.fourCC()
        switch t {
        case "prop": return .property(try .read(&r), key: try .read(&r))
        case "Clss": return .classRef(try .read(&r))
        case "Enmr": return .enumerated(try .read(&r), type: try .read(&r), value: try .read(&r))
        case "rele": return .offset(try .read(&r), try r.i32())
        case "Idnt": return .identifier(try r.u32())
        case "indx": return .index(try r.u32())
        case "name": return .name(try .read(&r), try .read(&r))
        default: throw PSDError.unsupported("reference item type \(t)")
        }
    }

    func write(_ w: inout ByteWriter) {
        name.write(&w)
        classID.write(&w)
        w.u32(UInt32(items.count))
        for it in items {
            it.key.write(&w)
            PSDDescriptor.writeValue(it.value, &w)
        }
    }

    static func writeValue(_ v: Value, _ w: inout ByteWriter) {
        w.fourCC(v.ostype)
        switch v {
        case let .reference(items):
            w.u32(UInt32(items.count))
            for it in items {
                switch it {
                case let .property(c, key):
                    w.fourCC("prop"); c.write(&w); key.write(&w)
                case let .classRef(c):
                    w.fourCC("Clss"); c.write(&w)
                case let .enumerated(c, type, value):
                    w.fourCC("Enmr"); c.write(&w); type.write(&w); value.write(&w)
                case let .offset(c, o):
                    w.fourCC("rele"); c.write(&w); w.i32(o)
                case let .identifier(i):
                    w.fourCC("Idnt"); w.u32(i)
                case let .index(i):
                    w.fourCC("indx"); w.u32(i)
                case let .name(c, n):
                    w.fourCC("name"); c.write(&w); n.write(&w)
                }
            }
        case let .descriptor(d), let .globalObject(d): d.write(&w)
        case let .list(items):
            w.u32(UInt32(items.count))
            for it in items { writeValue(it, &w) }
        case let .double(d): w.f64(d)
        case let .unitFloat(unit, value):
            w.fourCC(unit)
            w.f64(value)
        case let .unitFloats(unit, values):
            w.fourCC(unit)
            w.u32(UInt32(values.count))
            for x in values { w.f64(x) }
        case let .text(s): s.write(&w)
        case let .enumerated(t, v):
            t.write(&w)
            v.write(&w)
        case let .integer(i): w.i32(i)
        case let .largeInteger(i): w.i64(i)
        case let .boolean(b): w.u8(b ? 1 : 0)
        case let .classType(c), let .globalClass(c): c.write(&w)
        case let .alias(d), let .path(d), let .rawData(d):
            w.u32(UInt32(d.count))
            w.put(d)
        case let .objectArray(o):
            w.u32(o.prefix)
            o.body.write(&w)
        }
    }
}

/// A descriptor prefixed by a u32 version (16 in all current Photoshop files).
public struct PSDVersionedDescriptor: Equatable, Sendable {
    public var version: UInt32
    public var descriptor: PSDDescriptor

    public init(_ descriptor: PSDDescriptor, version: UInt32 = 16) {
        self.version = version
        self.descriptor = descriptor
    }

    /// Parses `data`, which must be consumed entirely.
    public init(bytes data: Data) throws {
        self = try data.withByteReader { r in
            let v = try PSDVersionedDescriptor.read(&r)
            guard r.isAtEnd else { throw PSDError.invalid("trailing bytes after versioned descriptor") }
            return v
        }
    }

    /// Parses a versioned descriptor at the start of `data` and returns it with the bytes used
    /// (trailing data allowed, e.g. the warp descriptor after the text descriptor in `TySh`).
    public static func parsePrefix(_ data: Data) throws -> (PSDVersionedDescriptor, Int) {
        try data.withByteReader { r in
            let v = try read(&r)
            return (v, r.pos)
        }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        write(&w)
        return w.data
    }

    static func read(_ r: inout ByteReader) throws -> PSDVersionedDescriptor {
        let v = try r.u32()
        guard v == 16 else { throw PSDError.invalid("descriptor version \(v), expected 16") }
        return PSDVersionedDescriptor(try PSDDescriptor.read(&r, depth: 0), version: v)
    }

    func write(_ w: inout ByteWriter) {
        w.u32(version)
        descriptor.write(&w)
    }
}
