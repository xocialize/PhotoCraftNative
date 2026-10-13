// Port of photocraft-algo (crates/algo/src/segment/tests.rs, segment/sky.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// Shared scenes of the segment tests.
enum SegTest {
    /// A textured disc on a noisy background: (image, ground-truth mask) — photocraft `disc_scene`.
    static func discScene(_ w: Int, _ h: Int, _ cx: Float, _ cy: Float, _ r: Float, seed: UInt64) -> (SegmentRGBImage, [Bool]) {
        var rng = SegmentKit.Rng(seed)
        var img = SegmentRGBImage(w: w, h: h)
        var truth = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let dx = Float(x) + 0.5 - cx, dy = Float(y) + 0.5 - cy
                let inside = dx * dx + dy * dy <= r * r
                truth[y * w + x] = inside
                let n = 0.05 * rng.normal()
                let p: SIMD3<Float>
                if inside {
                    // Stripes between two warm colours plus noise.
                    let t = clampf(sinf(Float(x + y) * 0.35) * 0.5 + 0.5, 0, 1)
                    p = SIMD3(0.85 + 0.05 * t + n, 0.2 + 0.3 * t + n, 0.15 + n)
                } else {
                    p = SIMD3(0.25 + n, 0.45 + n, 0.7 + n)
                }
                img.px[y * w + x] = SIMD3(clampf(p.x, 0, 1), clampf(p.y, 0, 1), clampf(p.z, 0, 1))
            }
        }
        return (img, truth)
    }

    /// Intersection over union of a region (coverage ≥ 0.5) and a mask.
    static func iou(_ region: SelectionRegion, _ truth: [Bool], _ w: Int, _ h: Int) -> Float {
        var inter = 0, uni = 0
        for y in 0..<h {
            for x in 0..<w {
                let a = region.at(Int32(x), Int32(y)) >= 0.5
                let b = truth[y * w + x]
                if a && b { inter += 1 }
                if a || b { uni += 1 }
            }
        }
        return Float(inter) / Float(max(uni, 1))
    }

    static func canvas(_ w: Int, _ h: Int) -> PixelRect { PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h)) }

    /// Blue gradient sky over textured ground, with a dark round "tree" crown on a trunk reaching
    /// into the sky (photocraft sky tests' `landscape`).
    static func landscape(_ w: Int, _ h: Int) -> SegmentRGBImage {
        let horizon = h * 3 / 5
        return SegmentRGBImage(w: w, h: h) { x, y in
            let cx = Float(w) * 0.7, cy = Float(h) * 0.35, rr = Float(h) * 0.18
            let ex = Float(x) - cx, ey = Float(y) - cy
            let inCrown = (ex * ex + ey * ey).squareRoot() < rr
            let inTrunk = abs(Float(x) - cx) < 3 && Float(y) > cy && y < horizon
            let n = (Float((x * 7919 + y * 104_729) % 97) / 97 - 0.5) * 0.25
            if inCrown { return SIMD3(0.1 + n * 0.5, 0.35 + n, 0.1 + n * 0.5) }
            if inTrunk { return SIMD3(0.3 + n * 0.3, 0.2, 0.1) }
            if y < horizon {
                let t = Float(y) / Float(horizon)
                return SIMD3(0.25 + 0.4 * t, 0.5 + 0.3 * t, 0.9 + 0.05 * t)
            }
            return SIMD3(0.35 + n, 0.3 + n, 0.15 + n * 0.5)
        }
    }
}

struct SegmentTests {
    // MARK: GMM

    @Test func gmmRecoversSyntheticClusters() throws {
        var rng = SegmentKit.Rng(3)
        let truth: [(SIMD3<Float>, Float, Float)] = [(SIMD3(0.2, 0.3, 0.8), 0.03, 0.5), (SIMD3(0.8, 0.2, 0.1), 0.05, 0.3), (SIMD3(0.5, 0.9, 0.4), 0.02, 0.2)]
        var samples: [SIMD3<Float>] = []
        for (mean, sd, w) in truth {
            for _ in 0..<Int(w * 6000) {
                let a = mean.x + sd * rng.normal()
                let b = mean.y + sd * rng.normal()
                let c = mean.z + sd * rng.normal()
                samples.append(SIMD3(a, b, c))
            }
        }
        let g = try #require(GMM.fit(samples, k: 3, reg: GMM.defaultReg))
        #expect(g.comps.count == 3)
        for (mean, sd, w) in truth {
            let c = try #require(g.comps.min { QuickSelection.d2($0.mean, mean) < QuickSelection.d2($1.mean, mean) })
            let d = QuickSelection.d2(c.mean, mean).squareRoot()
            #expect(d < 0.01, "\(c.mean) vs \(mean)")
            #expect(abs(Float(c.weight) - w) < 0.03, "\(c.weight) vs \(w)")
            let sdFit = Float(c.cov[0][0]).squareRoot()
            #expect(abs(sdFit - sd) < 0.01, "sd \(sdFit) vs \(sd)")
        }
        #expect(g.negLog(SIMD3(0.2, 0.3, 0.8)) < g.negLog(SIMD3(0.5, 0.5, 0.5)))
        // Refit keeps the model stable.
        let r = try #require(g.refit(samples))
        #expect(r.comps.count == 3)
    }

