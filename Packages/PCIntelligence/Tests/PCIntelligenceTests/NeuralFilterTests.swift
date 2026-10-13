// The model-free tiers of the Neural Filters and light operations, on generated images: JPEG
// Artifacts Removal / noise reduction through RestoreTier0's guided filter, Auto White Balance
// through LightTier0's shades-of-grey + Bradford, and SDR → HDR through LightTier0's BT.2408 chain.
// Also selection limits and outputs. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import PCHistory
import Testing
@testable import PCIntelligence

@Suite struct NeuralFilterTests {
    let ai = PCIntelligence()

    static func clean(_ x: Int, _ y: Int) -> SIMD4<Float> {
        // Two flat halves with a hard edge, plus a gentle ramp.
        let base: Float = x < 64 ? 0.3 : 0.7
        return SIMD4(base, base * 0.9 + Float(y) / 1000, base * 0.8, 1)
    }

    static func noisy(depth: SampleType = .u8) -> Document {
        var rng = Fixture.RNG(state: 7)
        return Fixture.document(width: 128, height: 96, depth: depth) { x, y in
            let n = rng.normal() * 0.07
            return clean(x, y) + SIMD4(n, n, n, 0)
        }
    }

    static func error(_ s: Surface, _ r: PixelRect) -> Float {
        let px = s.readRGBA(r)
        var e: Float = 0
        for (i, p) in px.enumerated() {
            let x = Int(r.x0) + i % r.width, y = Int(r.y0) + i / r.width
            let t = clean(x, y)
            e += abs(p.x - t.x) + abs(p.y - t.y) + abs(p.z - t.z)
        }
        return e / Float(px.count * 3)
    }

    @Test(arguments: [SampleType.u8, .u16])
    func jpegArtifactsRemovalSmoothsNoiseAndKeepsTheEdge(depth: SampleType) async throws {
        let d = NeuralFilterTests.noisy(depth: depth)
        let out = try await ai.jpegArtifactsRemoval(d, layer: d.layers[0].id, strength: .high)
        #expect(out.receipt.tier == .classical && out.receipt.engine == BuiltIn.classicalDenoise)
        let sigma = try #require(out.receipt.metrics["noiseSigma"]), after = try #require(out.receipt.metrics["noiseSigmaAfter"])
        #expect(sigma > 0.02, "Immerkaer measured the noise: \(sigma)")
        #expect(after < sigma / 2, "σ \(sigma) → \(after)")
        let s = try #require(try Fixture.applied(out.transaction, to: d).layers[0].rasterSurface)
        let r = d.bounds
        #expect(NeuralFilterTests.error(s, r) < NeuralFilterTests.error(d.layers[0].rasterSurface!, r) * 0.6)
        // The edge survives: the two sides stay apart.
        let left = Fixture.mean(s, PixelRect(x: 50, y: 40, width: 10, height: 10)), right = Fixture.mean(s, PixelRect(x: 68, y: 40, width: 10, height: 10))
        #expect(right.x - left.x > 0.35)
    }

    @Test func filtersAreLimitedByTheSelectionAndKeepAlpha() async throws {
        var d = NeuralFilterTests.noisy()
        var top = Layer.raster("Top", surface: d.layers[0].rasterSurface!)
        top.withRaster { $0.fill(PixelRect(x: 0, y: 0, width: 16, height: 96), with: [0.5, 0.5, 0.5, 0.25]) }
        let id = d.insertAbove(nil, top)
        d.selection = Fixture.selection(PixelRect(x: 0, y: 0, width: 64, height: 96))
        let out = try await ai.jpegArtifactsRemoval(d, layer: id, strength: .medium)
        #expect(out.changedRect == PixelRect(x: 0, y: 0, width: 64, height: 96))
        let before = try #require(d.layer(id)?.rasterSurface)
        let s = try #require(try Fixture.applied(out.transaction, to: d).layer(id)?.rasterSurface)
        let right = PixelRect(x: 64, y: 0, width: 64, height: 96)
        #expect(s.readRegion(right) == before.readRegion(right), "outside the selection nothing changed")
        #expect(s.pixel(x: 5, y: 5).last == before.pixel(x: 5, y: 5).last, "alpha is preserved")
        // New masked layer output.
        let masked = try await ai.jpegArtifactsRemoval(d, layer: id, output: .newLayerMasked)
        let a = try Fixture.applied(masked.transaction, to: d)
        let nl = try #require(a.layer(masked.layer))
        #expect(nl.mask?.value(x: 10, y: 10) == 1 && nl.mask?.value(x: 100, y: 10) == 0)
        #expect(a.layer(id) == d.layer(id))
        #expect(nl.name == "Top copy")
    }

