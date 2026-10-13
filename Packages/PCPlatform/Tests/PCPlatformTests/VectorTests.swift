// Ports the intent of photocraft-vector's tests (crates/vector/src/tests.rs, shapes.rs tests) onto
// CoreGraphics over PCDocument's model: exact areas, path operations, strokes and alignment, dashes,
// live shapes, shape layers with solid and gradient paints, vector masks, hit testing.
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import Testing
@testable import PCPlatform

private func area(_ c: [Float]) -> Double { c.reduce(0) { $0 + Double($1) } }
private func rectPath(_ x: Double, _ y: Double, _ w: Double, _ h: Double, op: PathOp = .combine) -> Subpath {
    Subpath.polygon([(x, y), (x + w, y), (x + w, y + h), (x, y + h)]).withOp(op)
}
private func stroke(_ width: Float, cap: LineCap = .butt, join: LineJoin = .miter, miter: Float = 100, dashes: [Float] = [], align: StrokeAlign = .center) -> StrokeStyle {
    StrokeStyle(ShapeStroke(width: width, align: align, cap: cap, join: join, miterLimit: miter, dashes: dashes))
}
private let canvas = PixelRect(x: 0, y: 0, width: 64, height: 64)

@Suite("Vector (CoreGraphics over PCDocument replaces photocraft-vector)")
struct VectorTests {
    @Test func exactAreaAntialiasing() {
        let r = VectorRasterizer.fillCoverage(VectorPath([rectPath(0.5, 0.5, 10, 10)]), rect: PixelRect(x: 0, y: 0, width: 12, height: 12))
        #expect(abs(area(r) - 100) < 0.2, "\(area(r))")
        let fine = VectorRasterizer.fillCoverage(VectorPath([rectPath(0.5, 0.5, 10, 10)]), rect: PixelRect(x: 0, y: 0, width: 12, height: 12), supersample: 4)
        measure("rect area: native AA \(area(r)), 4× supersampled \(area(fine)) (exact 100)")
        #expect(abs(area(fine) - 100) < abs(area(r) - 100) + 1e-6)
        let edge = r[1 * 12 + 0], corner = r[0], inner = r[5 * 12 + 5]
        measure("CG float-gray coverage of a half-pixel-offset rect: edge \(edge) (exact 0.5), corner \(corner) (exact 0.25), inner \(inner)")
        #expect(abs(edge - 0.5) < 1.0 / 255 && abs(corner - 0.25) < 1.0 / 255 && inner == 1)
        let disc = VectorRasterizer.fillCoverage(LiveShape.ellipse(rect: SIMD4(2, 2, 50, 50)).path, rect: canvas)
        let err = abs(area(disc) - Double.pi * 625) / (Double.pi * 625)
        measure("ellipse r=25 coverage area relative error \(err) (Bézier circle + AA)")
        #expect(err < 0.002)
        let hard = VectorRasterizer.fillCoverage(VectorPath([rectPath(0.5, 0.5, 10, 10)]), rect: PixelRect(x: 0, y: 0, width: 12, height: 12), antialias: false)
        #expect(hard.allSatisfy { $0 == 0 || $0 == 1 })
    }

    @Test func photoshopPathOperations() {
        // Squares A (10…40) and B (25…55): overlap 15 × 30.
        func a(_ op: PathOp) -> Double {
            area(VectorRasterizer.fillCoverage(VectorPath([rectPath(10, 10, 30, 30), rectPath(25, 10, 30, 30, op: op)]), rect: canvas))
        }
        #expect(abs(a(.combine) - 1350) < 0.5)
        #expect(abs(a(.subtract) - 450) < 0.5)
        #expect(abs(a(.intersect) - 450) < 0.5)
        #expect(abs(a(.exclude) - 900) < 0.5)
        // The first subpath always combines (Photoshop): a lone "intersect" still draws.
        #expect(abs(area(VectorRasterizer.fillCoverage(VectorPath([rectPath(10, 10, 30, 30, op: .intersect)]), rect: canvas)) - 900) < 0.5)
        // A custom shape's hole: a joined, reversed inner contour.
        var hole = rectPath(20, 20, 10, 10, op: .join)
        hole.knots.reverse()
        #expect(abs(area(VectorRasterizer.fillCoverage(VectorPath([rectPath(10, 10, 30, 30), hole]), rect: canvas)) - 800) < 0.5)
        let eo = VectorPath([rectPath(10, 10, 30, 30), rectPath(20, 20, 10, 10, op: .join)], fillRule: .evenOdd)
        #expect(abs(area(VectorRasterizer.fillCoverage(eo, rect: canvas)) - 800) < 0.5)
        let inv = VectorPath([rectPath(10, 10, 30, 30)], inverted: true)
        #expect(abs(area(VectorRasterizer.fillCoverage(inv, rect: canvas)) - (4096 - 900)) < 0.5)
    }

