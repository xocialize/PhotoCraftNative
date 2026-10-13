// Port of photocraft-algo (crates/algo/src/distort2.rs, tests_ext.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum Distort2TestKit {
    /// photocraft's `pattern` test image (RGBA, opaque) over `r`.
    static func pattern(_ r: PixelRect) -> FloatImage {
        var img = FloatImage(rect: r, channels: 4)
        for y in r.y0..<r.y1 {
            for x in r.x0..<r.x1 {
                let i = img.index(x: x, y: y)
                img.data[i] = Float((x * 7 + y * 3) % 64) / 63
                img.data[i + 1] = Float((x * x + y) % 50) / 49
                img.data[i + 2] = Float(y % 9) / 8
                img.data[i + 3] = 1
            }
        }
        return img
    }

    /// photocraft's `map_image`: an 8×8 RGBA map of one colour.
    static func flatMap(_ v: SIMD4<Float>) -> FloatImage {
        let r = PixelRect(x: 0, y: 0, width: 8, height: 8)
        return FloatImage(rect: r, channels: 4, data: (0..<64).flatMap { _ in [v.x, v.y, v.z, v.w] })
    }

    /// A smooth map with `channels` channels over `rect` (values 0…1).
    static func smoothMap(_ rect: PixelRect, channels: Int) -> FloatImage {
        var m = FloatImage(rect: rect, channels: channels)
        for y in rect.y0..<rect.y1 {
            for x in rect.x0..<rect.x1 {
                let i = m.index(x: x, y: y)
                for c in 0..<channels {
                    m.data[i + c] = 0.5 + 0.45 * sinf(Float(x) * 0.31 + Float(c) * 1.3) * cosf(Float(y) * 0.23 - Float(c))
                }
            }
        }
        return m
    }

    static let r = PixelRect(x: 0, y: 0, width: 40, height: 30)
    static func pixel(_ img: FloatImage, _ x: Int32, _ y: Int32) -> [Float] {
        let i = img.index(x: x, y: y)
        return Array(img.data[i..<i + img.channels])
    }
}

@Suite struct Distort2Tests {
    @Test func displaceParity() throws {
        var worst: Float = 0
        let maps = [Distort2TestKit.smoothMap(PixelRect(x: 0, y: 0, width: 23, height: 17), channels: 4),
                    Distort2TestKit.smoothMap(PixelRect(x: -5, y: 7, width: 64, height: 50), channels: 1),
                    Distort2TestKit.smoothMap(PixelRect(x: 2, y: 3, width: 9, height: 31), channels: 2),
                    Distort2TestKit.smoothMap(PixelRect(x: 0, y: 0, width: 1, height: 1), channels: 3)]
        for map in maps {
            for stretch in [true, false] {
                for u in UndefinedAreas.allCases {
                    worst = max(worst, try Parity.checkVariants(Displace(horizontal: 30, vertical: -45, stretch: stretch, undefined: u, map: map)))
                }
            }
        }
        for (h, v) in [(Float(0), Float(0)), (999, 999), (-999, 120)] {
            worst = max(worst, try Parity.checkVariants(Displace(horizontal: h, vertical: v, stretch: false, undefined: .wrap, map: maps[0])))
        }
        worst = max(worst, try DistortTestKit.offBoundsCases(Displace(horizontal: 40, vertical: 25, stretch: true, undefined: .transparent, map: maps[0])))
        worst = max(worst, try DistortTestKit.offBoundsCases(Displace(horizontal: 40, vertical: 25, stretch: false, undefined: .wrap, map: maps[2])))
        // No map: identity.
        worst = max(worst, try Parity.checkVariants(Displace(horizontal: 50, vertical: 50)))
        ParityLog.record("Displace", worst)
    }

    @Test func shearParity() throws {
        var worst: Float = 0
        let curves: [[SIMD2<Float>]] = [
            [SIMD2(0, 0), SIMD2(0.5, 0.3), SIMD2(1, 0)],
            [SIMD2(0, -0.4), SIMD2(0.2, 0.6), SIMD2(0.45, -1), SIMD2(0.8, 0.2), SIMD2(1, 1)],
            [SIMD2(0.7, 0.5), SIMD2(0.1, -0.3), SIMD2(0.1, 0.9), SIMD2(1.4, 2)],   // unsorted, duplicate t, out of range
            [SIMD2(0.5, 0.25)],
            [],
        ]
        for pts in curves {
            for u in UndefinedAreas.allCases { worst = max(worst, try Parity.checkVariants(Shear(points: pts, undefined: u))) }
        }
        worst = max(worst, try DistortTestKit.offBoundsCases(Shear(points: curves[1], undefined: .transparent)))
        worst = max(worst, try DistortTestKit.offBoundsCases(Shear(points: curves[0], undefined: .wrap)))
        ParityLog.record("Shear", worst)
    }

    @Test func zigzagParity() throws {
        var worst: Float = 0
        for s in ZigZagStyle.allCases {
            for (a, k) in [(Float(10), Float(5)), (100, 20), (-100, 0), (-35, 3.5), (0, 5), (250, 40)] {
                worst = max(worst, try Parity.checkVariants(ZigZag(amount: a, ridges: k, style: s)))
            }
            worst = max(worst, try DistortTestKit.offBoundsCases(ZigZag(amount: 60, ridges: 4, style: s)))
        }
        ParityLog.record("ZigZag", worst)
    }

