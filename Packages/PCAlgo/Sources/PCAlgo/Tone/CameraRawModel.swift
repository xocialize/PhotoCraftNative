// Camera Raw's per-pixel sliders as Photoshop's Camera Raw Filter draws them (AB-T-0241, AB-D-0139): white balance,
// Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Saturation, Vibrance, the parametric curve, the Color
// Mixer, Calibration and Color Grading. Each slider stop is one `Stage`, a model of ours whose parameters were fitted
// to Photoshop's behaviour: on linear ProPhoto RGB, a 3×3 matrix, a grey curve per channel, a chroma scale, a hue map (hue shift and
// saturation and value scales at 24 hues, the DNG HueSatMap's form), a tone stage (one grey curve, applied through the DNG SDK's
// hue-preserving RGB tone, per channel and as a luminance gain, mixed) and a tint keyed by lightness, each optional.
// The parameters (CameraRawModel.json) are fitted values and 1-D curves, not color tables (AB-D-0130). The fitting
// reference was Compositor's Photoshop-measured Camera Raw tables, which no longer ship; the fit and its receipts are
// AB-T-0241's.
//
// A slider between two fitted stops blends the two stops' results, as Compositor blended its tables; Temperature and
// Tint blend four stops of a grid of both; Contrast, Highlights and Shadows read the picture's brightness (each its
// own measure, `CameraRawStatistics`) and blend four stops of a grid of brightness and value. Every stage takes
// sRGB-encoded color to sRGB-encoded color, clipped to the sRGB gamut, as the fit was made.
//
// The slider logic (stop grids, Balance as a share of saturation, the order the stages compose in) follows
// Compositor's CameraRawTables.swift (MIT, © 2026 Wonder Assembly LLC).

import Foundation
import PCFoundation
import simd

/// What Camera Raw's adaptive sliders read from the picture, as sRGB-encoded levels 0…1: the mean of each pixel's
/// brightest channel (Contrast), the log-average of the brightest channel (Highlights) and the mean luminance
/// (Shadows), each averaged in linear light, by coverage.
public struct CameraRawStatistics: Codable, Sendable, Hashable {
    public var brightest: Float
    public var logBrightest: Float
    public var luminance: Float

    public init(brightest: Float = 0.5, logBrightest: Float = 0.5, luminance: Float = 0.5) {
        self.brightest = brightest; self.logBrightest = logBrightest; self.luminance = luminance
    }

    /// Measures straight RGBA pixels encoded with `gamma` (0 for the sRGB curve).
    public static func measure(_ px: [SIMD4<Float>], encodingGamma gamma: Float = 0) -> Self {
        let enc = CameraRawKit.Encoding.of(gamma)
        var brightest = 0.0, luminance = 0.0, logBrightest = 0.0, weight = 0.0
        for q in px {
            let a = Double(clampf(q.w, 0, 1))
            if a <= 0 { continue }
            let r = Double(clampf(enc.decode(q.x), 0, 1)), g = Double(clampf(enc.decode(q.y), 0, 1)), b = Double(clampf(enc.decode(q.z), 0, 1))
            let top = max(r, g, b)
            brightest += a * top
            luminance += a * (0.2126 * r + 0.7152 * g + 0.0722 * b)
            logBrightest += a * log(top + 3e-4)
            weight += a
        }
        guard weight > 0 else { return Self() }
        let s = { (v: Double) in Float(CameraRawKit.Model.encode(v)) }
        return Self(brightest: s(brightest / weight), logBrightest: s(exp(logBrightest / weight) - 3e-4), luminance: s(luminance / weight))
    }
}

extension CameraRawKit {
    enum Model {
        // MARK: Stage

