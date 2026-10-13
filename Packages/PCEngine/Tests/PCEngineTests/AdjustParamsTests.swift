// Port of photocraft-engine (crates/engine/src/adjust_params.rs `mod tests`; crates/engine/src/tests.rs adjustment tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCRender
import Testing

private let kinds = ["invert", "brightnessContrast", "threshold", "posterize", "exposure", "vibrance", "hueSaturation", "levels", "curves",
                     "colorBalance", "blackWhite", "photoFilter", "channelMixer", "gradientMap", "selectiveColor"]

/// A non-default parameter set per kind (RGB channel keys for Levels/Curves).
private func sample(_ kind: String) -> JSONValue {
    switch kind {
    case "brightnessContrast": ["brightness": 20, "contrast": -10, "legacy": true]
    case "threshold": ["level": 100]
    case "posterize": ["levels": 7]
    case "exposure": ["exposure": 1.5, "offset": 0.1, "gamma": 1.4]
    case "vibrance": ["vibrance": 30, "saturation": -20]
    case "hueSaturation": ["hue": 25, "saturation": -20, "lightness": 10, "reds": ["hue": 10, "saturation": -30, "lightness": 5, "range": [300, 340, 20, 50]]]
    case "levels": ["inBlack": 10, "inWhite": 240, "outBlack": 5, "outWhite": 250, "gamma": 1.2, "red": ["inBlack": 3, "gamma": 0.8]]
    case "curves": ["points": [[0, 0], [128, 150], [255, 255]], "blue": [[0, 20], [255, 235]]]
    case "colorBalance": ["shadows": [10, -5, 0], "midtones": [0, 20, -30], "highlights": [5, 5, 5], "preserveLuminosity": false]
    case "blackWhite": ["reds": 120, "blues": -40, "tint": true, "tintColor": "#d0a070"]
    case "photoFilter": ["color": "#3366cc", "density": 40, "preserveLuminosity": false]
    case "channelMixer": ["red": [80, 30, -10, 5], "blue": [0, 10, 90, 0]]
    case "gradientMap": ["stops": [[0, "#000000"], [0.5, "#ff0000"], [1, [1, 1, 1]]], "reverse": true, "dither": true]
    case "selectiveColor": ["method": "absolute", "reds": [10, 0, -20, 5]]
    default: .object([:])
    }
}

private func from(_ kind: String, _ p: JSONValue, _ base: Adjustment? = nil, _ mode: ColorMode = .rgb) throws -> Adjustment {
    try AdjustParams.fromParams(kind, p, base: base, mode: mode)
}

private func curvesParts(_ a: Adjustment) -> ([CurvePoint], [[CurvePoint]]) {
    if case .curves(let c) = a { return (c.master, c.perChannel) }
    Issue.record("expected curves")
    return ([], [[], [], []])
}

private func toneOutput(_ a: Adjustment, _ s: SIMD3<Float>) -> SIMD3<Float> {
    let luts = AdjustMath.toneLUTsQ(a, nil)
    var out = SIMD3<Float>()
    for c in 0..<3 {
        let row = luts[c]
        let pos = min(max(s[c], 0), 1) * Float(row.count - 1)
        let lower = Int(pos.rounded(.down))
        let upper = min(lower + 1, row.count - 1)
        let f = pos - Float(lower)
        out[c] = row[lower] * (1 - f) + row[upper] * f
    }
    return out
}

private func luma(_ c: SIMD3<Float>) -> Float { c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722 }

/// Paints `rect` (default: the canvas) of the active pixel layer with `c`, as one step.
func adjustTestPaint(_ s: Session, _ c: SIMD4<Float>, _ rect: PixelRect? = nil) throws {
    try s.edit("setup") { doc, active in
        guard let id = active else { throw EngineError.other("no active layer") }
        let r = rect ?? doc.bounds
        doc.withRaster(of: id) { surf in surf.fill(r, with: surf.format.components(fromRGBA: c)) }
    }
}

/// `document.pixel` as floats.
func adjustTestPixel(_ s: Session, _ x: Int, _ y: Int) throws -> [Float] {
    try s.execute("document.pixel", ["x": .int(x), "y": .int(y)]).arrayValue?.compactMap { $0.floatValue } ?? []
}

