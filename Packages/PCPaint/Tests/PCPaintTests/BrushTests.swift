// Port of photocraft-paint (crates/paint/src/brush_tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Brush-engine tests: tips, spacing, dynamics, masks, smoothing, determinism, formats.

import Foundation
import Testing
import PCFoundation
@testable import PCPaint

@Suite struct TipTests {
    @Test func roundTipRoundnessAndAngle() {
        let b = brush()
        var d = Dab.round(PaintPoint(50, 50), 20, 1)
        d.roundness = 0.25
        var r = raster(b, d)
        // Wide along x, thin along y.
        #expect(at(r, 50 + 15, 50) > 0.99)
        #expect(at(r, 50, 50 + 8) < 0.01)
        #expect(at(r, 50, 50 + 3) > 0.99)
        // Rotated 90° counter-clockwise: now tall.
        d.angle = .pi / 2
        r = raster(b, d)
        #expect(at(r, 50, 50 - 15) > 0.99)
        #expect(at(r, 50 + 8, 50) < 0.01)
        // 45°: the long axis runs up-right (y-down image space: x+, y−).
        d.angle = .pi / 4
        r = raster(b, d)
        #expect(at(r, 60, 40) > 0.99, "\(at(r, 60, 40))")
        #expect(at(r, 60, 60) < 0.01)
    }