        /// One fitted slider stop: sRGB-encoded color in, sRGB-encoded color out.
        struct Stage: Sendable {
            var matrix: simd_float3x3?
            /// A grey curve for each channel (white balance), sampled as `Tone.curve` is.
            var curves: [[Float]]?
            /// Chroma about the ProPhoto luminance, scaled by this (Saturation).
            var chroma: Float?
            var hue: Hue?
            var tone: Tone?
            var tint: Tint?

            struct Hue: Sendable {
                /// Per node: hue shift (turns), log saturation scale, log value scale.
                var nodes: [SIMD3<Float>]
                /// The weight of the node values by saturation, at `Model.hueSaturations`.
                var weights: [Float]
                /// The hue map works on ProPhoto raised to 1/gamma.
                var gamma: Float
            }

            struct Tone: Sendable {
                /// Shares of the hue-preserving tone, the per-channel curve and the luminance gain.
                var mix: SIMD3<Float>
                /// The luminance gain's lightness: luminance and the brightest channel, this much of the latter.
                var brightestShare: Float
                /// The grey curve, sRGB-encoded in to sRGB-encoded out, sampled at `curveSamples` points.
                var curve: [Float]
                /// The luminance gain's saturation exponent by encoded lightness, at `shapeSamples` points.
                var shape: [Float]
            }

            struct Tint: Sendable {
                /// The offset of each channel of ProPhoto^(1/1.8) by its lightness, at `tintSamples` points.
                var offsets: [SIMD3<Float>]
            }

            func callAsFunction(_ srgb: SIMD3<Float>) -> SIMD3<Float> {
                var x = Model.toProPhoto(srgb)
                if let m = matrix { x = simd_max(m * x, .zero) }
                if let c = curves { x = SIMD3(Tone.curve(c[0], x.x), Tone.curve(c[1], x.y), Tone.curve(c[2], x.z)) }
                if let k = chroma {
                    let y = simd_dot(x, Model.proPhotoLuminance)
                    x = simd_max(SIMD3(repeating: y) + (x - SIMD3(repeating: y)) * k, .zero)
                }
                if let h = hue { x = h.apply(x) }
                if let t = tone { x = t.apply(x) }
                if let t = tint { x = t.apply(x) }
                return Model.fromProPhoto(x)
            }
        }

        // MARK: Library

        /// Every slider's stops, read from CameraRawModel.json once.
        struct Library: Sendable {
            /// Linear sRGB to linear ProPhoto (D50 by Bradford, rows summing to one) and back, as the fit used them.
            var toProPhoto: simd_float3x3
            var fromProPhoto: simd_float3x3
            var exposure: [Stage?]                   // −5…5 by 0.5
            var whiteBalance: [[Stage?]]             // Temperature rows × Tint columns, −100…100 by 25
            var adaptive: [String: [[Stage?]]]       // contrast / highlights / shadows: brightness rows × `adaptiveValues`
            var quarter: [String: [Stage?]]          // whites, blacks, saturation, vibrance: −100…100 by 25
            var mixer: [[[Stage?]]]                  // luminance, saturation, hue × 8 colors × −100…100 by 50
            var calibration: [[Stage?]]              // red hue, red saturation, green hue, green saturation, blue hue, blue saturation
            var parametric: [[Stage?]]               // shadows, darks, lights, highlights
            var gradingLuminance: [[Stage?]]         // shadows, midtones, highlights, global
            var wheels: [[[[Stage?]]]]               // shadows, highlights, midtones, global × blending × hue × saturation
        }

        static let brightnesses: [Float] = [53, 80, 104, 130, 160, 190, 224].map { $0 / 255 }
        static let adaptiveValues: [Float] = [-100, -50, -25, 0, 25, 50, 100]
        static let hueSaturations: [Float] = [0, 0.25, 0.5, 0.75, 1]
        static let curveSamples = 1024, shapeSamples = 256, tintSamples = 256
        static let proPhotoLuminance = SIMD3<Float>(0.2880402, 0.7118741, 0.0000857)

