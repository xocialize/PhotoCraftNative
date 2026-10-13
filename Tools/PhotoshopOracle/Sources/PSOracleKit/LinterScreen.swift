// Pre-screen 4 (offline, before any open): PCPSD linter rules whose files Photoshop 27.11 is proven
// to refuse, so they are not opened just to be refused again.
//
// patternTransparencyInUserMask (AB-L-0258): pattern data (`Patt`/`Pat2`/`Pat3`) keeping its
// transparency in the user-mask array (slot 24). It flags all 40 PCIO exports refused for pattern
// data and none of the 2,064 files Photoshop opened; all 33 exports with it in the sheet mask
// (slot 25) opened.
// placedLayerWithoutLinkedData, placedLayerDataUnreadable, linkedFileKindMismatch: the causes the
// C′ bisect proved (RESULTS.md §C′). PCPSD calibrated them at 0 hits on ps-corpus (155), Unity,
// pcpsd-fixtures and every file Photoshop opened in C, C′ and C″.
// fillLayerDataUnreadable: an empty or unparseable `SoCo` (C′ bisect B2 opened, B3 refused). The
// rule also warns on `GdFl`/`PtFl` (unmeasured), so only its errors are screened. With it the error
// rules flag all 6 files Photoshop refused in C″ and none of the 1,475 it opened.
// vectorMaskWithoutPaths stays out: Photoshop opens path-less vector masks.

import Foundation
import PCPSD

public enum LinterScreen {
    /// The screened rules and the quarantine reason for each.
    public static let rules: [PSDCompatibilityRule: String] = [
        .patternTransparencyInUserMask: "pattern transparency in the user-mask array, slot 24 (known refusal class, AB-L-0258)",
        .placedLayerWithoutLinkedData: "placed layer without its linked-file data (known refusal class, C′ bisect A1)",
        .placedLayerDataUnreadable: "placed-layer data that does not parse (known refusal class, C′ bisect C1)",
        .linkedFileKindMismatch: "linked-file item whose kind does not match its layout (known refusal class, C′ bisect D1)",
        .fillLayerDataUnreadable: "empty or unparseable solid-colour fill block SoCo (known refusal class, C′ bisect B2/B3)",
    ]

    /// Why Photoshop is expected to refuse `f`, or nil.
    public static func violation(_ f: PSDFile) -> String? {
        for issue in f.compatibilityIssues() {
            // Errors only: a rule can also carry unmeasured warnings (fillLayerDataUnreadable on GdFl/PtFl).
            if issue.severity == .error, let r = issue.rule, let why = rules[r] { return "\(why): \(issue.description)" }
        }
        return nil
    }
}
