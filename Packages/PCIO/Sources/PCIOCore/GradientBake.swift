// Photoshop gradient appearance → dense linear stops.
// Port of photocraft-io (crates/io/src/gradient_bake.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.
//
// Photoshop interpolates gradient colours with a Smoothness setting (0–100 %) and, since the 2023
// releases, an interpolation method (Smooth / Perceptual / Linear / Classic). The compositors
// interpolate stops linearly in sRGB, so on import Photoshop's curve is sampled into dense stops.
// The model was fitted (by photocraft, clean-room, from pixels) to Photoshop's own composites:
// Smoothness blends linear interpolation with a Catmull-Rom spline through the stop colours (end
// tangents at half the chord slope); Perceptual interpolates in Oklab, Linear in linear light,
// Classic in sRGB. Stop midpoints remap each segment piecewise-linearly.
//
// Smooth (Photoshop's default since 2024) was fitted here on Photoshop 27.11's own composite of a
// three-stop Gradient Map (ps-corpus `adj-gradientMap.psd`): solving each output colour for the
// stop weights shows a linear scheme in Oklab whose far-stop weights are negative only in the half
// segment next to an interior stop. It is a Catmull-Rom spline through the stops *and* each
// segment's midpoint (the average of its two stop colours, at the stop midpoint's location), with
// the end tangents at 0.7 of the end chords, each channel clamped to its segment's range: every
// pixel within 1 level of Photoshop's (mean 0.09), where straight segments with an easing table
// were up to 8 levels off around the middle stop. For two stops it is the easing photocraft
// measured (within 0.005).

import Foundation
import simd
import PCDocument
import PCFoundation

public enum GradientBake {
    public enum Method: Sendable, Equatable {
        case classic, perceptual, linear, smooth

        public init(code: String?) {
            switch code {
            case "Perc": self = .perceptual
            case "Lnr ": self = .linear
            case "Smoo": self = .smooth
            default: self = .classic
            }
        }
    }