    @Test func hardnessProfileIsMonotonic() {
        for h: Float in [0, 0.5, 1] {
            let r = raster(with(brush()) { $0.hardness = h }, Dab.round(PaintPoint(50, 50), 20, 1))
            let prof = (0..<22).map { at(r, 50 + Int32($0), 50) }
            #expect(zip(prof, prof.dropFirst()).allSatisfy { $1 <= $0 + 1e-6 }, "h=\(h) \(prof)")
            #expect(prof[0] > 0.99)
            #expect(prof[21] == 0)
            let mid = at(r, 60, 50)
            if h == 1 { #expect(mid > 0.99) } else if h == 0 { #expect(mid > 0.2 && mid < 0.8, "\(mid)") }
        }
    }

    @Test func hardEdgeIsSharp() {
        let r = raster(with(brush()) { $0.hardness = 1 }, Dab.round(PaintPoint(50, 50), 20, 1))
        let prof = (0..<22).map { at(r, 50 + Int32($0), 50) }
        let band = prof.filter { (0.01..<0.99).contains($0) }.count
        #expect(band <= 3, "hardness 1 rim is \(band) px wide: \(prof)")
        #expect(prof[17] > 0.99, "translucent inside the rim: \(prof)")
        #expect(prof.last == 0)
        let rs = raster(with(brush()) { $0.hardness = 0 }, Dab.round(PaintPoint(50, 50), 20, 1))
        let profs = (0..<22).map { at(rs, 50 + Int32($0), 50) }
        let softBand = profs.filter { (0.01..<0.99).contains($0) }.count
        #expect(softBand >= 10, "soft rim is only \(softBand) px: \(profs)")
    }

    @Test func sampledTipIsScaledAndOriented() {
        // Tip: left half painted.
        let tip = GrayTile(width: 16, height: 16) { x, _ in x < 8 ? 1 : 0 }
        let b = with(brush()) { $0.tip = .sampled(tip) }
        let d = Dab.round(PaintPoint(50, 50), 20, 1)
        var r = raster(b, d)
        #expect(at(r, 40, 50) > 0.99 && at(r, 60, 50) < 0.01)
        // Flip X mirrors it.
        var fd = d
        fd.flipX = true
        r = raster(b, fd)
        #expect(at(r, 40, 50) < 0.01 && at(r, 60, 50) > 0.99)
        // Rotated 90° CCW: the painted (left) half moves to the bottom.
        var rd = d
        rd.angle = .pi / 2
        r = raster(b, rd)
        #expect(at(r, 50, 60) > 0.99 && at(r, 50, 40) < 0.01)
        // Heavily downscaled uses mips: still sensible coverage.
        r = raster(b, Dab.round(PaintPoint(50, 50), 2, 1))
        #expect(r.1.reduce(0, +) > 1)
    }

    @Test func pencilIsAliased() {
        let b = with(brush()) { $0.aliased = true; $0.hardness = 0; $0.size = 9 }
        let s = paint(b, line(10, 50, 20.5))
        for y: Int32 in 10..<32 {
            for x: Int32 in 0..<64 {
                let a = s.rgba(x, y).w
                #expect(a == 0 || a == 1, "(\(x),\(y)) = \(a)")
            }
        }
        #expect(s.rgba(30, 20).w == 1)
        // Anti-aliased brush has partial pixels.
        let s2 = paint(with(b) { $0.aliased = false }, line(10, 50, 20.3))
        #expect((10..<32).contains { y in (0..<64).contains { x in (0.01..<0.99).contains(s2.rgba(Int32(x), Int32(y)).w) } })
    }

    @Test func pencilDabsSitOnThePixelGrid() {
        // Odd sizes centre on the pixel holding the point, even ones on the nearest corner.
        #expect(gridCenter(10, 5, 1) == (10.5, 5.5))
        #expect(gridCenter(10.9, 5.2, 3) == (10.5, 5.5))
        #expect(gridCenter(10.4, 5.6, 2) == (10, 6))
        #expect(gridSquare(10.2, 5.7, 1) == [10, 5, 11, 6])
        #expect(gridSquare(10.2, 5.7, 4) == [8, 4, 12, 8])
        #expect(gridSquare(.nan, 0, .nan).count == 4)
        // A 1 px pencil paints exactly the pixel under each point, even on a pixel corner.
        let b = with(brush()) { $0.aliased = true; $0.hardness = 1; $0.size = 1 }
        var s = paint(b, [StrokePoint(7, 4, 1)])
        for y: Int32 in 0..<16 {
            for x: Int32 in 0..<16 { #expect(s.rgba(x, y).w == ((x, y) == (7, 4) ? 1 : 0), "(\(x),\(y))") }
        }
        // A horizontal 1 px line is one pixel thick and unbroken.
        s = paint(b, line(2, 20, 9.3))
        for x: Int32 in 2..<20 {
            #expect(s.rgba(x, 9).w == 1, "x \(x)")
            #expect(s.rgba(x, 8).w + s.rgba(x, 10).w == 0, "x \(x)")
        }
        // A 4 px dab stays inside its cursor square.
        let b4 = with(b) { $0.size = 4 }
        s = paint(b4, [StrokePoint(10.2, 5.7, 1)])
        let sq = gridSquare(10.2, 5.7, 4)
        for y: Int32 in 0..<16 {
            for x: Int32 in 0..<24 {
                let inside = Double(x) >= sq[0] && Double(x) < sq[2] && Double(y) >= sq[1] && Double(y) < sq[3]
                #expect(inside || s.rgba(x, y).w == 0, "(\(x),\(y)) outside the square is painted")
            }
        }
        #expect(s.rgba(9, 5).w == 1)
    }

    @Test func pencil1pxLineIsACleanEightConnectedStaircase() {
        // #2139: a 1 px Pencil line is one pixel per column (or row, when steep) on the ideal line.
        let b = with(brush()) { $0.aliased = true; $0.hardness = 1; $0.size = 1 }
        let cases: [((Double, Double), (Double, Double))] = [((2.5, 2.5), (22.5, 9.5)), ((3.5, 30.5), (10.5, 5.5)), ((1.2, 1.7), (25.8, 4.1)),
                                                             ((5.5, 5.5), (17.5, 17.5)), ((20.3, 3.6), (4.9, 12.2))]
        for ((ax, ay), (bx, by)) in cases {
            let s = paint(b, [StrokePoint(ax, ay, 1), StrokePoint(bx, by, 1)])
            var painted: [(Int32, Int32)] = []
            for y: Int32 in 0..<40 { for x: Int32 in 0..<40 where s.rgba(x, y).w > 0 { painted.append((x, y)) } }
            let a = (ax.rounded(.down), ay.rounded(.down)), e = (bx.rounded(.down), by.rounded(.down))
            let steep = abs(e.1 - a.1) > abs(e.0 - a.0)
            func major(_ p: (Double, Double)) -> (Double, Double) { steep ? (p.1, p.0) : (p.0, p.1) }
            let (m0, n0) = major(a), (m1, n1) = major(e)
            #expect(Double(painted.count) == abs(m1 - m0) + 1, "\(a)->\(e): one pixel per step, got \(painted)")
            for (x, y) in painted {
                let (m, n) = major((Double(x), Double(y)))
                let ideal = n0 + (n1 - n0) * (m - m0) / (m1 - m0)
                #expect(abs(n - ideal) <= 0.5 + 1e-9, "\(a)->\(e): (\(x),\(y)) is off the line")
            }
            let columns = Set(painted.map { Int(major((Double($0.0), Double($0.1))).0) })
            #expect(columns.count == painted.count, "\(a)->\(e): a column holds two pixels")
        }
    }
}

@Suite struct SpacingTests {
    @Test func spacingSetsDabCount() {
        for (spacing, len, expect) in [(Float(0.25), 100.0, 21), (1, 100, 6), (0.5, 200, 21)] {
            let b = with(brush()) { $0.spacing = spacing; $0.size = 20 }
            #expect(dabsOf(b, line(0, len, 0)).count == expect, "spacing \(spacing)")
        }
        // Spacing carries across segments: a polyline gives the same count as the straight line.
        let b = with(brush()) { $0.spacing = 0.5; $0.size = 20 }
        let pts = (0...20).map { StrokePoint(Double($0) * 10, 0, 1) }
        let d = dabsOf(b, pts)
        #expect(d.count == 21)
        #expect(zip(d, d.dropFirst()).allSatisfy { abs(($1.center.x - $0.center.x) - 10) < 1e-6 })
    }

    @Test func strokeHasNoSeams() {
        for spacing: Float in [0.1, 0.25, 0.5] {
            let s = paint(with(brush()) { $0.spacing = spacing; $0.size = 20 }, line(20, 180, 100.5))
            for y: Int32 in 98...102 {
                for x: Int32 in 40...160 {
                    let a = s.rgba(x, y).w
                    #expect(a > 0.99, "spacing \(spacing) seam at (\(x),\(y)): \(a)")
                }
            }
        }
    }

    @Test func spacingOffSpacesDabsByPointerSpeed() {
        var b = with(brush()) { $0.size = 20; $0.spacingEnabled = false }
        func timed(_ ms: Double) -> [StrokePoint] { [StrokePoint(0, 10, 1).with(time: 0), StrokePoint(100, 10, 1).with(time: ms)] }
        // 100 px in 400 ms: a dab every 8 ms = every 2 px; in 40 ms: every 20 px.
        #expect((dabsOf(b, timed(400)).count, dabsOf(b, timed(40)).count) == (51, 6))
        // Never denser than half a pixel, however slow.
        #expect(dabsOf(b, timed(1e9)).count <= 201)
        // No timestamps (a ⇧-click line): spaced by distance like Spacing on.
        let pts = [StrokePoint(0, 10, 1), StrokePoint(90, 10, 1), StrokePoint(100, 10, 1)]
        let checked = with(b) { $0.spacingEnabled = true }
        #expect(dabsOf(b, pts).count == dabsOf(checked, pts).count)
        #expect(dabsOf(b, pts).count > 3)
        b.spacingEnabled = true
        #expect(dabsOf(b, timed(400)).count == dabsOf(b, timed(40)).count)
        // Chunked input gives the same dabs.
        b.spacingEnabled = false
        let many = (0..<20).map { StrokePoint(Double($0) * 7, 10, 1).with(time: Double($0) * 13) }
        let one = dabsOf(b, many)
        var g = DabGenerator(brush: b, zoom: 1)
        var out: [Dab] = [], dual: [Dab] = []
        var i = 0
        while i < many.count {
            g.push(Array(many[i..<min(i + 3, many.count)]), &out, &dual)
            i += 3
        }
        g.finish(&out, &dual)
        #expect(one == out)
    }
}

@Suite struct DynamicsTests {
    @Test func pressureControlsSizeWithMinimum() {
        let b = with(brush()) {
            $0.size = 40
            $0.shapeDynamics = ShapeDynamics(enabled: true, size: Dynamic(control: .penPressure, minimum: 0.25))
        }
        let d = dabsOf(b, [StrokePoint(0, 0, 0), StrokePoint(200, 0, 1)])
        #expect(abs(d[0].radius - 5) < 1e-3, "min diameter 25 % of 40 → r 5, got \(d[0].radius)")
        #expect(abs(d.last!.radius - 20) < 0.5)
        #expect(zip(d, d.dropFirst()).allSatisfy { $1.radius >= $0.radius - 1e-4 })
    }

    @Test func fadeRampsOverSteps() {
        let b = with(brush()) {
            $0.size = 20; $0.spacing = 0.5
            $0.shapeDynamics = ShapeDynamics(enabled: true, size: Dynamic(control: .fade, fadeSteps: 10))
        }
        let d = dabsOf(b, line(0, 300, 0))
        #expect(abs(d[0].radius - 10) < 1e-3)
        #expect(d[5].radius < d[0].radius * 0.6, "\(d[5].radius)")
        #expect(d.dropFirst(10).allSatisfy { $0.radius <= 0.5 + 1e-6 })
        let b2 = with(brush()) { $0.transfer = Transfer(enabled: true, opacity: Dynamic(control: .fade, fadeSteps: 4)) }
        let d2 = dabsOf(b2, line(0, 100, 0))
        #expect(d2[0].opacity == 1)
        #expect(d2[4].opacity == 0)
    }

    @Test func tiltDirectionAndRotationDriveAngle() {
        func mk(_ c: Control) -> BrushSettings { with(brush()) { $0.shapeDynamics = ShapeDynamics(enabled: true, angle: .controlled(c)) } }
        var p = StrokePoint(0, 0, 1)
        p.tiltX = 0
        p.tiltY = -45  // pen leaning "up" the screen
        var d = dabsOf(mk(.penTilt), [p, p.with(x: 50)])
        #expect(abs(toDegrees(d[0].angle) - 90) < 1e-3, "\(toDegrees(d[0].angle))")
        // Direction: travelling down the screen = −90° (counter-clockwise positive).
        d = dabsOf(mk(.direction), [StrokePoint(0, 0, 1), StrokePoint(0, 50, 1)])
        #expect(d.allSatisfy { abs(toDegrees($0.angle) + 90) < 1e-3 })
        var q = StrokePoint(0, 0, 1)
        q.rotation = 30
        d = dabsOf(mk(.rotation), [q, q.with(x: 20)])
        #expect(abs(toDegrees(d[0].angle) - 30) < 1e-3)
        // Pen tilt on size: upright pen full size, flat pen minimum.
        let b = with(brush()) { $0.shapeDynamics = ShapeDynamics(enabled: true, size: .controlled(.penTilt)); $0.size = 20 }
        var flat = StrokePoint(0, 0, 1)
        flat.tiltX = 90
        #expect(dabsOf(b, [flat])[0].radius <= 0.5 + 1e-6)
    }

    @Test func jitterIsDeterministicPerSeed() {
        let b = with(brush()) {
            $0.size = 30; $0.seed = 42
            $0.shapeDynamics = ShapeDynamics(enabled: true, size: .jitter(1), angle: .jitter(1), roundness: Dynamic(jitter: 1, minimum: 0.2),
                                             flipXJitter: true, flipYJitter: true)
            $0.scattering = Scattering(enabled: true, scatter: .jitter(2), bothAxes: true, count: 3, countJitter: .jitter(1))
        }
        let pts = line(0, 300, 50)
        let a = dabsOf(b, pts)
        #expect(a == dabsOf(b, pts))
        #expect(a != dabsOf(with(b) { $0.seed = 43 }, pts))
        let radii = a.map(\.radius)
        #expect(radii.contains { $0 < 10 } && radii.allSatisfy { $0 <= 15 + 1e-4 })
        #expect(a.allSatisfy { $0.roundness >= 0.2 - 1e-6 && $0.roundness <= 1 })
        #expect(a.contains { $0.flipX } && a.contains { !$0.flipX })
        // Chunked feeding gives identical dabs.
        var r = StrokeRenderer(b, format: nil).recordingDabs()
        let many = (0...30).map { StrokePoint(Double($0) * 10, 50, 1) }
        var i = 0
        while i < many.count {
            r.push(Array(many[i..<min(i + 4, many.count)]))
            i += 4
        }
        r.finish()
        #expect(r.dabs == dabsOf(b, many))
    }

    @Test func scatteringStaysInBounds() {
        for both in [false, true] {
            let b = with(brush()) { $0.size = 20; $0.scattering = Scattering(enabled: true, scatter: .jitter(2), bothAxes: both, count: 4) }
            let d = dabsOf(b, line(0, 400, 100))
            // count 4 per spacing step (5 px) → 81 steps.
            #expect(d.count == 81 * 4)
            let maxOff = 2.0 * 10.0
            #expect(d.allSatisfy { abs($0.center.y - 100) <= maxOff + 1e-6 })
            #expect(d.contains { abs($0.center.y - 100) > maxOff * 0.5 }, "scatter too small")
            if !both {
                #expect(d.allSatisfy { abs($0.center.x / 5 - ($0.center.x / 5).rounded()) < 1e-6 })
            } else {
                #expect(d.contains { abs($0.center.x / 5 - ($0.center.x / 5).rounded()) > 0.1 })
            }
        }
    }

    @Test func zeroScatterKeepsDabsOnTheStroke() {
        let on = with(brush()) { $0.scattering = Scattering(enabled: true) }
        for b in [brush(), on] {
            let d = dabsOf(b, line(10, 90, 40.5))
            #expect(d.count > 4)
            #expect(d.allSatisfy { abs($0.center.y - 40.5) < 1e-9 })
        }
    }

    @Test func colorDynamicsRanges() {
        let base = with(brush()) { $0.color = SIMD4(1, 0, 0, 1); $0.background = SIMD4(0, 0, 1, 1); $0.seed = 5 }
        // FG/BG jitter mixes between the two colours only.
        var d = dabsOf(with(base) { $0.colorDynamics = ColorDynamics(enabled: true, fgBg: .jitter(1)) }, line(0, 200, 0))
        #expect(d.allSatisfy { (abs($0.color.y) < 1e-5 && abs($0.color.x + $0.color.z - 1) < 1e-3) || max($0.color.x, $0.color.z) >= 0.999 })
        #expect(d.contains { $0.color.z > 0.5 } && d.contains { $0.color.x > 0.5 })
        // Hue jitter keeps saturation/brightness of a pure colour.
        d = dabsOf(with(base) { $0.colorDynamics = ColorDynamics(enabled: true, hueJitter: 1) }, line(0, 200, 0))
        for x in d {
            let mx = max(x.color.x, x.color.y, x.color.z), mn = min(x.color.x, x.color.y, x.color.z)
            #expect(abs(mx - 1) < 1e-4 && abs(mn) < 1e-4, "\(x.color)")
        }
        #expect(d.contains { $0.color.y > 0.5 || $0.color.z > 0.5 })
        // Purity −1 desaturates completely.
        d = dabsOf(with(base) { $0.colorDynamics = ColorDynamics(enabled: true, purity: -1) }, line(0, 20, 0))
        #expect(d.allSatisfy { abs($0.color.x - $0.color.y) < 1e-5 && abs($0.color.y - $0.color.z) < 1e-5 })
        // Per-stroke: one colour for all dabs.
        d = dabsOf(with(base) { $0.colorDynamics = ColorDynamics(enabled: true, perTip: false, hueJitter: 1) }, line(0, 200, 0))
        #expect(zip(d, d.dropFirst()).allSatisfy { $0.color == $1.color })
        // Per-tip colours land in the pixels.
        let b = with(base) { $0.size = 10; $0.spacing = 3; $0.colorDynamics = ColorDynamics(enabled: true, fgBg: .jitter(1)) }
        let s = paint(b, line(10, 310, 20))
        let colours = (0..<11).map { s.rgba(10 + Int32($0) * 30, 20) }
        #expect(colours.contains { $0.z > 0.6 } && colours.contains { $0.x > 0.6 }, "\(colours)")
    }

    @Test func transferOpacityCapsAndFlowBuilds() {
        let b = with(brush()) { $0.transfer = Transfer(enabled: true, opacity: .controlled(.penPressure)); $0.size = 10 }
        let s = paint(b, [StrokePoint(10, 10, 0.4), StrokePoint(90, 10, 0.4)])
        #expect(abs(s.rgba(50, 10).w - 0.4) < 0.01, "\(s.rgba(50, 10).w)")
        // Low flow builds up with overlap but never past the opacity.
        let b2 = with(brush()) { $0.flow = 0.1; $0.opacity = 0.8; $0.size = 10 }
        let one = paint(b2, [StrokePoint(50, 10, 1)]).rgba(50, 10).w
        let many = paint(b2, line(40, 60, 10)).rgba(50, 10).w
        #expect(abs(one - 0.08) < 0.01, "\(one)")
        #expect(many > one * 3 && many <= 0.8 + 1e-4, "\(many)")
        // Flow jitter varies the dab alpha deterministically.
        let d = dabsOf(with(brush()) { $0.transfer = Transfer(enabled: true, flow: .jitter(1)) }, line(0, 100, 0))
        #expect(d.contains { $0.alpha < 0.5 } && d.allSatisfy { $0.alpha <= 1 })
    }

    @Test func buildUpAccumulatesOverTime() {
        let b = with(brush()) { $0.buildUp = true; $0.buildUpRate = 20; $0.flow = 0.05; $0.size = 20; $0.hardness = 1 }
        func hold(_ ms: Double) -> (Int, Float) {
            let a = StrokePoint(50, 50, 1).with(time: 0), z = StrokePoint(50, 50, 1).with(time: ms)
            return (dabsOf(b, [a, z]).count, paint(b, [a, z]).rgba(50, 50).w)
        }
        let (n0, a0) = hold(0), (n1, a1) = hold(500), (n2, a2) = hold(2000)
        #expect((n0, n1, n2) == (1, 11, 41))
        #expect(a0 < a1 && a1 < a2, "\(a0) \(a1) \(a2)")
        let nb = with(b) { $0.buildUp = false }
        #expect(dabsOf(nb, [StrokePoint(50, 50, 1).with(time: 0), StrokePoint(50, 50, 1).with(time: 2000)]).count == 1)
    }

    @Test func hugeAirbrushTimeGapEmitsBoundedCatchUp() {
        let b = with(brush()) { $0.buildUp = true; $0.buildUpRate = 1000 }
        let a = StrokePoint(20, 20, 1).with(time: 0)
        #expect(dabsOf(b, [a, a.with(time: 200)]).count == 201, "a 200 ms pause should retain its airbrush build-up")
        let d = dabsOf(b, [a, a.with(time: .greatestFiniteMagnitude)])
        #expect(d.count <= 2, "a huge pause resumes with one dab: \(d.count)")
        #expect(d.last?.center == PaintPoint(20, 20))
        #expect(dabsOf(b, [a, a.with(time: .infinity)]).count <= 1)
    }

    @Test func unboundedBrushDimensionsAreSafeInThePublicRenderer() {
        let b = with(brush()) { $0.size = .greatestFiniteMagnitude; $0.dualBrush = DualBrush(enabled: true, size: .infinity) }
        let ctx = BrushContext(b)
        #expect(ctx.brush.size == maxBrushSize)
        #expect(ctx.brush.dualBrush.size == 0.5)
        #expect(dabsOf(b, [StrokePoint(10, 10, 1)]).allSatisfy { $0.radius <= maxBrushSize / 2 })
    }

    @Test func poseOverridesStylusValues() {
        let b = with(brush()) {
            $0.size = 40
            $0.pose = Pose(enabled: true, pressure: 0.5, overridePressure: true)
            $0.shapeDynamics = ShapeDynamics(enabled: true, size: .controlled(.penPressure))
        }
        #expect(dabsOf(b, line(0, 50, 0)).allSatisfy { abs($0.radius - 10) < 1e-4 })
    }

    @Test func transferWetnessAndMixVaryPerDab() throws {
        let b = with(brush()) {
            $0.transfer = Transfer(enabled: true, wetness: .controlled(.penPressure), mix: Dynamic(jitter: 1, minimum: 0.25))
        }
        let pts = [StrokePoint(0, 0, 0.3), StrokePoint(60, 0, 0.3)]
        var d = dabsOf(b, pts)
        #expect(d.allSatisfy { abs($0.wet - 0.3) < 1e-5 })
        #expect(d.allSatisfy { (0.25...1).contains($0.mix) } && d.contains { $0.mix < 0.9 })
        d = dabsOf(brush(), pts)
        #expect(d.allSatisfy { $0.wet == 1 && $0.mix == 1 })
        // New fields round-trip and old JSON loads with neutral values.
        let full = with(b) {
            $0.spacingEnabled = false
            $0.shapeDynamics = ShapeDynamics(tiltScale: 1.5, brushProjection: true)
            $0.locks = SectionLocks(texture: true)
            $0.mixer = MixerSettings(wet: 0.9, sampleAllLayers: true)
        }
        let back = try JSONDecoder().decode(BrushSettings.self, from: JSONEncoder().encode(full))
        #expect(back == full)
        let old = try JSONDecoder().decode(BrushSettings.self, from: Data(#"{"size": 12, "shapeDynamics": {"enabled": true}, "transfer": {"enabled": true}}"#.utf8))
        #expect(old.spacingEnabled && !old.shapeDynamics.brushProjection && old.shapeDynamics.tiltScale == 0 && old.locks == SectionLocks())
        #expect(old.mixer == MixerSettings())
    }
}

@Suite struct MaskTests {
    @Test func textureModulatesCoverage() {
        let tile = GrayTile(width: 8, height: 8) { x, _ in x < 4 ? 1 : 0 }
        func tex(_ mode: MaskMode, _ depth: Float, _ eachTip: Bool) -> BrushSettings {
            with(brush()) { $0.size = 40; $0.texture = Texture(enabled: true, pattern: .tile(tile), eachTip: eachTip, mode: mode, depth: depth) }
        }
        for eachTip in [false, true] {
            let s = paint(tex(.multiply, 1, eachTip), line(20, 80, 30))
            #expect(s.rgba(46, 30).w < 0.1, "dark texel blocks paint")
            #expect(s.rgba(41, 30).w > 0.9, "light texel passes")
            let v = paint(tex(.multiply, 0.5, eachTip), line(20, 80, 30)).rgba(46, 30).w
            if eachTip { #expect(v > 0.5 && v < 1, "\(v)") } else { #expect(abs(v - 0.5) < 0.02, "\(v)") }
        }
        var b = tex(.multiply, 1, false)
        b.texture.invert = true
        var s = paint(b, line(20, 80, 30))
        #expect(s.rgba(46, 30).w > 0.9 && s.rgba(41, 30).w < 0.1)
        b.texture.invert = false
        b.texture.brightness = 1
        s = paint(b, line(20, 80, 30))
        // +150 lifts a black texel by 150 levels of 255, not to white (#3340).
        let lifted = s.rgba(46, 30).w
        #expect(abs(lifted - 150 / 255) < 0.02, "\(lifted)")
        for m in MaskMode.allCases {
            for t: Float in [0, 0.3, 1] {
                #expect(maskCombine(m, 0, t, 1) == 0, "\(m)")
                #expect((0...1).contains(maskCombine(m, 0.7, t, 0.8)), "\(m)")
                #expect(textureCombine(m, 0, t, 1) == 0, "\(m)")
                #expect((0...1).contains(textureCombine(m, 0.7, t, 0.8)), "\(m)")
            }
            #expect((0...1).contains(textureCombine(m, 0.7, .nan, .infinity)), "\(m)")
            #expect(maskCombine(m, 0.6, 1, 1) >= 0.6 - 1e-5 || m == .overlay, "\(m)")
        }
        var bj = tex(.multiply, 0.8, true)
        bj.texture.depthJitter = Dynamic(jitter: 1, minimum: 0.25)
        let d = dabsOf(bj, line(0, 200, 0))
        #expect(d.allSatisfy { $0.depth <= 0.8 + 1e-6 && $0.depth >= 0.8 * 0.25 - 1e-6 })
        #expect(d.contains { $0.depth < 0.6 })
    }

    /// Texture Brightness and Contrast as Photoshop applies them (#3340).
    @Test func textureBrightnessAndContrastMatchPhotoshop() {
        func level(_ brightness: Float, _ contrast: Float, _ invert: Bool, _ v: Float) -> Float {
            let c = contrast < 0 ? contrast / 50 : contrast / 100
            return Texture(invert: invert, brightness: brightness / 150, contrast: c).level(v / 255) * 255
        }
        let cases: [(Float, Float, Bool, Float, Float)] = [
            (87, 0, false, 8, 95), (87, 0, false, 200, 255), (-87, 0, false, 104, 17), (150, 0, false, 8, 158),
            (0, 50, false, 104, 81), (0, 50, false, 136, 145), (0, -50, false, 8, 67), (0, -50, false, 248, 188),
            (0, 100, false, 120, 0), (0, 100, false, 136, 255),
            (40, 50, false, 104, 161), (40, 50, false, 40, 33), (-40, -30, false, 120, 82), (-40, -30, false, 248, 172),
            (40, 0, true, 8, 207), (0, 50, true, 72, 238),
        ]
        for (b, c, inv, v, want) in cases {
            let got = level(b, c, inv, v)
            #expect(abs(got - want) <= 2, "brightness \(b), contrast \(c), invert \(inv), ramp \(v): \(got) (Photoshop \(want))")
        }
    }

    /// The Texture modes that differ from the Dual Brush's, against single Photoshop dabs (#3340).
    @Test func textureModesMatchPhotoshop() {
        let cases: [(MaskMode, Float, Float, Float, Float)] = [
            (.height, 0, 255, 8, 0), (.height, 0.01, 255, 8, 28), (.height, 0.05, 255, 8, 148), (.height, 0.05, 255, 136, 20),
            (.height, 0.13, 255, 8, 255), (.height, 0.13, 255, 152, 244), (.height, 0.13, 255, 248, 148), (.height, 0.13, 186, 88, 201),
            (.height, 0.13, 142, 104, 116), (.height, 0.25, 255, 248, 255),
            (.linearHeight, 0.01, 255, 152, 15), (.linearHeight, 0.05, 255, 8, 151), (.linearHeight, 0.05, 255, 152, 63),
            (.linearHeight, 0.10, 255, 72, 240), (.linearHeight, 0.13, 101, 120, 82), (.linearHeight, 0.13, 142, 104, 130),
            (.subtract, 1, 255, 8, 247), (.subtract, 1, 255, 248, 7), (.subtract, 0.5, 224, 72, 188),
            (.colorBurn, 0.5, 224, 72, 207), (.colorDodge, 0.5, 99, 120, 130),
            (.multiply, 0.13, 255, 8, 223), (.darken, 0.5, 255, 8, 131),
        ]
        for (m, d, v, t, want) in cases {
            let got = textureCombine(m, v / 255, t / 255, d) * 255
            #expect(abs(got - want) <= 3, "\(m) depth \(d), coverage \(v), ramp \(t): \(got) (Photoshop \(want))")
        }
    }

    /// #3340: an imported Height-mode brush at a low depth with a darkened pattern painted nothing.
    @Test func lowDepthHeightTexturePaints() {
        let tile = GrayTile(width: 8, height: 8) { x, y in (x + y) % 2 == 0 ? 0.45 : 0.6 }
        for mode in [MaskMode.height, .linearHeight] {
            let b = with(brush()) {
                $0.size = 40
                $0.texture = Texture(enabled: true, pattern: .tile(tile), brightness: -87 / 150, mode: mode, depth: 0.13)
            }
            let a = paint(b, line(20, 80, 30)).rgba(50, 30).w
            #expect(a > 0.95, "\(mode): \(a)")
        }
    }

    @Test func dualBrushIntersects() {
        let b = with(brush()) { $0.size = 30; $0.dualBrush = DualBrush(enabled: true, size: 6, hardness: 1, spacing: 5) }
        var s = paint(b, line(20, 200, 30))
        // Dual dabs every 30 px starting at x = 20.
        #expect(s.rgba(20, 30).w > 0.9 && s.rgba(50, 30).w > 0.9)
        #expect(s.rgba(35, 30).w < 0.01, "between dual dabs: \(s.rgba(35, 30).w)")
        #expect(s.rgba(20, 50).w == 0)
        s = paint(with(b) { $0.dualBrush = DualBrush() }, line(20, 200, 30))
        #expect(s.rgba(35, 30).w > 0.9)
    }

    @Test func wetEdgesShapeTheStrokeNotEachDab() {
        // #2088: Wet Edges darkens the rim of the whole stroke.
        let b = with(brush()) { $0.size = 40; $0.hardness = 0.8; $0.wetEdges = true }
        let s = paint(b, line(20, 220, 50))
        let centre = (60..<180).map { s.rgba(Int32($0), 50).w }
        let lo = centre.min()!, hi = centre.max()!
        #expect(hi - lo < 0.02, "centre line is even: \(lo)…\(hi)")
        #expect(hi < 0.6, "wet interior is lighter: \(hi)")
        for x: Int32 in [80, 120, 160] {
            let side = s.rgba(x, 50 + 16).w
            #expect(side > hi + 0.15, "the side at x=\(x) is darker than the centre: \(side) vs \(hi)")
        }
    }

    @Test func wetEdgesAndNoise() {
        let b = with(brush()) { $0.size = 40; $0.hardness = 0; $0.wetEdges = true }
        let centre = paint(b, line(20, 120, 50)).rgba(70, 50).w
        #expect(centre < 0.6, "wet interior is lighter: \(centre)")
        let single = paint(b, [StrokePoint(70, 50, 1)]).rgba(70, 50).w
        #expect(abs(centre - single) < 0.05, "\(centre) vs \(single)")
        let d = paint(with(b) { $0.hardness = 1 }, [StrokePoint(50, 50, 1)])
        #expect(d.rgba(50 + 18, 50).w > d.rgba(50, 50).w + 0.2)
        let soft = with(brush()) { $0.size = 40; $0.hardness = 0 }
        let a = paint(soft, [StrokePoint(50, 50, 1)])
        let n = paint(with(soft) { $0.noise = true }, [StrokePoint(50, 50, 1)])
        func extreme(_ s: Surface) -> Int {
            var c = 0
            for y: Int32 in 30..<70 { for x: Int32 in 30..<70 where !(0.15...0.85).contains(s.rgba(x, y).w) { c += 1 } }
            return c
        }
        #expect(extreme(n) > extreme(a) + 100, "\(extreme(n)) vs \(extreme(a))")
    }
}

@Suite struct SmoothingTests {
    @Test func smoothingModes() {
        let zig = (0..<40).map { StrokePoint(Double($0) * 5, $0 % 2 == 0 ? 0 : 6, 1) }
        func dev(_ pts: ArraySlice<StrokePoint>) -> Double { pts.map { abs($0.y - 3) }.reduce(0, +) / Double(pts.count) }
        let cfg = Smoothing(amount: 0.8)
        let sm = smoothPoints(cfg, zoom: 1, zig)
        #expect(dev(sm[5..<(sm.count - 1)]) < dev(zig[...]) * 0.5)
        #expect(sm.last!.x == zig.last!.x && sm.last!.y == zig.last!.y)
        var c2 = cfg
        c2.catchUpOnEnd = false
        #expect(smoothPoints(c2, zoom: 1, zig).last!.x < zig.last!.x - 1)
        // Pulled string: jitter smaller than the string moves nothing; the brush trails by the string.
        let ps = Smoothing(amount: 0.2, pulledString: true, catchUpOnEnd: false)
        let jitter = (0..<20).map { StrokePoint($0 % 2 == 0 ? 0 : 5, 0, 1) }
        #expect(smoothPoints(ps, zoom: 1, jitter).count == 1, "within the 60 px string (300 px at 100 %, photocraft #11888): no motion")
        var far = smoothPoints(ps, zoom: 1, [StrokePoint(0, 0, 1), StrokePoint(100, 0, 1)])
        #expect(abs(far.last!.x - 40) < 1e-4)
        far = smoothPoints(ps, zoom: 2, [StrokePoint(0, 0, 1), StrokePoint(100, 0, 1)])
        #expect(abs(far.last!.x - 70) < 1e-4)
        // Stroke catch-up: a pause (timestamps) lets the brush converge on the pointer.
        let a = StrokePoint(0, 0, 1).with(time: 0)
        let b = a.with(x: 100, time: 16)
        // the measured lag (photocraft #11888) needs a longer pause than the old pull did
        let c = b.with(time: 1000)
        let d = b.with(time: 2000)
        var s = Smoother(Smoothing(amount: 0.8, catchUp: true, catchUpOnEnd: false), zoom: 1)
        var out: [StrokePoint] = []
        for p in [a, b, c, d] { s.push(p, &out) }
        #expect(out.last!.x > 99, "\(out.last!.x)")
        s = Smoother(Smoothing(amount: 0.8, catchUp: false, catchUpOnEnd: false), zoom: 1)
        out = []
        for p in [a, b, c, d] { s.push(p, &out) }
        #expect(out.last!.x < 70, "\(out.last!.x)")
    }

    @Test func smoothingStringRunsFromTheLaggingBrushToThePointer() {
        let cfg = Smoothing(amount: 0.8)
        var s = Smoother(cfg, zoom: 1)
        var out: [StrokePoint] = []
        #expect(s.string == nil, "no stroke yet")
        s.push(StrokePoint(0, 0, 1), &out)
        #expect(s.string == nil, "the first point is the brush")
        s.push(StrokePoint(100, 0, 1), &out)
        let (b, p) = s.string!
        #expect(b.x > 0 && b.x < 100, "the brush lags: \(b)")
        #expect(p == SIMD2(100, 0))
        var off = Smoother(Smoothing(amount: 0), zoom: 1)
        off.push(StrokePoint(0, 0, 1), &out)
        off.push(StrokePoint(100, 0, 1), &out)
        #expect(off.string == nil, "smoothing off: no string")
    }

    @Test func smoothingPullsByTimeNotByHowOftenTheDeviceReports() {
        let cfg = Smoothing(amount: 0.8, catchUp: true, catchUpOnEnd: false)
        func run(_ interval: Double) -> Double {
            var s = Smoother(cfg, zoom: 1)
            var out: [StrokePoint] = []
            s.push(StrokePoint(0, 0, 1), &out)
            var t = 0.0
            while t < 32 {
                t += interval
                s.push(StrokePoint(100, 0, 1).with(time: t), &out)
            }
            return out.last?.x ?? 0
        }
        let fast = run(1), slow = run(16)
        // Two 16 ms steps of one step's pull `a`: 1 − (1 − a)² of the way (photocraft #11888).
        let a = smoothingPull(0.8)
        #expect(abs(slow - 100 * (1 - (1 - a) * (1 - a))) < 1e-4, "\(slow)")
        #expect(abs(fast - slow) < 1e-4, "1000 Hz \(fast) vs 60 Hz \(slow)")
        var s = Smoother(cfg, zoom: 1)
        var out: [StrokePoint] = []
        // without timestamps: one step per point with the pull it always had (photocraft e9a204f96)
        for x in [0.0, 100] { s.push(StrokePoint(x, 0, 1), &out) }
        #expect(abs((out.last?.x ?? 0) - 20) < 1e-4)
    }

    @Test func smoothingWithoutCatchUpStopsWhileThePointerPauses() {
        var s = Smoother(Smoothing(amount: 0.8, catchUp: false, catchUpOnEnd: false), zoom: 1)
        var out: [StrokePoint] = []
        s.push(StrokePoint(0, 0, 1), &out)
        s.push(StrokePoint(100, 0, 1).with(time: 16), &out)
        let n = out.count
        for t in [32.0, 48, 64] { s.push(StrokePoint(100, 0, 1).with(time: t), &out) }
        #expect(out.count == n, "held still: the brush doesn't move")
    }
}

@Suite struct StrokeRenderingTests {
    @Test func chunkedRenderingMatchesOneShot() {
        let b = with(brush()) {
            $0.size = 24; $0.seed = 9
            $0.shapeDynamics = ShapeDynamics(enabled: true, size: .jitter(0.5), angle: .jitter(1))
            $0.scattering = Scattering(enabled: true, scatter: .jitter(1), bothAxes: true, count: 2)
            $0.texture = Texture(enabled: true, depth: 0.5)
            $0.colorDynamics = ColorDynamics(enabled: true, hueJitter: 0.5)
            $0.color = SIMD4(1, 0, 0, 1)
        }
        let pts = (0..<60).map { StrokePoint(20 + Double($0) * 4, 60 + sin(Double($0) * 0.3) * 30, 1) }
        var one = Surface(format: .rgba8)
        let d1 = renderStroke(&one, b, pts)
        var inc = Surface(format: .rgba8)
        let pre = inc
        var r = StrokeRenderer(b, format: inc.format)
        var i = 0
        while i < pts.count {
            r.push(Array(pts[i..<min(i + 7, pts.count)]))
            r.composite(pre: pre, target: &inc, all: false)
            i += 7
        }
        r.finish()
        r.composite(pre: pre, target: &inc, all: false)
        #expect(d1 == r.bounds)
        #expect(one.readRegion(d1) == inc.readRegion(d1))
    }

    @Test func paintsEveryDepthAndModel() {
        let b = with(brush()) { $0.size = 8; $0.color = SIMD4(1, 0, 0, 1) }
        for mode in [ColorMode.rgb, .grayscale, .cmyk] {
            for sample in [SampleType.u8, .u16, .f32] {
                for alpha in [true, false] {
                    let fmt = PixelFormat.make(mode, sample, alpha)
                    var s = Surface(format: fmt, defaultPixel: fromRGBA(fmt, SIMD4(1, 1, 1, 1)))
                    let fancy = with(b) {
                        $0.shapeDynamics = ShapeDynamics(enabled: true, size: .jitter(0.3))
                        $0.colorDynamics = ColorDynamics(enabled: true, brightnessJitter: 0.1)
                        $0.texture = Texture(enabled: true, depth: 0.2)
                    }
                    for br in [b, fancy] { renderStroke(&s, br, line(5, 40, 5)) }
                    let c = s.rgba(20, 5)
                    let expect = toRGBA(fmt, fromRGBA(fmt, SIMD4(1, 0, 0, 1)))
                    #expect(abs(c.x - expect.x) < 0.15 && abs(c.y - expect.y) < 0.12, "\(fmt) \(c) vs \(expect)")
                    #expect(s.pixel(x: 20, y: 30) == s.pixel(x: 5000, y: 5000), "\(fmt) untouched")
                }
            }
        }
    }

    @Test func blendModeAndDissolve() {
        var s = Surface(format: .rgba32f)
        s.fillRect(PixelRect(x0: 0, y0: 0, x1: 100, y1: 20), [0.5, 0.5, 0.5, 1])
        renderStroke(&s, with(brush()) { $0.size = 10; $0.color = SIMD4(0.5, 0.5, 0.5, 1); $0.mode = .multiply }, line(10, 90, 10))
        #expect(abs(s.rgba(50, 10).x - 0.25) < 1e-4)
        var d = Surface(format: .rgba32f)
        renderStroke(&d, with(brush()) { $0.size = 30; $0.opacity = 0.5; $0.mode = .dissolve }, line(20, 80, 20))
        let vals = (30..<70).map { d.rgba(Int32($0), 20).w }
        #expect(vals.allSatisfy { $0 == 0 || $0 == 1 } && vals.contains(0) && vals.contains(1))
    }

    @Test func presetsRenderAndRoundTrip() throws {
        let presets = BrushPresets.builtin()
        #expect(presets.count >= 12)
        for p in presets {
            let back = try JSONDecoder().decode(BrushPreset.self, from: JSONEncoder().encode(p))
            #expect(back == p, "\(p.name)")
            var s = Surface(format: .rgba8)
            let pts = (0..<20).map { StrokePoint(40 + Double($0) * 8, 60, 0.8).with(time: Double($0) * 16) }
            let dmg = renderStroke(&s, p.brush, pts)
            #expect(!dmg.isEmpty, "\(p.name)")
            #expect(alphaSum(s, dmg) > 10, "\(p.name) painted nothing")
        }
        // Partial JSON fills defaults (and accepts the snake_case alias).
        let b = try JSONDecoder().decode(BrushSettings.self,
                                         from: Data(#"{"size": 50, "scattering": {"enabled": true, "scatter": {"jitter": 2}}, "pressure_size": false}"#.utf8))
        #expect(b.size == 50)
        #expect(b.scattering.enabled && b.scattering.count == 1 && !b.pressureSize)
        #expect(b.hardness == 1)
        // photocraft's blend-mode names.
        let m = try JSONDecoder().decode(BrushSettings.self, from: Data(#"{"mode": "LinearDodge"}"#.utf8))
        #expect(m.mode == .linearDodge)
        let j = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as! [String: Any]
        #expect(j["mode"] as? String == "LinearDodge")
        #expect(j["square"] == nil, "square is omitted when off")
    }

    @Test func protectTextureKeepsPattern() {
        let presets = BrushPresets.builtin()
        let chalk = BrushPresets.find(presets, "chalk")!.brush
        let canvas = BrushPresets.find(presets, "Canvas Texture")!.brush
        let cur = with(chalk) { $0.protectTexture = true }
        let next = canvas.withProtectedTexture(cur)
        #expect(next.texture.pattern == chalk.texture.pattern)
        #expect(next.texture.mode == canvas.texture.mode)
        #expect(canvas.withProtectedTexture(chalk).texture.pattern == canvas.texture.pattern)
    }

    @Test func lockedSectionsSurvivePickingAPreset() {
        let chalk = BrushPresets.find(BrushPresets.builtin(), "chalk")!.brush
        var cur = with(brush()) {
            $0.scattering = Scattering(enabled: true, count: 5)
            $0.transfer = Transfer(enabled: true, wetness: .jitter(0.4))
            $0.noise = true
        }
        var next = chalk.pickedOver(cur)
        #expect(next.scattering == chalk.scattering)
        #expect(next.noise == chalk.noise)
        cur.locks = SectionLocks(scattering: true, transfer: true, noise: true)
        next = chalk.pickedOver(cur)
        #expect(next.scattering == cur.scattering)
        #expect(next.transfer == cur.transfer)
        #expect(next.noise)
        #expect(next.locks == cur.locks)
        #expect(next.texture == chalk.texture)
        #expect(next.tip == chalk.tip)
    }

    @Test func tailPreviewShowsTheStrokeAsFinishingItWould() {
        let fmt = PixelFormat.make(.rgb, .u16, true)
        let b = with(brush()) { $0.size = 9; $0.smoothing = Smoothing(amount: 0.7) }
        let pts = (0..<12).map { StrokePoint(5 + Double($0) * 9, 20 + Double($0 % 3) * 7, 1) }
        let pre = Surface(format: fmt)
        var live = pre
        var r = StrokeRenderer(b, format: fmt)
        r.push(pts)
        r.composite(pre: pre, target: &live, all: false)
        var tail = r.tailPreview()!
        tail.composite(pre: pre, target: &live, all: false)
        var done = pre
        renderStroke(&done, b, pts)
        let area = PixelRect(x0: 0, y0: 0, x1: 120, y1: 60)
        #expect(live.readRegion(area) == done.readRegion(area))
        var r2 = StrokeRenderer(brush(), format: fmt)
        r2.push(pts)
        #expect(r2.tailPreview() == nil)
    }

    @Test(arguments: [SampleType.u8, .u16, .f32])
    func liveUnionOfPassesMatchesMergingTheFinishedPassesAfterEveryChunk(sample: SampleType) {
        let base = with(brush()) { $0.size = 14; $0.hardness = 0.6; $0.opacity = 0.6 }
        var brushes = [base, with(base) { $0.smoothing = Smoothing(amount: 0.7) }]
        brushes.append(with(base) { $0.dualBrush.enabled = true; $0.dualBrush.size = 6; $0.dualBrush.scatter = 1.5 })
        brushes.append(with(base) { $0.colorDynamics.enabled = true; $0.colorDynamics.hueJitter = 0.5 })
        brushes.append(with(base) { $0.wetEdges = true })
        brushes.append(with(base) { $0.mode = .dissolve })
        brushes.append(with(base) { $0.erase = true })
        brushes.append(with(base) { $0.texture.enabled = true; $0.texture.eachTip = false })
        let strokePts = (0..<40).map { StrokePoint(30 + Double($0) * 3.7, 40 + 25 * sin(Double($0) / 5), 1) }
        func mirror(_ fx: Bool, _ fy: Bool) -> [StrokePoint] {
            strokePts.map { StrokePoint(fx ? 200 - $0.x : $0.x, fy ? 150 - $0.y : $0.y, $0.pressure) }
        }
        let paths = [strokePts, mirror(true, false), mirror(false, true), mirror(true, true)]
        let area = PixelRect(x0: -20, y0: -20, x1: 240, y1: 190)
        var sel = Surface(format: .gray32f)
        let selRect = PixelRect(x0: 0, y0: 0, x1: 160, y1: 120)
        sel.writeRegion(selRect, (0..<(160 * 120)).map { min(Float($0 % 160) / 120, 1) })
        do {
            let fmt = PixelFormat.make(.rgb, sample, true)
            var pre = Surface(format: fmt)
            let fill = PixelRect(x0: 10, y0: 10, x1: 190, y1: 140)
            let n = fmt.channels
            var px: [Float] = []
            for i in 0..<fill.area { px.append(contentsOf: [Float(i % 7) / 7, 0.5, Float(i % 13) / 13, 0.8].prefix(n)) }
            pre.writeRegion(fill, px)
            for (bi, b) in brushes.enumerated() {
                for (four, selection) in [(false, nil), (true, nil), (true, sel)] as [(Bool, Surface?)] {
                    var renderers = (0..<4).map { _ in StrokeRenderer(b, format: fmt) }
                    var live = UnionLive()
                    var target = pre
                    var atI = 0, chunk = 1, merged = 0
                    while atI < strokePts.count {
                        let end = min(atI + chunk, strokePts.count)
                        for k in 0..<4 { renderers[k].push(Array(paths[k][atI..<end])) }
                        let count = four && atI >= 12 ? 4 : 2
                        let full = merged != count
                        merged = count
                        var passes = Array(renderers.prefix(count))
                        StrokeRenderer.compositeUnionLive(&passes, live: &live, full: full, pre: pre, target: &target, selection: selection)
                        for k in 0..<count { renderers[k] = passes[k] }
                        let finished = renderers.prefix(count).map { r -> StrokeRenderer in
                            var r = r
                            r.finish()
                            return r
                        }
                        var expected = pre
                        finished[0].compositeUnionMany(Array(finished.dropFirst()), pre: pre, target: &expected, selection: selection)
                        let ok = target.readRegion(area) == expected.readRegion(area)
                        #expect(ok, "\(sample), brush \(bi), four \(four), selection \(selection != nil), points ..\(end)")
                        #expect(live.bounds == finished.reduce(PixelRect.empty) { $0.union($1.bounds) })
                        if !ok { break }
                        atI = end
                        chunk = chunk % 3 + 1
                    }
                }
            }
        }
    }
}

@Suite struct GeometryTests {
    func extents(_ b: BrushSettings, _ d: Dab) -> (Int, Int) {
        let r = raster(b, d)
        let cx = Int32(d.center.x.rounded(.down)), cy = Int32(d.center.y.rounded(.down))
        let w = (r.0.x0..<r.0.x1).filter { at(r, $0, cy) > 0.5 }.count
        let h = (r.0.y0..<r.0.y1).filter { at(r, cx, $0) > 0.5 }.count
        return (w, h)
    }

    @Test func tiltScaleSquashesTheTipHeightWithPenTilt() {
        func mk(_ scale: Float) -> BrushSettings {
            with(brush()) { $0.size = 40; $0.shapeDynamics = ShapeDynamics(enabled: true, size: Dynamic(control: .penTilt, minimum: 1), tiltScale: scale) }
        }
        let upright = [pen(50, 50, 0, 0, 0)], tilted = [pen(50, 50, 45, 0, 0)]
        #expect(dabsOf(mk(0), tilted)[0].roundness == 1)
        #expect(dabsOf(mk(2), upright)[0].roundness == 1)
        let d = dabsOf(mk(1), tilted)[0]
        #expect(abs(d.roundness - 0.75) < 1e-4, "\(d.roundness)")
        let d2 = dabsOf(mk(2), tilted)[0]
        #expect(abs(d2.roundness - 0.5) < 1e-4, "\(d2.roundness)")
        let (w, h) = extents(mk(2), d2)
        #expect(w >= 38 && abs(h - 20) <= 2, "\(w)×\(h)")
        var b = mk(2)
        b.shapeDynamics.size.control = .penPressure
        #expect(dabsOf(b, tilted)[0].roundness == 1)
        let a = paint(mk(0), [pen(20, 40, 60, 0, 0), pen(120, 40, 60, 0, 0)])
        let c = paint(mk(2), [pen(20, 40, 60, 0, 0), pen(120, 40, 60, 0, 0)])
        let area = PixelRect(x0: 0, y0: 0, x1: 160, y1: 80)
        #expect(alphaSum(c, area) < alphaSum(a, area) * 0.75)
    }

    @Test func brushProjectionForeshortensAlongTiltAndTurnsWithRotation() {
        func mk(_ on: Bool) -> BrushSettings { with(brush()) { $0.size = 40; $0.shapeDynamics = ShapeDynamics(enabled: true, brushProjection: on) } }
        let pts = [pen(50, 50, 60, 0, 0)]
        var d = dabsOf(mk(true), pts)[0]
        #expect(abs(d.projScale - 0.5) < 1e-4 && abs(d.projAngle) < 1e-5, "\(d)")
        var (w, h) = extents(mk(true), d)
        #expect(abs(w - 20) <= 2 && h >= 38, "\(w)×\(h)")
        d = dabsOf(mk(true), [pen(50, 50, 0, 60, 0)])[0]
        (w, h) = extents(mk(true), d)
        #expect(w >= 38 && abs(h - 20) <= 2, "\(w)×\(h)")
        d = dabsOf(mk(false), pts)[0]
        #expect(d.projScale == 1 && d.angle == 0)
        #expect(extents(mk(false), d) == (40, 40))
        var b = mk(true)
        b.roundness = 0.5
        d = dabsOf(b, [pen(50, 50, 0, 0, 90)])[0]
        #expect(abs(toDegrees(d.angle) - 90) < 1e-3)
        (w, h) = extents(b, d)
        #expect(w < h, "\(w)×\(h)")
        // Dual-brush dabs are never projected.
        let ctx = BrushContext(mk(true))
        var dd = Dab.round(PaintPoint(50, 50), 20, 1)
        dd.projScale = 0.3
        let r = ctx.dabRect(dd, dual: true)
        var a: [Float] = [], c: [Float] = []
        ctx.rasterize(dd, dual: true, rect: r, &a)
        dd.projScale = 1
        ctx.rasterize(dd, dual: true, rect: r, &c)
        #expect(a == c)
    }

    func allDabs(_ b: BrushSettings, _ pts: [StrokePoint]) -> ([Dab], [Dab]) {
        var g = DabGenerator(brush: b, zoom: 1)
        var d: [Dab] = [], du: [Dab] = []
        g.push(pts, &d, &du)
        g.finish(&d, &du)
        return (d, du)
    }

    /// #977: Scatter far beyond 1000 % (or non-finite) is capped; dabs stay finite and renders work.
    @Test func hugeScatterIsCappedAndRendersAtEveryDepth() {
        let pts = line(10, 40, 10)
        func withScatter(_ j: Float) -> BrushSettings {
            with(brush()) {
                $0.size = 20
                $0.scattering = Scattering(enabled: true, scatter: .jitter(j), bothAxes: true, count: 4)
                $0.dualBrush = DualBrush(enabled: true, size: 6, scatter: j, bothAxes: true)
            }
        }
        let capped = allDabs(withScatter(maxScatter), pts)
        func near(_ ds: [Dab], _ r: Double) -> Bool { ds.allSatisfy { abs($0.center.x - 25) <= 15 + r && abs($0.center.y - 10) <= r } }
        #expect(near(capped.0, Double(maxScatter) * 10) && near(capped.1, Double(maxScatter) * 3))
        for j in [maxScatter + 0.01, 1e6, 1e38, .greatestFiniteMagnitude, .infinity] {
            let b = withScatter(j)
            let got = allDabs(b, pts)
            #expect(got.0 == capped.0 && got.1 == capped.1, "scatter \(j) paints like the maximum")
            let ctx = BrushContext(b)
            for d in capped.0 {
                let r = ctx.dabRect(d, dual: false)
                #expect(!r.isEmpty && r.width <= 24 && r.height <= 24, "\(r)")
            }
            for sample in [SampleType.u8, .u16, .f32] {
                var s = Surface(format: .make(.rgb, sample, true))
                let dmg = renderStroke(&s, b, pts)
                #expect(!dmg.isEmpty && dmg.x0 > -200 && dmg.x1 < 250, "scatter \(j) at \(sample): \(dmg)")
            }
        }
        let none = allDabs(withScatter(0), pts)
        let nan = allDabs(withScatter(.nan), pts)
        #expect(nan.0 == none.0 && nan.1 == none.1)
        #expect(none.0.allSatisfy { $0.center.y == 10 })
    }

    @Test func ordinaryScatterIsUnchangedByTheCap() {
        let b = with(brush()) {
            $0.size = 20
            $0.scattering = Scattering(enabled: true, scatter: .jitter(2), bothAxes: true, count: 3)
            $0.dualBrush = DualBrush(enabled: true, size: 6, scatter: 1.5, bothAxes: true)
        }
        #expect(b.boundedForRender() == b)
        let (d, du) = allDabs(b, line(10, 200, 50))
        #expect(d.contains { abs($0.center.y - 50) > 10 } && d.allSatisfy { abs($0.center.y - 50) <= 20 })
        #expect(du.contains { abs($0.center.y - 50) > 1 } && du.allSatisfy { abs($0.center.y - 50) <= 4.5 })
    }

    @Test func dabRectOfAFarOrNonFiniteCentreDoesNotOverflow() {
        let ctx = BrushContext(brush())
        for c in [Double.infinity, -.infinity, .nan, 1e300, -1e300, Double(Int32.max), Double(Int32.min)] {
            let d = Dab.round(PaintPoint(c, c), 10, 1)
            for r in [ctx.dabRect(d, dual: false), ctx.dabRect(d, dual: true), Retouch.dabRect(d)] {
                #expect(r.x0 <= r.x1 && r.y0 <= r.y1, "centre \(c): \(r)")
            }
        }
        let r = Retouch.dabRect(Dab.round(PaintPoint(5, 5), .infinity, 1))
        #expect(r.x0 <= r.x1 && r.y0 <= r.y1, "\(r)")
    }

    func crossSection(_ b: BrushSettings, _ pts: [StrokePoint], _ x: Int32) -> [Float] {
        var s = Surface(format: .make(.rgb, .f32, true))
        renderStroke(&s, b, pts)
        return (100..<170).map { s.rgba(x, Int32($0)).w }
    }

    func softEdgeWidth(_ p: [Float]) -> Int {
        func below(_ v: Float) -> Int { p.firstIndex { $0 < v } ?? p.count }
        return max(below(0.1) - below(0.9), 0)
    }

    @Test func aSoftStrokeKeepsMostOfItsTipsSoftness() {
        let b = with(BrushSettings()) { $0.size = 100; $0.hardness = 0; $0.pressureSize = false }
        let s = softEdgeWidth(crossSection(b, line(0, 400, 100.5), 200))
        let d = softEdgeWidth(crossSection(b, [StrokePoint(200.5, 100.5, 1)], 200))
        #expect(d >= 20 && s * 100 >= d * 65, "stroke soft edge \(s) px vs tip \(d) px")
    }

    @Test func aTinyDabsCoverageDoesNotDependOnWhereItLandsInAPixel() {
        func total(_ x: Double, _ y: Double) -> Float {
            let b = with(BrushSettings()) { $0.size = 1; $0.hardness = 1; $0.pressureSize = false }
            var s = Surface(format: .make(.rgb, .f32, true))
            renderStroke(&s, b, [StrokePoint(x, y, 1)])
            var t: Float = 0
            for py: Int32 in 0..<10 { for px: Int32 in 0..<10 { t += s.rgba(px, py).w } }
            return t
        }
        let sums = [(5.5, 5.5), (5.75, 5.5), (5.0, 5.0), (5.3, 5.8)].map { total($0.0, $0.1) }
        #expect(sums.max()! - sums.min()! < 0.03 * sums.max()!, "\(sums)")
    }

    @Test func theTipFallsOffFromTheHardCoreToZeroAtTheEdge() {
        #expect(tipFalloff(0, 10, 0) == 1)
        #expect(tipFalloff(10, 10, 0) == 0)
        #expect(tipFalloff(4, 10, 0.5) == 1, "inside the hard core")
        let v = (0...20).map { tipFalloff(Float($0) * 0.5, 10, 0) }
        #expect(zip(v, v.dropFirst()).allSatisfy { $1 <= $0 })
        let e: Float = 0.75 * 0.75 * 0.75 * 0.75
        #expect(abs(tipFalloff(5, 10, 0) - e) < 1e-6)
    }

    @Test func halfCoverageRadiusIsTheTips50PercentContour() {
        for h: Float in [0, 0.25, 0.5, 0.75, 0.99] {
            let d = halfCoverageRadius(10.5, h)
            #expect(abs(tipFalloff(d, 10.5, h) - 0.5) < 1e-3, "hardness \(h): ring at \(d)")
        }
        #expect(halfCoverageRadius(10.5, 1) == 10.5)
        #expect(halfCoverageRadius(10.5, .nan).isFinite)
    }
}

@Suite struct DitherTests {
    func softLowFlow(_ fmt: PixelFormat) -> Surface {
        var s = Surface(format: fmt, defaultPixel: [1, 1, 1, 1])
        let b = with(BrushSettings()) { $0.size = 120; $0.hardness = 0; $0.flow = 0.05; $0.opacity = 0.3; $0.color = SIMD4(0, 0, 0, 1); $0.pressureSize = false }
        renderStroke(&s, b, line(0, 300, 100))
        return s
    }

    func worstRowError(_ got: Surface, _ want: Surface) -> Float {
        var worst: Float = 0
        for y: Int32 in 30..<170 {
            var g: Float = 0, w: Float = 0
            for x: Int32 in 100..<200 { g += got.rgba(x, y).x; w += want.rgba(x, y).x }
            worst = max(worst, abs(g - w) / 100 * 255)
        }
        return worst
    }

    @Test func an8bitSoftStrokeIsDitheredInsteadOfBanded() {
        let err = worstRowError(softLowFlow(.rgba8), softLowFlow(.make(.rgb, .f32, true)))
        #expect(err < 0.15, "row averages are \(err) levels off the float render")
    }

    @Test func ditheringNeverMovesAnExactColourOrAnUntouchedPixel() {
        var s = Surface(format: .rgba8, defaultPixel: [1, 1, 1, 1])
        let b = with(BrushSettings()) { $0.size = 20; $0.hardness = 1; $0.color = SIMD4(0.2, 0.4, 0.6, 1); $0.pressureSize = false }
        renderStroke(&s, b, line(10, 90, 50))
        func q(_ v: Float) -> Int { Int((v * 255).rounded()) }
        for x: Int32 in 15..<85 {
            let p = s.rgba(x, 50)
            #expect(q(p.x) == q(0.2) && q(p.y) == q(0.4) && q(p.z) == q(0.6), "solid paint at x \(x): \(p)")
        }
        #expect(s.rgba(50, 5) == SIMD4(1, 1, 1, 1), "far from the stroke: untouched")
    }
}
