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

    // MARK: Tile lists

    static let tileListsKey = CodingUserInfoKey(rawValue: "pcraft.tileLists")!

    /// The surfaces' tile lists of one manifest being encoded (AB-T-0255). A save's manifest is mostly `{hash, tx, ty}`
    /// objects, thousands of them: through `JSONEncoder`, a `JSONTree` and the pretty text, each cost 2–3 KB while the
    /// manifest was built. `SurfaceM` hands its list here instead and encodes a placeholder string, unique to this
    /// encode; `expand` writes the lists in place of their placeholders, as `writePretty` would have.
    final class TileLists: @unchecked Sendable {
        /// Never in a document's own strings: a random UUID per encode.
        let prefix = "pcraft-tiles-\(UUID().uuidString)-"
        private(set) var lists: [[TileRef]] = []

        func placeholder(_ tiles: [TileRef]) -> String {
            lists.append(tiles)
            return prefix + String(lists.count - 1)
        }

        /// `text` (pretty, with placeholders) with each placeholder replaced by its list, written in serde_json's
        /// pretty style at the placeholder's indent: `{"hash", "tx", "ty"}` objects, keys sorted. The result is sized
        /// exactly first, so its buffer never regrows (a doubled buffer would stay with the save's manifest).
        func expand(_ text: [UInt8]) -> [UInt8] {
            if lists.isEmpty { return text }
            let quoted = Array(("\"" + prefix).utf8)
            // Where each placeholder is (its quotes included), the indent level of its line, and its list.
            var found: [(range: Range<Int>, level: Int, list: Int)] = []
            var i = 0, lineStart = 0
            let n = text.count, q = quoted.count
            while i < n {
                let b = text[i]
                if b == 0x0A { lineStart = i + 1 }
                if b == 0x22, i + q <= n, text[i ..< i + q].elementsEqual(quoted) {
                    var j = i + q, index = 0
                    while j < n, text[j] >= 0x30, text[j] <= 0x39 {
                        index = index * 10 + Int(text[j] - 0x30)
                        j += 1
                    }
                    if j < n, text[j] == 0x22, index < lists.count {
                        var spaces = 0
                        while lineStart + spaces < n, text[lineStart + spaces] == 0x20 { spaces += 1 }
                        found.append((i ..< j + 1, spaces / 2, index))
                        i = j + 1
                        continue
                    }
                }
                i += 1
            }
            var size = text.count
            for f in found { size += Self.length(lists[f.list], level: f.level) - f.range.count }
            var out: [UInt8] = []
            out.reserveCapacity(size)
            var from = 0
            for f in found {
                out.append(contentsOf: text[from ..< f.range.lowerBound])
                Self.write(lists[f.list], level: f.level, &out)
                from = f.range.upperBound
            }
            out.append(contentsOf: text[from...])
            assert(out.count == size)
            return out
        }

        /// The bytes `write` writes for `tiles` at `level`.
        static func length(_ tiles: [TileRef], level: Int) -> Int {
            if tiles.isEmpty { return 2 }
            let line = { (level: Int) in 1 + 2 * level }
            // "{" and "}" lines, the three members' lines, `"hash": ` + `,`, `"tx": ` + `,`, `"ty": `.
            let fixed = 2 * (line(level + 1) + 1) + 3 * line(level + 2) + 9 + 7 + 6
            var total = 1 + line(level) + 1 + (tiles.count - 1)
            for t in tiles {
                total += fixed + escapedLength(t.hash) + decimalLength(t.tx) + decimalLength(t.ty)
            }
            return total
        }

        /// `JSONTree.writeString`'s output length.
        static func escapedLength(_ s: String) -> Int {
            var n = 2
            for b in s.utf8 {
                switch b {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), 0x0A, 0x0D, 0x09: n += 2
                case 0 ..< 0x20: n += 6
                default: n += 1
                }
            }
            return n
        }

        static func decimalLength(_ v: Int32) -> Int {
            var m = v.magnitude, n = v < 0 ? 2 : 1
            while m >= 10 {
                m /= 10
                n += 1
            }
            return n
        }

        /// One tile list as the value of a member at `level`, as `JSONTree.render` writes an array of objects.
        static func write(_ tiles: [TileRef], level: Int, _ out: inout [UInt8]) {
            if tiles.isEmpty {
                out += [UInt8(ascii: "["), UInt8(ascii: "]")]
                return
            }
            func newline(_ level: Int) {
                out.append(0x0A)
                out.append(contentsOf: repeatElement(0x20, count: 2 * level))
            }
            func member(_ key: StaticString, _ last: Bool, _ value: (inout [UInt8]) -> Void) {
                newline(level + 2)
                out.append(UInt8(ascii: "\""))
                key.withUTF8Buffer { out.append(contentsOf: $0) }
                out += [UInt8(ascii: "\""), UInt8(ascii: ":"), 0x20]
                value(&out)
                if !last { out.append(UInt8(ascii: ",")) }
            }
            out.append(UInt8(ascii: "["))
            for (k, t) in tiles.enumerated() {
                if k > 0 { out.append(UInt8(ascii: ",")) }
                newline(level + 1)
                out.append(UInt8(ascii: "{"))
                member("hash", false) { JSONTree.writeString(t.hash, &$0) }
                member("tx", false) { $0.append(contentsOf: String(t.tx).utf8) }
                member("ty", true) { $0.append(contentsOf: String(t.ty).utf8) }
                newline(level + 1)
                out.append(UInt8(ascii: "}"))
            }
            newline(level)
            out.append(UInt8(ascii: "]"))
        }
    }

    static func tree<T: Encodable>(_ value: T, _ e: JSONEncoder) throws(FormatError) -> JSONTree {
        let data: Data
        do { data = try e.encode(value) } catch { throw .json(FormatError.jsonMessage(error)) }
        do throws(JSONTree.ParseError) { return try JSONTree.parse([UInt8](data)) } catch { throw .json(error.description) }
    }

    /// The manifest as pretty JSON text.
    static func encode(_ m: Manifest) throws(FormatError) -> [UInt8] {
        let e = encoder()
        let lists = TileLists()
        e.userInfo[tileListsKey] = lists
        var shallow = m
        shallow.document.layers = []
        var t = try tree(shallow, e)
        var layers: [JSONTree] = []
        layers.reserveCapacity(m.document.layers.count)
        for l in m.document.layers { layers.append(try layerTree(l, e)) }
        t["document"]["layers"] = .array(layers)
        var out: [UInt8] = []
        t.writePretty(&out, indent: 0)
        return lists.expand(out)
    }

    /// Where the number of `text`'s `format_version` member is, `text` being a manifest as `encode` writes it: the
    /// document's own member, a line of its own at the first level of indent (two spaces), which no nested key and
    /// nothing inside a string can be. Nil if it isn't there.
    static func formatVersionRange(_ text: [UInt8]) -> Range<Int>? {
        let key = Array("\n  \"format_version\": ".utf8)
        guard text.count >= key.count else { return nil }
        var at = text.count - key.count
        while at >= 0, !text[at ..< at + key.count].elementsEqual(key) { at -= 1 }
        guard at >= 0 else { return nil }
        let start = at + key.count
        var end = start
        while end < text.count, text[end] >= 0x30, text[end] <= 0x39 { end += 1 }
        return end > start ? start ..< end : nil
    }

    /// `text` (as for `formatVersionRange`) saying format `version`: what `encode` writes for the same manifest with
    /// that version. Nil when the number's length would change.
    static func withFormatVersion(_ text: [UInt8], _ version: UInt32) -> [UInt8]? {
        let digits = Array(String(version).utf8)
        guard let range = formatVersionRange(text), range.count == digits.count else { return nil }
        var out = text
        out.replaceSubrange(range, with: digits)
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