    @Test func booleanOperationsOnWholePaths() {
        let a = VectorPath([rectPath(10, 10, 30, 30)]), b = LiveShape.ellipse(rect: SIMD4(25, 25, 30, 30)).path
        let ua = area(VectorRasterizer.fillCoverage(PathBoolean.union(a, b), rect: canvas))
        let ia = area(VectorRasterizer.fillCoverage(PathBoolean.intersection(a, b), rect: canvas))
        let sa = area(VectorRasterizer.fillCoverage(PathBoolean.subtracting(a, b), rect: canvas))
        let xa = area(VectorRasterizer.fillCoverage(PathBoolean.symmetricDifference(a, b), rect: canvas))
        let circle = Double.pi * 225
        measure("CGPath booleans (square ∪/∩/−/⊕ circle): \(ua), \(ia), \(sa), \(xa); identities error \(abs(ua - (900 + circle - ia))) / \(abs(sa - (900 - ia))) / \(abs(xa - (ua - ia)))")
        #expect(abs(ua - (900 + circle - ia)) < 2)
        #expect(abs(sa - (900 - ia)) < 1)
        #expect(abs(xa - (ua - ia)) < 1)
        let merged = PathBoolean.merged(VectorPath([rectPath(10, 10, 30, 30), rectPath(25, 10, 30, 30, op: .subtract)]))
        #expect(abs(area(VectorRasterizer.fillCoverage(merged, rect: canvas)) - 450) < 0.5)
        let back = VectorPath(cgPath: b.cgPath)
        #expect(abs(area(VectorRasterizer.fillCoverage(back, rect: canvas)) - area(VectorRasterizer.fillCoverage(b, rect: canvas))) < 1e-3)
    }

    @Test func strokesCapsJoinsDashesAndAlignment() {
        let line = VectorPath([.polyline([(10, 20), (30, 20)])])
        func a(_ s: StrokeStyle, _ p: VectorPath = line) -> Double { area(VectorRasterizer.strokeCoverage(p, style: s, rect: canvas)) }
        #expect(abs(a(stroke(4)) - 80) < 0.5)
        #expect(abs(a(stroke(4, cap: .square)) - 96) < 0.5)
        #expect(abs(a(stroke(4, cap: .round)) - (80 + Double.pi * 4)) < 0.5)
        let dashed = a(stroke(2, dashes: [2, 2]))
        #expect(abs(dashed - 24) < 0.5, "4 px on / 4 px off over 20 px: dashes at 0, 8, 16 → 12 px × 2: \(dashed)")
        let sq = VectorPath([rectPath(20, 20, 20, 20)])
        let inside = VectorRasterizer.strokeCoverage(sq, style: stroke(4, align: .inside), rect: canvas)
        let outside = VectorRasterizer.strokeCoverage(sq, style: stroke(4, align: .outside), rect: canvas)
        let center = VectorRasterizer.strokeCoverage(sq, style: stroke(4), rect: canvas)
        measure("square 20 stroke 4: inside \(area(inside)) (exact 400−12² = 256), outside \(area(outside)) (exact 28²−400 = 384), centre \(area(center)) (exact 24²−16² = 320)")
        #expect(abs(area(inside) - 256) < 0.5 && abs(area(outside) - 384) < 0.5 && abs(area(center) - 320) < 0.5)
        let fill = VectorRasterizer.fillCoverage(sq, rect: canvas)
        #expect(zip(inside, fill).allSatisfy { $0 <= $1 + 1e-6 }, "inside strokes stay inside the fill")
        let v = VectorPath([.polyline([(10, 50), (30, 10), (50, 50)])])
        let miter = a(stroke(6, miter: 10), v), bevel = a(stroke(6, join: .bevel), v), round = a(stroke(6, join: .round), v)
        #expect(miter > round && round > bevel)
        #expect(abs(a(stroke(6, miter: 1), v) - bevel) < 0.5, "a miter limit of 1 bevels")
    }

