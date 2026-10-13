// Port of photocraft-paint (crates/paint/src/dynamics.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// From input points to dabs: smoothing, brush pose, path walking (spacing, airbrush build-up) and
// the per-dab dynamics (shape, scattering, transfer, colour, texture depth). Everything is
// incremental (feed points in any chunking, get the same dabs) and deterministic: jitter comes
// from `PaintRNG` keyed by the stroke seed and the step/dab index.

import Foundation

/// Maximum pulled-string length at 100 % smoothing, in screen pixels.
public let maxStringPx: Double = 100
/// Stroke time over which exponential smoothing moves its fraction of the way to the pointer.
public let smoothingStepMs: Double = 16
/// With Spacing unchecked, one dab per this many milliseconds of stroke time.
public let speedSpacingMs: Double = 8
/// Longest pixel-grid segment (in pixels) before falling back to distance spacing.
let maxGridSteps: Double = 1e7
/// Densest speed spacing, in pixels between dabs.
let minSpeedStep: Double = 0.5
/// Maximum airbrush catch-up dabs for one input segment.
let maxAirbrushDabsPerSegment = 512

@inline(__always) func lerpPoint(_ a: StrokePoint, _ b: StrokePoint, _ f: Double) -> StrokePoint {
    let ff = Float(f)
    return StrokePoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f,
                       pressure: a.pressure + (b.pressure - a.pressure) * ff,
                       tiltX: a.tiltX + (b.tiltX - a.tiltX) * ff, tiltY: a.tiltY + (b.tiltY - a.tiltY) * ff,
                       rotation: a.rotation + (b.rotation - a.rotation) * ff, wheel: a.wheel + (b.wheel - a.wheel) * ff,
                       time: a.time + (b.time - a.time) * f)
}

// MARK: - Smoothing

/// Incremental stroke smoothing: exponential (with optional time-based catch-up) or pulled string.
public struct Smoother: Sendable {
    var cfg: Smoothing
    var zoom: Double
    var pos: StrokePoint?
    var lastInput: StrokePoint?

    /// `zoom` is the view zoom (only used with `adjustForZoom`).
    public init(_ cfg: Smoothing, zoom: Float) {
        self.cfg = cfg
        self.zoom = Double(maxR(zoom, 0.01))
    }

    var active: Bool { cfg.amount > 0 }

    /// Feed one input point; appends the brush positions to paint through.
    public mutating func push(_ p: StrokePoint, _ out: inout [StrokePoint]) {
        let prevInput = lastInput
        lastInput = p
        if !active { out.append(p); return }
        guard let pos else {
            self.pos = p
            out.append(p)
            return
        }
        let amount = Double(clampR(cfg.amount, 0, 1))
        if cfg.pulledString {
            var len = amount * maxStringPx
            if cfg.adjustForZoom { len /= zoom }
            let dx = p.x - pos.x, dy = p.y - pos.y
            let d = (dx * dx + dy * dy).squareRoot()
            if d > len {
                let k = (d - len) / d
                var np = p
                np.x = pos.x + dx * k
                np.y = pos.y + dy * k
                self.pos = np
                out.append(np)
            }
            return
        }
        // Exponential: every SMOOTHING_STEP_MS of stroke time moves `a` of the way towards the
        // pointer, so the feel doesn't depend on how often the device reports.
        let a = 1 - minR(amount, 0.95)
        let dt = prevInput.map { p.time - $0.time } ?? 0
        let still = prevInput.map { $0.x == p.x && $0.y == p.y } ?? false
        if still && !cfg.catchUp { return }
        let iters: Int, step: Double
        if dt > 0 && dt.isFinite {
            let steps = dt / smoothingStepMs
            let it = clampR(steps.rounded(.up), 1, 64)
            iters = Int(it)
            step = 1 - pow(1 - a, minR(steps, 64) / it)
        } else {
            iters = 1
            step = a
        }
        var cur = pos
        for _ in 0..<iters {
            var n = p
            n.x = cur.x + (p.x - cur.x) * step
            n.y = cur.y + (p.y - cur.y) * step
            cur = n
            out.append(cur)
        }
        self.pos = cur
    }

