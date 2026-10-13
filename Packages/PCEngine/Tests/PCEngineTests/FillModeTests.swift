// Port of photocraft-engine (crates/engine/src/fx_mode_tests.rs, fill_layer_mode_tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Layer style and fill-layer colours made in a Grayscale, CMYK or Lab document are stored in the
// document's mode, so they composite as the same colour painted on a pixel layer does (#1905).
// Deviations: `edit.fill` (edit_cmds) isn't in this package, so "painted" references write the
// colour into a pixel layer directly (what Edit › Fill stores). Skipped: the Copy/Paste Layer Style
// half of `a_style_pasted_or_applied_into_a_grayscale_document_converts` (extra_cmds),
// `gray_fill_converts_with_the_document` (Image › Mode, image_cmds) and pattern_mode_tests.rs
// (Edit › Fill with a pattern and Image › Mode).

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import Testing

@Suite struct FillModeTests {
    typealias T = StyleTestSupport
    static let kinds = ["dropShadow", "innerShadow", "outerGlow", "innerGlow", "satin", "colorOverlay", "gradientOverlay", "stroke", "bevelEmboss"]

    func fxSession(_ mode: String, _ depth: Int) throws -> Session {
        let s = try T.session(48, 32, extra: ["mode": .string(mode), "depth": .int(depth), "background": "white"])
        try s.execute("layer.new.layer")
        try T.fill(s, PixelRect(x: 12, y: 8, width: 24, height: 16), SIMD4(0.5, 0.5, 0.5, 1))
        return s
    }

    /// The modes of every colour stored in the active layer's effects (any `{mode, c, alpha}`).
    func effectColourModes(_ s: Session) -> [String] {
        func walk(_ v: JSONValue, _ out: inout [String]) {
            switch v {
            case .object(let o):
                if let m = o["mode"]?.stringValue, o["c"] != nil, o["alpha"] != nil { out.append(m) }
                for x in o.values { walk(x, &out) }
            case .array(let a):
                for x in a { walk(x, &out) }
            default:
                break
            }
        }
        var out: [String] = []
        for e in T.effects(s) { walk(.encoded(e), &out) }
        return out
    }

    func modeName(_ mode: String) -> String {
        switch mode {
        case "gray": "Grayscale"
        case "cmyk": "Cmyk"
        default: "Rgb"
        }
    }

    func expectInMode(_ s: Session, _ mode: String, _ what: String) {
        let modes = effectColourModes(s)
        #expect(!modes.isEmpty, "\(what): no colours found")
        #expect(modes.allSatisfy { $0 == modeName(mode) }, "\(what): colours \(modes) in a \(mode) document")
    }

    @Test func everyEffectCommandStoresColoursInTheDocumentMode() throws {
        for mode in ["gray", "cmyk", "rgb"] {
            for depth in [8, 16, 32] {
                for kind in Self.kinds {
                    let s = try fxSession(mode, depth)
                    try s.execute("layer.layerStyle.\(kind)", ["color": "#ff3300"])
                    expectInMode(s, mode, "\(mode)/\(depth) \(kind)")
                }
            }
        }
    }

    @Test func theLayerStyleDialogStoresColoursInTheDocumentMode() throws {
        for mode in ["gray", "cmyk"] {
            let s = try fxSession(mode, 8)
            let effects = JSONValue.array(Self.kinds.map { ["kind": .string($0), "params": ["color": "#ff3300"]] })
            try s.execute("layer.layerStyle.replace", ["effects": effects])
            expectInMode(s, mode, "\(mode) layer.layerStyle.replace")
        }
    }

    @Test func aRedColorOverlayIsGreyInAGrayscaleDocument() throws {
        for depth in [8, 16, 32] {
            let s = try fxSession("gray", depth)
            try s.execute("layer.layerStyle.colorOverlay", ["color": "#ff0000"])
            let p = try T.pixel(s, 20, 15)
            // Red painted into a Gray document: 0.299.
            #expect(abs(p[0] - 0.299) < 0.01 && p[0] == p[1] && p[1] == p[2], "\(depth)-bit: \(p)")
        }
    }

    @Test func aStyleAppliedInAGrayscaleDocumentConverts() throws {
        let s = try fxSession("gray", 16)
        try s.execute("style.presets.apply", ["preset": "Gold"])
        expectInMode(s, "gray", "style.presets.apply Gold")
    }

    // MARK: Fill layers

