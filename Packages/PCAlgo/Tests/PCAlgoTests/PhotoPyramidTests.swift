// Port of photocraft-algo (crates/algo/src/pyramid.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// Shared helpers of the photo-area tests (photocraft's test-module helpers).
enum PhotoTest {
    static func checker(_ w: Int, _ h: Int, _ cell: Int, _ ch: Int) -> [Float] {
        var px = [Float](repeating: 0, count: w * h * ch)
        for y in 0..<h {
            for x in 0..<w {
                let v: Float = ((x / cell) + (y / cell)) % 2 == 0 ? 0.2 : 0.8
                for c in 0..<ch {
                    px[(y * w + x) * ch + c] = c == 0 ? v : c == 1 ? v * 0.9 : c == 2 ? v * 0.5 : 1
                }
            }
        }
        return px
    }

    static func lumaOf(_ w: Int, _ h: Int, _ ch: Int, _ px: [Float]) -> [Float] {
        (0..<(w * h)).map { i in ch >= 3 ? 0.2126 * px[i * ch] + 0.7152 * px[i * ch + 1] + 0.0722 * px[i * ch + 2] : px[i * ch] }
    }

    /// Every channel blurred with the 5-tap kernel `passes` times (no decimation).
    static func blurImg(_ w: Int, _ h: Int, _ ch: Int, _ px: [Float], _ passes: Int) -> [Float] {
        var planes: [[Float]] = (0..<ch).map { c in (0..<(w * h)).map { px[$0 * ch + c] } }
        for _ in 0..<passes {
            for c in 0..<ch { planes[c] = Pyramid.windowSum(w, h, planes[c], Pyramid.k) }
        }
        return (0..<(w * h * ch)).map { planes[$0 % ch][$0 / ch] }
    }

    static func rms(_ a: [Float], _ b: [Float]) -> Float {
        var s = 0.0
        for (x, y) in zip(a, b) { s += Double((x - y) * (x - y)) }
        return Float((s / Double(a.count)).squareRoot())
    }

    static func maxDiff(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "size \(a.count) vs \(b.count)")
        var m: Float = 0
        for (x, y) in zip(a, b) {
            let d = abs(x - y)
            if d.isNaN { return .infinity }
            m = max(m, d)
        }
        return m
    }

    /// Deterministic 8-bit-quantised test pixels (TestImage) as an interleaved buffer.
    static func pixels(_ w: Int, _ h: Int, _ ch: Int, seed: UInt32, hdr: Bool = false) -> [Float] {
        TestImage.make(PixelRect(x: 0, y: 0, width: w, height: h), channels: ch, alpha: false, seed: seed, hdr: hdr).data
    }

    static var gpu: Bool { MetalContext.shared != nil && AlgoGPU.isAvailable }
}

@Suite struct PhotoPyramidTests {
    @Test func laplacianRoundTripIsExact() {
        let (w, h) = (37, 23)
        let img: [Float] = (0..<(w * h * 2)).map { Float(($0 * 37) % 101) / 101 }
        let pyr = Pyramid.laplacian(width: w, height: h, channels: 2, img, levels: 5)
        #expect(pyr.count == 5)
        let back = Pyramid.collapse(pyr, channels: 2)
        #expect(zip(img, back).allSatisfy { abs($0 - $1) < 1e-4 })
    }

    @Test func blendWithOneHotWeightsReproducesEachSide() throws {
        let (w, h) = (64, 32)
        let a = [Float](repeating: 0.2, count: w * h), b = [Float](repeating: 0.8, count: w * h)
        let wa: [Float] = (0..<(w * h)).map { $0 % w < 32 ? 1 : 0 }
        let wb = wa.map { 1 - $0 }
        let out = try Pyramid.blend(width: w, height: h, channels: 1, images: [a, b], weights: [wa, wb],
                                    levels: Pyramid.autoLevels(width: w, height: h), on: .cpu)
        #expect(abs(out[5 * w + 2] - 0.2) < 1e-3)
        #expect(abs(out[5 * w + 61] - 0.8) < 1e-3)
        let mid = out[5 * w + 31]
        #expect(mid > 0.3 && mid < 0.7, "\(mid)")
    }

