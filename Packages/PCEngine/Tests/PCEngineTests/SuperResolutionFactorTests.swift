// image.superResolution reports the factor the provider applied (AB-T-0337). MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.

import CoreGraphics
import Foundation
import PCDocument
@testable import PCEngine
import PCFoundation
import PCIntelligence
import Testing

/// An upscaler that always returns ×4, whatever factor it is asked for.
struct AlwaysFourTimes: UpscaleProvider {
    var name = "AlwaysFour"
    func upscale(_ image: CGImage, factor: Int) async throws -> CGImage {
        let (w, h) = (image.width * 4, image.height * 4)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let out = { ctx.interpolationQuality = .none; ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return ctx.makeImage() }()
        else { throw EngineError.other("no context") }
        return out
    }
}

@Suite struct SuperResolutionFactorTests {
    /// A ×3 request to a provider that applies ×4: the result says 4 and the new document is four times the size.
    @Test(.timeLimit(.minutes(1))) func theResultReportsTheFactorTheProviderApplied() async throws {
        let services = EngineServices()
        services.intelligence.registry.register(upscale: AlwaysFourTimes())
        let s = Session(services: services)
        try s.execute("file.new", ["width": 20, "height": 10, "background": "white"])
        let r = try await s.executeAsync("image.superResolution", ["factor": 3])
        #expect(r["appliedFactor"]?.doubleValue == 4)
        #expect(r["width"]?.intValue == 80 && r["height"]?.intValue == 40)
    }
}
