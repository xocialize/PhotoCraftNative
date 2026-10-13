// Port of photocraft-algo's gallery timing (crates/algo/src/artistic_fx.rs `bench_gallery`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// Release timings at 4096×4096 RGBA (opt-in: `PCALGO_PERF=1 swift test -c release --filter GalleryFXPerfTests`).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PCALGO_PERF"] != nil))
struct GalleryFXPerfTests {
    @Test func gallery() throws {
        for f in [GalleryFilter.dryBrush, .watercolor, .angledStrokes, .smudgeStick, .glass, .stainedGlass, .craquelure, .notePaper, .glowingEdges] {
            try PerfTests.time("Gallery \(f.key)", FilterGallery(GalleryEffect(f)))
        }
    }
}