/// A colourful 16×16 document (`mode`, `depth`) for command tests.
private func colourful(_ mode: String, _ depth: Int) throws -> Session {
    let s = Session()
    try s.execute("file.new", ["width": 16, "height": 16, "mode": .string(mode), "depth": .int(depth)])
    for (i, c) in ["#c83c28", "#3c8c50", "#2850b4", "#d2b464"].enumerated() {
        let r = PixelRect(x: (i % 2) * 8, y: (i / 2) * 8, width: 8, height: 8)
        try adjustTestPaint(s, try #require(Params.parseHex(c)), r)
    }
    return s
}

private func pixels(_ s: Session) -> [[Float]] {
    guard let bg = s.active?.doc.layers.first?.surface else { return [] }
    return [(2, 2), (10, 2), (2, 10), (10, 10)].map { bg.pixel(x: Int32($0.0), y: Int32($0.1)) }
}

@Suite struct AdjustParamsTests {
    @Test func everyKindRoundTripsThroughParams() throws {
        for mode in [ColorMode.rgb, .cmyk, .lab, .grayscale] {
            for kind in kinds {
                var p = sample(kind)
                if ["levels", "curves"].contains(kind) && AdjustParams.defaultSpace(mode) != .rgb {
                    // Off RGB the channel keys are the document's.
                    p = p.removing("red").removing("blue")
                }
                let a = try from(kind, p, nil, mode)
                if kind != "invert" { #expect(a != (try AdjustParams.defaultFor(kind, mode: mode)), "\(kind) params ignored") }
                let back = try from(kind, AdjustParams.toParams(a), nil, mode)
                #expect(AdjustParams.toParams(back) == AdjustParams.toParams(a), "\(kind) \(mode)")
                #expect(back == a, "\(kind) \(mode): from_params(to_params(a)) == a")
                // A partial update keeps everything it doesn't name.
                let again = try from(kind, .object([:]), a, mode)
                #expect(again == a, "\(kind) \(mode)")
            }
        }
    }

    @Test func paramsReachTheModel() throws {
        var a = try from("colorBalance", ["midtones": [50, 0, -200]])
        #expect(a == .colorBalance(.init(shadows: .zero, midtones: SIMD3(50, 0, -100), highlights: .zero, preserveLuminosity: true)))
        a = try from("channelMixer", ["monochrome": true])
        if case .channelMixer(let cm) = a { #expect(cm.monochrome && cm.matrix[0] == SIMD4(0.4, 0.4, 0.2, 0)) } else { Issue.record("\(a)") }
        a = try from("photoFilter", ["filter": "cooling80", "density": 60])
        if case .photoFilter(let pf) = a { #expect(pf.color.z == 1 && abs(pf.density - 0.6) < 1e-6) } else { Issue.record("\(a)") }
        a = try from("blackWhite", ["reds": 120, "tint": true])
        if case .blackWhite(let bw) = a { #expect(bw.tint != nil && bw.weights[0] == 120 && bw.weights[1] == 60) } else { Issue.record("\(a)") }
        a = try from("hueSaturation", ["blues": ["hue": 40]])
        if case .hueSaturation(let hs) = a { #expect(hs.ranges[4].hue == 40 && hs.ranges[0].isNeutral) } else { Issue.record("\(a)") }
        // Colorize without a saturation starts at 25%; an explicit 0 and an already colorized base are kept.
        a = try from("hueSaturation", ["colorize": true, "hue": 30])
        if case .hueSaturation(let hs) = a { #expect(hs.colorize && hs.saturation == 25) } else { Issue.record("\(a)") }
        a = try from("hueSaturation", ["colorize": true, "saturation": 0])
        if case .hueSaturation(let hs) = a { #expect(hs.colorize && hs.saturation == 0) } else { Issue.record("\(a)") }
        a = try from("hueSaturation", ["hue": 120], a)
        if case .hueSaturation(let hs) = a { #expect(hs.colorize && hs.saturation == 0 && hs.hue == 120) } else { Issue.record("\(a)") }
        a = try from("gradientMap", ["stops": [[1, "#ffffff"], [0, "#000000"]], "dither": true])
        if case .gradientMap(let gm) = a { #expect(gm.dither && gm.stops[0].location == 0) } else { Issue.record("\(a)") }
        // CMYK curves: ink channels; Lab: lightness without a composite.
        a = try from("curves", ["black": [[0, 0], [255, 200]]])
        if case .curves(let c) = a { #expect(c.space == .cmyk && c.black.count == 2) } else { Issue.record("\(a)") }
        a = try from("curves", ["points": [[0, 40], [255, 255]]], nil, .lab)
        if case .curves(let c) = a { #expect(c.space == .lab && c.perChannel[0][0].output > 0.1) } else { Issue.record("\(a)") }
        a = try from("levels", ["inBlack": 20], nil, .cmyk)
        if case .levels(let l) = a { #expect(l.space == .cmyk && abs(l.master.inBlack - 20 / 255) < 1e-6) } else { Issue.record("\(a)") }
    }

    @Test func badParamsAreErrorsNotPanics() throws {
        let longBad: JSONValue = .array((0..<256).map { $0 == 9 ? .string("x") : .int($0) })
        let cases: [(String, JSONValue)] = [
            ("curves", ["points": "abc"]), ("curves", ["points": [[0, 0]]]), ("curves", ["red": [[0, 0], [1]]]),
            ("curves", ["points": [[5, 5], [5, 9]]]), ("curves", ["pencil": true, "points": [1, 2, 3]]), ("curves", ["pencil": "yes"]),
            ("curves", ["points": longBad]), ("levels", ["red": 3]), ("levels", ["inBlack": "x"]),
            ("hueSaturation", ["reds": ["range": [1, 2]]]), ("hueSaturation", ["colorize": 1]), ("colorBalance", ["shadows": [1, 2]]),
            ("blackWhite", ["tintColor": "#zz0000"]), ("photoFilter", ["filter": "nope"]), ("photoFilter", ["color": [1]]),
            ("channelMixer", ["red": [1, 2, 3]]), ("gradientMap", ["stops": [[0, "#000"]]]), ("gradientMap", ["stops": 7]),
            ("selectiveColor", ["method": 5]), ("selectiveColor", ["reds": "not-an-array"]), ("selectiveColor", ["colors": "reds", "cyan": "50"]),
            ("colorLookup", ["lut": 42]), ("colorLookup", ["interpolation": 5]), ("colorLookup", ["dither": "yes"]),
            ("nope", .object([:])), ("levels", [1, 2]),
        ]
        for (kind, p) in cases {
            #expect(throws: EngineError.self, "\(kind) \(p)") { try from(kind, p) }
        }
        // Out-of-range numbers clamp.
        if case .hueSaturation(let hs) = try from("hueSaturation", ["hue": 1e9, "saturation": -1e9]) {
            #expect(hs.hue == 180 && hs.saturation == -100)
        } else { Issue.record("expected hueSaturation") }
        if case .levels(let l) = try from("levels", ["inBlack": 250, "inWhite": 10]) {
            #expect(l.master.inWhite > l.master.inBlack)
        } else { Issue.record("expected levels") }
    }

    @Test func curvesBlackAndWhiteEyedroppersMoveTheInputReferences() throws {
        let base: JSONValue = ["points": [[0, 8], [120, 150], [255, 245]], "red": [[0, 0], [100, 130], [255, 255]],
                               "green": [[0, 0], [110, 125], [255, 255]], "blue": [[0, 0], [90, 120], [255, 255]]]
        let black = try AdjustParams.curvesEyedropper(base, .black, SIMD3(0.2, 0.3, 0.4), mode: .rgb)
        var (master, channels) = curvesParts(black)
        for (curve, s) in zip(channels, [Float(0.2), 0.3, 0.4]) {
            #expect(abs(curve[0].input - s) < 1e-6 && curve[0].output == 0, "\(curve)")
            #expect(curve.count == 3, "existing edit points are preserved")
        }
        #expect(master[0].output == 0, "the composite cannot lift the sampled black")
        let bo = toneOutput(black, SIMD3(0.2, 0.3, 0.4))
        #expect(bo.x < 1e-3 && bo.y < 1e-3 && bo.z < 1e-3)

        let white = try AdjustParams.curvesEyedropper(base, .white, SIMD3(0.6, 0.7, 0.8), mode: .rgb)
        (master, channels) = curvesParts(white)
        for (curve, s) in zip(channels, [Float(0.6), 0.7, 0.8]) {
            let end = try #require(curve.last)
            #expect(abs(end.input - s) < 1e-6 && end.output == 1, "\(curve)")
            #expect(curve.count == 3, "existing edit points are preserved")
        }
        #expect(master.last?.output == 1, "the composite cannot lower the sampled white")
        let wo = toneOutput(white, SIMD3(0.6, 0.7, 0.8))
        #expect(wo.x > 1 - 1e-3 && wo.y > 1 - 1e-3 && wo.z > 1 - 1e-3)

        let edgeBlack = try AdjustParams.curvesEyedropper(base, .black, SIMD3(1, 0.3, 0.4), mode: .rgb)
        var (_, edge) = curvesParts(edgeBlack)
        #expect(edge[0].count == 3, "edge samples preserve other curve points")
        #expect(edge[0].last?.output == 0)
        let edgeWhite = try AdjustParams.curvesEyedropper(base, .white, SIMD3(0, 0.7, 0.8), mode: .rgb)
        (_, edge) = curvesParts(edgeWhite)
        #expect(edge[0].count == 3, "edge samples preserve other curve points")
        #expect(edge[0].first?.output == 1)
    }

    private func checkCurve(_ curve: [CurvePoint], _ what: String) {
        #expect(curve.count >= 2, "\(what): \(curve)")
        #expect(curve.count <= AdjustParams.maxCurvePoints, "\(what): \(curve)")
        for i in 0..<max(curve.count - 1, 0) {
            #expect(curve[i].input < curve[i + 1].input, "\(what): \(curve)")
            #expect(curve[i + 1].input - curve[i].input >= AdjustParams.curvePointDuplicateDistance, "\(what): \(curve)")
        }
    }

    @Test func blackAndWhiteEyedroppersRoundTripNearSerializationBoundaries() throws {
        let cases: [(AdjustParams.CurvesEyedropper, Float, Float)] = [
            (.white, 0, 1), (.white, 0.001, 1), (.white, 0.494 / 255, 1),
            // 0.496 level rounds to 0.50; the sample is just below that representable point.
            (.white, 0.496 / 255, 0.992), (.white, 0.2, 1),
            (.black, 1, 0), (.black, 0.999, 0), (.black, 1 - 0.494 / 255, 0),
            // 254.504 levels rounds to 254.50, leaving a representable 0.50-level gap.
            (.black, 1 - 0.496 / 255, 0.008), (.black, 0.8, 0),
        ]
        for (picker, s, expected) in cases {
            let resolved = try AdjustParams.curvesEyedropper(.object([:]), picker, SIMD3(repeating: s), mode: .rgb)
            let parsed = try from("curves", AdjustParams.toParams(resolved))
            let (master, channels) = curvesParts(parsed)
            for curve in [master] + channels { checkCurve(curve, "\(picker) sample=\(s)") }
            let out = toneOutput(parsed, SIMD3(repeating: s))
            #expect(abs(out.x - expected) < 1e-3 && abs(out.y - expected) < 1e-3 && abs(out.z - expected) < 1e-3,
                    "\(picker) sample=\(s) output=\(out) expected=\(expected)")
        }
    }

    @Test func endpointEyedroppersFallBackWhenSerializationCollapsesCurvePoints() throws {
        let c: JSONValue = [[0, 0], [64, 50], [128, 100], [192, 200], [255, 255]]
        let base: JSONValue = ["points": c, "red": c, "green": c, "blue": c]
        for (picker, s, target, black) in [(AdjustParams.CurvesEyedropper.black, Float(0.995), Float(0), true), (.white, 0.005, 1, false)] {
            let resolved = try AdjustParams.curvesEyedropper(base, picker, SIMD3(repeating: s), mode: .rgb)
            let parsed = try from("curves", AdjustParams.toParams(resolved))
            let (master, channels) = curvesParts(parsed)
            for curve in [master] + channels {
                #expect(curve.count == 5, "collapsed points use the deterministic fallback: \(curve)")
                for (pt, input) in zip(curve, [Float(0), 64, 128, 192, 255]) {
                    #expect(abs(pt.input * 255 - input) < 1e-3, "existing point position was retained: \(curve)")
                }
            }
            for curve in channels {
                let plateau = black ? Array(curve.suffix(2)) : Array(curve.prefix(2))
                #expect(plateau.allSatisfy { abs($0.output - target) < 1e-6 }, "\(curve)")
            }
            let out = toneOutput(parsed, SIMD3(repeating: s))
            #expect(abs(out.x - target) < 0.01 && abs(out.y - target) < 0.01 && abs(out.z - target) < 0.01, "\(picker): \(out)")
        }
    }

    @Test func blackAndWhiteRoundTripsPreserveRepresentableCurveEdits() throws {
        let base: JSONValue = ["points": [[0, 8], [120, 150], [255, 245]], "red": [[0, 0], [100, 130], [255, 255]],
                               "green": [[0, 0], [110, 125], [255, 255]], "blue": [[0, 0], [90, 120], [255, 255]]]
        let black = try from("curves", AdjustParams.toParams(try AdjustParams.curvesEyedropper(base, .black, SIMD3(0.2, 0.3, 0.4), mode: .rgb)))
        var (_, ch) = curvesParts(black)
        #expect(ch[0].count == 3)
        #expect(abs(ch[0][1].input * 255 - 131) < 1e-3)
        #expect(abs(ch[0][1].output * 255 - 130) < 1e-3)
        let white = try from("curves", AdjustParams.toParams(try AdjustParams.curvesEyedropper(base, .white, SIMD3(0.6, 0.7, 0.8), mode: .rgb)))
        (_, ch) = curvesParts(white)
        #expect(ch[0].count == 3)
        #expect(abs(ch[0][1].input * 255 - 60) < 1e-3)
        #expect(abs(ch[0][1].output * 255 - 130) < 1e-3)
    }

    private func grayPointPreservesLumaAndEdits(_ s: SIMD3<Float>) throws {
        let base: JSONValue = ["points": [[0, 0], [128, 96], [255, 255]], "red": [[0, 0], [80, 90], [255, 255]],
                               "green": [[0, 0], [90, 100], [255, 255]], "blue": [[0, 0], [70, 80], [255, 255]]]
        let original = try from("curves", base)
        let expectedLuma = luma(s)
        let resolved = try AdjustParams.curvesEyedropper(base, .neutralGray, s, mode: .rgb)
        let parsed = try from("curves", AdjustParams.toParams(resolved))
        let (master, channels) = curvesParts(parsed)
        let (oMaster, oChannels) = curvesParts(original)
        #expect(master == oMaster, "the existing master curve is retained")
        for (curve, old) in zip(channels, oChannels) {
            let edit = old[1]
            #expect(curve.contains { abs($0.input - edit.input) < 1e-6 && abs($0.output - edit.output) < 1e-6 }, "the existing channel edit is retained: \(curve)")
        }
        let out = toneOutput(parsed, s)
        #expect(abs(out.x - out.y) < 0.002 && abs(out.y - out.z) < 0.002, "sample must become neutral: \(out)")
        #expect(abs(luma(out) - expectedLuma) < 0.003, "luma changed from \(expectedLuma) to \(luma(out))")
    }

    @Test func curvesNeutralGrayPreservesLumaForALightCastSample() throws { try grayPointPreservesLumaAndEdits(SIMD3(0.88, 0.76, 0.63)) }

    @Test func curvesNeutralGrayPreservesLumaForADarkCastSample() throws { try grayPointPreservesLumaAndEdits(SIMD3(0.17, 0.105, 0.075)) }

    @Test func curvesNeutralGrayHandlesNearBlackAndNearWhiteSamples() throws {
        for s in [SIMD3<Float>(0.004, 0.006, 0.008), SIMD3(0.992, 0.996, 0.999), SIMD3(0, 0, 0), SIMD3(1, 1, 1)] {
            let resolved = try AdjustParams.curvesEyedropper(.object([:]), .neutralGray, s, mode: .rgb)
            let parsed = try from("curves", AdjustParams.toParams(resolved))
            let (master, channels) = curvesParts(parsed)
            for curve in [master] + channels { checkCurve(curve, "\(s)") }
            let out = toneOutput(parsed, s)
            #expect(abs(out.x - out.y) < 0.002 && abs(out.y - out.z) < 0.002, "\(s): \(out)")
            #expect(abs(luma(out) - luma(s)) < 0.003, "\(s): \(out)")
        }
    }

    @Test func grayPointFallbackKeepsTightlySpacedPointsRoundTripSafe() throws {
        let c: JSONValue = [[0, 0], [100, 100], [100.51, 100], [255, 255]]
        let base: JSONValue = ["red": c, "green": c, "blue": c]
        let s = SIMD3<Float>(100.25 / 255, 100.1 / 255, 100.4 / 255)
        let target = luma(s)
        let parsed = try from("curves", AdjustParams.toParams(try AdjustParams.curvesEyedropper(base, .neutralGray, s, mode: .rgb)))
        let (_, channels) = curvesParts(parsed)
        for (curve, input) in zip(channels, [s.x, s.y, s.z]) {
            #expect(curve.count == 4, "the fallback keeps every serialized point: \(curve)")
            for i in 0..<(curve.count - 1) { #expect(curve[i + 1].input - curve[i].input >= AdjustParams.curvePointDuplicateDistance, "\(curve)") }
            let i = try #require((0..<(curve.count - 1)).first { curve[$0].input <= input && input <= curve[$0 + 1].input })
            #expect(abs(curve[i].output - curve[i + 1].output) < 1e-6, "fallback forms a plateau around the sample: \(curve)")
            #expect(abs(curve[i].output - target) < 0.001, "fallback uses the luma target: \(curve)")
        }
    }

    @Test func curvesEyedropperParamDrivesTheCommand() throws {
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 8])
        try adjustTestPaint(s, SIMD4(0.6, 0.5, 0.4, 1))
        try s.execute("image.adjustments.curves", ["eyedropper": ["point": "white", "at": [2, 2]]])
        var px = try adjustTestPixel(s, 2, 2)
        #expect(px.prefix(3).allSatisfy { $0 > 0.99 }, "the sample becomes white: \(px)")
        try s.execute("image.adjustments.curves", ["eyedropper": ["point": "black", "color": [1.0, 1.0, 1.0]]])
        px = try adjustTestPixel(s, 2, 2)
        #expect(px.prefix(3).allSatisfy { $0 < 0.01 }, "the given colour becomes black: \(px)")
        let bads: [JSONValue] = ["black", ["point": "nope", "at": [1, 1]], ["point": "black"], ["point": "black", "at": [99, 1]],
                                 ["point": "black", "at": [-1, 1]], ["point": "black", "at": [1]], ["point": "gray", "at": [.number(.greatestFiniteMagnitude), 1]],
                                 ["point": "black", "color": "red"]]
        for bad in bads {
            #expect(throws: EngineError.self, "\(bad)") { try s.execute("image.adjustments.curves", ["eyedropper": bad]) }
        }
    }

    /// The Properties panel's pickers on a Curves adjustment layer: one undoable step that samples
    /// the image below the layer, so a repeated click keeps the same curve.
    @Test func layerEyedropperSamplesBelowTheCurvesLayer() throws {
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 8])
        try adjustTestPaint(s, SIMD4(0.6, 0.5, 0.4, 1))
        try s.execute("layer.newAdjustmentLayer.curves")
        let steps = try #require(s.active).history.pastCount
        let pick: JSONValue = ["eyedropper": ["point": "white", "at": [2, 2], "size": 3]]
        try s.execute("layer.setAdjustment", pick)
        #expect(s.active?.history.pastCount == steps + 1)
        let px = try adjustTestPixel(s, 2, 2)
        #expect(px.prefix(3).allSatisfy { $0 > 0.99 }, "the sample becomes white: \(px)")
        let curve = s.active?.doc.layers.last?.content
        try s.execute("layer.setAdjustment", pick)
        #expect(s.active?.doc.layers.last?.content == curve, "sampled below the layer, not through it")
        try s.execute("edit.undo")
        try s.execute("edit.undo")
        #expect(s.active?.history.pastCount == steps)
        for bad: JSONValue in [["point": "black", "at": [99, 1]], ["point": "black", "at": [1, 1], "size": 2], ["point": "x", "at": [1, 1]]] {
            #expect(throws: EngineError.self, "\(bad)") { try s.execute("layer.setAdjustment", ["eyedropper": bad]) }
        }
        try s.execute("layer.newAdjustmentLayer.hueSaturation")
        #expect(throws: EngineError.self, "Levels and Curves only") {
            try s.execute("layer.setAdjustment", ["eyedropper": ["point": "white", "at": [1, 1]]])
        }
    }

    /// Levels' Set White/Neutral Gray Point: the white point maps the sampled colour to white at 8
    /// and 16 bit, the gray point neutralises a tinted grey at its luma on a Levels layer as one
    /// undoable step, and bad picks fail.
    @Test func levelsEyedroppersSetWhiteAndNeutralGray() throws {
        for depth in [8, 16] {
            let s = Session()
            try s.execute("file.new", ["width": 8, "height": 8, "depth": .int(depth)])
            try adjustTestPaint(s, SIMD4(0.6, 0.5, 0.4, 1))
            try s.execute("image.adjustments.levels", ["eyedropper": ["point": "white", "at": [2, 2]]])
            let px = try adjustTestPixel(s, 2, 2)
            #expect(px.prefix(3).allSatisfy { $0 > 0.995 }, "\(depth)-bit: the sample becomes white: \(px)")
        }
        let s = Session()
        try s.execute("file.new", ["width": 8, "height": 8])
        try adjustTestPaint(s, SIMD4(0.6, 0.5, 0.4, 1))
        let before = try adjustTestPixel(s, 2, 2)
        try s.execute("layer.newAdjustmentLayer.levels")
        let steps = try #require(s.active).history.pastCount
        try s.execute("layer.setAdjustment", ["eyedropper": ["point": "gray", "at": [2, 2]]])
        #expect(s.active?.history.pastCount == steps + 1)
        let px = try adjustTestPixel(s, 2, 2)
        let (lo, hi) = (px.prefix(3).min() ?? 0, px.prefix(3).max() ?? 1)
        #expect(hi - lo < 2.5 / 255, "neutral: \(px)")
        func l(_ c: [Float]) -> Float { c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722 }
        #expect(abs(l(px) - l(before)) < 2 / 255, "keeps the luma: \(px) vs \(before)")
        try s.execute("edit.undo")
        // Exact, as photocraft compares: `document.pixel` reads at full precision (PCRender's
        // display path composites a plain 8-bit stack in half floats by design).
        let undone = try adjustTestPixel(s, 2, 2)
        #expect(undone == before, "\(undone) vs \(before)")
        for bad: JSONValue in [["point": "gray", "at": [99, 1]], ["point": "x", "at": [1, 1]], ["point": "white", "color": [.number(.nan), 0, 0]]] {
            #expect(throws: EngineError.self, "\(bad)") { try s.execute("layer.setAdjustment", ["eyedropper": bad]) }
            #expect(throws: EngineError.self, "\(bad)") { try s.execute("image.adjustments.levels", ["eyedropper": bad]) }
        }
        try s.execute("file.new", ["width": 8, "height": 8, "mode": "grayscale"])
        #expect(throws: EngineError.self, "no gray picker in Grayscale") {
            try s.execute("image.adjustments.levels", ["eyedropper": ["point": "gray", "at": [1, 1]]])
        }
        try s.execute("image.adjustments.levels", ["eyedropper": ["point": "black", "color": [1.0, 1.0, 1.0]]])
    }

    @Test func curvesEyedropperSupportIsExplicitAndBadSamplesFail() throws {
        #expect(throws: Never.self) { try AdjustParams.curvesEyedropper(.object([:]), .black, SIMD3(repeating: 0.4), mode: .grayscale) }
        #expect(throws: Never.self) { try AdjustParams.curvesEyedropper(.object([:]), .white, SIMD3(repeating: 0.4), mode: .grayscale) }
        #expect(throws: EngineError.self) { try AdjustParams.curvesEyedropper(.object([:]), .neutralGray, SIMD3(repeating: 0.4), mode: .grayscale) }
        for mode in [ColorMode.cmyk, .lab] {
            #expect(throws: EngineError.self) { try AdjustParams.curvesEyedropper(.object([:]), .black, SIMD3(repeating: 0.4), mode: mode) }
        }
        #expect(throws: EngineError.self) { try AdjustParams.curvesEyedropper(.object([:]), .black, SIMD3(.nan, 0, 0), mode: .rgb) }
    }

    @Test func hueRangeSlidersStayOrdered() throws {
        guard case .hueSaturation(let hs) = try from("hueSaturation", ["greens": ["range": [100, 90, 200, 150]]]) else {
            Issue.record("expected hueSaturation")
            return
        }
        let b = hs.ranges[2].bounds
        #expect(b.x <= b.y && b.y <= b.z && b.z <= b.w && b.w - b.x < 360, "\(b)")
    }

    @Test func destructiveCommandsApplyTheirParamsAtEveryDepth() throws {
        for depth in [8, 16, 32] {
            for kind in kinds where kind != "invert" {
                var s = try colourful("rgb", depth)
                let before = pixels(s)
                let steps = try #require(s.active).history.pastCount
                try s.execute("image.adjustments.\(kind)", sample(kind))
                #expect(pixels(s) != before, "\(kind) @\(depth) changed nothing")
                #expect(s.active?.history.pastCount == steps + 1, "\(kind): one history step")
                // Identity params leave the pixels alone (within one 8-bit step).
                s = try colourful("rgb", depth)
                try s.execute("image.adjustments.\(kind)", AdjustParams.toParams(try AdjustParams.defaultFor(kind, mode: .rgb)))
                if !["threshold", "posterize", "blackWhite", "gradientMap", "photoFilter"].contains(kind) {
                    for (a, b) in zip(pixels(s), before) {
                        #expect(zip(a, b).allSatisfy { abs($0 - $1) <= 1 / 255 + 1e-4 }, "\(kind) @\(depth): \(a) vs \(b)")
                    }
                }
            }
        }
    }

    @Test func curvesPencilMapsDrawSmoothAndConvertBack() throws {
        // A drawn inversion: 256 output levels.
        let inverted: JSONValue = .array((0..<256).reversed().map { .int($0) })
        let a = try from("curves", ["pencil": true, "points": inverted])
        if case .curves(let c) = a { #expect(c.pencil && c.master.count == curveMapLength) } else { Issue.record("\(a)") }
        #expect(abs(toneOutput(a, SIMD3(repeating: 0.25)).x - 0.75) < 1e-3)
        #expect(try from("curves", AdjustParams.toParams(a)) == a)
        // Smooth evens out a hard step but keeps the endpoints.
        let step: JSONValue = .array((0..<256).map { .int($0 < 128 ? 0 : 255) })
        let sm = try from("curves", ["red": step, "smooth": 2], a)
        let (_, chans) = curvesParts(sm)
        #expect(chans[0][127].output > 0.2 && chans[0][128].output < 0.8)
        #expect(chans[0][0].output == 0 && chans[0][255].output == 1)
        // Edit points: the map is fitted with a point curve that still inverts.
        let pts = try from("curves", ["pencil": false], a)
        let (master, _) = curvesParts(pts)
        if case .curves(let c) = pts { #expect(!c.pencil && master.count <= AdjustParams.maxFittedPoints, "\(master)") }
        #expect(abs(toneOutput(pts, SIMD3(repeating: 0.25)).x - 0.75) < 2 / 255)
        // The command draws it at every depth.
        for depth in [8, 16, 32] {
            let s = try colourful("rgb", depth)
            let before = pixels(s)
            try s.execute("image.adjustments.curves", AdjustParams.toParams(a))
            let after = pixels(s)
            #expect(abs(after[0][0] - (1 - before[0][0])) < 2 / 255, "@\(depth): \(after) vs \(before)")
        }
    }

    @Test func destructiveLevelsDontClipIn32Bit() throws {
        // Input 15..230, gamma 1.3, output 10..245: integer documents stop at the output range, while
        // float documents preserve the curve's signed and HDR values beyond it.
        let params: JSONValue = ["inBlack": 15, "inWhite": 230, "gamma": 1.3, "outBlack": 10, "outWhite": 245]
        for depth in [8, 16, 32] {
            let s = Session()
            try s.execute("file.new", ["width": 16, "height": 16, "depth": .int(depth), "background": "white"])
            try adjustTestPaint(s, SIMD4(0, 0, 0, 1), PixelRect(x: 0, y: 0, width: 8, height: 16))
            try s.execute("image.adjustments.levels", params)
            let px = pixels(s)
            if depth == 32 {
                #expect(px[0][0].isFinite && px[0][0] < 0, "float black keeps its signed result: \(px[0])")
                #expect(px[1][0].isFinite && px[1][0] > 1, "float white keeps its HDR result: \(px[1])")
            } else {
                #expect(abs(px[0][0] * 255 - 10) < 0.6, "black @\(depth): \(px[0])")
                #expect(abs(px[1][0] * 255 - 245) < 0.6, "white @\(depth): \(px[1])")
            }
        }
    }

    @Test func cmykAndLabDocumentsUseTheirChannels() throws {
        var s = try colourful("cmyk", 8)
        var before = pixels(s)
        // More black ink darkens every patch.
        try s.execute("image.adjustments.curves", ["black": [[0, 0], [255, 180]]])
        var after = pixels(s)
        #expect(zip(after, before).allSatisfy { $0[3] > $1[3] + 0.05 }, "\(after) vs \(before)")
        s = try colourful("lab", 16)
        before = pixels(s)
        try s.execute("image.adjustments.levels", ["lightness": ["outBlack": 60]])
        after = pixels(s)
        #expect(zip(after, before).allSatisfy { $0[0] >= $1[0] }, "lightness lifted \(after) vs \(before)")
        // The adjustment layer of a CMYK document defaults to ink channels.
        s = try colourful("cmyk", 8)
        try s.execute("layer.newAdjustmentLayer.curves")
        let id = try #require(s.active?.activeLayer)
        guard case .adjustment(.curves(let c))? = s.active?.doc.layer(id)?.content else {
            Issue.record("expected a Curves layer")
            return
        }
        #expect(c.space == .cmyk)
    }

    @Test func setAdjustmentMergesAndResets() throws {
        let s = try colourful("rgb", 8)
        try s.execute("layer.newAdjustmentLayer.colorBalance", ["midtones": [30, 0, 0]])
        try s.execute("layer.setAdjustment", ["highlights": [0, 0, -20]])
        let id = try #require(s.active?.activeLayer)
        func adj() -> Adjustment? { if case .adjustment(let a)? = s.active?.doc.layer(id)?.content { a } else { nil } }
        if case .colorBalance(let cb)? = adj() {
            #expect(cb.midtones == SIMD3(30, 0, 0) && cb.highlights == SIMD3(0, 0, -20))
        } else { Issue.record("expected Color Balance") }
        try s.execute("layer.setAdjustment", ["layer": .id(id)])
        #expect(adj() == (try AdjustParams.defaultFor("colorBalance", mode: .rgb)))
        // Bad params are errors and leave the layer alone.
        try s.execute("layer.setAdjustment", ["midtones": [10, 10, 10]])
        let kept = adj()
        for bad: JSONValue in [["midtones": "x"], ["preserveLuminosity": 3], ["shadows": [1]]] {
            #expect(throws: EngineError.self, "\(bad)") { try s.execute("layer.setAdjustment", bad) }
            #expect(adj() == kept)
        }
    }

    @Test func commandsRejectBadParamsGracefully() throws {
        let s = try colourful("rgb", 8)
        let cases: [(String, JSONValue)] = [
            ("curves", ["points": [[0, 0]]]), ("levels", ["red": "dark"]), ("gradientMap", ["stops": [[0, 1, 2]]]),
            ("photoFilter", ["filter": 3]), ("channelMixer", ["gray": [1, 2]]), ("hueSaturation", ["reds": 4]), ("blackWhite", ["tint": "yes"]),
        ]
        for (kind, p) in cases {
            for prefix in ["image.adjustments.", "layer.newAdjustmentLayer."] {
                do {
                    try s.execute("\(prefix)\(kind)", p)
                    Issue.record("\(prefix)\(kind) \(p) succeeded")
                } catch EngineError.badParams {
                } catch {
                    Issue.record("\(prefix)\(kind) \(p): \(error)")
                }
            }
        }
    }

    // MARK: crates/engine/src/tests.rs

    @Test func everyAdjustmentCommandRuns() throws {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 48])
        let ids = s.registry.specs.filter { ($0.id.hasPrefix("layer.newAdjustmentLayer.") || $0.id.hasPrefix("image.adjustments.")) && $0.isAvailable }.map(\.id)
        #expect(ids.count >= 28)
        for id in ids {
            // Re-select the background for the destructive ones.
            let bg = try #require(s.active?.doc.layers.first?.id)
            try s.selectLayer(bg)
            #expect(throws: Never.self, "\(id)") { try s.execute(id) }
        }
    }

    @Test func thresholdAndHueParams() throws {
        let s = Session()
        try s.execute("file.new", ["width": 64, "height": 48])
        try adjustTestPaint(s, try #require(Params.parseHex("#404040")))
        try s.execute("layer.newAdjustmentLayer.threshold", ["level": 128])
        #expect(try adjustTestPixel(s, 0, 0) == [0, 0, 0, 1])
        try s.execute("layer.setAdjustment", ["level": 10])
        #expect(try adjustTestPixel(s, 0, 0) == [1, 1, 1, 1])
    }

    @Test func levelsAndCurvesParamsCoverOutputAndChannels() throws {
        guard case .levels(let l) = try from("levels", ["inBlack": 10, "outWhite": 200, "green": ["gamma": 1.5]]) else {
            Issue.record("expected Levels")
            return
        }
        #expect(abs(l.master.inBlack - 10 / 255) < 1e-6 && abs(l.master.outWhite - 200 / 255) < 1e-6)
        #expect(l.perChannel[1].gamma == 1.5)
        #expect(l.perChannel[0].gamma == 1)
        guard case .curves(let c) = try from("curves", ["points": [[0, 0], [128, 160], [255, 255]], "blue": [[0, 20], [255, 235]]]) else {
            Issue.record("expected Curves")
            return
        }
        #expect(c.master.count == 3)
        #expect(abs(c.perChannel[2][0].output - 20 / 255) < 1e-6)
        #expect(c.perChannel[0].count == 2)
    }
}


/// Brightness/Contrast's `mode` param (Photoshop 27: legacy / modern / light).
@Suite struct BrightnessContrastModeParamTests {
    @Test func modeDefaultsKeepTodaysBehaviourAndLightRoundTrips() throws {
        func bc(_ p: JSONValue, base: Adjustment? = nil) throws -> Adjustment.BrightnessContrast {
            guard case .brightnessContrast(let b) = try AdjustParams.fromParams("brightnessContrast", p, base: base, mode: .rgb) else {
                throw EngineError.other("not B/C")
            }
            return b
        }
        #expect(try bc(["brightness": 20]).mode == .modern)
        #expect(try bc(["legacy": true]).mode == .legacy)
        let light = try bc(["mode": "light", "contrast": 35, "exposure": 0.5, "whites": 10, "shadows": -15])
        #expect(light.mode == .light && light.contrast == 35 && light.exposure == 0.5 && light.whites == 10 && light.shadows == -15)
        // Editing a Light adjustment without naming the mode keeps it Light.
        #expect(try bc(["contrast": 20], base: .brightnessContrast(light)).mode == .light)
        let p = AdjustParams.toParams(.brightnessContrast(light))
        #expect(try bc(p) == light)
        #expect(AdjustParams.toParams(.brightnessContrast(.init(brightness: 1, contrast: 2, legacy: false))) == ["brightness": 1, "contrast": 2, "legacy": false])
        #expect(throws: (any Error).self) { try bc(["mode": "bright"]) }
    }

    /// Photoshop 27's ranges (M3 descriptor): Light's Contrast −100…100, Modern's −50…100,
    /// Exposure −5…5.
    @Test func lightRangesFollowPhotoshop() throws {
        func bc(_ p: JSONValue) throws -> Adjustment.BrightnessContrast {
            guard case .brightnessContrast(let b) = try AdjustParams.fromParams("brightnessContrast", p, base: nil, mode: .rgb) else {
                throw EngineError.other("not B/C")
            }
            return b
        }
        #expect(try bc(["mode": "light", "contrast": -100]).contrast == -100)
        #expect(try bc(["mode": "light", "exposure": -5]).exposure == -5)
        // Out-of-range values clamp, as Photoshop's descriptor does.
        #expect(try bc(["mode": "modern", "contrast": -100]).contrast == -50)
        #expect(try bc(["mode": "light", "exposure": 6]).exposure == 5)
        #expect(try bc(["mode": "light", "contrast": -130]).contrast == -100)
    }
}
