// `ps-oracle structure`: a Photoshop-free outline of how a PSD/PSB is laid out (header, colour-mode
// data, resources, where the layer info lives, global blocks, per-record flags and blocks), for
// diffing a file Photoshop rejects against one Photoshop wrote.

import Foundation
import PCPSD

public enum Structure {
    public static func outline(_ f: PSDFile) -> String {
        var s: [String] = []
        let h = f.header
        s.append("header: \(h.version) \(PCPSDFacts.modeName(h.colorMode)) \(h.depth)-bit \(h.width)x\(h.height), \(h.channels) channels")
        s.append("color mode data: \(f.colorModeData.count) bytes" + (f.colorModeData.isEmpty ? "" : " [\(f.colorModeData.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))…]"))
        s.append("resources: " + f.resources.map { "\($0.id)(\($0.data.count))" }.joined(separator: " "))
        switch f.layerInfoPlacement {
        case .section: s.append("layer info: in the layer section")
        case let .globalBlock(index, signature, key, padding, _): s.append("layer info: global block #\(index) \(signature.string)/\(key.string) padding \(padding.map { "\($0)" } ?? "default")")
        }
        if let li = f.layerInfo { s.append("layer count: \(li.layers.count), merged alpha flag (negative count): \(li.mergedAlpha), padding \(li.padding.map { "\($0)" } ?? "nil")") }
        s.append("global layer mask: \(f.globalLayerMask.map { "\($0.data.count) bytes" } ?? "absent")")
        s.append("global blocks: " + f.globalBlocks.map { "\($0.key.string)(\($0.data.count))" }.joined(separator: " "))
        s.append("merged image: \(f.imageData.compression), real \(f.hasRealMergedData.map { "\($0)" } ?? "?"), alpha \(f.mergedHasAlpha)")
        for (i, r) in f.layers.enumerated() {
            if let m = r.layerMask {
                s.append("  #\(i) mask: rect \(m.rect) default \(m.defaultColor) flags 0x\(String(m.flags, radix: 16))\(m.cameFromRendering ? " (came from rendering)" : "")\(m.isDisabled ? " (disabled)" : "") parameters \(m.parameters.map { "\($0)" } ?? "-") real \(m.real.map { "rect \($0.rect) flags 0x\(String($0.flags, radix: 16)) bg \($0.background)" } ?? "-")")
            }
            let simple = r.blocks.filter { ["knko", "infx", "clbl", "tsly", "lmgm", "vmgm", "iOpa", "brst"].contains($0.key.string) }
                .map { b in "\(b.key.string)=\((try? b.parsed()).flatMap { $0 }.map { "\($0)" } ?? b.data.map { String($0) }.joined(separator: "."))" }
            let br = r.blendingRanges.ranges.filter { $0.source != [0, 0, 255, 255] || $0.destination != [0, 0, 255, 255] }
            if !simple.isEmpty || !br.isEmpty {
                s.append("  #\(i) options: " + simple.joined(separator: " ") + (br.isEmpty ? "" : " blend-if \(br.map { "src \($0.source) dst \($0.destination)" })"))
            }
            s.append("  #\(i) \(r.displayName) kind \(r.kind) flags 0x\(String(r.flags.rawValue, radix: 16)) blend \(r.blendMode.key.string) opacity \(r.opacity) clip \(r.clipping) rect \(r.rect) channels \(r.channels.map { "\($0.id):\($0.compression.map { "\($0)" } ?? "?")" }.joined(separator: ",")) br \(r.blendingRanges.data.count) blocks " + r.blocks.map { "\($0.key.string)(\($0.data.count))" }.joined(separator: " "))
        }
        return s.joined(separator: "\n")
    }
}
