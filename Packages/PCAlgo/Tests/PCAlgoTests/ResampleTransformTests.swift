// Port of photocraft-algo (crates/algo/src/transform.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct ResampleTransformTests {
    static func q(_ v: [(Double, Double)]) -> [SIMD2<Double>] { v.map { SIMD2($0.0, $0.1) } }

    /// Perspective Crop's map lands each quad corner exactly on its rectangle corner; degenerate,
    /// self-crossing, counter-clockwise and non-finite quads have none.
    @Test func quadToRectMapsCornersAndRefusesBadQuads() {
        let quad = Self.q([(30, 12), (140, 25), (128, 110), (14, 95)])
        let h = Transform.quadToRect(quad, width: 100, height: 80)!
        for (c, want) in zip(quad, Self.q([(0, 0), (100, 0), (100, 80), (0, 80)])) {
            let (x, y) = h.apply(c.x, c.y)
            #expect(abs(x - want.x) < 1e-9 && abs(y - want.y) < 1e-9, "\(c) -> (\(x), \(y))")
        }
        let (w, ht) = Transform.quadSize(quad)
        #expect(abs(w - 112.874) < 1e-3 && abs(ht - 85.185) < 1e-3, "\(w) x \(ht)")
        for bad in [
            Self.q([(0, 0), (50, 0), (100, 0), (0, 50)]),
            Self.q([(0, 0), (50, 50), (50, 0), (0, 50)]),
            Self.q([(0, 0), (0, 50), (50, 50), (50, 0)]),
            Self.q([(0, 0), (.nan, 0), (50, 50), (0, 50)]),
            Self.q([(0, 0), (0, 0), (0, 0), (0, 0)]),
        ] {
            #expect(Transform.quadToRect(bad, width: 10, height: 10) == nil, "\(bad)")
        }
        #expect(Transform.quadToRect(quad, width: 0, height: 10) == nil)
    }

    @Test func homographyMapsRectCornersAndInverts() {
        let r = [10.0, 20, 110, 70]
        let quad = Self.q([(0, 0), (200, 10), (180, 150), (-20, 120)])
        let h = Homography.rectToQuad(r, quad)!
        for (p, e) in zip([(10.0, 20.0), (110, 20), (110, 70), (10, 70)], quad) {
            let (x, y) = h.apply(p.0, p.1)
            #expect(abs(x - e.x) < 1e-9 && abs(y - e.y) < 1e-9, "\(p) → \(x),\(y) vs \(e)")
        }
        let inv = h.inverse()!
        let (x, y) = inv.apply(90, 60)
        let (bx, by) = h.apply(x, y)
        #expect(abs(bx - 90) < 1e-9 && abs(by - 60) < 1e-9)
        let degenerate = Homography.rectToQuad(r, Self.q([(0, 0), (0, 0), (0, 0), (0, 0)]))
        #expect(degenerate == nil || degenerate!.inverse() == nil)
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func steepDistortKeepsEveryPixelInsideTheQuad(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        // Corner C is almost flat, so the horizon of the inverse map crosses the 256-px tiles that
        // also hold quad pixels; those tiles must still read every source pixel that lands in them.
        var s = Surface(format: .rgba8)
        s.fill(PixelRect(x0: 0, y0: 0, x1: 100, y1: 100), with: [1, 0, 0, 1])
        let r = s.contentBounds
        let h = Homography.rectToQuad([0, 0, 100, 100], Self.q([(0, 0), (300, 0), (155, 155), (0, 300)]))!
        let w = Transform.warpSurface(s, srcRect: r, h: h, interp: .nearest, on: backend)
        for (x, y) in [(Int32(20), Int32(20)), (252, 14), (252, 42), (14, 252), (42, 252)] {
            let a = w.readRegion(PixelRect(x0: x, y0: y, x1: x + 1, y1: y + 1))[3]
            #expect(a > 0.99, "(\(x),\(y)) inside the quad is transparent: \(a)")
        }
        for (x, y) in [(Int32(200), Int32(200)), (280, 100), (100, 280)] {
            #expect(w.readRegion(PixelRect(x0: x, y0: y, x1: x + 1, y1: y + 1))[3] == 0, "(\(x),\(y)) outside the quad is painted")
        }
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func identityAndTranslationAreExact(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        var s = Surface(format: .rgba8)
        s.fill(PixelRect(x0: 4, y0: 4, x1: 20, y1: 12), with: [1, 0.5, 0, 1])
        let r = s.contentBounds
        for interp in Interp.allCases {
            let h = Homography([1, 0, 7, 0, 1, -3, 0, 0, 1])
            let o = Transform.warpSurface(s, srcRect: r, h: h, interp: interp, on: backend)
            #expect(o.contentBounds == PixelRect(x0: 11, y0: 1, x1: 27, y1: 9), "\(interp)")
            #expect(o.pixel(x: 15, y: 5) == [1, 128 / 255, 0, 1], "\(interp)")
        }
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func translationPreservesColourRangeAtEveryDepth(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        let h = Homography([1, 0, 7, 0, 1, -3, 0, 0, 1])
        for sample in SampleType.allCases {
            for mode in [ColorMode.rgb, .grayscale] {
                for alpha in [false, true] {
                    var s = Surface(format: PixelFormat(mode: mode, sample: sample, alpha: alpha))
                    var pixel: [Float] = mode == .rgb ? [2, -0.25, 0.5] : [2]
                    if alpha { pixel.append(0.5) }
                    s.fill(PixelRect(x0: 4, y0: 4, x1: 8, y1: 8), with: pixel)
                    var expected = s.pixel(x: 5, y: 5)
                    if !alpha { expected.append(1) }
                    for interp in Interp.allCases {
                        let out = Transform.warpSurface(s, srcRect: s.contentBounds, h: h, interp: interp, on: backend)
                        #expect(out.pixel(x: 12, y: 2) == expected, "\(sample)/\(mode)/alpha=\(alpha)/\(interp)")
                        #expect(out.pixel(x: 0, y: 0).last == 0)
                    }
                }
            }
        }
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func bilinearTranslationInterpolatesSignedHDRColours(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        var s = Surface(format: .rgba32f)
        s.setPixel(x: 0, y: 0, [2, -0.5, 0.25, 0.5])
        s.setPixel(x: 1, y: 0, [4, -0.25, 0.75, 0.5])
        let h = Homography([1, 0, 0.5, 0, 1, 0, 0, 0, 1])
        let out = Transform.warpSurface(s, srcRect: s.contentBounds, h: h, interp: .bilinear, on: backend)
        #expect(out.pixel(x: 1, y: 0) == [3, -0.375, 0.5, 0.5])
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func scaleDoublesSizeAndRotationKeepsArea(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        var s = Surface(format: .rgba8)
        s.fill(PixelRect(x0: 0, y0: 0, x1: 40, y1: 20), with: [0.2, 0.4, 0.6, 1])
        let r = s.contentBounds
        let up = Transform.warpSurface(s, srcRect: r, h: Homography.rectToQuad([0, 0, 40, 20], Self.q([(0, 0), (80, 0), (80, 40), (0, 40)]))!,
                                       interp: .bicubic, on: backend)
        var b = up.contentBounds
        #expect(b.width >= 80 && b.width <= 82 && b.height >= 40 && b.height <= 42, "\(b)")
        // 90° rotation about (20, 10): a 40×20 box becomes 20×40.
        let quad = Self.q([(30, -10), (30, 30), (10, 30), (10, -10)])
        let rot = Transform.warpSurface(s, srcRect: r, h: Homography.rectToQuad([0, 0, 40, 20], quad)!, interp: .bilinear, on: backend)
        b = rot.contentBounds
        #expect(abs(b.width - 20) <= 2 && abs(b.height - 40) <= 2, "\(b)")
        let p = rot.pixel(x: 20, y: 10)
        #expect(abs(p[0] - 0.2) < 0.01 && p[3] > 0.99, "\(p)")
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func largeDownscaleIsPrefiltered(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        // A 1px checkerboard shrunk 8× must come out ~50% grey, not aliased black/white.
        var s = Surface(format: .rgba8)
        for y in Int32(0)..<64 { for x in Int32(0)..<64 { let v = Float((x + y) % 2); s.fill(PixelRect(x0: x, y0: y, x1: x + 1, y1: y + 1), with: [v, v, v, 1]) } }
        let h = Homography.rectToQuad([0, 0, 64, 64], Self.q([(0, 0), (8, 0), (8, 8), (0, 8)]))!
        let o = Transform.warpSurface(s, srcRect: s.contentBounds, h: h, interp: .bicubic, on: backend)
        let p = o.pixel(x: 4, y: 4)
        #expect(abs(p[0] - 0.5) < 0.1, "\(p)")
    }

    @Test(arguments: [Backend.cpu, .gpu])
    func surfacesWithoutAlphaGainIt(_ backend: Backend) {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        var s = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: false))
        s.fill(PixelRect(x0: 0, y0: 0, x1: 10, y1: 10), with: [1, 0, 0])
        let h = Homography([1, 0, 5, 0, 1, 0, 0, 0, 1])
        let o = Transform.warpSurface(s, srcRect: PixelRect(x0: 0, y0: 0, x1: 10, y1: 10), h: h, interp: .nearest, on: backend)
        #expect(o.format.alpha)
        #expect(o.pixel(x: 2, y: 2)[3] == 0)
        #expect(o.pixel(x: 7, y: 2) == [1, 0, 0, 1])
    }

    @Test func homographyIsIdentity() {
        #expect(Homography.identity.isIdentity)
        #expect(Homography([2, 0, 0, 0, 2, 0, 0, 0, 2]).isIdentity)
        #expect(!Homography([1, 0, 1, 0, 1, 0, 0, 0, 1]).isIdentity)
        #expect(!Homography([1, 0.1, 0, 0, 1, 0, 0, 0, 1]).isIdentity)
    }

    /// Quarter turns with nearest sampling are exact pixel permutations (and so is a half turn and
    /// a flip), on the CPU and the GPU, at every channel layout.
    @Test(arguments: [Backend.cpu, .gpu])
    func quarterTurnsWithNearestArePixelPermutations(_ backend: Backend) throws {
        if backend == .gpu && !AlgoGPU.isAvailable { return }
        let rect = PixelRect(x: -7, y: 5, width: 33, height: 21)
        // Source pixel (x, y) → destination: 90° clockwise about the origin is (−y − 1, x) for
        // pixel indices, from the point map (x, y) → (−y, x).
        let maps: [(Homography, (Int32, Int32) -> (Int32, Int32))] = [
            (Homography([0, -1, 0, 1, 0, 0, 0, 0, 1]), { x, y in (-y - 1, x) }),
            (Homography([-1, 0, 0, 0, -1, 0, 0, 0, 1]), { x, y in (-x - 1, -y - 1) }),
            (Homography([0, 1, 0, -1, 0, 0, 0, 0, 1]), { x, y in (y, -x - 1) }),
            (Homography([-1, 0, 10, 0, 1, 3, 0, 0, 1]), { x, y in (9 - x, y + 3) }),
            (Homography.rectToQuad([-7, 5, 26, 26], Self.q([(26, -7), (26, 26), (5, 26), (5, -7)]))!, { x, y in (25 - (y - 5) + 0, x) }),
        ]
        for ch in [1, 2, 3, 4, 5] {
            let alpha = ch == 2 || ch == 4 || ch == 5
            let img = TestImage.make(rect, channels: ch, alpha: alpha, seed: 7)
            let ctx = FilterContext.inferred(channels: ch, bounds: rect)
            for (h, f) in maps {
                let o = try Transform.warp(img, h: h, interp: .nearest, context: ctx, on: backend)
                let n = o.channels
                for y in rect.y0..<rect.y1 {
                    for x in rect.x0..<rect.x1 {
                        let (dx, dy) = f(x, y)
                        let si = img.index(x: x, y: y), di = o.index(x: dx, y: dy)
                        let a: Float = alpha ? img.data[si + ch - 1] : 1
                        if a == 0 { #expect(o.data[di + n - 1] == 0); continue }
                        // Colour goes through premultiplication and back: exact up to the f32
                        // rounding of c·a / a.
                        for c in 0..<(alpha ? ch - 1 : ch) {
                            #expect(abs(o.data[di + c] - img.data[si + c]) <= 1e-6, "\(ch)ch \(h.m) (\(x),\(y)) c\(c)")
                        }
                        #expect(o.data[di + n - 1] == a)
                    }
                }
            }
        }
    }

    /// The dense-image warp gives the surface warp's pixels.
    @Test func denseImageMatchesSurface() throws {
        let rect = PixelRect(x: 3, y: 2, width: 45, height: 31)
        let img = TestImage.make(rect, channels: 4, alpha: true, seed: 4)
        let s = RS.surface(img, .rgba32f)
        let hs = [
            Homography.rectToQuad([3, 2, 48, 33], Self.q([(10, 0), (70, 12), (60, 50), (0, 40)]))!,
            Homography.rectToQuad([3, 2, 48, 33], Self.q([(10, 0), (20, 2), (18, 9), (9, 8)]))!,
        ]
        for h in hs {
            for interp in Interp.allCases {
                let a = Transform.warpSurface(s, srcRect: rect, h: h, interp: interp, on: .cpu)
                let b = try Transform.warp(img, h: h, interp: interp, on: .cpu)
                let d = RS.maxDiff(a.readRegion(b.rect), b.data)
                #expect(d < 1e-6, "\(interp): \(d)")
                #expect(b.rect.contains(a.contentBounds))
            }
        }
    }
}
