// Prints the descriptor-based layer blocks of one file (PSO_DESC_FILE; PSO_DESC_KEY, default CgEd),
// plus the binary `brit` block, to see what Photoshop stored. Opt-in.

import Foundation
import Testing
import PCPSD
@testable import PSOracleKit

@Suite struct DescriptorDumpTests {
    static func dump(_ v: PSDDescriptor.Value, _ indent: String, into out: inout [String]) {
        if let d = v.descriptor {
            out.append("\(indent)<\(d.classID)>")
            for it in d.items { out.append("\(indent)  \(it.key) [\(it.value.ostype)]"); dump(it.value, indent + "    ", into: &out) }
        } else if let l = v.list {
            for x in l { dump(x, indent + "- ", into: &out) }
        } else if let n = v.number { out.append("\(indent)\(n)") }
        else if let b = v.bool { out.append("\(indent)\(b)") }
        else if let t = v.text { out.append("\(indent)\"\(t)\"") }
        else if let e = v.enumValue { out.append("\(indent)enum \(e)") }
        else { out.append("\(indent)(\(v.ostype))") }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PSO_DESC_FILE"] != nil)) func dumpDescriptors() throws {
        let env = ProcessInfo.processInfo.environment
        let key = env["PSO_DESC_KEY"] ?? "CgEd"
        for path in env["PSO_DESC_FILE"]!.split(separator: ":") {
            let f = try PSDFile(contentsOf: URL(fileURLWithPath: String(path)))
            for (i, r) in f.layers.enumerated() {
                if let b = r.block("brit") { print("DESC \(path.split(separator: "/").last!) #\(i) brit \(b.data.map { String(format: "%02x", $0) }.joined(separator: " "))") }
                guard let b = r.block(FourCC(stringLiteral: key)) else { continue }
                let vd: PSDVersionedDescriptor
                var head = ""
                if let v = try? PSDVersionedDescriptor(bytes: b.data) { vd = v } else {
                    let h = try PSDHeaderedDescriptor(bytes: b.data)
                    vd = h.descriptor
                    head = "header \(h.header) tail \(h.tail.count) "
                }
                var out: [String] = []
                Self.dump(.descriptor(vd.descriptor), "", into: &out)
                print("DESC \(path.split(separator: "/").last!) #\(i) \(r.displayName) \(key) \(head)v\(vd.version)\n" + out.joined(separator: "\n"))
            }
        }
    }
}

@Suite struct VectorMaskRuleTests {
    /// The path-less-vmsk rule against every Photoshop-written vector mask (none may be path-less)
    /// and the C′ file it was made for.
    @Test(.enabled(if: Fixtures.optIn("PSO_TYPE_DIAG"), Fixtures.reason("PSO_TYPE_DIAG"))) func pathlessVectorMasks() throws {
        let sc = Fixtures.path
        var withPaths = 0, pathless: [String] = []
        for u in Sweep.files(in: URL(fileURLWithPath: sc + "/ps-corpus")) + Sweep.files(in: URL(fileURLWithPath: sc + "/psd-corpus")) {
            guard let f = try? PSDFile(contentsOf: u) else { continue }
            for r in f.layers { if let v = r.vectorMask { if v.path.records.isEmpty { pathless.append(u.lastPathComponent) } else { withPaths += 1 } } }
        }
        print("VMSK Photoshop-written vector masks with path records \(withPaths), without \(pathless)")
        let f = try PSDFile(contentsOf: URL(fileURLWithPath: sc + "/ps-oracle/pcio-snapshot-c2/synthetic-rasterLayerBlocksPreserved-5848b4af0b.psd"))
        let facts = PCPSDFacts.layers(f)
        print("VMSK rasterLayerBlocksPreserved layer 1 vectorMask \(facts.count > 1 ? "\(facts[1].vectorMask)" : "?")")
        #expect(pathless.isEmpty)
    }
}

@Suite struct LUTProbeTests {
    /// Is the probe's composite the Base layer over the Background (i.e. the Color Lookup did
    /// nothing)? Opt-in: PSO_LUT_PROBE=<dir with lut-probe-cube.psd/.tif>.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PSO_LUT_PROBE"] != nil)) func compositeAgainstBase() throws {
        let dir = ProcessInfo.processInfo.environment["PSO_LUT_PROBE"]!
        let f = try PSDFile(contentsOf: URL(fileURLWithPath: dir + "/lut-probe-cube.psd"))
        let tif = try ReferenceImageReader.read(contentsOf: URL(fileURLWithPath: dir + "/lut-probe-cube.tif"))
        let bg = try f.layer(0)!.rgba8(), base = try f.layer(1)!.rgba8()
        let w = Int(f.header.width), h = Int(f.header.height)
        var worst = 0.0, differing = 0
        for y in 0 ..< h {
            for x in 0 ..< w {
                func px(_ im: PSDRGBA8Image) -> [Double] {
                    let lx = x - Int(im.left), ly = y - Int(im.top)
                    guard lx >= 0, ly >= 0, lx < im.width, ly < im.height else { return [0, 0, 0, 0] }
                    let o = (ly * im.width + lx) * 4
                    return (0 ..< 4).map { Double(im.data[o + $0]) }
                }
                let b = px(bg), t = px(base), a = t[3] / 255
                for c in 0 ..< 3 {
                    let want = (t[c] * a + b[c] * (1 - a)).rounded()
                    let d = abs(tif.planes[c][y * w + x] - want)
                    if d > 1 { differing += 1 }
                    worst = max(worst, d)
                }
            }
        }
        print("LUTPROBE composite vs Base over Background: worst \(worst) levels, samples differing by more than 1: \(differing) of \(w * h * 3)")
    }
}
