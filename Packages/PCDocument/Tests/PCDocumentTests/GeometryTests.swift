// Port of photocraft-geom's tests (crates/geom/src/lib.rs and warp.rs), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCFoundation
import Testing
@testable import PCDocument

@Suite struct GeomTests {
    @Test func rectBasics() {
        let r = PixelRect.xywh(10, 20, 30, 40)
        #expect(r.width == 30)
        #expect(r.height == 40)
        #expect(r.contains(x: 10, y: 20))
        #expect(!r.contains(x: 40, y: 20))
        #expect(PixelRect(x0: 5, y0: 5, x1: 5, y1: 10).isEmpty)
    }

    @Test func intersectAndUnion() {
        let a = PixelRect(x0: 0, y0: 0, x1: 10, y1: 10)
        let b = PixelRect(x0: 5, y0: 5, x1: 15, y1: 15)
        #expect(a.intersect(b) == PixelRect(x0: 5, y0: 5, x1: 10, y1: 10))
        #expect(a.union(b) == PixelRect(x0: 0, y0: 0, x1: 15, y1: 15))
        #expect(a.intersect(PixelRect(x0: 20, y0: 20, x1: 30, y1: 30)) == .empty)
        #expect(PixelRect.empty.union(a) == a)
    }

    @Test func tileCoordsHandleNegatives() {
        #expect(TileCoord(containing: 0, 0) == TileCoord(tx: 0, ty: 0))
        #expect(TileCoord(containing: 255, 255) == TileCoord(tx: 0, ty: 0))
        #expect(TileCoord(containing: 256, 0) == TileCoord(tx: 1, ty: 0))
        #expect(TileCoord(containing: -1, -1) == TileCoord(tx: -1, ty: -1))
        #expect(TileCoord(containing: -256, -257) == TileCoord(tx: -1, ty: -2))
    }

    @Test func rectTilesEnumeration() {
        #expect(PixelRect(x0: -10, y0: 0, x1: 300, y1: 10).tiles == [TileCoord(tx: -1, ty: 0), TileCoord(tx: 0, ty: 0), TileCoord(tx: 1, ty: 0)])
        #expect(PixelRect.empty.tiles.isEmpty)
        #expect(PixelRect(x0: 0, y0: 0, x1: 256, y1: 256).tiles.count == 1)
        #expect(PixelRect(x0: 0, y0: 0, x1: 257, y1: 257).tiles.count == 4)
    }

    @Test func affineInverseRoundTrip() throws {
        let t = PCAffine.translate(5, -3).then(.rotate(0.7)).then(.scale(2.5))
        let inv = try #require(t.inverse)
        let p = PCPoint(12, -7.5)
        let q = inv.apply(t.apply(p))
        #expect(abs(q.x - p.x) < 1e-9 && abs(q.y - p.y) < 1e-9)
        #expect(PCAffine.scale(0).inverse == nil)
    }

    /// photocraft `82f456b26` `remove_split_u_rejects_out_of_range_indices` (and `_v_`): an index at or past the
    /// last knot, up to `Int.max`, is refused and leaves the mesh as it was.
    @Test func removeSplitRejectsOutOfRangeIndices() {
        let original = BezierMesh.identity(bounds: SIMD4(0, 0, 300, 300), cols: 2, rows: 3)
        for k in [0, original.us.count - 1, original.us.count, Int.max - 1, Int.max] {
            var mesh = original
            #expect(!mesh.removeSplitU(k) && mesh == original, "u index \(k)")
        }
        for k in [0, original.vs.count - 1, original.vs.count, Int.max - 1, Int.max] {
            var mesh = original
            #expect(!mesh.removeSplitV(k) && mesh == original, "v index \(k)")
        }
    }

    /// photocraft #8769: a mesh with more than 65 knots a side is not valid.
    @Test func aMeshWithTooManyKnotsIsNotValid() {
        func mesh(knots n: Int) -> BezierMesh {
            let us = (0 ..< n).map { Double($0) / Double(n - 1) }
            let nx = 3 * (n - 1) + 1
            let points = (0 ..< 4).flatMap { j in (0 ..< nx).map { i in SIMD2(Double(i), Double(j)) } }
            return BezierMesh(us: us, vs: [0, 1], points: points)
        }
        #expect(mesh(knots: 65).isValid)
        #expect(mesh(knots: 66).isWellFormed && !mesh(knots: 66).isValid)
    }

