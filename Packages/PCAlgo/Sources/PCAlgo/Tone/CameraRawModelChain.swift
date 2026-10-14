// Camera Raw's per-pixel color stages for a set of settings (CameraRawModel.swift): which fitted stops each slider
// blends, in the order Compositor found composes like Photoshop's, and the whole run composed over a lattice of colors,
// so a pixel costs one lookup.

import Foundation
import PCFoundation
import simd
import Synchronization

extension CameraRawKit.Model {
    /// One step of the run, on sRGB-encoded color.
    enum Step: Sendable {
        /// A slider: its stops' results, weighted (nil is the color as it is).
        case blend([(stage: Stage?, weight: Float)])
        /// The tone curves (parametric with moved dividers, then the point curves), on the document's encoding.
        case curves(parametric: [Float]?, master: [Float]?, channels: [[Float]?])
    }

    /// Where a run starts and stops: before Dehaze, Texture and Clarity (Calibration, Exposure, white balance), after
    /// them (everything else), or all of it when none of them is on.
    enum Part: Hashable, Sendable { case before, after, all }

    /// The per-pixel color stages of `p`, on colors encoded as the document is.
    struct Chain: Sendable {
        var steps: [Step] = []
        var encoding = CameraRawKit.Encoding(gamma: 0)

        var isIdentity: Bool { steps.isEmpty }

        /// One color, each channel 0…1 in the document's encoding.
        func callAsFunction(_ color: SIMD3<Float>) -> SIMD3<Float> {
            var c = simd_clamp(color, .zero, SIMD3(repeating: 1))
            let srgb = encoding.gamma == 0
            if !srgb { c = SIMD3(encode(encoding.decode(c.x)), encode(encoding.decode(c.y)), encode(encoding.decode(c.z))) }
            for step in steps {
                switch step {
                case .blend(let terms):
                    var out = SIMD3<Float>()
                    for term in terms { out += term.weight * (term.stage.map { $0(c) } ?? c) }
                    c = simd_clamp(out, .zero, SIMD3(repeating: 1))
                case .curves(let parametric, let master, let channels):
                    var d = srgb ? c : SIMD3(encoding.encode(decode(c.x)), encoding.encode(decode(c.y)), encoding.encode(decode(c.z)))
                    for lut in [parametric, master] {
                        if let lut { lut.withUnsafeBufferPointer { b in d = SIMD3(CameraRawKit.lutEval(b, d.x), CameraRawKit.lutEval(b, d.y), CameraRawKit.lutEval(b, d.z)) } }
                    }
                    for ch in 0..<3 { if let lut = channels[ch] { lut.withUnsafeBufferPointer { d[ch] = CameraRawKit.lutEval($0, d[ch]) } } }
                    d = simd_clamp(d, .zero, SIMD3(repeating: 1))
                    c = srgb ? d : SIMD3(encode(encoding.decode(d.x)), encode(encoding.decode(d.y)), encode(encoding.decode(d.z)))
                }
            }
            if !srgb { c = SIMD3(encoding.encode(decode(c.x)), encoding.encode(decode(c.y)), encoding.encode(decode(c.z))) }
            return c
        }

        /// The run over a `size`³ lattice of colors, red slowest then green then blue, 3 values each.
        func lattice(size: Int) -> [Float] {
            var out = [Float](repeating: 0, count: size * size * size * 3)
            let step = 1 / Float(size - 1)
            out.withUnsafeMutableBufferPointer { o in
                let os = UnsafeSendable(o)
                parallelChunks(size * size, minChunk: 4) { rows in
                    for rg in rows {
                        let r = rg / size, g = rg % size
                        for b in 0..<size {
                            let v = self(SIMD3(Float(r) * step, Float(g) * step, Float(b) * step))
                            let k = (rg * size + b) * 3
                            os.value[k] = v.x; os.value[k + 1] = v.y; os.value[k + 2] = v.z
                        }
                    }
                }
            }
            return out
        }
    }

    // MARK: Building a run

