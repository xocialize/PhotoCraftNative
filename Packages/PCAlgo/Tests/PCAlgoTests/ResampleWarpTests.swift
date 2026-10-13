// Port of photocraft-algo (crates/algo/src/warp.rs and perspective.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct ResampleWarpTests {
    func sample(_ s: SampleType) -> Surface {
        var surf = Surface(format: PixelFormat(mode: .rgb, sample: s, alpha: true))
        for y in Int32(0)..<24 {
            for x in Int32(0)..<40 {
                let v = Float((x * 7 + y * 13) % 17) / 16
                surf.setPixel(x: x + 5, y: y + 3, [v, 1 - v, Float(x) / 40, 1])
            }
        }
        return surf
    }

    /// photocraft #995: the old and warped regions are written separately, not as one dense
    /// `src ∪ warped` buffer, for a 48 px selection moved 100000 px.
    @Test(arguments: [Backend.cpu, .auto])
    func aMeshWarpFarOffCanvasWritesOnlyTheTwoRegions(_ backend: Backend) {
        for sample in [SampleType.u8, .f32] {
            var sel = Surface(format: PixelFormat(mode: .grayscale, sample: sample, alpha: false))
            sel.fill(PixelRect(x0: 8, y0: 8, x1: 56, y1: 56), with: [1])
            for d in [100_000.0, -100_000.0, 300.0] {
                let out = MeshWarp.warpMeshGray(sel, map: { x, y in (x + d, y + d) }, interp: .bilinear, on: backend)
                let k = Int32(d)
                #expect(out.contentBounds == PixelRect(x0: 8 + k, y0: 8 + k, x1: 56 + k, y1: 56 + k), "\(sample) \(d)")
                #expect(out.pixel(x: 30 + k, y: 30 + k)[0] == 1, "\(sample) \(d): moved")
                #expect(out.pixel(x: 30, y: 30)[0] == 0, "\(sample) \(d): old region cleared")
            }
        }
    }

    /// The identity map, also as a numerically noisy one (photocraft's Warp::none, an identity
    /// Bezier mesh and a 0 % Arc all reduce to it), reproduces every depth within one 8-bit level.
    @Test(arguments: [Backend.cpu, .auto])
    func identityWarpIsANoOpAtEveryDepth(_ backend: Backend) {
        let maps: [(Double, Double) -> (Double, Double)] = [
            { x, y in (x, y) },
            { x, y in ((x * 3 + 0.1) / 3 - 0.1 / 3, (y / 7) * 7) },
        ]
        for s in [SampleType.u8, .u16, .f32] {
            let src = sample(s)
            let r = src.contentBounds
            for map in maps {
                for interp in Interp.allCases {
                    let out = MeshWarp.warpMeshSurface(src, srcRect: r, map: map, interp: interp, on: backend)
                    #expect(out.contentBounds == r, "\(s) \(interp)")
                    let worst = RS.maxDiff(src.readRegion(r), out.readRegion(r))
                    #expect(worst <= 1.0 / 255.0, "\(s) \(interp): \(worst)")
                }
            }
        }
    }

    /// photocraft `translation_and_known_arc_points`, translation part (the Arc preset lives in
    /// photocraft-geom's `Warp`, not ported here).
    @Test(arguments: [Backend.cpu, .auto])
    func translationMovesPixelsExactly(_ backend: Backend) {
        let src = sample(.u8)
        let r = src.contentBounds
        let out = MeshWarp.warpMeshSurface(src, srcRect: r, map: { x, y in (x + 10, y - 2) }, interp: .bilinear, on: backend)
        #expect(out.contentBounds == r.offsetBy(dx: 10, dy: -2))
        #expect(out.pixel(x: 20, y: 10) == src.pixel(x: 10, y: 12))
    }

    /// A smooth bend that lifts the top edge and widens it (an Arc-like stand-in).
    static func bend(_ w: Double, _ h: Double, _ amount: Double) -> (Double, Double) -> (Double, Double) {
        { x, y in
            let u = x / w - 0.5, v = y / h
            return (x + amount * u * w * (1 - v), y - amount * h * (1 - 4 * u * u) * (1 - v))
        }
    }

    /// A warped smart object placed at ~1/5 size: a grid of 1 px lines every 4 px must come out
    /// its area average (9/16 white) everywhere, not point-sampled moiré (photocraft
    /// `a_shrinking_mesh_warp_is_prefiltered`, with a bend in place of the 15 % Arc preset).
    @Test(arguments: [Backend.cpu, .auto])
    func aShrinkingMeshWarpIsPrefiltered(_ backend: Backend) {
        for s in [SampleType.u8, .u16, .f32] {
            let (w, h): (Int32, Int32) = (400, 320)
            var src = Surface(format: PixelFormat(mode: .rgb, sample: s, alpha: true))
            let px: [Float] = (0..<h).flatMap { y in (0..<w).flatMap { x -> [Float] in
                let v: Float = x % 4 == 0 || y % 4 == 0 ? 0 : 1
                return [v, v, v, 1]
            } }
            let r = PixelRect(x0: 0, y0: 0, x1: w, y1: h)
            src.writeRegion(r, px)
            let t = CGAffineTransform(a: 0.2, b: 0, c: 0, d: 0.2, tx: 7, ty: 5)
            let out = MeshWarp.placeSource(src, srcRect: r, transform: t, warp: Self.bend(Double(w), Double(h), 0.15), on: backend)
            let b = out.contentBounds
            let o = out.readRegion(b)
            let opaque = stride(from: 0, to: o.count, by: 4).filter { o[$0 + 3] >= 0.999 }.map { o[$0] }
            #expect(opaque.count > 2000, "\(s): \(opaque.count) opaque pixels")
            let worst = opaque.map { abs($0 - 0.5625) }.max() ?? 1
            // An area average over the ~5 px footprint still covers one or two lines per axis (up to
            // 0.2 off); point sampling lands wholly on or off a line (up to 0.56 off).
            #expect(worst < 0.25, "\(s): worst deviation from the area average \(worst)")
        }
    }

    @Test(arguments: [Backend.cpu, .auto])
    func grayMasksKeepTheirDefault(_ backend: Backend) {
        var m = Surface(format: .gray8, defaultPixel: [1])
        m.fill(PixelRect(x0: 4, y0: 4, x1: 10, y1: 10), with: [0])
        let o = MeshWarp.warpMeshGray(m, map: { x, y in (x + 5, y) }, interp: .bilinear, on: backend)
        #expect(o.pixel(x: 0, y: 0) == [1])
        #expect(o.pixel(x: 12, y: 6) == [0])
        #expect(o.pixel(x: 5, y: 6) == [1])
    }

    /// The dense-image mesh warp gives the surface warp's pixels.
    @Test func denseImageMatchesSurface() throws {
        let rect = PixelRect(x: 3, y: 2, width: 45, height: 31)
        let img = TestImage.make(rect, channels: 4, alpha: true, seed: 4)
        let s = RS.surface(img, .rgba32f)
        for map in [Self.bend(45, 31, 0.3), { x, y in (x * 0.3 + 0.07 * y, y * 0.25 + 3) }] {
            for interp in Interp.allCases {
                let a = MeshWarp.warpMeshSurface(s, srcRect: rect, map: map, interp: interp, on: .cpu)
                let b = try MeshWarp.warpMesh(img, map: map, interp: interp, on: .cpu)
                let d = RS.maxDiff(a.readRegion(b.rect), b.data)
                #expect(d < 1e-6, "\(interp): \(d)")
                #expect(b.rect.contains(a.contentBounds))
            }
        }
    }

    // MARK: perspective.rs

    static func close(_ a: (Double, Double), _ b: (Double, Double), _ tol: Double) -> Bool {
        abs(a.0 - b.0) <= tol && abs(a.1 - b.1) <= tol
    }

    static func q(_ v: [(Double, Double)]) -> [SIMD2<Double>] { v.map { SIMD2($0.0, $0.1) } }

    @Test func perspectiveIdentityAndAKnownHomography() {
        let quad = Self.q([(10, 10), (90, 12), (85, 70), (12, 75)])
        let m = PerspectiveMap(planes: [.identity(quad)])!
        for p in [(20.0, 20.0), (50, 40), (0, 0), (120, 90)] {
            #expect(Self.close(m.map(p.0, p.1), p, 1e-9), "\(p) → \(m.map(p.0, p.1))")
        }
        // Square → trapezoid: corners land exactly, the centre lands where the homography says.
        let src = Self.q([(0, 0), (100, 0), (100, 100), (0, 100)])
        let dst = Self.q([(20, 0), (80, 0), (100, 100), (0, 100)])
        let m2 = PerspectiveMap(planes: [PerspectiveMap.Plane(src: src, dst: dst)])!
        for (s, d) in zip(src, dst) { #expect(Self.close(m2.map(s.x, s.y), (d.x, d.y), 1e-9)) }
        let h = Homography.rectToQuad([0, 0, 100, 100], dst)!
        #expect(Self.close(m2.map(50, 50), h.apply(50, 50), 1e-9))
        // The diagonals' crossing stays the crossing.
        let c = m2.map(50, 50)
        #expect(abs(c.0 - 50) < 1e-9 && c.1 < 50, "\(c)")
    }

    @Test func perspectiveSharedEdgesStayContinuous() {
        // Two planes sharing the edge x = 50 (with slightly mismatched corners that get linked).
        let a = PerspectiveMap.Plane(src: Self.q([(0, 0), (50, 0), (50, 100), (0, 100)]), dst: Self.q([(0, 10), (50, 0), (55, 100), (0, 90)]))
        let b = PerspectiveMap.Plane(src: Self.q([(50.2, 0), (100, 0), (100, 100), (50, 100.2)]), dst: Self.q([(50, 0), (110, 20), (100, 80), (55, 100)]))
        let m = PerspectiveMap(planes: [a, b])!
        // After linking, the shared edge runs from (50.1, 0) to (50, 100.1).
        for t in [0.05, 0.25, 0.5, 0.77, 0.95] {
            let (x, y) = (50.1 - 0.1 * t, 100.1 * t)
            let l = m.map(x - 1e-6, y), r = m.map(x + 1e-6, y)
            #expect(Self.close(l, r, 1e-4), "t=\(t): \(l) vs \(r)")
        }
        #expect(PerspectiveMap.linkedCorners([.identity(Self.q([(0, 0), (0, 0), (0, 0), (0, 0)]))]).count == 1)
    }

    @Test func perspectiveStraightenLevelsAndPlumbsEdges() {
        var ps = [PerspectiveMap.Plane(src: Self.q([(0, 0), (100, 0), (100, 100), (0, 100)]), dst: Self.q([(0, 3), (100, -2), (96, 100), (4, 104)]))]
        PerspectiveMap.straighten(&ps, mode: .vertical)
        #expect(ps[0].dst[1].x == ps[0].dst[2].x)
        #expect(ps[0].dst[0].x == ps[0].dst[3].x)
        #expect(ps[0].dst[0].y != ps[0].dst[1].y)
        PerspectiveMap.straighten(&ps, mode: .auto)
        #expect(ps[0].dst[0].y == ps[0].dst[1].y)
        #expect(ps[0].dst[2].y == ps[0].dst[3].y)
        #expect(PerspectiveMap.Straighten(parsing: "Level") == .horizontal && PerspectiveMap.Straighten(parsing: "x") == nil)
    }

    /// A Perspective Warp resampled through the mesh warp: identity planes leave the image alone.
    @Test func perspectiveWarpThroughTheMesh() {
        let src = sample(.u8)
        let r = src.contentBounds
        let quad = Self.q([(Double(r.x0), Double(r.y0)), (Double(r.x1), Double(r.y0)), (Double(r.x1), Double(r.y1)), (Double(r.x0), Double(r.y1))])
        let m = PerspectiveMap(planes: [.identity(quad)])!
        let out = MeshWarp.warpMeshSurface(src, srcRect: r, map: m.map, interp: .bicubic, on: .auto)
        #expect(RS.maxDiff(src.readRegion(r), out.readRegion(r)) <= 1.0 / 255.0)
    }
}
