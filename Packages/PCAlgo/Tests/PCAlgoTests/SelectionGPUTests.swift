// Port of photocraft-algo (crates/algo/src/selection.rs, selection_blur.rs, selection/distance.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// CPU vs Metal parity of the selection algorithms.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum SelGPU {
    /// Straight RGBA test pixels (8-bit levels, transparent holes) over w × h.
    static func pixels(_ w: Int, _ h: Int, seed: UInt32 = 1) -> [SIMD4<Float>] {
        let img = TestImage.make(PixelRect(x: 0, y: 0, width: w, height: h), channels: 4, alpha: true, seed: seed)
        return (0..<(w * h)).map { SIMD4(img.data[$0 * 4], img.data[$0 * 4 + 1], img.data[$0 * 4 + 2], img.data[$0 * 4 + 3]) }
    }

    static func maxDiff(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "\(a.count) vs \(b.count)")
        var worst: Float = 0
        for (x, y) in zip(a, b) {
            if x.isNaN || y.isNaN { if !(x.isNaN && y.isNaN) { return .infinity } else { continue } }
            worst = max(worst, abs(x - y))
        }
        return worst
    }

    /// Binary masks: blobs, noise, a ring, a line, a single pixel.
    static func binaryMasks(_ w: Int, _ h: Int) -> [[Bool]] {
        var rng = SelTest.Rng(11)
        let noise = (0..<(w * h)).map { _ in rng.unit() < 0.3 }
        let sparse = (0..<(w * h)).map { _ in rng.unit() < 0.005 }
        let ring = (0..<(w * h)).map { i -> Bool in
            let dx = Float(i % w) - Float(w) * 0.4, dy = Float(i / w) - Float(h) * 0.55
            let d = (dx * dx + dy * dy).squareRoot()
            return d > Float(min(w, h)) * 0.2 && d < Float(min(w, h)) * 0.3
        }
        let line = (0..<(w * h)).map { $0 % w == ($0 / w) * 3 % w }
        var dot = [Bool](repeating: false, count: w * h)
        dot[(h / 3) * w + w / 5] = true
        return [noise, sparse, ring, line, dot]
    }
}

