// Port of photocraft-algo's release timings (crates/algo/src/tone.rs, other2.rs, camera_raw.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// Release timings of the tone area (opt-in: `PCALGO_PERF=1 swift test -c release --filter TonePerfTests`).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PCALGO_PERF"] != nil))
struct TonePerfTests {
    @Test func tone() throws {
        try PerfTests.time("HsbHsl rgb→hsl", HsbHsl(input: .rgb, output: .hsl))
        try PerfTests.time("ShadowsHighlights default", ShadowsHighlights())
        try PerfTests.time("HdrToning default", HdrToning())
        var cr = CameraRaw()
        cr.temperature = 20; cr.contrast = 30; cr.vibrance = 40; cr.hslSat[3] = 50
        cr.gradeShadows = CameraRawWheel(hue: 220, sat: 40, lum: 0); cr.vignetteAmount = -40; cr.grainAmount = 20
        try PerfTests.time("CameraRaw per-pixel", CameraRawFilter(settings: cr))
    }
}
