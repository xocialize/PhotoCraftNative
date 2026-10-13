// Port of photocraft-paint (crates/paint/src/lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Brush engine: Photoshop-grade brushes (computed and sampled tips, Shape Dynamics, Scattering,
// Texture, Dual Brush, Color Dynamics, Transfer, Brush Pose, Noise, Wet Edges, Build-up,
// Smoothing) plus the dab machinery shared by the retouching tools.
//
// Strokes are data (`Stroke`) so they can be recorded, replayed by automation, and tested
// deterministically: every jitter is a hash of the brush seed and the dab index (`PaintRNG`).
// Dabs composite with "build-up up to stroke opacity" semantics: within one stroke, coverage
// accumulates with flow towards each dab's opacity ceiling, and the stroke composites once at the
// stroke opacity (Photoshop's Opacity versus Flow).

import Foundation
import PCFoundation

/// One input sample. Missing stylus data defaults to "mouse": full pressure, no tilt/rotation.
public struct StrokePoint: Hashable, Sendable {
    public var x: Double = 0
    public var y: Double = 0
    /// 0…1, 1 for mouse.
    public var pressure: Float = 1
    /// Degrees -90…90 (W3C Pointer Events `tiltX`/`tiltY`).
    public var tiltX: Float = 0
    public var tiltY: Float = 0
    /// Barrel rotation in degrees 0…360.
    public var rotation: Float = 0
    /// Airbrush stylus wheel 0…1.
    public var wheel: Float = 1
    /// Timestamp in milliseconds (airbrush build-up, speed spacing and smoothing catch-up).
    public var time: Double = 0

    public init() {}

    public init(_ x: Double, _ y: Double, _ pressure: Float) {
        self.x = x; self.y = y; self.pressure = pressure
    }

    public init(x: Double, y: Double, pressure: Float = 1, tiltX: Float = 0, tiltY: Float = 0, rotation: Float = 0,
                wheel: Float = 1, time: Double = 0) {
        self.x = x; self.y = y; self.pressure = pressure; self.tiltX = tiltX; self.tiltY = tiltY
        self.rotation = rotation; self.wheel = wheel; self.time = time
    }

    /// A copy with fields replaced (Rust's `StrokePoint { time: 16.0, ..p }`).
    public func with(x: Double? = nil, y: Double? = nil, pressure: Float? = nil, time: Double? = nil) -> StrokePoint {
        var p = self
        if let x { p.x = x }
        if let y { p.y = y }
        if let pressure { p.pressure = pressure }
        if let time { p.time = time }
        return p
    }
}

extension StrokePoint: Codable {
    enum CodingKeys: String, CodingKey { case x, y, pressure, tiltX, tiltY, rotation, wheel, time }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StrokePoint()
        self.init(x: try c.get(.x, d.x), y: try c.get(.y, d.y), pressure: try c.get(.pressure, d.pressure), tiltX: try c.get(.tiltX, d.tiltX),
                  tiltY: try c.get(.tiltY, d.tiltY), rotation: try c.get(.rotation, d.rotation), wheel: try c.get(.wheel, d.wheel),
                  time: try c.get(.time, d.time))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x); try c.encode(y, forKey: .y); try c.encode(pressure, forKey: .pressure)
        try c.encode(tiltX, forKey: .tiltX); try c.encode(tiltY, forKey: .tiltY); try c.encode(rotation, forKey: .rotation)
        try c.encode(wheel, forKey: .wheel); try c.encode(time, forKey: .time)
    }
}

/// A recorded stroke: the brush and its input points.
public struct Stroke: Hashable, Sendable, Codable {
    public var brush: BrushSettings
    public var points: [StrokePoint]
    public init(brush: BrushSettings, points: [StrokePoint]) { self.brush = brush; self.points = points }
}

/// A dab placed along the stroke (after dynamics).
public struct Dab: Hashable, Sendable {
    public var center: PaintPoint
    public var radius: Float
    /// Flow: per-dab build-up amount.
    public var alpha: Float
    /// Radians, counter-clockwise.
    public var angle: Float = 0
    public var roundness: Float = 1
    public var flipX = false
    public var flipY = false
    /// Opacity ceiling this dab builds up to (Transfer › Opacity).
    public var opacity: Float = 1
    /// Straight RGBA paint colour (Color Dynamics).
    public var color: SIMD4<Float> = SIMD4(0, 0, 0, 1)
    /// Texture depth for per-tip texturing.
    public var depth: Float = 1
    /// Position in the stroke (0 = first).
    public var index: UInt64 = 0
    /// Brush Projection: direction (radians, CCW, y up) along which the tip is foreshortened, and
    /// the factor (1 = no projection).
    public var projAngle: Float = 0
    public var projScale: Float = 1
    /// Mixer Brush multipliers of Wet and Mix (Transfer › Wetness/Mix Jitter), 1 = as set.
    public var wet: Float = 1
    public var mix: Float = 1