        /// The fitted library, or nil when the resource is missing or malformed (the sliders then do nothing).
        static let library: Library? = load()
        static let matrices = (toProPhoto: library?.toProPhoto ?? matrix_identity_float3x3,
                               fromProPhoto: library?.fromProPhoto ?? matrix_identity_float3x3)

        // MARK: Color

        @inline(__always) static func decode(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4) }
        @inline(__always) static func encode(_ v: Float) -> Float { v <= 0.0031308 ? v * 12.92 : 1.055 * powf(Float.maximum(v, 0), 1 / 2.4) - 0.055 }
        static func encode(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(max(v, 0), 1 / 2.4) - 0.055 }

        @inline(__always) static func toProPhoto(_ srgb: SIMD3<Float>) -> SIMD3<Float> {
            matrices.toProPhoto * SIMD3(decode(srgb.x), decode(srgb.y), decode(srgb.z))
        }

        @inline(__always) static func fromProPhoto(_ pp: SIMD3<Float>) -> SIMD3<Float> {
            let lin = simd_clamp(matrices.fromProPhoto * pp, .zero, SIMD3(repeating: 1))
            return SIMD3(encode(lin.x), encode(lin.y), encode(lin.z))
        }

        /// Linear interpolation of `table`, sampled evenly over 0…1, at `u` (clamped).
        @inline(__always) static func sample(_ table: [Float], _ u: Float) -> Float {
            let x = clampf(u, 0, 1) * Float(table.count - 1)
            let i = min(Int(x), table.count - 2)
            let t = x - Float(i)
            return table[i] + (table[i + 1] - table[i]) * t
        }

        @inline(__always) static func sample(_ table: [SIMD3<Float>], _ u: Float) -> SIMD3<Float> {
            let x = clampf(u, 0, 1) * Float(table.count - 1)
            let i = min(Int(x), table.count - 2)
            let t = x - Float(i)
            return table[i] + (table[i + 1] - table[i]) * t
        }

        /// HSV with hue in turns (0…1).
        @inline(__always) static func hsv(_ c: SIMD3<Float>) -> SIMD3<Float> {
            let mx = c.max(), mn = c.min(), d = mx - mn
            var h: Float = 0
            if d > 1e-12 {
                if mx == c.x { h = euclidMod((c.y - c.z) / d, 6) }
                else if mx == c.y { h = (c.z - c.x) / d + 2 }
                else { h = (c.x - c.y) / d + 4 }
            }
            return SIMD3(h / 6, mx > 1e-12 ? d / mx : 0, mx)
        }

        @inline(__always) static func rgb(hue h: Float, saturation s: Float, value v: Float) -> SIMD3<Float> {
            let h6 = euclidMod(h, 1) * 6
            let fl = h6.rounded(.down)
            let i = Int(fl) % 6, f = h6 - fl
            let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
            switch i {
            case 0: return SIMD3(v, t, p)
            case 1: return SIMD3(q, v, p)
            case 2: return SIMD3(p, v, t)
            case 3: return SIMD3(p, q, v)
            case 4: return SIMD3(t, p, v)
            default: return SIMD3(v, p, q)
            }
        }
    }
}

// MARK: The blocks

extension CameraRawKit.Model.Stage.Hue {
    func apply(_ x: SIMD3<Float>) -> SIMD3<Float> {
        typealias M = CameraRawKit.Model
        let e = SIMD3(powf(x.x, 1 / gamma), powf(x.y, 1 / gamma), powf(x.z, 1 / gamma))
        let c = M.hsv(e)
        let n = Float(nodes.count)
        let t = c.x * n, fl = t.rounded(.down)
        let i0 = Int(fl) % nodes.count, i1 = (i0 + 1) % nodes.count, ft = t - fl
        let node = nodes[i0] * (1 - ft) + nodes[i1] * ft
        // The weight of the node by saturation (linear between the knots).
        let sx = clampf(c.y, 0, 1) * Float(M.hueSaturations.count - 1)
        let si = min(Int(sx), M.hueSaturations.count - 2)
        let w = weights[si] + (weights[si + 1] - weights[si]) * (sx - Float(si))
        let out = M.rgb(hue: c.x + node.x * w, saturation: clampf(c.y * expf(node.y * w), 0, 1), value: c.z * expf(node.z * w))
        let o = simd_max(out, .zero)
        return SIMD3(powf(o.x, gamma), powf(o.y, gamma), powf(o.z, gamma))
    }
}