    @Test func stackPicksTheSharpImage() {
        let (w, h) = (48, 48)
        func checker(_ x: Int, _ y: Int) -> Float { (x / 2 + y / 2) % 2 == 0 ? 0.1 : 0.9 }
        let i0: [Float] = (0..<(w * h)).map { $0 % w < 24 ? checker($0 % w, $0 / w) : 0.5 }
        let i1: [Float] = (0..<(w * h)).map { $0 % w >= 24 ? checker($0 % w, $0 / w) : 0.5 }
        let ones = [Float](repeating: 1, count: w * h)
        let wts = Pyramid.stackWeights(width: w, height: h, luma: [i0, i1], alpha: [ones, ones])
        #expect(wts[0][20 * w + 4] == 1)
        #expect(wts[1][20 * w + 44] == 1)
    }

    @Test func panoramaSplitsTheOverlap() {
        let (w, h) = (60, 20)
        let a: [Float] = (0..<(w * h)).map { $0 % w < 40 ? 1 : 0 }
        let b: [Float] = (0..<(w * h)).map { $0 % w >= 20 ? 1 : 0 }
        let wts = Pyramid.panoramaWeights(width: w, height: h, alpha: [a, b])
        #expect(wts[0][10 * w + 5] == 1)
        #expect(wts[1][10 * w + 55] == 1)
        let seam = (0..<w).first { wts[1][10 * w + $0] == 1 }!
        #expect((25...35).contains(seam), "\(seam)")
    }

    @Test func stackLevelsKeepTheResidualAbove32Px() {
        #expect(Pyramid.stackLevels(width: 64, height: 64) == 2)
        #expect(Pyramid.stackLevels(width: 48, height: 100) == 1)
        #expect(Pyramid.stackLevels(width: 2070, height: 1378) == 6)
        #expect(Pyramid.stackLevels(width: 8280, height: 5520) == 8)
        #expect(Pyramid.stackLevels(width: 100_000, height: 100_000) == 10)
    }

    @Test func binomialWindowAndWindowSum() {
        #expect(Pyramid.binomial(0) == [1])
        #expect(Pyramid.binomial(1) == [0.25, 0.5, 0.25])
        #expect(zip(Pyramid.binomial(2), Pyramid.k).allSatisfy { abs($0 - $1) < 1e-6 })
        let flat = [Float](repeating: 0.3, count: 7 * 5)
        #expect(Pyramid.windowSum(7, 5, flat, Pyramid.binomial(1)).allSatisfy { abs($0 - 0.3) < 1e-6 })
        #expect(Pyramid.windowSum(7, 5, flat, Pyramid.binomial(0)) == flat)
    }

    @Test func deviationAndEntropyMeasureLocalStructure() {
        let (w, h) = (20, 20)
        let flat = [Float](repeating: 0.5, count: w * h)
        let (d, e) = Pyramid.deviationEntropy(w, h, flat)
        #expect(d.allSatisfy { $0 == 0 } && e.allSatisfy { $0 == 0 })
        let check = PhotoTest.lumaOf(w, h, 1, PhotoTest.checker(w, h, 1, 1))
        let (d2, e2) = Pyramid.deviationEntropy(w, h, check)
        #expect(d2[10 * w + 10] > 0.08 && e2[10 * w + 10] > 0.6, "\(d2[10 * w + 10]) \(e2[10 * w + 10])")
    }

    @Test func fuseStackIdenticalImagesAreAFixedPoint() throws {
        let (w, h, ch) = (70, 50, 3)
        let im = PhotoTest.checker(w, h, 7, ch)
        let lm = PhotoTest.lumaOf(w, h, ch, im)
        let ones = [Float](repeating: 1, count: w * h)
        let three = Pyramid.StackFusion(levels: 3)
        var noHalo = three; noHalo.halo = 0
        var guide1 = three; guide1.guide = 1
        var r0 = three; r0.energyRadius = 0
        for backend in PhotoTest.backends {
            for p in [three, noHalo, guide1, r0] {
                let out = try Pyramid.fuseStack(width: w, height: h, channels: ch, images: [im, im, im], luma: [lm, lm, lm], alpha: [ones, ones, ones], p, on: backend)
                #expect(PhotoTest.rms(out, im) < 1e-5, "\(p): \(PhotoTest.rms(out, im))")
            }
            #expect(PhotoTest.rms(try Pyramid.fuseStack(width: w, height: h, channels: ch, images: [im], luma: [lm], alpha: [ones], three, on: backend), im) < 1e-5)
            #expect(try Pyramid.fuseStack(width: w, height: h, channels: ch, images: [], luma: [], alpha: [], three, on: backend) == [Float](repeating: 0, count: w * h * ch))
            let many = Pyramid.StackFusion(levels: 40)
            #expect(PhotoTest.rms(try Pyramid.fuseStack(width: w, height: h, channels: ch, images: [im], luma: [lm], alpha: [ones], many, on: backend), im) < 1e-5)
        }
    }