    /// The two entries of `points` (rising) either side of `value` (clamped to them) and how far it is between them.
    static func between(_ value: Float, in points: [Float]) -> (Int, Float) {
        let v = clampf(value, points[0], points[points.count - 1])
        var i = 0
        while i < points.count - 2 && v > points[i + 1] { i += 1 }
        return (i, (v - points[i]) / (points[i + 1] - points[i]))
    }

    /// The two stops either side of `value` on a run of `count` stops `step` apart from `low`.
    static func between(_ value: Float, low: Float, step: Float, count: Int) -> (Int, Float) {
        let position = clampf((value - low) / step, 0, Float(count - 1))
        let i = min(count - 2, Int(position))
        return (i, position - Float(i))
    }

    static func run(_ stops: [Stage?], _ value: Float, low: Float, step: Float) -> Step {
        let (i, t) = between(value, low: low, step: step, count: stops.count)
        return .blend([(stops[i], 1 - t), (stops[i + 1], t)])
    }

    static func fifty(_ stops: [Stage?], _ value: Float) -> Step { run(stops, value, low: -100, step: 50) }

    /// The run for `p`: `part` picks the stages either side of Dehaze, Texture and Clarity. `statistics` is what the
    /// adaptive sliders read; they need it only when one of them is on. `exposure` false leaves Exposure out (float
    /// documents take it as a gain in linear light instead, `CameraRawKit.exposureGain`).
    static func chain(_ p: CameraRaw, statistics: CameraRawStatistics?, part: Part, exposure: Bool = true) -> Chain {
        var chain = Chain(encoding: CameraRawKit.Encoding.of(p.encodingGamma))
        guard let lib = library else { return chain }
        var steps: [Step] = []
        if part != .after {
            let calibration = [p.calibrationRedHue, p.calibrationRedSaturation, p.calibrationGreenHue, p.calibrationGreenSaturation,
                               p.calibrationBlueHue, p.calibrationBlueSaturation]
            for (k, v) in calibration.enumerated() where v != 0 { steps.append(fifty(lib.calibration[k], v)) }
            if exposure && p.exposure != 0 { steps.append(run(lib.exposure, p.exposure, low: -5, step: 0.5)) }
            if p.temperature != 0 || p.tint != 0 {
                let (r, down) = between(p.temperature, low: -100, step: 25, count: 9)
                let (c, across) = between(p.tint, low: -100, step: 25, count: 9)
                let wb = lib.whiteBalance
                steps.append(.blend([(wb[r][c], (1 - down) * (1 - across)), (wb[r][c + 1], (1 - down) * across),
                                     (wb[r + 1][c], down * (1 - across)), (wb[r + 1][c + 1], down * across)]))
            }
        }
        if part != .before {
            let stats = statistics ?? CameraRawStatistics()
            for (name, value, brightness) in [("contrast", p.contrast, stats.brightest), ("highlights", p.highlights, stats.logBrightest),
                                              ("shadows", p.shadows, stats.luminance)] where value != 0 {
                let grid = lib.adaptive[name]!
                let (row, down) = between(brightness, in: brightnesses)
                let (col, across) = between(value, in: adaptiveValues)
                steps.append(.blend([(grid[row][col], (1 - down) * (1 - across)), (grid[row][col + 1], (1 - down) * across),
                                     (grid[row + 1][col], down * (1 - across)), (grid[row + 1][col + 1], down * across)]))
            }
            for (name, value) in [("whites", p.whites), ("blacks", p.blacks), ("saturation", p.saturation), ("vibrance", p.vibrance)]
                where value != 0 {
                steps.append(run(lib.quarter[name]!, value, low: -100, step: 25))
            }
            // The parametric curve's fitted stops hold while its dividers are where they were fitted; moved, its formula
            // goes into the curve step.
            let fitted = p.curveSplits == [25, 50, 75]
            if fitted {
                for (k, v) in [p.curveShadows, p.curveDarks, p.curveLights, p.curveHighlights].enumerated() where v != 0 {
                    steps.append(fifty(lib.parametric[k], v))
                }
            }
            func points(_ c: [SIMD2<Float>]) -> [Float]? { CameraRawKit.isLinear(c) ? nil : CameraRawKit.curveLUT(c, 1024) }
            let parametric = fitted || p.parametricNeutral ? nil : CameraRawKit.parametricLUT(p, 1024)
            let master = points(p.pointCurve)
            let channels = [points(p.pointCurveRed), points(p.pointCurveGreen), points(p.pointCurveBlue)]
            if parametric != nil || master != nil || channels.contains(where: { $0 != nil }) {
                steps.append(.curves(parametric: parametric, master: master, channels: channels))
            }
            // The Color Mixer: luminance, then saturation, then hue, the order that composes like Photoshop's.
            for (kind, values) in [p.hslLum, p.hslSat, p.hslHue].enumerated() {
                for (color, v) in values.enumerated() where v != 0 { steps.append(fifty(lib.mixer[kind][color], v)) }
            }
            steps += grading(p, lib)
        }
        chain.steps = steps
        return chain
    }

