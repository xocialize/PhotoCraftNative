// Port of photocraft-algo's release timings (docs/pixelate-performance.md, examples/bench_filters2.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// Release timings at 4096×4096 RGBA (opt-in: `PCALGO_PERF=1 swift test -c release --filter StylizePerfTests`).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PCALGO_PERF"] != nil))
struct StylizePerfTests {
    @Test func stylize() throws {
        try PerfTests.time("Mosaic 10", Mosaic(cellSize: 10))
        try PerfTests.time("Emboss", Emboss())
        try PerfTests.time("Extrude blocks 30/30", Extrude())
        try PerfTests.time("Extrude blocks 2/255", Extrude(size: 2, depth: 255), cpu: false)
        try PerfTests.time("Wind blast", Wind(method: .blast))
        try PerfTests.time("Oil Paint", OilPaint())
        try PerfTests.time("Glowing Edges", GlowingEdges())
    }

    @Test func pixelate() throws {
        try PerfTests.time("Color Halftone r8", ColorHalftone(maxRadius: 8))
        try PerfTests.time("Crystallize 10", Crystallize(cellSize: 10))
        try PerfTests.time("Crystallize 300", Crystallize(cellSize: 300))
        try PerfTests.time("Facet", Facet())
        try PerfTests.time("Pointillize 5", Pointillize())
    }
}
