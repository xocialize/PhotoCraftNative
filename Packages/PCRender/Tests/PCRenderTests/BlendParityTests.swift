// Port of photocraft-compose (crates/compose/src/psblend.rs tests) and photocraft-gpu (parity tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Testing
import PCDocument
import PCFoundation
@testable import PCRender

/// Every blend mode through the composite op, CPU vs Metal, at 8-bit tolerance — plus the
/// Photoshop measurements photocraft's psblend tests carry.
@Suite struct BlendParityTests {
    static let rect = PixelRect(x: -7, y: 3, width: 48, height: 40)
    static let bg = LeafID(layer: 1, role: .content), fg = LeafID(layer: 2, role: .content)

    static func source() -> LeafTable {
        LeafTable(leaves: [
            bg: .surface(TS.blob(rect, seed: 11, cx: 10, cy: 20, r: 26)),
            fg: .surface(TS.blob(rect, seed: 12, cx: 22, cy: 25, r: 16, opaqueInside: false)),
        ])
    }

    @Test func metalIsAvailable() { #expect(TS.metal != nil) }

    @Test(arguments: BlendMode.allLayerModes)
    func compositeModeParity(_ mode: BlendMode) throws {
        let src = Self.source()
        for (opacity, fill, gamma) in [(Float(1), Float(1), Float(1)), (0.7, 0.45, 1), (0.9, 1, 1.45)] {
            for ctx in [RenderContext(canvas: Self.rect), RenderContext(canvas: Self.rect, mode: .lab), RenderContext(canvas: Self.rect, depth: .f32)] {
                let plan = RenderPlan(context: ctx, ops: [
                    .pushTransparent, .drawTiles(DrawTiles(leaf: Self.bg)), .composite(LayerBlend()),
                    .drawTiles(DrawTiles(leaf: Self.fg)), .composite(LayerBlend(mode, opacity: opacity, fill: fill, textGamma: gamma)),
                ])
                let (cpu, gpu) = try TS.both(plan, Self.rect, src)
                guard let gpu else { continue }
                let d = TS.diff(cpu, gpu)
                #expect(d.levels <= 1, "\(mode) o\(opacity) f\(fill) g\(gamma) \(ctx.mode) \(ctx.depth): \(d.max)")
            }
        }
    }

    @Test(arguments: BlendMode.allLayerModes)
    func atopAndAdjustMixParity(_ mode: BlendMode) throws {
        let src = Self.source()
        let plan = RenderPlan(context: RenderContext(canvas: Self.rect), ops: [
            .pushTransparent,
            .drawTiles(DrawTiles(leaf: Self.bg)), .beginClipBase,
            .drawTiles(DrawTiles(leaf: Self.fg)), .clipped(LayerBlend(mode, opacity: 0.8, fill: 0.9, textGamma: mode == .normal ? 1.45 : 1)),
            .composite(LayerBlend(.normal, opacity: 0.9)),
            .pick(0), .adjust(.invert), .adjustMix(AdjustMix(mode: mode, opacity: 0.6)), .quantize(255),
        ])
        let (cpu, gpu) = try TS.both(plan, Self.rect, src)
        guard let gpu else { return }
        let d = TS.diff(cpu, gpu)
        #expect(d.levels <= 1, "\(mode): \(d.max)")
    }

    /// Photoshop 27.11, measured (psblend::special_eight_fill_matches_photoshop).
    @Test func specialEightFillMatchesPhotoshop() {
        let measured: [(BlendMode, SIMD3<Float>)] = [
            (.colorBurn, SIMD3(176, 132, 88)), (.linearBurn, SIMD3(122, 112, 82)), (.colorDodge, SIMD3(249, 232, 176)),
            (.linearDodge, SIMD3(250, 240, 210)), (.vividLight, SIMD3(193, 188, 157)), (.linearLight, SIMD3(171, 202, 192)),
            (.hardMix, SIMD3(245, 225, 165)), (.difference, SIMD3(150, 60, 10)),
        ]
        let b = SIMD4<Float>(200, 150, 100, 255) / 255, t = SIMD4<Float>(100, 180, 220, 255) / 255
        for (mode, want) in measured {
            let got = PSBlend.compositeFill(mode, b, t, opacity: 1, fill: 128.0 / 255, gamma: 1, .srgb)
            for i in 0..<3 { #expect(abs(got[i] * 255 - want[i]) <= 1.5, "\(mode) \(i): \(got[i] * 255) vs \(want[i])") }
            #expect(PSBlend.compositeFill(mode, b, t, opacity: 1, fill: 1, gamma: 1, .srgb) == PSBlend.composite(mode, b, t, 1, .srgb))
            let none = PSBlend.compositeFill(mode, b, t, opacity: 1, fill: 0, gamma: 1, .srgb)
            for i in 0..<3 { #expect(abs(none[i] - b[i]) < 1e-5) }
        }
    }

    /// 69 % blue over grey 129 shows (57, 80, 146) in Photoshop with text gamma 1.45.
    @Test func textGammaLightensDarkEdges() {
        let r = PSBlend.compositeGamma(.normal, SIMD4(129, 129, 129, 255) / 255, SIMD4(0, 0.2, 0.6, 0.686), 1, 1.45, .srgb)
        #expect(abs(r.x * 255 - 57) < 1 && abs(r.y * 255 - 80) < 1 && abs(r.z * 255 - 146) < 1, "\(r)")
    }

    @Test func vividLightAndHardMixEdges() {
        #expect(PSBlend.vividLightPS(0, 1) == 1 && PSBlend.vividLightPS(1, 0) == 0)
        #expect(PSBlend.hardMixPS(1, 0) == 1 && PSBlend.hardMixPS(0, 1) == 0 && PSBlend.hardMixPS(0.6, 0.6) == 1 && PSBlend.hardMixPS(0.3, 0.3) == 0)
        #expect(PSBlend.colorBurn(1 - 1e-6, 0) == 1 && PSBlend.colorDodge(1e-6, 1) == 0)
    }

    @Test func dissolveIsDeterministicAndStableUnderTiling() throws {
        let src = Self.source()
        let plan = RenderPlan(context: RenderContext(canvas: Self.rect), ops: [
            .pushTransparent, .drawTiles(DrawTiles(leaf: Self.bg)), .composite(LayerBlend()),
            .drawTiles(DrawTiles(leaf: Self.fg)), .composite(LayerBlend(.dissolve, opacity: 0.6)),
        ])
        let a = try CPUCompositor(tileSize: 16).render(plan, region: Self.rect, source: src)
        let b = try CPUCompositor(tileSize: 256).render(plan, region: Self.rect, source: src)
        #expect(a == b)
        if let m = TS.metal {
            let g = try m.renderBuffer(plan, region: Self.rect, source: src)
            #expect(TS.diff(a, g).levels <= 1)
        }
    }
}
