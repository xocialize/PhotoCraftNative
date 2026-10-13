// The EngineData structures Photoshop requires in a type layer (`TySh`).
// Measured with Photoshop 27.11 by the port's Photoshop oracle (2026-10): every one of the 474 type
// layers Photoshop opened carried them. A `TySh` whose EngineData lacks the first group crashes
// Photoshop on open (null dereference). With that group present but the font-set fields missing,
// Photoshop no longer crashes but refuses the file. Original to this port (photocraft-text's
// writer, crates/text/src/psd.rs, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors, always emits these structures but never checks for them).

import Foundation

/// A structure missing from a type layer's EngineData, and what Photoshop does about it.
public struct PSDEngineDataGap: Hashable, Sendable, CustomStringConvertible {
    public enum Consequence: Hashable, Sendable {
        /// Photoshop crashes while opening the file (null dereference).
        case crashesPhotoshop
        /// Photoshop opens nothing: it refuses the file.
        case photoshopRefusesFile
    }

    /// Dotted path, array elements as `[i]` (`EngineDict.Rendered.Shapes.Children[0].Procession`).
    public var path: String
    public var consequence: Consequence

    public init(path: String, consequence: Consequence) {
        self.path = path
        self.consequence = consequence
    }

    public var description: String { "\(path) (\(consequence == .crashesPhotoshop ? "crashes Photoshop" : "Photoshop refuses the file"))" }
}

extension PSDEngineData {
    /// Every Photoshop-required structure this EngineData document lacks, in document order:
    /// `DocumentResources`; `EngineDict.Rendered.Version`; `Rendered.Shapes.WritingDirection`; per
    /// shape `Lines{WritingDirection, Children}`, `Procession` and
    /// `Cookie.Photoshop.Base{TransformPoint0..2}`; `EngineDict.AntiAlias`;
    /// `EngineDict.UseFractionalGlyphWidths`; each paragraph run's `ParagraphSheet.DefaultStyleSheet`
    /// (all `.crashesPhotoshop`), and `ResourceDict.FontSet[].FontType` / `Synthetic`
    /// (`.photoshopRefusesFile`). Empty for every type layer Photoshop itself writes.
    public func photoshopStructureGaps() -> [PSDEngineDataGap] {
        var gaps: [PSDEngineDataGap] = []
        func crash(_ p: String) { gaps.append(PSDEngineDataGap(path: p, consequence: .crashesPhotoshop)) }
        func refuse(_ p: String) { gaps.append(PSDEngineDataGap(path: p, consequence: .photoshopRefusesFile)) }
        func dict(_ v: PSDEngineData?) -> PSDEngineData? { if case .dict? = v { v } else { nil } }

        if dict(self["DocumentResources"]) == nil { crash("DocumentResources") }

        let engine = dict(self["EngineDict"])
        let rendered = dict(engine?["Rendered"])
        if rendered?["Version"] == nil { crash("EngineDict.Rendered.Version") }
        let shapes = dict(rendered?["Shapes"])
        if shapes?["WritingDirection"] == nil { crash("EngineDict.Rendered.Shapes.WritingDirection") }
        if let children = shapes?["Children"]?.array, !children.isEmpty {
            for (i, shape) in children.enumerated() {
                let p = "EngineDict.Rendered.Shapes.Children[\(i)]"
                if let lines = dict(shape["Lines"]) {
                    if lines["WritingDirection"] == nil { crash("\(p).Lines.WritingDirection") }
                    if lines["Children"]?.array == nil { crash("\(p).Lines.Children") }
                } else {
                    crash("\(p).Lines")
                }
                if shape["Procession"] == nil { crash("\(p).Procession") }
                if let base = dict(shape.path("Cookie", "Photoshop", "Base")) {
                    for k in ["TransformPoint0", "TransformPoint1", "TransformPoint2"] where base[k] == nil { crash("\(p).Cookie.Photoshop.Base.\(k)") }
                } else {
                    crash("\(p).Cookie.Photoshop.Base")
                }
            }
        } else {
            crash("EngineDict.Rendered.Shapes.Children")
        }
        if engine?["AntiAlias"] == nil { crash("EngineDict.AntiAlias") }
        if engine?["UseFractionalGlyphWidths"] == nil { crash("EngineDict.UseFractionalGlyphWidths") }
        if let runs = engine?.path("ParagraphRun", "RunArray")?.array, !runs.isEmpty {
            for (i, run) in runs.enumerated() where run.path("ParagraphSheet", "DefaultStyleSheet") == nil {
                crash("EngineDict.ParagraphRun.RunArray[\(i)].ParagraphSheet.DefaultStyleSheet")
            }
        } else {
            crash("EngineDict.ParagraphRun.RunArray[].ParagraphSheet.DefaultStyleSheet")
        }

        if let fonts = self.path("ResourceDict", "FontSet")?.array, !fonts.isEmpty {
            for (i, font) in fonts.enumerated() {
                if font["FontType"] == nil { refuse("ResourceDict.FontSet[\(i)].FontType") }
                if font["Synthetic"] == nil { refuse("ResourceDict.FontSet[\(i)].Synthetic") }
            }
        } else {
            refuse("ResourceDict.FontSet")
        }
        return gaps
    }