    @Test func fuseStackPicksTheSharpHalfFromEachImage() throws {
        let (w, h, ch) = (96, 64, 4)
        let sharp = PhotoTest.checker(w, h, 6, ch)
        let soft = PhotoTest.blurImg(w, h, ch, sharp, 6)
        var a = sharp, b = sharp
        for i in 0..<(w * h) {
            for c in 0..<ch {
                if i % w >= w / 2 { a[i * ch + c] = soft[i * ch + c] } else { b[i * ch + c] = soft[i * ch + c] }
            }
        }
        let la = PhotoTest.lumaOf(w, h, ch, a), lb = PhotoTest.lumaOf(w, h, ch, b)
        let ones = [Float](repeating: 1, count: w * h)
        for backend in PhotoTest.backends {
            for p in [Pyramid.StackFusion(halo: 0), Pyramid.StackFusion(energyRadius: 0, halo: 0), Pyramid.StackFusion(guide: 0)] {
                let out = try Pyramid.fuseStack(width: w, height: h, channels: ch, images: [a, b], luma: [la, lb], alpha: [ones, ones], p, on: backend)
                let err = PhotoTest.rms(out, sharp)
                #expect(err < 0.3 * PhotoTest.rms(a, sharp), "\(p): fused rms \(err)")
                #expect(stride(from: 3, to: out.count, by: ch).allSatisfy { abs(out[$0] - 1) < 1e-4 }, "alpha stays opaque")
                let e1 = abs(out[(20 * w + 10) * ch] - sharp[(20 * w + 10) * ch]), e2 = abs(out[(20 * w + 85) * ch + 1] - sharp[(20 * w + 85) * ch + 1])
                let tol: Float = p.halo > 0 ? 1e-3 : 0.1
                #expect(e1 < tol && e2 < tol, "\(p): \(e1) \(e2)")
            }
            let wts = Pyramid.stackWeights(width: w, height: h, luma: [la, lb], alpha: [ones, ones])
            let old = try Pyramid.blend(width: w, height: h, channels: ch, images: [a, b], weights: wts, levels: Pyramid.autoLevels(width: w, height: h), on: backend)
            let new = try Pyramid.fuseStack(width: w, height: h, channels: ch, images: [a, b], luma: [la, lb], alpha: [ones, ones], on: backend)
            #expect(PhotoTest.rms(new, sharp) <= PhotoTest.rms(old, sharp), "new \(PhotoTest.rms(new, sharp)) old \(PhotoTest.rms(old, sharp))")
        }
    }

    @Test func fuseStackIgnoresUncoveredPixels() throws {
        let (w, h, ch) = (96, 64, 4)
        let sharp = PhotoTest.checker(w, h, 6, ch)
        let a: [Float] = (0..<(w * h * ch)).map { $0 % ch == 3 ? 1 : 0.5 }
        let b: [Float] = (0..<(w * h * ch)).map { i in ((i / ch) % w < w / 2) ? sharp[i] : (i % ch == 3 ? 0 : 1) }
        let alphaB: [Float] = (0..<(w * h)).map { $0 % w < w / 2 ? 1 : 0 }
        let la = PhotoTest.lumaOf(w, h, ch, a), lb = PhotoTest.lumaOf(w, h, ch, b)
        let ones = [Float](repeating: 1, count: w * h)
        for backend in PhotoTest.backends {
            for p in [Pyramid.StackFusion(halo: 0), Pyramid.StackFusion(guide: 0)] {
                let out = try Pyramid.fuseStack(width: w, height: h, channels: ch, images: [a, b], luma: [la, lb], alpha: [ones, alphaB], p, on: backend)
                #expect(abs(out[(30 * w + 12) * ch] - sharp[(30 * w + 12) * ch]) < 0.05, "\(p)")
                for x in [60, 70, 90] {
                    let px = out[((30 * w + x) * ch)..<((30 * w + x + 1) * ch)]
                    #expect(px.prefix(3).allSatisfy { abs($0 - 0.5) < 0.03 }, "\(p): x \(x) \(Array(px))")
                }
            }
        }
    }

