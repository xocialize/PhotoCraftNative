// Port of photocraft-compose (crates/compose/src/adjust.rs) and photocraft-gpu (compose.wgsl), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Evaluation of adjustment layers on a composite buffer — the CPU reference the Metal `pcr_adjust`
// kernels match. Formulas are photocraft's (fitted to Photoshop 27.11 measurements; see the comments
// carried over from adjust.rs). Tables (tone LUTs, hue-range tables, matrices) are built once per
// adjustment in `PreparedAdjustment` and shared by every tile and by the GPU upload.

import Foundation
import PCDocument
import PCFoundation
import simd

/// The document tone curve adjustments that work in linear light use.
public enum Transfer: Hashable, Sendable {
    /// sRGB piecewise curve.
    case srgb
    /// Pure power law with this exponent.
    case gamma(Float)

    /// Default transfer for a document: 32-bit samples are linear; grey documents use the
    /// "Dot Gain 20%" fit (γ 1.732); everything else sRGB.
    public static func forDocument(mode: ColorMode, depth: SampleType) -> Transfer {
        if depth == .f32 { return .gamma(1) }
        switch mode {
        case .grayscale, .duotone, .bitmap: return .gamma(1.732)
        default: return .srgb
        }
    }

    /// Exposure linearises RGB documents through a pure 2.2 power, grey documents their gamma.
    public var forExposure: Transfer {
        if case .srgb = self { return .gamma(2.2) }
        return self
    }

    /// Tone-encoded value → linear light.
    @inline(__always) public func decode(_ v: Float) -> Float {
        switch self {
        case .srgb: return ColorConvert.srgbToLinear(max(v, 0))
        case .gamma(let g): return g == 1 ? max(v, 0) : powf(max(v, 0), g)
        }
    }

    /// Linear light → tone-encoded value.
    @inline(__always) public func encode(_ v: Float) -> Float {
        switch self {
        case .srgb: return ColorConvert.linearToSRGB(max(v, 0))
        case .gamma(let g): return g == 1 ? max(v, 0) : powf(max(v, 0), 1 / g)
        }
    }

    /// The shader's `t_decode` / `t_encode` exponent (0: the sRGB curve).
    var exponent: Float {
        switch self { case .srgb: 0; case .gamma(let g): g }
    }
}

/// Steps per unit an integer document's adjustment results are rounded to (8-bit: 255,
/// 16-bit: 32768; 32-bit: none) — Photoshop applies adjustment layers at the document's depth.
public func adjustmentQuantum(_ depth: SampleType) -> Float? {
    switch depth {
    case .u8: 255
    case .u16: 32768
    case .f32: nil
    }
}

public enum AdjustMath {
    /// Entries of every tone / hue table.
    public static let lutSize = 4096

    /// Legacy Brightness/Contrast pivot (128 of 255).
    public static let legacyPivot: Float = 128.0 / 255.0

    /// Weights of the grey Vibrance › Saturation desaturates to (R, G; blue has none).
    public static let vibranceGrey: SIMD2<Float> = SIMD2(0.288, 0.712)

    /// Positive Vibrance's saturation boost (c0, c1, p, q, r0, ra, rt), refitted to Photoshop
    /// 27.11 (M1 lattice, Vibrance 50 / 100): photocraft's fit (0.5001, 0.0887, 0.4374, 0.7573,
    /// −0.8113, 0.5154, 2.8026) was 2.4–5.7 levels mean off there.
    public static let vibranceBoost: [Float] = [0.7674, 0.08208, 0.5788, 0.9946, -0.2027, 0.1551, 1.9724]

    /// Positive Vibrance's brightness lift (× v × shape; photocraft ¼).
    public static let vibranceLift: Float = 0.2478

    /// Skin protection of positive Vibrance: hue h1 (full) → h2 (none) … h3 (none) → 360 (full),
    /// then protection w · min(1, (c0 + c1 (1 − v)) (1 − t)^k), so saturated skin tones still move.
    /// (h1, h2, h3, c0, c1, k).
    public static let vibranceSkinFit: [Float] = [30.17, 45.16, 298.34, 0.7761, 1.0504, 0.9268]

    /// Dark roll-off of positive Vibrance's boost, × mx / (mx + d). (Negative Vibrance keeps
    /// photocraft's form: a roll-off there cut its max error but raised the mean 0.1 → 0.6.)
    public static let vibranceDark: Float = 0.005788

    /// How far one Color Balance slider at ±100 moves the black or white point.
    public static let balanceLevels: Float = 0.39

    @inline(__always) public static func lut(_ table: [Float], _ v: Float) -> Float {
        table.withUnsafeBufferPointer { lut($0, v) }
    }

    @inline(__always) static func lut(_ t: UnsafeBufferPointer<Float>, _ v: Float) -> Float {
        let n = t.count
        let x = (v.isNaN ? 0 : min(max(v, 0), 1)) * Float(n - 1)
        let i = Int(x.rounded(.down))
        let j = min(i + 1, n - 1)
        let f = x - Float(i)
        return t[i] * (1 - f) + t[j] * f
    }

    // MARK: Brightness / Contrast

    /// Legacy Brightness/Contrast as one channel's tone curve.
    public static func legacyBrightnessContrast(_ brightness: Float, _ contrast: Float) -> (pre: Float, k: Float, post: Float) {
        let b = brightness / 255
        let c = min(max(contrast, -100), 99)
        let k: Float = c >= 0 ? 1 / (1 - c / 100) : 1 + c / 100
        return c >= 0 ? (b, k, 0) : (0, k, b)
    }

    @inline(__always) static func legacyCurve(_ v: Float, _ p: (pre: Float, k: Float, post: Float)) -> Float {
        min(max((v + p.pre - legacyPivot) * p.k + legacyPivot + p.post, 0), 1)
    }

    /// Modern Brightness curve (`brightness` −150…150).
    public static func modernBrightness(_ v0: Float, _ brightness: Float) -> Float {
        if brightness == 0 { return v0 }
        let s = powf(1.375, brightness / 50)
        let p: Float = brightness >= 0 ? max(4.5 - 0.013 * brightness, 2) : 5 - 0.072 * brightness
        let v = min(max(v0, 0), 1)
        return min(max(s * v + (1 - s) * powf(v, p), 0), 1)
    }

    /// Modern Contrast curve (`contrast` −50…100): a cubic-Hermite S pivoting at 0.5.
    public static func modernContrast(_ v0: Float, _ contrast: Float) -> Float {
        if contrast == 0 { return v0 }
        let k = contrast / 128
        let (end, mid) = (1 - k, 1 + k)
        func half(_ t: Float) -> Float {
            end * 0.5 * (t * t * t - 2 * t * t + t) + (-2 * t * t * t + 3 * t * t) * 0.5 + mid * 0.5 * (t * t * t - t * t)
        }
        let v = min(max(v0, 0), 1)
        return v <= 0.5 ? half(v / 0.5) : 1 - half((1 - v) / 0.5)
    }

    // MARK: Brightness/Contrast, Modern and Light modes (Photoshop 27.11, M1 / M2)

    /// Modern Brightness's fit (Photoshop 27.11, M2 + ps-corpus adj-brightnessContrast-b25c35):
    /// the soft-clip exponent p(b) = x + y·exp(−|b| / z) and the slope at black w^(|b|/50).
    public static let modernBrightnessFit: SIMD4<Float> = SIMD4(4.161, 17.36, 10.68, 1.3776)

    /// Modern (`brightnessModeModern`) Brightness on one channel, `brightness` −150…150. Positive:
    /// y = m(s x) / m(s) with the soft minimum m(v) = (v⁻ᵖ + 1)^(−1/p), and s chosen so the slope
    /// at black is 1.3776^(b/50) — a straight line from black that rolls into white, its knee the
    /// sharper the smaller b (p 5.83 at +25, 4.32 at +50, 4.16 at +150). Negative: the inverse of
    /// the curve for |b| (Photoshop's −50 / −150 curves invert its +50 / +150 ones to 0.16 / 0.73
    /// levels mean). Fitted on +25 (the corpus file, through its Contrast 35), +50, +150: 0.33,
    /// 0.50, 0.67 levels rms; −50 / −150, held out, 0.58 / 0.70. photocraft's s x + (1 − s) xᵖ
    /// (`modernBrightness`) was up to 45 levels off.
    public static func modernBrightnessPS(_ v0: Float, _ brightness: Float) -> Float {
        modernBrightnessCurve(brightness)(v0)
    }

    /// `modernBrightnessPS` at `brightness` as a function of the value: the curve's parameters (its
    /// soft minimum's exponent and scale, found by bisection) are worked out once, not per value.
    static func modernBrightnessCurve(_ brightness: Float) -> (Float) -> Float {
        if brightness == 0 || !brightness.isFinite { return { v0 in Float(Double(min(max(v0, 0), 1))) } }
        let f = modernBrightnessFit
        let b = Double(min(abs(brightness), 150))
        let (p, base) = (Double(f.x) + Double(f.y) * exp(-b / Double(f.z)), Double(f.w))
        let slope = pow(base, b / 50)
        func sm(_ x: Double) -> Double { x <= 0 ? 0 : pow(pow(x, -p) + 1, -1 / p) }
        var (lo, hi) = (1.0, slope)
        for _ in 0..<60 { let m = (lo + hi) / 2; if m / sm(m) < slope { lo = m } else { hi = m } }
        let s = (lo + hi) / 2, top = sm(s)
        func fwd(_ x: Double) -> Double { min(sm(s * x) / top, 1) }
        let positive = brightness > 0
        return { v0 in
            let v = Double(min(max(v0, 0), 1))
            if positive { return Float(fwd(v)) }
            var (lo2, hi2) = (0.0, 1.0)
            for _ in 0..<50 { let m = (lo2 + hi2) / 2; if fwd(m) < v { lo2 = m } else { hi2 = m } }
            return Float((lo2 + hi2) / 2)
        }
    }