    /// photocraft #10959 `slices_past_the_limit_are_left_out`: at most 10,000 stored slices are resolved, and the
    /// document says how many were left out.
    @Test func slicesPastTheLimitAreLeftOut() {
        var d = Document(name: "slices", size: PixelSize(width: 100, height: 100), mode: .rgb, depth: .u8)
        d.slices.list = (0 ..< Slices.maxResolved + 5).map { i in
            var s = Slice(id: UInt32(i) + 1)
            s.rect = PixelRect(x0: 0, y0: 0, x1: 10, y1: 10)
            return s
        }
        #expect(d.slicesOverLimitNote == "5 stored slices past the first 10000 were ignored")
        let ids = Set(d.resolvedSlices().compactMap(\.id))
        #expect(!ids.contains { $0 > UInt32(Slices.maxResolved) }, "none past the limit")
        d.slices.list.removeLast(5)
        #expect(d.slicesOverLimitNote == nil)
    }

    /// photocraft #8651: a transform with a non-finite term, or whose inverse has one, has no inverse.
    @Test func affineInverseRejectsNonFiniteResults() {
        #expect(PCAffine(a: .nan, b: 0, c: 0, d: 1, e: 0, f: 0).inverse == nil)
        #expect(PCAffine(a: .infinity, b: 0, c: 0, d: 1, e: 0, f: 0).inverse == nil)
        #expect(PCAffine(a: 1e-6, b: 0, c: 0, d: 1e-6, e: 1e308, f: 1e308).inverse == nil)
        #expect(PCAffine(a: 1e200, b: 0, c: 0, d: 1e200, e: 0, f: 0).inverse == nil)
    }

    @Test func affineThenOrder() {
        let t = PCAffine.translate(10, 0).then(.scale(2))
        // translate first, then scale
        #expect(t.apply(PCPoint(1, 0)) == PCPoint(22, 0))
        #expect(t.cgAffineTransform == CGAffineTransform(translationX: 10, y: 0).concatenating(CGAffineTransform(scaleX: 2, y: 2)))
    }

    @Test func translateAndInflateSaturateOnOverflow() {
        let r = PixelRect(x0: .max - 10, y0: .min + 10, x1: .max, y1: .min + 20)
        let t = r.translated(dx: 100, dy: -100)
        #expect(t.x0 == .max)
        #expect(t.x1 == .max)
        #expect(t.y0 == .min)
        #expect(t.y1 == .min)
        let grown = PixelRect(x0: .max - 5, y0: .min + 5, x1: .max - 1, y1: .min + 10).inflated(by: 10)
        #expect(grown.x1 == .max)
        #expect(grown.y0 == .min)
    }

    @Test func widthAndHeightDoNotOverflowOnExtremeEdges() {
        // Inverted extreme rect: empty, so 0.
        let r = PixelRect(x0: .max, y0: .max, x1: .min, y1: .min)
        #expect(r.width == 0 && r.height == 0)
        #expect(r.isEmpty)
        // Widest possible rect: the true extent fits.
        let w = PixelRect(x0: .min, y0: .min + 20, x1: .max, y1: .max - 5)
        #expect(w.width == Int(UInt32.max))
        #expect(w.height == Int(UInt32.max) - 25)
        #expect(w.size == PixelSize(width: Int(UInt32.max), height: Int(UInt32.max) - 25))
    }

    @Test func affineSerializesAsPhotocraft() throws {
        #expect(try encodeJSON(PCAffine.translate(1, 2)) == #"{"m":[1,0,0,1,1,2]}"#)
        #expect(try decodeJSON(PCAffine.self, #"{"m":[2,0,0,2,0,0]}"#) == .scale(2))
        #expect(throws: (any Error).self) { try decodeJSON(PCAffine.self, #"{"m":[1,0]}"#) }
        #expect(try encodeJSON(PCPoint(1.5, -2)) == #"{"x":1.5,"y":-2}"#)
    }
}

@Suite struct WarpTests {
    let b = SIMD4<Double>(10, 20, 110, 70)

