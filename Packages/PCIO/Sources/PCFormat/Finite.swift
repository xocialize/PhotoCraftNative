// Save-time check that the manifest holds only finite floats (photocraft issue #1101).
//
// JSON cannot spell NaN or the infinities: serde_json writes them as `null`, which the manifest's
// float fields refuse on load, so such a document would save (and autosave) with a success report
// and then never open again. The save is refused instead, naming the value, by walking the
// manifest with an encoder that produces nothing and fails on the first non-finite float.
// Port of photocraft-format (crates/format/src/finite.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.

enum Finite {
    /// Path of the first non-finite float, e.g. `document.layers[2].content.adjustment.Exposure.exposure`.
    /// (`other` is reserved for an `Encodable` failing on its own.)
    enum Problem: Error, Equatable, CustomStringConvertible {
        case nonFinite(path: String)
        case other(String)

        var description: String {
            switch self {
            case .nonFinite(let path): "`\(path)` is NaN or infinite"
            case .other(let m): m
            }
        }
    }

    /// Succeeds when every float in `value`'s encoded form is finite; otherwise throws the path of
    /// the first one that is not.
    static func check<T: Encodable>(_ value: T) throws(Problem) {
        do {
            try value.encode(to: CheckEncoder(path: ""))
        } catch let p as Problem {
            throw p
        } catch {
            throw .other(String(describing: error))
        }
    }

    /// `check` for a manifest, one layer at a time (group children taken out) so the stack used
    /// per group nesting level stays small. Paths are the same as for the whole tree, e.g.
    /// `document.layers[0].content.children[2].opacity`.
    static func checkManifest(_ m: Manifest) throws(Problem) {
        var shallow = m
        shallow.document.layers = []
        try check(shallow)
        for (i, l) in m.document.layers.enumerated() { try checkLayer(l, "document.layers[\(i)]") }
    }

    static func checkLayer(_ l: LayerM, _ path: String) throws(Problem) {
        try checkLayerWith(l, path)
        if case .group(let g) = l.content {
            for (i, c) in g.children.enumerated() { try checkLayer(c, "\(path).content.children[\(i)]") }
        }
    }

    @inline(never)
    static func checkLayerWith(_ l: LayerM, _ path: String) throws(Problem) {
        var shallow = l
        if case .group(var g) = shallow.content {
            g.children = []
            shallow.content = .group(g)
        }
        do {
            try shallow.encode(to: CheckEncoder(path: path))
        } catch let p as Problem {
            throw p
        } catch {
            throw .other(String(describing: error))
        }
    }

    struct PathKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(stringValue: String) { self.stringValue = stringValue }
        init(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
    }

    static func float(_ finite: Bool, _ path: String) throws {
        if !finite {
            var p = Substring(path)
            while p.first == "." { p = p.dropFirst() }
            throw Problem.nonFinite(path: String(p))
        }
    }

