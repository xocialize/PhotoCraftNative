// Port of photocraft-engine's render timing (crates/engine/src/render_cmds.rs `bench_24mp`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// Release timings on a 6000 × 4000 RGBA8 layer (opt-in: `PCALGO_PERF=1 swift test -c release --filter RenderProcPerfTests`).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PCALGO_PERF"] != nil))
struct RenderProcPerfTests {
    @Test func bench24MP() throws {
        let c = PixelRect(x: 0, y: 0, width: 6000, height: 4000)
        var f1 = FlameSpec(); f1.flameType = .multipleFlamesAlongPath; f1.length = 600; f1.width = 160; f1.interval = 120
        var f2 = FlameSpec(); f2.length = 1500; f2.width = 400; f2.flameLines = 100; f2.quality = 4
        var t1 = TreeSpec(); t1.leavesAmount = 100
        var t6 = TreeSpec(); t6.baseTreeType = 6; t6.leavesAmount = 100
        let cases: [(String, () -> [RenderProc.Prim])] = [
            ("flame multiple", { RenderProc.flame(f1, paths: [RenderProc.defaultFlamePath(c)]) }),
            ("flame 1500 fine", { RenderProc.flame(f2, paths: [RenderProc.defaultFlamePath(c)]) }),
            ("tree oak", { RenderProc.tree(t1, canvas: c) }),
            ("tree willow", { RenderProc.tree(t6, canvas: c) }),
            ("frame vine", { RenderProc.pictureFrame(FrameSpec(), canvas: c) }),
        ]
        // Warm-up: shader library and pipeline compilation.
        var warm = Surface(format: .rgba8)
        try RenderProc.composite(&warm, [.disc(SIMD2(8, 8), 4, SIMD4(1, 0, 0, 1))], clip: PixelRect(x: 0, y: 0, width: 16, height: 16), on: .gpu)
        for (name, make) in cases {
            var t0 = Date()
            let prims = make()
            let gen = Date().timeIntervalSince(t0)
            var times: [Double] = []
            for be in [Backend.cpu, .gpu] {
                var best = Double.infinity
                for _ in 0..<3 {
                    var s = Surface(format: .rgba8)
                    t0 = Date()
                    try RenderProc.composite(&s, prims, clip: c, on: be)
                    best = min(best, Date().timeIntervalSince(t0))
                }
                times.append(best)
            }
            print(String(format: "PERF\tRender %@\t%d prims\tgenerate %.1f ms\tcomposite cpu %.1f ms\tgpu %.1f ms", name, prims.count, gen * 1000, times[0] * 1000, times[1] * 1000))
        }
    }
}