    /// The largest mismatch between the tangents on the two sides of any interior grid line.
    func tangentDefect(_ m: BezierMesh) -> Double {
        let nx = m.nx
        var worst = 0.0
        if m.us.count > 2 {
            for a in 1..<(m.us.count - 1) {
                let (hl, hr) = (m.us[a] - m.us[a - 1], m.us[a + 1] - m.us[a])
                for j in 0..<m.ny {
                    let (l, c, r) = (m.points[j * nx + 3 * a - 1], m.points[j * nx + 3 * a], m.points[j * nx + 3 * a + 1])
                    for k in 0..<2 { worst = max(worst, abs((c[k] - l[k]) / hl - (r[k] - c[k]) / hr)) }
                }
            }
        }
        if m.vs.count > 2 {
            for bb in 1..<(m.vs.count - 1) {
                let (hl, hr) = (m.vs[bb] - m.vs[bb - 1], m.vs[bb + 1] - m.vs[bb])
                for i in 0..<nx {
                    let (l, c, r) = (m.points[(3 * bb - 1) * nx + i], m.points[3 * bb * nx + i], m.points[(3 * bb + 1) * nx + i])
                    for k in 0..<2 { worst = max(worst, abs((c[k] - l[k]) / hl - (r[k] - c[k]) / hr)) }
                }
            }
        }
        return worst
    }

    @Test func draggingAnAnchorOrHandleKeepsTheSurfaceSmoothAcrossTheLines() {
        var base = BezierMesh.identity(bounds: SIMD4(0, 0, 300, 300), cols: 1, rows: 1)
        for s in [0.3, 0.55, 0.9] {
            do { let ok = base.splitU(s); #expect(ok) }
            do { let ok = base.splitV(s); #expect(ok) }
        }
        let nx = base.nx
        // Every kind of point on a grid line, interior and border: anchors, handles each way.
        for (i, j) in [(6, 6), (7, 6), (5, 6), (6, 7), (6, 5), (3, 9), (9, 3), (0, 6), (6, 0), (4, 3), (3, 4), (12, 12)] {
            var m = base
            m.dragPoint(base: base.points, index: j * nx + i, d: SIMD2(23, -31))
            #expect(m.points[j * nx + i] == SIMD2(base.points[j * nx + i].x + 23, base.points[j * nx + i].y - 31), "(\(i), \(j)) lands on the pointer")
            #expect(tangentDefect(m) < 1e-6, "(\(i), \(j)): \(tangentDefect(m))")
        }
    }

    /// Fraction of the surface where the map folds over itself (its Jacobian is not positive).
    func foldFraction(_ m: BezierMesh) -> Double {
        let (n, h) = (80, 1e-4)
        var bad = 0
        for j in 0..<n {
            for i in 0..<n {
                let (s, t) = ((Double(i) + 0.5) / Double(n), (Double(j) + 0.5) / Double(n))
                let q = m.eval(s, t)
                let (qs, qt) = (m.eval(s + h, t), m.eval(s, t + h))
                if (qs.x - q.x) * (qt.y - q.y) - (qt.x - q.x) * (qs.y - q.y) <= 0 { bad += 1 }
            }
        }
        return Double(bad) / Double(n * n)
    }

    @Test func aPullWithinAQuarterCellNeverFoldsTheSurface() {
        // 75 px cells: dragging a quarter of a cell, any direction, anywhere in the grid must not tear the picture.
        let base = BezierMesh.identity(bounds: SIMD4(0, 0, 300, 300), cols: 4, rows: 4)
        for (s, t) in [(0.42, 0.42), (0.75, 0.2), (0.2, 0.2), (0.5, 0.5), (0.85, 0.7), (0.3, 0.7)] {
            for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1), (0.7, 0.7), (-0.7, 0.7)] {
                var m = base
                m.pull(base: base.points, s: s, t: t, d: SIMD2(dx * 19, dy * 19))
                #expect(foldFraction(m) == 0, "(\(s), \(t)) by (\(dx), \(dy)) quarter cells")
            }
        }
    }