    /// Is Stroke Catch-Up still pulling the brush towards a pointer that has stopped?
    public var lagging: Bool {
        guard active && cfg.catchUp && !cfg.pulledString, let pos, let last = lastInput else { return false }
        return abs(pos.x - last.x) + abs(pos.y - last.y) > 0.01
    }

    /// The string between the brush and the pointer (brush, pointer) while smoothing holds the
    /// brush back from the last input point; nil when they coincide (or smoothing is off).
    public var string: (brush: SIMD2<Double>, pointer: SIMD2<Double>)? {
        guard let pos, let last = lastInput else { return nil }
        guard active && (pos.x != last.x || pos.y != last.y) else { return nil }
        return (SIMD2(pos.x, pos.y), SIMD2(last.x, last.y))
    }

    /// End of stroke: with Catch-Up On Stroke End the brush finishes at the last pointer position.
    public mutating func finish(_ out: inout [StrokePoint]) {
        if !active || !cfg.catchUpOnEnd { return }
        if let pos, let last = lastInput, pos.x != last.x || pos.y != last.y {
            self.pos = last
            out.append(last)
        }
    }
}

/// Smooth a whole point list with the brush's smoothing settings.
public func smoothPoints(_ cfg: Smoothing, zoom: Float, _ pts: [StrokePoint]) -> [StrokePoint] {
    var s = Smoother(cfg, zoom: zoom)
    var out: [StrokePoint] = []
    out.reserveCapacity(pts.count)
    for p in pts { s.push(p, &out) }
    s.finish(&out)
    return out
}

// MARK: - Path walking

/// One spacing (or airbrush time) step along the path.
public struct StepInput: Sendable {
    public var point: StrokePoint
    /// Visual (counter-clockwise, y-up) direction of travel in radians.
    public var direction: Float
    public var initialDirection: Float
    /// Sequential step number (0 = first).
    public var step: UInt64
}

/// Walks a polyline and emits steps every `stepLen(point)` pixels, plus airbrush steps in time.
public struct PathWalker: Sendable {
    var last: StrokePoint?
    /// Path distance from `last` to the next step.
    var nextAt: Double = 0
    /// First point, emitted lazily once the initial direction is known.
    var pendingFirst: StrokePoint?
    var initialDir: Float?
    var dir: Float = 0
    var step: UInt64 = 0
    /// Airbrush interval in ms (nil = off).
    var interval: Double?
    var timeAcc: Double = 0
    /// Speed spacing (Spacing unchecked): one step per this many ms of stroke time.
    var speed: Double?
    var speedAcc: Double = 0
    /// Pixel-grid stepping for small aliased tips: the dab-centre offset inside a pixel.
    var grid: Double?

    public init(buildUpIntervalMs: Double?) { interval = buildUpIntervalMs }

    /// Step pixel by pixel instead of by distance (a small aliased tip draws a clean 8-connected
    /// staircase, photocraft #2139). `offset` is 0.5 for odd tip diameters, 0 for even ones.
    public func pixelGrid(_ offset: Double) -> PathWalker {
        var w = self
        w.grid = offset
        return w
    }

    /// Space steps by stroke time instead of distance: faster movement spreads them out.
    public func speedSpacing(_ intervalMs: Double) -> PathWalker {
        var w = self
        w.speed = maxR(intervalMs, 0.1)
        return w
    }

    mutating func emit(_ point: StrokePoint, _ out: (StepInput) -> Void) {
        let s = StepInput(point: point, direction: dir, initialDirection: initialDir ?? dir, step: step)
        step += 1
        out(s)
    }