    /// Modern Brightness/Contrast's per-channel curve, `lutSize` entries: Contrast after Brightness
    /// (`modernContrast` — photocraft's, which Photoshop's −50…100 ramps match within 1 level —
    /// of `modernBrightnessPS`). Every channel takes the same curve (M2: the 64³ lattice is exactly
    /// per channel); the curve does not depend on the image (M2's nine pivot inputs agree exactly).
    public static func modernToneLUT(_ brightness: Float, _ contrast: Float) -> [Float] {
        let curve = modernBrightnessCurve(brightness)
        return (0..<lutSize).map { k in
            min(max(modernContrast(curve(Float(k) / Float(lutSize - 1)), contrast), 0), 1)
        }
    }

    /// Light mode's Contrast pivot in ProPhoto's γ 1.8 encoding (sRGB level 157 on a grey; the M1
    /// lattice's — Photoshop's Light pivot moves with the image, see PORT-NOTES phase 4).
    public static let contrastPivot: Float = 0.55
    /// Light mode's Contrast slopes: end 1 − c / x, pivot 1 + c / y (c ≥ 0) or 1 + c / z (c < 0).
    public static let contrastScales: SIMD3<Float> = SIMD3(136.4, 131.1, 168.9)

    /// ROMM (ProPhoto) γ 1.8 encoding with its linear toe, and back.
    @inline(__always) static func rommEncode(_ v: Float) -> Float { v < 1.0 / 512 ? v * 16 : powf(v, 1 / 1.8) }
    @inline(__always) static func rommDecode(_ v: Float) -> Float { v < 16.0 / 512 ? v / 16 : powf(v, 1.8) }

    /// Light mode's Contrast on a grey (sRGB-encoded `v`): a cubic Hermite S through (0, 0), the
    /// pivot and (1, 1) in ProPhoto's γ 1.8 encoding, end and pivot slopes from `contrastScales`.
    /// Fitted to Photoshop's grey ramps at −50, 50, 100 within 0.43 levels rms (rounding: 0.29);
    /// M3's ramps at −50, 50, 100 agree within 2 levels. Light's range is −100…100 (M3 descriptor;
    /// below −50 the slopes are extrapolated — no ramp measures it yet).
    public static func photoshopContrast(_ v0: Float, _ contrast: Float) -> Float {
        if contrast == 0 { return v0 }
        let c = min(max(contrast, -100), 100)
        let (p, s) = (contrastPivot, contrastScales)
        let end = 1 - c / s.x, mid = 1 + c / (c >= 0 ? s.y : s.z)
        func half(_ t: Float) -> Float {
            let (t2, t3) = (t * t, t * t * t)
            return (t3 - 2 * t2 + t) * end + (-2 * t3 + 3 * t2) + (t3 - t2) * mid
        }
        let x = rommEncode(ColorConvert.srgbToLinear(min(max(v0, 0), 1)))
        let y = x <= p ? p * half(x / p) : 1 - (1 - p) * half((1 - x) / (1 - p))
        return ColorConvert.linearToSRGB(rommDecode(min(max(y, 0), 1)))
    }

    /// Light mode's grey curve for Contrast alone, `lutSize` entries.
    public static func lightToneLUT(_ contrast: Float) -> [Float] {
        (0..<lutSize).map { k in photoshopContrast(Float(k) / Float(lutSize - 1), contrast) }
    }

    // MARK: Light mode's Exposure, Whites and Blacks (Photoshop 27.11, batch M3)

    /// Grey levels (sRGB-encoded, 0…255) of the `lightPsi…` samples.
    public static let lightPsiLevels: [Float] = [2, 4, 6, 8, 12, 16, 24, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224,
                                                 232, 240, 244, 248, 251, 253, 255]
    /// Light Exposure's exposure scale ψ, in stops from mid grey (level 128): Exposure `ev` maps a
    /// grey x to ψ⁻¹(ψ(x) + ev) — a gain of 2^ev in the scene domain 2^ψ, which is why ±1.25 twice
    /// is ±2.5 (M3: within 2 levels). Fitted by least squares to the M3 ramps (+1.25, +2.5, +5);
    /// +2.5 held out: max 2 levels, mean 0.99. Below level 2, ψ is log₂ x (code-value gain, the
    /// fitted slope there). The last two samples only carry the soft shoulder past level 251 —
    /// Photoshop's positive Exposure approaches white slowly and never clips below it.
    public static let lightPsiPositive: [Float] = [-7.1661, -6.1871, -5.6171, -5.1744, -4.5465, -4.0600, -3.3229, -2.8372, -2.0906,
                                                   -1.5854, -1.0656, -0.6994, -0.3402, 0, 0.2984, 0.5766, 0.8629, 1.2345, 1.6087,
                                                   2.0146, 2.3357, 2.7392, 2.9815, 3.2851, 3.7149, 4.7149, 7.7149]
    /// ψ for negative Exposure (M3 ramps −1.25, −2.5, −5): the same scale below level ~224, but
    /// white is darkened too (−5 takes white to 56), so the top is finite. −1.25's top 15 levels
    /// do not compose with the others (white 241 where −2.5 ∘ … implies ~228): up to 11 levels.
    public static let lightPsiNegative: [Float] = [-7.1620, -6.1496, -5.5630, -5.1580, -4.5035, -4.0418, -3.2828, -2.7968, -2.0357,
                                                   -1.5543, -1.0489, -0.6339, -0.3181, 0, 0.3312, 0.6246, 0.8861, 1.2026, 1.5963,
                                                   1.9940, 2.2178, 2.4851, 2.6935, 2.9023, 3.0757, 3.2152, 3.4123]
    /// Grey levels of the `LightFlow` samples.
    public static let lightFlowLevels: [Float] = [0, 2, 4, 8, 12, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192,
                                                  208, 224, 232, 240, 248, 252, 255]
    /// Whites or Blacks in one direction as a one-parameter flow: amount t maps a grey x to
    /// χ⁻¹(χ(x) ± (|t|/100)^γ) (+ brightens, − darkens). The ±50 and ±100 curves of each direction
    /// commute (M3: within 0.6–1.8 levels mean), which is what a flow needs; χ and γ are fitted to
    /// both ramps (γ from where ±50 sits between 0 and ±100).
    public struct LightFlow: Sendable {
        public let chi: [Float]
        public let gamma: Float
        public let sign: Float
    }
    /// Whites +: ramps +50 max 7 mean 2.39, +100 max 4 mean 0.56 (+50 and +100 commute least).
    public static let lightWhitesUp = LightFlow(chi: [-26.8827, -22.9479, -19.0065, -15.0458, -11.0488, -8.3837, -5.6771, -4.1023, -3.1483,
                                                       -2.5072, -2.0041, -1.5984, -0.9973, -0.5820, -0.2536, 0, 0.2042, 0.3892, 0.5881,
                                                       0.7842, 0.9582, 1.1239, 1.2251, 1.2750, 1.3908, 1.4651, 1.5389], gamma: 2.3966, sign: 1)
    /// Whites −: −50 max 3 mean 0.87, −100 max 2 mean 0.71 (white stays white).
    public static let lightWhitesDown = LightFlow(chi: [-73.8893, -68.8981, -63.8885, -58.8247, -53.6551, -48.3133, -42.7194, -36.7817,
                                                         -30.3976, -24.1732, -17.9520, -13.6222, -7.9412, -4.2752, -1.7650, 0, 1.3660,
                                                         2.4943, 3.4296, 4.2220, 4.8930, 5.5096, 5.8410, 6.2256, 6.8552, 7.5198, 8.9257],
                                                  gamma: 0.8466, sign: -1)
    /// Blacks +: +50 max 1 mean 0.39, +100 max 1 mean 0.33.
    public static let lightBlacksUp = LightFlow(chi: [-11.6177, -9.6192, -8.5760, -7.4021, -6.7766, -6.2080, -5.3745, -4.7621, -4.2646,
                                                       -3.8196, -3.4125, -3.0217, -2.2634, -1.5200, -0.7803, 0, 0.8489, 1.9007, 3.2481,
                                                       5.1064, 7.9442, 12.8920, 17.2608, 23.6353, 31.6140, 39.5590, 47.4922], gamma: 1.0831, sign: 1)
    /// Blacks −: −50 max 3 mean 0.65, −100 max 2 mean 0.29 (shadows clip to black).
    public static let lightBlacksDown = LightFlow(chi: [-2.6574, -2.5942, -2.5579, -2.4994, -2.4399, -2.3917, -2.2763, -2.1452, -2.0175,
                                                         -1.8794, -1.7320, -1.5673, -1.2453, -0.8716, -0.4505, 0, 0.5214, 1.1685, 1.9996,
                                                         3.1057, 4.7111, 7.3122, 9.3818, 12.5399, 18.7859, 22.8000, 26.8075],
                                                  gamma: 2.3611, sign: -1)

    /// Piecewise-linear `vals` over `levels` (0…255) at x (0…1), clamped to the ends.
    static func knotAt(_ levels: [Float], _ vals: [Float], _ x: Float) -> Float {
        let v = x * 255
        if v <= levels[0] { return vals[0] }
        let n = levels.count
        if v >= levels[n - 1] { return vals[n - 1] }
        var i = 0
        while v > levels[i + 1] { i += 1 }
        let f = (v - levels[i]) / (levels[i + 1] - levels[i])
        return vals[i] + (vals[i + 1] - vals[i]) * f
    }
    /// Inverse of `knotAt` (vals increasing): x (0…1) with knotAt(x) = p, clamped to the ends.
    static func knotInverse(_ levels: [Float], _ vals: [Float], _ p: Float) -> Float {
        let n = vals.count
        if p <= vals[0] { return levels[0] / 255 }
        if p >= vals[n - 1] { return levels[n - 1] / 255 }
        var i = 0
        while p > vals[i + 1] { i += 1 }
        let f = (p - vals[i]) / (vals[i + 1] - vals[i])
        return (levels[i] + (levels[i + 1] - levels[i]) * f) / 255
    }