    /// A plain round dab.
    public static func round(_ center: PaintPoint, _ radius: Float, _ alpha: Float) -> Dab {
        Dab(center: center, radius: radius, alpha: alpha)
    }

    public init(center: PaintPoint, radius: Float, alpha: Float, angle: Float = 0, roundness: Float = 1, flipX: Bool = false,
                flipY: Bool = false, opacity: Float = 1, color: SIMD4<Float> = SIMD4(0, 0, 0, 1), depth: Float = 1, index: UInt64 = 0,
                projAngle: Float = 0, projScale: Float = 1, wet: Float = 1, mix: Float = 1) {
        self.center = center; self.radius = radius; self.alpha = alpha; self.angle = angle; self.roundness = roundness
        self.flipX = flipX; self.flipY = flipY; self.opacity = opacity; self.color = color; self.depth = depth
        self.index = index; self.projAngle = projAngle; self.projScale = projScale; self.wet = wet; self.mix = mix
    }
}

/// All primary dabs of a stroke (smoothing, pose, spacing, build-up and dynamics applied).
public func dabs(_ stroke: Stroke) -> [Dab] {
    var g = DabGenerator(brush: stroke.brush, zoom: 1)
    var out: [Dab] = [], dual: [Dab] = []
    g.push(stroke.points, &out, &dual)
    g.finish(&out, &dual)
    return out
}

/// Opacity of a round tip at distance `d` from its centre, without edge anti-aliasing: 1 in the
/// hard core (`hardness` of the radius), then a Gaussian-like fall to 0 at the radius:
/// `(1 − t²)⁴`, which tracks `exp(−4.6 t²)` closely but is exact (no `exp`, the same on every
/// platform), reaches exactly 0 at the edge and leaves it flat.
@inline(__always) public func tipFalloff(_ d: Float, _ radius: Float, _ hardness: Float) -> Float {
    let inner = radius * clampR(hardness, 0, 1)
    if d <= inner || radius - inner < 1e-3 { return 1 }
    let t = clampR((d - inner) / (radius - inner), 0, 1)
    let s = 1 - t * t
    let s2 = s * s
    return s2 * s2
}

/// Distance from the centre where `tipFalloff` drops to 50 %: the contour Preferences › Cursors ›
/// Normal Brush Tip outlines (`t = √(1 − ½^¼) ≈ 0.399` of the way from the hard core to the edge).
public func halfCoverageRadius(_ radius: Float, _ hardness: Float) -> Float {
    let h: Float = hardness.isNaN ? 0 : clampR(hardness, 0, 1)
    let t = (1 - Float(0.5).squareRoot().squareRoot()).squareRoot()
    return radius * (h + t * (1 - h))
}

/// Coverage of a round dab at distance `d` from its centre (anti-aliased edge, hardness falloff).
@inline(__always) public func dabCoverage(_ d: Float, _ radius: Float, _ hardness: Float) -> Float {
    if d >= radius + 0.5 { return 0 }
    let edge = minR(clampR(radius + 0.5 - d, 0, 1), 1)
    return edge * tipFalloff(d, radius, hardness)
}

/// Rasterise a stroke onto `target`, optionally limited by a selection (grayscale coverage
/// surface). Returns the damaged rectangle.
@discardableResult
public func applyStroke(_ target: inout Surface, _ stroke: Stroke, selection: Surface? = nil, lockTransparency: Bool = false) -> PixelRect {
    renderStroke(&target, stroke.brush, stroke.points, selection: selection, lockTransparency: lockTransparency, zoom: 1)
}

/// Exponential moving-average smoothing of input points (Photoshop's "Smoothing" %, simplified).
public func smooth(_ points: [StrokePoint], amount: Float) -> [StrokePoint] {
    let a = Double(1 - clampR(amount, 0, 0.95))
    var out: [StrokePoint] = []
    out.reserveCapacity(points.count)
    var cur: StrokePoint?
    for p in points {
        let n: StrokePoint
        if let c = cur {
            var q = p
            q.x = c.x + (p.x - c.x) * a
            q.y = c.y + (p.y - c.y) * a
            n = q
        } else {
            n = p
        }
        out.append(n)
        cur = n
    }
    if !out.isEmpty, let end = points.last { out[out.count - 1] = end }
    return out
}