    /// Emits the pixel steps from `a` to `p`; false (emitting nothing) when the span is not finite
    /// or implausibly long, so distance spacing takes over.
    mutating func gridSteps(_ a: StrokePoint, _ p: StrokePoint, _ offset: Double, _ out: (StepInput) -> Void) -> Bool {
        func cell(_ v: Double) -> Double { offset > 0 ? v.rounded(.down) : v.rounded() }
        let x0 = cell(a.x), y0 = cell(a.y)
        let dx = cell(p.x) - x0, dy = cell(p.y) - y0
        let n = maxR(abs(dx), abs(dy))
        if !n.isFinite || n > maxGridSteps { return false }
        let steps = asU64(n)
        if steps >= 1 {
            for i in 1...steps {
                let fi = Double(i)
                var q = lerpPoint(a, p, fi / n)
                q.x = x0 + (dx * fi / n).rounded() + offset
                q.y = y0 + (dy * fi / n).rounded() + offset
                emit(q, out)
            }
        }
        return true
    }

    public mutating func push(_ p: StrokePoint, stepLen: (StrokePoint) -> Double, out: (StepInput) -> Void) {
        guard let a = last else {
            last = p
            pendingFirst = p
            nextAt = stepLen(p)
            return
        }
        let dx = p.x - a.x, dy = p.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        if len > 1e-9 {
            dir = Float(atan2(-dy, dx))
            if initialDir == nil { initialDir = dir }
        }
        if let f = pendingFirst {
            pendingFirst = nil
            emit(f, out)
        }
        if len > 1e-9 {
            // Speed spacing needs the segment's duration; without timestamps the segment is spaced
            // by distance instead.
            let dt = p.time - a.time
            if let iv = speed, dt > 0 && dt.isFinite {
                speedAcc += dt
                let maxN = asUsize(maxR((len / minSpeedStep).rounded(.up), 1))
                var n = 0
                while speedAcc >= iv && n < maxN {
                    speedAcc -= iv
                    let f = clampR((dt - speedAcc) / dt, 0, 1)
                    emit(lerpPoint(a, p, f), out)
                    n += 1
                }
                if n == maxN { speedAcc = remEuclid(speedAcc, iv) }
            } else {
                var done = false
                if let g = grid { done = gridSteps(a, p, g, out) }
                if !done {
                    while nextAt <= len + 1e-9 {
                        let q = lerpPoint(a, p, minR(nextAt / len, 1))
                        emit(q, out)
                        nextAt += maxR(stepLen(q), 0.25)
                    }
                    nextAt -= len
                }
            }
        }
        if let iv = interval {
            let dt = p.time - a.time
            if dt > 0 && dt.isFinite {
                if dt > iv * Double(maxAirbrushDabsPerSegment) {
                    // A stalled or hostile timestamp must not replay an arbitrarily long backlog.
                    timeAcc = 0
                    emit(p, out)
                    last = p
                    return
                }
                timeAcc += dt
                var n = 0
                while timeAcc >= iv && n < maxAirbrushDabsPerSegment {
                    timeAcc -= iv
                    let f = clampR((dt - timeAcc) / dt, 0, 1)
                    emit(lerpPoint(a, p, f), out)
                    n += 1
                }
            }
        }
        last = p
    }

    public mutating func finish(_ out: (StepInput) -> Void) {
        if let f = pendingFirst {
            pendingFirst = nil
            emit(f, out)
        }
    }
}

// MARK: - Dynamics

/// Scalar control value in 0…1.
public func controlValue(_ c: Control, _ fadeSteps: UInt32, _ s: StepInput) -> Float {
    let p = s.point
    switch c {
    case .off, .initialDirection, .direction: return 1
    case .fade: return 1 - minR(Float(s.step) / Float(max(fadeSteps, 1)), 1)
    case .penPressure: return clampR(p.pressure, 0, 1)
    // Upright pen = 1, flat pen = 0 (a mouse reports no tilt, so paints at full value).
    case .penTilt: return 1 - clampR(hypotf(p.tiltX, p.tiltY) / 90, 0, 1)
    case .stylusWheel: return clampR(p.wheel, 0, 1)
    case .rotation: return remEuclid(p.rotation, 360) / 360
    }
}