    /// Light mode's Exposure on a grey (sRGB-encoded `x`): ψ⁻¹(ψ(x) + ev), see `lightPsiPositive`.
    public static func lightExposure(_ x: Float, _ ev0: Float) -> Float {
        let ev = min(max(ev0, -5), 5)
        if ev == 0 || x <= 0 { return max(x, 0) }
        let psi = ev > 0 ? lightPsiPositive : lightPsiNegative, levels = lightPsiLevels
        let k0 = levels[0] / 255
        let p = (x < k0 ? psi[0] + log2(x / k0) : knotAt(levels, psi, min(x, 1))) + ev
        if p >= psi[psi.count - 1] { return 1 }
        if p < psi[0] { return k0 * exp2(p - psi[0]) }
        return knotInverse(levels, psi, p)
    }

    /// Whites (`up` / `down`: `lightWhitesUp` / `lightWhitesDown`) or Blacks (`lightBlacksUp` /
    /// `lightBlacksDown`) on a grey (sRGB-encoded `x`), amount `t` (−100…100).
    public static func lightFlow(_ x: Float, _ t0: Float, up: LightFlow, down: LightFlow) -> Float {
        let t = min(max(t0, -100), 100)
        if t == 0 { return x }
        let f = t > 0 ? up : down
        let tau = f.sign * powf(abs(t) / 100, f.gamma)
        return knotInverse(lightFlowLevels, f.chi, knotAt(lightFlowLevels, f.chi, min(max(x, 0), 1)) + tau)
    }

    /// How a Light stage carries its grey curve onto colours (ProPhoto channels; `lightTone`).
    public enum LightStageMode: Int, Sendable {
        case skip = 0
        /// The DNG SDK's RGB tone on linear ProPhoto: largest and smallest channels through the
        /// curve, the middle one kept between them (Exposure, Whites +, Blacks −).
        case linearTone = 1
        /// The same on sRGB-encoded ProPhoto (Contrast, M1).
        case encodedTone = 2
        /// The grey curve's change at the mean of the sRGB-encoded ProPhoto channels added to all
        /// three — chroma kept (Whites −, Blacks +: M3's colours lose ~half the error of a tone).
        case additive = 3
    }

    /// Light mode's four stages in Photoshop's order — Exposure, Contrast, Whites, Blacks — each a
    /// grey LUT (`lutSize`) and how it reaches colours. Exposure then Contrast composes exactly
    /// on M3's greys (combination 1, held out: max 2 levels). Highlights and Shadows are local
    /// (spatially varying) in Photoshop and stay identity here (PORT-NOTES phase 5, M3).
    public static func lightStages(_ bc: Adjustment.BrightnessContrast) -> [(mode: LightStageMode, lut: [Float])] {
        let n = lutSize
        func table(_ f: (Float) -> Float) -> [Float] { (0..<n).map { k in min(max(f(Float(k) / Float(n - 1)), 0), 1) } }
        let identity = table { $0 }
        let (ev, c, w, b) = (bc.exposure, bc.contrast, bc.whites, bc.blacks)
        return [
            ev == 0 ? (.skip, identity) : (.linearTone, table { lightExposure($0, ev) }),
            c == 0 ? (.skip, identity) : (.encodedTone, table { photoshopContrast($0, c) }),
            w == 0 ? (.skip, identity) : (w > 0 ? .linearTone : .additive, table { lightFlow($0, w, up: lightWhitesUp, down: lightWhitesDown) }),
            b == 0 ? (.skip, identity) : (b > 0 ? .additive : .linearTone, table { lightFlow($0, b, up: lightBlacksUp, down: lightBlacksDown) }),
        ]
    }

    /// Light mode's grey curve (all stages composed), `lutSize` entries — what Lab's L and CMYK ink
    /// planes take.
    public static func lightToneLUT(_ bc: Adjustment.BrightnessContrast) -> [Float] {
        let stages = lightStages(bc)
        return (0..<lutSize).map { k in
            stages.reduce(Float(k) / Float(lutSize - 1)) { v, s in s.mode == .skip ? v : lut(s.lut, v) }
        }
    }

    /// Light mode on a colour: sRGB → linear ProPhoto, each stage (`LightStageMode`), back to sRGB,
    /// clipped. `modes` and `t` (four `lutSize` rows, one after another) are `lightStages`'s.
    public static func lightTone(_ c: SIMD3<Float>, _ modes: SIMD4<Int32>, _ t: UnsafeBufferPointer<Float>) -> SIMD3<Float> {
        let (m, mi) = (proPhotoFromSRGB, srgbFromProPhoto)
        let l0 = SIMD3(ColorConvert.srgbToLinear(min(max(c.x, 0), 1)), ColorConvert.srgbToLinear(min(max(c.y, 0), 1)),
                       ColorConvert.srgbToLinear(min(max(c.z, 0), 1)))
        var l = SIMD3((m[0] * l0).sum(), (m[1] * l0).sum(), (m[2] * l0).sum())
        func enc(_ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(ColorConvert.linearToSRGB(max(v.x, 0)), ColorConvert.linearToSRGB(max(v.y, 0)), ColorConvert.linearToSRGB(max(v.z, 0)))
        }
        func dec(_ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(ColorConvert.srgbToLinear(max(v.x, 0)), ColorConvert.srgbToLinear(max(v.y, 0)), ColorConvert.srgbToLinear(max(v.z, 0)))
        }
        func tone(_ u: SIMD3<Float>, _ f: (Float) -> Float) -> SIMD3<Float> {
            let (mx, mn) = (u.max(), u.min())
            let (tmx, tmn) = (f(mx), f(mn))
            return mx > mn ? SIMD3(repeating: tmn) + (u - SIMD3(repeating: mn)) * ((tmx - tmn) / (mx - mn)) : SIMD3(repeating: tmx)
        }
        for i in 0..<4 {
            let row = UnsafeBufferPointer(rebasing: t[(i * lutSize)..<((i + 1) * lutSize)])
            func curve(_ v: Float) -> Float { lut(row, v) }
            switch modes[i] {
            case 1:
                l = tone(SIMD3(max(l.x, 0), max(l.y, 0), max(l.z, 0))) { ColorConvert.srgbToLinear(curve(ColorConvert.linearToSRGB(max($0, 0)))) }
            case 2:
                l = dec(tone(enc(l), curve))
            case 3:
                let u = enc(l), k = u.sum() / 3
                l = dec(u + SIMD3(repeating: curve(k) - k))
            default: break
            }
        }
        let o = SIMD3((mi[0] * l).sum(), (mi[1] * l).sum(), (mi[2] * l).sum())
        return SIMD3(ColorConvert.linearToSRGB(min(max(o.x, 0), 1)), ColorConvert.linearToSRGB(min(max(o.y, 0), 1)),
                     ColorConvert.linearToSRGB(min(max(o.z, 0), 1)))
    }

    /// Linear sRGB → linear ProPhoto (both D50), rows normalised to keep greys grey.
    public static let proPhotoFromSRGB: [SIMD3<Float>] = {
        let romm: [SIMD3<Double>] = [SIMD3(0.7976749, 0.1351917, 0.0313534), SIMD3(0.2880402, 0.7118741, 0.0000857), SIMD3(0, 0, 0.8252100)]
        let s = ColorConvert.srgbToXYZD50.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
        let inv = invert3(romm)
        return (0..<3).map { r in
            var row = SIMD3<Double>.zero
            for c in 0..<3 { for k in 0..<3 { row[c] += inv[r][k] * s[k][c] } }
            row /= row.sum()
            return SIMD3(Float(row.x), Float(row.y), Float(row.z))
        }
    }()
    /// Linear ProPhoto → linear sRGB (inverse of `proPhotoFromSRGB`).
    public static let srgbFromProPhoto: [SIMD3<Float>] = {
        let m = proPhotoFromSRGB.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
        return invert3(m).map { SIMD3(Float($0.x), Float($0.y), Float($0.z)) }
    }()