    @Test func aPullInTheMiddleLeavesTheBorderWhereItIs() {
        var base = BezierMesh.identity(bounds: SIMD4(0, 0, 600, 800), cols: 1, rows: 1)
        for s in [0.33, 0.66] { let ok = base.splitU(s); #expect(ok) }
        do { let ok = base.splitV(0.5); #expect(ok) }
        let (nx, ny) = (base.nx, base.ny)
        var m = base
        m.pull(base: base.points, s: 0.5, t: 0.5, d: SIMD2(-180, 40))
        for j in 0..<ny {
            for i in 0..<nx where i == 0 || j == 0 || i == nx - 1 || j == ny - 1 {
                #expect(close(m.points[j * nx + i], base.points[j * nx + i], 1e-6), "border point (\(i), \(j)) moved")
            }
        }
        // The pull itself still lands exactly.
        let (before, after) = (base.eval(0.5, 0.5), m.eval(0.5, 0.5))
        #expect(abs(after.x - before.x + 180) < 1e-4 && abs(after.y - before.y - 40) < 1e-4)
    }

    @Test func aPullAnywhereAwayFromTheBorderNeverMovesTheBorder() {
        // The default one-patch grid and a cut one; grabs all over, none within 12% of an edge.
        let one = BezierMesh.identity(bounds: SIMD4(0, 0, 600, 800), cols: 1, rows: 1)
        var cut = one
        do { let ok = cut.splitU(0.4) && cut.splitU(0.7) && cut.splitV(0.35) && cut.splitV(0.8); #expect(ok) }
        for base in [one, cut] {
            let (nx, ny) = (base.nx, base.ny)
            for (s, t) in [(0.5, 0.5), (0.2, 0.5), (0.8, 0.3), (0.3, 0.85), (0.14, 0.14), (0.86, 0.5)] {
                for d in [SIMD2<Double>(-400, 0), SIMD2(250, -90), SIMD2(0, 300)] {
                    var m = base
                    m.pull(base: base.points, s: s, t: t, d: d)
                    for j in 0..<ny {
                        for i in 0..<nx where i == 0 || j == 0 || i == nx - 1 || j == ny - 1 {
                            #expect(close(m.points[j * nx + i], base.points[j * nx + i], 1e-6), "(\(s), \(t)) by \(d) moved border point (\(i), \(j))")
                        }
                    }
                    let (before, after) = (base.eval(s, t), m.eval(s, t))
                    #expect(abs(after.x - before.x - d.x) < 1e-3 && abs(after.y - before.y - d.y) < 1e-3, "(\(s), \(t)) by \(d): \(after)")
                }
            }
        }
    }

    @Test func pullingOnTheBorderBowsItAndLeavesTheCornersPut() {
        // A one-patch grid, grabbed on the middle of its right edge and pulled 170 px out.
        let base = BezierMesh.identity(bounds: SIMD4(0, 0, 800, 1200), cols: 1, rows: 1)
        var m = base
        m.pull(base: base.points, s: 1, t: 0.5, d: SIMD2(170, 0))
        let at = m.eval(1, 0.5)
        #expect(abs(at.x - 970) < 1e-3 && abs(at.y - 600) < 1e-3, "\(at)")
        for (s, t) in [(0.0, 0.0), (1, 0), (0, 1), (1, 1)] {
            #expect(close(m.eval(s, t), base.eval(s, t), 1e-6), "corner (\(s), \(t)) moved")
        }
        // The other three edges did not move.
        for k in 0...10 {
            let u = Double(k) / 10
            for (s, t) in [(0.0, u), (u, 0), (u, 1)] {
                #expect(close(m.eval(s, t), base.eval(s, t), 1e-6), "edge point (\(s), \(t)) moved")
            }
        }
        // Only the right edge's two handles carry the pull.
        let nx = base.nx
        let moved = (0..<m.points.count).filter { m.points[$0] != base.points[$0] }
        #expect(moved == [nx + 3, 2 * nx + 3], "\(moved)")
        #expect(foldFraction(m) == 0)
    }

    @Test func pullKeepsTheSurfaceSmoothAcrossTheGridLines() {
        // A grid cut unevenly both ways, then pulled hard inside one cell and then another.
        var base = BezierMesh.identity(bounds: SIMD4(0, 0, 300, 300), cols: 1, rows: 1)
        for s in [0.3, 0.55, 0.9] {
            do { let ok = base.splitU(s); #expect(ok) }
            do { let ok = base.splitV(s); #expect(ok) }
        }
        #expect(tangentDefect(base) < 1e-9, "cuts are exact")
        for (s, t, d) in [(0.42, 0.42, SIMD2<Double>(60, -35)), (0.75, 0.2, SIMD2(-40, 50)), (0.1, 0.95, SIMD2(30, 30))] {
            var m = base
            m.pull(base: base.points, s: s, t: t, d: d)
            #expect(tangentDefect(m) < 1e-6, "(\(s), \(t)): \(tangentDefect(m))")
            let (before, after) = (base.eval(s, t), m.eval(s, t))
            #expect(abs(after.x - before.x - d.x) < 1e-4 && abs(after.y - before.y - d.y) < 1e-4, "\(after)")
        }
    }

    @Test func pullMovesTheGrabbedSurfacePointExactlyAndStaysLocal() {
        let base = BezierMesh.identity(bounds: b, cols: 3, rows: 2)
        for (s, t) in [(0.5, 0.5), (0.1, 0.9), (0.4, 0.25), (0.0, 0.5), (1.0, 0.3)] {
            var m = base
            let before = base.eval(s, t)
            m.pull(base: base.points, s: s, t: t, d: SIMD2(7, -4.5))
            let after = m.eval(s, t)
            #expect(abs(after.x - before.x - 7) < 1e-4 && abs(after.y - before.y + 4.5) < 1e-4, "(\(s), \(t)): \(after)")
        }
        // The pull stays near the grabbed patch: the far end of the grid does not move.
        var m = base
        m.pull(base: base.points, s: 0.1, t: 0.25, d: SIMD2(5, 5))
        let nx = base.nx
        func moved(_ k: Int) -> Bool { abs(m.points[k].x - base.points[k].x) > 1e-6 || abs(m.points[k].y - base.points[k].y) > 1e-6 }
        #expect((0..<base.ny).allSatisfy { !moved($0 * nx + nx - 1) }, "last column stays put")
        #expect((0..<nx).contains { moved($0) }, "something moved")
        // Pulling again from the same base replaces the pull (a drag is not cumulative).
        m.pull(base: base.points, s: 0.5, t: 0.25, d: .zero)
        #expect(zip(m.points, base.points).allSatisfy { close($0, $1, 1e-9) })
    }

    @Test func stylesParseAndRoundTripNames() throws {
        for s in WarpStyle.all {
            #expect(WarpStyle.parse(s.id) == s)
            #expect(WarpStyle.parse(s.psdName) == s)
            #expect(WarpStyle.parse(s.label) == s, "\(s)")
        }
        #expect(WarpStyle.parse("spiral") == nil)
        #expect(WarpStyle.arcLower.psdName == "warpArcLower")
        #expect(try encodeJSON(WarpStyle.shellUpper) == #""shellUpper""#)
    }

    @Test func presetsAtBendZeroAreIdentity() {
        for s in WarpStyle.presets {
            let w = Warp.preset(s, bend: 0, bounds: b)
            #expect(w.isIdentity)
            #expect(w.map(33, 44) == SIMD2(33, 44))
        }
    }

    @Test func identityMeshIsExactAndFitReproducesAffine() {
        let m = BezierMesh.identity(bounds: b, cols: 1, rows: 1)
        #expect(m.nx == 4 && m.ny == 4)
        let w = Warp.custom(m, bounds: b)
        #expect(w.isIdentity)
        #expect(close(w.map(37.5, 61.25), SIMD2(37.5, 61.25), 1e-9))
        // Affine maps fit exactly.
        let f = { (s: Double, t: Double) in SIMD2(3 + 2 * s - t, 1 + 0.5 * s + 4 * t) }
        let m2 = BezierMesh.fit(f, us: [0, 1], vs: [0, 0.4, 1])
        for (s, t) in [(0.1, 0.9), (0.5, 0.2), (0.77, 0.41)] {
            #expect(close(m2.eval(s, t), f(s, t), 1e-9))
        }
    }

    @Test func splitsAreExactAndRemovable() {
        var m = BezierMesh.identity(bounds: b, cols: 1, rows: 1)
        // Bend it: move an inner control point.
        m.points[5] = SIMD2(50, 10)
        let grid = (0...10).flatMap { j in (0...10).map { i in (Double(i) / 10, Double(j) / 10) } }
        let before = grid.map { m.eval($0.0, $0.1) }
        let orig = m
        do { let ok = m.splitU(0.3); #expect(ok) }
        do { let ok = m.splitV(0.6); #expect(ok) }
        do { let ok = !m.splitU(0.3); #expect(ok, "existing boundary") }
        #expect(m.nx == 7 && m.ny == 7)
        #expect(m.isValid)
        let after = grid.map { m.eval($0.0, $0.1) }
        for (a, c) in zip(before, after) { #expect(close(a, c, 1e-9)) }
        let st = m.paramAt(m.eval(0.42, 0.77))
        #expect(abs(st.x - 0.42) < 1e-6 && abs(st.y - 0.77) < 1e-6, "\(st)")
        do { let ok = m.removeSplitU(1); #expect(ok) }
        do { let ok = m.removeSplitV(1); #expect(ok) }
        #expect(m.us == orig.us)
        for (a, c) in zip(m.points, orig.points) { #expect(close(a, c, 1e-9)) }
    }

    let square = SIMD4<Double>(128, 128, 384, 384)
    let wide = SIMD4<Double>(128, 208, 384, 304)
    let tall = SIMD4<Double>(208, 128, 304, 384)

    /// Photoshop 27.11, measured: a 256 px grid image whose colours encode each pixel's own
    /// position, warped in a 512 px document over the box (128, 128)–(384, 384). Each pair is a
    /// source point and where Photoshop put it.
    @Test func presetsMatchPhotoshop() {
        typealias Pair = (SIMD2<Double>, SIMD2<Double>)
        let cases: [(WarpStyle, Double, Double, Double, Bool, SIMD4<Double>, [Pair])] = [
            (.arc, 50, 0, 0, false, square, [(SIMD2(272.5, 155.5), SIMD2(296.5, 104.5)), (SIMD2(331.5, 182.5), SIMD2(424.5, 168.5)), (SIMD2(259.5, 157.5), SIMD2(264.5, 104.5))]),
            (.arc, -100, 0, 0, false, square, [(SIMD2(277.5, 354.5), SIMD2(344.5, 472.5)), (SIMD2(140.5, 218.5), SIMD2(40.5, 168.5)), (SIMD2(172.5, 237.5), SIMD2(56.5, 264.5))]),
            (.flag, 50, 0, 0, false, square, [(SIMD2(136.5, 143.5), SIMD2(136.5, 120.5)), (SIMD2(136.5, 159.5), SIMD2(136.5, 136.5)), (SIMD2(136.5, 175.5), SIMD2(136.5, 152.5))]),
            (.twist, -50, 0, 0, false, square, [(SIMD2(148.5, 205.5), SIMD2(152.5, 216.5)), (SIMD2(197.5, 212.5), SIMD2(200.5, 232.5)), (SIMD2(134.5, 212.5), SIMD2(136.5, 216.5))]),
            (.shellLower, 50, 0, 0, false, square, [(SIMD2(248.5, 136.5), SIMD2(248.5, 136.5)), (SIMD2(264.5, 136.5), SIMD2(264.5, 136.5)), (SIMD2(232.5, 136.5), SIMD2(232.5, 136.5))]),
            (.fish, -100, 0, 0, false, square, [(SIMD2(296.5, 355.5), SIMD2(296.5, 440.5)), (SIMD2(344.5, 298.5), SIMD2(344.5, 344.5)), (SIMD2(328.5, 356.5), SIMD2(328.5, 472.5))]),
            (.bulge, 50, 50, 0, false, square, [(SIMD2(293.5, 147.5), SIMD2(296.5, 88.5)), (SIMD2(293.5, 375.5), SIMD2(296.5, 440.5)), (SIMD2(340.5, 281.5), SIMD2(344.5, 296.5))]),
            (.arc, 50, 0, -50, false, square, [(SIMD2(181.5, 350.5), SIMD2(184.5, 328.5)), (SIMD2(291.5, 372.5), SIMD2(280.5, 344.5)), (SIMD2(232.5, 349.5), SIMD2(232.5, 312.5))]),
            (.arc, 50, 0, 0, true, square, [(SIMD2(155.5, 272.5), SIMD2(104.5, 296.5)), (SIMD2(182.5, 331.5), SIMD2(168.5, 424.5)), (SIMD2(157.5, 259.5), SIMD2(104.5, 264.5))]),
            // Wide (256 × 96 at 128, 208) and tall (96 × 256 at 208, 128) boxes, and a vertical
            // warp with distortion.
            (.arc, 50, 0, 0, false, wide, [(SIMD2(144.5, 269.6), SIMD2(120.5, 264.5)), (SIMD2(271.5, 220.42), SIMD2(280.5, 168.5))]),
            (.bulge, 50, 0, 0, false, tall, [(SIMD2(249.11, 374.5), SIMD2(248.5, 392.5)), (SIMD2(249.11, 360.5), SIMD2(248.5, 376.5))]),
            (.flag, 50, 0, 0, true, wide, [(SIMD2(137.5, 296.42), SIMD2(184.5, 296.5)), (SIMD2(153.5, 296.42), SIMD2(200.5, 296.5))]),
            (.rise, 50, 0, 0, true, tall, [(SIMD2(250.97, 152.5), SIMD2(344.5, 152.5)), (SIMD2(301.26, 264.5), SIMD2(344.5, 264.5))]),
            (.bulge, 60, 20, -10, false, wide, [(SIMD2(208.5, 224.15), SIMD2(200.5, 184.5)), (SIMD2(219.5, 277.42), SIMD2(216.5, 296.5))]),
            (.arc, 50, 30, 0, true, square, [(SIMD2(331.5, 327.5), SIMD2(296.5, 360.5)), (SIMD2(318.5, 240.5), SIMD2(264.5, 232.5))]),
        ]
        for (style, bend, hd, vd, vertical, bounds, pairs) in cases {
            let w = Warp(style: style, bend: bend, hDistort: hd, vDistort: vd, vertical: vertical, bounds: bounds)
            for (src, want) in pairs {
                let got = w.map(src.x, src.y)
                let d = hypot(got.x - want.x, got.y - want.y)
                #expect(d < 1.5, "\(style) \(bend) h\(hd) v\(vd) vertical \(vertical) \(bounds): \(src) -> \(got), Photoshop \(want)")
            }
        }
    }

    @Test func presetFitsCloselyAsMeshAndAffineComposes() {
        let w = Warp.preset(.bulge, bend: 40, bounds: b)
        let m = Warp.custom(w.toMesh(cols: 4, rows: 4), bounds: b)
        for (x, y) in [(20.0, 30.0), (60, 45), (100, 65)] {
            #expect(close(w.map(x, y), m.map(x, y), 0.5), "\(w.map(x, y)) vs \(m.map(x, y))")
        }
        let t = Warp.custom(BezierMesh.identity(bounds: b, cols: 1, rows: 1), bounds: b).thenAffine(.translate(5, -2))
        #expect(close(t.map(50, 50), SIMD2(55, 48), 1e-9))
        let ob = Warp.none(b).outputBounds
        #expect(abs(ob.x - 10) < 1e-9 && abs(ob.w - 70) < 1e-9)
    }

    @Test func warpsSerializeWithPhotocraftKeys() throws {
        var w = Warp.preset(.arc, bend: 25, bounds: b)
        w.hDistort = 5
        #expect(try roundTrip(w) == w)
        let j = try jsonValue(w)
        #expect(j["hDistort"] == 5 && j["style"] == "arc" && j["bounds"] == [10, 20, 110, 70])
        let minimal = try decodeJSON(Warp.self, #"{"style":"custom","bounds":[0,0,1,1],"mesh":{"us":[0,1],"vs":[0,1],"points":[]}}"#)
        #expect(minimal.bend == 0 && !minimal.vertical && minimal.mesh?.isValid == false)
        // A malformed mesh from a file maps nothing and never traps.
        #expect(minimal.map(0.5, 0.5) == .zero)
        var bad = BezierMesh(us: [0], vs: [], points: [])
        do { let ok = !bad.splitU(0.5) && !bad.removeSplitU(1); #expect(ok) }
        bad.pull(base: [], s: 0.5, t: 0.5, d: SIMD2(1, 1))
        bad.dragPoint(base: [], index: 0, d: SIMD2(1, 1))
    }
}