@Suite(.enabled(if: AlgoGPU.isAvailable)) struct SelectionGPUTests {
    @Test func magicWandParity() throws {
        var worst: Float = 0
        let (w, h) = (173, 121)
        let area = PixelRect(x: -20, y: 7, width: w, height: h)
        for (px, seeds) in [(SelGPU.pixels(w, h), [(Int32(10), Int32(30)), (-20, 7), (100, 100), (-5, 70)]),
                            (SelTest.blobs(w, h).map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), Float($0.w)) / 255 }, [(0, 40), (80, 60)])] {
            for seed in seeds {
                for tol: Float in [0, 10, 32, 80, 255] {
                    for contiguous in [true, false] {
                        for aa in [false, true] {
                            let c = try Selection.magicWand(px, area: area, seed: seed, tolerance: tol, contiguous: contiguous, antiAlias: aa, on: .cpu)
                            let g = try Selection.magicWand(px, area: area, seed: seed, tolerance: tol, contiguous: contiguous, antiAlias: aa, on: .gpu)
                            let e = SelGPU.maxDiff(c, g)
                            #expect(e == 0, "seed \(seed) tol \(tol) contiguous \(contiguous) aa \(aa): \(e)")
                            worst = max(worst, e)
                        }
                    }
                }
            }
        }
        // A maze-like spiral: propagation needs many sweep rounds.
        let (sw, sh) = (64, 64)
        let spiral = SelTest.img(sw, sh) { x, y in
            let ring = min(x, y, sw - 1 - x, sh - 1 - y)
            let wall = ring % 2 == 1 && !(x == ring + 1 && y == ring)
            return wall ? SIMD4(0, 0, 0, 1) : SIMD4(1, 1, 1, 1)
        }
        let sa = PixelRect(x: 0, y: 0, width: sw, height: sh)
        let c = try Selection.magicWand(spiral, area: sa, seed: (0, 0), tolerance: 5, contiguous: true, antiAlias: true, on: .cpu)
        let g = try Selection.magicWand(spiral, area: sa, seed: (0, 0), tolerance: 5, contiguous: true, antiAlias: true, on: .gpu)
        #expect(c == g)
        ParityLog.record("Magic Wand", max(worst, SelGPU.maxDiff(c, g)))
    }

    @Test func rangesParity() throws {
        var worst: Float = 0
        let (w, h) = (131, 97)
        let px = SelGPU.pixels(w, h, seed: 3)
        for (color, fz) in [(SIMD3<Float>(0.8, 0.2, 0.3), Float(40)), (SIMD3(0.5, 0.5, 0.5), 0), (SIMD3(0.1, 0.9, 0.4), 200), (SIMD3(0.3, 0.3, 0.9), -5)] {
            let e = SelGPU.maxDiff(try Selection.colorRange(px, color: color, fuzziness: fz, on: .cpu), try Selection.colorRange(px, color: color, fuzziness: fz, on: .gpu))
            #expect(e == 0, "colorRange \(color) \(fz): \(e)")
            worst = max(worst, e)
        }
        let samples = [RangeSample(color: SIMD3(0.8, 0.2, 0.3), at: SIMD2(10, 20)), RangeSample(color: SIMD3(0.2, 0.6, 0.5)),
                       RangeSample(color: SIMD3(0.5, 0.5, 0.5), at: SIMD2(100, 80))]
        for loc in [nil, Float(30), 0.5] {
            let e = SelGPU.maxDiff(try Selection.colorRangeSamples(px, w: w, samples: samples, fuzziness: 60, localized: loc, on: .cpu),
                                   try Selection.colorRangeSamples(px, w: w, samples: samples, fuzziness: 60, localized: loc, on: .gpu))
            #expect(e == 0, "samples localized \(String(describing: loc)): \(e)")
            worst = max(worst, e)
        }
        // Lab pixels: L 0…100, a/b −128…127 (from the RGB test image), some transparent.
        let lab = px.map { SIMD4<Float>($0.x * 100, $0.y * 255 - 128, $0.z * 255 - 128, $0.w) }
        for (range, fz) in [(LabRange(lo: SIMD3(40, -10, 0), hi: SIMD3(60, 20, 30)), Float(40)), (LabRange.point(SIMD3(50, 0, 0)), 100), (LabRange.point(SIMD3(70, 30, -40)), 0)] {
            for grid8 in [false, true] {
                for loc: (radius: Float, at: [SIMD2<Float>])? in [nil, (25, [SIMD2(20, 30), SIMD2(90, 10)])] {
                    let e = SelGPU.maxDiff(try Selection.colorRangeLab(lab, w: w, range: range, fuzziness: fz, grid8: grid8, localized: loc, on: .cpu),
                                           try Selection.colorRangeLab(lab, w: w, range: range, fuzziness: fz, grid8: grid8, localized: loc, on: .gpu))
                    #expect(e == 0, "lab \(range) \(fz) grid8 \(grid8): \(e)")
                    worst = max(worst, e)
                }
            }
        }
        for center: Float in [0, 60, 120, 180, 240, 300, 17] {
            let e = SelGPU.maxDiff(try Selection.hueRange(px, center: center, on: .cpu), try Selection.hueRange(px, center: center, on: .gpu))
            #expect(e == 0, "hue \(center): \(e)")
            worst = max(worst, e)
        }
        for (lo, hi, fall) in [(Float(0), Float(65), Float(20)), (190, 255, 20), (105, 150, 0), (100, 90, 5)] {
            let e = SelGPU.maxDiff(try Selection.toneRange(px, lo: lo, hi: hi, falloff: fall, on: .cpu), try Selection.toneRange(px, lo: lo, hi: hi, falloff: fall, on: .gpu))
            #expect(e == 0, "tone \(lo)…\(hi): \(e)")
            worst = max(worst, e)
        }
        ParityLog.record("Color/Lab/Hue/Tone Range", worst)
    }

    @Test func distanceParity() throws {
        var worst: Float = 0
        for (w, h) in [(157, 103), (1, 50), (64, 1), (300, 211)] {
            for inside in SelGPU.binaryMasks(w, h) {
                let c = try Selection.edt(inside, w: w, h: h, on: .cpu), g = try Selection.edt(inside, w: w, h: h, on: .gpu)
                #expect(c == g, "edt \(w)x\(h)")
                worst = max(worst, SelGPU.maxDiff(c, g))
            }
        }
        let (w, h) = (157, 103)
        var rng = SelTest.Rng(3)
        let soft: [Float] = SelGPU.binaryMasks(w, h)[2].map { $0 ? 0.6 + 0.4 * rng.unit() : 0.4 * rng.unit() }
        for r: Float in [0, 1, 2.5, 7, 40] {
            for (name, cpu, gpu) in [("expand", try Selection.expand(soft, w: w, h: h, r: r, on: .cpu), try Selection.expand(soft, w: w, h: h, r: r, on: .gpu)),
                                     ("contract", try Selection.contract(soft, w: w, h: h, r: r, on: .cpu), try Selection.contract(soft, w: w, h: h, r: r, on: .gpu)),
                                     ("border", try Selection.border(soft, w: w, h: h, r: r, on: .cpu), try Selection.border(soft, w: w, h: h, r: r, on: .gpu))] {
                let e = SelGPU.maxDiff(cpu, gpu)
                #expect(e == 0, "\(name) r \(r): \(e)")
                worst = max(worst, e)
            }
        }
        ParityLog.record("EDT/Expand/Contract/Border", worst)
    }

    /// Smooth: binary masks match exactly; soft masks only where the box average is within 1e-5
    /// of ½ (Float vs Double running sums at a hard threshold).
    @Test func smoothParity() throws {
        let (w, h) = (143, 109)
        var flips = 0, total = 0
        let masks = ModifyTest.masks(w, h, 9) + SelGPU.binaryMasks(w, h).map { ("bin", $0.map { $0 ? Float(1) : 0 }) }
        for (kind, m) in masks {
            for r: Float in [0, 1, 2.4, 5, 16, 60, 300] {
                let c = try Selection.smooth(m, w: w, h: h, r: r, on: .cpu), g = try Selection.smooth(m, w: w, h: h, r: r, on: .gpu)
                total += c.count
                var avg: [Float]?
                for i in 0..<c.count where c[i] != g[i] {
                    flips += 1
                    if avg == nil { avg = ModifyTest.boxBlur(m, w, h, Int(max(r, 0).rounded())) }
                    #expect(abs(avg![i] - 0.5) < 1e-5, "\(kind) r \(r) pixel \(i): average \(avg![i])")
                }
            }
        }
        print("SMOOTH flips \(flips) of \(total)")
        ParityLog.record("Smooth (pixels flipped at ½)", Float(flips))
    }

    /// Feather: radius ≤ 12 is the same direct convolution (bit-identical); above, the CPU's cosine
    /// series is within its fit error of the GPU's exact Gaussian.
    @Test func featherParity() throws {
        var worstDirect: Float = 0, worstSeries: Float = 0
        for (w, h, seed) in [(143, 109, UInt64(2)), (40, 230, 4)] {
            for (kind, m) in ModifyTest.masks(w, h, seed) {
                for radius: Float in [0.1, 0.6, 1, 2.5, 4, 3.9] {
                    let e = SelGPU.maxDiff(try Selection.feather(m, w: w, h: h, radius: radius, on: .cpu), try Selection.feather(m, w: w, h: h, radius: radius, on: .gpu))
                    #expect(e == 0, "\(kind) \(w)x\(h) r \(radius): \(e)")
                    worstDirect = max(worstDirect, e)
                }
                for radius: Float in [4.5, 8, 25, 70] {
                    let e = SelGPU.maxDiff(try Selection.feather(m, w: w, h: h, radius: radius, on: .cpu), try Selection.feather(m, w: w, h: h, radius: radius, on: .gpu))
                    #expect(e <= 1 / 255, "\(kind) \(w)x\(h) r \(radius): \(e)")
                    worstSeries = max(worstSeries, e)
                }
            }
        }
        ParityLog.record("Feather (r ≤ 12, direct)", worstDirect)
        ParityLog.record("Feather (cosine series)", worstSeries)
    }
}
