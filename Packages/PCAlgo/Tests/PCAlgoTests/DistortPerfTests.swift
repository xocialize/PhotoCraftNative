// Port of photocraft-algo's release timings (crates/algo/src/distort.rs, render.rs, relight.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// Release timings at 4096×4096 RGBA (opt-in: `PCALGO_PERF=1 swift test -c release --filter DistortPerfTests`).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PCALGO_PERF"] != nil))
struct DistortPerfTests {
    @Test func distortAndRender() throws {
        try PerfTests.time("Twirl 50", Twirl(angle: 50))
        try PerfTests.time("Wave 5 gens", Wave(seed: 1))
        try PerfTests.time("Lighting Effects 3 lights + bump", LightingEffects(lights: [Light(), Light(kind: .point), Light(kind: .infinite)], texture: .luminance))
        try PerfTests.time("Relight", Relight())
    }
}
