// Port of photocraft-affinity (crates/affinity/src/access.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Typed reads of `Stream` objects. Every accessor returns nil when a field is missing or has another
// type, so the document mapping treats odd data as absent rather than failing.

extension Affinity.Stream {
    public func object(_ id: Affinity.ObjID) -> Affinity.Object? {
        objects.indices.contains(id) ? objects[id] : nil
    }

    public func field(_ id: Affinity.ObjID, _ tag: Affinity.Tag) -> Affinity.Value? {
        guard objects.indices.contains(id) else { return nil }
        return objects[id].get(tag)
    }

    public func classTag(_ id: Affinity.ObjID) -> Affinity.Tag? {
        objects.indices.contains(id) ? objects[id].classTag : nil
    }

    /// Whether object `id` is of class `cls` (photocraft's `is`).
    public func isClass(_ id: Affinity.ObjID, _ cls: Affinity.Tag) -> Bool {
        classTag(id) == cls
    }

    /// A child object (shared, linked or inline); nil for null or missing.
    public func obj(_ id: Affinity.ObjID, _ tag: Affinity.Tag) -> Affinity.ObjID? {
        if case .obj(let o)? = field(id, tag) { return o }
        return nil
    }

    /// An array of objects (nulls skipped).
    public func objs(_ id: Affinity.ObjID, _ tag: Affinity.Tag) -> [Affinity.ObjID] {
        guard case .array(let a)? = field(id, tag) else { return [] }
        return a.compactMap { if case .obj(let o?) = $0 { o } else { nil } }
    }

    public func f64(_ id: Affinity.ObjID, _ tag: Affinity.Tag) -> Double? {
        if case .float(let f)? = field(id, tag), f.isFinite { return f }
        return nil
    }

    public func int(_ id: Affinity.ObjID, _ tag: Affinity.Tag) -> Int64? {
        switch field(id, tag) {
        case .int(let i)?: i
        case .uint(let u)?: Int64(exactly: u)
        default: nil
        }
    }

    public func bool(_ id: Affinity.ObjID, _ tag: Affinity.Tag) -> Bool? {
        if case .bool(let b)? = field(id, tag) { return b }
        return nil
    }

    public func str(_ id: Affinity.ObjID, _ tag: Affinity.Tag) -> String? {
        if case .str(let s)? = field(id, tag) { return s }
        return nil
    }

    public func enumeration(_ id: Affinity.ObjID, _ tag: Affinity.Tag) -> (id: UInt16, version: UInt16)? {
        if case .enumeration(let i, let v)? = field(id, tag) { return (i, v) }
        return nil
    }

    /// A fixed vector of `count` finite floats (points, rectangles, transforms).
    public func floats(_ id: Affinity.ObjID, _ tag: Affinity.Tag, count: Int) -> [Double]? {
        if case .floats(let v)? = field(id, tag), v.count == count, v.allSatisfy(\.isFinite) { return v }
        return nil
    }

    public func bytes(_ id: Affinity.ObjID, _ tag: Affinity.Tag) -> [UInt8]? {
        switch field(id, tag) {
        case .bytes(let b)?, .blob(let b)?: b
        default: nil
        }
    }

    public func entry(_ id: Affinity.ObjID, _ tag: Affinity.Tag) -> String? {
        if case .entry(let s)? = field(id, tag) { return s }
        return nil
    }

    /// Untagged fields of a positional object, in order.
    public func positional(_ id: Affinity.ObjID) -> [Affinity.Value] {
        object(id)?.fields.map(\.value) ?? []
    }
}
