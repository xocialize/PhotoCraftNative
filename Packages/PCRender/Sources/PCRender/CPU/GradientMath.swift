// Port of photocraft-compose (crates/compose/src/effects.rs, fill_layout.rs, gradient_fill.rs) and photocraft-gpu (compose.wgsl), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Gradient geometry shared by gradient fills, gradient overlays, gradient strokes and gradient glows:
// the parameter `t` of a pixel (`effects::gradient_t`), Photoshop's whole-pixel end points
// (`fill_layout::gradient_layout`), and the colour ramps (effect gradients: colour + opacity stops;
// fill gradients: plus midpoints and dither).

import Foundation
import PCDocument
import PCFoundation

public enum GradientMath {
    /// (chord, ellipse-norm length) a 100 % gradient at `angle` spans in a `w × h` frame.
    public static func units(_ angle: Float, _ w: Float, _ h: Float) -> (Float, Float) {
        let (s, c) = (sinf(radians(angle)), cosf(radians(angle)))
        let len = max(((c * w) * (c * w) + (s * h) * (s * h)).squareRoot(), 1)
        let chord = max(min(w / max(abs(c), 1e-6), h / max(abs(s), 1e-6)), 1)
        return (chord, len)
    }

    /// Gradient parameter `t` (0…1) for pixel centre `(x, y)` in `bounds`.
    public static func t(_ style: GradientStyle, angle: Float, scale: Float, reverse: Bool, offset: SIMD2<Float>,
                         bounds: PixelRect, x: Float, y: Float) -> Float {
        let w = Float(max(bounds.width, 1)), h = Float(max(bounds.height, 1))
        let cx = Float(bounds.x0) + w / 2 + offset.x * w
        let cy = Float(bounds.y0) + h / 2 + offset.y * h
        let (s, c) = (sinf(radians(angle)), cosf(radians(angle)))
        let (dx, dy) = (x - cx, y - cy)
        let along = dx * c - dy * s
        let across = dx * s + dy * c
        let (chord0, len0) = units(angle, w, h)
        let (chord, len) = (chord0 * max(scale, 1e-3), len0 * max(scale, 1e-3))
        let corner = 0.5 * (c - s)
        var t: Float
        switch style {
        case .linear: t = (along - corner) / chord + 0.5
        case .reflected: t = abs((along - corner) / (chord / 2))
        case .radial: t = (dx * dx + dy * dy).squareRoot() / (len / 2)
        case .diamond: t = (abs(along) + abs(across)) / (len / 2)
        case .angle: t = remEuclid((radians(angle) - atan2f(-dy, dx)) / (2 * piF), 1)
        }
        t = min(max(t, 0), 1)
        return reverse ? 1 - t : t
    }

    /// Effective (angle, scale, centre offset) with Linear / Reflected end points snapped to whole
    /// pixels (`fill_layout::gradient_layout`).
    public static func layout(_ style: GradientStyle, angle: Float, scale: Float, offset: SIMD2<Float>, frame: PixelRect) -> (Float, Float, SIMD2<Float>) {
        let unchanged = (angle, scale, offset)
        if !(style == .linear || style == .reflected) || !angle.isFinite || !scale.isFinite || !offset.x.isFinite || !offset.y.isFinite {
            return unchanged
        }
        let w = Double(max(frame.width, 1)), h = Double(max(frame.height, 1))
        let cx = Double(frame.x0) + w / 2 + Double(offset.x) * w
        let cy = Double(frame.y0) + h / 2 + Double(offset.y) * h
        func chordOf(_ a: Double) -> Double { max(min(w / max(abs(cos(a)), 1e-6), h / max(abs(sin(a)), 1e-6)), 1) }
        let a = Double(angle) * (.pi / 180)
        let scale64 = Double(max(scale, 1e-3))
        let half = chordOf(a) * scale64 / 2
        let (dx, dy) = (cos(a) * half, -sin(a) * half)
        func snap(_ v: Double) -> Double { (v + 1e-4).rounded(.down) }
        let end = (snap(cx + dx), snap(cy + dy))
        let start: (Double, Double), mid: (Double, Double)
        if style == .reflected {
            start = (cx, cy); mid = (cx, cy)
        } else {
            let s0 = (snap(cx - dx), snap(cy - dy))
            start = s0; mid = ((s0.0 + end.0) / 2, (s0.1 + end.1) / 2)
        }
        let v = (end.0 - start.0, end.1 - start.1)
        let len = hypot(v.0, v.1)
        if len < 0.5 { return unchanged }
        let a2 = atan2(-v.1, v.0)
        let span = style == .reflected ? 2 * len : len
        let scale2 = span / chordOf(a2)
        let shift = SIMD2(Float((mid.0 - cx) / w), Float((mid.1 - cy) / h))
        return (Float(a2 * 180 / .pi), Float(scale2), offset + shift)
    }

    /// Colour + opacity stops sampled at `t` (`effects::sample_gradient`), colours as display RGB.
    public struct EffectRamp: Sendable {
        let color: [(Float, SIMD3<Float>)]
        let opacity: [(Float, SIMD3<Float>)]

