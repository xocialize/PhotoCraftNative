// Pre-screen class 2: layer blend modes Photoshop does not allow for the document's colour mode and
// depth. Measured with `ps-oracle blend-table` (new documents only), not guessed. A pixel layer in
// such a mode makes Photoshop refuse the file, or raise "This file uses an unsupported blending
// mode. Substitute normal mode?" — a modal that blocks scripting despite DialogModes.NO.

import Foundation
import PCPSD

public struct BlendTable: Sendable {
    /// (mode name, depth) → allowed PSD keys, for layers and for groups.
    public var layer: [String: Set<String>] = [:]
    public var group: [String: Set<String>] = [:]
    public var layerless: [String: String] = [:]

    public static func defaultURL(_ scratch: URL) -> URL { scratch.appendingPathComponent("ps-oracle/blend-table.json") }

    static let keys: [String: String] = [
        "normal": "norm", "dissolve": "diss", "darken": "dark", "multiply": "mul ", "colorBurn": "idiv", "linearBurn": "lbrn",
        "darkerColor": "dkCl", "lighten": "lite", "screen": "scrn", "colorDodge": "div ", "linearDodge": "lddg", "lighterColor": "lgCl",
        "overlay": "over", "softLight": "sLit", "hardLight": "hLit", "vividLight": "vLit", "linearLight": "lLit", "pinLight": "pLit",
        "hardMix": "hMix", "difference": "diff", "exclusion": "smud", "blendSubtraction": "fsub", "blendDivide": "fdiv", "hue": "hue ",
        "saturation": "sat ", "color": "colr", "luminosity": "lum ", "passThrough": "pass",
    ]
    static let order = ["normal", "dissolve", "darken", "multiply", "colorBurn", "linearBurn", "darkerColor", "lighten", "screen", "colorDodge",
                        "linearDodge", "lighterColor", "overlay", "softLight", "hardLight", "vividLight", "linearLight", "pinLight", "hardMix",
                        "difference", "exclusion", "blendSubtraction", "blendDivide", "hue", "saturation", "color", "luminosity", "passThrough"]

    static func combo(_ mode: String, _ bits: Int) -> String { "\(mode) \(bits)" }

    public init(json: [String: Any]) {
        for row in (json["table"] as? [[String: Any]]) ?? [] {
            let c = Self.combo(row["mode"] as? String ?? "?", (row["bits"] as? Int) ?? Int(row["bits"] as? Double ?? 0))
            for (target, into) in [("layer", \BlendTable.layer), ("group", \BlendTable.group)] {
                let m = (row[target] as? [String: Bool]) ?? [:]
                self[keyPath: into][c] = Set(m.filter(\.value).compactMap { Self.keys[$0.key] })
            }
        }
        layerless = (json["layerless"] as? [String: String]) ?? [:]
    }

    public static func load(_ scratch: URL) -> BlendTable? {
        guard let d = try? Data(contentsOf: defaultURL(scratch)), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return BlendTable(json: j)
    }

    /// Why `f` uses a blend mode Photoshop does not allow there, or nil.
    public func violation(_ f: PSDFile) -> String? {
        let c = Self.combo(PCPSDFacts.modeName(f.header.colorMode), Int(f.header.depth))
        if !f.layers.isEmpty, let note = layerless[PCPSDFacts.modeName(f.header.colorMode)], note.hasPrefix("no layers") {
            return "blend mode invalid for document mode/depth (modal): \(c) documents cannot hold layers"
        }
        guard let allowedLayer = layer[c], let allowedGroup = group[c] else {
            return f.layers.isEmpty ? nil : "blend mode invalid for document mode/depth (modal): no measured table for \(c) documents with layers"
        }
        for (i, r) in f.layers.enumerated() {
            switch r.kind {
            case .groupEnd: continue
            case .group:
                let k = (r.sectionDivider?.blendMode ?? r.blendMode).key.string
                if !allowedGroup.contains(k) { return "blend mode invalid for document mode/depth (modal): group #\(i) \"\(r.displayName)\" uses \(k) in a \(c) document" }
            default:
                let k = r.blendMode.key.string
                if !allowedLayer.contains(k) { return "blend mode invalid for document mode/depth (modal): layer #\(i) \"\(r.displayName)\" uses \(k) in a \(c) document" }
            }
        }
        return nil
    }

    public var markdown: String {
        let combos = layer.keys.sorted { a, b in
            let order = ["RGB", "Grayscale", "CMYK", "Lab"]
            let (ma, mb) = (a.split(separator: " ")[0], b.split(separator: " ")[0])
            let (ia, ib) = (order.firstIndex(of: String(ma)) ?? 9, order.firstIndex(of: String(mb)) ?? 9)
            return ia != ib ? ia < ib : Int(a.split(separator: " ")[1])! < Int(b.split(separator: " ")[1])!
        }
        var s = "| Mode (key) | " + combos.joined(separator: " | ") + " |\n|---|" + combos.map { _ in ":---:" }.joined(separator: "|") + "|\n"
        for m in Self.order {
            let k = Self.keys[m]!
            s += "| \(m) (`\(k)`) | " + combos.map { c in
                let l = layer[c]?.contains(k) ?? false, g = group[c]?.contains(k) ?? false
                return l && g ? "✓" : l ? "layer only" : g ? "group only" : "–"
            }.joined(separator: " | ") + " |\n"
        }
        for (k, v) in layerless.sorted(by: { $0.key < $1.key }) { s += "\n\(k): \(v)" }
        return s
    }
}
