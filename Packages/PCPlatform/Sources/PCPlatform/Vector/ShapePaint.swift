// The colour source of a shape fill or stroke: solid colours and every gradient field (midpoints,
// opacity stops, centre offset, whole-pixel snapping, reverse, dither).
// Port of photocraft-vector's `Paint` (crates/vector/src/lib.rs: `Paint::from_fill`, `at`,
// `gradient_units`, `gradient_layout`, `gradient_t`, `midpoint_remap`, `sample_*`, `dither`) over
// PCDocument's `Fill`. Pure maths — no framework renders Photoshop's gradient geometry. MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation

/// Straight-RGBA colour source (photocraft `Paint`).
public enum ShapePaint: Sendable {
    case none
    case solid(SIMD4<Float>)
    case gradient(stops: [(Float, SIMD4<Float>)], midpoints: [Float], opacityStops: [(Float, Float)], style: GradientStyle,
                  layout: (angle: Float, scale: Float, offset: SIMD2<Float>), reverse: Bool, dither: Bool, frame: SIMD4<Double>)

    /// Paint for a model fill, gradients laid out over `bounds` (`x0, y0, x1, y1`, the shape's
    /// frame) or over `canvas` when the fill is not aligned with the layer. Pattern fills render
    /// transparent here, as in photocraft (they need the document's pattern table).
    public init(_ f: Fill, bounds: SIMD4<Double>, canvas: SIMD4<Double>) {
        func rgba(_ c: PCColor) -> SIMD4<Float> { SIMD4(c.rgb, c.alpha) }
        switch f {
        case .solid(let c): self = .solid(rgba(c))
        case .gradient(let g):
            let frame = g.align ? bounds : canvas
            let stops = g.stops.map { ($0.location, rgba($0.color)) }.sorted { $0.0 < $1.0 }
            let opacity = g.opacityStops.map { ($0.location, $0.opacity) }.sorted { $0.0 < $1.0 }
            self = .gradient(stops: stops, midpoints: g.midpoints, opacityStops: opacity, style: g.style,
                             layout: Self.layout(g.style, g.angle, g.scale, g.offset, frame), reverse: g.reverse, dither: g.dither, frame: frame)
        case .pattern: self = .none
        }
    }

    /// Straight RGBA at pixel centre `(x, y)`.
    public func at(_ x: Double, _ y: Double) -> SIMD4<Float> {
        switch self {
        case .none: return .zero
        case .solid(let c): return c
        case .gradient(let stops, let mids, let opacity, let style, let layout, let reverse, let dither, let frame):
            let t = Self.t(style, layout.angle, layout.scale, reverse, layout.offset, frame, x, y)
            var c = Self.sampleColor(stops, mids, t)
            if !opacity.isEmpty { c.w *= Self.sampleOpacity(opacity, t) }
            if dither {
                let n = (ColorConvert.ditherNoise(x: Int32(x.rounded(.down)), y: Int32(y.rounded(.down))) - 0.5) / 255
                for k in 0..<3 { c[k] = min(max(c[k] + n, 0), 1) }
            }
            return c
        }
    }

    /// `(chord, diagonal)` gradient lengths over a `w × h` frame (photocraft `gradient_units`).
    static func units(_ angle: Double, _ w: Double, _ h: Double) -> (Double, Double) {
        let (s, c) = (sin(angle), cos(angle))
        let len = max(((c * w) * (c * w) + (s * h) * (s * h)).squareRoot(), 1)
        let chord = max(min(w / max(abs(c), 1e-6), h / max(abs(s), 1e-6)), 1)
        return (chord, len)
    }

    /// Effective `(angle, scale, offset)` with Linear/Reflected end points snapped to whole pixels
    /// (photocraft `gradient_layout`).
    static func layout(_ style: GradientStyle, _ angle: Float, _ scale: Float, _ offset: SIMD2<Float>, _ frame: SIMD4<Double>)
        -> (angle: Float, scale: Float, offset: SIMD2<Float>) {
        let unchanged = (angle: angle, scale: scale, offset: offset)
        guard style == .linear || style == .reflected, angle.isFinite, scale.isFinite, offset.x.isFinite, offset.y.isFinite else { return unchanged }
        let w = max(frame.z - frame.x, 1), h = max(frame.w - frame.y, 1)
        let cx = frame.x + w / 2 + Double(offset.x) * w, cy = frame.y + h / 2 + Double(offset.y) * h
        let a = Double(angle) * .pi / 180
        let half = units(a, w, h).0 * Double(max(scale, 1e-3)) / 2
        let (dx, dy) = (cos(a) * half, -sin(a) * half)
        func snap(_ v: Double) -> Double { (v + 1e-4).rounded(.down) }
        let end = (snap(cx + dx), snap(cy + dy))
        let start: (Double, Double), mid: (Double, Double)
        if style == .reflected { start = (cx, cy); mid = (cx, cy) } else {
            start = (snap(cx - dx), snap(cy - dy)); mid = ((start.0 + end.0) / 2, (start.1 + end.1) / 2)
        }
        let v = (end.0 - start.0, end.1 - start.1), len = (v.0 * v.0 + v.1 * v.1).squareRoot()
        if len < 0.5 { return unchanged }
        let a2 = atan2(-v.1, v.0)
        let span = style == .reflected ? 2 * len : len
        let scale2 = span / units(a2, w, h).0
        let shift = SIMD2(Float((mid.0 - cx) / w), Float((mid.1 - cy) / h))
        return (Float(a2 * 180 / .pi), Float(scale2), offset + shift)
    }

    /// Gradient parameter at pixel centre `(x, y)` (photocraft `gradient_t`).
    static func t(_ style: GradientStyle, _ angle: Float, _ scale: Float, _ reverse: Bool, _ offset: SIMD2<Float>, _ frame: SIMD4<Double>,
                  _ x: Double, _ y: Double) -> Float {
        let w = max(frame.z - frame.x, 1), h = max(frame.w - frame.y, 1)
        let cx = frame.x + w / 2 + Double(offset.x) * w, cy = frame.y + h / 2 + Double(offset.y) * h
        let a = Double(angle) * .pi / 180
        let (s, c) = (sin(a), cos(a))
        let (dx, dy) = (x - cx, y - cy)
        let along = dx * c - dy * s, across = dx * s + dy * c
        var (chord, len) = units(a, w, h)
        chord *= Double(max(scale, 1e-3)); len *= Double(max(scale, 1e-3))
        let corner = 0.5 * (c - s)
        var t: Double
        switch style {
        case .linear: t = (along - corner) / chord + 0.5
        case .reflected: t = abs((along - corner) / (chord / 2))
        case .radial: t = (dx * dx + dy * dy).squareRoot() / (len / 2)
        case .diamond: t = (abs(along) + abs(across)) / (len / 2)
        case .angle:
            let r = (a - atan2(-dy, dx)) / (2 * .pi)
            t = r - r.rounded(.down)
        }
        t = min(max(t, 0), 1)
        return Float(reverse ? 1 - t : t)
    }

    static func midpointRemap(_ u: Float, _ m: Float) -> Float {
        let m = min(max(m, 0.05), 0.95)
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
}
