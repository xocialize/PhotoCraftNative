// Aggregate Dissolve comparisons between M2 composites (no per-pixel data is written). Opt-in
// (PSO_M2_DIR=<batch dir>).

import Foundation
import Testing
@testable import PSOracleKit

@Suite struct DissolveAggregateTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PSO_M2_DIR"] != nil)) func samePattern() throws {
        let dir = ProcessInfo.processInfo.environment["PSO_M2_DIR"]!
        func red(_ id: String) throws -> [Bool] { try ReferenceImageReader.read(contentsOf: URL(fileURLWithPath: "\(dir)/tif/\(id).tif")).planes[1].map { $0 < 128 } }
        let o50 = try red("dissolve-o50")
        for id in ["dissolve-fill50", "dissolve-mask50", "dissolve-o45", "dissolve-o55"] {
            let other = try red(id)
            let same = zip(o50, other).filter { $0 == $1 }.count
            let nested = zip(o50, other).filter { $0.0 != $0.1 }.allSatisfy { a, b in id == "dissolve-o45" ? (a && !b) : id == "dissolve-o55" ? (!a && b) : true }
            print("DISSOLVE \(id) vs o50: equal \(Double(same) / Double(o50.count)); differences all one way (nested thresholds): \(nested)")
        }
    }
}
