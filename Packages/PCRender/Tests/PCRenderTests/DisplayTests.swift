// Port of photocraft-gpu display behaviour (canvas texture, display LUT; docs/architecture.md §7.3), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Metal
import Testing
import PCFoundation
@testable import PCRender

@Suite struct DisplayTests {
    static let rect = PixelRect(x: 0, y: 0, width: 50, height: 40)

    static func composite() -> RGBABuffer {
        RGBABuffer(rect: rect, px: TS.blob(rect, seed: 41, cx: 25, cy: 20, r: 17, opaqueInside: false).readRGBA(rect))
    }

    func render(_ r: CanvasRenderer, size: (Int, Int)) throws -> RGBABuffer {
        let ctx = r.context
        let target = ctx.makeTexture(width: size.0, height: size.1, pixelFormat: .rgba32Float)!
        let cb = ctx.queue.makeCommandBuffer()!
        try r.encode(into: cb, target: target)
        cb.commit(); cb.waitUntilCompleted()
        return RGBABuffer(ctx.readImage(target, rect: PixelRect(x: 0, y: 0, width: size.0, height: size.1), channels: 4))
    }

    @Test func displayMatchesTheCPUMirror() throws {
        guard let ctx = MetalContext.shared else { return }
        let comp = Self.composite()
        let r = try CanvasRenderer(context: ctx)
        try r.setComposite(try ctx.makeTexture(from: comp.floatImage), rect: Self.rect)
        for view in [CanvasViewTransform(zoom: 1, translate: SIMD2(7, 3)), CanvasViewTransform(zoom: 2, translate: SIMD2(-5, 4)),
                     CanvasViewTransform(zoom: 3.3, translate: SIMD2(1.5, -2.25)), CanvasViewTransform(zoom: 0.7, translate: SIMD2(6, 2)),
                     CanvasViewTransform(zoom: 0.55, translate: .zero)] {
            r.view = view
            let out = try render(r, size: (90, 70))
            var worst: Float = 0
            for y in 0..<70 {
                for x in 0..<90 {
                    let want = CanvasDisplayMath.shade(comp, view: view, pos: SIMD2(Float(x) + 0.5, Float(y) + 0.5))
                    worst = max(worst, simd_reduce_max(simd_abs(want - out.px[y * 90 + x])))
                }
            }
            #expect(worst <= 1.0 / 255, "zoom \(view.zoom): \(worst)")
        }
    }

    @Test func nearestAbove100PercentCopiesPixels() throws {
        guard let ctx = MetalContext.shared else { return }
        var comp = Self.composite()
        for i in comp.px.indices { comp.px[i].w = 1 }
        let r = try CanvasRenderer(context: ctx)
        try r.setComposite(try ctx.makeTexture(from: comp.floatImage), rect: Self.rect)
        r.view = CanvasViewTransform(zoom: 4, translate: .zero)
        let out = try render(r, size: (80, 80))
        for (x, y) in [(0, 0), (13, 7), (19, 19)] {
            for dy in 0..<4 { for dx in 0..<4 {
                #expect(simd_reduce_max(simd_abs(out.px[(y * 4 + dy) * 80 + x * 4 + dx] - comp.px[y * 50 + x])) < 1e-6)
            } }
        }
    }

    @Test func reductionLevelsAreAreaAverages() throws {
        guard let ctx = MetalContext.shared else { return }
        #expect(CanvasViewTransform(zoom: 0.5).level == 0 && CanvasViewTransform(zoom: 0.49).level == 1 && CanvasViewTransform(zoom: 0.2).level == 2)
        let comp = RGBABuffer(rect: Self.rect, filled: SIMD4(0.3, 0.6, 0.9, 1))
        let r = try CanvasRenderer(context: ctx)
        try r.setComposite(try ctx.makeTexture(from: comp.floatImage), rect: Self.rect)
        r.view = CanvasViewTransform(zoom: 0.2, translate: .zero)
        let out = try render(r, size: (8, 6))
        #expect(simd_reduce_max(simd_abs(out.px[0] - SIMD4(0.3, 0.6, 0.9, 1))) < 2e-3, "\(out.px[0])")
    }

    @Test func displayLUTIsTheFinalStep() throws {
        guard let ctx = MetalContext.shared else { return }
        let comp = Self.composite()
        let r = try CanvasRenderer(context: ctx)
        try r.setComposite(try ctx.makeTexture(from: comp.floatImage), rect: Self.rect)
        r.view = CanvasViewTransform(zoom: 1.5, translate: SIMD2(3, 3))
        let plain = try render(r, size: (60, 50))
        r.displayLUT = DisplayLUT(device: ctx.device) { $0 }
        let ident = try render(r, size: (60, 50))
        r.displayLUT = DisplayLUT(device: ctx.device) { SIMD3<Float>(repeating: 1) - $0 }
        let inv = try render(r, size: (60, 50))
        for i in plain.px.indices {
            #expect(simd_reduce_max(simd_abs(ident.px[i] - plain.px[i])) < 2e-3)
            let want = SIMD3<Float>(repeating: 1) - SIMD3(plain.px[i].x, plain.px[i].y, plain.px[i].z)
            #expect(simd_reduce_max(simd_abs(SIMD3(inv.px[i].x, inv.px[i].y, inv.px[i].z) - want)) < 2e-3)
        }
    }
}

import simd
