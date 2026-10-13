// Port of photocraft-algo (crates/algo/src/vanishing.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct GeometryVanishingTests {
    /// A ground plane seen by a camera with focal `f`: projects 3-D points.
    static func project(_ f: Double, _ c: SIMD2<Double>, _ p: SIMD3<Double>) -> SIMD2<Double> { SIMD2(c.x + f * p.x / p.z, c.y + f * p.y / p.z) }

    /// A 2 × 1 rectangle on a tilted plane, rotated about the vertical axis too.
    static func floorQuad(_ f: Double, _ c: SIMD2<Double>) -> VpPlane {
        let rx = 0.6, ry = 0.4
        func rot(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let s = sin(rx), co = cos(rx)
            let q = SIMD3(p.x, co * p.y - s * p.z, s * p.y + co * p.z)
            let s2 = sin(ry), c2 = cos(ry)
            return SIMD3(c2 * q.x + s2 * q.z, q.y, -s2 * q.x + c2 * q.z)
        }
        let corners = [SIMD3<Double>(-1, -0.5, 0), SIMD3(1, -0.5, 0), SIMD3(1, 0.5, 0), SIMD3(-1, 0.5, 0)].map { project(f, c, VpKit.add(rot($0), SIMD3(0, 0, 4))) }
        return VpPlane(corners: corners)
    }

    static let c = SIMD2<Double>(400, 300)

    @Test func focalAndMetricAspectFromOnePlane() {
        let pl = Self.floorQuad(500, Self.c)
        let f = pl.focal(Self.c)!
        #expect(abs(f - 500) < 1, "\(f)")
        let (lu, lv) = pl.lift(f, Self.c).lengths()
        #expect(abs(lu / lv - 2) < 0.01, "aspect \(lu / lv)")
    }

    @Test func planeCheckAndCornerOrder() {
        func q(_ v: [(Double, Double)]) -> VpPlane { VpPlane(corners: v.map { SIMD2($0.0, $0.1) }) }
        #expect(Self.floorQuad(500, Self.c).check(Self.c) == .valid)
        let square = q([(10, 10), (110, 10), (110, 110), (10, 110)])
        #expect(square.check(Self.c) == .valid, "fronto-parallel")
        #expect(q([(10, 10), (110, 110), (110, 10), (10, 110)]).check(Self.c) == .invalid)
        #expect(q([(10, 10), (110, 10), (40, 40), (10, 110)]).check(Self.c) == .invalid, "concave")
        #expect(q([(10, 10), (300, 10), (300, 40), (200, 40)]).check(Self.c) == .questionable, "a corner sharper than 10°")
        #expect(q([(.nan, 10), (110, 10), (110, 110), (10, 110)]).check(Self.c) == .invalid)
        // Clicked counter-clockwise from the bottom-right: clockwise from the top-left.
        #expect(q([(110, 110), (110, 10), (10, 10), (10, 110)]).normalized() == square)
    }

    @Test func tearOffIsPerpendicularAndSharesTheEdge() {
        var sc = VanishingPoint.Scene(first: Self.floorQuad(500, Self.c), center: Self.c, fallback: 800)
        let k = sc.tearOff(from: 0, edge: .top, angle: 90, depth: 1)!
        let p = sc.planes[k]
        #expect(abs(p.corners[3].x - sc.planes[0].corners[0].x) < 1e-6 && abs(p.corners[2].x - sc.planes[0].corners[1].x) < 1e-6)
        let a = sc.lifted(0), b = sc.lifted(k)
        let n1 = VpKit.norm(VpKit.cross(VpKit.sub(a.pts[1], a.pts[0]), VpKit.sub(a.pts[3], a.pts[0])))
        let n2 = VpKit.norm(VpKit.cross(VpKit.sub(b.pts[1], b.pts[0]), VpKit.sub(b.pts[3], b.pts[0])))
        #expect(abs(VpKit.dot(n1, n2)) < 0.02, "\(VpKit.dot(n1, n2))")
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func pasteAndCloneInPerspective(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        let sc = VanishingPoint.Scene(first: Self.floorQuad(500, Self.c), center: Self.c, fallback: 800)
        var img = Surface(format: .rgba8)
        img.fill(PixelRect(x0: 0, y0: 0, x1: 100, y1: 50), with: [1, 0, 0, 1])
        let out = VanishingPoint.paste(sc, plane: 0, img, srcRect: PixelRect(x0: 0, y0: 0, x1: 100, y1: 50), at: SIMD2(0.25, 0.25), width: 0.5, on: backend)!
        // The pasted rectangle lands inside the plane, around plane (0.5, 0.5).
        let h = sc.planes[0].homography()!
        var (x, y) = h.apply(0.5, 0.5)
        #expect(out.pixel(x: Int32(x), y: Int32(y))[3] > 0.9)
        (x, y) = h.apply(0.1, 0.1)
        #expect(out.pixel(x: Int32(x), y: Int32(y))[3] < 0.1)
        // Clone: paint a red dot near the far edge from a red source near the near edge.
        var s = Surface(format: .rgba8)
        s.fill(PixelRect(x0: 0, y0: 0, x1: 800, y1: 600), with: [0.2, 0.2, 0.2, 1])
        let (sx, sy) = h.apply(0.5, 0.8)
        s.fill(PixelRect(x0: Int32(sx) - 6, y0: Int32(sy) - 6, x1: Int32(sx) + 6, y1: Int32(sy) + 6), with: [1, 0, 0, 1])
        let (dx, dy) = h.apply(0.5, 0.3)
        let n = VanishingPoint.cloneStroke(sc, &s, source: SIMD2(sx, sy), points: [SIMD2(dx, dy)], size: 10, hardness: 0.8, opacity: 1)
        #expect(n == 1)
        #expect(s.pixel(x: Int32(dx), y: Int32(dy))[0] > 0.8, "\(s.pixel(x: Int32(dx), y: Int32(dy)))")
    }

    @Test func codableMatchesPhotocraft() throws {
        let p = try JSONDecoder().decode(VpPlane.self, from: Data(#"{"corners":[[0,0],[10,0],[10,10],[0,10]]}"#.utf8))
        #expect(p.corners[2] == SIMD2(10, 10))
        #expect(try JSONDecoder().decode(VanishingPoint.Edge.self, from: Data(#""bottom""#.utf8)) == .bottom)
    }

    /// Pasting onto a plane on the GPU vs the CPU over the channel variants.
    @Test func pasteParity() throws {
        let sc = VanishingPoint.Scene(first: Self.floorQuad(500, Self.c), center: Self.c, fallback: 800)
        let rect = PixelRect(x: 3, y: -2, width: 61, height: 47)
        var worst: Float = 0
        for (at, width) in [(SIMD2(0.25, 0.25), 0.5), (SIMD2(0.05, 0.4), 0.9), (SIMD2(0.6, 0.1), 0.08)] {
            let e = try GEO.variants(rect) { img, ctx, b in try VanishingPoint.paste(sc, plane: 0, img, at: at, width: width, context: ctx, on: b)! }
            guard let e else { return }
            #expect(e <= 1.0 / 255.0, "\(at) \(width): \(e)")
            worst = max(worst, e)
        }
        ParityLog.record("VanishingPoint paste", worst)
    }
}
