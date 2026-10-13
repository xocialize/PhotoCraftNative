// Offline explanations for files Photoshop refuses, from the causes this oracle has proven (each
// with Photoshop opens of minimal variants; RESULTS.md). `ps-oracle explain` runs them over a
// sweep's refusals, so new opens are spent only on what stays unexplained.

import Foundation
import PCPSD

public enum KnownCauses {
    public static func explain(_ f: PSDFile, blendTable: BlendTable?) -> [String] {
        var out: [String] = []
        // Proven: Lr16/Lr32 before the Mt16/Mt32 matte block (variants A–E).
        if case let .globalBlock(index, _, key, _, _) = f.layerInfoPlacement,
           let m = f.globalBlocks.firstIndex(where: { $0.key == "Mt16" || $0.key == "Mt32" }), m >= index {
            out.append("matte order: \(key.string) placed before \(f.globalBlocks[m].key.string) (Photoshop needs the matte block first)")
        }
        if let why = CrashSignatures.match(f) { out.append(why) }
        if let t = blendTable, let why = t.violation(f) { out.append(why) }
        for (i, r) in f.layers.enumerated() {
            // Proven: a grdm block whose length is not a multiple of 4 (PCIO's own block + 2 zero bytes opens).
            if let g = r.block("grdm"), g.data.count % 4 != 0 { out.append("grdm length \(g.data.count) not a multiple of 4 (layer #\(i))") }
            // Proven by bisect: a 4-byte selc (Photoshop's is 84).
            if let s = r.block("selc"), s.data.count < 84 { out.append("selc block \(s.data.count) bytes (Photoshop's is 84) (layer #\(i))") }
            if r.block("PtFl") != nil || r.block("vscg").map({ PSDHeaderedDescriptor.fillKeyIsPattern($0) }) == true {
                let hasPatterns = f.globalBlocks.contains { ["Patt", "Pat2", "Pat3"].contains($0.key.string) && !$0.data.isEmpty }
                if !hasPatterns { out.append("pattern fill without embedded pattern data (no non-empty Patt/Pat2/Pat3) (layer #\(i))") }
            }
        }
        // Proven by bisect: a CAI block that is not Photoshop's versioned descriptor; an unreadable Anno.
        if let c = f.globalBlocks.first(where: { $0.key == "CAI " }), !c.data.starts(with: [0, 0, 0, 3]) { out.append("CAI block is not a Photoshop CAI descriptor") }
        if let a = f.globalBlocks.first(where: { $0.key == "Anno" }), (try? a.parsed()) == nil, a.data.count < 8 || a.data.prefix(2) != Data([0, 2]) {
            out.append("Anno block unreadable")
        }
        // Proven by bisect (opens without it): a Txt2 written by PCIO. Probable for every General
        // Photoshop error refusal of a file carrying Txt2 that Photoshop did not write.
        return out
    }
}

extension PSDHeaderedDescriptor {
    static func fillKeyIsPattern(_ b: PSDTaggedBlock) -> Bool {
        (try? PSDHeaderedDescriptor(bytes: b.data))?.fillKey == "PtFl"
    }
}