        public init(_ g: StyleGradient) {
            color = g.stops.map { ($0.location, $0.color.rgb) }
            opacity = g.opacityStops.map { ($0.location, SIMD3(repeating: $0.opacity)) }
        }

        public func sample(_ t: Float) -> SIMD4<Float> {
            let c = GradientMath.sampleStops(color, t)
            let a = opacity.isEmpty ? 1 : GradientMath.sampleStops(opacity, t).x
            return SIMD4(c, a)
        }

        /// The stops packed for the GPU: (location, r, g, b) colour then (location, a) opacity.
        var packed: (color: [SIMD4<Float>], opacity: [SIMD4<Float>]) {
            (color.map { SIMD4($0.0, $0.1.x, $0.1.y, $0.1.z) }, opacity.map { SIMD4($0.0, $0.1.x, 0, 0) })
        }
    }

    static func sampleStops(_ stops: [(Float, SIMD3<Float>)], _ t: Float) -> SIMD3<Float> {
        if stops.isEmpty { return SIMD3(repeating: t) }
        if stops.count == 1 { return stops[0].1 }
        if t <= stops[0].0 { return stops[0].1 }
        for i in 0..<(stops.count - 1) {
            let (a, b) = (stops[i], stops[i + 1])
            if t <= b.0 {
                let k = b.0 > a.0 ? (t - a.0) / (b.0 - a.0) : 0
                return a.1 + (b.1 - a.1) * k
            }
        }
        return stops[stops.count - 1].1
    }

    /// A gradient fill's ramp: sorted colour stops with midpoints, sorted opacity stops.
    public struct FillRamp: Sendable {
        let color: [(Float, SIMD4<Float>)]
        let mids: [Float]
        let opacity: [(Float, Float)]

        public init(_ f: GradientFill) {
            color = f.stops.map { ($0.location, SIMD4($0.color.rgb, $0.color.alpha)) }.sorted { $0.0 < $1.0 }
            mids = f.midpoints
            opacity = f.opacityStops.map { ($0.location, $0.opacity) }.sorted { $0.0 < $1.0 }
        }

        public func sample(_ t: Float) -> SIMD4<Float> {
            var c = GradientMath.sampleColor(color, mids, t)
            c.w *= GradientMath.sampleOpacity(opacity, t)
            return c
        }

        var packed: (color: [SIMD4<Float>], alpha: [SIMD4<Float>], mids: [Float]) {
            (color.map { SIMD4($0.0, $0.1.x, $0.1.y, $0.1.z) }, color.map { SIMD4($0.0, $0.1.w, 0, 0) }, mids)
        }
    }

    /// Where a segment's relative position lands once its midpoint is `m`.
    public static func midpointRemap(_ u: Float, _ m0: Float) -> Float {
        let m = min(max(m0, 0.05), 0.95)
        if abs(m - 0.5) < 1e-6 { return u }
        return u <= m ? 0.5 * u / m : 0.5 + 0.5 * (u - m) / (1 - m)
    }

    static func sampleColor(_ stops: [(Float, SIMD4<Float>)], _ mids: [Float], _ t: Float) -> SIMD4<Float> {
        guard let first = stops.first, let last = stops.last else { return .zero }
        if t <= first.0 { return first.1 }
        for i in 0..<(stops.count - 1) {
            let (a, b) = (stops[i], stops[i + 1])
            if t <= b.0 {
                let u = b.0 > a.0 ? (t - a.0) / (b.0 - a.0) : 0
                let k = midpointRemap(u, i < mids.count ? mids[i] : 0.5)
                return a.1 + (b.1 - a.1) * k
            }
        }
        return last.1
    }

    static func sampleOpacity(_ stops: [(Float, Float)], _ t: Float) -> Float {
        guard let first = stops.first, let last = stops.last else { return 1 }
        if t <= first.0 { return first.1 }
        for i in 0..<(stops.count - 1) where t <= stops[i + 1].0 {
            let (a, b) = (stops[i], stops[i + 1])
            let u = b.0 > a.0 ? (t - a.0) / (b.0 - a.0) : 0
            return a.1 + (b.1 - a.1) * u
        }
        return last.1
    }

    /// One level of the shared dither noise, then rounded to `quantum` steps when given.
    @inline(__always) static func dither(_ c: SIMD4<Float>, _ x: Int32, _ y: Int32, _ quantum: Float?) -> SIMD4<Float> {
        let n = (ColorConvert.ditherNoise(x: x, y: y) - 0.5) / 255
        var o = c
        for i in 0..<3 {
            var v = min(max(o[i] + n, 0), 1)
            if let q = quantum { v = (v * q + 0.5).rounded(.down) / q }
            o[i] = v
        }
        return o
    }
}

extension GradientStyle {
    /// The shader's style index.
    var index: Float {
        switch self { case .linear: 0; case .radial: 1; case .angle: 2; case .reflected: 3; case .diamond: 4 }
    }
}
