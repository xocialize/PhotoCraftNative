// Offline pre-screen for files known to crash Photoshop 27.11, checked before any open. Each
// signature comes from crashes seen in this oracle's runs (RESULTS.md, "Crashes").

import Foundation
import PCPSD

public enum CrashSignatures {
    /// EngineData structures every type layer Photoshop 27.11 opened had (478/478), all of which
    /// the three files that crashed it (EXC_BAD_ACCESS, null read, inside `app.open`) lacked: the
    /// nine structures of PCIO's `PSDText.buildEngineData` (photocraft `build_engine_data`) plus
    /// `FontSet[].FontType`. Same rule as PCPSD's coming `missingPhotoshopStructures()`.
    public static let requiredEngineData = [
        "DocumentResources", "EngineDict.Rendered.Version", "EngineDict.Rendered.Shapes.WritingDirection",
        "EngineDict.Rendered.Shapes.Children[].Lines", "EngineDict.Rendered.Shapes.Children[].Procession",
        "EngineDict.Rendered.Shapes.Children[].Cookie.Photoshop.Base", "EngineDict.AntiAlias", "EngineDict.UseFractionalGlyphWidths",
        "EngineDict.ParagraphRun.RunArray[].ParagraphSheet.DefaultStyleSheet", "ResourceDict.FontSet[].FontType",
    ]

    public static let reason = "incomplete EngineData (known Photoshop crash class)"

    static func paths(_ e: PSDEngineData, _ prefix: String = "", into out: inout Set<String>) {
        switch e {
        case let .dict(items):
            for it in items {
                let p = prefix.isEmpty ? it.key : prefix + "." + it.key
                out.insert(p)
                paths(it.value, p, into: &out)
            }
        case let .array(a):
            for x in a { paths(x, prefix + "[]", into: &out) }
        default: break
        }
    }

    /// Why opening `f` is expected to crash Photoshop (or make it refuse the file), or nil. Uses
    /// PCPSD's own definition (`PSDTypeTool.photoshopStructureGaps()`), shared with the writers.
    public static func match(_ f: PSDFile) -> String? {
        for (i, r) in f.layers.enumerated() {
            guard let block = r.block("TySh") else { continue }
            let gaps: [PSDEngineDataGap]
            do { gaps = try PSDTypeTool(bytes: block.data).photoshopStructureGaps() } catch {
                return "\(reason): type layer #\(i) \"\(r.displayName)\" TySh does not parse (\(error))"
            }
            guard !gaps.isEmpty else { continue }
            let crash = gaps.filter { $0.consequence == .crashesPhotoshop }.map(\.path)
            let refuse = gaps.filter { $0.consequence == .photoshopRefusesFile }.map(\.path)
            let what = crash.isEmpty ? "refuse class: \(refuse.joined(separator: ", "))" : "crash class: \(crash.prefix(6).joined(separator: ", "))\(crash.count > 6 ? " … (\(crash.count))" : "")"
            return "\(reason): type layer #\(i) \"\(r.displayName)\" lacks \(what)"
        }
        return nil
    }
}