    /// Color Grading: the luminance sliders, then the global and midtone wheels, then highlights, then shadows. A wheel
    /// blends the stops either side of its hue (30° apart) and saturation (25, 50, 100; below 25 toward no change), the
    /// shadow and highlight wheels also between the Blending stops (0, 50, 100); the midtone and global wheels hold
    /// Photoshop's default Blending. Balance strengthens one of those two wheels and weakens the other, as a share of
    /// saturation (Compositor's fit to Photoshop's renders at ±50).
    static func grading(_ p: CameraRaw, _ lib: Library) -> [Step] {
        var steps: [Step] = []
        for (k, wheel) in [p.gradeShadows, p.gradeMidtones, p.gradeHighlights, p.gradeGlobal].enumerated() where wheel.lum != 0 {
            steps.append(fifty(lib.gradingLuminance[k], clampf(wheel.lum, -100, 100)))
        }
        let balance = clampf(p.gradeBalance, -100, 100) / 100
        let highlightShare = Float.maximum(0, balance < 0 ? 1 + 1.4 * balance : 1 + 2 * balance)
        let shadowShare = Float.maximum(0, balance < 0 ? 1 - 1.2 * balance : 1 - 1.4 * balance)
        let (blendLow, blendUp) = between(clampf(p.gradeBlending, 0, 100), in: [0, 50, 100])
        // Library order: shadows, highlights, midtones, global.
        for (index, wheel, share, blends) in [(3, p.gradeGlobal, Float(1), false), (2, p.gradeMidtones, 1, false),
                                              (1, p.gradeHighlights, highlightShare, true), (0, p.gradeShadows, shadowShare, true)] {
            let saturation = clampf(wheel.sat, 0, 100) * share
            guard saturation > 0 else { continue }
            let position = euclidMod(wheel.hue, 360) / 30
            let first = Int(position) % 12, second = (first + 1) % 12, around = position - Float(Int(position))
            let (level, up) = between(saturation, in: [0, 25, 50, 100])
            let stops = lib.wheels[index]
            let blendings: [(Int, Float)] = blends ? [(blendLow, 1 - blendUp), (blendLow + 1, blendUp)] : [(0, 1)]
            var terms: [(stage: Stage?, weight: Float)] = []
            for (b, bw) in blendings {
                for (hue, hw) in [(first, 1 - around), (second, around)] {
                    for (sat, sw) in [(level, 1 - up), (level + 1, up)] {
                        terms.append((sat == 0 ? nil : stops[b][hue][sat - 1], bw * hw * sw))
                    }
                }
            }
            steps.append(.blend(terms))
        }
        return steps
    }

    // MARK: Lattices