    struct CheckEncoder: Encoder {
        let path: String
        var codingPath: [any CodingKey] { [] }
        var userInfo: [CodingUserInfoKey: Any] { [:] }

        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
            KeyedEncodingContainer(Keyed<Key>(path: path))
        }
        func unkeyedContainer() -> any UnkeyedEncodingContainer { Unkeyed(path: path) }
        func singleValueContainer() -> any SingleValueEncodingContainer { Single(path: path) }
    }

    struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let path: String
        var codingPath: [any CodingKey] { [] }

        func at(_ key: Key) -> String { "\(path).\(key.stringValue)" }

        mutating func encodeNil(forKey key: Key) throws {}
        mutating func encode(_ value: Bool, forKey key: Key) throws {}
        mutating func encode(_ value: String, forKey key: Key) throws {}
        mutating func encode(_ value: Double, forKey key: Key) throws { try Finite.float(value.isFinite, at(key)) }
        mutating func encode(_ value: Float, forKey key: Key) throws { try Finite.float(value.isFinite, at(key)) }
        mutating func encode(_ value: Int, forKey key: Key) throws {}
        mutating func encode(_ value: Int8, forKey key: Key) throws {}
        mutating func encode(_ value: Int16, forKey key: Key) throws {}
        mutating func encode(_ value: Int32, forKey key: Key) throws {}
        mutating func encode(_ value: Int64, forKey key: Key) throws {}
        mutating func encode(_ value: UInt, forKey key: Key) throws {}
        mutating func encode(_ value: UInt8, forKey key: Key) throws {}
        mutating func encode(_ value: UInt16, forKey key: Key) throws {}
        mutating func encode(_ value: UInt32, forKey key: Key) throws {}
        mutating func encode(_ value: UInt64, forKey key: Key) throws {}
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws { try value.encode(to: CheckEncoder(path: at(key))) }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
            KeyedEncodingContainer(Keyed<NestedKey>(path: at(key)))
        }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer { Unkeyed(path: at(key)) }
        mutating func superEncoder() -> any Encoder { CheckEncoder(path: "\(path).super") }
        mutating func superEncoder(forKey key: Key) -> any Encoder { CheckEncoder(path: at(key)) }
    }

    struct Unkeyed: UnkeyedEncodingContainer {
        let path: String
        var count = 0
        var codingPath: [any CodingKey] { [] }

        init(path: String) { self.path = path }

        mutating func next() -> String {
            defer { count += 1 }
            return "\(path)[\(count)]"
        }

        mutating func encodeNil() throws { count += 1 }
        mutating func encode(_ value: Bool) throws { count += 1 }
        mutating func encode(_ value: String) throws { count += 1 }
        mutating func encode(_ value: Double) throws { try Finite.float(value.isFinite, next()) }
        mutating func encode(_ value: Float) throws { try Finite.float(value.isFinite, next()) }
        mutating func encode(_ value: Int) throws { count += 1 }
        mutating func encode(_ value: Int8) throws { count += 1 }
        mutating func encode(_ value: Int16) throws { count += 1 }
        mutating func encode(_ value: Int32) throws { count += 1 }
        mutating func encode(_ value: Int64) throws { count += 1 }
        mutating func encode(_ value: UInt) throws { count += 1 }
        mutating func encode(_ value: UInt8) throws { count += 1 }
        mutating func encode(_ value: UInt16) throws { count += 1 }
        mutating func encode(_ value: UInt32) throws { count += 1 }
        mutating func encode(_ value: UInt64) throws { count += 1 }
        mutating func encode<T: Encodable>(_ value: T) throws { try value.encode(to: CheckEncoder(path: next())) }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
            KeyedEncodingContainer(Keyed<NestedKey>(path: next()))
        }
        mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer { Unkeyed(path: next()) }
        mutating func superEncoder() -> any Encoder { CheckEncoder(path: next()) }
    }

    struct Single: SingleValueEncodingContainer {
        let path: String
        var codingPath: [any CodingKey] { [] }

        mutating func encodeNil() throws {}
        mutating func encode(_ value: Bool) throws {}
        mutating func encode(_ value: String) throws {}
        mutating func encode(_ value: Double) throws { try Finite.float(value.isFinite, path) }
        mutating func encode(_ value: Float) throws { try Finite.float(value.isFinite, path) }
        mutating func encode(_ value: Int) throws {}
        mutating func encode(_ value: Int8) throws {}
        mutating func encode(_ value: Int16) throws {}
        mutating func encode(_ value: Int32) throws {}
        mutating func encode(_ value: Int64) throws {}
        mutating func encode(_ value: UInt) throws {}
        mutating func encode(_ value: UInt8) throws {}
        mutating func encode(_ value: UInt16) throws {}
        mutating func encode(_ value: UInt32) throws {}
        mutating func encode(_ value: UInt64) throws {}
        mutating func encode<T: Encodable>(_ value: T) throws { try value.encode(to: CheckEncoder(path: path)) }
    }
}
