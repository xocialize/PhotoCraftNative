// Writes PCIO's proposed single-edit variants (A1–A3, B1–B3, C1–C3, D1–D3) of the 7 C′ files
// Photoshop refused, for `ps-oracle try-variants`. Opt-in: PSO_REFUSAL_VARIANTS_OUT=<dir>.

import Foundation
import Testing
import PCPSD
@testable import PSOracleKit

@Suite struct RefusalVariantTests {
    static let snap = Fixtures.path + "/ps-oracle/pcio-snapshot-c2/"
    static let corpus = Fixtures.path + "/ps-corpus/"

    static func u64(_ d: [UInt8], _ o: Int) -> Int { (0 ..< 8).reduce(0) { $0 << 8 | Int(d[o + $1]) } }
    static func be64(_ v: Int) -> [UInt8] { (0 ..< 8).map { UInt8(truncatingIfNeeded: v >> (56 - 8 * $0)) } }

    /// The items of a `lnk2` block: (offset of the length word, total bytes incl. length and pad).
    static func lnk2Items(_ d: [UInt8]) -> [(offset: Int, length: Int, size: Int)] {
        var out: [(Int, Int, Int)] = []
        var o = 0
        while o + 8 <= d.count {
            let n = u64(d, o)
            guard n > 0, o + 8 + n <= d.count else { break }
            var size = 8 + n
            while size % 4 != 0 { size += 1 }
            out.append((o, n, size))
            o += size
        }
        return out
    }

    /// The uuid (Pascal string) of a `PlLd` block.
    static func placedUUID(_ b: PSDTaggedBlock) -> [UInt8] {
        let d = [UInt8](b.data)
        let n = Int(d[8])
        return Array(d[9 ..< 9 + n])
    }

    /// One `lnk2` item with its uuid replaced (lengths rebuilt).
    static func item(_ d: [UInt8], _ it: (offset: Int, length: Int, size: Int), uuid: [UInt8]) -> [UInt8] {
        let body = Array(d[it.offset + 8 ..< it.offset + 8 + it.length])
        let oldLen = Int(body[8])
        let nb = Array(body[0 ..< 8]) + [UInt8(uuid.count)] + uuid + Array(body[(9 + oldLen)...])
        var out = be64(nb.count) + nb
        while out.count % 4 != 0 { out.append(0) }
        return out
    }

    static func write(_ f: PSDFile, _ dir: URL, _ name: String) throws {
        var g = f
        if var info = g.layerInfo {
            try info.pad(to: 4, version: g.header.version)
            g.layerInfo = info
        }
        try g.write(to: dir.appendingPathComponent(name))
        print("VARIANT \(name)")
    }

    static func removeBlocks(_ f: inout PSDFile, record: Int, keys: Set<String>) {
        f.layers[record].blocks.removeAll { keys.contains($0.key.string) }
    }

    @Test(.enabled(if: Fixtures.optIn("PSO_REFUSAL_VARIANTS_OUT"), Fixtures.reason("PSO_REFUSAL_VARIANTS_OUT"))) func writeVariants() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PSO_REFUSAL_VARIANTS_OUT"]!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let smart = try PSDFile(contentsOf: URL(fileURLWithPath: Self.corpus + "smart-object.psd"))
        let shape = try PSDFile(contentsOf: URL(fileURLWithPath: Self.corpus + "shape-rect.psd"))
        let smartRec = try #require(smart.layers.first { $0.block("SoLd") != nil })
        let shapeRec = try #require(shape.layers.first { $0.block("SoCo") != nil })