    /// `lattice` (size³ × 3, red slowest) at `c`, by tetrahedral interpolation of the cube around it.
    @inline(__always) static func lookup(_ lattice: UnsafeBufferPointer<Float>, _ size: Int, _ c: SIMD3<Float>) -> SIMD3<Float> {
        let n = Float(size - 1)
        let p = simd_clamp(c, .zero, SIMD3(repeating: 1)) * n
        let i = SIMD3<Int>(min(Int(p.x), size - 2), min(Int(p.y), size - 2), min(Int(p.z), size - 2))
        let f = p - SIMD3<Float>(Float(i.x), Float(i.y), Float(i.z))
        @inline(__always) func at(_ dr: Int, _ dg: Int, _ db: Int) -> SIMD3<Float> {
            let k = (((i.x + dr) * size + (i.y + dg)) * size + (i.z + db)) * 3
            return SIMD3(lattice[k], lattice[k + 1], lattice[k + 2])
        }
        let c000 = at(0, 0, 0), c111 = at(1, 1, 1)
        if f.x >= f.y {
            if f.y >= f.z {
                let c100 = at(1, 0, 0), c110 = at(1, 1, 0)
                return c000 + f.x * (c100 - c000) + f.y * (c110 - c100) + f.z * (c111 - c110)
            } else if f.x >= f.z {
                let c100 = at(1, 0, 0), c101 = at(1, 0, 1)
                return c000 + f.x * (c100 - c000) + f.z * (c101 - c100) + f.y * (c111 - c101)
            } else {
                let c001 = at(0, 0, 1), c101 = at(1, 0, 1)
                return c000 + f.z * (c001 - c000) + f.x * (c101 - c001) + f.y * (c111 - c101)
            }
        } else {
            if f.z >= f.y {
                let c001 = at(0, 0, 1), c011 = at(0, 1, 1)
                return c000 + f.z * (c001 - c000) + f.y * (c011 - c001) + f.x * (c111 - c011)
            } else if f.z >= f.x {
                let c010 = at(0, 1, 0), c011 = at(0, 1, 1)
                return c000 + f.y * (c010 - c000) + f.z * (c011 - c010) + f.x * (c111 - c011)
            } else {
                let c010 = at(0, 1, 0), c110 = at(1, 1, 0)
                return c000 + f.y * (c010 - c000) + f.x * (c110 - c010) + f.z * (c111 - c110)
            }
        }
    }

    /// The lattice the CPU and Metal paths both apply. The fitted stages bend sharply at the gamut's edge and between hue
    /// nodes, so its interpolation needs a fine lattice: against the stages themselves on random colors, 33³ is off by
    /// a p99 of about 6 levels (mean 0.4), 49³ by 4 (0.2), 65³ by 2 (0.16).
    static let latticeSize = 65

    /// The lattice of `p`'s run (`chain`), or nil when it changes nothing. The last few are kept: a filter runs again
    /// with the same settings for each tile and plane, and while a preview is adjusted.
    static func lattice(_ p: CameraRaw, statistics: CameraRawStatistics?, part: Part, exposure: Bool) -> [Float]? {
        let key = LatticeKey(settings: p, statistics: statistics, part: part, exposure: exposure)
        if let hit = lattices.withLock({ $0.first { $0.key == key }?.lattice }) { return hit }
        let chain = chain(p, statistics: statistics, part: part, exposure: exposure)
        let lattice = chain.isIdentity ? nil : chain.lattice(size: latticeSize)
        lattices.withLock { cache in
            cache.removeAll { $0.key == key }
            cache.insert((key, lattice), at: 0)
            if cache.count > 4 { cache.removeLast() }
        }
        return lattice
    }

    struct LatticeKey: Hashable {
        var settings: CameraRaw
        var statistics: CameraRawStatistics?
        var part: Part
        var exposure: Bool
    }

    private static let lattices = Mutex<[(key: LatticeKey, lattice: [Float]?)]>([])

    /// Applies the run of `p` to straight RGBA pixels through its lattice. In float documents a value past 0…1 keeps its
    /// excess.
    static func apply(_ p: CameraRaw, statistics: CameraRawStatistics?, part: Part, exposure: Bool, to px: inout [SIMD4<Float>],
                      float: Bool) {
        guard let lattice = lattice(p, statistics: statistics, part: part, exposure: exposure) else { return }
        let size = latticeSize
        lattice.withUnsafeBufferPointer { l in
            let ls = UnsafeSendable(l)
            CameraRawKit.forEach(&px) { q in
                let c = SIMD3(q.x, q.y, q.z)
                let inside = simd_clamp(c, .zero, SIMD3(repeating: 1))
                var o = lookup(ls.value, size, inside)
                if float { o += c - inside }
                q = SIMD4(o, q.w)
            }
        }
    }
}
