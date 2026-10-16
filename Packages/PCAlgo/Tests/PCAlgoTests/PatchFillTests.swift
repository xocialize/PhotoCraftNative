// Tests for `InpaintKit.patchFill`, the port of Compositor's PatchPixels.c (AB-T-0299). The curved-edge case it was
// ported for is PCEngine's `SpotHealingCurveTests`.

import Foundation
import Testing
@testable import PCAlgo

@Suite struct PatchFillTests {
    /// Diagonal stripes, 3 px wide, two grays and opaque, with a red square at (36…47, 36…47).
    static func stripes(_ w: Int, _ h: Int, red: Bool) -> [Float] {
        var out: [Float] = []
        for y in 0..<h {
            for x in 0..<w {
                let inRed = red && (36..<48).contains(x) && (36..<48).contains(y)
                let g: Float = (x + y) / 3 % 2 == 0 ? 0.3 : 0.6
                out += inRed ? [1, 0, 0, 1] : [g, g, g, 1]
            }
        }
        return out
    }

    @Test func fillsTheHoleAndLeavesEverythingElse() throws {
        let (w, h) = (96, 96)
        let image = Self.stripes(w, h, red: true), truth = Self.stripes(w, h, red: false)
        let hole = (0..<(w * h)).map { (36..<48).contains($0 % w) && (36..<48).contains($0 / w) }
        let out = try #require(InpaintKit.patchFill(width: w, height: h, channels: 4, image: image, hole: hole, alpha: 3, seed: 7))
        var error: Float = 0
        for p in 0..<(w * h) {
            if !hole[p] { #expect(Array(out[(p * 4)..<(p * 4 + 4)]) == Array(image[(p * 4)..<(p * 4 + 4)])); continue }
            for c in 0..<3 { error += abs(out[p * 4 + c] - truth[p * 4 + c]) }
            #expect(abs(out[p * 4 + 3] - 1) < 1e-4, "an opaque fill stays opaque")
        }
        let mean = error / Float(144 * 3) * 255
        #expect(mean < 20, "the stripes run on through the square: off by \(mean) levels")
        // The red is gone.
        #expect(out[(42 * w + 42) * 4] - out[(42 * w + 42) * 4 + 1] < 0.1)
    }

    @Test func anEmptyHoleChangesNothingAndNoSourceGivesNil() {
        let (w, h) = (64, 64)
        let image = Self.stripes(w, h, red: false)
        #expect(InpaintKit.patchFill(width: w, height: h, channels: 4, image: image, hole: [Bool](repeating: false, count: w * h)) == image)
        // Everything is the hole: no 7 × 7 patch is left to copy from.
        #expect(InpaintKit.patchFill(width: w, height: h, channels: 4, image: image, hole: [Bool](repeating: true, count: w * h)) == nil)
        // Transparent pixels outside the hole aren't copied from either.
        var clear = image
        for p in 0..<(w * h) { clear[p * 4 + 3] = 0 }
        let hole = (0..<(w * h)).map { $0 % w == 30 && $0 / w == 30 }
        #expect(InpaintKit.patchFill(width: w, height: h, channels: 4, image: clear, hole: hole, alpha: 3) == nil)
    }
}
