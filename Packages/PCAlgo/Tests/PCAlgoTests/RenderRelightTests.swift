// Port of photocraft-algo (crates/algo/src/relight.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum RelightTestKit {
    /// photocraft's `shaded_sphere` (RGBA, opaque) over (0, 0, size, size).
    static func shadedSphere(_ size: Int32) -> FloatImage {
        let r = PixelRect(x0: 0, y0: 0, x1: size, y1: size)
        var img = FloatImage(rect: r, channels: 4)
        let cx = Float(size) / 2, rad = Float(size) * 0.42
        for y in 0..<size {
            for x in 0..<size {
                let dx = Float(x) + 0.5 - cx, dy = Float(y) + 0.5 - cx
                let d2 = dx * dx + dy * dy
                let i = img.index(x: x, y: y)
                if d2 <= rad * rad {
                    let nz = max(rad * rad - d2, 0).squareRoot() / rad
                    let sh = 0.22 + 0.78 * nz
                    img.data.replaceSubrange(i..<i + 4, with: [0.55 * sh, 0.55 * sh, 0.55 * sh, 1])
                } else {
                    img.data.replaceSubrange(i..<i + 4, with: [0.18, 0.18, 0.18, 1])
                }
            }
        }
        return img
    }

    static func luma(_ p: [Float]) -> Float { 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2] }

    static func sphereHalfMean(_ s: FloatImage, _ size: Int32, left: Bool) -> Float {
        let cx = Float(size) / 2, rad = Float(size) * 0.42
        var sum: Float = 0, n: Float = 0
        for y in 0..<size {
            for x in 0..<size {
                let dx = Float(x) + 0.5 - cx, dy = Float(y) + 0.5 - cx
                if dx * dx + dy * dy > rad * rad { continue }
                if left && Float(x) >= cx - 4 { continue }
                if !left && Float(x) < cx + 4 { continue }
                sum += luma(RenderTestKit.pixel(s, x, y))
                n += 1
            }
        }
        return sum / max(n, 1)
    }

    /// photocraft's `run`: the layer's pixels (transparent beyond them) through the filter over
    /// its bounds, the source read with the halo.
    static func run(_ f: Relight, _ s: FloatImage, bounds: PixelRect? = nil) -> FloatImage {
        let b = bounds ?? s.rect
        let pad: Int32 = if case .radius(let r) = f.halo(bounds: b) { r } else { 0 }
        let src = s.crop(s.rect.outset(by: pad))
        return f.cpu(src, out: s.rect, ctx: FilterContext(bounds: b, mode: .rgb, alpha: s.channels == 4))
    }

    static func maxDiff(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map { abs($0 - $1) }.max() ?? 0 }
}

@Suite struct RenderRelightTests {
    @Test func relightParity() throws {
        var worst: Float = 0
        for (a, e, i, amb, w, s) in [(Float(45), Float(40), Float(40), Float(55), Float(0), Float(25)), (180, 30, 90, 12, 0, 15),
                                     (-120, 0, 100, 0, 100, 1), (0, 90, 5, 100, -100, 100), (75, 60, 250, -20, 40, 60)] {
            worst = max(worst, try Parity.checkVariants(Relight(angle: a, elevation: e, intensity: i, ambient: amb, warmth: w, softness: s)))
        }
        worst = max(worst, try Parity.checkVariants(Relight(intensity: 0)))
        // A larger area: σ 16, step 16, reach 65.
        let big = PixelRect(x: -30, y: 12, width: 300, height: 200)
        worst = max(worst, try Parity.checkVariants(Relight(angle: 160, elevation: 25, intensity: 80, ambient: 30, warmth: 30, softness: 100), out: big))
        ParityLog.record("Relight", worst)
    }

    /// Outputs whose luma field would exceed the budget run in bands, on both backends alike.
    @Test func bandsMatchAcrossBackendsAndNearlyMatchOnePiece() throws {
        let out = PixelRect(x: 0, y: 0, width: 90, height: 70)
        var f = Relight(angle: 200, elevation: 35, intensity: 70, ambient: 35, warmth: -30, softness: 60)
        guard case .radius(let h) = f.halo(bounds: out) else { Issue.record("halo"); return }
        let src = TestImage.make(out.outset(by: h), channels: 4, alpha: true, seed: 6)
        let ctx = FilterContext(bounds: out, mode: .rgb, alpha: true)
        let whole = f.cpu(src, out: out, ctx: ctx)
        f.maxLumaPixels = 6000
        #expect(RelightKit.bands(out, RelightKit.readRadius(RelightKit.sigma(f.softness, out)), limit: f.maxLumaPixels).count > 3)
        let banded = f.cpu(src, out: out, ctx: ctx)
        #expect(Parity.maxError(whole, banded, alpha: true) <= 1e-4, "band seams")
        if let e = try Parity.check(f, src: src, out: out, ctx: ctx) { ParityLog.record("Relight (bands)", e) }
    }