    @Test func layerPixelsOffTheCanvasAreLeftAlone() async throws {
        // A layer reaching 40 px past the left edge and below the canvas (layer bounds ≠ canvas).
        var d = NeuralFilterTests.noisy()
        var rng = Fixture.RNG(state: 3)
        var top = Layer.raster("Wide", format: d.pixelFormat)
        let reach = PixelRect(x: -40, y: 50, width: 120, height: 80)
        top.withRaster { s in
            s.writeRegion(reach, (0..<reach.area).flatMap { _ in [0.5 + rng.normal() * 0.05, 0.4, 0.3, 1] })
        }
        let id = d.insertAbove(nil, top)
        let out = try await ai.jpegArtifactsRemoval(d, layer: id)
        #expect(out.changedRect == PixelRect(x: 0, y: 50, width: 80, height: 46), "only the on-canvas part of the content")
        let before = try #require(d.layer(id)?.rasterSurface)
        let s = try #require(try Fixture.applied(out.transaction, to: d).layer(id)?.rasterSurface)
        let left = PixelRect(x: -40, y: 50, width: 40, height: 80), below = PixelRect(x: 0, y: 96, width: 80, height: 34)
        #expect(s.readRegion(left) == before.readRegion(left))
        #expect(s.readRegion(below) == before.readRegion(below))
        #expect(s.readRegion(PixelRect(x: 0, y: 50, width: 80, height: 46)) != before.readRegion(PixelRect(x: 0, y: 50, width: 80, height: 46)))
    }

    @Test func autoWhiteBalanceNeutralisesACast() async throws {
        // Grey ramps under a warm illuminant (linear R ×1.25, B ×0.7).
        let cast = SIMD3<Float>(1.25, 1.0, 0.7)
        let d = Fixture.document(width: 96, height: 64) { x, y in
            let g = 0.08 + 0.6 * Float(x) / 95 * (0.6 + 0.4 * Float(y) / 63)
            let lin = SIMD3(repeating: g) * cast
            return SIMD4(ColorConvert.linearToSRGB(lin.x), ColorConvert.linearToSRGB(lin.y), ColorConvert.linearToSRGB(lin.z), 1)
        }
        let out = try await ai.autoWhiteBalance(d, layer: d.layers[0].id)
        #expect(out.receipt.tier == .classical && out.receipt.capability == .whiteBalance)
        let kelvin = try #require(out.receipt.metrics["kelvin"])
        #expect(kelvin < 5000, "a warm cast reads as a low colour temperature: \(kelvin) K")
        let before = Fixture.mean(d.layers[0].rasterSurface!, d.bounds)
        let after = Fixture.mean(try #require(try Fixture.applied(out.transaction, to: d).layers[0].rasterSurface), d.bounds)
        #expect(abs(before.x - before.z) > 0.15)
        #expect(abs(after.x - after.z) < 0.02 && abs(after.x - after.y) < 0.02, "neutral after: \(after)")
        // A grayscale document has no white balance.
        var gray = d
        gray.mode = .grayscale
        await #expect(throws: IntelligenceError.self) { try await ai.autoWhiteBalance(gray, layer: gray.layers[0].id) }
    }

    @Test func sdrToHDRAnchorsDiffuseWhite() async throws {
        let d = Fixture.document(width: 96, height: 32, depth: .u16) { x, _ in
            x < 32 ? SIMD4(1, 1, 1, 1) : x < 64 ? SIMD4(0.5, 0.5, 0.5, 1) : SIMD4(0, 0, 0, 1)
        }
        let at203 = try await ai.sdrToHDR(d)
        #expect(at203.receipt.tier == .classical && at203.receipt.engine == BuiltIn.hdrExpansion)
        let doc = at203.document
        #expect(doc.depth == .f32 && doc.mode == .rgb && doc.size == d.size)
        #expect(doc.iccProfile.flatMap { CGColorSpace(iccData: Data($0) as CFData) } != nil, "tagged linear sRGB")
        #expect(doc.layers.first?.name == "Background")
        let s = try #require(doc.layers.first?.rasterSurface)
        #expect(abs(s.pixel(x: 16, y: 16)[0] - 1) < 0.01, "SDR white = 203 cd/m² = 1.0")
        #expect(abs(s.pixel(x: 48, y: 16)[0] - ColorConvert.srgbToLinear(0.5)) < 0.01, "mid grey linearised")
        #expect(s.pixel(x: 80, y: 16)[0] < 0.001)
        #expect(abs((at203.receipt.metrics["peakNits"] ?? 0) - 203) < 3)
        // A brighter anchor lifts white to 1000 / 203 ≈ 4.93: HDR values above 1.
        let at1000 = try await ai.sdrToHDR(d, options: HDRExpansionOptions(diffuseWhiteNits: 1000))
        let w = try #require(at1000.document.layers.first?.rasterSurface).pixel(x: 16, y: 16)[0]
        #expect(abs(w - Float(1000.0 / 203.0)) < 0.05, "white \(w)")
        await #expect(throws: IntelligenceError.self) { try await ai.sdrToHDR(d, options: HDRExpansionOptions(diffuseWhiteNits: 20)) }
    }

    @Test func modelOnlyFiltersAreUnavailableWithoutProviders() async throws {
        let d = NeuralFilterTests.noisy()
        for op in [
            { try await ai.colorize(d, layer: d.layers[0].id) },
            { try await ai.restoreFaces(d, layer: d.layers[0].id) },
        ] as [@Sendable () async throws -> PixelEditOutcome] {
            do {
                _ = try await op()
                Issue.record("ran without a provider")
            } catch IntelligenceError.unavailable(_, let reason) {
                #expect(reason.contains("register"))
            }
        }
        await #expect(throws: IntelligenceError.self) {
            try await ai.upscale(d.layers[0].rasterSurface!, rect: d.bounds, factor: 2)
        }
    }
}