        // A: placedLayerBlocksKeepTheirKeys — the placed layer (record #4) has no linked data.
        for name in ["synthetic-placedLayerBlocksKeepTheirKeys-0ddc3c139b", "synthetic-placedLayerBlocksKeepTheirKeys-6ef8c594b9"] {
            let f = try PSDFile(contentsOf: URL(fileURLWithPath: Self.snap + name + ".psd"))
            let i = try #require(f.layers.firstIndex { $0.block("PlLd") != nil })
            var a1 = f
            a1.layers.remove(at: i)
            try Self.write(a1, out, "A1-" + name + ".psd")
            let uuid = Self.placedUUID(f.layers[i].block("PlLd")!)
            let lnk = [UInt8](try #require(smart.globalBlocks.first { $0.key == "lnk2" }).data)
            let items = Self.lnk2Items(lnk)
            let newItem = Self.item(lnk, items[0], uuid: uuid)
            var a2 = f
            a2.globalBlocks.append(PSDTaggedBlock(key: "lnk2", data: Data(newItem)))
            try Self.write(a2, out, "A2-" + name + ".psd")
            var a3 = a2
            let sold = [UInt8](smartRec.block("SoLd")!.data)
            let (vd, used) = try PSDVersionedDescriptor.parsePrefix(Data(sold[8...]))
            var d = vd
            let old = d.descriptor["Idnt"]?.text ?? ""
            let nul = old.hasSuffix("\u{0}")
            d.descriptor.set("Idnt", .text(PSDUnicodeString(String(decoding: uuid, as: UTF8.self) + (nul ? "\u{0}" : ""))))
            let newSold = Array(sold[0 ..< 8]) + [UInt8](d.serialized()) + Array(sold[(8 + used)...])
            a3.layers[i].setBlock(PSDTaggedBlock(key: "SoLd", data: Data(newSold)))
            try Self.write(a3, out, "A3-" + name + ".psd")
            print("A uuid \(String(decoding: uuid, as: UTF8.self)) lnk2 items in smart-object.psd \(items.count); Idnt was \(old.count) chars")
        }

        // B: vectorRenderedMaskNotDoubledOnShapes — a 0-byte SoCo on the shape layer.
        for name in ["synthetic-vectorRenderedMaskNotDoubledOnShapes-4e72e7e793", "synthetic-vectorRenderedMaskNotDoubledOnShapes-f9d8020237"] {
            let f = try PSDFile(contentsOf: URL(fileURLWithPath: Self.snap + name + ".psd"))
            let i = try #require(f.layers.firstIndex { $0.block("SoCo") != nil })
            var b1 = f
            Self.removeBlocks(&b1, record: i, keys: ["SoCo", "vmsk"])
            try Self.write(b1, out, "B1-" + name + ".psd")
            var b2 = f
            b2.layers[i].setBlock(shapeRec.block("SoCo")!)
            try Self.write(b2, out, "B2-" + name + ".psd")
            var b3 = f
            b3.layers[i].setBlock(shapeRec.block("vmsk")!)
            try Self.write(b3, out, "B3-" + name + ".psd")
        }

        // C: textShapeSmartRawBlocksSurvive — stand-in raw blocks on #41/#42.
        do {
            let name = "synthetic-textShapeSmartRawBlocksSurvive-562681b0c1"
            let f = try PSDFile(contentsOf: URL(fileURLWithPath: Self.snap + name + ".psd"))
            let s = try #require(f.layers.firstIndex { $0.block("PlLd") != nil })
            let v = try #require(f.layers.firstIndex { $0.block("vscg") != nil })
            var c1 = f
            Self.removeBlocks(&c1, record: s, keys: ["PlLd"])
            try Self.write(c1, out, "C1-" + name + ".psd")
            var c2 = f
            Self.removeBlocks(&c2, record: v, keys: ["vscg"])
            try Self.write(c2, out, "C2-" + name + ".psd")
            var c3 = f
            for k in c3.layers.indices { Self.removeBlocks(&c3, record: k, keys: ["vmsk"]) }
            try Self.write(c3, out, "C3-" + name + ".psd")
            print("C records PlLd #\(s) vscg #\(v)")
        }

        // D: independentUnavailableLink… — an liFD item relabelled liFE, and its clone.
        for name in ["synthetic-independentUnavailableLinkRetainsSeparatePreservedRecord-4eac7886eb", "synthetic-independentUnavailableLinkRetainsSeparatePreservedRecord-5e9454b392"] {
            let f = try PSDFile(contentsOf: URL(fileURLWithPath: Self.snap + name + ".psd"))
            let gi = try #require(f.globalBlocks.firstIndex { $0.key == "lnk2" })
            let lnk = [UInt8](f.globalBlocks[gi].data)
            let items = Self.lnk2Items(lnk)
            print("D \(name) lnk2 items \(items.map { "\($0.offset)+\($0.size) \(String(decoding: lnk[$0.offset + 8 ..< $0.offset + 12], as: UTF8.self))" })")
            var d1 = f
            var bytes = lnk
            for it in items { bytes.replaceSubrange(it.offset + 8 ..< it.offset + 12, with: Array("liFD".utf8)) }
            d1.globalBlocks[gi] = PSDTaggedBlock(key: "lnk2", data: Data(bytes))
            try Self.write(d1, out, "D1-" + name + ".psd")
            var d2 = f
            if items.count >= 2 {
                d2.globalBlocks[gi] = PSDTaggedBlock(key: "lnk2", data: Data(lnk[0 ..< items[1].offset]))
                try Self.write(d2, out, "D2-" + name + ".psd")
            }
            var d3 = f
            d3.globalBlocks.remove(at: gi)
            try Self.write(d3, out, "D3-" + name + ".psd")
        }
    }
}

@Suite struct RefusalVariantFidelityTests {
    /// The unedited files written the same way come back byte for byte (so each variant differs
    /// from its source only by its edit).
    @Test(.enabled(if: Fixtures.optIn("PSO_REFUSAL_VARIANTS_OUT"), Fixtures.reason("PSO_REFUSAL_VARIANTS_OUT"))) func unchangedRewriteIsIdentical() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PSO_REFUSAL_VARIANTS_OUT"]!)
        for name in ["synthetic-placedLayerBlocksKeepTheirKeys-0ddc3c139b", "synthetic-vectorRenderedMaskNotDoubledOnShapes-4e72e7e793",
                     "synthetic-textShapeSmartRawBlocksSurvive-562681b0c1", "synthetic-independentUnavailableLinkRetainsSeparatePreservedRecord-4eac7886eb"] {
            let src = URL(fileURLWithPath: RefusalVariantTests.snap + name + ".psd")
            let f = try PSDFile(contentsOf: src)
            try RefusalVariantTests.write(f, out, "same-" + name + ".psd")
            let a = try Data(contentsOf: src), b = try Data(contentsOf: out.appendingPathComponent("same-" + name + ".psd"))
            print("FIDELITY \(name): \(a == b ? "identical" : "DIFFERS (\(a.count) vs \(b.count) bytes)")")
            try FileManager.default.removeItem(at: out.appendingPathComponent("same-" + name + ".psd"))
        }
    }
}
