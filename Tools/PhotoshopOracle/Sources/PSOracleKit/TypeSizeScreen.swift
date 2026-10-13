// Pre-screen 3 (offline, before any open): type layers whose sizes Photoshop cannot read. Photoshop
// 27.11 turned a type layer with a 1e30 pt run into an empty pixel layer (20 s open), and one with a
// Double.greatestFiniteMagnitude run and transform raised "Some of the type layers in this document
// were rasterized because an error prevented them from being read" (a modal; RESULTS.md, C′).
//
// The bounds are Photoshop's own type-size limits (0.01–1296 pt) and its largest canvas side
// (300,000 px) for the transform. Calibration: no type layer Photoshop wrote (ps-corpus, the Unity
// corpus) or opened and kept as type (PCIO sweeps) comes near them; those lie within 5.5–130 pt,
// a transform scale of 0.47–1.36 and transform components of at most 311.

import Foundation
import PCPSD

public enum TypeSizeScreen {
    public static let reason = "type size outside Photoshop's range (type-layer rasterize modal class)"
    public static let minPoints = 0.01
    public static let maxPoints = 1296.0
    public static let maxTransform = 300_000.0

    /// Why `f` is expected to have Photoshop rasterize a type layer (with a modal), or nil.
    public static func violation(_ f: PSDFile) -> String? {
        for (i, r) in f.layers.enumerated() {
            guard let block = r.block("TySh"), let t = try? PSDTypeTool(bytes: block.data) else { continue }
            if let why = violation(t) { return "\(reason): type layer #\(i) \"\(r.displayName)\" \(why)" }
        }
        return nil
    }

    static func inRange(_ v: Double) -> Bool { v.isFinite && v >= minPoints && v <= maxPoints }

    /// The first out-of-range value of one type layer: a transform component, a run or style-sheet
    /// FontSize, or a run's effective size (FontSize x the transform's scale, sqrt |det|).
    public static func violation(_ t: PSDTypeTool) -> String? {
        let m = t.transform
        if let bad = m.first(where: { !$0.isFinite || abs($0) > maxTransform }) {
            return "transform component \(bad) (limit ±\(Int(maxTransform)))"
        }
        let scale = m.count >= 4 ? abs(m[0] * m[3] - m[1] * m[2]).squareRoot() : 1
        guard let e = t.engineData else { return nil } // pre-screen 1's case
        var sizes: [(String, Double)] = []
        for (j, run) in (e.path("EngineDict", "StyleRun", "RunArray")?.array ?? []).enumerated() {
            if let s = run.path("StyleSheet", "StyleSheetData", "FontSize")?.double { sizes.append(("style run \(j)", s)) }
        }
        let runs = sizes.count
        for res in ["ResourceDict", "DocumentResources"] {
            for (j, sheet) in (e.path(res, "StyleSheetSet")?.array ?? []).enumerated() {
                if let s = sheet.path("StyleSheetData", "FontSize")?.double { sizes.append(("\(res) style sheet \(j)", s)) }
            }
        }
        for (what, s) in sizes where !inRange(s) {
            return "FontSize \(s) pt (\(what)) outside [\(minPoints), \(Int(maxPoints))]"
        }
        for (what, s) in sizes.prefix(runs) where !inRange(s * scale) {
            return "effective size \(s * scale) pt (\(what): FontSize \(s) x transform scale \(scale)) outside [\(minPoints), \(Int(maxPoints))]"
        }
        return nil
    }
}
