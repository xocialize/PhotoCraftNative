// Reads CameraRawModel.json, the fitted parameters of Camera Raw's slider stops (CameraRawModel.swift), into `Stage`s.

import Foundation
import PCFoundation
import simd

extension CameraRawKit.Model {
    /// The resource's shape. Each stop is its packed parameters, or null where the slider leaves the picture as it is;
    /// a stop's parameters pack its slider's blocks in order: matrix (9: the offset from the identity, row by row),
    /// curves (3 × 24 log rises of each channel's grey curve), chroma (the log of its scale), hue (24 × [hue shift in turns, log saturation scale, log value scale], then the saturation weights at 0.25, 0.5
    /// and 0.75), tone (3 mix logits, the brightest-channel share as a logit, 9 saturation-exponent knots, 24 log rises
    /// of the grey curve) and tint (11 × 3 inner offset knots).
    struct File: Decodable {
        struct Slider<Stops: Decodable>: Decodable {
            var blocks: [String]
            var hueGamma: Float
            var stops: Stops
        }
        typealias Stop = [Float]?
        var format: Int
        var toProPhoto: [Float]
        var fromProPhoto: [Float]
        var exposure: Slider<[Stop]>
        var whiteBalance: Slider<[[Stop]]>
        var contrast: Slider<[[Stop]]>
        var highlights: Slider<[[Stop]]>
        var shadows: Slider<[[Stop]]>
        var whites: Slider<[Stop]>
        var blacks: Slider<[Stop]>
        var saturation: Slider<[Stop]>
        var vibrance: Slider<[Stop]>
        var mixerLuminance: Slider<[[Stop]]>
        var mixerSaturation: Slider<[[Stop]]>
        var mixerHue: Slider<[[Stop]]>
        var calibration: Slider<[[Stop]]>
        var parametric: Slider<[[Stop]]>
        var gradingLuminance: Slider<[[Stop]]>
        var gradingShadows: Slider<[[[Stop]]]>
        var gradingHighlights: Slider<[[[Stop]]]>
        var gradingMidtones: Slider<[[[Stop]]]>
        var gradingGlobal: Slider<[[[Stop]]]>
    }

    static let hueNodes = 24, curveKnots = 25, shapeKnots = 9, tintKnots = 13
    static let blockSizes: [String: Int] = ["matrix": 9, "curves": 3 * 24, "chroma": 1, "hue": 3 * 24 + 3, "tone": 3 + 1 + 9 + 24, "tint": 11 * 3]