    @Test func haloControlKeepsTheCoarseLevelsWithTheGuide() throws {
        let (w, h, ch) = (192, 144, 3)
        let a = PhotoTest.checker(w, h, 6, ch)
        var b = PhotoTest.blurImg(w, h, ch, a, 64)
        for y in 0..<h {
            for x in 0..<w {
                let d2 = powf(Float(x) - 96, 2) + powf(Float(y) - 72, 2)
                let bump = 0.35 * expf(-d2 / (2 * powf(20, 2)))
                for c in 0..<ch { b[(y * w + x) * ch + c] = min(b[(y * w + x) * ch + c] + bump, 1) }
            }
        }
        let ones = [Float](repeating: 1, count: w * h)
        for backend in PhotoTest.backends {
            func fuse(_ halo: Float, _ imgs: [[Float]]) throws -> [Float] {
                let l = [PhotoTest.lumaOf(w, h, ch, imgs[0]), PhotoTest.lumaOf(w, h, ch, imgs[1])]
                return try Pyramid.fuseStack(width: w, height: h, channels: ch, images: imgs, luma: l, alpha: [ones, ones],
                                             Pyramid.StackFusion(halo: halo, guide: 2, levels: 5), on: backend)
            }
            let off = PhotoTest.rms(try fuse(0, [a, b]), a)
            #expect(off > 0.05, "without halo control the bump gets in: rms \(off)")
            for halo: Float in [1, 2, 4, 8, 100] {
                let on = PhotoTest.rms(try fuse(halo, [a, b]), a)
                #expect(on < 0.15 * off, "halo \(halo): rms \(on) vs \(off) without")
            }
            #expect(PhotoTest.rms(try fuse(2, [b, a]), a) < 0.15 * off)
        }
        #expect(abs(Pyramid.haloWeight(Pyramid.haloRef - Pyramid.haloFloor, 3) - 1) < 1e-5)
        #expect(Pyramid.haloWeight(1e-3, 2) > Pyramid.haloWeight(1e-4, 2))
        #expect(Pyramid.haloWeight(0, 8) > 0 && Pyramid.haloWeight(1e3, 8).isFinite)
    }

    @Test func residualRuleTakesTheImageThatWinsDeviationAndEntropy() throws {
        let (w, h, ch) = (40, 40, 3)
        let a = PhotoTest.checker(w, h, 2, ch)
        let b = [Float](repeating: 0.5, count: w * h * ch)
        let ones = [Float](repeating: 1, count: w * h)
        let one = Pyramid.StackFusion(halo: 0, levels: 1)
        for backend in PhotoTest.backends {
            let out = try Pyramid.fuseStack(width: w, height: h, channels: ch, images: [b, a], luma: [PhotoTest.lumaOf(w, h, ch, b), PhotoTest.lumaOf(w, h, ch, a)],
                                            alpha: [ones, ones], one, on: backend)
            #expect(PhotoTest.rms(out, a) < 1e-6)
            let out2 = try Pyramid.fuseStack(width: w, height: h, channels: ch, images: [b, a], luma: [PhotoTest.lumaOf(w, h, ch, a), PhotoTest.lumaOf(w, h, ch, a)],
                                             alpha: [ones, ones], one, on: backend)
            let mean = zip(a, b).map { ($0 + $1) / 2 }
            #expect(PhotoTest.rms(out2, mean) < 1e-6)
        }
    }
}

extension PhotoTest {
    /// The CPU, and the GPU when there is one.
    static var backends: [Backend] { gpu ? [.cpu, .gpu] : [.cpu] }
}