    static func lin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }

    static func enc(_ c: Float) -> Float {
        let c = min(max(c, 0), 1)
        return c <= 0.003_130_8 ? 12.92 * c : 1.055 * powf(c, 1 / 2.4) - 0.055
    }

    static func toOklab(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let (r, g, b) = (lin(rgb.x), lin(rgb.y), lin(rgb.z))
        let l = cbrtf(0.412_221_46 * r + 0.536_332_55 * g + 0.051_445_995 * b)
        let m = cbrtf(0.211_903_5 * r + 0.680_699_5 * g + 0.107_396_96 * b)
        let s = cbrtf(0.088_302_46 * r + 0.281_718_85 * g + 0.629_978_7 * b)
        return SIMD3(0.210_454_26 * l + 0.793_617_8 * m - 0.004_072_047 * s,
                     1.977_998_5 * l - 2.428_592_2 * m + 0.450_593_7 * s,
                     0.025_904_037 * l + 0.782_771_77 * m - 0.808_675_77 * s)
    }

    static func fromOklab(_ p: SIMD3<Float>) -> SIMD3<Float> {
        func cube(_ v: Float) -> Float { v * v * v }
        let l = cube(p.x + 0.396_337_78 * p.y + 0.215_803_76 * p.z)
        let m = cube(p.x - 0.105_561_346 * p.y - 0.063_854_17 * p.z)
        let s = cube(p.x - 0.089_484_18 * p.y - 1.291_485_5 * p.z)
        return SIMD3(enc(4.076_741_7 * l - 3.307_711_6 * m + 0.230_969_94 * s),
                     enc(-1.268_438 * l + 2.609_757_4 * m - 0.341_319_38 * s),
                     enc(-0.004_196_086_3 * l - 0.703_418_6 * m + 1.707_614_7 * s))
    }

    static func intoSpace(_ m: Method, _ rgb: SIMD3<Float>) -> SIMD3<Float> {
        switch m {
        case .classic: rgb
        case .linear: SIMD3(lin(rgb.x), lin(rgb.y), lin(rgb.z))
        case .perceptual, .smooth: toOklab(rgb)
        }
    }

    static func outOfSpace(_ m: Method, _ p: SIMD3<Float>) -> SIMD3<Float> {
        switch m {
        case .classic: simd_clamp(p, SIMD3(repeating: 0), SIMD3(repeating: 1))
        case .linear: SIMD3(enc(p.x), enc(p.y), enc(p.z))
        case .perceptual, .smooth: fromOklab(p)
        }
    }

    /// Smooth's end tangents, as a fraction of the end chords' slope (fitted: 0.70 minimises the
    /// error on Photoshop's composite; 0.66 and 0.74 double it).
    static let smoothEndTangent: Float = 0.7

    /// Smooth's spline knots for sorted stops in Oklab: each stop, and between two stops the
    /// average of their colours at the segment's midpoint location. `segment` is the stop
    /// segment each knot interval belongs to.
    static func smoothKnots(_ stops: [(Float, SIMD3<Float>)], _ mids: [Float]) -> [(t: Float, p: SIMD3<Float>, segment: Int)] {
        var k: [(t: Float, p: SIMD3<Float>, segment: Int)] = []
        for i in stops.indices {
            k.append((stops[i].0, stops[i].1, min(i, stops.count - 2)))
            guard i + 1 < stops.count else { break }
            let (t0, t1) = (stops[i].0, stops[i + 1].0)
            guard t1 - t0 > 1e-6 else { continue }
            let mid = min(max(i < mids.count ? mids[i] : 0.5, 0.05), 0.95)
            k.append((t0 + (t1 - t0) * mid, (stops[i].1 + stops[i + 1].1) * 0.5, i))
        }
        return k
    }

    /// Smooth's colour at `t` (Oklab) on the knots of `smoothKnots`, clamped to the stop segment.
    static func smoothEval(_ stops: [(Float, SIMD3<Float>)], _ k: [(t: Float, p: SIMD3<Float>, segment: Int)], _ t: Float) -> SIMD3<Float> {
        let n = k.count
        if t <= k[0].t { return k[0].p }
        if t >= k[n - 1].t { return k[n - 1].p }
        var i = 0
        for j in 0 ..< n - 1 where t >= k[j].t && t <= k[j + 1].t && k[j + 1].t - k[j].t > 1e-6 { i = j; break }
        let h = max(k[i + 1].t - k[i].t, 1e-6)
        let u = (t - k[i].t) / h
        func tangent(_ j: Int) -> SIMD3<Float> {
            if j == 0 || j == n - 1 {
                let (a, b) = j == 0 ? (0, 1) : (n - 2, n - 1)
                return (k[b].p - k[a].p) / max(k[b].t - k[a].t, 1e-6) * smoothEndTangent
            }
            return (k[j + 1].p - k[j - 1].p) / max(k[j + 1].t - k[j - 1].t, 1e-6)
        }
        let (u2, u3) = (u * u, u * u * u)
        let (h00, h10, h01, h11) = (2 * u3 - 3 * u2 + 1, u3 - 2 * u2 + u, -2 * u3 + 3 * u2, u3 - u2)
        let v = h00 * k[i].p + h10 * h * tangent(i) + h01 * k[i + 1].p + h11 * h * tangent(i + 1)
        // The segment's stop colours bound each channel (Photoshop holds an overshooting channel
        // at the stop's value).
        let s = min(k[i].segment, stops.count - 2)
        let (a, b) = (stops[s].1, stops[s + 1].1)
        return simd_clamp(v, simd_min(a, b), simd_max(a, b))
    }

    /// Colour at `t` for sorted stops (positions in 0...1) in `m`'s space.
    static func eval(_ stops: [(Float, SIMD3<Float>)], _ mids: [Float], _ smooth: Float, _ t: Float, _ m: Method) -> SIMD3<Float> {
        let n = stops.count
        if t <= stops[0].0 { return stops[0].1 }
        if t >= stops[n - 1].0 { return stops[n - 1].1 }
        var i = 0
        for k in 0 ..< n - 1 where t >= stops[k].0 && t <= stops[k + 1].0 { i = k; break }
        let (t0, t1) = (stops[i].0, stops[i + 1].0)
        let h = max(t1 - t0, 1e-6)
        var u = (t - t0) / h
        // Midpoint: where the segment reaches 50 % (default 0.5 = identity).
        let mid = min(max(i < mids.count ? mids[i] : 0.5, 0.05), 0.95)
        u = u <= mid ? 0.5 * u / mid : 0.5 + 0.5 * (u - mid) / (1 - mid)
        let (p0, p1) = (stops[i].1, stops[i + 1].1)
        // Catmull-Rom tangents per unit t; the ends use half the chord slope.
        func tangent(_ k: Int) -> SIMD3<Float> {
            let (a, b) = k == 0 ? (0, 1) : (k == n - 1 ? (n - 2, n - 1) : (k - 1, k + 1))
            let d = max(stops[b].0 - stops[a].0, 1e-6)
            let half: Float = k == 0 || k == n - 1 ? 0.5 : 1
            return (stops[b].1 - stops[a].1) / d * half
        }
        let (m0, m1) = (tangent(i), tangent(i + 1))
        let (u2, u3) = (u * u, u * u * u)
        let (h00, h10, h01, h11) = (2 * u3 - 3 * u2 + 1, u3 - 2 * u2 + u, -2 * u3 + 3 * u2, u3 - u2)
        var out = SIMD3<Float>()
        for c in 0 ..< 3 {
            let linear = p0[c] + (p1[c] - p0[c]) * u
            let spline = h00 * p0[c] + h10 * h * m0[c] + h01 * p1[c] + h11 * h * m1[c]
            let value = linear + (spline - linear) * smooth
            // Catmull-Rom tangents can overshoot neighbouring stops: clamp to this segment.
            let (lo, hi) = (min(p0[c], p1[c]), max(p0[c], p1[c]))
            out[c] = lo.isFinite && hi.isFinite ? min(max(value, lo), hi) : value
        }
        return out
    }

    /// Dense linear stops reproducing Photoshop's interpolation. Returns the input unchanged when
    /// it already interpolates linearly in sRGB.
    public static func bake(_ stops: [ColorStop], _ midpoints: [Float], _ smoothness: Float, _ method: Method) -> [ColorStop] {
        let plainMids = midpoints.allSatisfy { abs($0 - 0.5) < 1e-3 }
        // Classic interpolates in the stops' own model: Lab stops (Lab documents) blend in L*a*b*.
        let lab = method == .classic && stops.allSatisfy { $0.color.mode == .lab }
        if stops.count < 2 || (smoothness <= 0 && method == .classic && plainMids && !lab) { return stops }
        let s = stops.enumerated().sorted { a, b in
            a.element.location != b.element.location ? a.element.location < b.element.location : a.offset < b.offset
        }.map(\.element)
        func alpha(_ t: Float) -> Float {
            // Stop colours carry no alpha in Photoshop (opacity has its own stops); keep the nearest.
            var best: ColorStop?
            for x in s where best == nil || abs(x.location - t) < abs(best!.location - t) { best = x }
            return best?.color.alpha ?? 1
        }
        let pts: [(Float, SIMD3<Float>)] = s.map { st in
            (st.location, lab ? SIMD3(st.color.c.x, st.color.c.y, st.color.c.z) : intoSpace(method, st.color.rgb))
        }
        let n = 96
        let knots = method == .smooth ? smoothKnots(pts, midpoints) : []
        // Smooth's knots are sampled exactly too (its clamped channels turn there).
        let ts = (Set((0 ... n).map { Float($0) / Float(n) }).union(knots.map { min(max($0.t, 0), 1) })).sorted()
        var out: [ColorStop] = []
        for t in ts {
            let v = method == .smooth ? smoothEval(pts, knots, t) : eval(pts, midpoints, min(max(smoothness, 0), 1), t, method)
            let stop: ColorStop
            if lab {
                stop = ColorStop(t, PCColor(mode: .lab, c: SIMD4(min(max(v.x, 0), 1), min(max(v.y, 0), 1), min(max(v.z, 0), 1), 0), alpha: alpha(t)))
            } else {
                let rgb = outOfSpace(method, v)
                stop = ColorStop(t, .rgb(rgb.x, rgb.y, rgb.z, alpha(t)))
            }
            if let last = out.last, abs(last.location - stop.location) < 1e-6 { continue }
            out.append(stop)
        }
        return out
    }
}
