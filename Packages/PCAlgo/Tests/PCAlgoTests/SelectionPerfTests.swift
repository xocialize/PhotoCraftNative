// Port of photocraft-algo's release timings (crates/algo/src/selection_blur.rs bench_24mp, selection/distance tests, seam.rs, segment/workflow_tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// Release timings of the selection algorithms (opt-in: `PCALGO_PERF=1 swift test -c release --filter SelectionPerfTests`).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PCALGO_PERF"] != nil))
struct SelectionPerfTests {
    static func time(_ name: String, _ body: () throws -> Void) rethrows {
        try body()
        var best = Double.infinity
        for _ in 0..<3 {
            let t0 = Date()
            try body()
            best = min(best, Date().timeIntervalSince(t0))
        }
        print(String(format: "PERF\t%@\t%.1f ms", name, best * 1000))
    }

    @Test func masks() throws {
        let (w, h) = (4096, 4096)
        let area = PixelRect(x: 0, y: 0, width: w, height: h)
        let px = SelGPU.pixels(w, h, seed: 5)
        for b in [Backend.cpu, .gpu] {
            try Self.time("magic wand contiguous tol 40 \(b)") { _ = try Selection.magicWand(px, area: area, seed: (100, 100), tolerance: 40, contiguous: true, antiAlias: true, on: b) }
            try Self.time("color range \(b)") { _ = try Selection.colorRange(px, color: SIMD3(0.8, 0.3, 0.2), fuzziness: 40, on: b) }
        }
        let ellipse: [Float] = (0..<(w * h)).map { i in
            let x = Float(i % w) / Float(w) - 0.5, y = Float(i / w) / Float(h) - 0.5
            return x * x + y * y < 0.11 ? 1 : 0
        }
        for b in [Backend.cpu, .gpu] {
            try Self.time("expand 10 \(b)") { _ = try Selection.expand(ellipse, w: w, h: h, r: 10, on: b) }
            try Self.time("smooth 8 \(b)") { _ = try Selection.smooth(ellipse, w: w, h: h, r: 8, on: b) }
            for r: Float in [4, 25, 100] {
                try Self.time("feather \(Int(r)) \(b)") { _ = try Selection.feather(ellipse, w: w, h: h, radius: r, on: b) }
            }
        }
    }

    @Test func seamAndQuickSelection() throws {
        let (w, h) = (2048, 1536)
        let img = SeamReference.noise(w * h * 3, 255, 3)
        for b in [Backend.cpu, .gpu] {
            try Self.time("seam energy \(w)x\(h) \(b)") { _ = try SeamCarving.energy(w: w, h: h, ch: 3, img: img, on: b) }
        }
        let e = try SeamCarving.energy(w: w, h: h, ch: 3, img: img)
        Self.time("one seam DP \(w)x\(h)") { _ = SeamCarving.findSeam(w: w, h: h, energy: e) }
        Self.time("carve 2048x1536 -> 1948x1536 (100 seams)") { _ = SeamCarving.carve(w: w, h: h, ch: 3, img: img, protect: nil, newW: w - 100, newH: h) }
        let scene = QuickTest.square(2000, 600, QuickTest.red, QuickTest.blue)
        Self.time("quick select click 2000x2000") { _ = QuickTest.qs(scene, [SIMD2(1000, 1000)], 30) }
        Self.time("quick select drag 2000x2000") { _ = QuickTest.qs(scene, [SIMD2(900, 1000), SIMD2(1100, 1000)], 60) }
    }
}
