// The enlarger slot (AB-T-0292): its status (empty, filled, unavailable, emptied), the CGImage adapter's
// round trip (placement at the doubled rect, depth, straight alpha, an opaque region kept opaque), and the
// checks `enlarge(passes:)` makes of each pass. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.

import CoreGraphics
import PCFoundation
import Testing
@testable import PCIntelligence

@Suite struct EnlargeTests {
    /// A nearest ×2 of a CGImage, through the bridge's own conversions.
    static func nearest2x(_ image: CGImage, _ sample: SampleType) throws -> CGImage {
        let cs = KitBridge.defaultColorSpace(sample: sample)
        let src = try KitBridge.rgba(from: image, colorSpace: cs, sample: sample)
        let (w, h) = (image.width, image.height)
        var out = [SIMD4<Float>](repeating: .zero, count: 4 * w * h)
        for y in 0..<(2 * h) { for x in 0..<(2 * w) { out[y * 2 * w + x] = src[(y / 2) * w + x / 2] } }
        let opaque = image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst
        return try KitBridge.image(fromRGBA: out, width: 2 * w, height: 2 * h, sample: sample, colorSpace: cs, alpha: opaque ? .opaque : .keep)
    }

    @Test func theSlotIsUnavailableUntilFilledAndAfterEmptying() {
        let r = ProviderRegistry()
        let ai = PCIntelligence(registry: r)
        #expect(!r.status(of: .enlarge).isAvailable)
        #expect(r.status(of: .enlarge).reason?.contains("register an ImageEnlarger") == true)
        #expect(ai.enlarger == nil)

        r.register(enlarger: ImageEnlargerClosure("Doubler") { s, _ in s })
        #expect(r.status(of: .enlarge) == .available(tier: .model, engine: "Doubler", injected: true))
        #expect(ai.enlarger?.name == "Doubler")

        r.register(enlarger: ImageEnlargerClosure("Anime4K", availability: { .unavailable(reason: "no Metal device") }) { s, _ in s })
        #expect(r.status(of: .enlarge).reason == "Anime4K can't run: no Metal device")
        #expect(ai.enlarger == nil)

        r.register(enlarger: ImageEnlargerClosure("Doubler") { s, _ in s })
        r.unregister(.enlarge)
        #expect(!r.status(of: .enlarge).isAvailable && ai.enlarger == nil)
        r.register(enlarger: ImageEnlargerClosure("Doubler") { s, _ in s })
        r.removeAll()
        #expect(!r.status(of: .enlarge).isAvailable && ai.enlarger == nil)
    }

    @Test(arguments: [SampleType.u8, .u16, .f32])
    func theCGImageAdapterPlacesTheDoubleAtTheDoubledRect(_ sample: SampleType) async throws {
        let format = PixelFormat(mode: .rgb, sample: sample, alpha: true)
        let rect = PixelRect(x: 5, y: 3, width: 3, height: 2)
        var s = Surface(format: format)
        let colours: [SIMD4<Float>] = [SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 0.5), SIMD4(0, 0, 1, 1),
                                       SIMD4(1, 1, 0, 1), SIMD4(0, 1, 1, 0.25), SIMD4(1, 0, 1, 1)]
        s.writeRGBA(rect, colours)
        let e = CGImageEnlarger("Nearest") { try EnlargeTests.nearest2x($0, sample) }
        let out = try await e.enlarge(s, rect: rect)
        #expect(out.format == format)
        #expect(out.contentBounds == PixelRect(x: 10, y: 6, width: 6, height: 4))
        for i in colours.indices {
            // What the surface stores (8 bits keep 0.5 as 128/255).
            let c = s.rgba(x: Int32(5 + i % 3), y: Int32(3 + i / 3))
            let (x, y) = (Int32(10 + 2 * (i % 3)), Int32(6 + 2 * (i / 3)))
            for (dx, dy) in [(Int32(0), Int32(0)), (1, 0), (0, 1), (1, 1)] {
                let p = out.rgba(x: x + dx, y: y + dy)
                // Straight alpha survives, and colours under partial alpha keep their stored levels.
                #expect(max(abs(p.x - c.x), abs(p.y - c.y), abs(p.z - c.z), abs(p.w - c.w)) < 1e-6, "\(sample) \(i): \(p) vs \(c)")
            }
        }
    }

    @Test func anOpaqueRegionStaysOpaque() async throws {
        let format = PixelFormat(mode: .rgb, sample: .u8, alpha: true)
        let rect = PixelRect(x: 0, y: 0, width: 4, height: 4)
        var s = Surface(format: format)
        s.writeRGBA(rect, [SIMD4<Float>](repeating: SIMD4(0.2, 0.4, 0.6, 1), count: 16))
        let e = CGImageEnlarger("Nearest") { image in
            #expect(image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst, "\(image.alphaInfo)")
            return try EnlargeTests.nearest2x(image, .u8)
        }
        let out = try await e.enlarge(s, rect: rect)
        #expect(out.readRGBA(PixelRect(x: 0, y: 0, width: 8, height: 8)).allSatisfy { $0.w == 1 })
    }

    @Test func theCGImageAdapterRefusesAnotherSize() async throws {
        var s = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: true))
        let rect = PixelRect(x: 0, y: 0, width: 4, height: 4)
        s.writeRGBA(rect, [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 1), count: 16))
        let same = CGImageEnlarger("Same") { $0 }
        await #expect(throws: KitBridgeError.self) { _ = try await same.enlarge(s, rect: rect) }
    }

    @Test func enlargeRunsThePassesAndChecksEachOne() async throws {
        let format = PixelFormat(mode: .rgb, sample: .u8, alpha: true)
        var s = Surface(format: format)
        let rect = PixelRect(x: 1, y: 2, width: 3, height: 3)
        s.writeRGBA(rect, [SIMD4<Float>](repeating: SIMD4(0, 0, 1, 1), count: 9))
        let r = ProviderRegistry()
        let ai = PCIntelligence(registry: r)
        await #expect(throws: IntelligenceError.unavailable(.enlarge, r.status(of: .enlarge).reason!)) {
            _ = try await ai.enlarge(s, rect: rect, passes: 1)
        }

        r.register(enlarger: CGImageEnlarger("Nearest") { try EnlargeTests.nearest2x($0, .u8) })
        let up = try await ai.enlarge(s, rect: rect, passes: 2)
        #expect(up.rect == PixelRect(x: 4, y: 8, width: 12, height: 12))
        #expect(up.surface.contentBounds == up.rect)
        #expect(up.receipt.engine == "Nearest" && up.receipt.metrics["appliedScale"] == 4 && up.passes == 2)
        await #expect(throws: IntelligenceError.self) { _ = try await ai.enlarge(s, rect: rect, passes: 0) }

        // Another format, or pixels outside the doubled rect, fail the pass.
        r.register(enlarger: ImageEnlargerClosure("Gray") { _, _ in Surface(format: PixelFormat(mode: .grayscale, sample: .u8, alpha: false)) })
        await #expect(throws: IntelligenceError.self) { _ = try await ai.enlarge(s, rect: rect, passes: 1) }
        r.register(enlarger: ImageEnlargerClosure("Spill") { s, _ in s })
        await #expect(throws: IntelligenceError.self) { _ = try await ai.enlarge(s, rect: rect, passes: 1) }
    }
}