    static func invert3(_ m: [SIMD3<Double>]) -> [SIMD3<Double>] {
        let (a, b, c) = (m[0], m[1], m[2])
        let det = a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) + a.z * (b.x * c.y - b.y * c.x)
        return [SIMD3((b.y * c.z - b.z * c.y) / det, (a.z * c.y - a.y * c.z) / det, (a.y * b.z - a.z * b.y) / det),
                SIMD3((b.z * c.x - b.x * c.z) / det, (a.x * c.z - a.z * c.x) / det, (a.z * b.x - a.x * b.z) / det),
                SIMD3((b.x * c.y - b.y * c.x) / det, (a.y * c.x - a.x * c.y) / det, (a.x * b.y - a.y * b.x) / det)]
    }

    /// Light mode's Contrast on a colour (Photoshop 27.11, M1): the grey curve `t` applied
    /// hue-preservingly in ProPhoto — the largest and smallest channels go through the curve and
    /// the middle one keeps its place between them (the DNG SDK's RGB tone), with the channels
    /// sRGB-encoded — then back to sRGB, clipped. Per-channel curves were 8.5–15.8 levels mean off
    /// on the M1 lattice; this is 1.1–1.3 (unclipped colours). Light's pivot is image-adaptive in
    /// Photoshop (PORT-NOTES phase 4); `contrastPivot` is the M1 lattice's.
    public static func proPhotoTone(_ c: SIMD3<Float>, _ t: UnsafeBufferPointer<Float>) -> SIMD3<Float> {
        let (m, mi) = (proPhotoFromSRGB, srgbFromProPhoto)
        let l = SIMD3(ColorConvert.srgbToLinear(min(max(c.x, 0), 1)), ColorConvert.srgbToLinear(min(max(c.y, 0), 1)),
                      ColorConvert.srgbToLinear(min(max(c.z, 0), 1)))
        let pp = SIMD3((m[0] * l).sum(), (m[1] * l).sum(), (m[2] * l).sum())
        let u = SIMD3(ColorConvert.linearToSRGB(max(pp.x, 0)), ColorConvert.linearToSRGB(max(pp.y, 0)), ColorConvert.linearToSRGB(max(pp.z, 0)))
        let (mx, mn) = (u.max(), u.min())
        let (tmx, tmn) = (lut(t, mx), lut(t, mn))
        let o = mx > mn ? SIMD3(repeating: tmn) + (u - SIMD3(repeating: mn)) * ((tmx - tmn) / (mx - mn)) : SIMD3(repeating: tmx)
        let ol = SIMD3(ColorConvert.srgbToLinear(o.x), ColorConvert.srgbToLinear(o.y), ColorConvert.srgbToLinear(o.z))
        let s = SIMD3((mi[0] * ol).sum(), (mi[1] * ol).sum(), (mi[2] * ol).sum())
        return SIMD3(ColorConvert.linearToSRGB(min(max(s.x, 0), 1)), ColorConvert.linearToSRGB(min(max(s.y, 0), 1)),
                     ColorConvert.linearToSRGB(min(max(s.z, 0), 1)))
    }

    /// Photoshop posterize: `n` equal input bins over 0…255, outputs `floor(k·255/(n−1))`.
    public static func posterize(_ v: Float, _ levels: UInt32) -> Float {
        let n = Float(min(max(levels, 2), 255))
        let x = (min(max(v, 0), 1) * 255).rounded()
        let bin = min((x * n / 256).rounded(.down), n - 1)
        return (bin * 255 / (n - 1)).rounded(.down) / 255
    }

    // MARK: Levels / Curves

    /// Levels on samples with `quantum` steps per unit (whole levels, as Photoshop).
    public static func levelsQ(_ ch: LevelsChannel, _ v0: Float, _ quantum: Float?) -> Float {
        let range = max(ch.inWhite - ch.inBlack, 1e-6)
        let u: Float
        if let q = quantum, q.isFinite, q >= 1 {
            let v = (v0 * q).rounded() / q
            u = ((min(max((v - ch.inBlack) / range, 0), 1) * q + 0.5 + 1e-3).rounded(.down)) / q
        } else {
            u = min(max((v0 - ch.inBlack) / range, 0), 1)
        }
        let g = max(ch.gamma, 0.01)
        let t: Float
        if g > 1 {
            let power = powf(u, 1 / g)
            let line = 0.93 * powf(2, g) * u
            if power <= 1e-6 || line <= 1e-6 {
                t = min(power, line)
            } else {
                let p: Float = 10
                t = powf(powf(power, -p) + powf(line, -p), -1 / p)
            }
        } else {
            t = powf(u, 1 / g)
        }
        return ch.outBlack + t * (ch.outWhite - ch.outBlack)
    }

    /// Levels in a 32-bit document: unclipped, plain mirrored power curve.
    public static func levelsFloat(_ ch: LevelsChannel, _ v: Float) -> Float {
        let t0 = (v - ch.inBlack) / max(ch.inWhite - ch.inBlack, 1e-6)
        let t = ch.gamma == 1 ? t0 : copysign(powf(abs(t0), 1 / max(ch.gamma, 0.01)), t0 == 0 ? 0 : t0)
        return ch.outBlack + t * (ch.outWhite - ch.outBlack)
    }

    static func identityLUT() -> [Float] { (0..<lutSize).map { Float($0) / Float(lutSize - 1) } }

    /// A pencil-drawn Curves map: straight segments, constant outside, clamped, as a LUT.
    public static func curveMapLUT(_ points: [CurvePoint]) -> [Float] {
        var pts = points.filter { $0.input.isFinite && $0.output.isFinite }.map { ($0.input, $0.output) }
        pts.sort { $0.0 < $1.0 }
        pts = dedup(pts)
        guard let first = pts.first, let last = pts.last else { return identityLUT() }
        var seg = 0
        return (0..<lutSize).map { k in
            let xv = Float(k) / Float(lutSize - 1)
            if xv <= first.0 { return min(max(first.1, 0), 1) }
            if xv >= last.0 { return min(max(last.1, 0), 1) }
            while seg + 1 < pts.count && pts[seg + 1].0 < xv { seg += 1 }
            guard seg + 1 < pts.count else { return min(max(last.1, 0), 1) }
            let (x0, y0) = pts[seg], (x1, y1) = pts[seg + 1]
            let t = x1 > x0 ? (xv - x0) / (x1 - x0) : 0
            return min(max(y0 + (y1 - y0) * t, 0), 1)
        }
    }

    /// Rust `dedup_by(|a, b| (a.0 - b.0).abs() < 1e-6)`: drops a point within 1e-6 of the kept one before it.
    static func dedup(_ pts: [(Float, Float)]) -> [(Float, Float)] {
        var out: [(Float, Float)] = []
        for p in pts {
            if let l = out.last, abs(p.0 - l.0) < 1e-6 { continue }
            out.append(p)
        }
        return out
    }

    /// Photoshop curve: a natural cubic spline through the points, constant outside, clamped, as a LUT.
    public static func curveLUT(_ points: [CurvePoint]) -> [Float] {
        var pts = points.map { ($0.input, $0.output) }
        pts.sort { a, b in a.0 < b.0 }
        pts = dedup(pts)
        if pts.count < 2 { return identityLUT() }
        let n = pts.count
        var m2 = [Double](repeating: 0, count: n)
        if n > 2 {
            let x = pts.map { Double($0.0) }, y = pts.map { Double($0.1) }
            var c = [Double](repeating: 0, count: n), d = [Double](repeating: 0, count: n)
            for i in 1..<(n - 1) {
                let h0 = x[i] - x[i - 1], h1 = x[i + 1] - x[i]
                let a = h0 / 6, b = (h0 + h1) / 3, cc = h1 / 6
                let r = (y[i + 1] - y[i]) / h1 - (y[i] - y[i - 1]) / h0
                let denom = b - a * c[i - 1]
                c[i] = cc / denom
                d[i] = (r - a * d[i - 1]) / denom
            }
            for i in stride(from: n - 2, through: 1, by: -1) { m2[i] = d[i] - c[i] * m2[i + 1] }
        }
        return (0..<lutSize).map { k in
            let xv = Float(k) / Float(lutSize - 1)
            if xv <= pts[0].0 { return min(max(pts[0].1, 0), 1) }
            if xv >= pts[n - 1].0 { return min(max(pts[n - 1].1, 0), 1) }
            var i = n - 2
            for w in 0..<(n - 1) where xv <= pts[w + 1].0 { i = w; break }
            let (x0, y0) = (Double(pts[i].0), Double(pts[i].1))
            let (x1, y1) = (Double(pts[i + 1].0), Double(pts[i + 1].1))
            let h = x1 - x0, t = Double(xv)
            let a = (x1 - t) / h, b = (t - x0) / h
            let y = a * y0 + b * y1 + ((a * a * a - a) * m2[i] + (b * b * b - b) * m2[i + 1]) * h * h / 6
            return min(max(Float(y), 0), 1)
        }
    }

    /// The LUT of one Curves curve (pencil map or spline).
    public static func curveLUTMode(_ points: [CurvePoint], pencil: Bool) -> [Float] {
        pencil ? curveMapLUT(points) : curveLUT(points)
    }

    /// A layer-style contour: `curveLUT`, bending sharply at corner points.
    public static func contourCurveLUT(_ points: [CurvePoint], corners: [Bool]) -> [Float] {
        var pts: [(CurvePoint, Bool)] = points.enumerated().map { ($0.element, $0.offset < corners.count ? corners[$0.offset] : false) }
        if !pts.contains(where: { $0.1 }) { return curveLUT(points) }
        pts.sort { $0.0.input < $1.0.input }
        var dd: [(CurvePoint, Bool)] = []
        for p in pts {
            if let l = dd.last, abs(p.0.input - l.0.input) < 1e-6 { continue }
            dd.append(p)
        }
        pts = dd
        var out: [Float] = []
        var start = 0
        let last = max(pts.count - 1, 0)
        if last >= 1 {
            for i in 1...last {
                let corner = pts[i].1
                if !(corner || i == last) { continue }
                let seg = pts[start...i]
                let from = seg.first?.0.input ?? 0
                let l = curveLUT(seg.map { $0.0 })
                if out.isEmpty {
                    out = l
                } else {
                    for k in 0..<out.count where Float(k) / Float(lutSize - 1) >= from { out[k] = l[k] }
                }
                start = i
            }
        }
        return out.isEmpty ? curveLUT(points) : out
    }

    /// Per-channel LUTs of Levels / Curves (channel record, then master), four rows (3 + black).
    public static func toneLUTsQ(_ adj: Adjustment, _ quantum: Float?) -> [[Float]] {
        func x(_ k: Int) -> Float { Float(k) / Float(lutSize - 1) }
        switch adj {
        case .levels(let lv):
            let (master, perChannel, space, black) = (lv.master, lv.perChannel, lv.space, lv.black)
            let m = space == .lab ? LevelsChannel() : master
            func row(_ c: LevelsChannel) -> [Float] { (0..<lutSize).map { levelsQ(m, levelsQ(c, x($0), quantum), quantum) } }
            let pc = perChannel.count >= 3 ? perChannel : [LevelsChannel(), LevelsChannel(), LevelsChannel()]
            return [row(pc[0]), row(pc[1]), row(pc[2]), row(space == .cmyk ? black : LevelsChannel())]
        case .curves(let cv):
            let (master, perChannel, space, black, pencil) = (cv.master, cv.perChannel, cv.space, cv.black, cv.pencil)
            let m = space == .lab ? curveLUT([]) : curveLUTMode(master, pencil: pencil)
            func row(_ c: [CurvePoint]) -> [Float] { curveLUTMode(c, pencil: pencil).map { lut(m, $0) } }
            let pc = perChannel.count >= 3 ? perChannel : [[], [], []]
            return [row(pc[0]), row(pc[1]), row(pc[2]), row(space == .cmyk ? black : [])]
        default:
            return (0..<4).map { _ in identityLUT() }
        }
    }

    /// `toneLUTsQ` in a document of `depth` (32-bit RGB Levels sampled from `levelsFloat`).
    public static func toneLUTsDepth(_ adj: Adjustment, _ depth: SampleType?) -> [[Float]] {
        if case .levels(let lv) = adj, lv.space == .rgb, depth == .f32 {
            let (master, perChannel) = (lv.master, lv.perChannel)
            let pc = perChannel.count >= 3 ? perChannel : [LevelsChannel(), LevelsChannel(), LevelsChannel()]
            func row(_ c: LevelsChannel) -> [Float] {
                (0..<lutSize).map { min(max(levelsFloat(master, levelsFloat(c, Float($0) / Float(lutSize - 1))), 0), 1) }
            }
            return [row(pc[0]), row(pc[1]), row(pc[2]), identityLUT()]
        }
        return toneLUTsQ(adj, depth.flatMap(adjustmentQuantum))
    }

    /// Float RGB curve channels with no edit keep samples outside the LUT domain.
    public static func floatToneIdentity(_ adj: Adjustment, _ depth: SampleType?) -> [Bool] {
        if case .curves(let cv) = adj, cv.space == .rgb, depth == .f32 {
            let (master, perChannel) = (cv.master, cv.perChannel)
            return (0..<3).map { isIdentityCurve(master) && isIdentityCurve(perChannel.count > $0 ? perChannel[$0] : []) }
        }
        return [false, false, false]
    }

    /// Channel LUTs applied in CMYK (ink brightness) or Lab space, as a difference of two round trips.
    public static func toneInSpace(_ space: ToneSpace, _ luts: [[Float]], _ c: SIMD3<Float>) -> SIMD3<Float> {
        let before: SIMD3<Float>, after: SIMD3<Float>
        switch space {
        case .cmyk:
            let ink = ColorConvert.rgbToCMYK(c)
            let out = SIMD4<Float>(1 - lut(luts[0], 1 - ink.x), 1 - lut(luts[1], 1 - ink.y), 1 - lut(luts[2], 1 - ink.z), 1 - lut(luts[3], 1 - ink.w))
            if out == ink { return c }
            before = ColorConvert.cmykToRGB(ink); after = ColorConvert.cmykToRGB(out)
        case .lab:
            let l = ColorConvert.srgbToLab(c)
            let n = SIMD3(l.x / 100, (l.y + 128) / 255, (l.z + 128) / 255)
            let o = SIMD3(lut(luts[0], n.x), lut(luts[1], n.y), lut(luts[2], n.z))
            if o == n { return c }
            func back(_ v: SIMD3<Float>) -> SIMD3<Float> { ColorConvert.labToSRGB(SIMD3(v.x * 100, v.y * 255 - 128, v.z * 255 - 128)) }
            before = back(n); after = back(o)
        case .rgb:
            return SIMD3(lut(luts[0], c.x), lut(luts[1], c.y), lut(luts[2], c.z))
        }
        return simd_clamp(c + after - before, .zero, SIMD3(repeating: 1))
    }

    // MARK: Hue / Saturation

    /// Range edits as three hue-indexed tables (shift°, saturation, lightness fractions).
    public static func hueRangeTables(_ ranges: [HueRange]) -> [[Float]] {
        var rows = [[Float]](repeating: [Float](repeating: 0, count: lutSize), count: 3)
        let active = ranges.filter { !$0.isNeutral }
        for k in 0..<lutSize {
            let deg = Float(k) / Float(lutSize - 1) * 360
            var acc = SIMD3<Float>.zero
            for r in active {
                let w = r.weight(deg)
                acc += SIMD3(w * r.hue, w * r.saturation / 100, w * r.lightness / 100)
            }
            rows[0][k] = acc.x; rows[1][k] = acc.y; rows[2][k] = acc.z
        }
        return rows
    }

    public static func rgbToHSL(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z)
        let l = (mx + mn) / 2
        if abs(mx - mn) < 1e-7 { return SIMD3(0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        let h: Float
        if mx == c.x { h = remEuclid((c.y - c.z) / d, 6) } else if mx == c.y { h = (c.z - c.x) / d + 2 } else { h = (c.x - c.y) / d + 4 }
        return SIMD3(h / 6, s, l)
    }

    public static func hslToRGB(_ h: Float, _ s: Float, _ l: Float) -> SIMD3<Float> {
        if s <= 0 { return SIMD3(repeating: l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func f(_ t0: Float) -> Float {
            let t = remEuclid(t0, 1)
            if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
            return p
        }
        return SIMD3(f(h + 1.0 / 3.0), f(h), f(h - 1.0 / 3.0))
    }

    /// One Hue/Saturation evaluation: hue shift in degrees, saturation and lightness in −1…1.
    public static func hueSaturation(_ c: SIMD3<Float>, _ hue: Float, _ s: Float, _ l: Float, _ colorize: Bool) -> SIMD3<Float> {
        func lighten(_ v: Float) -> Float { l > 0 ? v + (1 - v) * l : v * (1 + l) }
        if colorize {
            let ll = rgbToHSL(c).z
            return hslToRGB(remEuclid(hue, 360) / 360, min(abs(s), 1), lighten(ll))
        }
        let lc = SIMD3(lighten(c.x), lighten(c.y), lighten(c.z))
        let hsl = rgbToHSL(lc)
        let hh = remEuclid(hsl.x + hue / 360, 1)
        let ss = min(max(s > 0 ? hsl.y / max(1 - s, 1.0 / 512.0) : hsl.y * (1 + s), 0), 1)
        return hslToRGB(hh, ss, hsl.z)
    }

    /// A colour range's Lightness: towards the brightest channel when raised, the darkest when lowered.
    public static func rangeLightness(_ c: SIMD3<Float>, _ l0: Float) -> SIMD3<Float> {
        let l = min(max(l0, -1), 1)
        let target = l > 0 ? max(c.x, c.y, c.z) : min(c.x, c.y, c.z)
        return c + (SIMD3(repeating: target) - c) * abs(l)
    }

    // MARK: Black & White, dither, 3D LUT

    public static func blackWhiteGray(_ c: SIMD3<Float>, _ weights: [Float]) -> Float {
        let (r, g, b) = (c.x, c.y, c.z)
        let mx = max(r, g, b), mn = min(r, g, b)
        let mid = r + g + b - mx - mn
        let primary = (r >= g && r >= b) ? 0 : (g >= b ? 2 : 4)
        let secondary = (b <= r && b <= g) ? 1 : (r <= g ? 3 : 5)
        let w = weights.count >= 6 ? weights : [40, 60, 40, 60, 20, 80]
        return min(max(mn + (mid - mn) * w[secondary] / 100 + (mx - mid) * w[primary] / 100, 0), 1)
    }

    /// Ordered-dither offset in −0.5…0.5 (4×4 Bayer) for document pixel (x, y).
    @inline(__always) public static func bayer4(_ x: Int32, _ y: Int32) -> Float {
        let m: [Float] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        return (m[Int((y & 3) * 4 + (x & 3))] + 0.5) / 16 - 0.5
    }

    /// Samples a 3D LUT (`n`³ RGB triplets, red fastest) at `c`, trilinear or tetrahedral.
    public static func lut3DSample(_ lut: UnsafeBufferPointer<Float>, _ n: Int, _ c: SIMD3<Float>, tetrahedral: Bool) -> SIMD3<Float> {
        let m = Float(n - 1)
        let pos = simd_clamp(c, .zero, SIMD3(repeating: 1)) * m
        let i0 = SIMD3<Int>(min(Int(pos.x.rounded(.down)), n - 2), min(Int(pos.y.rounded(.down)), n - 2), min(Int(pos.z.rounded(.down)), n - 2))
        let f = pos - SIMD3(Float(i0.x), Float(i0.y), Float(i0.z))
        func at(_ dr: Int, _ dg: Int, _ db: Int) -> SIMD3<Float> {
            let idx = (((i0.z + db) * n + i0.y + dg) * n + i0.x + dr) * 3
            return SIMD3(lut[idx], lut[idx + 1], lut[idx + 2])
        }
        let (fr, fg, fb) = (f.x, f.y, f.z)
        if tetrahedral {
            let c000 = at(0, 0, 0), c111 = at(1, 1, 1)
            if fr > fg {
                if fg > fb { return (1 - fr) * c000 + (fr - fg) * at(1, 0, 0) + (fg - fb) * at(1, 1, 0) + fb * c111 }
                if fr > fb { return (1 - fr) * c000 + (fr - fb) * at(1, 0, 0) + (fb - fg) * at(1, 0, 1) + fg * c111 }
                return (1 - fb) * c000 + (fb - fr) * at(0, 0, 1) + (fr - fg) * at(1, 0, 1) + fg * c111
            }
            if fb > fg { return (1 - fb) * c000 + (fb - fg) * at(0, 0, 1) + (fg - fr) * at(0, 1, 1) + fr * c111 }
            if fb > fr { return (1 - fg) * c000 + (fg - fb) * at(0, 1, 0) + (fb - fr) * at(0, 1, 1) + fr * c111 }
            return (1 - fg) * c000 + (fg - fr) * at(0, 1, 0) + (fr - fb) * at(1, 1, 0) + fb * c111
        }
        func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
        let c00 = lerp(at(0, 0, 0), at(1, 0, 0), fr)
        let c10 = lerp(at(0, 1, 0), at(1, 1, 0), fr)
        let c01 = lerp(at(0, 0, 1), at(1, 0, 1), fr)
        let c11 = lerp(at(0, 1, 1), at(1, 1, 1), fr)
        return lerp(lerp(c00, c10, fg), lerp(c01, c11, fg), fb)
    }

    // MARK: Color Balance, Selective Color

    /// Color Balance on channel `ch` of `v`; `tones` = shadows, midtones, highlights slider triples.
    public static func colorBalanceChannel(_ tones: [SIMD3<Float>], _ preserve: Bool, _ ch: Int, _ v0: Float) -> Float {
        let shadows = tones[0], midtones = tones[1], highlights = tones[2]
        func black(_ v: Float, _ b: Float) -> Float { max((v - b) / (1 - b), 0) }
        func white(_ v: Float, _ w: Float) -> Float { min(v / w, 1) }
        var v = min(max(v0, 0), 1)
        for (tone, sliders) in [(2, highlights), (0, shadows), (1, midtones)] {
            let a = simd_clamp(sliders / 100, SIMD3(repeating: -1), SIMD3(repeating: 1))
            if preserve && tone != 1 {
                let own = a[ch]
                let lo = min(a.x, a.y, a.z), hi = max(a.x, a.y, a.z)
                v = tone == 0 ? black(v, balanceLevels * (hi - own)) : white(v, 1 - balanceLevels * (own - lo))
                continue
            }
            for src in 0..<3 {
                let a = min(max(sliders[src] / 100, -1), 1)
                let own = src == ch
                if a == 0 || (!preserve && !own) { continue }
                switch (tone, preserve) {
                case (1, false): v = powf(v, powf(2, -a))
                case (1, true): v = powf(v, powf(2, (own ? -a : a) / 2))
                case (0, false): v = a < 0 ? powf(black(v, balanceLevels * -a), powf(2, -a / 2)) : powf(v, powf(2, -a / 2))
                case (2, false): v = a > 0 ? powf(white(v, 1 - balanceLevels * a), powf(2, -a / 2)) : powf(v, powf(2, -a / 2))
                default: break
                }
            }
        }
        return v
    }

    public static func selectiveColorWeights(_ c: SIMD3<Float>) -> [Float] {
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z)
        let mid = c.x + c.y + c.z - mx - mn
        func top(_ i: Int) -> Float { c[i] >= mx ? mx - mid : 0 }
        func bottom(_ i: Int) -> Float { c[i] <= mn ? mid - mn : 0 }
        return [top(0), bottom(2), top(1), bottom(0), top(2), bottom(1),
                max((mn - 0.5) * 2, 0), min(max(1 - abs(mx - 0.5) - abs(mn - 0.5), 0), 1), max((0.5 - mx) * 2, 0)]
    }

    /// Each colour range moves the pixel towards its own fully adjusted value, clamped to 0…1,
    /// by the range's weight; in Absolute mode a channel's ink and Black combine as
    /// (1 + ink)(1 + black) − 1. Fitted to ps-corpus adj-selectiveColor (mean 0.18 levels, no
    /// pixel off): photocraft adds the ranges' unclamped changes, scaled by min(2·value, 1), and
    /// sums ink and Black (mean 1.24 levels, 63 % of pixels off).
    public static func selectiveColor(_ c: SIMD3<Float>, _ relative: Bool, _ adj: [SIMD4<Float>]) -> SIMD3<Float> {
        let w = selectiveColorWeights(c)
        var out = c
        for (r, wr) in w.enumerated() where wr > 0 && r < adj.count {
            let a = adj[r] / 100
            if a == .zero { continue }
            for i in 0..<3 {
                let d = relative ? (a[i] + a.w) * (1 - c[i]) : (1 + a[i]) * (1 + a.w) - 1
                out[i] += wr * (min(max(c[i] - d, 0), 1) - c[i])
            }
        }
        return simd_clamp(out, .zero, SIMD3(repeating: 1))
    }

    // MARK: Photo Filter, Vibrance

    /// Photo Filter's linear-light RGB matrix (rows).
    public static func photoFilterMatrix(_ color: SIMD3<Float>, _ density: Float, normalizeY: Bool) -> [SIMD3<Float>] {
        let d = density.isFinite ? min(max(density, 0), 1) : 0
        let lin = SIMD3(ColorConvert.srgbToLinear(min(max(color.x, 0), 1)), ColorConvert.srgbToLinear(min(max(color.y, 0), 1)),
                        ColorConvert.srgbToLinear(min(max(color.z, 0), 1)))
        let m = ColorConvert.srgbToXYZD50, inv = ColorConvert.xyzD50ToSRGB
        let xyz = SIMD3((m[0] * lin).sum(), (m[1] * lin).sum(), (m[2] * lin).sum())
        var s = SIMD3<Float>(repeating: 1 - d) + d * xyz / ColorConvert.d50
        if normalizeY && s.y > 1e-6 { s /= s.y }
        var rows: [SIMD3<Float>] = []
        for r in 0..<3 {
            var row = SIMD3<Float>.zero
            for c in 0..<3 {
                var acc: Float = 0
                for k in 0..<3 {
                    let term: Float = inv[r][k] * s[k] * m[k][c]
                    acc += term
                }
                row[c] = acc
            }
            rows.append(row)
        }
        return rows
    }

    public static func vibrancePixel(_ c: SIMD3<Float>, _ v: Float, _ s: Float, _ transfer: Transfer, _ hi: Float) -> SIMD3<Float> {
        var l = SIMD3(transfer.decode(c.x), transfer.decode(c.y), transfer.decode(c.z))
        if v != 0 { l = vibranceLinear(l, v) }
        if s != 0 {
            let g = vibranceGrey.x * l.x + vibranceGrey.y * l.y
            for i in 0..<3 { l[i] = min(max(g + (1 + s) * (l[i] - g), 0), hi) }
        }
        return SIMD3(transfer.encode(min(max(l.x, 0), hi)), transfer.encode(min(max(l.y, 0), hi)), transfer.encode(min(max(l.z, 0), hi)))
    }

    /// Vibrance on linear RGB: a per-pixel scale about a grey, from the HSV saturation t and value
    /// mx (photocraft's form). Positive amounts refitted to Photoshop 27.11 (M1: boost, lift,
    /// saturation-dependent skin protection, dark roll-off); negative ones are photocraft's (M1:
    /// 0.06–0.14 levels mean). Hue is kept (linear HSV), as Photoshop's is.
    public static func vibranceLinear(_ c: SIMD3<Float>, _ v: Float) -> SIMD3<Float> {
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z)
        if mx <= 0 || mx - mn <= 1e-9 { return c }
        let t = 1 - mn / mx
        let shape = t * (1 - t) * (2 - t + t * t) * mx * max(1 - mx, 0)
        let t2: Float, v2: Float
        if v < 0 {
            let a = -v
            t2 = t * (1 - a / 4) * (1 - a + a * t * (1 + t) / 2)
            v2 = mx - a * shape
        } else {
            let (b, sk) = (vibranceBoost, vibranceSkinFit)
            let w = vibranceSkin(hsvHue(c, mx, mn))
            let protection = w * min(1, max(sk[3] + sk[4] * (1 - v), 0) * powf(1 - t, sk[5]))
            let a = v * (1 - protection)
            let boost = (b[0] * a + b[1] * a * a) * powf(t, b[2]) * powf(1 - t, b[3]) * expf((b[4] + b[5] * a + b[6] * (1 - t)) * max(1 - mx, 0))
                * (mx / (mx + vibranceDark))
            t2 = min(t * (1 + boost), 1)
            v2 = mx + v * vibranceLift * shape
        }
        let m2 = v2 * (1 - t2)
        let k = (v2 - m2) / (mx - mn)
        return SIMD3(repeating: m2) + (c - SIMD3(repeating: mn)) * k
    }

    /// Skin weight of a hue (degrees): 1 up to h1, ramping to 0 at h2, 0 until h3, back to 1 at 360.
    static func vibranceSkin(_ h: Float) -> Float {
        let s = vibranceSkinFit
        if h <= s[0] { return 1 }
        if h < s[1] { return (s[1] - h) / (s[1] - s[0]) }
        if h < s[2] { return 0 }
        return (h - s[2]) / (360 - s[2])
    }

    static func hsvHue(_ c: SIMD3<Float>, _ mx: Float, _ mn: Float) -> Float {
        let d = mx - mn
        let h: Float
        if mx == c.x { h = remEuclid((c.y - c.z) / d, 6) } else if mx == c.y { h = (c.z - c.x) / d + 2 } else { h = (c.x - c.y) / d + 4 }
        return h * 60
    }

    /// Gradient Map's input: Photoshop's luminosity 0.30 R + 0.59 G + 0.11 B (PCIO, ps-corpus
    /// adj-gradientMap: mean 0.58 → 0.09 levels against Rec. 601's 0.299 / 0.587 / 0.114).
    @inline(__always) public static func gradientMapInput(_ c: SIMD3<Float>) -> Float { 0.3 * c.x + 0.59 * c.y + 0.11 * c.z }

    /// Grey document modes (their composites are held as R = G = B).
    @inline(__always) static func grayMode(_ m: ColorMode) -> Bool { m == .grayscale || m == .duotone || m == .bitmap }

    /// Gradient Map stops at `t` (no stops: grey `t`).
    public static func gradient(_ stops: [GradientMapStop], _ t: Float) -> SIMD3<Float> {
        if stops.isEmpty { return SIMD3(repeating: t) }
        if stops.count == 1 { return stops[0].rgb }
        if t <= stops[0].location { return stops[0].rgb }
        for i in 0..<(stops.count - 1) {
            let a = stops[i], b = stops[i + 1]
            if t <= b.location {
                let k = b.location > a.location ? (t - a.location) / (b.location - a.location) : 0
                return a.rgb + (b.rgb - a.rgb) * k
            }
        }
        return stops[stops.count - 1].rgb
    }

    // MARK: Lab channels

    /// Encoded sRGB → Lab normalised like Photoshop's channels: L/100, (a+128)/255, (b+128)/255.
    @inline(__always) static func labNorm(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let l = ColorConvert.srgbToLab(c)
        return SIMD3(l.x / 100, (l.y + 128) / 255, (l.z + 128) / 255)
    }

    @inline(__always) static func labDenorm(_ n: SIMD3<Float>) -> SIMD3<Float> {
        ColorConvert.labToSRGB(SIMD3(n.x * 100, n.y * 255 - 128, n.z * 255 - 128))
    }

    /// Whether a Lab document evaluates `adj` on L, a and b.
    public static func labChannelAdjustment(_ adj: Adjustment) -> Bool {
        switch adj {
        case .invert, .posterize, .threshold, .brightnessContrast, .gradientMap: true
        default: false
        }
    }
}

