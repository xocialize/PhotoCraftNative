// Ports the intent of photocraft-codecs' tests (crates/codecs/tests/{roundtrip,png_jpeg,fidelity,
// metadata,orientation,detect_caps,limits,tiff_pages,malformed}.rs) onto ImageIO, webp-swift and the
// small ported codecs. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import ImageIO
import PCFoundation
import Testing
@testable import PCPlatform

private func fmt(_ m: ColorMode, _ s: SampleType, _ a: Bool) -> PixelFormat { PixelFormat(mode: m, sample: s, alpha: a) }

@Suite("Codecs (ImageIO replaces photocraft-codecs)")
struct CodecTests {
    @Test func capsMatchImageIOAtRunTime() {
        measure("ImageIO reads \(ImageFormat.imageIOReadableTypes.count) types: \(ImageFormat.imageIOReadableTypes.joined(separator: " "))")
        measure("ImageIO writes \(ImageFormat.imageIOWritableTypes.count) types: \(ImageFormat.imageIOWritableTypes.joined(separator: " "))")
        for f in ImageFormat.allCases {
            let c = f.caps
            if c.readBackend == .imageIO { #expect(ImageFormat.imageIOReadableTypes.contains(f.uti), "\(f)") }
            if c.writeBackend == .imageIO { #expect(ImageFormat.imageIOWritableTypes.contains(f.uti), "\(f)") }
        }
        #expect(!ImageFormat.imageIOWritableTypes.contains(ImageFormat.webp.uti), "WebP write is webp-swift's")
        #expect(ImageFormat.webp.caps.write)
        #expect(ImageFormat.from(extension: "photo.JPG") == .jpeg)
        #expect(ImageFormat.from(extension: ".tif") == .tiff)
        #expect(ImageFormat.from(extension: "x.cr3") == .cameraRaw)
    }

    /// Lossless round trips at the native depth and layout (photocraft roundtrip.rs).
    @Test(arguments: [
        (ImageFormat.png, [fmt(.grayscale, .u8, false), fmt(.grayscale, .u8, true), fmt(.rgb, .u8, false), fmt(.rgb, .u8, true),
                           fmt(.grayscale, .u16, false), fmt(.rgb, .u16, true)]),
        (.tiff, [fmt(.grayscale, .u8, false), fmt(.rgb, .u8, true), fmt(.rgb, .u16, false), fmt(.rgb, .u16, true), fmt(.rgb, .f32, true),
                 fmt(.grayscale, .f32, false), fmt(.cmyk, .u8, false), fmt(.cmyk, .u16, false), fmt(.cmyk, .u8, true)]),
        (.openEXR, [fmt(.rgb, .f32, true), fmt(.grayscale, .f32, false)]),
        (.psd, [fmt(.rgb, .u8, false), fmt(.rgb, .u16, false), fmt(.grayscale, .u16, false), fmt(.cmyk, .u8, false)]),
        (.bmp, [fmt(.rgb, .u8, false), fmt(.rgb, .u8, true)]),
        (.tga, [fmt(.rgb, .u8, true), fmt(.grayscale, .u8, false)]),
        (.qoi, [fmt(.rgb, .u8, false), fmt(.rgb, .u8, true)]),
        (.pnm, [fmt(.grayscale, .u8, false), fmt(.rgb, .u16, false), fmt(.rgb, .u8, true), fmt(.rgb, .f32, false), fmt(.grayscale, .f32, false)]),
        (.fits, [fmt(.grayscale, .u8, false), fmt(.grayscale, .u16, false), fmt(.rgb, .u16, false), fmt(.rgb, .f32, false)]),
        (.webp, [fmt(.rgb, .u8, true)]),
    ])
    func losslessRoundTrip(format: ImageFormat, formats: [PixelFormat]) throws {
        for f in formats {
            let src = Fixtures.raster(f, hdr: f.sample == .f32 && format != .fits && format != .pnm)
            var opts = EncodeOptions()
            opts.tiffCompression = .deflate
            let data = try ImageCodecs.encode(src, as: format, options: opts)
            #expect(ImageFormat.detect(data) == format, "\(format) detect")
            let d = try ImageCodecs.decode(data)
            var tol: Float = 0
            if format == .webp { tol = 0 }
            if f.sample == .f32 && format == .pnm { tol = 0 }
            if format == .fits && f.sample == .f32 { tol = 1e-6 }
            // ImageIO's EXR path converts through the file's chromaticities: ~1e-5 absolute.
            if format == .openEXR { tol = 2e-4 }
            #expect(d.raster.format == src.format, "\(format) \(f): decoded as \(d.raster.format)")
            if d.raster.format == src.format {
                let diff = Fixtures.maxDiff(src, d.raster)
                #expect(diff <= tol, "\(format) \(f): max diff \(diff)")
            }
        }
    }

    @Test func halfFloatEXRAndRadiance() throws {
        let src = Fixtures.raster(.rgba32f, hdr: true)
        var o = EncodeOptions(); o.exrPrecision = .half
        let half = try ImageCodecs.decode(try ImageCodecs.encode(src, as: .openEXR, options: o))
        #expect(half.storedDepth == .f16)
        #expect(half.warnings.contains(.depthWidened(from: .f16, to: .f32)))
        let rel = zip(src.floats(), half.raster.floats()).map { abs($0 - $1) / max(abs($0), 0.1) }.max()!
        measure("EXR half round trip max error \(rel) relative to max(|v|, 0.1) (half precision 2⁻¹¹ ≈ 4.9e-4; ImageIO's chromaticity round trip adds ~5e-5 absolute)")
        #expect(rel < 1.5e-3)
        // ImageIO's EXR writer always adds an A channel to RGB (measured: channels A,B,G,R).
        let rgbOnly = try ImageCodecs.decode(try ImageCodecs.encode(Fixtures.raster(PixelFormat(mode: .rgb, sample: .f32, alpha: false)), as: .openEXR))
        #expect(rgbOnly.raster.format == .rgba32f && rgbOnly.raster.floats()[3] == 1)
        // Radiance: ImageIO reads, PCPlatform writes flat RGBE.
        let rgb = Fixtures.raster(PixelFormat(mode: .rgb, sample: .f32, alpha: false), hdr: true)
        let hdr = try ImageCodecs.encode(rgb, as: .hdr)
        #expect(ImageFormat.detect(hdr) == .hdr)
        let back = try ImageCodecs.decode(hdr)
        // RGBE shares one exponent per pixel: error is relative to the pixel's largest component.
        let a = rgb.floats(), b = back.raster.floats()
        var relH: Float = 0
        for i in stride(from: 0, to: a.count, by: 3) {
            let m = max(a[i], a[i + 1], a[i + 2], 1e-6)
            for k in 0..<3 { relH = max(relH, abs(a[i + k] - b[i + k]) / m) }
        }
        measure("Radiance RGBE write (ported) → ImageIO read: max error relative to the pixel's max component \(relH) (RGBE: 8-bit mantissa)")
        #expect(back.raster.format == rgb.format && relH < 2.0 / 256)
    }

    @Test func lossyFormatsStayClose() throws {
        for (format, f, tol) in [(ImageFormat.jpeg, fmt(.rgb, .u8, false), Float(0.06)), (.jpeg, fmt(.grayscale, .u8, false), 0.06),
                                 (.jpeg, fmt(.cmyk, .u8, false), 0.08), (.heif, fmt(.rgb, .u8, true), 0.08), (.heif, fmt(.rgb, .u16, false), 0.08),
                                 (.avif, fmt(.rgb, .u8, true), 0.08), (.jpeg2000, fmt(.rgb, .u8, true), 0.08)] {
            let src = Fixtures.raster(f, width: 64, height: 48)
            let d = try ImageCodecs.decode(try ImageCodecs.encode(src, as: format))
            let mean = Fixtures.meanDiff(src, d.raster)
            measure("\(format) \(f.mode) \(f.sample)\(f.alpha ? "+α" : "") → decoded \(d.raster.format.sample)\(d.raster.format.alpha ? "+α" : "") (stored \(d.storedDepth)): mean |Δ| \(mean)")
            #expect(d.raster.format.mode == f.mode && d.raster.format.alpha == f.alpha, "\(format) \(f)")
            #expect(mean < tol, "\(format) \(f)")
        }
        // CMYK JPEG keeps the ink convention (1 = full ink), not Adobe's inverted storage.
        var c = RasterBuffer(width: 16, height: 16, format: fmt(.cmyk, .u8, false))
        for i in 0..<256 { c.bytes[i * 4] = 255 }
        let back = try ImageCodecs.decode(try ImageCodecs.encode(c, as: .jpeg))
        #expect(back.raster.floats()[0] > 0.9 && back.raster.floats()[3] < 0.1, "\(back.raster.floats().prefix(4))")
        // WebP lossy (webp-swift).
        var o = EncodeOptions(); o.webpLossless = false; o.webpQuality = 85
        let src = Fixtures.raster(.rgba8, width: 64, height: 48)
        let w = try ImageCodecs.encode(src, as: .webp, options: o)
        #expect(SourceSettings.webpEncoding(w) != .lossless)
        if case .lossy(let q) = SourceSettings.webpEncoding(w) { #expect(q != nil); measure("webp-swift q85 lossy base quantiser \(q ?? -1)") }
        #expect(SourceSettings.webpEncoding(try ImageCodecs.encode(src, as: .webp)) == .lossless)
        #expect(Fixtures.meanDiff(src, try ImageCodecs.decode(w).raster) < 0.06)
    }

    /// PCEngine request 6: a lossy WebP's quality on libwebp's scale, recovered from its frame
    /// header with libwebp's own quality → quantiser mapping inverted (photocraft
    /// `webp_lossless_and_lossy_are_told_apart` inverts its own encoder's the same way), within ±2.
    @Test func webpQualityIsRecoveredOnLibwebpsScale() throws {
        // The forward map is libwebp's: 75 → 26 (c = 0.5^⅓), 0 → 127, 100 → 0.
        #expect(SourceSettings.libwebpQuantizer(quality: 75) == 26 && SourceSettings.libwebpQuantizer(quality: 0) == 127 && SourceSettings.libwebpQuantizer(quality: 100) == 0)
        // The inverse lands back inside each quality's quantiser interval.
        for q in 0...100 {
            let i = SourceSettings.libwebpQuantizer(quality: Double(q))
            let back = SourceSettings.libwebpQuality(compression: 1 - (Double(i) + 0.5) / 127)
            #expect(SourceSettings.libwebpQuantizer(quality: back) == i, "q\(q) → index \(i) → \(back)")
        }
        // Half flat, half noise: most macroblocks alike, so libwebp clips the other segments'
        // susceptibility at ±127 (the case the clipped solve in `webpQuality` exists for).
        func split(_ flatFirst: Bool) -> RasterBuffer {
            let noise = Fixtures.raster(PixelFormat(mode: .rgb, sample: .u8, alpha: false), width: 128, height: 96).floats()
            var v = noise
            for y in 0..<96 { for x in 0..<128 where (x < 96) == flatFirst { for k in 0..<3 { v[(y * 128 + x) * 3 + k] = [0.5, 0.4, 0.3][k] } } }
            return RasterBuffer(width: 128, height: 96, format: PixelFormat(mode: .rgb, sample: .u8, alpha: false), floats: v)
        }
        var recovered: [String] = []
        for (name, src) in [("photo", Fixtures.smooth(width: 96, height: 72)), ("noise", Fixtures.raster(PixelFormat(mode: .rgb, sample: .u8, alpha: false), width: 80, height: 64)),
                            ("noise+α", Fixtures.raster(.rgba8, width: 64, height: 48)), ("¾ flat", split(true)), ("¼ flat", split(false))] {
            for q in [10, 30, 50, 60, 75, 80, 90, 95, 100] {
                var o = EncodeOptions(); o.webpLossless = false; o.webpQuality = q
                let bytes = try ImageCodecs.encode(src, as: .webp, options: o)
                // The top of the knob stays lossy (fleet lesson: Chrome / libwebp flip to lossless at 1.0).
                #expect(SourceSettings.webpImageChunk([UInt8](bytes))?.lossless == false, "\(name) q\(q) is VP8")
                guard case .lossy = SourceSettings.webpEncoding(bytes) else { Issue.record("\(name) q\(q) not lossy"); continue }
                guard let est = SourceSettings.webpQuality(bytes) else { Issue.record("\(name) q\(q): no quality"); continue }
                recovered.append("\(q)→\(est)")
                #expect(abs(est - q) <= 2, "\(name): lossy WebP saved at \(q), recovered \(est)")
            }
            measure("webp-swift lossy \(name) quality written → recovered: \(recovered.joined(separator: ", "))")
            recovered = []
        }
        #expect(SourceSettings.webpQuality(try ImageCodecs.encode(Fixtures.smooth(width: 32, height: 32), as: .webp)) == nil, "lossless has no quality")
        #expect(SourceSettings.webpQuality(Data("RIFF\0\0\0\0WAVE".utf8)) == nil)
    }

    @Test func jpegQualityIsEstimatedAndKept() throws {
        // photocraft source_settings tests: the IJG curve.
        #expect(SourceSettings.scaled(16, 50, wide: false) == 16)
        #expect(SourceSettings.scaled(121, 100, wide: false) == 1)
        #expect(SourceSettings.scaled(16, 75, wide: false) == 8)
        #expect(SourceSettings.scaled(121, 1, wide: false) == 255)
        #expect(SourceSettings.scaled(121, 1, wide: true) == 6050)
        #expect(Set(SourceSettings.zigzag).count == 64)
        let cal = SourceSettings.imageIOJPEGCalibration()
        measure("ImageIO lossy quality → IJG quality of its tables: 0.5→\(cal[50]) 0.6→\(cal[60]) 0.75→\(cal[75]) 0.8→\(cal[80]) 0.85→\(cal[85]) 0.9→\(cal[90]) 0.95→\(cal[95]) 1.0→\(cal[100])")
        let src = Fixtures.raster(.rgb8Opaque, width: 64, height: 64)
        var hits: [String] = []
        for q in [30, 50, 75, 85, 90, 95] {
            var o = EncodeOptions(); o.jpegQuality = q
            let est = try #require(SourceSettings.jpegQuality(try ImageCodecs.encode(src, as: .jpeg, options: o)))
            hits.append("\(q)→\(est)")
            #expect(abs(est - q) <= 3, "asked \(q), file estimates \(est)")
        }
        measure("Save-at-quality round trip (asked → estimated from DQT): \(hits.joined(separator: ", "))")
        #expect(SourceSettings.jpegQuality(Data([0xFF, 0xD8, 0xFF, 0xDB, 0x00])) == nil)
        #expect(SourceSettings.jpegQuality(Data("not a jpeg".utf8)) == nil)
    }

    @Test func metadataSurvivesARoundTrip() throws {
        // A JPEG with EXIF, XMP, DPI and a Display P3 profile.
        let src = Fixtures.raster(.rgb8Opaque, width: 32, height: 32)
        var meta = ImageMetadata(resolution: Resolution(x: 300, y: 300))
        meta.propertyList = try PropertyListSerialization.data(fromPropertyList: [
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifUserComment as String: "PhotoCraftNative test", kCGImagePropertyExifLensModel as String: "Test Lens 50mm"],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFArtist as String: "PCPlatform"],
        ], format: .binary, options: 0)
        let tree = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueWithPath(tree, nil, "dc:title" as CFString, "Native port" as CFString)
        CGImageMetadataSetValueWithPath(tree, nil, "xmp:CreatorTool" as CFString, "PCPlatform" as CFString)
        meta.xmp = CGImageMetadataCreateXMPData(tree, nil) as Data?
        let p3 = BuiltinProfile.displayP3.profile
        for format in [ImageFormat.jpeg, .tiff, .png, .heif] {
            let data = try ImageCodecs.encode(src, as: format, profile: p3, metadata: meta)
            let d = try ImageCodecs.decode(data)
            #expect(d.profile?.sameColors(as: p3) == true, "\(format) ICC")
            #expect(d.metadata.resolution == Resolution(x: 300, y: 300), "\(format) DPI \(String(describing: d.metadata.resolution))")
            let comment = d.metadata.exif("UserComment") as? String
            let lens = d.metadata.exif("LensModel") as? String
            let title = d.metadata.xmpValue("dc:title")
            let tool = d.metadata.xmpValue("xmp:CreatorTool")
            measure("\(format) metadata round trip: ICC ✓, DPI ✓, EXIF UserComment \(comment ?? "–"), LensModel \(lens ?? "–"), XMP dc:title \(title ?? "–"), CreatorTool \(tool ?? "–")")
            #expect(title == "Native port", "\(format) XMP")
            if format != .png { #expect(lens == "Test Lens 50mm", "\(format) EXIF") }
            // And again: decode → encode keeps it.
            let again = try ImageCodecs.decode(try ImageCodecs.encode(d.raster, as: format, profile: d.profile, metadata: d.metadata))
            #expect(again.metadata.xmpValue("dc:title") == "Native port", "\(format) second generation")
        }
        // PNG text chunks.
        var t = ImageMetadata(); t.text = [TextEntry(key: kCGImagePropertyPNGDescription as String, value: "hello"), TextEntry(key: kCGImagePropertyPNGAuthor as String, value: "me")]
        let png = try ImageCodecs.decode(try ImageCodecs.encode(src, as: .png, metadata: t))
        #expect(png.metadata.text.contains(TextEntry(key: kCGImagePropertyPNGDescription as String, value: "hello")))
        // FITS cards survive as text.
        var ft = ImageMetadata(); ft.text = [TextEntry(key: "OBJECT", value: "M31"), TextEntry(key: "TELESCOP", value: "Test")]
        let fits = try ImageCodecs.decode(try ImageCodecs.encode(Fixtures.raster(.gray16), as: .fits, metadata: ft))
        #expect(fits.metadata.text.contains(TextEntry(key: "OBJECT", value: "M31")))
    }

    @Test func orientationIsAppliedLikeImageIOsTransform() throws {
        let src = Fixtures.raster(.rgb8Opaque, width: 7, height: 4)
        let cg = try SurfaceBridge.cgImage(src)
        for o in 1...8 {
            let out = NSMutableData()
            let dst = CGImageDestinationCreateWithData(out, "public.tiff" as CFString, 1, nil)!
            CGImageDestinationAddImage(dst, cg, [kCGImagePropertyOrientation: o] as CFDictionary)
            #expect(CGImageDestinationFinalize(dst))
            let data = out as Data
            let d = try ImageCodecs.decode(data)
            #expect(d.metadata.orientation == 1)
            #expect((d.raster.width, d.raster.height) == (o >= 5 ? (4, 7) : (7, 4)), "orientation \(o)")
            // ImageIO's own upright rendering of the same file.
            let isrc = CGImageSourceCreateWithData(data as CFData, nil)!
            let thumb = CGImageSourceCreateThumbnailAtIndex(isrc, 0, [kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                      kCGImageSourceThumbnailMaxPixelSize: 7] as CFDictionary)!
            let ref = try SurfaceBridge.raster(from: thumb)
            #expect((ref.width, ref.height) == (d.raster.width, d.raster.height))
            #expect(Fixtures.maxDiff(ref, d.raster) <= 1.0 / 255, "orientation \(o) differs from ImageIO's transform")
            var keep = DecodeOptions(); keep.keepOrientation = true
            let k = try ImageCodecs.decode(data, options: keep)
            #expect(k.metadata.orientation == o && k.raster.width == 7)
        }
    }

    @Test func framesAndPages() throws {
        let colours: [[Float]] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1]]
        let frames = colours.map { c -> (raster: RasterBuffer, delay: Double?) in
            (RasterBuffer(width: 8, height: 6, format: .rgba8, floats: (0..<48).flatMap { _ in c }), 0.25)
        }
        for format in [ImageFormat.gif, .png, .tiff, .heics, .pdf] {
            let data = try ImageCodecs.encodeFrames(frames, as: format)
            let info = try ImageCodecs.frames(data)
            measure("\(format) multi-frame write: \(info.count) frames, delays \(info.map { $0.delay.map { "\($0)" } ?? "–" })")
            #expect(info.count == 3, "\(format)")
            if [ImageFormat.gif, .png, .heics].contains(format) { #expect(info.allSatisfy { abs(($0.delay ?? 0) - 0.25) < 0.011 }, "\(format) delays") }
            let all = try ImageCodecs.decodeAllFrames(data)
            #expect(all.count == 3)
            if format != .pdf && format != .heics {
                for (i, d) in all.enumerated() { #expect(abs(d.raster.floats()[i] - 1) < 0.02, "\(format) frame \(i) colour") }
            }
            #expect(all[0].warnings.contains { if case .moreFrames = $0 { true } else if case .morePages = $0 { true } else { false } })
        }
    }

    @Test func limitsRefuseOversizedImages() throws {
        let data = try ImageCodecs.encode(Fixtures.raster(.rgba8, width: 64, height: 64), as: .png)
        var o = DecodeOptions(); o.limits.maxWidth = 32
        #expect(throws: PlatformError.self) { try ImageCodecs.decode(data, options: o) }
        var p = DecodeOptions(); p.limits.maxPixels = 1000
        #expect(throws: PlatformError.self) { try ImageCodecs.decode(data, options: p) }
        #expect(throws: PlatformError.self) { try ImageCodecs.encode(Fixtures.raster(.rgba8, width: 300, height: 300), as: .ico) }
    }

    @Test func malformedInputThrowsWithoutCrashing() throws {
        #expect(throws: PlatformError.self) { try ImageCodecs.decode(Data()) }
        #expect(throws: PlatformError.self) { try ImageCodecs.decode(Data("hello world, not an image".utf8)) }
        for format in [ImageFormat.png, .jpeg, .tiff, .qoi, .fits, .openEXR, .gif] {
            let good = try ImageCodecs.encode(Fixtures.raster(format == .fits ? .gray8 : .rgba8, width: 20, height: 20), as: format)
            for cut in [8, good.count / 2, good.count - 3] { _ = try? ImageCodecs.decode(good.prefix(cut)) }
            var b = [UInt8](good)
            for i in stride(from: 16, to: b.count, by: 13) { b[i] ^= 0xA5 }
            _ = try? ImageCodecs.decode(Data(b))
        }
        // PCX: a hand-made 2×1 8-bit three-plane file decodes; a bad one is refused.
        var pcx = [UInt8](repeating: 0, count: 128)
        pcx[0] = 0x0A; pcx[1] = 5; pcx[2] = 1; pcx[3] = 8; pcx[8] = 1; pcx[65] = 3; pcx[66] = 2
        pcx += [0xC1, 255, 0, 0, 0xC1, 255, 0, 0]   // R plane, G plane, B plane (≥ 0xC0 needs an RLE packet)
        let d = try ImageCodecs.decode(Data(pcx))
        #expect(d.format == .pcx && d.raster.width == 2 && d.raster.bytes == [255, 0, 0, 0, 255, 0])
        #expect(throws: PlatformError.self) { try ImageCodecs.decode(Data(pcx.prefix(130)), as: .pcx) }
        // Binary PBM (P4), which ImageIO refuses.
        let p4 = try ImageCodecs.decode(Data("P4\n# c\n8 2\n".utf8) + Data([0b1010_1010, 0b0101_0101]))
        #expect(p4.raster.bytes == [0, 255, 0, 255, 0, 255, 0, 255, 255, 0, 255, 0, 255, 0, 255, 0])
    }

    @Test func fidelityWarningsMatchThePlan() {
        let w1 = ImageCodecs.fidelityWarnings(for: .rgba16, as: .jpeg)
        #expect(w1.contains(.alphaDiscarded) && w1.contains(.depthReduced(from: .u16, to: .u8)) && w1.contains(.lossyCompression))
        let w2 = ImageCodecs.fidelityWarnings(for: .rgba32f, as: .png)
        #expect(w2.contains(.depthReduced(from: .f32, to: .u16)) && w2.contains(.rangeClipped))
        #expect(ImageCodecs.fidelityWarnings(for: .cmyka8, as: .png).contains(.modelConverted(from: .cmyk, to: .rgb)))
        #expect(ImageCodecs.fidelityWarnings(for: .rgba8, as: .webp).isEmpty, "lossless WebP keeps 8-bit RGBA")
        #expect(ImageCodecs.fidelityWarnings(for: .rgba8, as: .gif).contains(.alphaBinarized))
        #expect(ImageCodecs.fidelityWarnings(for: .rgba8, as: .fits).contains(.alphaDiscarded))
        #expect(ImageCodecs.fidelityWarnings(for: .rgba32f, as: .openEXR).isEmpty)
        #expect(ImageCodecs.fidelityWarnings(for: .rgba8, width: 20000, height: 10, as: .webp).contains(.dimensionsExceeded(maxWidth: 16383, maxHeight: 16383)))
        #expect(ImageCodecs.fidelityWarnings(for: .rgba8, as: .jpegXL).contains(.writeUnsupported(.jpegXL)))
        #expect(ImageCodecs.fidelityWarnings(for: .rgba8, as: .png, hasProfile: true).isEmpty)
        var o = EncodeOptions(); o.embedICC = false
        #expect(ImageCodecs.fidelityWarnings(for: .rgba8, as: .png, options: o, hasProfile: true).contains(.iccDropped))
    }

    @Test func imageBridgeProbeAndDisplayDecode() throws {
        let src = Fixtures.raster(.rgba16, width: 40, height: 30)
        let url = Fixtures.url("bridge-probe-rgba16.png")
        try ImageCodecs.encode(src, as: .png).write(to: url)
        let meta = try ImageCodecs.probe(url: url)
        measure("media-bridge probe of a 16-bit RGBA PNG: format \(meta.format) \(meta.width)×\(meta.height) bitDepth \(meta.bitDepth) alpha \(meta.alpha) frames \(meta.frameCount)")
        #expect(meta.width == 40 && meta.height == 30 && meta.bitDepth == 16)
        let frames = try ImageCodecs.decodeDisplay8(url: url)
        #expect(frames.count == 1 && frames[0].format == .rgba8)
        let mean = Fixtures.meanDiff(src.converted(to: .u8), frames[0])
        measure("media-bridge 8-bit display decode vs native 16-bit decode: mean |Δ| \(mean * 255)/255 (alpha premultiply round trip)")
        #expect(mean < 3.0 / 255)
    }

    @Test func qualityTargetedExport() throws {
        let src = Fixtures.smooth(width: 128, height: 96)
        for format in [ImageFormat.jpeg, .webp, .heif] {
            let r = try ImageCodecs.encodeToQualityTarget(src, as: format, targetScore: 70)
            measure("SSIMULACRA2-targeted \(format) (target 70): quality \(r.quality), score \(r.score), \(r.data.count) B, met \(r.metTarget)")
            #expect(r.metTarget && r.score >= 70)
        }
    }
}

extension PixelFormat {
    static let rgb8Opaque = PixelFormat(mode: .rgb, sample: .u8, alpha: false)
}

@Suite("Codec options reach the files")
struct CodecOptionTests {
    @Test func tiffCompressionPNGInterlaceAndJPEGProgressive() throws {
        let src = Fixtures.raster(.rgba8, width: 64, height: 64)
        var sizes: [String] = []
        for c in [TIFFCompression.none, .lzw, .packBits, .deflate] {
            var o = EncodeOptions(); o.tiffCompression = c
            let d = try ImageCodecs.encode(src, as: .tiff, options: o)
            let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(d as CFData, nil)!, 0, nil) as! [String: Any]
            let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            let written = tiff?[kCGImagePropertyTIFFCompression as String] as? Int
            sizes.append("\(c)=tag \(written.map(String.init) ?? "?") \(d.count) B")
            #expect(written == c.rawValue, "\(c)")
            #expect(Fixtures.maxDiff(src, try ImageCodecs.decode(d).raster) == 0)
        }
        measure("TIFF compression honoured: \(sizes.joined(separator: ", "))")
        var o = EncodeOptions(); o.pngInterlaced = true
        let png = try ImageCodecs.encode(src, as: .png, options: o)
        let pp = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil) as! [String: Any]
        #expect((pp[kCGImagePropertyPNGDictionary as String] as? [String: Any])?[kCGImagePropertyPNGInterlaceType as String] as? Int == 1)
        var j = EncodeOptions(); j.jpegProgressive = true
        let jpg = try ImageCodecs.encode(Fixtures.raster(.rgb8Opaque, width: 64, height: 64), as: .jpeg, options: j)
        let jp = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(jpg as CFData, nil)!, 0, nil) as! [String: Any]
        let prog = (jp[kCGImagePropertyJFIFDictionary as String] as? [String: Any])?[kCGImagePropertyJFIFIsProgressive as String] as? Bool
        measure("JPEG progressive flag read back: \(prog.map { "\($0)" } ?? "absent")")
        #expect(prog == true)
    }
}
