// `ps-oracle bisect`: why does Photoshop reject a file? Writes variants of it — each top-level layer
// node on its own, no layers at all, each global block dropped, each image resource dropped — and
// asks Photoshop to open every one. The variants that open (or still fail) name the culprit.

import Foundation
import PCPSD

public enum Bisect {
    public struct Variant {
        public var name: String
        public var description: String
        public var url: URL
    }

    static func describe(_ f: PSDFile, _ node: PSDLayerNode) -> String {
        let r = f.layers[node.index]
        return "\(r.displayName) (\(r.kind)\(node.isGroup ? ", \(node.count - 1) inside" : ""), records \(node.recordIndices.map(String.init).joined(separator: ",")))"
    }

    /// Writes the variants of `url` into `dir`.
    public static func variants(of url: URL, into dir: URL) throws -> [Variant] {
        let f = try PSDFile(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        var out: [Variant] = []
        func write(_ name: String, _ description: String, _ g: PSDFile) throws {
            let u = dir.appendingPathComponent("\(name).\(ext)")
            try g.write(to: u)
            out.append(Variant(name: name, description: description, url: u))
        }
        if var info = f.layerInfo {
            let tree = f.layerTree()
            for (k, node) in tree.enumerated() {
                var g = f
                info.layers = node.recordIndices.map { f.layers[$0] }
                try info.pad(to: 4, version: f.header.version)
                g.layerInfo = info
                try write(String(format: "isolate-%03d", k), "only top-level node \(k): \(describe(f, node))", g)
            }
            var g = f
            g.layerInfo = nil
            if case .globalBlock = f.layerInfoPlacement { g.layerInfoPlacement = .section }
            try write("no-layers", "no layer records (merged image only)", g)
        }
        for (i, b) in f.globalBlocks.enumerated() {
            var g = f
            g.globalBlocks.remove(at: i)
            if case let .globalBlock(index, sig, key, pad, over) = f.layerInfoPlacement, index > i {
                g.layerInfoPlacement = .globalBlock(index: index - 1, signature: sig, key: key, padding: pad, longLengthOverride: over)
            }
            try write(String(format: "drop-global-%02d-%@", i, b.key.string.trimmingCharacters(in: .whitespaces)), "without global block \(b.key.string)", g)
        }
        for (i, r) in f.resources.enumerated() {
            var g = f
            g.resources.remove(at: i)
            try write("drop-resource-\(r.id)", "without image resource \(r.id)", g)
        }
        return out
    }
}
