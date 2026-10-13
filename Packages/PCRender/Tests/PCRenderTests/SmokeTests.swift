// Smoke tests (new: PCROp layout against the MSL struct, one CPU/GPU plan), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Testing
import PCDocument
import PCFoundation
@testable import PCRender

@Suite struct SmokeTests {
    @Test func uniformLayoutMatchesMSL() {
        #expect(MemoryLayout<PCROp>.size == 288)
        #expect(MemoryLayout<PCROp>.offset(of: \PCROp.leafOutside) == 128)
        #expect(MemoryLayout<PCROp>.offset(of: \PCROp.p0) == 160)
        #expect(MemoryLayout<PCROp>.offset(of: \PCROp.aux) == 120)
    }

    @Test func libraryCompilesAndSimplePlanMatches() throws {
        let rect = PixelRect(x: 0, y: 0, width: 40, height: 30)
        let bg = LeafID(layer: 1, role: .content), fg = LeafID(layer: 2, role: .content)
        let src = LeafTable(leaves: [
            bg: .surface(TS.blob(rect, seed: 1, cx: 20, cy: 15, r: 30)),
            fg: .surface(TS.blob(rect, seed: 2, cx: 12, cy: 10, r: 9, opaqueInside: false)),
        ])
        let plan = RenderPlan(context: RenderContext(canvas: rect), ops: [
            .pushTransparent,
            .drawTiles(DrawTiles(leaf: bg)), .composite(LayerBlend()),
            .drawTiles(DrawTiles(leaf: fg)), .composite(LayerBlend(.multiply, opacity: 0.8)),
        ])
        let (cpu, gpu) = try TS.both(plan, rect, src)
        guard let gpu else { return }
        let d = TS.diff(cpu, gpu)
        #expect(d.levels <= 1, "max \(d.max)")
    }
}