extension Adjustment {
    /// The tone space of Levels / Curves (RGB for every other adjustment).
    var toneSpace: ToneSpace {
        switch self {
        case .levels(let l): l.space
        case .curves(let c): c.space
        default: .rgb
        }
    }
}

/// An adjustment with its tables built once (shared by every tile and the GPU upload).
public struct PreparedAdjustment: @unchecked Sendable {
    public let adjustment: Adjustment
    public let transfer: Transfer
    public let depth: SampleType?
    public let mode: ColorMode
    /// Tone LUTs (Levels / Curves: 4 rows), hue-range tables (3 rows).
    let luts: [[Float]]
    let identity: [Bool]
    let photoMatrix: [SIMD3<Float>]
    /// Light Brightness/Contrast: each stage's `AdjustMath.LightStageMode` (rows 1…4 of `luts`).
    let lightModes: SIMD4<Int32>
    /// Lab document evaluating on L, a, b (`apply_lab`).
    let lab: Bool
    /// The buffer's space: `.lab` buffers hold Lab channels (see `applyNativeLab`).
    public let native: NativeSpace

    public init(_ adj: Adjustment, transfer: Transfer, depth: SampleType?, mode: ColorMode, native: NativeSpace = .none) {
        adjustment = adj; self.transfer = transfer; self.depth = depth; self.mode = mode; self.native = native
        lab = mode == .lab && AdjustMath.labChannelAdjustment(adj)
        var luts: [[Float]] = []
        var identity = [false, false, false]
        var pm: [SIMD3<Float>] = []
        var lightModes = SIMD4<Int32>.zero
        switch adj {
        case .levels(let lv) where lv.space == .rgb && depth == .f32 && !lab:
            break
        case .levels, .curves:
            luts = AdjustMath.toneLUTsDepth(adj, depth)
            identity = AdjustMath.floatToneIdentity(adj, depth)
        case .brightnessContrast(let bc) where bc.mode == .modern:
            luts = [AdjustMath.modernToneLUT(bc.brightness, bc.contrast)]
        case .brightnessContrast(let bc) where bc.mode == .light:
            // [grey curve (Lab L, CMYK planes), then the four stage rows]; `identity` marks skipped stages.
            let stages = AdjustMath.lightStages(bc)
            luts = [AdjustMath.lightToneLUT(bc)] + stages.map(\.lut)
            lightModes = SIMD4(stages.map { Int32($0.mode.rawValue) })
        case .hueSaturation(let hs):
            let (colorize, ranges) = (hs.colorize, hs.ranges)
            if !colorize && ranges.contains(where: { !$0.isNeutral }) { luts = AdjustMath.hueRangeTables(ranges) }
        case .photoFilter(let pf):
            let (color, density, preserve) = (pf.color, pf.density, pf.preserveLuminosity)
            let linearDoc = depth == .f32
            pm = AdjustMath.photoFilterMatrix(color, density, normalizeY: preserve && linearDoc)
        default: break
        }
        self.luts = luts; self.identity = identity; self.photoMatrix = pm; self.lightModes = lightModes
    }

