// Offline pattern checks (AB-L-0258): which exports carry transparent patterns and where, and what
// the placeholder `Patt` fixtures hold. Opt-in (PSO_PATTERN_DIAG=1).

import Foundation
import Testing
import PCPSD
@testable import PSOracleKit

@Suite struct PatternDiagTests {
    static let scratch = Fixtures.path

    static func patternBlocks(_ f: PSDFile) -> [PSDTaggedBlock] {
        let keys: Set<String> = ["Patt", "Pat2", "Pat3"]
        return (f.globalBlocks + f.layers.flatMap(\.blocks)).filter { keys.contains($0.key.string) }
    }

    @Test(.enabled(if: Fixtures.optIn("PSO_PATTERN_DIAG"), Fixtures.reason("PSO_PATTERN_DIAG"))) func transparentPatterns() throws {
        for dir in ["/ps-oracle/pcio-snapshot-c2", "/pcpsd-fixtures", "/ps-corpus", "/psd-corpus"] {
            var lines: [String] = []
            for u in Sweep.files(in: URL(fileURLWithPath: Self.scratch + dir)) {
                guard let f = try? PSDFile(contentsOf: u) else { continue }
                let blocks = Self.patternBlocks(f)
                guard !blocks.isEmpty else { continue }
                let userMask = f.compatibilityIssues().contains { $0.rule == .patternTransparencyInUserMask }
                for b in blocks {
                    let ps = (try? PSDPattern.parseBlock(b.data)) ?? []
                    for p in ps where p.alpha != nil || dir.contains("corpus") {
                        lines.append("\(b.key.string) depth \(p.depth) mode \(p.mode) doc \(f.header.depth)-bit \(p.alpha == nil ? "opaque" : userMask ? "SLOT24" : "slot25") \(u.lastPathComponent)")
                    }
                }
            }
            let summary = Dictionary(grouping: lines, by: { $0.components(separatedBy: " ").prefix(8).joined(separator: " ") }).mapValues(\.count)
            print("PAT \(dir): \(lines.count) transparent patterns")
            for (k, v) in summary.sorted(by: { $0.key < $1.key }) { print("PAT   \(v) × \(k)") }
            for l in lines where l.hasPrefix("Pat3") { print("PAT3 \(dir) \(l)") }
        }
    }

    @Test(.enabled(if: Fixtures.optIn("PSO_PATTERN_DIAG"), Fixtures.reason("PSO_PATTERN_DIAG"))) func placeholderPatt() throws {
        let sc = Self.scratch
        func rows(_ p: String) -> [SweepRow] { (try? JSONDecoder().decode([SweepRow].self, from: Data(contentsOf: URL(fileURLWithPath: sc + p)))) ?? [] }
        for (json, dir) in [("/ps-oracle/pcio/pcio.json", "/ps-oracle/pcio-snapshot"), ("/ps-oracle/pcio-c2/pcio-c2.json", "/ps-oracle/pcio-snapshot-c2")] {
            for r in rows(json) {
                guard let f = try? PSDFile(contentsOf: URL(fileURLWithPath: sc + dir + "/" + r.file)) else { continue }
                let blocks = Self.patternBlocks(f).filter { (try? PSDPattern.parseBlock($0.data))?.isEmpty ?? true }
                guard !blocks.isEmpty else { continue }
                let what = blocks.map { "\($0.key.string)(\($0.data.count)) \($0.data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))" }.joined(separator: ", ")
                let issues = f.compatibilityIssues().filter { $0.message.contains("Patt") || $0.message.contains("pattern") || $0.message.contains("lnk2") }.map(\.description)
                print("PLACEHOLDER \(json.split(separator: "/")[1]) \(r.opened ? "OPENED" : "not opened: \((r.photoshopError ?? "").prefix(50))") \(r.file): \(what) \(issues)")
            }
        }
    }
}