    /// photocraft `halo_is_zero_at_identity_and_covers_sigma_otherwise`.
    @Test func haloIsZeroAtIdentityAndCoversSigmaOtherwise() {
        let r = PixelRect(x: 0, y: 0, width: 24, height: 16)
        #expect(Relight(intensity: 0).halo(bounds: r) == .radius(0))
        #expect(Relight(intensity: 40).halo(bounds: .empty) == .radius(RelightKit.haloRadiusMax))
        #expect(RelightKit.haloRadiusMax == RelightKit.readRadius(RelightKit.sigmaMax))
        let wide = PixelRect(x: 0, y: 0, width: 1600, height: 1600)
        let sig = RelightKit.sigma(25, wide)
        #expect(abs(sig - 32) < 1e-4, "σ \(sig)")
        let reach = RelightKit.readRadius(sig)
        #expect(reach == 96 + 1 + 32)
        #expect(Relight(intensity: 40, softness: 25).halo(bounds: wide) == .radius(reach))
    }

    /// photocraft `identity_at_zero_intensity_all_depths`.
    @Test func identityAtZeroIntensity() {
        let r = PixelRect(x: 0, y: 0, width: 24, height: 16)
        let p = Relight(angle: 120, elevation: 40, intensity: 0, ambient: 55, warmth: 80, softness: 90)
        let s = Distort2TestKit.pattern(r)
        #expect(RelightTestKit.run(p, s).data == s.data)
        let g = FloatImage(rect: r, channels: 2, data: (0..<r.area).flatMap { _ in [Float(0.4), 1] })
        #expect(p.cpu(g, out: r, ctx: FilterContext(bounds: r, mode: .grayscale, alpha: true)).data == g.data)
    }

    /// photocraft `direction_flips_on_a_shaded_sphere` (64 px) and `…_large_shaded_sphere` (256 px).
    @Test(arguments: [Int32(64), 256])
    func directionFlipsOnAShadedSphere(size: Int32) {
        let s = RelightTestKit.shadedSphere(size)
        let leftLit = RelightTestKit.run(Relight(angle: 180, elevation: 30, intensity: 90, ambient: 12, warmth: 0, softness: 15), s)
        let rightLit = RelightTestKit.run(Relight(angle: 0, elevation: 30, intensity: 90, ambient: 12, warmth: 0, softness: 15), s)
        let lL = RelightTestKit.sphereHalfMean(leftLit, size, left: true), lR = RelightTestKit.sphereHalfMean(leftLit, size, left: false)
        let rL = RelightTestKit.sphereHalfMean(rightLit, size, left: true), rR = RelightTestKit.sphereHalfMean(rightLit, size, left: false)
        #expect(lL - lR >= 0.05, "light from the left (\(size)px): \(lL) vs \(lR)")
        #expect(rR - rL >= 0.05, "light from the right (\(size)px): \(rL) vs \(rR)")
    }

    /// photocraft `warmth_tints_a_neutral_field`.
    @Test func warmthTintsANeutralField() {
        let s = RenderTestKit.flat(SIMD4(0.5, 0.5, 0.5, 1), PixelRect(x: 0, y: 0, width: 32, height: 32))
        let w = RenderTestKit.pixel(RelightTestKit.run(Relight(angle: 45, elevation: 40, intensity: 50, ambient: 55, warmth: 80, softness: 25), s), 16, 16)
        let c = RenderTestKit.pixel(RelightTestKit.run(Relight(angle: 45, elevation: 40, intensity: 50, ambient: 55, warmth: -80, softness: 25), s), 16, 16)
        #expect(w[0] > w[2], "warmth should raise R over B: \(w)")
        #expect(c[2] > c[0], "cool light should raise B over R: \(c)")
    }

    /// photocraft `high_ambient_keeps_white_finite`.
    @Test func highAmbientKeepsWhiteFinite() {
        let s = RenderTestKit.flat(SIMD4(1, 1, 1, 1), PixelRect(x: 0, y: 0, width: 16, height: 16))
        let px = RenderTestKit.pixel(RelightTestKit.run(Relight(angle: 45, elevation: 40, intensity: 40, ambient: 100, warmth: 0, softness: 25), s), 8, 8)
        #expect(px.allSatisfy { $0.isFinite }, "\(px)")
    }

    /// photocraft `alpha_is_preserved`.
    @Test func alphaIsPreserved() {
        var s = RenderTestKit.flat(SIMD4(0.4, 0.4, 0.5, 1), PixelRect(x: 0, y: 0, width: 16, height: 16))
        s.data.replaceSubrange(s.index(x: 3, y: 3)..<s.index(x: 3, y: 3) + 4, with: [0.4, 0.4, 0.5, 0])
        s.data.replaceSubrange(s.index(x: 4, y: 4)..<s.index(x: 4, y: 4) + 4, with: [0.2, 0.3, 0.4, 0.5])
        let out = RelightTestKit.run(Relight(angle: 180, elevation: 40, intensity: 50, ambient: 55, warmth: 20, softness: 25), s)
        #expect(RenderTestKit.pixel(out, 3, 3)[3] == 0)
        #expect(abs(RenderTestKit.pixel(out, 5, 5)[3] - 1) < 1e-6)
        #expect(abs(RenderTestKit.pixel(out, 4, 4)[3] - 0.5) < 1e-6)
    }