extension CameraRawKit.Model.Stage.Tone {
    /// The grey curve on linear light: values past 1 keep their excess.
    @inline(__always) func f(_ v: Float) -> Float { Self.curve(curve, v) }

    /// A curve sampled sRGB-encoded in to sRGB-encoded out, on linear light: values past 1 keep their excess.
    @inline(__always) static func curve(_ samples: [Float], _ v: Float) -> Float {
        typealias M = CameraRawKit.Model
        let y = M.sample(samples, M.encode(clampf(v, 0, 1)))
        return M.decode(Float.maximum(y, 0)) + Float.maximum(v - 1, 0)
    }

    func apply(_ x: SIMD3<Float>) -> SIMD3<Float> {
        typealias M = CameraRawKit.Model
        var out = SIMD3<Float>.zero
        if mix.x > 0 { out += mix.x * Self.rgbTone(x, f) }
        if mix.y > 0 { out += mix.y * SIMD3(f(x.x), f(x.y), f(x.z)) }
        if mix.z > 0 {
            let l = Float.maximum((1 - brightestShare) * simd_dot(x, M.proPhotoLuminance) + brightestShare * x.max(), 1e-7)
            let b = M.sample(shape, M.encode(clampf(l, 0, 1)))
            let gain = log2f(Float.maximum(f(l) / l, 1e-9))
            var o = SIMD3<Float>()
            for ch in 0..<3 where x[ch] > 0 { o[ch] = x[ch] * exp2f(gain + b * log2f(Float.maximum(x[ch], 1e-7) / l)) }
            out += mix.z * o
        }
        return out
    }

    /// The DNG SDK's RefBaselineRGBTone with `f`: sorted channels, the largest and smallest through the curve, the
    /// middle one at its relative place between them (ties give the same values in either order).
    @inline(__always) static func rgbTone(_ x: SIMD3<Float>, _ f: (Float) -> Float) -> SIMD3<Float> {
        var order = (0, 1, 2)
        func swap(_ a: inout Int, _ b: inout Int) { let t = a; a = b; b = t }
        if x[order.1] < x[order.0] { swap(&order.0, &order.1) }
        if x[order.2] < x[order.1] { swap(&order.1, &order.2) }
        if x[order.1] < x[order.0] { swap(&order.0, &order.1) }
        let lo = x[order.0], mid = x[order.1], hi = x[order.2]
        let flo = f(lo), fhi = f(hi), span = hi - lo
        let t: Float = span > 1e-12 ? (mid - lo) / span : 0
        var o = SIMD3<Float>()
        o[order.0] = flo; o[order.2] = fhi; o[order.1] = flo + (fhi - flo) * t
        return o
    }
}

extension CameraRawKit.Model.Stage.Tint {
    func apply(_ x: SIMD3<Float>) -> SIMD3<Float> {
        typealias M = CameraRawKit.Model
        let p = simd_max(x, .zero)
        let e = SIMD3(powf(p.x, 1 / 1.8), powf(p.y, 1 / 1.8), powf(p.z, 1 / 1.8))
        let l = clampf(powf(Float.maximum(simd_dot(p, M.proPhotoLuminance), 0), 1 / 1.8), 0, 1)
        let o = simd_max(e + M.sample(offsets, l), .zero)
        return SIMD3(powf(o.x, 1.8), powf(o.y, 1.8), powf(o.z, 1.8))
    }
}
