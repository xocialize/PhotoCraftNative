// Port of photocraft-algo (crates/algo/src/selection.rs tests, selection/marquee.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum SelTest {
    static func img(_ w: Int, _ h: Int, _ f: (Int, Int) -> SIMD4<Float>) -> [SIMD4<Float>] {
        (0..<h).flatMap { y in (0..<w).map { x in f(x, y) } }
    }

    static func rgba(_ v: [Float]) -> SIMD4<Float> { SIMD4(v[0], v[1], v[2], v[3]) }

    /// photocraft `photo_util::Rng` (SplitMix64).
    struct Rng {
        var s: UInt64
        init(_ s: UInt64) { self.s = s }
        mutating func next() -> UInt64 {
            s = s &+ 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Float { Float(Double(next() >> 11) / Double(UInt64(1) << 53)) }
    }

    /// photocraft's `blobs`: a blotchy 8-bit image with gradients, hard edges and half-transparent columns.
    static func blobs(_ w: Int, _ h: Int) -> [SIMD4<UInt8>] {
        (0..<(w * h)).map { i in
            let x = i % w, y = i / w
            let v = UInt8((x * 7 + y * 3) % 23 + ((x / 5 + y / 4) % 3 == 0 ? 120 : 0))
            return SIMD4(v, v / 2, 255 - v, x % 11 == 0 ? 128 : 255)
        }
    }

    static func cpu(_ f: () throws -> [Float]) -> [Float] { (try? f()) ?? [] }
}

@Suite struct SelectionTests {
    // MARK: Magic wand

    /// photocraft `wand_contiguous_vs_global`.
    @Test func wandContiguousVsGlobal() throws {
        let px = SelTest.img(20, 10) { x, _ in (2..<6).contains(x) || (12..<16).contains(x) ? SIMD4(1, 0, 0, 1) : SIMD4(repeating: 1) }
        let a = PixelRect(x: 0, y: 0, width: 20, height: 10)
        let c = try Selection.magicWand(px, area: a, seed: (3, 3), tolerance: 10, contiguous: true, antiAlias: false, on: .cpu)
        #expect(c.filter { $0 > 0 }.count == 40)
        let g = try Selection.magicWand(px, area: a, seed: (3, 3), tolerance: 10, contiguous: false, antiAlias: false, on: .cpu)
        #expect(g.filter { $0 > 0 }.count == 80)
        let aa = try Selection.magicWand(px, area: a, seed: (3, 3), tolerance: 10, contiguous: true, antiAlias: true, on: .cpu)
        #expect(aa[3 * 20 + 6] > 0 && aa[3 * 20 + 6] < 1)
        #expect(try Selection.magicWand(px, area: a, seed: (50, 3), tolerance: 10, contiguous: true, antiAlias: false, on: .cpu).allSatisfy { $0 == 0 })
    }

    /// photocraft `wand_tolerance`.
    @Test func wandTolerance() throws {
        let px = SelTest.img(10, 1) { x, _ in SIMD4(Float(x) * 10 / 255, 0, 0, 1) }
        let m = try Selection.magicWand(px, area: PixelRect(x: 0, y: 0, width: 10, height: 1), seed: (0, 0), tolerance: 25, contiguous: true, antiAlias: false, on: .cpu)
        #expect(m.filter { $0 > 0 }.count == 3)
    }

