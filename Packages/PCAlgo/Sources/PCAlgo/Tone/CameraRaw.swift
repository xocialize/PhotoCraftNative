// Port of photocraft-algo (crates/algo/src/camera_raw.rs; photo_util.rs: hash01, bilinear), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Camera Raw Filter: a float develop pipeline over RGB pixels. Stages, in order (each
// skipped when its controls are neutral, so defaults are an identity):
// 1. White balance and exposure in linear light (sRGB curve as the working encoding).
// 2. Dehaze (He, Sun, Tang, "Single Image Haze Removal Using Dark Channel Prior", CVPR 2009).
// 3. Tone on luminance with colour ratios kept: Highlights / Shadows (a local Laplacian filter,
//    see CameraRawLocalTone.swift), Contrast (an S-curve), Clarity (guided filter, He et al.
//    2010) and Texture (band-pass); then Whites / Blacks (image-adaptive curves measured on
//    Photoshop 25.4, see CameraRawWhitesBlacks.swift).
// 4. Presence: Vibrance and Saturation. 5. Tone Curve: parametric regions, then point curves
//    (monotone cubic, Fritsch–Carlson 1980). 6. Color Mixer (HSL, eight hue bands).
// 7. Color Grading (shadows / midtones / highlights / global wheels).
// 8. Detail: sharpening and noise reduction on luminance / chroma.
// 9. Effects: post-crop vignette and grain (position-hashed, deterministic).
//
// GPU: stages 1, 3 (Contrast alone), 4–7 and 9 are per pixel and run as one Metal kernel
// (`CameraRawFilter` / `ToneKit.develop(on:)`); settings that use Dehaze, Highlights/Shadows,
// Clarity, Texture, Whites/Blacks or Detail (image statistics, pyramids, guided filters) run the
// CPU reference.

import Foundation
import PCFoundation

/// One colour grading wheel (photocraft `camera_raw::Wheel`).
public struct CameraRawWheel: Codable, Sendable, Hashable {
    /// Degrees 0…360.
    public var hue: Float
    /// 0…100.
    public var sat: Float
    /// −100…100.
    public var lum: Float

    public init(hue: Float = 0, sat: Float = 0, lum: Float = 0) { self.hue = hue; self.sat = sat; self.lum = lum }

    var neutral: Bool { sat == 0 && lum == 0 }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = try c.decodeIfPresent(Float.self, forKey: .hue) ?? 0
        sat = try c.decodeIfPresent(Float.self, forKey: .sat) ?? 0
        lum = try c.decodeIfPresent(Float.self, forKey: .lum) ?? 0
    }
}