/// GPU vs CPU parity of the pyramid operations (max absolute difference; 0 = bit-identical).
@Suite struct PhotoPyramidParityTests {
    @Test func gaussianLaplacianCollapse() throws {
        guard PhotoTest.gpu else { return }
        var worst: Float = 0
        for (w, h, ch, levels) in [(37, 23, 2, 5), (64, 48, 4, 4), (101, 7, 5, 10), (1, 9, 3, 6), (130, 97, 1, 3)] {
            let px = PhotoTest.pixels(w, h, ch, seed: UInt32(w), hdr: true)
            let gc = Pyramid.gaussian(width: w, height: h, channels: ch, px, levels: levels)
            let gg = try Pyramid.gaussian(width: w, height: h, channels: ch, px, levels: levels, on: .gpu)
            #expect(gc.count == gg.count)
            for (a, b) in zip(gc, gg) { #expect(a.w == b.w && a.h == b.h); worst = max(worst, PhotoTest.maxDiff(a.px, b.px)) }
            let lc = Pyramid.laplacian(width: w, height: h, channels: ch, px, levels: levels)
            let lg = try Pyramid.laplacian(width: w, height: h, channels: ch, px, levels: levels, on: .gpu)
            for (a, b) in zip(lc, lg) { worst = max(worst, PhotoTest.maxDiff(a.px, b.px)) }
            let cc = Pyramid.collapse(lc, channels: ch)
            let cg = try Pyramid.collapse(lc, channels: ch, on: .gpu)
            worst = max(worst, PhotoTest.maxDiff(cc, cg))
        }
        ParityLog.record("Pyramid gaussian/laplacian/collapse", worst)
        #expect(worst == 0)
    }

    @Test func blend() throws {
        guard PhotoTest.gpu else { return }
        var worst: Float = 0
        for (w, h, ch, n, levels) in [(64, 48, 4, 3, 5), (37, 23, 5, 2, 10), (50, 50, 1, 4, 1), (90, 31, 3, 2, 3)] {
            let imgs = (0..<n).map { PhotoTest.pixels(w, h, ch, seed: UInt32(3 + $0), hdr: $0 == 1) }
            let wts: [[Float]] = (0..<n).map { k in (0..<(w * h)).map { i in hash01(Int32(i % w), Int32(i / w), UInt32(k), 9) > 0.5 ? Float(k + 1) * 0.3 : 0 } }
            let c = try Pyramid.blend(width: w, height: h, channels: ch, images: imgs, weights: wts, levels: levels, on: .cpu)
            let g = try Pyramid.blend(width: w, height: h, channels: ch, images: imgs, weights: wts, levels: levels, on: .gpu)
            worst = max(worst, PhotoTest.maxDiff(c, g))
        }
        ParityLog.record("Pyramid blend", worst)
        #expect(worst == 0)
    }

    @Test func stackWeights() throws {
        guard PhotoTest.gpu else { return }
        var mismatches = 0
        for (w, h, n) in [(64, 48, 3), (200, 130, 2), (37, 300, 4)] {
            var luma = (0..<n).map { PhotoTest.pixels(w, h, 1, seed: UInt32(30 + $0)) }
            luma[1] = PhotoTest.blurImg(w, h, 1, luma[1], 2)
            let alpha: [[Float]] = (0..<n).map { k in (0..<(w * h)).map { i in k == 0 && i % w < w / 3 ? 0 : 1 } }
            let c = try Pyramid.stackWeights(width: w, height: h, luma: luma, alpha: alpha, on: .cpu)
            let g = try Pyramid.stackWeights(width: w, height: h, luma: luma, alpha: alpha, on: .gpu)
            if c != g { mismatches += 1 }
        }
        ParityLog.record("Pyramid stackWeights (mismatching sets)", Float(mismatches))
        #expect(mismatches == 0)
    }

    @Test func fuseStack() throws {
        guard PhotoTest.gpu else { return }
        var exact: Float = 0, haloWorst: Float = 0
        for (w, h, ch, n) in [(96, 64, 4, 3), (70, 50, 3, 2), (45, 33, 1, 4), (64, 64, 5, 2)] {
            var imgs = (0..<n).map { PhotoTest.pixels(w, h, ch, seed: UInt32(11 + $0)) }
            for k in 1..<n { imgs[k] = PhotoTest.blurImg(w, h, ch, imgs[k], k) }
            let luma = imgs.map { PhotoTest.lumaOf(w, h, ch, $0) }
            let alpha: [[Float]] = (0..<n).map { k in (0..<(w * h)).map { i in k == 1 && (i % w) > w * 2 / 3 ? 0.2 : 1 } }
            let ps = [Pyramid.StackFusion(halo: 0), Pyramid.StackFusion(energyRadius: 0, halo: 0), Pyramid.StackFusion(energyRadius: 2, halo: 0, levels: 3),
                      Pyramid.StackFusion(halo: 0, levels: 1), Pyramid.StackFusion(), Pyramid.StackFusion(guide: 0),
                      Pyramid.StackFusion(energyRadius: 0, halo: 8, guide: 1, levels: 4), Pyramid.StackFusion(halo: 100, levels: 40)]
            for p in ps {
                let c = try Pyramid.fuseStack(width: w, height: h, channels: ch, images: imgs, luma: luma, alpha: alpha, p, on: .cpu)
                let g = try Pyramid.fuseStack(width: w, height: h, channels: ch, images: imgs, luma: luma, alpha: alpha, p, on: .gpu)
                let d = PhotoTest.maxDiff(c, g)
                if p.halo > 0 { haloWorst = max(haloWorst, d) } else { exact = max(exact, d) }
            }
        }
        ParityLog.record("Pyramid fuseStack", exact)
        ParityLog.record("Pyramid fuseStack halo", haloWorst)
        #expect(exact == 0)
        // Halo control weighs coefficients by exp/ln of the region energy: MSL's precise exp/log
        // are a few ulp from libm's, a relative 1e-6 on the weights.
        #expect(haloWorst <= 1e-5)
    }
}