    /// photocraft `wand_ignores_hidden_rgb_only_when_both_pixels_are_fully_transparent`.
    @Test func wandIgnoresHiddenRGBOnlyWhenBothPixelsAreFullyTransparent() throws {
        let area = PixelRect(x: 0, y: 0, width: 6, height: 1)
        let pixels: [SIMD4<UInt8>] = [SIMD4(255, 0, 0, 0), SIMD4(0, 255, 0, 0), SIMD4(255, 0, 0, 128), SIMD4(253, 0, 0, 128), SIMD4(0, 0, 255, 0), SIMD4(255, 0, 0, 255)]
        let floats = pixels.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), Float($0.w)) / 255 }
        let cases: [((Int32, Int32), Float, Bool, [Float])] = [
            ((0, 0), 0, true, [1, 1, 0, 0, 0, 0]), ((0, 0), 0, false, [1, 1, 0, 0, 1, 0]), ((4, 0), 32, false, [1, 1, 0, 0, 1, 0]),
            ((2, 0), 0, false, [0, 0, 1, 0, 0, 0]), ((2, 0), 2, true, [0, 0, 1, 1, 0, 0]), ((5, 0), 32, false, [0, 0, 0, 0, 0, 1]),
        ]
        for (seed, tol, contiguous, expected) in cases {
            #expect(try Selection.magicWand(floats, area: area, seed: seed, tolerance: tol, contiguous: contiguous, antiAlias: false, on: .cpu) == expected)
            let region = Selection.wandRegion(pixels, area: area, seed: seed, tolerance: tol, contiguous: contiguous, antiAlias: false)!
            for (x, value) in expected.enumerated() { #expect(region.at(Int32(x), 0) == value, "seed \(seed) tol \(tol) x \(x)") }
        }
        // Hidden RGB cannot introduce extra edges into the anti-aliased selection either.
        let plain = pixels.map { $0.w == 0 ? SIMD4<UInt8>(repeating: 0) : $0 }
        for contiguous in [false, true] {
            #expect(Selection.wandRegion(pixels, area: area, seed: (0, 0), tolerance: 0, contiguous: contiguous, antiAlias: true)
                    == Selection.wandRegion(plain, area: area, seed: (0, 0), tolerance: 0, contiguous: contiguous, antiAlias: true))
        }
    }

    /// photocraft `wand_region_matches_reference_magic_wand`.
    @Test func wandRegionMatchesReferenceMagicWand() throws {
        let (w, h) = (37, 29)
        let area = PixelRect(x: 3, y: -2, width: w, height: h)
        let img = SelTest.blobs(w, h)
        let f = img.map { SIMD4<Float>(Float($0.x), Float($0.y), Float($0.z), Float($0.w)) / 255 }
        let cases: [((Int32, Int32), Float, Bool, Bool)] = [((10, 5), 10, true, true), ((10, 5), 10, true, false), ((20, 20), 40, false, true),
                                                            ((4, -2), 0, true, true), ((30, 10), 255, true, true)]
        for (seed, tol, contiguous, aa) in cases {
            let reference = try Selection.magicWand(f, area: area, seed: seed, tolerance: tol, contiguous: contiguous, antiAlias: aa, on: .cpu)
            let r = Selection.wandRegion(img, area: area, seed: seed, tolerance: tol, contiguous: contiguous, antiAlias: aa)!
            for y in area.y0..<area.y1 {
                for x in area.x0..<area.x1 {
                    let want = (reference[Int(y - area.y0) * w + Int(x - area.x0)] * 255).rounded()
                    #expect(abs(r.at(x, y) * 255 - want) <= 1, "\(seed) \(tol) \(contiguous) \(aa) at \(x),\(y)")
                }
            }
        }
        #expect(Selection.wandRegion(img, area: area, seed: (0, 0), tolerance: 10, contiguous: true, antiAlias: true) == nil)
    }

    // MARK: Color Range

    /// photocraft `color_range_falloff`.
    @Test func colorRangeFalloff() throws {
        let px: [SIMD4<Float>] = [SIMD4(1, 0, 0, 1), SIMD4(0.9, 0, 0, 1), SIMD4(0, 0, 1, 1), SIMD4(1, 0, 0, 0)]
        let m = try Selection.colorRange(px, color: SIMD3(1, 0, 0), fuzziness: 40, on: .cpu)
        #expect(m[0] == 1)
        #expect(m[1] > 0.3 && m[1] < 1)
        #expect(m[2] == 0 && m[3] == 0)
    }

    /// photocraft `color_range_several_samples_and_localized`.
    @Test func colorRangeSeveralSamplesAndLocalized() throws {
        let red = SIMD4<Float>(1, 0, 0, 1), blue = SIMD4<Float>(0, 0, 1, 1), green = SIMD4<Float>(0, 1, 0, 1)
        let px = [red, blue, green, red]
        let s = { (c: SIMD4<Float>, at: SIMD2<Float>?) in RangeSample(color: SIMD3(c.x, c.y, c.z), at: at) }
        #expect(try Selection.colorRangeSamples(px, w: 4, samples: [s(red, nil), s(blue, nil)], fuzziness: 10, localized: nil, on: .cpu) == [1, 1, 0, 1])
        #expect(try Selection.colorRangeSamples(px, w: 4, samples: [s(red, nil)], fuzziness: 40, localized: nil, on: .cpu)
                == Selection.colorRange(px, color: SIMD3(1, 0, 0), fuzziness: 40, on: .cpu))
        #expect(try Selection.colorRangeSamples(px, w: 4, samples: [s(red, SIMD2(0, 0))], fuzziness: 10, localized: 2, on: .cpu) == [1, 0, 0, 0])
        let reds = [SIMD4<Float>](repeating: red, count: 4)
        #expect(try Selection.colorRangeSamples(reds, w: 4, samples: [s(red, SIMD2(0, 0))], fuzziness: 10, localized: 2, on: .cpu) == [1, 0.5, 0, 0])
        #expect(try Selection.colorRangeSamples(px, w: 4, samples: [], fuzziness: 10, localized: nil, on: .cpu).allSatisfy { $0 == 0 })
    }

    /// Photoshop 2024's own Color Range coverage around the sample Lab (60, 25, 19.9961)
    /// (photocraft `PHOTOSHOP_COVERAGE`).
    static let photoshopCoverage: [(SIMD3<Float>, Float, Float)] = [
        (SIMD3(61.9989, 25.5977, 20.5742), 40, 0.9686), (SIMD3(64.9989, 25.5977, 20.5742), 40, 0.7961), (SIMD3(67.9988, 25.5977, 20.5742), 40, 0.4824),
        (SIMD3(71.9997, 25.5977, 20.5742), 40, 0.1098), (SIMD3(79.9985, 25.5977, 20.5742), 40, 0), (SIMD3(71.9997, 25.5977, 20.5742), 100, 0.8118),
        (SIMD3(79.9985, 25.5977, 20.5742), 100, 0.4824), (SIMD3(60, 13.5508, 20.5742), 40, 0.0432), (SIMD3(60, 19.5742, 20.5742), 40, 0.6706),
        (SIMD3(60, 22.582, 20.5742), 40, 0.9333), (SIMD3(60, 28.6055, 20.5742), 40, 0.8549), (SIMD3(60, 31.6211, 20.5742), 40, 0.5098),
        (SIMD3(60, 37.6445, 20.5742), 40, 0.0078), (SIMD3(60, 13.5508, 20.5742), 100, 0.7647), (SIMD3(60, 37.6445, 20.5742), 100, 0.7137),
        (SIMD3(60, 25.5977, 10.5352), 40, 0.1725), (SIMD3(60, 25.5977, 16.5586), 40, 0.8667), (SIMD3(60, 25.5977, 24.5898), 40, 0.7647),
        (SIMD3(60, 25.5977, 30.6133), 40, 0.0863), (SIMD3(60, 25.5977, 10.5352), 100, 0.8392), (SIMD3(60, 25.5977, 30.6133), 100, 0.8),
    ]

    /// photocraft `lab_range_matches_photoshop`.
    @Test func labRangeMatchesPhotoshop() {
        let r = LabRange.point(SIMD3(60, 25, 19.9961))
        for (lab, fz, ps) in Self.photoshopCoverage {
            let got = Selection.labRangeCoverage(lab, r, fuzziness: fz)
            #expect(abs(got - ps) <= 2 / 255, "\(lab) at \(fz): \(got) vs Photoshop \(ps)")
        }
        #expect(Selection.labRangeCoverage(SIMD3(66, 25, 20), r, fuzziness: 40) > Selection.labRangeCoverage(SIMD3(60, 31, 20), r, fuzziness: 40))
        for fz: Float in [1, 10, 40] { #expect(Selection.labRangeCoverage(SIMD3(60, 25, 19.9961), r, fuzziness: fz) == 1) }
        #expect(Selection.quantizeLab8(SIMD3(60.1, 25.4, -19.6)) == SIMD3<Float>(Float(153) / 2.55, 25, -20))
    }

    /// photocraft `lab_range_box_and_edges`.
    @Test func labRangeBoxAndEdges() {
        let r = LabRange.spanning([SIMD3(50, 10, 0), SIMD3(60, 20, 5)])!
        #expect(r == LabRange(lo: SIMD3(50, 10, 0), hi: SIMD3(60, 20, 5)))
        #expect(LabRange.spanning([]) == nil)
        for fz: Float in [1, 40, 200] { #expect(Selection.labRangeCoverage(SIMD3(55, 15, 2), r, fuzziness: fz) == 1) }
        let near = Selection.labRangeCoverage(SIMD3(55, 22, 2), r, fuzziness: 40)
        #expect(near > 0 && near < 1)
        #expect(Selection.labRangeCoverage(SIMD3(55, 40, 2), r, fuzziness: 40) == 0)
        let p = LabRange.point(SIMD3(50, 10, -5))
        #expect(Selection.labRangeCoverage(SIMD3(50, 10, -5), p, fuzziness: 0) == 1)
        #expect(Selection.labRangeCoverage(SIMD3(50, 11, -5), p, fuzziness: 0) == 0)
        for v in [Float.nan, .infinity, -.infinity] {
            for fz in [v, 40] {
                let k = Selection.labRangeCoverage(SIMD3(v, 0, 0), p, fuzziness: fz)
                #expect(k >= 0 && k <= 1, "\(k)")
            }
        }
    }

    /// photocraft `subtract_reshapes_the_box_like_photoshop`.
    @Test func subtractReshapesTheBoxLikePhotoshop() {
        let table: [(Float, Float, Float, Float, Float, Float)] = [
            (0, 20, 5, 40, 5, 20), (0, 20, 10, 40, 0, 10), (0, 20, 15, 40, 0, 15), (0, 20, 0, 40, 2.68, 20), (0, 20, -2, 40, 0.68, 20),
            (0, 20, -3, 40, 2.36, 20), (0, 20, -8, 40, 0.04, 20), (0, 20, -11, 40, 2.4, 20), (0, 20, -13, 40, 0.4, 20), (0, 20, -14, 40, 0, 20),
            (0, 20, 20, 40, 0, 17.32), (0, 20, 23, 40, 0, 17.64), (0, 20, 33, 40, 0, 19.6), (0, 20, 0, 80, 5.35, 20), (0, 20, -12, 80, 4.05, 20),
            (0, 20, -22, 80, 4.76, 20), (0, 20, -30, 80, 0, 20), (0, 6, 4, 40, 0, 4), (0, 2, 0, 40, 2, 2), (0, 2, 3, 40, 0, 0.32),
        ]
        for (lo, hi, m, fz, wantLo, wantHi) in table {
            let r = LabRange(lo: SIMD3(50, lo, 0), hi: SIMD3(50, hi, 0)).subtract(SIMD3(50, m, 0), fuzziness: fz)
            #expect(abs(r.lo.y - wantLo) < 0.03 && abs(r.hi.y - wantHi) < 0.03, "a [\(lo), \(hi)] − \(m) at \(fz): [\(r.lo.y), \(r.hi.y)]")
        }
        for (m, want) in [(Float(40), Float(43.14)), (34.902, 41.17), (25.098, 40.79), (45.098, 45.1)] {
            let r = LabRange(lo: SIMD3(40, 0, 0), hi: SIMD3(60, 0, 0)).subtract(SIMD3(m, 0, 0), fuzziness: 40)
            #expect(abs(r.lo.x - want) < 0.05, "L − \(m): \(r.lo.x) vs \(want)")
        }
        let r = LabRange(lo: SIMD3(53.58, 0, 0), hi: SIMD3(59.05, 30.56, 25.03)).subtract(SIMD3(53.33, -28.71, 36.45), fuzziness: 40)
        let want = LabRange(lo: SIMD3(56.47, 0, 0), hi: SIMD3(59.05, 30.56, 23.05))
        for k in 0..<3 { #expect(abs(r.lo[k] - want.lo[k]) < 0.05 && abs(r.hi[k] - want.hi[k]) < 0.05, "\(r)") }
        let p = LabRange.point(SIMD3(50, 10, 10))
        #expect(p.subtract(SIMD3(50, 10, 10), fuzziness: 40) == p)
        #expect(p.subtract(SIMD3(.nan, .infinity, -.infinity), fuzziness: .nan) == p)
        #expect(LabRange.spanning([SIMD3(50, 0, 0)])!.grow(SIMD3(60, -5, 3)) == LabRange(lo: SIMD3(50, -5, 0), hi: SIMD3(60, 0, 3)))
    }

    /// photocraft `eight_bit_grid_steps_are_uneven_like_photoshop`.
    @Test func eightBitGridStepsAreUnevenLikePhotoshop() throws {
        let r = LabRange.point(SIMD3(50, 10, -20))
        for fz: Float in [1, 5, 10, 40] { #expect(Selection.labRangeCoverage8bit(SIMD3(50, 10, -20), r, fuzziness: fz) == 1) }
        let up = Selection.labRangeCoverage8bit(SIMD3(50, 11, -20), r, fuzziness: 40)
        let down = Selection.labRangeCoverage8bit(SIMD3(50, 9, -20), r, fuzziness: 40)
        let p = { (d: Float) -> Float in min(((1 - 2 * (d / (40 * 256 / 255)) * (d / (40 * 256 / 255))) * 256).rounded(.down), 255) / 255 }
        #expect(up == p(4.5) && down == p(1.5))
        #expect(down > up)
        #expect(Selection.labRangeCoverage8bit(SIMD3(51, 10, -20), r, fuzziness: 40) == Selection.labRangeCoverage8bit(SIMD3(49, 10, -20), r, fuzziness: 40))
        #expect(Selection.labRangeCoverage(SIMD3(50, 11, -20), r, fuzziness: 40) == Selection.labRangeCoverage(SIMD3(50, 9, -20), r, fuzziness: 40))
        let px: [SIMD4<Float>] = [SIMD4(50, 11, -20, 1), SIMD4(50, 9, -20, 1)]
        #expect(try Selection.colorRangeLab(px, w: 2, range: r, fuzziness: 40, grid8: true, localized: nil, on: .cpu) == [up, down])
    }

    /// photocraft `color_range_lab_alpha_and_localized`.
    @Test func colorRangeLabAlphaAndLocalized() throws {
        let r = LabRange.point(SIMD3(50, 0, 0))
        let px = SelTest.img(10, 1) { x, _ in SIMD4(50, 0, 0, x == 0 ? 0 : 1) }
        let m = try Selection.colorRangeLab(px, w: 10, range: r, fuzziness: 40, grid8: false, localized: nil, on: .cpu)
        #expect(m[0] == 0, "transparent pixels are never selected")
        #expect(m[1...].allSatisfy { $0 > 0.9 })
        let l = try Selection.colorRangeLab(px, w: 10, range: r, fuzziness: 40, grid8: false, localized: (4, [SIMD2(1, 0)]), on: .cpu)
        #expect(l[1] > l[3] && l[3] > 0 && l[6] == 0, "\(l)")
        #expect(try Selection.colorRangeLab(px, w: 10, range: r, fuzziness: 40, grid8: false, localized: (4, []), on: .cpu) == m)
        #expect(try Selection.colorRangeLab([], w: 0, range: r, fuzziness: 40, grid8: false, localized: nil, on: .cpu).isEmpty)
    }

    /// photocraft `hue_families`.
    @Test func hueFamilies() throws {
        let px: [SIMD4<Float>] = [SIMD4(1, 0, 0, 1), SIMD4(1, 0.5, 0, 1), SIMD4(0.5, 0.5, 0.5, 1), SIMD4(1, 0.5, 0.5, 1), SIMD4(0, 0, 1, 1), SIMD4(1, 0, 0, 0)]
        let reds = try Selection.hueRange(px, center: 0, on: .cpu)
        #expect(reds[0] == 1 && abs(reds[1] - 0.5) < 1e-5 && reds[2] == 0 && abs(reds[3] - 0.5) < 1e-5 && reds[4] == 0 && reds[5] == 0)
        #expect(abs(try Selection.hueRange(px, center: 60, on: .cpu)[1] - 0.5) < 1e-5)
        #expect(try Selection.hueRange(px, center: 240, on: .cpu)[4] == 1)
        #expect(try Selection.hueRange([SIMD4(1, 0, 1, 1)], center: 300, on: .cpu)[0] == 1)
        #expect(abs(try Selection.hueRange([SIMD4(1, 0, 0.5, 1)], center: 300, on: .cpu)[0] - 0.5) < 1e-5)
    }

    /// photocraft `tonal_ranges`.
    @Test func tonalRanges() throws {
        let g = { (v: Float) in SIMD4<Float>(v / 255, v / 255, v / 255, 1) }
        let px = [g(0), g(60), g(75), g(128), g(200), g(255)]
        let near = { (a: [Float], b: [Float]) in zip(a, b).allSatisfy { abs($0 - $1) < 1e-4 } }
        #expect(near(try Selection.toneRange(px, lo: 0, hi: 65, falloff: 20, on: .cpu), [1, 1, 0.5, 0, 0, 0]))
        #expect(near(try Selection.toneRange(px, lo: 190, hi: 255, falloff: 20, on: .cpu), [0, 0, 0, 0, 1, 1]))
        #expect(near(try Selection.toneRange(px, lo: 105, hi: 150, falloff: 20, on: .cpu), [0, 0, 0, 1, 0, 0]))
    }

    // MARK: Lasso

    /// photocraft `polygon_area_and_aa`.
    @Test func polygonAreaAndAA() {
        let a = PixelRect(x: 0, y: 0, width: 20, height: 20)
        let sq = Selection.polygon([SIMD2(2, 2), SIMD2(12, 2), SIMD2(12, 12), SIMD2(2, 12)], area: a, antiAlias: true)
        #expect(abs(sq.reduce(0, +) - 100) < 1e-3)
        let tri = Selection.polygon([SIMD2(0, 0), SIMD2(10, 0), SIMD2(0, 10)], area: a, antiAlias: true)
        #expect(abs(tri.reduce(0, +) - 50) < 1)
        #expect(tri.contains { $0 > 0 && $0 < 1 })
        let hard = Selection.polygon([SIMD2(0, 0), SIMD2(10, 0), SIMD2(0, 10)], area: a, antiAlias: false)
        #expect(hard.allSatisfy { $0 == 0 || $0 == 1 })
        #expect(Selection.polygon([SIMD2(0, 0), SIMD2(1, 1)], area: a, antiAlias: true).allSatisfy { $0 == 0 })
    }

    // MARK: Surfaces

    /// photocraft `combine_modes`.
    @Test func combineModes() {
        let a = PixelRect(x: 0, y: 0, width: 4, height: 1)
        let old = Selection.maskToSurface([1, 1, 0, 0], area: a)
        let new: [Float] = [0, 1, 1, 0]
        let v = { (s: Surface?) in Selection.maskFromSurface(s, area: a) }
        #expect(v(Selection.combine(old, new, area: a, mode: .replace)) == [0, 1, 1, 0])
        #expect(v(Selection.combine(old, new, area: a, mode: .add)) == [1, 1, 1, 0])
        #expect(v(Selection.combine(old, new, area: a, mode: .subtract)) == [1, 0, 0, 0])
        #expect(v(Selection.combine(old, new, area: a, mode: .intersect)) == [0, 1, 0, 0])
        #expect(Selection.combine(old, [1, 1, 1, 1], area: a, mode: .subtract) == nil)
        #expect(SelectionMode.parse("add") == .add && SelectionMode.parse("bogus") == .replace)
    }

    /// The per-sample conversions photocraft keeps as the oracle for the tiled fast paths.
    static func oldMaskToSurface(_ m: [Float], _ area: PixelRect) -> Surface {
        var s = Surface(format: .gray8)
        if !area.isEmpty { s.writeRegion(area, m) }
        s.prune()
        return s
    }

    static func oldCombine(_ old: Surface?, _ new: [Float], _ area: PixelRect, _ mode: SelectionMode) -> Surface? {
        let prev = old.map { $0.readRegion(area) } ?? [Float](repeating: 0, count: new.count)
        let q = new.map { (clampf($0, 0, 1) * 255).rounded() / 255 }
        var out: [Float]
        switch mode {
        case .replace: out = q
        case .add: out = zip(prev, q).map { Float.maximum($0, $1) }
        case .subtract: out = zip(prev, q).map { Float.maximum($0 - $1, 0) }
        case .intersect: out = zip(prev, q).map { Float.minimum($0, $1) }
        }
        out = out.map { $0 < 0.5 / 255 ? 0 : $0 }
        if out.allSatisfy({ $0 <= 0 }) { return nil }
        return oldMaskToSurface(out, area)
    }

    /// photocraft `tiled_conversions_match_per_sample_ones`.
    @Test func tiledConversionsMatchPerSampleOnes() {
        var rng = SelTest.Rng(7)
        for area in [PixelRect(x0: 0, y0: 0, x1: 300, y1: 20), PixelRect(x0: -37, y0: 250, x1: 530, y1: 263), PixelRect(x0: 255, y0: -3, x1: 258, y1: 600),
                     PixelRect(x0: 5, y0: 5, x1: 6, y1: 6), PixelRect(x0: -37, y0: -300, x1: 300, y1: 263)] {
            let n = area.area
            let oldM: [Float] = (0..<n).map { i in i % 97 < 40 ? rng.unit() : 0 }
            let old = Self.oldMaskToSurface(oldM, area)
            #expect(Selection.maskToSurface(oldM, area: area) == old, "\(area)")
            #expect(Selection.maskFromSurface(old, area: area) == old.readRegion(area))
            for kind in 0..<4 {
                let new: [Float] = (0..<n).map { i in
                    switch kind {
                    case 0: return rng.unit() * 1.2 - 0.1
                    case 1: return i % 131 < 50 ? 1 : 0
                    case 2: return 0.001
                    default: return i >= 1000 ? 1 : 0
                    }
                }
                for mode in SelectionMode.allCases {
                    for prev in [nil, old] {
                        #expect(Selection.combine(prev, new, area: area, mode: mode) == Self.oldCombine(prev, new, area, mode), "\(area) \(kind) \(mode)")
                    }
                }
            }
        }
        let a = PixelRect(x: 0, y: 0, width: 10, height: 10)
        #expect(Selection.combine(nil, [Float](repeating: 1, count: 5), area: a, mode: .replace) != nil)
        #expect(Selection.maskToSurface([], area: a).tileCount == 0)
        #expect(Selection.combine(nil, [], area: .empty, mode: .replace) == nil)
    }

    /// photocraft `combine_region_matches_combine`.
    @Test func combineRegionMatchesCombine() {
        let area = PixelRect(x: 0, y: 0, width: 40, height: 30)
        var old = Surface(format: .gray8)
        old.fill(PixelRect(x0: 5, y0: 5, x1: 25, y1: 20), with: [1])
        old.fill(PixelRect(x0: 8, y0: 8, x1: 10, y1: 10), with: [0.4])
        let img = SelTest.blobs(40, 30)
        let region = Selection.wandRegion(img, area: area, seed: (12, 12), tolerance: 30, contiguous: true, antiAlias: true)!
        let full: [Float] = (0..<30).flatMap { y in (0..<40).map { x in region.at(Int32(x), Int32(y)) } }
        for mode in SelectionMode.allCases {
            let a = Selection.combine(old, full, area: area, mode: mode), b = Selection.combineRegion(old, region, mode: mode)
            #expect((a == nil) == (b == nil), "\(mode)")
            if let a, let b {
                for y: Int32 in 0..<30 {
                    for x: Int32 in 0..<40 { #expect(abs(a.pixel(x: x, y: y)[0] - b.pixel(x: x, y: y)[0]) < 1.5 / 255, "\(mode) \(x),\(y)") }
                }
            }
        }
        #expect(Selection.combineRegion(nil, nil, mode: .subtract) == nil)
    }

    /// The Elliptical Marquee as it was: every pixel tested and written one at a time.
    static func oldEllipse(_ r: PixelRect, _ area: PixelRect, _ aa: Bool) -> Surface {
        let cut = r.intersect(area)
        var shape = Surface(format: .gray8)
        let cx = Float(r.x0 + r.x1) / 2, cy = Float(r.y0 + r.y1) / 2
        let rx = Float(r.width) / 2, ry = Float(r.height) / 2
        func inside(_ x: Float, _ y: Float) -> Bool { let dx = (x - cx) / rx, dy = (y - cy) / ry; return dx * dx + dy * dy <= 1 }
        if cut.isEmpty { return shape }
        for y in cut.y0..<cut.y1 {
            for x in cut.x0..<cut.x1 {
                let fx = Float(x), fy = Float(y)
                let corners = [(fx, fy), (fx + 1, fy), (fx, fy + 1), (fx + 1, fy + 1)].filter { inside($0.0, $0.1) }.count
                let cov: Float
                if !aa { cov = inside(fx + 0.5, fy + 0.5) ? 1 : 0 } else if corners == 4 { cov = 1 } else {
                    cov = Float((0..<16).filter { inside(fx + (Float($0 % 4) + 0.5) / 4, fy + (Float($0 / 4) + 0.5) / 4) }.count) / 16
                }
                if cov > 0 { shape.setPixel(x: x, y: y, [cov]) }
            }
        }
        return shape
    }

    static func oldCombineSurfaces(_ a: Surface, _ b: Surface, _ area: PixelRect, _ f: (Float, Float) -> Float) -> Surface {
        let data = zip(a.readRegion(area), b.readRegion(area)).map { f($0, $1) }
        var out = Surface(format: .gray8)
        out.writeRegion(area, data)
        out.prune()
        return out
    }

    /// photocraft `marquee_matches_the_per_pixel_version` (smaller canvas: the oracle is per pixel).
    @Test func marqueeMatchesThePerPixelVersion() {
        let area = PixelRect(x: 0, y: 0, width: 600, height: 400)
        let shapes = [PixelRect(x: 40, y: 30, width: 520, height: 340), PixelRect(x: 3, y: 5, width: 1, height: 1), PixelRect(x: 10, y: 10, width: 2, height: 7),
                      PixelRect(x: 100, y: 200, width: 37, height: 301), PixelRect(x: 255, y: 255, width: 258, height: 2),
                      PixelRect(x: -300, y: -200, width: 700, height: 500), PixelRect(x: -500, y: -500, width: 1700, height: 1400),
                      PixelRect(x: 590, y: 390, width: 40, height: 40), PixelRect(x: 2000, y: 0, width: 50, height: 50)]
        for r in shapes {
            for aa in [true, false] { #expect(Selection.ellipseSurface(r, clip: area, antiAlias: aa) == Self.oldEllipse(r, area, aa), "ellipse \(r) aa \(aa)") }
        }
        var rect = Surface(format: .gray8)
        rect.fill(PixelRect(x: 200, y: 100, width: 300, height: 250), with: [1])
        let ell = Self.oldEllipse(PixelRect(x: -60, y: 150, width: 400, height: 300), area, true)
        let ops: [(Float, Float) -> Float] = [{ max($0, $1) }, { $0 * (1 - $1) }, { min($0, $1) }]
        for (a, b) in [(rect, ell), (ell, rect), (ell, ell)] {
            for f in ops { #expect(Selection.combineSurfaces(a, b, area: area, f) == Self.oldCombineSurfaces(a, b, area, f)) }
        }
    }

    /// rgba8Image reads any format as straight RGBA8.
    @Test func rgba8Image() {
        var s = Surface(format: .rgba32f)
        let r = PixelRect(x: 0, y: 0, width: 3, height: 1)
        s.writeRegion(r, [0.5, 0.25, 1.2, 1, -0.1, 0, 0, 0.5, .nan, 1, 1, 1])
        let px = Selection.rgba8Image(s, area: PixelRect(x: 0, y: 0, width: 4, height: 1))
        #expect(px == [SIMD4(128, 64, 255, 255), SIMD4(0, 0, 0, 128), SIMD4(0, 255, 255, 255), SIMD4(0, 0, 0, 0)])
    }
}