/// Angle contributed by a control, in degrees (counter-clockwise).
public func controlAngle(_ c: Control, _ fadeSteps: UInt32, _ s: StepInput) -> Float {
    let p = s.point
    switch c {
    case .off: return 0
    case .fade: return 360 * minR(Float(s.step) / Float(max(fadeSteps, 1)), 1)
    case .penPressure: return 360 * clampR(p.pressure, 0, 1)
    case .penTilt: return (p.tiltX == 0 && p.tiltY == 0) ? 0 : toDegrees(atan2f(-p.tiltY, p.tiltX))
    case .stylusWheel: return 360 * clampR(p.wheel, 0, 1)
    case .rotation: return p.rotation
    case .initialDirection: return toDegrees(s.initialDirection)
    case .direction: return toDegrees(s.direction)
    }
}

/// A 0…1 multiplier from a dynamic: control lerps from `minimum` to 1, jitter reduces randomly,
/// never below `minimum`.
func scalar(_ d: Dynamic, _ s: StepInput, _ r: Float) -> Float {
    if !d.isActive { return 1 }
    let mn = clampR(d.minimum, 0, 1)
    let cv = controlValue(d.control, d.fadeSteps, s)
    let v = (mn + (1 - mn) * cv) * (1 - clampR(d.jitter, 0, 1) * r)
    return maxR(v, mn)
}

func rgbToHSV(_ c: SIMD3<Float>) -> SIMD3<Float> {
    let mx = maxR(maxR(c.x, c.y), c.z)
    let mn = minR(minR(c.x, c.y), c.z)
    let d = mx - mn
    let h: Float
    if d <= 0 {
        h = 0
    } else if mx == c.x {
        h = remEuclid((c.y - c.z) / d, 6) / 6
    } else if mx == c.y {
        h = ((c.z - c.x) / d + 2) / 6
    } else {
        h = ((c.x - c.y) / d + 4) / 6
    }
    return SIMD3(h, mx > 0 ? d / mx : 0, mx)
}

func hsvToRGB(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
    let h6 = remEuclid(h, 1) * 6
    let i = h6.rounded(.down)
    let f = h6 - i
    let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
    switch asI32(i) {
    case 0: return SIMD3(v, t, p)
    case 1: return SIMD3(q, v, p)
    case 2: return SIMD3(p, v, t)
    case 3: return SIMD3(p, q, v)
    case 4: return SIMD3(t, p, v)
    default: return SIMD3(v, p, q)
    }
}

/// Colour Dynamics for one dab (or once per stroke, with `index = 0`).
public func dynamicColor(_ b: BrushSettings, _ s: StepInput, seed: UInt64, index: UInt64) -> SIMD4<Float> {
    let cd = b.colorDynamics
    let fg = b.color, bg = b.background
    func r(_ st: UInt64) -> Float { PaintRNG.rand01(seed, index, st) }
    let base: Float = cd.fgBg.control != .off ? 1 - controlValue(cd.fgBg.control, cd.fgBg.fadeSteps, s) : 0
    let t = clampR(base + (1 - base) * clampR(cd.fgBg.jitter, 0, 1) * r(PaintRNG.Stream.fgBg), 0, 1)
    let rgb = SIMD3(fg.x + (bg.x - fg.x) * t, fg.y + (bg.y - fg.y) * t, fg.z + (bg.z - fg.z) * t)
    var hsv = rgbToHSV(rgb)
    hsv.x += PaintRNG.randSigned(seed, index, PaintRNG.Stream.hue) * clampR(cd.hueJitter, 0, 1) * 0.5
    var sat = clampR(hsv.y + PaintRNG.randSigned(seed, index, PaintRNG.Stream.sat) * clampR(cd.saturationJitter, 0, 1), 0, 1)
    let pu = clampR(cd.purity, -1, 1)
    sat = pu >= 0 ? sat + (1 - sat) * pu : sat * (1 + pu)
    let v = clampR(hsv.z + PaintRNG.randSigned(seed, index, PaintRNG.Stream.bright) * clampR(cd.brightnessJitter, 0, 1), 0, 1)
    let o = hsvToRGB(hsv.x, sat, v)
    return SIMD4(o.x, o.y, o.z, fg.w + (bg.w - fg.w) * t)
}

