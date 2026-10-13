// Port of photocraft-algo (crates/algo/src/features.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct PhotoFeaturesTests {
    /// Deterministic textured test image: blobs of varying brightness.
    static func texture(_ w: Int, _ h: Int) -> [Float] {
        var rng = PhotoKit.Rng(42)
        var img = [Float](repeating: 0.3, count: w * h)
        for _ in 0..<140 {
            let cx = rng.unit() * Double(w), cy = rng.unit() * Double(h)
            let r = 3.0 + rng.unit() * 9.0
            let v = Float(rng.unit())
            let sq = rng.unit() > 0.5
            for y in 0..<h {
                for x in 0..<w {
                    let dx = Double(x) - cx, dy = Double(y) - cy
                    let inside = sq ? (abs(dx) < r && abs(dy) < r * 0.6) : hypot(dx, dy) < r
                    if inside { img[y * w + x] = v }
                }
            }
        }
        return img
    }

    /// Resamples `img` by destination → source lookup `inv`, bilinear, edge-clamped.
    static func warp(_ w: Int, _ hgt: Int, _ img: [Float], _ inv: Homography) -> [Float] {
        var out = [Float](repeating: 0.3, count: w * hgt)
        for y in 0..<hgt {
            for x in 0..<w {
                let (sx, sy) = inv.apply(Double(x), Double(y))
                if sx < 0 || sy < 0 || sx >= Double(w - 1) || sy >= Double(hgt - 1) { continue }
                let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
                let tx = Float(sx - Double(x0)), ty = Float(sy - Double(y0))
                func p(_ xx: Int, _ yy: Int) -> Float { img[yy * w + xx] }
                let top = p(x0, y0) + (p(x0 + 1, y0) - p(x0, y0)) * tx
                let bot = p(x0, y0 + 1) + (p(x0 + 1, y0 + 1) - p(x0, y0 + 1)) * tx
                out[y * w + x] = top + (bot - top) * ty
            }
        }
        return out
    }

    @Test func harrisFindsSquareCorners() throws {
        let (w, h) = (80, 80)
        var img = [Float](repeating: 0, count: w * h)
        for y in 30..<50 { for x in 30..<50 { img[y * w + x] = 1 } }
        for backend in PhotoTest.backends {
            let c = try Features.harris(width: w, height: h, img, max: 10, minDist: 5, on: backend)
            #expect(c.count >= 4, "\(c)")
            for (x, y): (Float, Float) in [(30, 30), (49, 49)] {
                #expect(c.contains { abs($0.x - x) <= 2 && abs($0.y - y) <= 2 }, "corner near (\(x),\(y)): \(c)")
            }
        }
    }

    @Test func fitsAreExactOnCleanData() {
        let src: [SIMD2<Double>] = [[0, 0], [10, 0], [10, 10], [0, 10], [5, 3]]
        let truth = Homography([1.1, 0.05, 3.0, -0.02, 0.95, -2.0, 0.001, 0.0005, 1.0])
        let dst = src.map { p in let q = truth.apply(p.x, p.y); return SIMD2(q.0, q.1) }
        let h = Features.fit(.homography, src: src, dst: dst)!
        for p in src {
            let a = h.apply(p.x, p.y), b = truth.apply(p.x, p.y)
            #expect(abs(a.0 - b.0) < 1e-6 && abs(a.1 - b.1) < 1e-6)
        }
        let sim = Homography([0.9, -0.2, 4.0, 0.2, 0.9, 1.0, 0.0, 0.0, 1.0])
        let dst2 = src.map { p in let q = sim.apply(p.x, p.y); return SIMD2(q.0, q.1) }
        let h2 = Features.fit(.similarity, src: src, dst: dst2)!
        #expect(zip(h2.m, sim.m).allSatisfy { abs($0 - $1) < 1e-9 })
    }

    @Test func ransacRejectsOutliers() {
        var src: [SIMD2<Double>] = [], dst: [SIMD2<Double>] = []
        for i in 0..<40 {
            let p = SIMD2(Double(i * 7 % 50), Double(i * 13 % 50))
            src.append(p)
            dst.append(i % 4 == 0 ? SIMD2(p.x * 3 + 40, -p.y) : SIMD2(p.x + 12, p.y - 5))
        }
        let (h, inl) = Features.ransac(.translation, src: src, dst: dst, iters: 100, threshold: 1, seed: 1)!
        #expect(inl.count == 30)
        #expect(abs(h.m[2] - 12) < 1e-9 && abs(h.m[5] + 5) < 1e-9)
    }

    @Test func registersTranslationAndSimilarity() throws {
        let (w, h) = (192, 160)
        let reference = Self.texture(w, h)
        let shift = Homography([1, 0, 9, 0, 1, -6, 0, 0, 1])
        let moving = Self.warp(w, h, reference, shift.inverse()!)
        for backend in PhotoTest.backends {
            let (m, n) = try Features.register(width: w, height: h, reference: reference, moving: moving, model: .translation, on: backend)!
            #expect(n >= 6)
            #expect(abs(m.m[2] + 9) < 1 && abs(m.m[5] - 6) < 1, "\(m)")
            let c = cos(PhotoKit.radians(4)) * 1.03, s = sin(PhotoKit.radians(4)) * 1.03
            let cx = Double(w) / 2, cy = Double(h) / 2
            let sim = Homography([c, -s, cx - c * cx + s * cy, s, c, cy - s * cx - c * cy, 0, 0, 1])
            let moving2 = Self.warp(w, h, reference, sim.inverse()!)
            let (m2, _) = try Features.register(width: w, height: h, reference: reference, moving: moving2, model: .similarity, on: backend)!
            for p: SIMD2<Double> in [[40, 40], [150, 120], [96, 80]] {
                let (x, y) = sim.apply(p.x, p.y)
                let (bx, by) = m2.apply(x, y)
                #expect(abs(bx - p.x) < 1.5 && abs(by - p.y) < 1.5, "\(p) → \(bx),\(by)")
            }
        }
    }

    @Test func descriptorsAreDeterministic() throws {
        let (w, h) = (96, 96)
        let img = Self.texture(w, h)
        let c = try Features.harris(width: w, height: h, img, max: 50, minDist: 6)
        #expect(Features.describe(width: w, height: h, img, corners: c, upright: false) == Features.describe(width: w, height: h, img, corners: c, upright: false))
        #expect(Features.hamming(SIMD4(0, 0, 0, 0), SIMD4(1, 3, 0, UInt64.max)) == 67)
    }

    /// The Metal Harris response reproduces the CPU's corners exactly (same positions, scores and
    /// order) on textured, flat-plateau and small images.
    @Test func harrisGPUParity() throws {
        guard PhotoTest.gpu else { return }
        var mismatches = 0
        for (w, h, seed) in [(192, 160, 1), (97, 61, 2), (33, 40, 3), (300, 200, 4)] {
            var img = Self.texture(w, h)
            if seed == 3 { img = img.map { min($0, 0.5) } }
            if seed == 4 { img = PhotoTest.pixels(w, h, 1, seed: 4) }
            let valid: [Bool]? = seed == 2 ? (0..<(w * h)).map { $0 % w < w * 3 / 4 } : nil
            let a = try Features.harris(width: w, height: h, img, max: 400, minDist: 3, valid: valid, on: .cpu)
            let b = try Features.harris(width: w, height: h, img, max: 400, minDist: 3, valid: valid, on: .gpu)
            if a != b { mismatches += 1 }
            if seed == 1 || seed == 4 { #expect(a.count > 20, "\(a.count) corners") }
        }
        ParityLog.record("Features harris (corner mismatches)", Float(mismatches))
        #expect(mismatches == 0)
    }
}