    @Test func liveShapes() {
        #expect(LiveShape.rect(rect: SIMD4(0, 0, 100, 50), radii: SIMD4(repeating: 10)).path.subpaths[0].knots.count == 8)
        #expect(LiveShape.rect(rect: SIMD4(0, 0, 100, 50), radii: .zero).path.subpaths[0].knots.count == 4)
        #expect(LiveShape.rect(rect: SIMD4(0, 0, 100, 50), radii: SIMD4(10, 0, 10, 0)).path.subpaths[0].knots.count == 6)
        #expect(LiveShape.clampRadii(width: 10, height: 10, SIMD4(repeating: 10)) == SIMD4(repeating: 5))
        #expect(LiveShape.polygon(rect: SIMD4(0, 0, 10, 10), sides: 5, starRatio: 0.5).path.subpaths[0].knots.count == 10)
        #expect(LiveShape.polygon(rect: SIMD4(0, 0, 10, 10), sides: 6, starRatio: 1).path.subpaths[0].knots.count == 6)
        let top = LiveShape.polygon(rect: SIMD4(0, 0, 10, 10), sides: 3, starRatio: 1).path.subpaths[0].knots[0].anchor
        #expect(abs(top.x - 5) < 1e-9 && abs(top.y) < 1e-9)
        let rra = area(VectorRasterizer.fillCoverage(LiveShape.rect(rect: SIMD4(5, 5, 50, 40), radii: SIMD4(repeating: 10)).path, rect: canvas))
        #expect(abs(rra - (2000 - (400 - Double.pi * 100))) < 2.5, "rounded rect area \(rra)")
        let bar = area(VectorRasterizer.fillCoverage(LiveShape.line(from: SIMD2(10, 10), to: SIMD2(40, 50), weight: 4).path, rect: canvas))
        #expect(abs(bar - 200) < 0.5, "a 50 px line 4 px thick")
    }

    @Test func hitTesting() {
        var hole = rectPath(20, 20, 10, 10, op: .join); hole.knots.reverse()
        let p = VectorPath([rectPath(10, 10, 30, 30), hole])
        #expect(PathHitTest.fillContains(p, CGPoint(x: 12, y: 12)))
        #expect(!PathHitTest.fillContains(p, CGPoint(x: 25, y: 25)), "inside the hole")
        #expect(!PathHitTest.fillContains(p, CGPoint(x: 5, y: 5)))
        #expect(PathHitTest.strokeContains(p, style: stroke(4), CGPoint(x: 10, y: 25)))
        #expect(!PathHitTest.strokeContains(p, style: stroke(4), CGPoint(x: 15, y: 25)))
        let k = PathHitTest.knot(p, near: CGPoint(x: 41, y: 11), tolerance: 3)
        #expect(k?.subpath == 0 && k?.knot == 1 && k?.part == .anchor)
        let curve = LiveShape.ellipse(rect: SIMD4(0, 0, 40, 40)).path
        #expect(PathHitTest.knot(curve, near: CGPoint(x: 31, y: 0), tolerance: 1)?.part == .outControl, "handles are hit too")
        let s = PathHitTest.segment(VectorPath([.polyline([(0, 0), (40, 0)])]), near: CGPoint(x: 10, y: 2), tolerance: 3)
        #expect(s != nil && abs(s!.t - 0.25) < 1e-3 && abs(s!.distance - 2) < 1e-3)
        #expect(PathHitTest.segment(curve, near: CGPoint(x: 20, y: 20), tolerance: 3) == nil)
    }