/// Camera Raw settings in Adobe Camera Raw's slider units (photocraft `camera_raw::CameraRaw`;
/// camelCase keys, every field optional when decoding).
public struct CameraRaw: Codable, Sendable, Hashable {
    // Basic
    public var temperature: Float = 0
    public var tint: Float = 0
    public var exposure: Float = 0
    public var contrast: Float = 0
    public var highlights: Float = 0
    public var shadows: Float = 0
    public var whites: Float = 0
    public var blacks: Float = 0
    public var texture: Float = 0
    public var clarity: Float = 0
    public var dehaze: Float = 0
    public var vibrance: Float = 0
    public var saturation: Float = 0
    // Tone curve
    public var curveHighlights: Float = 0
    public var curveLights: Float = 0
    public var curveDarks: Float = 0
    public var curveShadows: Float = 0
    /// Region splits (percent), three values.
    public var curveSplits: [Float] = [25, 50, 75]
    /// Point curves as (input, output) in 0…255 (empty = linear).
    public var pointCurve: [SIMD2<Float>] = []
    public var pointCurveRed: [SIMD2<Float>] = []
    public var pointCurveGreen: [SIMD2<Float>] = []
    public var pointCurveBlue: [SIMD2<Float>] = []
    // Color mixer: red, orange, yellow, green, aqua, blue, purple, magenta (eight each).
    public var hslHue: [Float] = [Float](repeating: 0, count: 8)
    public var hslSat: [Float] = [Float](repeating: 0, count: 8)
    public var hslLum: [Float] = [Float](repeating: 0, count: 8)
    // Color grading
    public var gradeShadows = CameraRawWheel()
    public var gradeMidtones = CameraRawWheel()
    public var gradeHighlights = CameraRawWheel()
    public var gradeGlobal = CameraRawWheel()
    public var gradeBlending: Float = 50
    public var gradeBalance: Float = 0
    // Detail
    public var sharpenAmount: Float = 0
    public var sharpenRadius: Float = 1
    public var sharpenDetail: Float = 25
    public var sharpenMasking: Float = 0
    public var noiseLuminance: Float = 0
    public var noiseLuminanceDetail: Float = 50
    public var noiseColor: Float = 0
    public var noiseColorDetail: Float = 50
    // Effects
    public var grainAmount: Float = 0
    public var grainSize: Float = 25
    public var grainRoughness: Float = 50
    public var vignetteAmount: Float = 0
    public var vignetteMidpoint: Float = 50
    public var vignetteRoundness: Float = 0
    public var vignetteFeather: Float = 50
    public var vignetteHighlights: Float = 0
    /// `highlightPriority | colorPriority | paintOverlay`.
    public var vignetteStyle: String = "highlightPriority"
    public var seed: UInt32 = 0
    /// Pixel-size multiplier for previews on downsampled proxies (radii in px scale by it).
    public var pixelScale: Float = 1
    /// The document's transfer curve: 0 for sRGB's, else the gamma of a power-law space.
    public var encodingGamma: Float = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case temperature, tint, exposure, contrast, highlights, shadows, whites, blacks, texture, clarity, dehaze, vibrance, saturation
        case curveHighlights, curveLights, curveDarks, curveShadows, curveSplits, pointCurve, pointCurveRed, pointCurveGreen, pointCurveBlue
        case hslHue, hslSat, hslLum, gradeShadows, gradeMidtones, gradeHighlights, gradeGlobal, gradeBlending, gradeBalance
        case sharpenAmount, sharpenRadius, sharpenDetail, sharpenMasking, noiseLuminance, noiseLuminanceDetail, noiseColor, noiseColorDetail
        case grainAmount, grainSize, grainRoughness, vignetteAmount, vignetteMidpoint, vignetteRoundness, vignetteFeather, vignetteHighlights
        case vignetteStyle, seed, pixelScale, encodingGamma
    }

    /// serde `#[serde(default)]`: missing keys keep their defaults.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func f(_ k: CodingKeys, _ v: inout Float) throws { if let x = try c.decodeIfPresent(Float.self, forKey: k) { v = x } }
        func a(_ k: CodingKeys, _ v: inout [Float], _ n: Int) throws {
            if let x = try c.decodeIfPresent([Float].self, forKey: k) {
                guard x.count == n else { throw DecodingError.dataCorruptedError(forKey: k, in: c, debugDescription: "expected \(n) values") }
                v = x
            }
        }
        func pc(_ k: CodingKeys, _ v: inout [SIMD2<Float>]) throws { if let x = try c.decodeIfPresent([SIMD2<Float>].self, forKey: k) { v = x } }
        func wh(_ k: CodingKeys, _ v: inout CameraRawWheel) throws { if let x = try c.decodeIfPresent(CameraRawWheel.self, forKey: k) { v = x } }
        try f(.temperature, &temperature); try f(.tint, &tint); try f(.exposure, &exposure); try f(.contrast, &contrast)
        try f(.highlights, &highlights); try f(.shadows, &shadows); try f(.whites, &whites); try f(.blacks, &blacks)
        try f(.texture, &texture); try f(.clarity, &clarity); try f(.dehaze, &dehaze); try f(.vibrance, &vibrance); try f(.saturation, &saturation)
        try f(.curveHighlights, &curveHighlights); try f(.curveLights, &curveLights); try f(.curveDarks, &curveDarks); try f(.curveShadows, &curveShadows)
        try a(.curveSplits, &curveSplits, 3)
        try pc(.pointCurve, &pointCurve); try pc(.pointCurveRed, &pointCurveRed); try pc(.pointCurveGreen, &pointCurveGreen); try pc(.pointCurveBlue, &pointCurveBlue)
        try a(.hslHue, &hslHue, 8); try a(.hslSat, &hslSat, 8); try a(.hslLum, &hslLum, 8)
        try wh(.gradeShadows, &gradeShadows); try wh(.gradeMidtones, &gradeMidtones); try wh(.gradeHighlights, &gradeHighlights); try wh(.gradeGlobal, &gradeGlobal)
        try f(.gradeBlending, &gradeBlending); try f(.gradeBalance, &gradeBalance)
        try f(.sharpenAmount, &sharpenAmount); try f(.sharpenRadius, &sharpenRadius); try f(.sharpenDetail, &sharpenDetail); try f(.sharpenMasking, &sharpenMasking)
        try f(.noiseLuminance, &noiseLuminance); try f(.noiseLuminanceDetail, &noiseLuminanceDetail); try f(.noiseColor, &noiseColor); try f(.noiseColorDetail, &noiseColorDetail)
        try f(.grainAmount, &grainAmount); try f(.grainSize, &grainSize); try f(.grainRoughness, &grainRoughness)
        try f(.vignetteAmount, &vignetteAmount); try f(.vignetteMidpoint, &vignetteMidpoint); try f(.vignetteRoundness, &vignetteRoundness)
        try f(.vignetteFeather, &vignetteFeather); try f(.vignetteHighlights, &vignetteHighlights)
        if let s = try c.decodeIfPresent(String.self, forKey: .vignetteStyle) { vignetteStyle = s }
        if let s = try c.decodeIfPresent(UInt32.self, forKey: .seed) { seed = s }
        try f(.pixelScale, &pixelScale); try f(.encodingGamma, &encodingGamma)
    }

    // MARK: Validation (photocraft `validate_curve`, `validate`, `validate_changes`)

    /// Most points a point curve accepts from commands.
    public static let maxCurvePoints = 16

    /// Checks a point curve from untrusted input: empty (linear) or 2…16 finite points in 0…255
    /// with inputs increasing by at least one level.
    public static func validateCurve(_ points: [SIMD2<Float>]) -> String? {
        if points.count == 1 { return "a nonempty curve needs at least two points" }
        if points.count > maxCurvePoints { return "at most \(maxCurvePoints) curve points" }
        if !points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...255).contains($0.x) && (0...255).contains($0.y) }) {
            return "curve coordinates must be finite and in 0..=255"
        }
        if zip(points, points.dropFirst()).contains(where: { $1.x - $0.x < 1 }) { return "curve inputs must increase by at least one level" }
        return nil
    }

    var namedCurves: [(String, [SIMD2<Float>])] {
        [("pointCurve", pointCurve), ("pointCurveRed", pointCurveRed), ("pointCurveGreen", pointCurveGreen), ("pointCurveBlue", pointCurveBlue)]
    }

    /// Rejects malformed point curves in new settings (nil when valid).
    public func validate() -> String? {
        for (name, c) in namedCurves { if let e = Self.validateCurve(c) { return "\(name): \(e)" } }
        return nil
    }

    /// `validate` for an edit of `stored` settings: a curve left as stored is accepted.
    public func validateChanges(_ stored: CameraRaw) -> String? {
        for ((name, c), (_, kept)) in zip(namedCurves, stored.namedCurves) where c != kept {
            if let e = Self.validateCurve(c) { return "\(name): \(e)" }
        }
        return nil
    }

    // MARK: Neutrality

    var wbNeutral: Bool { temperature == 0 && tint == 0 && exposure == 0 }
    var localToneNeutral: Bool { [contrast, highlights, shadows, texture, clarity].allSatisfy { $0 == 0 } }
    var toneNeutral: Bool { localToneNeutral && whites == 0 && blacks == 0 }
    var hslNeutral: Bool { (hslHue + hslSat + hslLum).allSatisfy { $0 == 0 } }
    var gradeNeutral: Bool { gradeShadows.neutral && gradeMidtones.neutral && gradeHighlights.neutral && gradeGlobal.neutral }
    var parametricNeutral: Bool { [curveHighlights, curveLights, curveDarks, curveShadows].allSatisfy { $0 == 0 } }
    var curvesNeutral: Bool {
        parametricNeutral && [pointCurve, pointCurveRed, pointCurveGreen, pointCurveBlue].allSatisfy(CameraRawKit.isLinear)
    }

    /// True when every control is neutral (the filter is an identity).
    public var isIdentity: Bool {
        wbNeutral && toneNeutral && dehaze == 0 && vibrance == 0 && saturation == 0 && curvesNeutral && hslNeutral && gradeNeutral
            && sharpenAmount == 0 && noiseLuminance == 0 && noiseColor == 0 && grainAmount == 0 && vignetteAmount == 0
    }

    /// Whether every active stage is per pixel (the Metal path handles it).
    public var isPerPixel: Bool {
        dehaze == 0 && highlights == 0 && shadows == 0 && texture == 0 && clarity == 0 && whites == 0 && blacks == 0
            && !(noiseLuminance > 0 || noiseColor > 0 || sharpenAmount > 0)
    }
}