    /// photocraft `curve_passes_through_points_and_clamps`.
    @Test func curvePassesThroughPointsAndClamps() {
        let pts: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0.5, 0.4), SIMD2(1, -0.2)]
        #expect(abs(Shear.curveAt(pts, 0.5) - 0.4) < 1e-6)
        #expect(abs(Shear.curveAt(pts, 1) + 0.2) < 1e-6)
        #expect(Shear.curveAt(pts, -1) == 0)
        #expect(Shear.curveAt([SIMD2(0, 0.3), SIMD2(1, 0.3)], 0.42) == 0.3)
    }

    /// Points are clamped, sorted by t and de-duplicated (first of equal t kept).
    @Test func shearPointPreparation() {
        let s = Shear(points: [SIMD2(0.7, 0.5), SIMD2(0.1, -0.3), SIMD2(0.1000001, 0.9), SIMD2(1.4, 2), SIMD2(-1, 0)])
        #expect(s.prepared == [SIMD2(0, 0), SIMD2(0.1, -0.3), SIMD2(0.7, 0.5), SIMD2(1, 1)])
    }

    /// photocraft `displace_shifts_by_map_and_shear_by_curve`.
    @Test func displaceShiftsByMapAndShearByCurve() {
        let r = Distort2TestKit.r
        let s = Distort2TestKit.pattern(r)
        let ctx = FilterContext(bounds: r, mode: .rgb, alpha: true)
        let v: Float = 0.5 + 3.0 / 64.0
        let out = Displace(horizontal: 25, vertical: 0, stretch: false, undefined: .wrap, map: Distort2TestKit.flatMap(SIMD4(v, 0.5, 0.5, 1)))
            .cpu(s, out: r, ctx: ctx)
        for x: Int32 in 0..<30 { #expect(Distort2TestKit.pixel(out, x, 7) == Distort2TestKit.pixel(s, x + 3, 7), "x=\(x)") }
        let sh = Shear(points: [SIMD2(0, 0.1), SIMD2(1, 0.1)], undefined: .wrap).cpu(s, out: r, ctx: ctx)
        #expect(Distort2TestKit.pixel(sh, 10, 4) == Distort2TestKit.pixel(s, 8, 4))
    }

    /// photocraft `identities_at_zero_strength` (distort2 cases).
    @Test func identitiesAtZeroStrength() {
        let r = Distort2TestKit.r
        let s = Distort2TestKit.pattern(r)
        let ctx = FilterContext(bounds: r, mode: .rgb, alpha: true)
        let filters: [any Filter] = [
            Displace(horizontal: 0, vertical: 0, stretch: true, undefined: .wrap, map: Distort2TestKit.flatMap(SIMD4(0.9, 0.1, 0, 1))),
            Displace(horizontal: 50, vertical: 50, stretch: true, undefined: .wrap, map: nil),
            Shear(points: [SIMD2(0, 0), SIMD2(1, 0)], undefined: .wrap),
            ZigZag(amount: 0, ridges: 5, style: .aroundCenter),
        ]
        for f in filters {
            #expect(Parity.maxError(f.cpu(s, out: r, ctx: ctx), s, alpha: true) < 1e-6, "\(f.label)")
        }
    }

    /// photocraft `every_filter_changes_something` / halos (distort2 cases).
    @Test func halosAndChanges() {
        let r = Distort2TestKit.r
        let s = Distort2TestKit.pattern(r)
        let ctx = FilterContext(bounds: r, mode: .rgb, alpha: true)
        let filters: [any Filter] = [
            Displace(horizontal: 10, vertical: 10, stretch: true, undefined: .wrap, map: Distort2TestKit.flatMap(SIMD4(0.8, 0.3, 0.5, 1))),
            Shear(points: [SIMD2(0, 0), SIMD2(0.5, 0.3), SIMD2(1, 0)], undefined: .repeat),
            ZigZag(amount: 50, ridges: 4, style: .pondRipples),
        ]
        for f in filters {
            #expect(f.halo(bounds: r) == .bounds)
            #expect(f.cpu(s, out: r, ctx: ctx).data != s.data, "\(f.label) did nothing")
        }
    }

    /// photocraft `new_params_serde_roundtrip`: the caller-supplied map is not serialized.
    @Test func codable() throws {
        let d = Displace(horizontal: 10, vertical: -20, stretch: false, undefined: .transparent, map: Distort2TestKit.flatMap(SIMD4(0.8, 0.3, 0.5, 1)))
        let j = try JSONEncoder().encode(d)
        let s = String(data: j, encoding: .utf8)!
        #expect(!s.contains("map"), "\(s)")
        let back = try JSONDecoder().decode(Displace.self, from: j)
        var stripped = d; stripped.map = nil
        #expect(back == stripped)
        let sh = try JSONDecoder().decode(Shear.self, from: Data(#"{"points":[[0,0],[0.5,0.3],[1,0]],"undefined":"repeat"}"#.utf8))
        #expect(sh == Shear(points: [SIMD2(0, 0), SIMD2(0.5, 0.3), SIMD2(1, 0)], undefined: .repeat))
        let z = try JSONDecoder().decode(ZigZag.self, from: Data(#"{"amount":50,"ridges":4,"style":"outFromCenter"}"#.utf8))
        #expect(z == ZigZag(amount: 50, ridges: 4, style: .outFromCenter))
        let shj = try JSONEncoder().encode(sh)
        let shb = try JSONDecoder().decode(Shear.self, from: shj)
        #expect(shb == sh)
    }
}
