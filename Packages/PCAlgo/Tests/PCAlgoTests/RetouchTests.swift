// Port of photocraft-algo (crates/algo/src/poisson.rs, retouch.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo

@Suite struct PoissonTests {
    func disc(_ w: Int, _ h: Int, _ cx: Float, _ cy: Float, _ r: Float) -> [Bool] {
        (0..<(w * h)).map { hypotf(Float($0 % w) - cx, Float($0 / w) - cy) < r }
    }

    @Test func membraneReproducesLinearBoundary() {
        let (w, h) = (80, 60)
        let unknown = disc(w, h, 40, 30, 20)
        let truth = (0..<(w * h)).map { 0.2 + 0.005 * Float($0 % w) + 0.003 * Float($0 / w) }
        var v = zip(truth, unknown).map { $1 ? 0 : $0 }
        Poisson.solveMembrane(width: w, height: h, unknown: unknown, values: &v)
        #expect(zip(v, truth).map { abs($0 - $1) }.max()! < 2e-3)
    }

    @Test func multigridMatchesReferenceSolve() {
        let (w, h) = (96, 72)
        let unknown = disc(w, h, 45, 36, 28)
        let initial = (0..<(w * h)).map { sinf(Float($0 % w) * 0.21) * 0.3 + cosf(Float($0 / w) * 0.13) * 0.2 + 0.5 }
        var fast = initial, reference = initial
        Poisson.solveMembrane(width: w, height: h, unknown: unknown, values: &fast)
        Poisson.solveMembraneReference(w, h, unknown, &reference, 1e-7, 100_000)
        #expect(zip(fast, reference).map { abs($0 - $1) }.max()! < 2e-3)
        #expect((0..<(w * h)).allSatisfy { unknown[$0] || fast[$0] == initial[$0] })
    }

    @Test func seamlessCloneTakesDestinationColourAndSourceTexture() {
        let (w, h, ch) = (64, 64, 3)
        let mask = disc(w, h, 32, 32, 20)
        let dst: [Float] = (0..<(w * h)).flatMap { _ -> [Float] in [0.7, 0.3, 0.2] }
        let src = (0..<(w * h)).flatMap { i -> [Float] in
            let t: Float = (i % w / 4) % 2 == 0 ? 0.05 : -0.05
            return [0.1 + t, 0.2 + t, 0.8 + t]
        }
        let out = Poisson.seamlessClone(width: w, height: h, channels: ch, source: src, destination: dst, mask: mask)
        let inside = (0..<(w * h)).filter { mask[$0] }
        for c in 0..<ch {
            let m = inside.map { out[$0 * ch + c] }.reduce(0, +) / Float(inside.count)
            #expect(abs(m - dst[c]) < 0.02)
        }
        var e: Float = 0, n = 0
        for i in inside where mask[i + 1] {
            e += abs((out[(i + 1) * ch] - out[i * ch]) - (src[(i + 1) * ch] - src[i * ch])); n += 1
        }
        #expect(e / Float(n) < 0.01)
        #expect(Array(out[0..<3]) == Array(dst[0..<3]))
    }
}

@Suite struct RetouchTests {
    @Test func dodgeMidtonesAffectsMidtonesMost() {
        let g = { (v: Float) in Retouch.dodgeBurn(SIMD3(repeating: v), 0.5, .midtones, burn: false, protectTones: true).x - v }
        #expect(g(0.5) > 0.1 && g(0.5) > 2 * g(0.1) && g(0.5) > 2 * g(0.95))
        #expect(Retouch.dodgeBurn(.zero, 0.5, .midtones, burn: false, protectTones: true) == .zero)
        #expect(Retouch.dodgeBurn(SIMD3(repeating: 0.5), 0.5, .midtones, burn: true, protectTones: true).x < 0.45)
    }