    @Test func shapeLayersMasksAndCoverageSurfaces() {
        let far = VectorPath([rectPath(1000, 2000, 20, 20)])
        let s = VectorRasterizer.coverageSurface(far, sample: .u16, clip: PixelRect(x: 0, y: 0, width: 4096, height: 4096))
        #expect(s.tileCount == 1 && s.format == .gray16, "only the touched tile is allocated")
        #expect(s.pixel(x: 1010, y: 2010)[0] == 1 && s.pixel(x: 5, y: 5)[0] == 0)
        var shape = ShapeLayer(path: VectorPath([rectPath(10, 10, 30, 30)]), fill: .solid(.rgb(1, 0, 0)),
                               stroke: ShapeStroke(width: 4, paint: .solid(.rgb(0, 0, 1)), align: .inside))
        let r = VectorRasterizer.rasterize(shape, format: .rgba8, clip: canvas)
        let mid = r.pixel(x: 25, y: 25), edge = r.pixel(x: 11, y: 25), outside = r.pixel(x: 5, y: 5)
        #expect(mid[0] == 1 && mid[2] == 0 && mid[3] == 1)
        #expect(edge[2] == 1 && edge[0] == 0, "the inside stroke covers the fill's edge")
        #expect(outside[3] == 0)
        let drawn = VectorRasterizer.renderCache(&shape, format: .rgba8, clip: canvas)
        #expect(shape.cache == r && drawn.contains(PixelRect(x: 10, y: 10, width: 30, height: 30)))
        let c = VectorRasterizer.rasterize(shape, format: .cmyka8, clip: canvas).pixel(x: 25, y: 25)
        #expect(c[1] > 0.8 && c[2] > 0.8 && c[4] == 1, "red fill in CMYK (naive or the installed managed converter): \(c)")
        // A linear gradient fill (photocraft's Paint): red at the left edge, blue at the right.
        let grad = Fill.gradient(GradientFill(stops: [ColorStop(0, .rgb(1, 0, 0)), ColorStop(1, .rgb(0, 0, 1))], angle: 0, scale: 1, style: .linear, reverse: false))
        let g = VectorRasterizer.rasterize(ShapeLayer(path: VectorPath([rectPath(0, 0, 64, 8)]), fill: grad), format: .rgba8, clip: canvas)
        let left = g.pixel(x: 0, y: 4), right = g.pixel(x: 63, y: 4), middle = g.pixel(x: 32, y: 4)
        measure("linear gradient shape fill: left \(left), middle \(middle), right \(right)")
        #expect(left[0] > 0.95 && right[2] > 0.95 && abs(middle[0] - 0.5) < 0.05)
        // A pattern paint is transparent here, as in photocraft-vector.
        #expect(VectorRasterizer.rasterize(ShapeLayer(path: VectorPath([rectPath(0, 0, 8, 8)]), fill: .pattern(PatternFill(name: "p"))), format: .rgba8, clip: canvas).tileCount == 0)
        // Vector masks: disabled and empty reveal everything; density lifts the hidden part.
        let r4 = PixelRect(x: 0, y: 0, width: 4, height: 4)
        #expect(VectorRasterizer.coverage(of: VectorMask(path: VectorPath()), rect: r4).allSatisfy { $0 == 1 })
        #expect(VectorRasterizer.coverage(of: VectorMask(path: VectorPath(inverted: true)), rect: r4).allSatisfy { $0 == 0 })
        #expect(VectorRasterizer.coverage(of: VectorMask(path: VectorPath([rectPath(0, 0, 2, 4)]), enabled: false), rect: r4).allSatisfy { $0 == 1 })
        let m = VectorRasterizer.coverage(of: VectorMask(path: VectorPath([rectPath(0, 0, 2, 4)]), density: 0.5), rect: r4)
        #expect(m[0] == 1 && abs(m[3] - 0.5) < 1e-6)
    }