    /// Whether a native Lab buffer is adjusted on its channels directly (Lab-channel adjustments
    /// and Lab-space Levels / Curves); every other adjustment converts through display RGB.
    var labDirect: Bool { lab || adjustment.toneSpace == .lab }

    /// Applies the adjustment to `buf` (transparent pixels untouched).
    public func apply(to buf: inout RGBABuffer) {
        if native == .lab {
            if labDirect { applyNativeLab(&buf); return }
            map(&buf) { AdjustMath.labDenorm($0) }
            applyDisplay(&buf)
            map(&buf) { AdjustMath.labNorm($0) }
            return
        }
        applyDisplay(&buf)
    }

    /// `applyLab` on a native Lab buffer (no conversions): the GPU's `pcr_adjust_lab_native`.
    func applyNativeLab(_ buf: inout RGBABuffer) {
        let mid: Float = 128.0 / 255.0
        switch adjustment {
        case .invert:
            map(&buf) { SIMD3<Float>(repeating: 1) - simd_clamp($0, .zero, SIMD3(repeating: 1)) }
        case .posterize(let levels):
            map(&buf) { n in SIMD3(AdjustMath.posterize(n.x, levels), AdjustMath.posterize(n.y, levels), AdjustMath.posterize(n.z, levels)) }
        case .threshold(let level):
            let t = (level * 255).rounded()
            map(&buf) { n in SIMD3((min(max(n.x, 0), 1) * 255).rounded() >= t ? 1 : 0, mid, mid) }
        case .brightnessContrast(let bc):
            let (b, c, legacy) = (bc.brightness, bc.contrast, bc.legacy)
            let p = AdjustMath.legacyBrightnessContrast(b, c)
            let t = luts.first ?? []
            map(&buf) { n in SIMD3(legacy ? AdjustMath.legacyCurve(n.x, p) : AdjustMath.lut(t, n.x), n.y, n.z) }
        case .gradientMap(let gm):
            let (stops, reverse, dither) = (gm.stops, gm.reverse, gm.dither)
            mapXY(&buf) { n, x, y in
                let l = min(max(n.x, 0), 1)
                var o = AdjustMath.gradient(stops, reverse ? 1 - l : l)
                if dither { o = simd_clamp(o + AdjustMath.bayer4(x, y) / 255, .zero, SIMD3(repeating: 1)) }
                return AdjustMath.labNorm(o)
            }
        case .levels, .curves:
            let luts = self.luts
            map(&buf) { n in SIMD3(AdjustMath.lut(luts[0], n.x), AdjustMath.lut(luts[1], n.y), AdjustMath.lut(luts[2], n.z)) }
        default: break
        }
    }

