// Port of photocraft-algo (crates/algo/src/render.rs, tests_ext.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum RenderTestKit {
    static let r = PixelRect(x: 0, y: 0, width: 40, height: 30)

    /// photocraft's `flat` (RGBA) over `r`.
    static func flat(_ px: SIMD4<Float>, _ r: PixelRect = r) -> FloatImage {
        FloatImage(rect: r, channels: 4, data: (0..<r.area).flatMap { _ in [px.x, px.y, px.z, px.w] })
    }

    static func pixel(_ img: FloatImage, _ x: Int32, _ y: Int32) -> [Float] {
        let i = img.index(x: x, y: y)
        return Array(img.data[i..<i + img.channels])
    }

    /// photocraft's `run` for a radius filter: the source grown by the halo (0 outside).
    static func run<F: Filter>(_ f: F, _ s: FloatImage, ctx: FilterContext? = nil) -> FloatImage {
        let c = ctx ?? FilterContext(bounds: s.rect, mode: .rgb, alpha: true)
        return f.cpu(s, out: s.rect, ctx: c)
    }
}

@Suite struct RenderTests {
    @Test func fibersParity() throws {
        var worst: Float = 0
        for (v, s) in [(Float(16), Float(4)), (1, 1), (64, 64), (0, 200), (37.5, 9)] {
            for seed: UInt32 in [0, 8, 0xffff_fff0] {
                worst = max(worst, try Parity.checkVariants(Fibers(variance: v, strength: s, seed: seed,
                                                                   foreground: SIMD4(1, 0.2, 0, 1), background: SIMD4(0.1, 0.3, 0.9, 1))))
            }
        }
        // Far from the origin (large noise coordinates).
        worst = max(worst, try Parity.checkVariants(Fibers(), out: PixelRect(x: 3000, y: -2500, width: 64, height: 40)))
        ParityLog.record("Fibers", worst)
    }

    @Test func lensFlareParity() throws {
        var worst: Float = 0
        for lens in LensType.allCases {
            for (b, cx, cy) in [(Float(100), Float(0.5), Float(0.5)), (300, 0.3, 0.3), (10, -0.5, 1.5), (180, 0.9, 0.2)] {
                worst = max(worst, try Parity.checkVariants(LensFlare(brightness: b, centerX: cx, centerY: cy, lens: lens)))
            }
            // Ghost discs big enough to cover many pixels near their hard edges (gd = 0.85 / 1.2).
            worst = max(worst, try Parity.checkVariants(LensFlare(brightness: 150, centerX: 0.1, centerY: 0.2, lens: lens),
                                                        out: PixelRect(x: -20, y: 7, width: 700, height: 420)))
        }
        ParityLog.record("Lens Flare", worst)
    }

    @Test func lightingParity() throws {
        var worst: Float = 0
        let lightSets: [[Light]] = [
            [Light()],
            [Light(kind: .point, x: 0.1, y: 0.5, z: 0.2, intensity: 50, radius: 1)],
            [Light(kind: .infinite, angle: 30, elevation: 20, color: SIMD3(1, 0.8, 0.6), intensity: 90)],
            [Light(kind: .spot, x: 0.5, y: 0.5, z: 0.3, targetX: 0.5, targetY: 0.5, cone: 20),
             Light(kind: .point, x: 0.9, y: 0.1, z: 0.4, color: SIMD3(0.2, 0.4, 1), intensity: -60, radius: 0.5),
             Light(kind: .infinite, angle: -120, elevation: 70, intensity: 25)],
            [],
        ]
        for ls in lightSets {
            for tex in TextureChannel.allCases {
                worst = max(worst, try Parity.checkVariants(LightingEffects(lights: ls, gloss: 30, metallic: -20, exposure: 10, ambience: 8,
                                                                            texture: tex, height: 60, whiteIsHigh: tex != .red)))
            }
        }
        for (g, m, e, a) in [(Float(-100), Float(100), Float(-100), Float(-100)), (100, -100, 100, 100), (0, 0, 0, 0)] {
            worst = max(worst, try Parity.checkVariants(LightingEffects(lights: lightSets[3], gloss: g, metallic: m, exposure: e, ambience: a,
                                                                        texture: .luminance, height: 100)))
        }
        // Bounds smaller than the source: the bump texture clamps to the bounds.
        let bounds = PixelRect(x: 6, y: 3, width: 30, height: 25)
        for (img, ctx0) in TestImage.variants(PixelRect(x: 0, y: 0, width: 44, height: 33), seed: 2) {
            var ctx = ctx0
            ctx.bounds = bounds
            let f = LightingEffects(lights: lightSets[3], gloss: 40, texture: .luminance, height: 80)
            if !f.supportsGPU(ctx, channels: img.channels) { continue }
            if let e = try Parity.check(f, src: img, out: PixelRect(x: 2, y: 2, width: 40, height: 29), ctx: ctx) { worst = max(worst, e) }
        }
        ParityLog.record("Lighting Effects", worst)
    }