    // MARK: SLIC

    @Test func slicCountsCompactnessAndEdges() throws {
        var rng = SegmentKit.Rng(11)
        let (w, h) = (120, 120)
        var img = SegmentRGBImage(w: w, h: h) { x, _ in x < 60 ? SIMD3(0.8, 0.3, 0.2) : SIMD3(0.2, 0.5, 0.8) }
        img.px = img.px.map { p in
            let a = clampf(p.x + 0.02 * rng.normal(), 0, 1)
            let b = clampf(p.y + 0.02 * rng.normal(), 0, 1)
            let c = clampf(p.z + 0.02 * rng.normal(), 0, 1)
            return SIMD3(a, b, c)
        }
        let sp = try SLIC.slic(img, target: 64, compactness: 10, iters: 10)
        #expect((40...90).contains(sp.count), "count \(sp.count)")
        var bbox = [(Int, Int, Int, Int)](repeating: (Int.max, Int.max, 0, 0), count: sp.count)
        var left = [Int](repeating: 0, count: sp.count), total = [Int](repeating: 0, count: sp.count)
        for y in 0..<h {
            for x in 0..<w {
                let l = Int(sp.labels[y * w + x])
                let b = bbox[l]
                bbox[l] = (min(b.0, x), min(b.1, y), max(b.2, x), max(b.3, y))
                total[l] += 1
                if x < 60 { left[l] += 1 }
            }
        }
        let s = sp.step
        for (l, b) in bbox.enumerated() {
            #expect(total[l] > 0)
            #expect(Float(b.2 - b.0 + 1) <= 3 * s && Float(b.3 - b.1 + 1) <= 3 * s, "superpixel \(l) too elongated: \(b) (S=\(s))")
            // Superpixels respect the strong colour edge.
            let purity = Float(max(left[l], total[l] - left[l])) / Float(total[l])
            #expect(purity > 0.95, "superpixel \(l) straddles the edge (\(purity))")
        }
    }

    // MARK: GrabCut / object selection

    @Test func grabcutTrimapOnDisc() throws {
        let (img, truth) = SegTest.discScene(120, 100, 60, 50, 30, seed: 1)
        var tri = [UInt8](repeating: GrabCut.bg, count: img.w * img.h)
        for y in 12..<88 { for x in 22..<98 { tri[y * img.w + x] = GrabCut.prFG } }
        _ = try #require(GrabCut.grabcut(img, trimap: &tri, iters: 8))
        var inter = 0, uni = 0
        for (t, g) in zip(tri, truth) {
            let a = t == GrabCut.prFG || t == GrabCut.fg
            if a && g { inter += 1 }
            if a || g { uni += 1 }
        }
        let iou = Float(inter) / Float(uni)
        #expect(iou > 0.95, "IoU \(iou)")
    }

    @Test func objectSelectDiscFullResolution() throws {
        let (img, truth) = SegTest.discScene(200, 160, 100, 80, 50, seed: 2)
        let s = ImageSegmentSampler(img, origin: (0, 0))
        let reg = try #require(GrabCut.objectSelect(s, canvas: SegTest.canvas(200, 160), rect: PixelRect(x0: 40, y0: 20, x1: 160, y1: 140), workPx: 1_000_000))
        let v = SegTest.iou(reg, truth, 200, 160)
        #expect(v > 0.95, "IoU \(v)")
    }

    @Test func objectSelectDownsampledWithBandRefinement() throws {
        let (img, truth) = SegTest.discScene(640, 480, 330, 250, 150, seed: 3)
        let s = ImageSegmentSampler(img, origin: (0, 0))
        // A small working budget forces step > 1 and the full-resolution band re-cut.
        let reg = try #require(GrabCut.objectSelect(s, canvas: SegTest.canvas(640, 480), rect: PixelRect(x0: 160, y0: 80, x1: 500, y1: 420), workPx: 20_000))
        let v = SegTest.iou(reg, truth, 640, 480)
        #expect(v > 0.95, "IoU \(v)")
        // Boundary accuracy: few pixels wrong far (> 2 px) from the true edge.
        var farWrong = 0
        for y in 0..<480 {
            for x in 0..<640 {
                let dx = Float(x) + 0.5 - 330, dy = Float(y) + 0.5 - 250
                let d = (dx * dx + dy * dy).squareRoot() - 150
                if abs(d) > 2 && (reg.at(Int32(x), Int32(y)) >= 0.5) != truth[y * 640 + x] { farWrong += 1 }
            }
        }
        #expect(farWrong < 300, "\(farWrong) pixels wrong away from the edge")
    }

    // MARK: Select Subject

    @Test func selectSubjectFindsCentredObject() throws {
        let (img, truth) = SegTest.discScene(200, 150, 100, 75, 40, seed: 6)
        let reg = try #require(SelectSubject.select(ImageSegmentSampler(img, origin: (0, 0)), canvas: SegTest.canvas(200, 150)))
        let v = SegTest.iou(reg, truth, 200, 150)
        #expect(v > 0.9, "IoU \(v)")
    }