    @Test func rangesTargetTheirTones() {
        let d = { (v: Float, r: ToneRange) in Retouch.toneCurve(v, 0.5, r, burn: false) - v }
        #expect(d(0.1, .shadows) > d(0.9, .shadows))
        #expect(d(0.9, .highlights) > d(0.1, .highlights))
        let b = { (v: Float, r: ToneRange) in v - Retouch.toneCurve(v, 0.5, r, burn: true) }
        #expect(b(0.9, .highlights) > b(0.2, .highlights))
        #expect(b(0.3, .shadows) / 0.3 > b(0.9, .shadows) / 0.9)
    }

    @Test func protectTonesKeepsHue() {
        let c = SIMD3<Float>(0.6, 0.3, 0.2)
        let p = Retouch.dodgeBurn(c, 0.8, .midtones, burn: false, protectTones: true)
        #expect(p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1 && p.z >= 0 && p.z <= 1)
        #expect(abs(p.x / p.y - c.x / c.y) < 0.05)
    }

    @Test func spongeChangesSaturation() {
        let c = SIMD3<Float>(0.8, 0.4, 0.3)
        let d = Retouch.sponge(c, 0.5, saturate: false, vibrance: false)
        #expect(Retouch.saturation(d) < Retouch.saturation(c))
        #expect(abs(Retouch.luma(d) - Retouch.luma(c)) < 1e-4)
        let s = Retouch.sponge(c, 0.5, saturate: true, vibrance: false)
        #expect(Retouch.saturation(s) > Retouch.saturation(c))
        let v = Retouch.sponge(SIMD3(1, 0.1, 0.1), 0.5, saturate: true, vibrance: true)
        let nv = Retouch.sponge(SIMD3(1, 0.1, 0.1), 0.5, saturate: true, vibrance: false)
        #expect(abs(v.y - 0.1) <= abs(nv.y - 0.1))
        #expect(Retouch.sponge(SIMD3(repeating: 0.5), 1, saturate: false, vibrance: false) == SIMD3(repeating: 0.5))
    }

    @Test func blurReducesVarianceAndSharpenIncreasesIt() {
        let (w, h) = (16, 16)
        let data = (0..<(w * h)).map { Float(($0 % w + $0 / w) % 2 == 0 ? 0.2 : 0.8) }
        func variance(_ v: [Float]) -> Float { let m = v.reduce(0, +) / Float(v.count); return v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(v.count) }
        let win = (4, 4, 12, 12)
        let orig = (4..<12).flatMap { y in (4..<12).map { data[y * w + $0] } }
        #expect(variance(Retouch.localBlur(data, width: w, height: h, channels: 1, alpha: nil, window: win, sigma: 1.5)) < variance(orig) * 0.2)
        let smooth = (0..<(w * h)).map { 0.3 + 0.03 * Float($0 % w) + ($0 % w == 8 ? 0.2 : 0) }
        let s = Retouch.localSharpen(smooth, width: w, height: h, channels: 1, alpha: nil, window: win, amount: 1, protectDetail: false)
        let so = (4..<12).flatMap { y in (4..<12).map { smooth[y * w + $0] } }
        #expect(variance(s) > variance(so))
        let sp = Retouch.localSharpen(smooth, width: w, height: h, channels: 1, alpha: nil, window: win, amount: 4, protectDetail: true)
        let hi = smooth.max()!
        #expect(sp.allSatisfy { $0 <= hi + 1e-6 })
    }

    @Test func blurIgnoresTransparentColour() {
        let (w, h, ch) = (8, 1, 4)
        let data: [Float] = (0..<w).flatMap { x -> [Float] in x < 4 ? [1, 0, 0, 1] : [0, 1, 0, 0] }
        let b = Retouch.localBlur(data, width: w, height: h, channels: ch, alpha: 3, window: (2, 0, 6, 1), sigma: 1)
        for i in stride(from: 0, to: b.count, by: 4) where b[i + 3] > 0.01 { #expect(b[i] > 0.99 && b[i + 1] < 0.01) }
    }
}