    /// The paths of `photoshopStructureGaps()`: empty when Photoshop can open the type layer.
    public func missingPhotoshopStructures() -> [String] { photoshopStructureGaps().map(\.path) }
}

extension PSDTypeTool {
    /// The EngineData gaps of this type layer. A text descriptor with no `EngineData`, or one
    /// that does not parse, is reported as `EngineData` (Photoshop cannot lay the text out).
    public func photoshopStructureGaps() -> [PSDEngineDataGap] {
        guard let e = engineData else { return [PSDEngineDataGap(path: "EngineData", consequence: .crashesPhotoshop)] }
        return e.photoshopStructureGaps()
    }

    /// The paths of `photoshopStructureGaps()`.
    public func missingPhotoshopStructures() -> [String] { photoshopStructureGaps().map(\.path) }
}

// MARK: Type sizes Photoshop can read

/// A type layer value outside the range Photoshop reads (see `PSDTypeTool.typeSizeViolations()`).
struct PSDTypeSizeViolation: Hashable, Sendable {
    /// In a class the oracle measured: Photoshop 27.11 turned a 1e30 pt layer into an empty pixel
    /// layer, and a `Double.greatestFiniteMagnitude` one raised the "type layers … were rasterized"
    /// modal. Non-finite values and sizes of 1e6 pt or more. Otherwise the value is only outside
    /// Photoshop's documented limits.
    var measured: Bool
    var what: String
}

extension PSDTypeTool {
    /// Photoshop's documented type-size range in points.
    static let typeSizeRange: ClosedRange<Double> = 0.01 ... 1296
    /// Largest transform component: Photoshop's largest canvas side (300,000 px).
    static let maxTransformComponent = 300_000.0
    /// Sizes from which the measured class starts (the oracle saw 1e30 pt and
    /// `Double.greatestFiniteMagnitude`; Photoshop's own type layers lie within 5.5–130 pt).
    static let measuredLostTextSize = 1e6

    /// Every value Photoshop is not expected to read as type, as the oracle's pre-screen 3
    /// (`TypeSizeScreen`) checks: a transform component that is not finite or beyond ±300,000; a
    /// style run's or style sheet's (`ResourceDict`, `DocumentResources`) FontSize outside
    /// 0.01–1,296 pt; a style run's effective size (FontSize × the transform's scale √|det|)
    /// outside it. An EngineData that does not parse is the structure rules' case.
    func typeSizeViolations() -> [PSDTypeSizeViolation] {
        var out: [PSDTypeSizeViolation] = []
        let m = transform
        for (k, v) in m.enumerated() where !v.isFinite || abs(v) > Self.maxTransformComponent {
            out.append(PSDTypeSizeViolation(measured: !v.isFinite, what: "transform component \(k) is \(v) (limit ±\(Int(Self.maxTransformComponent)))"))
        }
        guard let e = engineData else { return out }
        func measured(_ s: Double) -> Bool { !s.isFinite || abs(s) >= Self.measuredLostTextSize }
        var runs: [(String, Double)] = []
        for (j, run) in (e.path("EngineDict", "StyleRun", "RunArray")?.array ?? []).enumerated() {
            if let s = run.path("StyleSheet", "StyleSheetData", "FontSize")?.double { runs.append(("style run \(j)", s)) }
        }
        var sheets: [(String, Double)] = []
        for res in ["ResourceDict", "DocumentResources"] {
            for (j, sheet) in (e.path(res, "StyleSheetSet")?.array ?? []).enumerated() {
                if let s = sheet.path("StyleSheetData", "FontSize")?.double { sheets.append(("\(res) style sheet \(j)", s)) }
            }
        }
        for (what, s) in runs + sheets where !Self.typeSizeRange.contains(s) {
            out.append(PSDTypeSizeViolation(measured: measured(s), what: "FontSize \(s) pt (\(what))"))
        }
        if m.count >= 4, m.allSatisfy(\.isFinite) {
            let scale = abs(m[0] * m[3] - m[1] * m[2]).squareRoot()
            for (what, s) in runs where Self.typeSizeRange.contains(s) && !Self.typeSizeRange.contains(s * scale) {
                out.append(PSDTypeSizeViolation(measured: measured(s * scale), what: "effective size \(s * scale) pt (\(what): FontSize \(s) × transform scale \(scale))"))
            }
        }
        return out
    }
}