    /// Joint filters on CMYK/Lab: Lens Flare works in sRGB, so the engine runs it on the GPU through
    /// its sRGB round trip; Lighting Effects reads native channels and refuses `.gpu`.
    @Test func jointFiltersFallBackForCMYKAndLab() throws {
        let r = RenderTestKit.r
        let img = TestImage.make(r, channels: 5, alpha: true)
        let ctx = FilterContext(bounds: r, mode: .cmyk, alpha: true)
        let f = LensFlare(lens: .prime35)
        #expect(FilterEngine.runsOnGPU(f, channels: 5, context: ctx) == AlgoGPU.isAvailable)
        let lit = LightingEffects(lights: [Light(kind: .point, x: 0.3)])
        #expect(!FilterEngine.runsOnGPU(lit, channels: 5, context: ctx))
        #expect(throws: FilterError.self) { try FilterEngine.apply(lit, to: img, output: r, context: ctx, on: .gpu) }
        let a = try FilterEngine.apply(f, to: img, output: r, context: ctx, on: .auto)
        let finite = a.data.allSatisfy { $0.isFinite }
        #expect(finite)
        let lab = TestImage.make(r, channels: 4, alpha: true)
        let lctx = FilterContext(bounds: r, mode: .lab, alpha: true)
        for g in [Fibers(seed: 3) as any Filter, LightingEffects(texture: .luminance) as any Filter] {
            let out = g.cpu(lab, out: r, ctx: lctx)
            let ok = out.data.allSatisfy { $0.isFinite }
            #expect(ok, "\(g.label)")
        }
    }

    /// photocraft `fibers_lie_between_colours_and_are_seeded`.
    @Test func fibersLieBetweenColoursAndAreSeeded() {
        let s = RenderTestKit.flat(SIMD4(1, 1, 1, 1))
        let p = Fibers(variance: 16, strength: 4, seed: 1, foreground: SIMD4(1, 0, 0, 1), background: SIMD4(0, 0, 1, 1))
        let a = RenderTestKit.run(p, s)
        #expect(a == RenderTestKit.run(p, s))
        for i in 0..<a.rect.area {
            #expect(abs(a.data[i * 4] + a.data[i * 4 + 2] - 1) < 1e-5 && abs(a.data[i * 4 + 1]) < 1e-6)
        }
        var q = p; q.seed = 2
        #expect(a != RenderTestKit.run(q, s))
    }

    /// photocraft `lens_flare_is_brightest_at_its_centre`.
    @Test func lensFlareIsBrightestAtItsCentre() {
        let s = RenderTestKit.flat(SIMD4(0.2, 0.2, 0.2, 1))
        let out = RenderTestKit.run(LensFlare(brightness: 100, centerX: 0.25, centerY: 0.5, lens: .prime105), s)
        #expect(RenderTestKit.pixel(out, 10, 15)[0] > 0.9)
        #expect(RenderTestKit.pixel(out, 10, 15)[0] > RenderTestKit.pixel(out, 38, 2)[0])
        #expect(RenderTestKit.pixel(out, 38, 2)[0] >= 0.2 - 1e-6, "screen never darkens")
    }

    /// photocraft `lighting_point_light_falls_off`.
    @Test func lightingPointLightFallsOff() {
        let s = RenderTestKit.flat(SIMD4(0.8, 0.8, 0.8, 1))
        let light = Light(kind: .point, x: 0.1, y: 0.5, z: 0.2, intensity: 50, radius: 1)
        let out = RenderTestKit.run(LightingEffects(lights: [light], gloss: -100, metallic: 0, exposure: 0, ambience: 0, texture: .none,
                                                    height: 0, whiteIsHigh: true), s)
        #expect(RenderTestKit.pixel(out, 4, 15)[0] > RenderTestKit.pixel(out, 36, 15)[0] + 0.1)
        // A spot light does not reach outside its cone.
        let spot = Light(kind: .spot, x: 0.5, y: 0.5, z: 0.3, targetX: 0.5, targetY: 0.5, cone: 20)
        let o2 = RenderTestKit.run(LightingEffects(lights: [spot], gloss: 0, metallic: 0, exposure: 0, ambience: 0, texture: .none,
                                                   height: 0, whiteIsHigh: true), s)
        #expect(RenderTestKit.pixel(o2, 20, 15)[0] > 0.3 && RenderTestKit.pixel(o2, 1, 1)[0] < 1e-4)
    }

    /// Halos (photocraft `halo_ext`): Fibers and Lens Flare read nothing around, Lighting one ring.
    @Test func halos() {
        let r = RenderTestKit.r
        #expect(Fibers().halo(bounds: r) == .radius(0))
        #expect(LensFlare().halo(bounds: r) == .radius(0))
        #expect(LightingEffects().halo(bounds: r) == .radius(2))
    }

    /// Parameters decode from photocraft's serde JSON; a light's missing fields take the defaults.
    @Test func codable() throws {
        let j = #"{"lights":[{"kind":"point","x":0.1,"color":[1,0.5,0.25]},{}],"gloss":0,"metallic":0,"exposure":0,"ambience":10,"texture":"luminance","height":50,"whiteIsHigh":true}"#
        let l = try JSONDecoder().decode(LightingEffects.self, from: Data(j.utf8))
        #expect(l.lights.count == 2 && l.lights[0].kind == .point && l.lights[0].x == 0.1 && l.lights[0].y == 0.2)
        #expect(l.lights[0].color == SIMD3(1, 0.5, 0.25) && l.lights[1] == Light())
        #expect(l.texture == .luminance)
        let lj = try JSONEncoder().encode(l)
        let lb = try JSONDecoder().decode(LightingEffects.self, from: lj)
        #expect(lb == l)
        let f = try JSONDecoder().decode(Fibers.self, from: Data(#"{"variance":16,"strength":4,"seed":8,"foreground":[0,0,0,1],"background":[1,1,1,1]}"#.utf8))
        #expect(f == Fibers(variance: 16, strength: 4, seed: 8))
        let lf = try JSONDecoder().decode(LensFlare.self, from: Data(#"{"brightness":100,"centerX":0.3,"centerY":0.3,"lens":"moviePrime"}"#.utf8))
        #expect(lf == LensFlare(brightness: 100, centerX: 0.3, centerY: 0.3, lens: .moviePrime))
    }
}