    /// photocraft `tiles_match_a_full_apply` (and past the old fixed halo: 400 px, σ 8).
    @Test(arguments: [Int32(64), 400])
    func tilesMatchAFullApply(size: Int32) {
        let bounds = PixelRect(x0: 0, y0: 0, x1: size, y1: size)
        let f = Relight(angle: 180, elevation: 40, intensity: 60, ambient: 40, warmth: 0, softness: 25)
        guard case .radius(let h) = f.halo(bounds: bounds) else { return }
        let s = RelightTestKit.shadedSphere(size).crop(bounds.outset(by: 2 * h))
        let ctx = FilterContext(bounds: bounds, mode: .rgb, alpha: true)
        let full = f.cpu(s, out: bounds, ctx: ctx)
        let t = size / 4 + 3
        var y: Int32 = 0
        while y < size {
            var x: Int32 = 0
            while x < size {
                let tile = PixelRect(x0: x, y0: y, x1: min(x + t, size), y1: min(y + t, size))
                let part = f.cpu(s.crop(tile.outset(by: h)), out: tile, ctx: ctx)
                #expect(RelightTestKit.maxDiff(part.data, full.crop(tile).data) <= 1e-4, "tile seam at \(tile)")
                x += t
            }
            y += t
        }
    }

    /// photocraft `hostile_sizes_do_not_panic`.
    @Test func hostileSizesDoNotPanic() throws {
        let p = Relight(angle: 45, elevation: 40, intensity: 40, ambient: 55, warmth: 0, softness: 25)
        for (w, h) in [(1, 1), (2, 2), (1, 2), (0, 0)] {
            let r = PixelRect(x: 0, y: 0, width: w, height: h)
            let s = RenderTestKit.flat(SIMD4(0.4, 0.5, 0.6, 1), r)
            _ = RelightTestKit.run(p, s, bounds: r.isEmpty ? PixelRect(x: 0, y: 0, width: 1, height: 1) : r)
            _ = p.cpu(s, out: .empty, ctx: FilterContext(bounds: PixelRect(x: 0, y: 0, width: 4, height: 4), mode: .rgb, alpha: true))
            if !r.isEmpty, AlgoGPU.isAvailable {
                _ = try FilterEngine.apply(p, to: s.crop(r.outset(by: 20)), output: r, context: FilterContext(bounds: r, mode: .rgb, alpha: true), on: .gpu)
            }
        }
    }

    /// photocraft `nan_and_inf_pixels_pass_through`, on both backends.
    @Test func nanAndInfPixelsPassThrough() throws {
        let r = PixelRect(x: 0, y: 0, width: 24, height: 24)
        var s = Distort2TestKit.pattern(r)
        s.data[s.index(x: 5, y: 5)] = .nan
        s.data[s.index(x: 6, y: 8)] = .infinity
        let before = RenderTestKit.pixel(s, 7, 5)
        let f = Relight(angle: 180, elevation: 40, intensity: 50, ambient: 55, warmth: 0, softness: 20)
        let out = RelightTestKit.run(f, s)
        #expect(RenderTestKit.pixel(out, 5, 5)[0].isNaN)
        #expect(RenderTestKit.pixel(out, 6, 8)[0].isInfinite)
        let n = RenderTestKit.pixel(out, 7, 5)
        #expect(n.allSatisfy { $0.isFinite })
        #expect(n != before)
        guard AlgoGPU.isAvailable, case .radius(let h) = f.halo(bounds: r) else { return }
        let src = s.crop(r.outset(by: h))
        let ctx = FilterContext(bounds: r, mode: .rgb, alpha: true)
        let g = try FilterEngine.apply(f, to: src, output: r, context: ctx, on: .gpu)
        var worst: Float = 0
        for i in 0..<out.data.count {
            let a = out.data[i], b = g.data[i]
            if a.isNaN || b.isNaN { #expect(a.isNaN && b.isNaN, "NaN at \(i)"); continue }
            if a.isInfinite || b.isInfinite { #expect(a == b, "inf at \(i)"); continue }
            worst = max(worst, abs(a - b))
        }
        #expect(worst <= 1.0 / 255.0)
    }

    @Test func codable() throws {
        let j = #"{"angle":45,"elevation":40,"intensity":40,"ambient":55,"warmth":0,"softness":25}"#
        let r = try JSONDecoder().decode(Relight.self, from: Data(j.utf8))
        #expect(r == Relight())
        let enc = String(data: try JSONEncoder().encode(r), encoding: .utf8)!
        #expect(!enc.contains("maxLuma"), "\(enc)")
    }
}
