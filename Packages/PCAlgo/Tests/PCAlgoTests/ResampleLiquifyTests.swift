// Port of photocraft-algo (crates/algo/src/liquify.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct ResampleLiquifyTests {
    static func p3(_ x: Double, _ y: Double, _ p: Double = 1) -> SIMD3<Double> { SIMD3(x, y, p) }
    static func stroke(_ tool: LiquifyTool, _ size: Double, _ pts: [[Double]] = []) -> LiquifyStroke {
        LiquifyStroke(tool: tool, size: size, points: pts)
    }
    static let bounds = PixelRect(x0: 0, y0: 0, x1: 96, y1: 64)

    static func sample(_ st: SampleType) -> Surface {
        var s = Surface(format: PixelFormat(mode: .rgb, sample: st, alpha: true))
        var px: [Float] = []
        for y in 0..<64 { for x in 0..<96 { px += [Float((x / 4 + y / 4) % 2), Float(x) / 96, Float(y) / 64, 1] } }
        s.writeRegion(bounds, px)
        return s
    }

    static func worst(_ a: Surface, _ b: Surface, _ r: PixelRect) -> Float { RS.maxDiff(a.readRegion(r), b.readRegion(r)) }

    static func maxDiff(_ a: LiquifyField, _ b: LiquifyField) -> (Float, Float) {
        let dd = zip(a.d, b.d).map { max(abs($0.x - $1.x), abs($0.y - $1.y)) }.max() ?? 0
        let df = zip(a.freeze, b.freeze).map { abs($0 - $1) }.max() ?? 0
        return (dd, df)
    }

    /// photocraft #937: skipping the dabs that can't reach a field node leaves every result
    /// bit-identical to the full walk.
    @Test func aSegmentWalksOnlyTheDabsThatCanReachTheField() {
        let bounds = PixelRect(x0: -7, y0: 3, x1: 89, y1: 67)
        let segments: [(SIMD3<Double>, SIMD3<Double>)] = [
            (Self.p3(10, 20), Self.p3(70, 50, 0.5)),
            (Self.p3(-900, 30), Self.p3(40, 31)),
            (Self.p3(40, 30), Self.p3(40, 4000, 0.2)),
            (Self.p3(-500, -500), Self.p3(600, 600)),
            (Self.p3(-300, -9), Self.p3(300, -9)),
            (Self.p3(-300, -400), Self.p3(300, -400)),
            (Self.p3(88.5, -50), Self.p3(88.5, 120)),
            (Self.p3(200, 200), Self.p3(201, 900)),
            (Self.p3(0, 0), Self.p3(0.25, 0.1)),
            (Self.p3(60, 40), Self.p3(-2000, 45)),
        ]
        for tool in [LiquifyTool.forwardWarp, .pushLeft, .reconstruct, .smooth, .twirlCw, .twirlCcw, .pucker, .bloat, .freeze, .thaw] {
            for size in [6.0, 40.0] {
                for (a, b) in segments {
                    let s = Self.stroke(tool, size)
                    var fast = LiquifyField(bounds: bounds, cell: 2), full = LiquifyField(bounds: bounds, cell: 2)
                    // Some displacement first, so Reconstruct and Smooth have something to undo.
                    fast.strokeSegment(Self.stroke(.forwardWarp, 30), Self.p3(20, 20), Self.p3(60, 40))
                    full.strokeSegment(Self.stroke(.forwardWarp, 30), Self.p3(20, 20), Self.p3(60, 40))
                    let dirty = fast.strokeSegment(s, a, b)
                    #expect(dirty == full.walkSegment(s, a, b, skip: false), "\(tool) \(size) \(a) \(b)")
                    #expect(fast.d == full.d && fast.freeze == full.freeze, "\(tool) \(size) \(a) \(b)")
                }
            }
        }
    }

    /// The same path sampled by `parts` pointer events per leg, unevenly.
    static func sampled(_ path: [[Double]], _ parts: Int) -> [[Double]] {
        var out = [path[0]]
        for k in 1..<path.count {
            let a = path[k - 1], b = path[k]
            for q in 1...parts {
                let t = Double(q * q) / Double(parts * parts)
                out.append((0..<3).map { a[$0] + (b[$0] - a[$0]) * t })
            }
        }
        return out
    }

    /// photocraft #2606: spacing runs on along the whole stroke, so any sampling of a path gives
    /// the same field.
    @Test func theResultDoesNotDependOnHowFinelyThePathWasSampled() {
        let path: [[Double]] = [[20, 20, 1], [62, 26, 0.6], [70, 50, 0.9], [28, 55, 1], [30, 30, 1]]
        for tool in [LiquifyTool.forwardWarp, .pushLeft, .twirlCw, .bloat, .reconstruct, .smooth, .freeze] {
            for size in [12.0, 40.0] {
                func field(_ parts: Int) -> LiquifyField {
                    let warp = Self.stroke(.forwardWarp, 30, [[30, 30], [50, 40]])
                    let s = Self.stroke(tool, size, Self.sampled(path, parts))
                    return LiquifyField.fromStrokes(bounds: Self.bounds, cell: 2, strokes: [warp, s])
                }
                let coarse = field(1)
                for parts in [3, 17, 60] {
                    let (dd, df) = Self.maxDiff(coarse, field(parts))
                    #expect(dd < 1e-3 && df < 1e-4, "\(tool) \(size)px, \(parts) events per leg: field differs by \(dd) px, mask by \(df)")
                }
            }
        }
    }

    @Test func aLongDiagonalDragGivesOneFieldAtAnyEventSpacing() {
        func field(_ step: Double) -> LiquifyField {
            let pts = (0...Int(300 / step)).map { k in [40 + Double(k) * step * 0.6, 20 + Double(k) * step * 0.8] }
            return LiquifyField.fromStrokes(bounds: PixelRect(x0: 0, y0: 0, x1: 320, y1: 300), cell: 2, strokes: [Self.stroke(.forwardWarp, 40, pts)])
        }
        let slow = field(2), fast = field(60)
        #expect(slow.maxDisplacement > 50, "the drag builds up a deep displacement")
        #expect(Self.maxDiff(slow, fast).0 < 1e-3)
    }

    @Test func aStrokeInterruptedByAJumpRestartsItsSpacing() {
        let s = Self.stroke(.forwardWarp, 20)
        var f = LiquifyField(bounds: Self.bounds, cell: 2)
        f.strokeBegin(s, Self.p3(10, 10))
        f.strokeSegment(s, Self.p3(10, 10), Self.p3(10.3, 10))
        var g = LiquifyField(bounds: Self.bounds, cell: 2)
        f.strokeSegment(s, Self.p3(40, 30), Self.p3(50, 30))
        g.strokeBegin(s, Self.p3(40, 30))
        g.strokeSegment(s, Self.p3(40, 30), Self.p3(50, 30))
        #expect(f == g)
        // Hostile points: nothing traps and the next segment starts afresh.
        f.strokeSegment(s, Self.p3(.nan, 3), Self.p3(4, .infinity))
        f.strokeSegment(s, Self.p3(4, 3, .nan), Self.p3(9, 3))
    }

    @Test func aSegmentToAFarOffPointReturns() {
        var f = LiquifyField(bounds: PixelRect(x0: 0, y0: 0, x1: 24, y1: 16), cell: 2)
        let s = Self.stroke(.forwardWarp, 30)
        let dirty = f.strokeSegment(s, Self.p3(0, 0), Self.p3(1e15, 0))
        #expect(!dirty.isEmpty && dirty.x1 <= 64, "\(dirty)")
        f.strokeSegment(s, Self.p3(-1e308, 5), Self.p3(1e308, 5))
        f.strokeSegment(Self.stroke(.bloat, 30), Self.p3(5, -1e15), Self.p3(5, 1e15))
    }

    static func lasso(_ points: [[Double]], _ amount: Double?) -> LiquifyStroke {
        var s = Self.stroke(.lassoMask, 1, points)
        s.amount = amount
        return s
    }

    /// Reference even-odd test (ray casting).
    static func inside(_ p: SIMD2<Double>, _ poly: [[Double]]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for (i, a) in poly.enumerated() {
            let b = poly[j]
            if (a[1] > p.y) != (b[1] > p.y) && p.x < (b[0] - a[0]) * (p.y - a[1]) / (b[1] - a[1]) + a[0] { inside.toggle() }
            j = i
        }
        return inside
    }

    @Test func lassoFreezesExactlyTheNodesInsideAConcavePolygon() {
        let poly: [[Double]] = [[10, 8], [70, 8], [70, 20], [30, 22.5], [33, 40], [80, 41], [60, 58], [9, 55]]
        for cell in [1.0, 2.0, 3.5] {
            var f = LiquifyField(bounds: Self.bounds, cell: cell)
            let dirty = f.applyStroke(Self.lasso(poly, nil))
            #expect(dirty == PixelRect(x0: 9, y0: 8, x1: 80, y1: 58))
            for j in 0..<f.h {
                for i in 0..<f.w {
                    let want: Float = Self.inside(f.nodePos(i, j), poly) ? 1 : 0
                    #expect(f.freeze[j * f.w + i] == want, "cell \(cell): node (\(i), \(j))")
                }
            }
            #expect(f.freeze.contains(1))
            #expect(LiquifyField.fromStrokes(bounds: Self.bounds, cell: cell, strokes: [Self.lasso(poly, nil)]) == f)
        }
    }

    @Test func lassoThawsWithAmountZero() {
        var f = LiquifyField(bounds: Self.bounds, cell: 2)
        f.applyStroke(Self.stroke(.freezeAll, 1))
        #expect(f.freeze.allSatisfy { $0 == 1 })
        f.applyStroke(Self.lasso([[20, 20], [40, 20], [40, 40], [20, 40]], 0))
        #expect(f.freezeAt(30, 30) == 0, "thawed inside")
        #expect(f.freezeAt(5, 5) == 1, "still frozen outside")
    }

    @Test func lassoIgnoresDegenerateAndHostilePolygons() {
        let empty = LiquifyField(bounds: Self.bounds, cell: 2)
        let cases: [[[Double]]] = [
            [],
            [[10, 10], [50, 50]],
            [[.nan, 10], [50, .infinity], [20, 30]],
            [[-50, -50], [-10, -50], [-10, -10]],
            [[200, 10], [300, 10], [250, 50]],
            [[10, 1e12], [50, 1e12], [30, 2e12]],
        ]
        for poly in cases {
            var f = empty
            #expect(f.applyStroke(Self.lasso(poly, nil)) == .empty, "\(poly)")
            #expect(f == empty, "\(poly)")
        }
        var f = empty
        f.applyStroke(Self.lasso([[-1e15, -1e15], [1e15, -1e15], [1e15, 1e15], [-1e15, 1e15]], nil))
        #expect(f.freeze.allSatisfy { $0 == 1 })
        var g = empty
        g.applyStroke(Self.lasso([[10, 10], [.nan, 0], [50, 10], [50, 50], [10, 50]], nil))
        #expect(g.freezeAt(30, 30) == 1)
    }

    @Test func theBrushFadesToNothingAtItsRimAtEveryDensity() {
        for density in [0.0, 0.25, 0.5, 0.75, 1.0, .nan, -3.0, 7.0] {
            #expect(Liquify.falloff(0, density) == 1, "full strength at the centre (\(density))")
            #expect(Liquify.falloff(1, density) == 0, "nothing at the rim (\(density))")
            #expect(Liquify.falloff(0.98 * 0.98, density) < 0.02, "\(density)")
            var prev = 1.0
            for k in 1...100 {
                let v = Liquify.falloff(Double(k) / 100, density)
                #expect(v <= prev && v >= 0, "\(density): not falling at t² = \(k)%")
                prev = v
            }
        }
        for k in 1..<100 {
            let t2 = Double(k) / 100
            #expect(Liquify.falloff(t2, 1) >= Liquify.falloff(t2, 0.5) && Liquify.falloff(t2, 0.5) >= Liquify.falloff(t2, 0), "t² = \(t2)")
        }
        #expect(Liquify.falloff(0.5, 1) > 0.5 && Liquify.falloff(0.5, 0) < 0.2)
    }

    /// photocraft #2606: a Forward Warp leaves the brush rim in place at every density.
    @Test func forwardWarpLeavesTheBrushRimInPlace() {
        let (r, drag) = (20.0, 1.0)
        for density in [0.0, 50, 100] {
            var s = Self.stroke(.forwardWarp, 2 * r, [[48, 32], [48 + drag, 32]])
            s.density = density
            let f = LiquifyField.fromStrokes(bounds: Self.bounds, cell: 1, strokes: [s])
            var rim = 0
            for j in 0..<f.h {
                for i in 0..<f.w {
                    let p = f.nodePos(i, j)
                    let t = hypot(p.x - 48, p.y - 32) / r
                    if t >= 0.97 && t < 1 {
                        let d = f.d[j * f.w + i]
                        #expect(Double(hypotf(d.x, d.y)) < 0.03 * drag, "density \(density): a node at \(t) r moved \(d)")
                        rim += 1
                    }
                }
            }
            #expect(rim > 20, "\(rim) rim nodes")
            #expect(f.sample(48, 32).x < -0.9 * drag, "density \(density): the centre follows the brush")
        }
    }

    @Test func noStrokesIsIdentityAtEveryDepth() {
        for st in [SampleType.u8, .u16, .f32] {
            let s = Self.sample(st)
            let f = LiquifyField(bounds: Self.bounds, cell: 2)
            #expect(Liquify.apply(s, field: f) == s)
            var st0 = Self.stroke(.forwardWarp, 30, [[40, 30], [60, 30]])
            st0.pressure = 0
            #expect(LiquifyField.fromStrokes(bounds: Self.bounds, cell: 2, strokes: [st0]).isIdentity)
        }
    }

    @Test func fullResolutionPreviewMatchesTheUnitScaleProxyAndPartialUpdates() {
        let canvas = Self.bounds
        for st in [SampleType.u8, .u16, .f32] {
            let source = Self.sample(st)
            var field = LiquifyField.fromStrokes(bounds: canvas, cell: 2, strokes: [Self.stroke(.forwardWarp, 32, [[38, 30, 1], [52, 34, 0.8]])])
            let proxy = Liquify.ProxyImage(source, bounds: canvas, maxSide: 96)
            #expect(proxy.scale == 1)
            var want = [SIMD4<UInt8>](repeating: .zero, count: proxy.w * proxy.h)
            proxy.render(field, [0, 0, proxy.w, proxy.h], into: &want)
            var got = [SIMD4<UInt8>](repeating: .zero, count: proxy.w * proxy.h)
            var scratch: [SIMD4<Float>] = []
            #expect(Liquify.ProxyImage.renderFullResolution(source, field: field, bounds: canvas, region: canvas, out: &got, sourceScratch: &scratch))
            #expect(got == want, "full-resolution render at \(st)")
            let dirty = field.applyStroke(Self.stroke(.bloat, 16, [[43, 32, 1]]))
            proxy.render(field, proxy.proxyRect(dirty), into: &want)
            #expect(Liquify.ProxyImage.renderFullResolution(source, field: field, bounds: canvas, region: dirty, out: &got, sourceScratch: &scratch))
            #expect(got == want, "partial update at \(st)")
        }
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func forwardWarpDisplacesAlongTheStrokeAndReconstructRestores(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        var f = LiquifyField.fromStrokes(bounds: Self.bounds, cell: 2, strokes: [Self.stroke(.forwardWarp, 40, [[40, 32], [52, 32]])])
        let d = f.sample(52, 32)
        #expect(d.x < -4 && abs(d.y) < 0.5, "\(d)")
        var img = Surface(format: PixelFormat(mode: .grayscale, sample: .f32, alpha: true))
        img.fill(Self.bounds, with: [0, 1])
        img.fill(PixelRect(x0: 40, y0: 28, x1: 42, y1: 36), with: [1, 1])
        let out = Liquify.apply(img, field: f, on: backend)
        // Rust's max_by keeps the last of equal maxima.
        var brightest: Int32 = 30
        for x in Int32(30)..<70 where out.pixel(x: x, y: 32)[0] >= out.pixel(x: brightest, y: 32)[0] { brightest = x }
        #expect(brightest > 44, "marker moved right: \(brightest)")
        var rec = Self.stroke(.reconstructAll, 10)
        rec.amount = 100
        f.applyStroke(rec)
        #expect(f.isIdentity)
        #expect(Liquify.apply(img, field: f, on: backend) == img)
    }

    @Test func reconstructBrushReducesTheFieldAndFreezeProtects() {
        let s = Self.stroke(.forwardWarp, 40, [[30, 32], [45, 32]])
        var f = LiquifyField.fromStrokes(bounds: Self.bounds, cell: 2, strokes: [s])
        let before = f.maxDisplacement
        f.applyStroke(Self.stroke(.reconstruct, 80, [[Double]](repeating: [40, 32], count: 30)))
        #expect(f.maxDisplacement < before * 0.2, "\(f.maxDisplacement) vs \(before)")
        var fr = Self.stroke(.freeze, 60, [[40, 32]])
        fr.density = 100
        var g = LiquifyField(bounds: Self.bounds, cell: 2)
        g.applyStroke(fr)
        #expect(g.freezeAt(40, 32) > 0.99)
        g.applyStroke(s)
        #expect(abs(g.sample(40, 32).x) < 1e-3)
        var th = fr
        th.tool = .thaw
        g.applyStroke(th)
        #expect(g.freezeAt(40, 32) < 0.01)
        g.applyStroke(Self.stroke(.freezeAll, 1))
        #expect(g.freeze.allSatisfy { $0 == 1 })
        g.applyStroke(Self.stroke(.invertFreeze, 1))
        #expect(g.freeze.allSatisfy { $0 == 0 })
        g.applyStroke(fr)
        g.applyStroke(Self.stroke(.invertFreeze, 1))
        #expect(g.freezeAt(40, 32) < 0.01 && g.freezeAt(5, 5) > 0.99)
        g.applyStroke(Self.stroke(.thawAll, 1))
        #expect(g.freeze.allSatisfy { $0 == 0 })
    }

    @Test func twirlPuckerBloatAndPushLeftHaveTheRightSense() {
        func at(_ tool: LiquifyTool, _ pts: [[Double]]) -> LiquifyField {
            LiquifyField.fromStrokes(bounds: Self.bounds, cell: 2, strokes: [Self.stroke(tool, 40, pts)])
        }
        let c = [[Double]](repeating: [48, 32], count: 10)
        #expect(at(.pucker, c).sample(58, 32).x > 0.1)
        #expect(at(.bloat, c).sample(58, 32).x < -0.1)
        #expect(at(.twirlCw, c).sample(58, 32).y < -0.1)
        #expect(at(.twirlCcw, c).sample(58, 32).y > 0.1)
        #expect(at(.pushLeft, [[48, 44], [48, 20]]).sample(48, 32).x > 0.5)
        var g = LiquifyField.fromStrokes(bounds: Self.bounds, cell: 2, strokes: [Self.stroke(.forwardWarp, 12, [[40, 32], [50, 32]])])
        let m0 = g.maxDisplacement
        g.applyStroke(Self.stroke(.smooth, 60, [[Double]](repeating: [45, 32], count: 20)))
        #expect(g.maxDisplacement < m0)
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func replayIsDeterministicAndDepthsAgree(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        let s = Self.stroke(.twirlCw, 50, [[48, 32, 0.5], [50, 33, 1], [52, 34]])
        let a = LiquifyField.fromStrokes(bounds: Self.bounds, cell: 2, strokes: [s])
        let b = LiquifyField.fromStrokes(bounds: Self.bounds, cell: 2, strokes: [s])
        #expect(a == b)
        let r8 = Liquify.apply(Self.sample(.u8), field: a, on: backend)
        let r32 = Liquify.apply(Self.sample(.f32), field: a, on: backend)
        #expect(Self.worst(r8, r32, Self.bounds) < 2.0 / 255.0 + 1e-4)
    }

    @Test func proxyMatchesTheFullRenderRoughly() {
        let src = Self.sample(.u8)
        let f = LiquifyField.fromStrokes(bounds: Self.bounds, cell: 2, strokes: [Self.stroke(.bloat, 40, [[Double]](repeating: [48, 32], count: 8))])
        let p = Liquify.ProxyImage(src, bounds: Self.bounds, maxSide: 96)
        #expect(p.w == 96 && p.h == 64 && p.scale == 1)
        var out = [SIMD4<UInt8>](repeating: .zero, count: p.w * p.h)
        p.render(f, [0, 0, p.w, p.h], into: &out)
        let full = Liquify.apply(src, field: f, on: .cpu)
        var bad = 0
        for y in Int32(0)..<64 {
            for x in Int32(0)..<96 where abs(Float(out[Int(y) * 96 + Int(x)][1]) / 255 - full.pixel(x: x, y: y)[1]) > 0.1 { bad += 1 }
        }
        #expect(bad < 96 * 64 / 50, "\(bad)")
    }

    @Test func strokeDecodesWithPhotocraftDefaults() throws {
        let s = try JSONDecoder().decode(LiquifyStroke.self, from: Data(#"{"tool":"twirlCw","points":[[1,2]]}"#.utf8))
        #expect(s.tool == .twirlCw && s.size == 100 && s.density == 50 && s.pressure == 100 && s.rate == 80 && s.amount == nil)
        #expect(throws: (any Error).self) { try LiquifyStroke(size: 0.5).validate() }
        #expect(throws: (any Error).self) { try LiquifyStroke(points: [[1]]).validate() }
    }

    /// GPU vs CPU over the channel variants, for several fields, with the image larger than,
    /// equal to and inside the field bounds.
    @Test func liquifyParity() throws {
        var worst: Float = 0
        let fieldBounds = PixelRect(x: 5, y: -3, width: 58, height: 44)
        let strokes: [[LiquifyStroke]] = [
            [Self.stroke(.forwardWarp, 30, [[20, 10], [40, 18], [45, 30]])],
            [Self.stroke(.twirlCw, 36, [[Double]](repeating: [30, 20], count: 6)), Self.stroke(.bloat, 20, [[Double]](repeating: [45, 5], count: 5))],
            [Self.stroke(.pucker, 50, [[Double]](repeating: [34, 18], count: 9)), Self.stroke(.pushLeft, 16, [[10, 30], [12, 0]])],
        ]
        for (k, ss) in strokes.enumerated() {
            for cell in [2.0, 3.5] {
                let field = LiquifyField.fromStrokes(bounds: fieldBounds, cell: cell, strokes: ss)
                for rect in [fieldBounds.outset(by: 6), fieldBounds, PixelRect(x: 12, y: 2, width: 40, height: 30)] {
                    let e = try RS.variants(rect, seed: UInt32(k + 2)) { img, ctx, b in
                        try Liquify.apply(img, field: field, context: ctx, on: b)
                    }
                    guard let e else { return }
                    #expect(e <= 1.0 / 255.0, "strokes \(k) cell \(cell) \(rect): \(e)")
                    worst = max(worst, e)
                }
            }
        }
        ParityLog.record("Liquify", worst)
    }

    /// The dense-image Liquify gives the surface Liquify's pixels.
    @Test func denseImageMatchesSurface() throws {
        let img = TestImage.make(Self.bounds, channels: 4, alpha: true, seed: 6)
        let s = RS.surface(img, .rgba32f)
        let f = LiquifyField.fromStrokes(bounds: Self.bounds, cell: 2, strokes: [Self.stroke(.forwardWarp, 30, [[30, 30], [50, 36]])])
        let a = Liquify.apply(s, field: f, on: .cpu)
        let b = try Liquify.apply(img, field: f, on: .cpu)
        #expect(RS.maxDiff(a.readRegion(Self.bounds), b.data) == 0)
    }
}
