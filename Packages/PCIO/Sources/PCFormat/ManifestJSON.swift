// Manifest ⇄ JSON text, one layer at a time.
//
// Foundation's coders recurse through the whole layer tree, kilobytes of stack per group level,
// and a bundle may nest groups 100 deep. So, as photocraft's `layers_from_json` does for loading,
// each layer is coded on its own with its group children taken out, and the tree is assembled
// as a `JSONTree` by small recursive functions. The text is written in serde_json's pretty style
// (`"key": value`, two-space indent), keys sorted.
// Port of photocraft-format (crates/format/src/store.rs: `read_manifest`, `layers_from_json`,
// `layer_from_json`, `take_array`; `prepare`'s `to_vec_pretty`), MIT OR Apache-2.0, © ArtCraft
// Team and the PhotoCraft contributors.

import Foundation

enum ManifestJSON {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static func tree<T: Encodable>(_ value: T, _ e: JSONEncoder) throws(FormatError) -> JSONTree {
        let data: Data
        do { data = try e.encode(value) } catch { throw .json(FormatError.jsonMessage(error)) }
        do throws(JSONTree.ParseError) { return try JSONTree.parse([UInt8](data)) } catch { throw .json(error.description) }
    }

    /// The manifest as pretty JSON text.
    static func encode(_ m: Manifest) throws(FormatError) -> [UInt8] {
        let e = encoder()
        var shallow = m
        shallow.document.layers = []
        var t = try tree(shallow, e)
        var layers: [JSONTree] = []
        layers.reserveCapacity(m.document.layers.count)
        for l in m.document.layers { layers.append(try layerTree(l, e)) }
        t["document"]["layers"] = .array(layers)
        var out: [UInt8] = []
        t.writePretty(&out, indent: 0)
        return out
    }

    static func layerTree(_ l: LayerM, _ e: JSONEncoder) throws(FormatError) -> JSONTree {
        // Children first, from this small frame.
        var kids: [JSONTree] = []
        if case .group(let g) = l.content {
            kids.reserveCapacity(g.children.count)
            for c in g.children { kids.append(try layerTree(c, e)) }
        }
        return try layerTreeWith(l, kids, e)
    }

    /// One layer, given its already converted group children.
    @inline(never)
    static func layerTreeWith(_ l: LayerM, _ kids: [JSONTree], _ e: JSONEncoder) throws(FormatError) -> JSONTree {
        var shallow = l
        if case .group(var g) = shallow.content {
            g.children = []
            shallow.content = .group(g)
        }
        var t = try tree(shallow, e)
        if case .group = l.content { t["content"]["children"] = .array(kids) }
        return t
    }

    /// Decodes a (migrated) manifest tree.
    static func decode(_ tree: JSONTree) throws(FormatError) -> Manifest {
        var t = tree
        let layers = take(&t, "document", "layers")
        var m: Manifest = try decodeValue(t)
        m.document.layers = try layersFrom(layers)
        return m
    }

    static func decodeValue<T: Decodable>(_ t: JSONTree) throws(FormatError) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(t.bytes))
        } catch {
            throw .json(FormatError.jsonMessage(error))
        }
    }

    /// Decodes layers one at a time, group children first.
    static func layersFrom(_ values: [JSONTree]) throws(FormatError) -> [LayerM] {
        var out: [LayerM] = []
        out.reserveCapacity(values.count)
        for v in values {
            var v = v
            let children = try layersFrom(take(&v, "content", "children"))
            out.append(try layerFrom(v, children))
        }
        return out
    }

    /// One layer without its children (out of line, so its large locals stay off the recursion).
    @inline(never)
    static func layerFrom(_ v: JSONTree, _ children: [LayerM]) throws(FormatError) -> LayerM {
        var layer: LayerM = try decodeValue(v)
        if case .group(var g) = layer.content {
            g.children = children
            layer.content = .group(g)
        }
        return layer
    }

    /// Takes the array at `a`/`b` out of `v`, leaving an empty one (nothing if absent or not an
    /// array).
    static func take(_ v: inout JSONTree, _ a: String, _ b: String) -> [JSONTree] {
        guard case .array(let arr) = v[a][b] else { return [] }
        v[a][b] = .array([])
        return arr
    }
}