    @Test func saliencyHighlightsTheObject() {
        let (img, truth) = SegTest.discScene(120, 90, 60, 45, 22, seed: 8)
        let sal = SelectSubject.saliency(img)
        var fi: Float = 0, fn: Float = 0, bi: Float = 0, bn: Float = 0
        for (s, t) in zip(sal, truth) {
            if t { fi += s; fn += 1 } else { bi += s; bn += 1 }
        }
        #expect(fi / fn > 0.6 && bi / bn < 0.25, "fg \(fi / fn) bg \(bi / bn)")
    }

    // MARK: Focus Area

    @Test func focusAreaSelectsSharpHalf() throws {
        var rng = SegmentKit.Rng(12)
        let (w, h) = (160, 100)
        let noise = (0..<(w * h)).map { _ in rng.f32() }
        // Right half: heavily blurred copy of the texture.
        let blurred = Matting.boxMean(noise, w: w, h: h, r: 4)
        let img = SegmentRGBImage(w: w, h: h) { x, y in
            let v = x < 80 ? noise[y * w + x] : blurred[y * w + x]
            return SIMD3(v, v * 0.8, 0.3)
        }
        let reg = try #require(FocusArea.select(ImageSegmentSampler(img, origin: (0, 0)), canvas: SegTest.canvas(w, h), range: 0.5, noise: 0))
        var l = 0, r = 0
        for y in 0..<Int32(h) {
            for x in 0..<Int32(w) where reg.at(x, y) >= 0.5 {
                if x < 80 { l += 1 } else { r += 1 }
            }
        }
        #expect(Float(l) > 0.85 * 80 * Float(h), "sharp half \(l)")
        #expect(Float(r) < 0.1 * 80 * Float(h), "blurred half \(r)")
    }

    // MARK: Helpers

    @Test func samplerDownsamplingMatchesImageDownsample() {
        let img = SegmentRGBImage(w: 37, h: 29) { x, y in SIMD3(Float(x) / 37, Float(y) / 29, Float((x * y) % 7) / 7) }
        let s = ImageSegmentSampler(img, origin: (5, 3))
        let a = s.rgbScaled(PixelRect(x0: 5, y0: 3, x1: 42, y1: 32), step: 4)
        let b = img.downsample(4)
        #expect(a.w == b.w && a.h == b.h)
        var worst: Float = 0
        for (p, q) in zip(a.px, b.px) { for c in 0..<3 { worst = max(worst, abs(p[c] - q[c])) } }
        #expect(worst < 1e-5)
    }

    @Test func cleanMaskDropsIslandsAndFillsHoles() {
        let (w, h) = (40, 40)
        var m = [Bool](repeating: false, count: w * h)
        for y in 5..<30 { for x in 5..<30 { m[y * w + x] = true } }
        m[15 * w + 15] = false // hole
        m[36 * w + 36] = true // island
        let c = Segment.cleanMask(m, w: w, h: h, frac: 0.1, holeFrac: 0.05)
        #expect(c[15 * w + 15])
        #expect(!c[36 * w + 36])
    }

    // MARK: Select Sky

    @Test func findsSkyAndNotGroundOrTree() throws {
        let img = SegTest.landscape(160, 100)
        let r = try #require(SelectSky.select(ImageSegmentSampler(img, origin: (0, 0)), canvas: SegTest.canvas(160, 100)))
        #expect(r.at(10, 5) > 0.9, "top-left sky")
        #expect(r.at(80, 50) > 0.9, "sky near the horizon")
        #expect(r.at(10, 80) < 0.1, "ground")
        #expect(r.at(112, 35) < 0.1, "tree crown")
        #expect(r.bbox.y1 <= 64, "\(r.bbox)")
    }

    @Test func noSkyInAGroundOnlyImage() {
        let img = SegmentRGBImage(w: 64, h: 64) { x, y in
            let n = (Float((x * 7919 + y * 104_729) % 97) / 97 - 0.5) * 0.3
            return SIMD3(0.35 + n, 0.3 + n, 0.12)
        }
        #expect(SelectSky.select(ImageSegmentSampler(img, origin: (0, 0)), canvas: SegTest.canvas(64, 64)) == nil)
    }

    @Test func overcastSkyIsFound() throws {
        let img = SegmentRGBImage(w: 64, h: 64) { _, y in y < 30 ? SIMD3(0.85, 0.86, 0.88) : SIMD3(0.2, 0.3, 0.1) }
        let r = try #require(SelectSky.select(ImageSegmentSampler(img, origin: (0, 0)), canvas: SegTest.canvas(64, 64)))
        #expect(r.at(30, 10) > 0.9 && r.at(30, 50) < 0.1)
    }

    @Test func colourPriorRanksSkyOverFoliage() {
        #expect(SelectSky.colourPrior(SIMD3(0.4, 0.6, 0.95)) > 0.8)
        #expect(SelectSky.colourPrior(SIMD3(0.15, 0.4, 0.15)) < 0.1)
        #expect(SelectSky.colourPrior(SIMD3(0.9, 0.9, 0.92)) > 0.8)
    }
}