    static func load() -> Library? {
        guard let url = Bundle.module.url(forResource: "CameraRawModel", withExtension: "json"),
              let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data),
              file.format == 1, file.toProPhoto.count == 9, file.fromProPhoto.count == 9 else { return nil }
        func one(_ s: File.Slider<[File.Stop]>) -> [Stage?] { s.stops.map { $0.flatMap { stage($0, blocks: s.blocks, hueGamma: s.hueGamma) } } }
        func two(_ s: File.Slider<[[File.Stop]]>) -> [[Stage?]] {
            s.stops.map { row in row.map { $0.flatMap { stage($0, blocks: s.blocks, hueGamma: s.hueGamma) } } }
        }
        func three(_ s: File.Slider<[[[File.Stop]]]>) -> [[[Stage?]]] {
            s.stops.map { a in a.map { b in b.map { $0.flatMap { stage($0, blocks: s.blocks, hueGamma: s.hueGamma) } } } }
        }
        let library = Library(
            toProPhoto: rows(file.toProPhoto), fromProPhoto: rows(file.fromProPhoto),
            exposure: one(file.exposure), whiteBalance: two(file.whiteBalance),
            adaptive: ["contrast": two(file.contrast), "highlights": two(file.highlights), "shadows": two(file.shadows)],
            quarter: ["whites": one(file.whites), "blacks": one(file.blacks), "saturation": one(file.saturation), "vibrance": one(file.vibrance)],
            mixer: [two(file.mixerLuminance), two(file.mixerSaturation), two(file.mixerHue)],
            calibration: two(file.calibration), parametric: two(file.parametric), gradingLuminance: two(file.gradingLuminance),
            wheels: [three(file.gradingShadows), three(file.gradingHighlights), three(file.gradingMidtones), three(file.gradingGlobal)])
        // The grids the slider logic indexes.
        func grid(_ g: [[Stage?]], _ rows: Int, _ columns: Int) -> Bool { g.count == rows && g.allSatisfy { $0.count == columns } }
        func wheel(_ w: [[[Stage?]]], _ blendings: Int) -> Bool { w.count == blendings && w.allSatisfy { grid($0, 12, 3) } }
        let shapes: [Bool] = [
            library.exposure.count == 21, grid(library.whiteBalance, 9, 9),
            library.adaptive.values.allSatisfy { grid($0, 7, 7) }, library.quarter.values.allSatisfy { $0.count == 9 },
            library.mixer.allSatisfy { grid($0, 8, 5) }, grid(library.calibration, 6, 5), grid(library.parametric, 4, 5),
            grid(library.gradingLuminance, 4, 5), wheel(library.wheels[0], 3), wheel(library.wheels[1], 3),
            wheel(library.wheels[2], 1), wheel(library.wheels[3], 1),
        ]
        guard shapes.allSatisfy({ $0 }) else { return nil }
        return library
    }

    /// A grey curve from its log rises between the evenly spaced knots, from 0 at black, sampled for `Tone.curve`.
    private static func greyCurve(_ rises: [Float]) -> [Float] {
        var ys: [Float] = [0]
        for r in rises { ys.append(ys[ys.count - 1] + expf(clampf(r, -30, 5))) }
        return Pchip(even: ys).samples(curveSamples)
    }

    private static func rows(_ v: [Float]) -> simd_float3x3 {
        simd_float3x3(rows: [SIMD3(v[0], v[1], v[2]), SIMD3(v[3], v[4], v[5]), SIMD3(v[6], v[7], v[8])])
    }

    /// One stop from its packed parameters.
    static func stage(_ p: [Float], blocks: [String], hueGamma: Float) -> Stage? {
        guard p.count == blocks.reduce(0, { $0 + (blockSizes[$1] ?? .max / 8) }) else { return nil }
        var stage = Stage()
        var k = 0
        for block in blocks {
            let q = Array(p[k..<(k + blockSizes[block]!)])
            k += q.count
            switch block {
            case "matrix":
                stage.matrix = rows(q) + matrix_identity_float3x3
            case "chroma":
                stage.chroma = expf(q[0])
            case "curves":
                stage.curves = (0..<3).map { ch in greyCurve(Array(q[(ch * (curveKnots - 1))..<((ch + 1) * (curveKnots - 1))])) }
            case "hue":
                let nodes = (0..<hueNodes).map { SIMD3(q[3 * $0], q[3 * $0 + 1], q[3 * $0 + 2]) }
                stage.hue = Stage.Hue(nodes: nodes, weights: [0] + q[(3 * hueNodes)...] + [1], gamma: hueGamma)
            case "tone":
                let logits = SIMD3(q[0], q[1], q[2])
                let e = exp(logits - SIMD3(repeating: logits.max()))
                stage.tone = Stage.Tone(mix: e / (e.x + e.y + e.z), brightestShare: 1 / (1 + expf(-q[3])),
                                        curve: greyCurve(Array(q[(4 + shapeKnots)...])),
                                        shape: Pchip(even: Array(q[4..<(4 + shapeKnots)])).samples(shapeSamples))
            case "tint":
                let channels = (0..<3).map { ch in Pchip(even: [0] + (0..<(tintKnots - 2)).map { q[3 * $0 + ch] } + [0]).samples(tintSamples) }
                stage.tint = Stage.Tint(offsets: (0..<tintSamples).map { SIMD3(channels[0][$0], channels[1][$0], channels[2][$0]) })
            default:
                return nil
            }
        }
        return stage
    }

    /// SciPy's `PchipInterpolator` (monotone piecewise cubic Hermite, Fritsch–Butland derivatives with its one-sided
    /// three-point ends), through values at evenly spaced knots on 0…1, as the fit evaluated its curves.
    struct Pchip {
        let x: [Double], y: [Double], d: [Double]

        init(even values: [Float]) {
            let n = values.count
            let xs = (0..<n).map { Double($0) / Double(n - 1) }
            let ys = values.map(Double.init)
            let h = (0..<(n - 1)).map { xs[$0 + 1] - xs[$0] }
            let m = (0..<(n - 1)).map { (ys[$0 + 1] - ys[$0]) / h[$0] }
            var slopes = [Double](repeating: 0, count: n)
            if n == 2 {
                slopes = [m[0], m[0]]
            } else {
                for k in 1..<(n - 1) {
                    let w1 = 2 * h[k] + h[k - 1], w2 = h[k] + 2 * h[k - 1]
                    if Self.sign(m[k - 1]) != Self.sign(m[k]) || m[k - 1] == 0 || m[k] == 0 { continue }
                    slopes[k] = 1 / ((w1 / m[k - 1] + w2 / m[k]) / (w1 + w2))
                }
                slopes[0] = Self.edge(h[0], h[1], m[0], m[1])
                slopes[n - 1] = Self.edge(h[n - 2], h[n - 3], m[n - 2], m[n - 3])
            }
            x = xs; y = ys; d = slopes
        }

        private static func sign(_ v: Double) -> Double { v > 0 ? 1 : v < 0 ? -1 : 0 }

        /// SciPy's one-sided three-point end slope, kept from overshooting.
        private static func edge(_ h0: Double, _ h1: Double, _ m0: Double, _ m1: Double) -> Double {
            let e = ((2 * h0 + h1) * m0 - h0 * m1) / (h0 + h1)
            if sign(e) != sign(m0) { return 0 }
            if sign(m0) != sign(m1) && abs(e) > 3 * abs(m0) { return 3 * m0 }
            return e
        }

        func callAsFunction(_ t: Double) -> Double {
            let n = x.count
            let k = min(max(Int(t * Double(n - 1)), 0), n - 2)
            let h = x[k + 1] - x[k], s = (t - x[k]) / h
            let h00 = (1 + 2 * s) * (1 - s) * (1 - s), h10 = s * (1 - s) * (1 - s)
            let h01 = s * s * (3 - 2 * s), h11 = s * s * (s - 1)
            return h00 * y[k] + h10 * h * d[k] + h01 * y[k + 1] + h11 * h * d[k + 1]
        }

        func samples(_ count: Int) -> [Float] { (0..<count).map { Float(self(Double($0) / Double(count - 1))) } }
    }
}