/// Base (pre-jitter) diameter at a step: size × size control (pressure etc.). Drives spacing.
public func baseDiameter(_ b: BrushSettings, _ s: StepInput) -> Float {
    let sd = b.shapeDynamics
    var f: Float = 1
    if sd.enabled && sd.size.control != .off {
        let mn = clampR(sd.size.minimum, 0, 1)
        f = mn + (1 - mn) * controlValue(sd.size.control, sd.size.fadeSteps, s)
    } else if b.pressureSize {
        f = clampR(s.point.pressure, 0, 1)
    }
    return b.size * f
}

/// Builds the primary dabs of a step (Shape Dynamics, Scattering, Transfer, Color, Texture depth).
public struct DabBuilder: Sendable {
    public var brush: BrushSettings
    public var seed: UInt64
    /// Per-stroke colour (Color Dynamics with per-tip off), computed at the first step.
    var strokeColor: SIMD4<Float>?
    var nextIndex: UInt64 = 0

    public init(_ brush: BrushSettings) {
        self.brush = brush
        self.seed = brush.seed
    }

    public func stepLen(_ p: StrokePoint) -> Double {
        let s = StepInput(point: p, direction: 0, initialDirection: 0, step: 0)
        let d = maxR(baseDiameter(brush, s), 1)
        return maxR(Double(d * maxR(brush.spacing, 0.01)), 0.5)
    }

    public mutating func build(_ s: StepInput, _ out: inout [Dab]) {
        let b = brush
        let seed = self.seed
        let sd = b.shapeDynamics
        let sc = b.scattering
        let count: UInt32
        if sc.enabled {
            let n = Float(min(max(sc.count, 1), 16))
            let k = scalar(sc.countJitter, s, PaintRNG.rand01(seed, s.step, PaintRNG.Stream.count))
            count = min(max(asU32((n * k).rounded()), 1), 16)
        } else {
            count = 1
        }
        let baseD = baseDiameter(b, s)
        for _ in 0..<count {
            let i = nextIndex
            nextIndex += 1
            func r(_ st: UInt64) -> Float { PaintRNG.rand01(seed, i, st) }
            // Shape.
            var diameter = baseD
            var angle = b.angle
            var roundness = clampR(b.roundness, 0.01, 1)
            var fx = b.flipX, fy = b.flipY
            if sd.enabled {
                if sd.size.jitter > 0 {
                    let mn = clampR(sd.size.minimum, 0, 1)
                    let f = maxR(1 - clampR(sd.size.jitter, 0, 1) * r(PaintRNG.Stream.size), mn)
                    diameter *= f
                }
                angle += controlAngle(sd.angle.control, sd.angle.fadeSteps, s)
                    + PaintRNG.randSigned(seed, i, PaintRNG.Stream.angle) * clampR(sd.angle.jitter, 0, 1) * 180
                roundness = clampR(roundness * scalar(sd.roundness, s, r(PaintRNG.Stream.roundness)), 0.01, 1)
                if sd.flipXJitter && r(PaintRNG.Stream.flipX) < 0.5 { fx.toggle() }
                if sd.flipYJitter && r(PaintRNG.Stream.flipY) < 0.5 { fy.toggle() }
            }
            // Tilt Scale and Brush Projection (Shape Dynamics).
            var projAngle: Float = 0, projScale: Float = 1
            if sd.enabled {
                let tilt = clampR(hypotf(s.point.tiltX, s.point.tiltY), 0, 90)
                if sd.size.control == .penTilt && sd.tiltScale > 0 {
                    let k = 1 - clampR(sd.tiltScale, 0, 2) * 0.5 * tilt / 90
                    roundness = clampR(roundness * k, 0.01, 1)
                }
                if sd.brushProjection {
                    angle += s.point.rotation
                    if tilt > 0 {
                        projAngle = atan2f(-s.point.tiltY, s.point.tiltX)
                        projScale = maxR(cosf(toRadians(tilt)), 0.05)
                    }
                }
            }
            let radius = maxR(diameter / 2, 0.5)
            // Scatter.
            var c = PaintPoint(s.point.x, s.point.y)
            if sc.enabled && sc.scatter.jitter > 0 {
                let cv = controlValue(sc.scatter.control, sc.scatter.fadeSteps, s)
                let amt = Double(sc.scatter.jitter * cv * radius)
                let ox = Double(PaintRNG.randSigned(seed, i, PaintRNG.Stream.scatterX)) * amt
                let oy = Double(PaintRNG.randSigned(seed, i, PaintRNG.Stream.scatterY)) * amt
                if sc.bothAxes {
                    c.x += ox
                    c.y += oy
                } else {
                    // Perpendicular to the direction of travel (y-down image space).
                    let dx = Double(cosf(s.direction)), dy = -Double(sinf(s.direction))
                    c.x += -dy * ox
                    c.y += dx * ox
                }
            }
            // Transfer.
            let tr = b.transfer
            var opacity: Float = 1, flow = b.flow
            if tr.enabled {
                opacity = scalar(tr.opacity, s, r(PaintRNG.Stream.opacity))
                flow *= scalar(tr.flow, s, r(PaintRNG.Stream.flow))
            }
            let wet: Float, mix: Float
            if tr.enabled {
                wet = scalar(tr.wetness, s, r(PaintRNG.Stream.wet))
                mix = scalar(tr.mix, s, r(PaintRNG.Stream.mix))
            } else {
                wet = 1; mix = 1
            }
            if b.pressureOpacity && !(tr.enabled && tr.opacity.control != .off) {
                opacity *= clampR(s.point.pressure, 0, 1)
            }
            // Colour.
            let color: SIMD4<Float>
            if b.colorDynamics.enabled {
                if b.colorDynamics.perTip {
                    color = dynamicColor(b, s, seed: seed, index: i)
                } else {
                    if strokeColor == nil { strokeColor = dynamicColor(b, s, seed: seed, index: 0) }
                    color = strokeColor!
                }
            } else {
                color = b.color
            }
            // Texture depth (per tip).
            let tx = b.texture
            let depth = (tx.enabled && tx.eachTip)
                ? clampR(tx.depth, 0, 1) * scalar(tx.depthJitter, s, r(PaintRNG.Stream.depth))
                : clampR(tx.depth, 0, 1)
            out.append(Dab(center: c, radius: radius, alpha: clampR(flow, 0, 1), angle: toRadians(angle), roundness: roundness,
                           flipX: fx, flipY: fy, opacity: clampR(opacity, 0, 1), color: color, depth: depth, index: i,
                           projAngle: projAngle, projScale: projScale, wet: wet, mix: mix))
        }
    }
}

