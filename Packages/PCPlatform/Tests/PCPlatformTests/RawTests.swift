// Ports the intent of photocraft-raw's DNG tests (crates/raw/tests/dng.rs: develop a synthetic DNG,
// check colours, white balance, exposure, orientation) onto Core Image's CIRAWFilter, with the DNG
// generated in-test. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCFoundation
import Testing
import ImageBridge
@testable import PCPlatform

private func patch(_ r: RasterBuffer, x: Int) -> SIMD3<Float> {
    let f = r.floats(), ch = r.format.channels
    var s = SIMD3<Float>.zero
    var n: Float = 0
    for y in (r.height / 2 - 8)..<(r.height / 2 + 8) { for xx in (x - 8)..<(x + 8) {
        let i = (y * r.width + xx) * ch
        s += SIMD3(f[i], f[i + 1], f[i + 2]); n += 1
    } }
    return s / n
}

@Suite("Camera raw (CIRAWFilter replaces photocraft-raw)")
struct RawTests {
    @Test func developsASyntheticDNGTo16BitProPhoto() throws {
        let dng = Fixtures.dng()
        try dng.write(to: Fixtures.url("synthetic-bayer.dng"))
        #expect(ImageFormat.detect(dng) == .cameraRaw)
        #expect(RawDeveloper.isSupported(data: dng))
        let dev = try RawDeveloper.develop(data: dng)
        #expect(dev.raster.format == PixelFormat(mode: .rgb, sample: .u16, alpha: false))
        #expect((dev.raster.width, dev.raster.height) == (384, 256))
        #expect(dev.profile == BuiltinProfile.proPhoto.profile)
        #expect(dev.info.make == "PhotoCraftNative" && dev.info.model == "Synthetic")
        #expect(dev.info.nativeWidth == 384 && dev.info.nativeHeight == 256)
        let red = patch(dev.raster, x: 64), green = patch(dev.raster, x: 192), gray = patch(dev.raster, x: 320)
        measure("synthetic DNG → CIRAWFilter (decoder \(dev.info.decoderVersion), versions \(dev.info.supportedDecoderVersions)) ProPhoto16: red patch \(red), green \(green), gray \(gray); as-shot \(dev.info.asShotTemperature) K tint \(dev.info.asShotTint)")
        #expect(red.x > red.y && red.x > red.z)
        #expect(green.y > green.x && green.y > green.z)
        #expect(abs(gray.x - gray.y) < 0.01 && abs(gray.y - gray.z) < 0.01, "neutral stays neutral: \(gray)")
        // Through the generic decode entry point too.
        let d = try ImageCodecs.decode(dng)
        #expect(d.format == .cameraRaw && d.raster.format.sample == .u16)
    }

    @Test func exposureWhiteBalanceAndOutputs() throws {
        let dng = Fixtures.dng()
        let base = try RawDeveloper.develop(data: dng, settings: { var s = RawDevelopSettings(); s.output = .linearFloat; return s }())
        #expect(base.raster.format.sample == .f32)
        let plus = try RawDeveloper.develop(data: dng, settings: { var s = RawDevelopSettings(exposure: 1); s.output = .linearFloat; return s }())
        let g0 = patch(base.raster, x: 320), g1 = patch(plus.raster, x: 320)
        measure("linear float gray patch: as shot \(g0), +1 EV \(g1), ratio \(g1.y / g0.y)")
        #expect(abs(g1.y / g0.y - 2) < 0.1, "scene-linear: +1 EV doubles the light")
        let t = base.info.asShotTemperature
        let warm = try RawDeveloper.develop(data: dng, settings: RawDevelopSettings(exposure: 0, temperature: t + 2500, tint: base.info.asShotTint))
        let cool = try RawDeveloper.develop(data: dng, settings: RawDevelopSettings(exposure: 0, temperature: t - 1500, tint: base.info.asShotTint))
        let w = patch(warm.raster, x: 320), c = patch(cool.raster, x: 320)
        measure("white balance on the gray patch: \(Int(t + 2500)) K → R/B \(w.x / w.z); \(Int(t - 1500)) K → R/B \(c.x / c.z)")
        #expect(w.x / w.z > c.x / c.z, "a higher temperature setting renders warmer")
        for out in [RawOutput.sRGB16, .displayP3_16, .proPhotoFloat] {
            let r = try RawDeveloper.develop(data: dng, settings: { var s = RawDevelopSettings(); s.output = out; return s }())
            #expect(r.raster.width == 384)
        }
        let half = try RawDeveloper.develop(data: dng, settings: { var s = RawDevelopSettings(); s.scale = 0.5; return s }())
        #expect(half.raster.width == 192 && half.raster.height == 128)
    }

    @Test func orientationAndTone() throws {
        let dng = Fixtures.dng(orientation: 6)
        let up = try RawDeveloper.develop(data: dng)
        #expect((up.raster.width, up.raster.height) == (256, 384), "orientation 6 applied")
        #expect(up.metadata.orientation == 1)
        let stored = try RawDeveloper.develop(data: dng, settings: { var s = RawDevelopSettings(); s.orient = false; return s }())
        #expect((stored.raster.width, stored.raster.height) == (384, 256))
        let tone = RawTone(shadows: 60, highlights: -60, clarity: 30, texture: 20, dehaze: 10)
        let toned = try RawDeveloper.develop(data: Fixtures.dng(), settings: { var s = RawDevelopSettings(); s.tone = tone; return s }())
        measure("tone mapping warnings: \(toned.warnings)")
        #expect(toned.warnings.contains { $0.contains("Dehaze") })
        #expect(toned.raster.bytes != (try RawDeveloper.develop(data: Fixtures.dng())).raster.bytes)
    }

    @Test func refusesNonRawAndReadsPreviews() throws {
        #expect(!RawDeveloper.isSupported(data: Data("nope".utf8)))
        #expect(throws: PlatformError.self) { try RawDeveloper.develop(data: Data("nope".utf8)) }
        // A synthetic DNG has no embedded JPEG; ImageIO renders a thumbnail instead.
        let p = RawDeveloper.embeddedPreview(data: Fixtures.dng(), maxPixelSize: 128)
        measure("embedded preview of a synthetic DNG: \(p.map { "\($0.width)×\($0.height)" } ?? "none")")
        #expect(RawDeveloper.supportedCameraModels.count > 100)
        measure("Core Image raw decoder supports \(RawDeveloper.supportedCameraModels.count) camera models")
    }

    @Test func agreesWithMediaBridgesEightBitRawDecode() throws {
        let url = Fixtures.url("synthetic-bayer-bridge.dng")
        try Fixtures.dng().write(to: url)
        let bridge = try ImageCodecs.decodeDisplay8(url: url)
        #expect(bridge.count == 1)
        let ours = try RawDeveloper.develop(url: url, settings: { var s = RawDevelopSettings(); s.output = .sRGB16; return s }())
        let ours8 = ours.raster.converted(to: .u8)
        let b = ImageCodecs.stripAlpha(bridge[0])
        #expect((b.width, b.height) == (ours8.width, ours8.height))
        let mean = Fixtures.meanDiff(ours8, b)
        measure("our 16-bit sRGB develop vs media-bridge ImageBridge 8-bit raw decode: mean |Δ| \(mean * 255)/255")
        #expect(mean < 2.0 / 255)
        let probe = try ImageCodecs.probe(url: url)
        #expect(probe.isRaw && probe.bitDepth == 8, "ImageBridge narrows raw to 8-bit (its P1)")
    }
}