/// Camera Raw's shared maths (photocraft `camera_raw` private functions).
enum CameraRawKit {
    /// How the pixels encode light: the sRGB curve (gamma 0) or a pure power law.
    struct Encoding: Equatable {
        var gamma: Float
        static func of(_ gamma: Float) -> Encoding { Encoding(gamma: gamma.isFinite && gamma > 0 ? clampf(gamma, 0.5, 4) : 0) }
        @inline(__always) func decode(_ v: Float) -> Float { gamma > 0 ? powf(Float.maximum(v, 0), gamma) : ColorConvert.srgbToLinear(v) }
        @inline(__always) func encode(_ v: Float) -> Float { gamma > 0 ? powf(Float.maximum(v, 0), 1 / gamma) : ColorConvert.linearToSRGB(v) }
    }

    /// Hue band centres of the Color Mixer (degrees).
    static let hslBands: [Float] = [0, 30, 60, 120, 180, 240, 270, 300]

    @inline(__always)
    static func luma(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// camera_raw's smoothstep (no degenerate-edge case).
    @inline(__always)
    static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = clampf((x - e0) / (e1 - e0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    static func isLinear(_ c: [SIMD2<Float>]) -> Bool { c.count < 2 || c.allSatisfy { abs($0.x - $0.y) < 1e-3 } }

    /// Box mean of a single-channel buffer (radius `r`, edge clamped), f64 running sums: rows
    /// (subtracting in f64), then columns (subtracting in f32, as photocraft's banded pass).
    static func boxMean(_ v: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        if r == 0 || w == 0 || h == 0 { return v }
        let n = Double(2 * r + 1)
        var tmp = [Float](repeating: 0, count: w * h)
        v.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { t in
                let ts = UnsafeSendable(t)
                parallelChunks(h, minChunk: 8) { rows in
                    for y in rows {
                        let base = y * w
                        @inline(__always) func at(_ k: Int) -> Double { Double(src[base + min(max(k, 0), w - 1)]) }
                        var acc = -0.0
                        for k in -r...r { acc += at(k) }
                        for x in 0..<w {
                            ts.value[base + x] = Float(acc / n)
                            acc += at(x + r + 1) - at(x - r)
                        }
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        tmp.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                let os = UnsafeSendable(o)
                parallelChunks(w, minChunk: 16) { cols in
                    for x in cols {
                        @inline(__always) func at(_ y: Int) -> Float { t[min(max(y, 0), h - 1) * w + x] }
                        var acc = 0.0
                        for y in -r...r { acc += Double(at(y)) }
                        for y in 0..<h {
                            os.value[y * w + x] = Float(acc / n)
                            acc += Double(at(y + r + 1) - at(y - r))
                        }
                    }
                }
            }
        }
        return out
    }

    /// Approximate Gaussian: box means of the three Kovesi radii in turn.
    static func gauss(_ v: [Float], _ w: Int, _ h: Int, _ sigma: Float) -> [Float] {
        if sigma < 0.3 { return v }
        var out = v
        for r in FxUtil.gaussBoxRadii(sigma) { out = boxMean(out, w, h, r) }
        return out
    }

    /// photocraft `photo_util::bilinear` of a single-channel buffer, clamped to the edges.
    @inline(__always)
    static func bilinear(_ buf: UnsafeBufferPointer<Float>, _ w: Int, _ h: Int, _ x0f: Float, _ y0f: Float) -> Float {
        let x = clampf(x0f, 0, Float(w - 1)), y = clampf(y0f, 0, Float(h - 1))
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let tx = x - Float(x0), ty = y - Float(y0)
        @inline(__always) func p(_ xx: Int, _ yy: Int) -> Float { buf[yy * w + xx] }
        let top = p(x0, y0) + (p(x1, y0) - p(x0, y0)) * tx
        let bot = p(x0, y1) + (p(x1, y1) - p(x0, y1)) * tx
        return top + (bot - top) * ty
    }

    /// Guided filter of `p` guided by `i` (He et al. 2010).
    static func guided(_ i: [Float], _ p: [Float], _ w: Int, _ h: Int, _ r: Int, _ eps: Float) -> [Float] {
        let mi = boxMean(i, w, h, r), mp = boxMean(p, w, h, r)
        let ip = zip(i, p).map { $0 * $1 }, ii = i.map { $0 * $0 }
        let mip = boxMean(ip, w, h, r), mii = boxMean(ii, w, h, r)
        let a = (0..<(w * h)).map { k in (mip[k] - mi[k] * mp[k]) / (mii[k] - mi[k] * mi[k] + eps) }
        let b = (0..<(w * h)).map { k in mp[k] - a[k] * mi[k] }
        let ma = boxMean(a, w, h, r), mb = boxMean(b, w, h, r)
        return (0..<(w * h)).map { k in ma[k] * i[k] + mb[k] }
    }

    /// Fast guided filter (He & Sun 2015): coefficients on an `s×` subsampled copy.
    static func guidedFast(_ i: [Float], _ p: [Float], _ w: Int, _ h: Int, _ r: Int, _ eps: Float) -> [Float] {
        let s = min(max(r / 8, 1), 8)
        if s == 1 { return guided(i, p, w, h, r, eps) }
        let sw = (w + s - 1) / s, sh = (h + s - 1) / s
        func down(_ v: [Float]) -> [Float] {
            var o = [Float](repeating: 0, count: sw * sh), c = [Float](repeating: 0, count: sw * sh)
            for y in 0..<h { for x in 0..<w { let k = (y / s) * sw + x / s; o[k] += v[y * w + x]; c[k] += 1 } }
            return zip(o, c).map { $0 / Float.maximum($1, 1) }
        }
        let si = down(i), sp = down(p)
        let rs = max(r / s, 1)
        let mi = boxMean(si, sw, sh, rs), mp = boxMean(sp, sw, sh, rs)
        let ip = zip(si, sp).map { $0 * $1 }, ii = si.map { $0 * $0 }
        let mip = boxMean(ip, sw, sh, rs), mii = boxMean(ii, sw, sh, rs)
        let a = (0..<(sw * sh)).map { k in (mip[k] - mi[k] * mp[k]) / (mii[k] - mi[k] * mi[k] + eps) }
        let b = (0..<(sw * sh)).map { k in mp[k] - a[k] * mi[k] }
        let ma = boxMean(a, sw, sh, rs), mb = boxMean(b, sw, sh, rs)
        var out = [Float](repeating: 0, count: w * h)
        let sf = Float(s)
        ma.withUnsafeBufferPointer { mab in
            mb.withUnsafeBufferPointer { mbb in
                out.withUnsafeMutableBufferPointer { o in
                    let os = UnsafeSendable(o)
                    parallelChunks(h, minChunk: 8) { rows in
                        for y in rows {
                            let fy = (Float(y) + 0.5) / sf - 0.5
                            for x in 0..<w {
                                let fx = (Float(x) + 0.5) / sf - 0.5
                                os.value[y * w + x] = bilinear(mab, sw, sh, fx, fy) * i[y * w + x] + bilinear(mbb, sw, sh, fx, fy)
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Monotone cubic (Fritsch–Carlson) through `pts` (0…255), evaluated into an `n`-entry LUT
    /// (photocraft `curve_lut`).
    static func curveLUT(_ pts: [SIMD2<Float>], _ n: Int) -> [Float] {
        var p = ToneKit.sortedIndices(pts.count) { pts[$0].x / 255 }.map { SIMD2(pts[$0].x / 255, pts[$0].y / 255) }
        var dd: [SIMD2<Float>] = []
        for q in p where dd.last.map({ abs(q.x - $0.x) >= 1e-6 }) ?? true { dd.append(q) }
        p = dd
        if p.count < 2 { return (0..<n).map { Float($0) / Float(n - 1) } }
        let m = p.count
        let d = (0..<(m - 1)).map { k in (p[k + 1].y - p[k].y) / Float.maximum(p[k + 1].x - p[k].x, 1e-6) }
        var t = [Float](repeating: 0, count: m)
        t[0] = d[0]
        t[m - 1] = d[m - 2]
        if m > 2 { for k in 1..<(m - 1) { t[k] = d[k - 1] * d[k] <= 0 ? 0 : (d[k - 1] + d[k]) / 2 } }
        for k in 0..<(m - 1) {
            if d[k] == 0 { t[k] = 0; t[k + 1] = 0; continue }
            let a = t[k] / d[k], b = t[k + 1] / d[k]
            let s = a * a + b * b
            if s > 9 {
                let tau = 3 / s.squareRoot()
                t[k] = tau * a * d[k]
                t[k + 1] = tau * b * d[k]
            }
        }
        return (0..<n).map { i in
            let x = Float(i) / Float(n - 1)
            if x <= p[0].x { return p[0].y }
            if x >= p[m - 1].x { return p[m - 1].y }
            var k = m - 2
            for j in 0..<(m - 1) where x <= p[j + 1].x { k = j; break }
            let hh = p[k + 1].x - p[k].x
            let s = (x - p[k].x) / hh
            let h00 = 2 * s * s * s - 3 * s * s + 1, h10 = s * s * s - 2 * s * s + s
            let h01 = -2 * s * s * s + 3 * s * s, h11 = s * s * s - s * s
            return clampf(h00 * p[k].y + h10 * hh * t[k] + h01 * p[k + 1].y + h11 * hh * t[k + 1], 0, 1)
        }
    }

    @inline(__always)
    static func lutEval(_ lut: UnsafeBufferPointer<Float>, _ v: Float) -> Float {
        if !(v >= 0 && v <= 1) {
            // Extend linearly outside (float documents).
            return v < 0 ? v + lut[0] : lut[lut.count - 1] + (v - 1)
        }
        let x = v * Float(lut.count - 1)
        let i = min(Int(x), lut.count - 2)
        let t = x - Float(i)
        return lut[i] + (lut[i + 1] - lut[i]) * t
    }

    /// Parametric tone curve as a LUT (photocraft `parametric_lut`).
    static func parametricLUT(_ p: CameraRaw, _ n: Int) -> [Float] {
        let s = p.curveSplits.map { clampf($0, 5, 95) / 100 }
        let centres = [s[0] / 2, (s[0] + s[1]) / 2, (s[1] + s[2]) / 2, (s[2] + 1) / 2]
        let amounts = [p.curveShadows, p.curveDarks, p.curveLights, p.curveHighlights]
        let widths = [Float.maximum(s[0], 0.1), Float.maximum(s[1] - s[0], 0.1), Float.maximum(s[2] - s[1], 0.1), Float.maximum(1 - s[2], 0.1)]
        var lut: [Float] = (0..<n).map { i in
            let x = Float(i) / Float(n - 1)
            var y = x
            for k in 0..<4 {
                let d = (x - centres[k]) / (widths[k] * 1.2)
                let bump = expf(-d * d * 2) * x * (1 - x) * 4
                y += amounts[k] / 100 * 0.25 * bump
            }
            return clampf(y, 0, 1)
        }
        for i in 1..<n { lut[i] = Float.maximum(lut[i], lut[i - 1]) }
        return lut
    }

    @inline(__always)
    static func rgbToHSV(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let mx = Float.maximum(Float.maximum(c.x, c.y), c.z), mn = Float.minimum(Float.minimum(c.x, c.y), c.z)
        let d = mx - mn
        let h: Float
        if d <= 1e-9 { h = 0 }
        else if mx == c.x { h = 60 * euclidMod((c.y - c.z) / d, 6) }
        else if mx == c.y { h = 60 * ((c.z - c.x) / d + 2) }
        else { h = 60 * ((c.x - c.y) / d + 4) }
        return SIMD3(h, mx > 1e-9 ? d / mx : 0, mx)
    }

    @inline(__always)
    static func hsvToRGB(_ h0: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let h = euclidMod(h0, 360) / 60
        let c = v * s
        let x = c * (1 - abs(fmodf(h, 2) - 1))
        let seg: UInt32 = h.isNaN || h <= 0 ? 0 : (h >= 4_294_967_296 ? .max : UInt32(h))
        let rgb: SIMD3<Float>
        switch seg {
        case 0: rgb = SIMD3(c, x, 0)
        case 1: rgb = SIMD3(x, c, 0)
        case 2: rgb = SIMD3(0, c, x)
        case 3: rgb = SIMD3(0, x, c)
        case 4: rgb = SIMD3(x, 0, c)
        default: rgb = SIMD3(c, 0, x)
        }
        let m = v - c
        return SIMD3(rgb.x + m, rgb.y + m, rgb.z + m)
    }

    /// Weights of the eight HSL bands at hue `h` (hat functions between neighbouring centres).
    static func bandWeights(_ h: Float) -> [Float] {
        (0..<8).map { k in
            let (c, prev, next) = (hslBands[k], hslBands[(k + 7) % 8], hslBands[(k + 1) % 8])
            let diff = fmodf(h - c + 540, 360) - 180
            let span = diff >= 0 ? euclidMod(next - c, 360) : euclidMod(c - prev, 360)
            return Float.maximum(1 - abs(diff) / Float.maximum(span, 1e-3), 0)
        }
    }

    /// photocraft `photo_util::hash01`: 64-bit position hash → 0…1.
    @inline(__always)
    static func hash01(_ x: Int64, _ y: Int64, _ seed: UInt64) -> Float {
        var z = UInt64(bitPattern: x) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: y) &* 0xC2B2_AE3D_27D4_EB4F ^ seed &* 0x1656_67B1_9E37_79F9
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }

    /// Rust's saturating `f32 as i64`.
    @inline(__always)
    static func toI64(_ v: Float) -> Int64 {
        if v.isNaN { return 0 }
        if v >= 9.223372e18 { return .max }
        if v <= -9.223372e18 { return .min }
        return Int64(v)
    }

    @inline(__always)
    static func valueNoise(_ x: Float, _ y: Float, _ seed: UInt64) -> Float {
        let xi = x.rounded(.down), yi = y.rounded(.down)
        let tx = x - xi, ty = y - yi
        let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        let (ix, iy) = (toI64(xi), toI64(yi))
        @inline(__always) func h(_ dx: Int64, _ dy: Int64) -> Float { hash01(ix &+ dx, iy &+ dy, seed) }
        let top = h(0, 0) + (h(1, 0) - h(0, 0)) * sx
        let bot = h(0, 1) + (h(1, 1) - h(0, 1)) * sx
        return top + (bot - top) * sy
    }
}

extension ToneKit {
    /// Camera Raw's white-balance channel gains for Temperature / Tint (−100…100): warmer raises
    /// red and lowers blue (±35 %), a negative tint raises green, a positive one lowers it (±25 %)
    /// (photocraft `white_balance_gains`).
    public static func whiteBalanceGains(temperature: Float, tint: Float) -> SIMD3<Float> {
        let t = temperature / 100, tn = tint / 100
        return SIMD3(1 + 0.35 * t, 1 - 0.25 * tn, 1 - 0.35 * t)
    }

    /// Monotone cubic LUT of a point curve (photocraft `curve_lut`).
    public static func curveLUT(_ points: [SIMD2<Float>], count n: Int) -> [Float] { CameraRawKit.curveLUT(points, n) }

    /// Weights of the eight Color Mixer bands at hue `h` (photocraft `band_weights`).
    public static func bandWeights(_ h: Float) -> [Float] { CameraRawKit.bandWeights(h) }

    /// Runs the Camera Raw pipeline on straight RGBA pixels (`w × h`, display-encoded RGB);
    /// `float` keeps values above 1 (32-bit documents) — photocraft `camera_raw::develop`.
    public static func develop(_ px: inout [SIMD4<Float>], w: Int, h: Int, _ p: CameraRaw, float: Bool) {
        CameraRawKit.develop(&px, w, h, p, float)
    }

    /// `develop` on the CPU (`.cpu`) or, for per-pixel settings (`CameraRaw.isPerPixel`), on the
    /// GPU (`.auto` falls back to the CPU otherwise; `.gpu` throws).
    public static func develop(_ px: inout [SIMD4<Float>], w: Int, h: Int, _ p: CameraRaw, float: Bool, on backend: Backend) throws {
        if backend == .cpu || (backend == .auto && !p.isPerPixel) { CameraRawKit.develop(&px, w, h, p, float); return }
        try runRGBA(CameraRawFilter(settings: p, float: float), &px, w: w, h: h, on: backend)
    }
}

extension CameraRawKit {
    static func develop(_ px: inout [SIMD4<Float>], _ w: Int, _ h: Int, _ p: CameraRaw, _ float: Bool) {
        if px.isEmpty || p.isIdentity { return }
        let ps = clampf(p.pixelScale, 0.01, 1)
        let long = Float(max(w, h))
        // 1. White balance + exposure in linear light.
        if !p.wbNeutral {
            let g = wbGains(p)
            forEach(&px) { q in
                for c in 0..<3 { q[c] = ColorConvert.linearToSRGB(Float.maximum(ColorConvert.srgbToLinear(q[c]) * g[c], 0)) }
            }
        }
        // 2. Dehaze.
        if p.dehaze != 0 { dehaze(&px, w, h, p.dehaze / 100) }
        // 3. Tone. Highlights and Shadows: a local Laplacian filter.
        if p.highlights != 0 || p.shadows != 0 {
            LocalTone.apply(&px, w, h, p.shadows, p.highlights, Encoding.of(p.encodingGamma))
        }
        if !p.localToneNeutral && [p.contrast, p.texture, p.clarity].contains(where: { $0 != 0 }) {
            let l = px.map { Float.maximum(luma(SIMD3($0.x, $0.y, $0.z)), 0) }
            let lc = l.map { Float.minimum($0, 1) }
            let clar = p.clarity != 0 ? guidedFast(lc, lc, w, h, max(ToneKit.asIndex(long * 0.02), 3), 0.005) : nil
            let tex = p.texture != 0 ? gauss(lc, w, h, Float.maximum(long * 0.002, 1.5 * ps)) : nil
            let kCon = p.contrast / 100 * 0.6
            px.withUnsafeMutableBufferPointer { q in
                let qs = UnsafeSendable(q)
                parallelChunks(q.count, minChunk: 4096) { r in
                    for i in r { qs.value[i] = tonePixel(qs.value[i], l[i], lc[i], clar?[i], tex?[i], p.clarity, p.texture, kCon) }
                }
            }
        }
        // 3b. Whites and Blacks: global curves adapted to the image's black and white points.
        if p.whites != 0 || p.blacks != 0 {
            let enc = Encoding.of(p.encodingGamma)
            let (bp, wp) = luminancePoints(px, w, h, enc)
            let (xw, xb) = WhitesBlacks.amounts(clampf(p.whites, -100, 100), clampf(p.blacks, -100, 100), bp, wp)
            WhitesBlacks.apply(&px, xw, xb, enc)
        }
        // 4–7: per-pixel colour stages.
        if p.needsColor {
            let plan = ColorPlan(p)
            forEach(&px) { q in q = plan.apply(q) }
        }
        // 8. Detail.
        if p.noiseLuminance > 0 || p.noiseColor > 0 || p.sharpenAmount > 0 { detail(&px, w, h, p, ps) }
        // 9. Effects.
        if p.vignetteAmount != 0 {
            let v = Vignette(p, w, h)
            px.withUnsafeMutableBufferPointer { q in
                let qs = UnsafeSendable(q)
                parallelChunks(h, minChunk: 4) { rows in
                    for y in rows { for x in 0..<w { qs.value[y * w + x] = v.apply(qs.value[y * w + x], x, y) } }
                }
            }
        }
        if p.grainAmount > 0 {
            let g = Grain(p, ps)
            px.withUnsafeMutableBufferPointer { q in
                let qs = UnsafeSendable(q)
                parallelChunks(h, minChunk: 4) { rows in
                    for y in rows { for x in 0..<w { qs.value[y * w + x] = g.apply(qs.value[y * w + x], x, y) } }
                }
            }
        }
        if !float { forEach(&px) { q in for c in 0..<3 { q[c] = clampf(q[c], 0, 1) } } }
    }

    static func forEach(_ px: inout [SIMD4<Float>], _ f: (inout SIMD4<Float>) -> Void) {
        px.withUnsafeMutableBufferPointer { q in
            let qs = UnsafeSendable(q)
            withoutActuallyEscaping(f) { fe in
                nonisolated(unsafe) let fn = fe
                parallelChunks(q.count, minChunk: 4096) { r in for i in r { fn(&qs.value[i]) } }
            }
        }
    }

    /// Stage 1's channel gains: white balance normalised to keep luminance, times 2^exposure.
    static func wbGains(_ p: CameraRaw) -> SIMD3<Float> {
        let g = ToneKit.whiteBalanceGains(temperature: p.temperature, tint: p.tint)
        let norm = luma(g)
        let e = powf(2, p.exposure)
        return SIMD3(g.x / norm * e, g.y / norm * e, g.z / norm * e)
    }

    /// Stage 3's per-pixel Contrast / Clarity / Texture on luminance with colour ratios kept.
    @inline(__always)
    static func tonePixel(_ q0: SIMD4<Float>, _ l0: Float, _ lci: Float, _ clar: Float?, _ tex: Float?, _ clarity: Float, _ texture: Float,
                          _ kCon: Float) -> SIMD4<Float> {
        var q = q0
        var lv = lci
        if let c = clar {
            let e = 2 * clampf(lv, 0, 1) - 1
            let mw = 1 - e * e
            lv += clarity / 100 * 0.8 * (lci - c) * mw
        }
        if let t = tex { lv += texture / 100 * 0.9 * clampf(lci - t, -0.1, 0.1) }
        if kCon != 0 {
            let xx = clampf(lv, 0, 1)
            lv += -kCon * sinf(PCAMath.tau * xx) / PCAMath.tau
        }
        let lv2 = Float.maximum(lv, 0) + (l0 - lci)
        let ratio: Float = l0 > 1e-5 ? lv2 / l0 : 1
        for c in 0..<3 { q[c] = l0 > 1e-5 ? q[c] * ratio : q[c] + (lv2 - l0) }
        return q
    }

    /// The image's black and white points as sRGB-encoded grey levels: the 3rd percentile of
    /// the luminance and the 99.5th of the brightest channel, on a copy at most 256 px across.
    static func luminancePoints(_ px: [SIMD4<Float>], _ w: Int, _ h: Int, _ enc: Encoding) -> (Float, Float) {
        let f = max((max(w, h) + 255) / 256, 1)
        let sw = (w + f - 1) / f, sh = (h + f - 1) / f
        var sum = [SIMD4<Double>](repeating: .zero, count: sw * sh)
        for y in 0..<h {
            for x in 0..<w {
                let q = px[y * w + x]
                let k = (y / f) * sw + x / f
                for c in 0..<3 { sum[k][c] += Double(clampf(enc.decode(q[c]), 0, 1)) }
                sum[k][3] += 1
            }
        }
        let cells: [SIMD3<Float>] = sum.filter { $0[3] > 0 }.map { s in SIMD3(Float(s.x / s.w), Float(s.y / s.w), Float(s.z / s.w)) }
        if cells.isEmpty { return (0, 1) }
        func pct(_ v: [Float], _ q: Float) -> Float {
            let s = ToneKit.totalSorted(v)
            return s[Int((Float(s.count - 1) * q).rounded())]
        }
        let bp = pct(cells.map(luma), 0.03)
        let wp = pct(cells.map { Float.maximum(Float.maximum($0.x, $0.y), $0.z) }, 0.995)
        return (ColorConvert.linearToSRGB(bp), ColorConvert.linearToSRGB(wp))
    }

    // MARK: 4–7 Colour stages

    /// The derived constants of the colour stages (photocraft `develop`'s `need_color` block).
    struct ColorPlan {
        var vibSat: Bool, saturation: Float, vibrance: Float
        var par: [Float]?, master: [Float]?, chan: [[Float]?]
        var hsl: Bool, hue: [Float], sat: [Float], lum: [Float]
        var grade: Bool, tints: [SIMD3<Float>], lums: [Float], blend: Float, bal: Float

        init(_ p: CameraRaw) {
            vibSat = p.vibrance != 0 || p.saturation != 0
            saturation = p.saturation; vibrance = p.vibrance
            par = p.parametricNeutral ? nil : parametricLUT(p, 1024)
            func pts(_ c: [SIMD2<Float>]) -> [Float]? { isLinear(c) ? nil : curveLUT(c, 1024) }
            master = pts(p.pointCurve)
            chan = [pts(p.pointCurveRed), pts(p.pointCurveGreen), pts(p.pointCurveBlue)]
            hsl = !p.hslNeutral; hue = p.hslHue; sat = p.hslSat; lum = p.hslLum
            grade = !p.gradeNeutral
            func tint(_ wh: CameraRawWheel) -> SIMD3<Float> {
                let c = hsvToRGB(wh.hue, 1, 1)
                let l = luma(c)
                return SIMD3((c.x - l) * wh.sat / 100 * 0.3, (c.y - l) * wh.sat / 100 * 0.3, (c.z - l) * wh.sat / 100 * 0.3)
            }
            tints = [tint(p.gradeShadows), tint(p.gradeMidtones), tint(p.gradeHighlights), tint(p.gradeGlobal)]
            lums = [p.gradeShadows.lum, p.gradeMidtones.lum, p.gradeHighlights.lum, p.gradeGlobal.lum]
            blend = 0.15 + clampf(p.gradeBlending, 0, 100) / 100 * 0.35
            bal = clampf(p.gradeBalance, -100, 100) / 100 * 0.25
        }

        func apply(_ q: SIMD4<Float>) -> SIMD4<Float> {
            var c = SIMD3(q.x, q.y, q.z)
            if vibSat {
                let l = luma(c)
                let mx = Float.maximum(Float.maximum(c.x, c.y), c.z), mn = Float.minimum(Float.minimum(c.x, c.y), c.z)
                let s: Float = mx > 1e-6 ? (mx - mn) / mx : 0
                // Vibrance protects skin-ish hues (oranges) a little, like ACR.
                let hh = rgbToHSV(c).x
                let skin = clampf(1 - abs(hh - 25) / 25, 0, 1) * 0.5
                let k = Float.maximum(1 + saturation / 100 + vibrance / 100 * (1 - s) * (1 - skin), 0)
                c = SIMD3(l + (c.x - l) * k, l + (c.y - l) * k, l + (c.z - l) * k)
            }
            if let lut = par { lut.withUnsafeBufferPointer { b in c = SIMD3(lutEval(b, c.x), lutEval(b, c.y), lutEval(b, c.z)) } }
            if let lut = master { lut.withUnsafeBufferPointer { b in c = SIMD3(lutEval(b, c.x), lutEval(b, c.y), lutEval(b, c.z)) } }
            for ch in 0..<3 { if let lut = chan[ch] { lut.withUnsafeBufferPointer { b in c[ch] = lutEval(b, c[ch]) } } }
            if hsl {
                let hsv = rgbToHSV(SIMD3(Float.maximum(c.x, 0), Float.maximum(c.y, 0), Float.maximum(c.z, 0)))
                let (hh, s, v) = (hsv.x, hsv.y, hsv.z)
                if s > 1e-4 {
                    let wts = bandWeights(hh)
                    var dh: Float = 0, ds: Float = 0, dl: Float = 0
                    for k in 0..<8 { dh += wts[k] * hue[k]; ds += wts[k] * sat[k]; dl += wts[k] * lum[k] }
                    let nh = hh + dh / 100 * 30
                    let ns = clampf(s * (1 + ds / 100), 0, 1)
                    var out = hsvToRGB(nh, ns, v)
                    // Keep the luminance, then apply the luminance shift weighted by saturation.
                    let (l0, l1) = (luma(c), luma(out))
                    if l1 > 1e-6 { out = SIMD3(out.x * l0 / l1, out.y * l0 / l1, out.z * l0 / l1) }
                    let k = powf(2, dl / 100 * 1 * s)
                    c = SIMD3(out.x * k, out.y * k, out.z * k)
                }
            }
            if grade {
                let l = clampf(luma(c), 0, 1)
                let sh = 1 - smoothstep(0, 0.5 + bal + blend, l)
                let hi = smoothstep(0.5 + bal - blend, 1, l)
                let mid = Float.maximum(1 - sh - hi, 0)
                let masks: [Float] = [sh, mid, hi, 1]
                for k in 0..<4 {
                    for ch in 0..<3 { c[ch] += masks[k] * tints[k][ch] }
                    if lums[k] != 0 {
                        let f = powf(2, masks[k] * lums[k] / 100 * 0.6)
                        c = SIMD3(c.x * f, c.y * f, c.z * f)
                    }
                }
            }
            return SIMD4(c, q.w)
        }
    }

    // MARK: 9 Effects

    struct Vignette {
        var amt: Float, hl: Float, style: String
        var cx: Float, cy: Float, ax: Float, ay: Float, pw: Float, edge0: Float, edge1: Float

        init(_ p: CameraRaw, _ w: Int, _ h: Int) {
            amt = p.vignetteAmount / 100
            let mid = clampf(p.vignetteMidpoint, 0, 100) / 100
            let feather = clampf(p.vignetteFeather, 0, 100) / 100
            let round = clampf(p.vignetteRoundness, -100, 100) / 100
            hl = clampf(p.vignetteHighlights, 0, 100) / 100
            style = p.vignetteStyle
            cx = Float(w) / 2; cy = Float(h) / 2
            // Roundness: 0 follows the frame's aspect, +1 a circle, −1 a rounded rectangle.
            if round >= 0 {
                let r = Float.minimum(cx, cy) + (Float.maximum(cx, cy) - Float.minimum(cx, cy)) * (1 - round)
                ax = cx >= cy ? r : cx
                ay = cy > cx ? r : cy
            } else { ax = cx; ay = cy }
            pw = 2 + Float.maximum(-round, 0) * 6
            let inner = 1 - mid * 0.8
            edge0 = inner - feather * 0.5 * inner
            edge1 = inner + feather * 0.5 * (1.4 - inner) + 0.02
        }

        var styleCode: UInt32 { style == "paintOverlay" ? 2 : style == "colorPriority" ? 1 : 0 }

        @inline(__always)
        func apply(_ q0: SIMD4<Float>, _ x: Int, _ y: Int) -> SIMD4<Float> {
            var q = q0
            let dx = abs((Float(x) + 0.5 - cx) / ax), dy = abs((Float(y) + 0.5 - cy) / ay)
            let r = powf(powf(dx, pw) + powf(dy, pw), 1 / pw)
            let m = smoothstep(edge0, edge1, r)
            if m <= 0 { return q }
            let l = clampf(luma(SIMD3(q.x, q.y, q.z)), 0, 1)
            if style == "paintOverlay" {
                let target: Float = amt < 0 ? 0 : 1
                let k = m * abs(amt)
                for c in 0..<3 { q[c] += (target - q[c]) * k }
            } else {
                var k = powf(2, amt * 2 * m)
                if amt < 0 && hl > 0 {
                    // Highlights: let bright areas punch through a darkening vignette.
                    let protect = smoothstep(0.6, 1, l) * hl
                    k += (1 - k) * protect
                }
                if style == "colorPriority" {
                    let nl = l * k
                    for c in 0..<3 { q[c] += nl - l }
                } else {
                    for c in 0..<3 { q[c] *= k }
                }
            }
            return q
        }
    }

    struct Grain {
        var cell: Float, rough: Float, amt: Float, seed: UInt64, pscale: Float

        init(_ p: CameraRaw, _ ps: Float) {
            cell = 1 + p.grainSize / 25
            rough = p.grainRoughness / 100
            amt = p.grainAmount / 100 * 0.12
            seed = UInt64(p.seed)
            pscale = 1 / ps
        }

        @inline(__always)
        func apply(_ q0: SIMD4<Float>, _ x: Int, _ y: Int) -> SIMD4<Float> {
            var q = q0
            // Sample in full-resolution coordinates so previews match the result.
            let fx = Float(x) * pscale / cell, fy = Float(y) * pscale / cell
            let n = valueNoise(fx, fy, seed) * (1 - rough) + (valueNoise(fx * 2.3, fy * 2.3, seed &+ 7) - 0) * rough
            let l = clampf(luma(SIMD3(q.x, q.y, q.z)), 0, 1)
            let g = (n - 0.5) * 2 * amt * (0.4 + 2.4 * l * (1 - l))
            for c in 0..<3 { q[c] += g }
            return q
        }
    }

    // MARK: 2 Dehaze, 8 Detail (CPU)

    static func dehaze(_ px: inout [SIMD4<Float>], _ w: Int, _ h: Int, _ amount: Float) {
        // Transmission on a ≤ 768 px proxy, upsampled.
        let k = max((max(w, h) + 767) / 768, 1)
        let sw = (w + k - 1) / k, sh = (h + k - 1) / k
        var small = [SIMD3<Float>](repeating: .zero, count: sw * sh)
        var cnt = [Float](repeating: 0, count: sw * sh)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y / k) * sw + x / k
                for c in 0..<3 { small[i][c] += clampf(px[y * w + x][c], 0, 1) }
                cnt[i] += 1
            }
        }
        for i in 0..<small.count { let c = Float.maximum(cnt[i], 1); small[i] = SIMD3(small[i].x / c, small[i].y / c, small[i].z / c) }
        let r = max(max(sw, sh) / 60, 2)
        func minFilter(_ v: [Float]) -> [Float] {
            var a = [Float](repeating: 0, count: sw * sh)
            for y in 0..<sh {
                for x in 0..<sw {
                    var m = Float.greatestFiniteMagnitude
                    for xx in max(x - r, 0)...min(x + r, sw - 1) { m = Float.minimum(m, v[y * sw + xx]) }
                    a[y * sw + x] = m
                }
            }
            var b = [Float](repeating: 0, count: sw * sh)
            for y in 0..<sh {
                for x in 0..<sw {
                    var m = Float.greatestFiniteMagnitude
                    for yy in max(y - r, 0)...min(y + r, sh - 1) { m = Float.minimum(m, a[yy * sw + x]) }
                    b[y * sw + x] = m
                }
            }
            return b
        }
        let dark = minFilter(small.map { Float.minimum(Float.minimum($0.x, $0.y), $0.z) })
        // Atmospheric light: mean colour of the brightest 0.1 % of the dark channel.
        let idx = ToneKit.sortedIndices(sw * sh) { -dark[$0] }
        let top = max(sw * sh / 1000, 1)
        var air = SIMD3<Float>()
        for i in idx[0..<top] { for c in 0..<3 { air[c] += small[i][c] / Float(top) } }
        air = SIMD3(Float.maximum(air.x, 0.2), Float.maximum(air.y, 0.2), Float.maximum(air.z, 0.2))
        let normDark = minFilter(small.map { Float.minimum(Float.minimum($0.x / air.x, $0.y / air.y), $0.z / air.z) })
        let tRaw = normDark.map { 1 - 0.95 * $0 }
        let guide = small.map(luma)
        let t = guided(guide, tRaw, sw, sh, r * 2, 1e-3)
        let ks = Float(k)
        t.withUnsafeBufferPointer { tb in
            px.withUnsafeMutableBufferPointer { q in
                let qs = UnsafeSendable(q)
                parallelChunks(h, minChunk: 4) { rows in
                    for y in rows {
                        for x in 0..<w {
                            let tv = clampf(bilinear(tb, sw, sh, (Float(x) + 0.5) / ks - 0.5, (Float(y) + 0.5) / ks - 0.5), 0.1, 1)
                            var o = qs.value[y * w + x]
                            for c in 0..<3 {
                                let i = o[c]
                                let j = (i - air[c]) / tv + air[c]
                                o[c] = amount >= 0 ? i + (j - i) * amount : i + (air[c] - i) * (-amount) * 0.5 * (1 - tv * 0.5)
                            }
                            qs.value[y * w + x] = o
                        }
                    }
                }
            }
        }
    }

    static func detail(_ px: inout [SIMD4<Float>], _ w: Int, _ h: Int, _ p: CameraRaw, _ ps: Float) {
        // Work in Y + chroma (BT.709 luma, B−Y, R−Y).
        var y = px.map { luma(SIMD3($0.x, $0.y, $0.z)) }
        var cb = zip(px, y).map { $0.z - $1 }
        var cr = zip(px, y).map { $0.x - $1 }
        if p.noiseLuminance > 0 {
            let n = p.noiseLuminance / 100
            let r = Int(Float.maximum(((1 + 3 * n) * ps).rounded(), 1))
            let e = n * 0.06
            let smooth = guided(y, y, w, h, r, e * e + 1e-6)
            let keep = p.noiseLuminanceDetail / 100 * 0.5
            for i in 0..<(w * h) { y[i] = smooth[i] + (y[i] - smooth[i]) * keep }
        }
        if p.noiseColor > 0 {
            let sigma = Float.maximum(p.noiseColor / 100 * 6 * ps, 0.3)
            let bcb = gauss(cb, w, h, sigma), bcr = gauss(cr, w, h, sigma)
            let keep = p.noiseColorDetail / 100 * 0.3
            for i in 0..<(w * h) {
                cb[i] = bcb[i] + (cb[i] - bcb[i]) * keep
                cr[i] = bcr[i] + (cr[i] - bcr[i]) * keep
            }
        }
        if p.sharpenAmount > 0 {
            let sigma = Float.maximum(clampf(p.sharpenRadius, 0.5, 3) * ps, 0.3)
            let blur = gauss(y, w, h, sigma)
            // Masking: an edge mask from the gradient of a smoothed luminance.
            var mask: [Float]?
            if p.sharpenMasking > 0 {
                let s = gauss(y, w, h, 1 * Float.maximum(ps, 0.5))
                let t = p.sharpenMasking / 100 * 0.08
                mask = (0..<(w * h)).map { i in
                    let (x, yy) = (i % w, i / w)
                    let gx = s[yy * w + min(x + 1, w - 1)] - s[yy * w + max(x - 1, 0)]
                    let gy = s[min(yy + 1, h - 1) * w + x] - s[max(yy - 1, 0) * w + x]
                    return smoothstep(t * 0.5, t + 1e-4, hypotf(gx, gy))
                }
            }
            let amt = p.sharpenAmount / 100 * 1.2
            let det = p.sharpenDetail / 100
            for i in 0..<(w * h) {
                // Low Detail damps large (halo-producing) differences.
                let limit = 0.03 + det * 0.3
                let hp = clampf(y[i] - blur[i], -limit, limit) * (0.5 + 0.5 * det)
                let m = mask?[i] ?? 1
                y[i] += amt * hp * m
            }
        }
        for i in 0..<(w * h) {
            let (l, b, r) = (y[i], cb[i], cr[i])
            let (rr, bb) = (r + l, b + l)
            let g = (l - 0.2126 * rr - 0.0722 * bb) / 0.7152
            px[i].x = rr; px[i].y = g; px[i].z = bb
        }
    }
}

extension CameraRaw {
    /// Whether any of stages 4–7 is active.
    var needsColor: Bool { vibrance != 0 || saturation != 0 || !curvesNeutral || !hslNeutral || !gradeNeutral }
}