/// Builds Dual Brush dabs (the second tip: size, spacing, scatter, count, flip).
public struct DualBuilder: Sendable {
    public var brush: BrushSettings
    var nextIndex: UInt64 = 0

    public init(_ brush: BrushSettings) { self.brush = brush }

    public func stepLen(_ p: StrokePoint) -> Double {
        let d = brush.dualBrush
        return maxR(Double(maxR(d.size, 1) * maxR(d.spacing, 0.01)), 0.5)
    }

    public mutating func build(_ s: StepInput, _ out: inout [Dab]) {
        let d = brush.dualBrush
        let seed = brush.seed ^ 0xD0A1
        for _ in 0..<min(max(d.count, 1), 16) {
            let i = nextIndex
            nextIndex += 1
            let radius = maxR(d.size / 2, 0.5)
            let amt = Double(d.scatter * radius)
            let ox = Double(PaintRNG.randSigned(seed, i, PaintRNG.Stream.dualX)) * amt
            let oy = Double(PaintRNG.randSigned(seed, i, PaintRNG.Stream.dualY)) * amt
            var c = PaintPoint(s.point.x, s.point.y)
            if d.bothAxes {
                c.x += ox
                c.y += oy
            } else {
                let dx = Double(cosf(s.direction)), dy = -Double(sinf(s.direction))
                c.x += -dy * ox
                c.y += dx * ox
            }
            let flip = d.flip && PaintRNG.rand01(seed, i, PaintRNG.Stream.dualFlip) < 0.5
            out.append(Dab(center: c, radius: radius, alpha: 1, angle: toRadians(d.angle), roundness: clampR(d.roundness, 0.01, 1),
                           flipX: flip, flipY: false, opacity: 1, color: SIMD4(0, 0, 0, 1), depth: 1, index: i))
        }
    }
}