    /// The adjustment on display-RGB colours.
    func applyDisplay(_ buf: inout RGBABuffer) {
        if lab { applyLab(&buf); return }
        let rect = buf.rect
        let adj = adjustment
        switch adj {
        case .invert:
            map(&buf) { SIMD3<Float>(repeating: 1) - $0 }
        case .threshold(let level):
            let t = (level * 255).rounded()
            map(&buf) { c in SIMD3(repeating: (ColorConvert.rgbToGray(c) * 255).rounded() >= t ? 1 : 0) }
        case .posterize(let levels):
            map(&buf) { SIMD3(AdjustMath.posterize($0.x, levels), AdjustMath.posterize($0.y, levels), AdjustMath.posterize($0.z, levels)) }
        case .brightnessContrast(let bc) where bc.legacy:
            let (b, c) = (bc.brightness, bc.contrast)
            let p = AdjustMath.legacyBrightnessContrast(b, c)
            map(&buf) { SIMD3(AdjustMath.legacyCurve($0.x, p), AdjustMath.legacyCurve($0.y, p), AdjustMath.legacyCurve($0.z, p)) }
        case .brightnessContrast(let bc):
            let t = luts[0]
            // Modern: one curve per channel (M2). Light: Contrast through ProPhoto (M1); CMYK ink
            // planes (no Light mode in Photoshop) take its curve per plane.
            if bc.mode == .modern || native == .cmykInk || native == .cmykBlack {
                if bc.mode == .modern && bc.brightness == 0 && bc.contrast == 0 { return }
                map(&buf) { SIMD3(AdjustMath.lut(t, $0.x), AdjustMath.lut(t, $0.y), AdjustMath.lut(t, $0.z)) }
            } else if lightModes != .zero {
                let rows = Array(luts[1...4].joined()), modes = lightModes
                rows.withUnsafeBufferPointer { tp in
                    let tb = UnsafeSendable(tp)
                    map(&buf) { AdjustMath.lightTone($0, modes, tb.value) }
                }
            }
        case .exposure(let ex):
            let (exposure, offset, gamma) = (ex.exposure, ex.offset, ex.gamma)
            let m = powf(2, exposure), g = max(gamma, 0.01)
            let tr = transfer.forExposure
            let hdr = depth == .f32
            func f(_ v: Float) -> Float {
                if hdr {
                    let lin = v * m + offset
                    return g == 1 ? lin : copysign(powf(abs(lin), 1 / g), lin == 0 ? 0 : lin)
                }
                var lin = max(tr.decode(v) * m + offset, 0)
                if g != 1 { lin = powf(lin, 1 / g) }
                return min(max(tr.encode(lin), 0), 1)
            }
            map(&buf) { SIMD3(f($0.x), f($0.y), f($0.z)) }
        case .levels(let lv) where lv.space == .rgb && depth == .f32:
            let (master, perChannel) = (lv.master, lv.perChannel)
            let pc = perChannel.count >= 3 ? perChannel : [LevelsChannel(), LevelsChannel(), LevelsChannel()]
            let masterIdentity = master.isIdentity
            let chIdentity = pc.map(\.isIdentity)
            if !masterIdentity || chIdentity.contains(false) {
                map(&buf) { c in
                    var o = c
                    for i in 0..<3 {
                        let v = chIdentity[i] ? c[i] : AdjustMath.levelsFloat(pc[i], c[i])
                        o[i] = masterIdentity ? v : AdjustMath.levelsFloat(master, v)
                    }
                    return o
                }
            }
        case .levels, .curves:
            let space = adj.toneSpace
            let luts = self.luts, identity = self.identity
            switch space {
            case .rgb:
                map(&buf) { c in
                    SIMD3(identity[0] ? c.x : AdjustMath.lut(luts[0], c.x), identity[1] ? c.y : AdjustMath.lut(luts[1], c.y),
                          identity[2] ? c.z : AdjustMath.lut(luts[2], c.z))
                }
            case .cmyk, .lab:
                map(&buf) { AdjustMath.toneInSpace(space, luts, $0) }
            }
        case .hueSaturation(let hs):
            let (hue, saturation, lightness, colorize) = (hs.hue, hs.saturation, hs.lightness, hs.colorize)
            let tables = luts
            map(&buf) { c in
                var (dh, ds, dl): (Float, Float, Float) = (0, 0, 0)
                if !tables.isEmpty {
                    let h0 = AdjustMath.rgbToHSL(c).x
                    let chroma = min((max(c.x, c.y, c.z) - min(c.x, c.y, c.z)) * 4, 1)
                    dh = AdjustMath.lut(tables[0], h0) * chroma
                    ds = AdjustMath.lut(tables[1], h0) * chroma
                    dl = AdjustMath.lut(tables[2], h0) * chroma
                }
                let out = AdjustMath.hueSaturation(c, hue + dh, min(max(saturation / 100 + ds, -1), 1), min(max(lightness / 100, -1), 1), colorize)
                return AdjustMath.rangeLightness(out, dl)
            }
        case .vibrance(let vb):
            let (vibrance, saturation) = (vb.vibrance, vb.saturation)
            let (v, s) = (vibrance / 100, saturation / 100)
            let hi: Float = depth == .f32 ? .infinity : 1
            let tr = transfer
            map(&buf) { AdjustMath.vibrancePixel($0, v, s, tr, hi) }
        case .channelMixer(let cm):
            let (matrix, monochrome) = (cm.matrix, cm.monochrome)
            let mtx = matrix.count >= 3 ? matrix : [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0)]
            func mix(_ row: SIMD4<Float>, _ c: SIMD3<Float>) -> Float { min(max(row.x * c.x + row.y * c.y + row.z * c.z + row.w, 0), 1) }
            map(&buf) { c in monochrome ? SIMD3(repeating: mix(mtx[0], c)) : SIMD3(mix(mtx[0], c), mix(mtx[1], c), mix(mtx[2], c)) }
        case .photoFilter(let pf):
            let preserve = pf.preserveLuminosity
            let linearDoc = depth == .f32
            let setLum = preserve && !linearDoc
            let m = photoMatrix, tr = transfer
            map(&buf) { c in
                let l = SIMD3(tr.decode(c.x), tr.decode(c.y), tr.decode(c.z))
                var f = SIMD3(tr.encode((m[0] * l).sum()), tr.encode((m[1] * l).sum()), tr.encode((m[2] * l).sum()))
                if setLum { f = Blend.setLum(f, Blend.lum(c)) }
                return simd_clamp(f, .zero, SIMD3(repeating: 1))
            }
        case .blackWhite(let bw):
            let (weights, tint) = (bw.weights, bw.tint)
            map(&buf) { c in
                let g = AdjustMath.blackWhiteGray(c, weights)
                if let t = tint { return simd_clamp(Blend.setLum(t, g), .zero, SIMD3(repeating: 1)) }
                return SIMD3(repeating: g)
            }
        case .gradientMap(let gm):
            let (stops, reverse, dither) = (gm.stops, gm.reverse, gm.dither)
            mapXY(&buf) { c, x, y in
                var t = AdjustMath.gradientMapInput(c)
                if reverse { t = 1 - t }
                var o = AdjustMath.gradient(stops, t)
                if dither { o = simd_clamp(o + AdjustMath.bayer4(x, y) / 255, .zero, SIMD3(repeating: 1)) }
                return o
            }
        case .colorBalance(let cbal):
            let (s, m, h, preserve) = (cbal.shadows, cbal.midtones, cbal.highlights, cbal.preserveLuminosity)
            let tones = [s, m, h]
            map(&buf) { c in
                SIMD3(AdjustMath.colorBalanceChannel(tones, preserve, 0, c.x), AdjustMath.colorBalanceChannel(tones, preserve, 1, c.y),
                      AdjustMath.colorBalanceChannel(tones, preserve, 2, c.z))
            }
        case .selectiveColor(let sc):
            let (relative, adjustments) = (sc.relative, sc.adjustments)
            if AdjustMath.grayMode(mode) {
                // A Grayscale document stores (and Photoshop shows) the result's grey (PCIO request).
                map(&buf) { SIMD3(repeating: ColorConvert.rgbToGray(AdjustMath.selectiveColor($0, relative, adjustments))) }
            } else {
                map(&buf) { AdjustMath.selectiveColor($0, relative, adjustments) }
            }
        case .colorLookup(let cl) where cl.lut != nil:
            let (table, size, tetrahedral, dither) = (cl.lut!, cl.size, cl.tetrahedral, cl.dither)
            guard let len = lut3DLength(size), table.count >= len else { return }
            let n = Int(size)
            table.withUnsafeBufferPointer { t in
                let tb = UnsafeSendable(t)
                mapXY(&buf) { c, x, y in
                    var o = AdjustMath.lut3DSample(tb.value, n, c, tetrahedral: tetrahedral)
                    if dither { o = simd_clamp(o + AdjustMath.bayer4(x, y) / 255, .zero, SIMD3(repeating: 1)) }
                    return o
                }
            }
        case .colorLookup, .unsupported:
            break
        case .filter:
            // Planned as `.filter` / `.backdropFilter` ops (Filters.swift), never `.adjust`.
            break
        }
        _ = rect
    }

    /// `apply_lab`: the Lab-channel evaluation of Invert, Posterize, Threshold, B/C and Gradient Map.
    func applyLab(_ buf: inout RGBABuffer) {
        switch adjustment {
        case .invert:
            map(&buf) { AdjustMath.labDenorm(SIMD3(repeating: 1) - simd_clamp(AdjustMath.labNorm($0), .zero, SIMD3(repeating: 1))) }
        case .posterize(let levels):
            map(&buf) { c in
                let n = AdjustMath.labNorm(c)
                return AdjustMath.labDenorm(SIMD3(AdjustMath.posterize(n.x, levels), AdjustMath.posterize(n.y, levels), AdjustMath.posterize(n.z, levels)))
            }
        case .threshold(let level):
            let t = (level * 255).rounded()
            map(&buf) { c in SIMD3(repeating: (min(max(AdjustMath.labNorm(c).x, 0), 1) * 255).rounded() >= t ? 1 : 0) }
        case .brightnessContrast(let bc):
            let (b, c, legacy) = (bc.brightness, bc.contrast, bc.legacy)
            let p = AdjustMath.legacyBrightnessContrast(b, c)
            let t = luts.first ?? []
            func curve(_ v: Float) -> Float { legacy ? AdjustMath.legacyCurve(v, p) : AdjustMath.lut(t, v) }
            map(&buf) { col in
                let n = AdjustMath.labNorm(col)
                let l = curve(n.x)
                if l == n.x { return col }
                let before = AdjustMath.labDenorm(n), after = AdjustMath.labDenorm(SIMD3(l, n.y, n.z))
                return simd_clamp(col + after - before, .zero, SIMD3(repeating: 1))
            }
        case .gradientMap(let gm):
            let (stops, reverse, dither) = (gm.stops, gm.reverse, gm.dither)
            mapXY(&buf) { c, x, y in
                let l = min(max(AdjustMath.labNorm(c).x, 0), 1)
                var o = AdjustMath.gradient(stops, reverse ? 1 - l : l)
                if dither { o = simd_clamp(o + AdjustMath.bayer4(x, y) / 255, .zero, SIMD3(repeating: 1)) }
                return o
            }
        default: break
        }
    }

    /// `map_rgb`: `f` on the colour of every pixel with alpha > 0, in parallel.
    func map(_ buf: inout RGBABuffer, _ f: (SIMD3<Float>) -> SIMD3<Float>) {
        mapXY(&buf) { c, _, _ in f(c) }
    }

    func mapXY(_ buf: inout RGBABuffer, _ f: (SIMD3<Float>, Int32, Int32) -> SIMD3<Float>) {
        let rect = buf.rect
        let w = rect.width
        buf.px.withUnsafeMutableBufferPointer { p in
            let pb = UnsafeSendable(p)
            withoutActuallyEscaping(f) { fn in
                let fb = UnsafeSendable(fn)
                parallelRows(rect.height, width: w) { y in
                    let base = y * w
                    for x in 0..<w {
                        let q = pb.value[base + x]
                        if q.w <= 0 { continue }
                        let r = fb.value(SIMD3(q.x, q.y, q.z), rect.x0 + Int32(x), rect.y0 + Int32(y))
                        pb.value[base + x] = SIMD4(r, q.w)
                    }
                }
            }
        }
    }
}