    /// PCEngine request 5: CoreGraphics draws nothing once a path point is ~1e9 px from the bitmap,
    /// so the rasteriser clips far paths to the rendered rectangle first; fills, strokes, dashes and
    /// shape layers come out as if CoreGraphics had no limit.
    @Test func farCoordinatesAreClippedBeforeCoreGraphics() throws {
        for x in [1e8, 3e9, 1e12] {
            let half = VectorPath([rectPath(-x, -x, 2 * x, x + 20)])
            // CoreGraphics on its own, past its limit, draws nothing.
            let raw = try #require(VectorRasterizer.context(canvas))
            raw.addPath(half.cgPath)
            raw.fillPath()
            let rawArea = area(VectorRasterizer.read(raw, canvas))
            let clipped = area(VectorRasterizer.fillCoverage(half, rect: canvas))
            measure("half-plane y < 20 with corners at ±\(x): CoreGraphics alone \(rawArea) px², clipped first \(clipped) px² (exact 1280)")
            if x >= 1e9 { #expect(rawArea == 0, "CoreGraphics' own limit (if this fails it was lifted)") }
            #expect(abs(clipped - 1280) < 0.5)
            #expect(abs(area(VectorRasterizer.coverage(half.cgPath, rect: canvas)) - 1280) < 0.5, "the CGPath entry point too")
            // A far diagonal (half the canvas), and a far subtract.
            let diagonal = VectorPath([Subpath.polygon([(-x, -x), (x, x), (x, -x)])])
            #expect(abs(area(VectorRasterizer.fillCoverage(diagonal, rect: canvas)) - 2048) < 1)
            let cut = VectorPath([rectPath(-x, -x, 2 * x, 2 * x), rectPath(10, 10, 20, 20, op: .subtract)])
            #expect(abs(area(VectorRasterizer.fillCoverage(cut, rect: canvas)) - (4096 - 400)) < 0.5)
            // A huge circle whose top touches y = 32: the lower half of the canvas.
            let circle = LiveShape.ellipse(rect: SIMD4(32 - x, 32, 2 * x, 2 * x)).path
            #expect(abs(area(VectorRasterizer.fillCoverage(circle, rect: canvas)) - 2048) < 1, "\(x)")
            // Strokes: an open line across the canvas, the top edge of a far closed rectangle, and a
            // dashed line whose pattern starts 16·k px before the canvas (8 on, 8 off from x = 0).
            let line = VectorPath([Subpath.polyline([(-x, 32), (x, 32)])])
            #expect(abs(area(VectorRasterizer.strokeCoverage(line, style: stroke(4), rect: canvas)) - 256) < 0.5)
            let frame = VectorPath([rectPath(-x, 32, 2 * x, x)])
            #expect(abs(area(VectorRasterizer.strokeCoverage(frame, style: stroke(4), rect: canvas)) - 256) < 0.5, "only the edge through the canvas")
            let dashed = VectorRasterizer.strokeCoverage(line, style: stroke(4, dashes: [2, 2]), rect: canvas)
            #expect(abs(area(dashed) - 128) < 0.5 && dashed[32 * 64 + 4] == 1 && dashed[32 * 64 + 12] == 0, "dash phase kept: \(area(dashed))")
            // Shape layers: bounds, fill and stroke.
            var shape = ShapeLayer(path: half)
            shape.fill = .solid(.rgb(1, 0, 0))
            shape.stroke = ShapeStroke(width: 4)
            #expect(VectorRasterizer.bounds(of: shape, clip: canvas) == canvas)
            let surf = VectorRasterizer.rasterize(shape, format: .rgba8, clip: canvas)
            let alpha = surf.readRegion(canvas).enumerated().filter { $0.offset % 4 == 3 }.reduce(0.0) { $0 + Double($1.element) }
            #expect(abs(alpha - (1280 + 2 * 64)) < 1, "fill y < 20 plus the stroke's outer half: \(alpha)")
            #expect(!VectorRasterizer.coverageSurface(half, clip: canvas).contentBounds.isEmpty)
        }
        // Non-finite points are dropped, not handed to CoreGraphics.
        let nan = VectorPath([Subpath.polygon([(0, 0), (.nan, 10), (40, 0), (40, 40), (0, 40)])])
        #expect(area(VectorRasterizer.fillCoverage(nan, rect: canvas)) > 0)
    }
}