/// Apply Brush Pose to an input point.
public func applyPose(_ b: BrushSettings, _ p0: StrokePoint) -> StrokePoint {
    var p = p0
    let pose = b.pose
    if pose.enabled {
        if pose.overrideTilt { p.tiltX = pose.tiltX; p.tiltY = pose.tiltY }
        if pose.overrideRotation { p.rotation = pose.rotation }
        if pose.overridePressure { p.pressure = pose.pressure }
    }
    return p
}

/// Incremental dab generation for a whole brush (primary and optional dual dabs).
public struct DabGenerator: Sendable {
    var smoother: Smoother
    var walker: PathWalker
    var dualWalker: PathWalker?
    public private(set) var builder: DabBuilder
    var dual: DualBuilder?

    public init(brush brush0: BrushSettings, zoom: Float) {
        let brush = brush0.boundedForRender()
        let interval: Double? = brush.buildUp ? 1000 / Double(clampR(brush.buildUpRate, 0.1, 1000)) : nil
        let dualOn = brush.dualBrush.enabled
        var walker = brush.spacingEnabled ? PathWalker(buildUpIntervalMs: interval)
            : PathWalker(buildUpIntervalMs: interval).speedSpacing(speedSpacingMs)
        // A small aliased tip whose dabs are at most a pixel apart steps pixel by pixel (#2139).
        if brush.aliased && brush.size * maxR(brush.spacing, 0.01) <= 1 {
            walker = walker.pixelGrid(Double(gridCenter(0, 0, brush.size).0))
        }
        smoother = Smoother(brush.smoothing, zoom: zoom)
        self.walker = walker
        dualWalker = dualOn ? PathWalker(buildUpIntervalMs: nil) : nil
        builder = DabBuilder(brush)
        dual = dualOn ? DualBuilder(brush) : nil
    }

    /// Does the stroke change with time while the pointer is held still (airbrush Build-up, or
    /// smoothing still catching up)? The canvas then keeps feeding it the held point.
    public var wantsTime: Bool { walker.interval != nil || smoother.lagging }

    /// See `Smoother.string`.
    public var smoothingString: (brush: SIMD2<Double>, pointer: SIMD2<Double>)? { smoother.string }

    mutating func walk(_ pts: [StrokePoint], _ dabs: inout [Dab], _ dual: inout [Dab]) {
        var steps: [StepInput] = []
        let b = builder
        for p0 in pts {
            let p = applyPose(b.brush, p0)
            steps.removeAll(keepingCapacity: true)
            walker.push(p, stepLen: { b.stepLen($0) }, out: { steps.append($0) })
            for s in steps { builder.build(s, &dabs) }
            if dualWalker != nil, let db = self.dual {
                steps.removeAll(keepingCapacity: true)
                dualWalker!.push(p, stepLen: { db.stepLen($0) }, out: { steps.append($0) })
                for s in steps { self.dual!.build(s, &dual) }
            }
        }
    }

    /// Feed input points; appends the new primary and dual dabs.
    public mutating func push(_ pts: [StrokePoint], _ dabs: inout [Dab], _ dual: inout [Dab]) {
        var sm: [StrokePoint] = []
        sm.reserveCapacity(pts.count)
        for p in pts { smoother.push(p, &sm) }
        walk(sm, &dabs, &dual)
    }

    /// End of stroke.
    public mutating func finish(_ dabs: inout [Dab], _ dual: inout [Dab]) {
        var sm: [StrokePoint] = []
        smoother.finish(&sm)
        walk(sm, &dabs, &dual)
        var steps: [StepInput] = []
        walker.finish { steps.append($0) }
        for s in steps { builder.build(s, &dabs) }
        if dualWalker != nil, self.dual != nil {
            steps.removeAll()
            dualWalker!.finish { steps.append($0) }
            for s in steps { self.dual!.build(s, &dual) }
        }
    }
}