    static let blue = SIMD4<Float>(0, 0, 1, 1)
    static let green = SIMD4<Float>(0, 1, 0, 1)

    func fillSession(_ mode: String, _ depth: Int) throws -> Session {
        let s = try T.session(64, 32, extra: ["mode": .string(mode), "depth": .int(depth), "background": "white"])
        s.tools.foreground = Self.blue
        s.tools.background = Self.green
        return s
    }

    /// The composite of `color` painted on a new pixel layer: what a fill layer of that colour
    /// must look like.
    func painted(_ mode: String, _ depth: Int, _ color: SIMD4<Float>) throws -> [Float] {
        let s = try fillSession(mode, depth)
        try s.execute("layer.new.layer")
        try T.fill(s, nil, color)
        return try T.pixel(s, 10, 10)
    }

    func close(_ a: [Float], _ b: [Float], _ tol: Float) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= tol } }

    func fillColors(_ s: Session) -> [PCColor] {
        guard let d = s.active, let id = d.activeLayer, case .fill(let f)? = d.doc.layer(id)?.content else { return [] }
        switch f {
        case .solid(let c): return [c]
        case .gradient(let g): return g.stops.map(\.color)
        case .pattern: return []
        }
    }

    func expectFillInMode(_ s: Session, _ mode: ColorMode, _ what: String) {
        let cs = fillColors(s)
        #expect(!cs.isEmpty, "\(what): no fill")
        for c in cs { #expect(c.mode == mode, "\(what): \(c)") }
    }

    @Test func solidColorFillMatchesPaintedColour() throws {
        for (mode, cm) in [("gray", ColorMode.grayscale), ("cmyk", .cmyk), ("lab", .lab)] {
            for depth in [8, 16, 32] {
                let s = try fillSession(mode, depth)
                try s.execute("layer.newFillLayer.solidColor", ["color": "#0000ff"])
                expectFillInMode(s, cm, mode)
                let got = try T.pixel(s, 10, 10)
                let want = try painted(mode, depth, Self.blue)
                #expect(close(got, want, 0.01), "\(mode)/\(depth): fill layer \(got), painted \(want)")
                if cm == .grayscale { #expect(abs(got[0] - 0.114) < 0.01 && got[0] == got[1] && got[1] == got[2], "\(mode)/\(depth): \(got)") }
            }
        }
    }

    @Test func gradientFillLayersAreGrayInAGrayscaleDocument() throws {
        func grey(_ p: [Float]) -> Bool { abs(p[0] - p[1]) < 1e-4 && abs(p[1] - p[2]) < 1e-4 }
        let ways: [(String, JSONValue)] = [
            ("layer.newFillLayer.gradient", ["from": "#0000ff", "to": "#00ff00", "angle": 0]),
            ("gradient.fill.create", ["from": [0, 16], "to": [64, 16]]),
            ("gradient.presets.apply", ["preset": "Blue 01", "angle": 0]),
        ]
        for depth in [8, 16, 32] {
            for (cmd, p) in ways {
                let s = try fillSession("gray", depth)
                try s.execute(cmd, p)
                expectFillInMode(s, .grayscale, cmd)
                for x in [1, 32, 62] {
                    let px = try T.pixel(s, x, 16)
                    #expect(grey(px), "\(cmd) at \(depth), x \(x): \(px)")
                }
            }
        }
    }

    @Test func gradientEditsKeepColoursInTheDocumentMode() throws {
        let s = try fillSession("cmyk", 8)
        try s.execute("gradient.fill.create", ["from": [0, 16], "to": [64, 16]])
        try s.execute("gradient.fill.set", ["stops": [[0, "#ff0000"], [1, "#0000ff"]]])
        expectFillInMode(s, .cmyk, "gradient.fill.set")
        let start = try T.pixel(s, 0, 16)
        let red = try painted("cmyk", 8, SIMD4(1, 0, 0, 1))
        #expect(close(start, red, 0.02), "\(start) vs \(red)")
        try s.execute("gradient.presets.select", ["preset": "Green 01"])
        expectFillInMode(s, .cmyk, "gradient.presets.select")
    }

    @Test func rgbDocumentsKeepRGBFillColours() throws {
        let s = try fillSession("rgb", 8)
        try s.execute("layer.newFillLayer.solidColor", ["color": "#0000ff"])
        #expect(fillColors(s) == [.rgb(0, 0, 1)])
        #expect(close(try T.pixel(s, 10, 10), [0, 0, 1, 1], 1e-6))
    }
}
