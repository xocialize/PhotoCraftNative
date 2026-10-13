// Port of photocraft-io (crates/io/tests/flat.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Flat formats through `DocumentIO` and the injected codec (`ImageIOCodec`): PNG, JPEG and TIFF
// export and import, GIF import, and the export warnings. photocraft's TGA, FITS, BMP, QOI,
// OpenEXR and Radiance HDR codecs are PCPlatform's codec layer and are not exercised here.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import Testing
import UniformTypeIdentifiers
@testable import PCIO

@Suite struct FlatTests {
    init() { ExportSweep.install() }
    typealias Kit = FlatKit

    struct CodecCase: Sendable, CustomTestStringConvertible {
        var name: String, ext: String, mode: ColorMode, depth: SampleType, alpha: Bool, tol: Float
        var testDescription: String { name }
    }

    /// photocraft's `codec_rt!` cases that go through PNG and TIFF (TGA and FITS: codec layer).
    static let codecCases: [CodecCase] = [
        CodecCase(name: "png_rgba8", ext: "png", mode: .rgb, depth: .u8, alpha: true, tol: 0),
        CodecCase(name: "png_rgb8_opaque", ext: "png", mode: .rgb, depth: .u8, alpha: false, tol: 0),
        CodecCase(name: "png_rgba16", ext: "png", mode: .rgb, depth: .u16, alpha: true, tol: 0),
        CodecCase(name: "png_gray8", ext: "png", mode: .grayscale, depth: .u8, alpha: false, tol: 0),
        CodecCase(name: "png_graya16", ext: "png", mode: .grayscale, depth: .u16, alpha: true, tol: 0),
        CodecCase(name: "tiff_rgba8", ext: "tiff", mode: .rgb, depth: .u8, alpha: true, tol: 0),
        CodecCase(name: "tiff_rgb16", ext: "tif", mode: .rgb, depth: .u16, alpha: false, tol: 0),
        CodecCase(name: "tiff_cmyk8", ext: "tiff", mode: .cmyk, depth: .u8, alpha: false, tol: 0),
        CodecCase(name: "tiff_cmyka16", ext: "tiff", mode: .cmyk, depth: .u16, alpha: true, tol: 0),
        CodecCase(name: "tiff_gray8", ext: "tiff", mode: .grayscale, depth: .u8, alpha: false, tol: 0),
    ]

    @Test(arguments: codecCases) func codecRoundTrip(_ c: CodecCase) throws {
        let d = Kit.single(c.mode, c.depth, c.alpha)
        let r = try Kit.export(d, c.ext)
        let back = try Kit.importFile("x.\(c.ext)", r.bytes).document
        #expect(back.size == d.size)
        #expect(back.mode == d.mode, "mode")
        #expect(back.depth == d.depth, "depth")
        let m = Kit.pixelDiff(d, back)
        #expect(m != nil && m! <= c.tol, "max diff \(String(describing: m))")
    }

    static func jpegRoundTrip(_ mode: ColorMode, _ ext: String) throws {
        let d = Kit.smooth(mode)
        let r = try Kit.export(d, ext)
        #expect(r.warnings.contains { $0.lowercased().contains("lossy") }, "\(r.warnings)")
        let back = try Kit.importFile("x.jpg", r.bytes).document
        #expect(back.mode == mode)
        let a = try #require(d.layers.first?.surface).readRegion(d.bounds)
        let b = try #require(back.layers.first?.surface).readRegion(d.bounds)
        #expect(a.count == b.count)
        let mean = zip(a, b).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / Float(max(a.count, 1))
        #expect(mean < 0.02, "mean error \(mean)")
    }

    @Test func jpegRGB8() throws { try Self.jpegRoundTrip(.rgb, "jpg") }

    @Test func jpegGray8() throws { try Self.jpegRoundTrip(.grayscale, "jpeg") }

    /// Arbitrary bytes are fine for PNG iCCP (photocraft's codec does not validate).
    static func sampleICC() -> [UInt8] {
        var v = [UInt8](repeating: 0, count: 128)
        v.replaceSubrange(36 ..< 40, with: Array("acsp".utf8))
        return v
    }

    @Test func metadataRoundtripPNG() throws {
        var d = Kit.single(.rgb, .u8, false)
        d.resolutionDpi = 300
        d.iccProfile = Self.sampleICC()
        d.metadata.xmp = "<x:xmpmeta xmlns:x='adobe:ns:meta/'/>"
        // DPI and ICC always travel with the file; XMP unless Export As asks for none (#647). The
        // `XmpEmbed::None` half has no PCIO counterpart (IOOptions has no metadata option).
        let r = try Kit.export(d, "png")
        let back = try Kit.importFile("x.png", r.bytes).document
        #expect(abs(back.resolutionDpi - 300) < 1, "dpi \(back.resolutionDpi)")
        #expect(back.iccProfile == d.iccProfile, "icc")
        #expect(back.metadata.xmp == d.metadata.xmp, "xmp \(String(describing: back.metadata.xmp))")
    }

    @Test func layeredToPNGWarnsFlatten() throws {
        let d = genDoc(.rgb, .u8, .pixels)
        let r = try Kit.export(d, "out.png")
        #expect(r.warnings.contains { $0.contains("flattened") }, "\(r.warnings)")
        let back = try Kit.importFile("out.png", r.bytes).document
        // The composite equals our flatten.
        let flat = try Kit.flatten(d)
        let v = try #require(back.layers.first?.surface).readRegion(back.bounds)
        let px = stride(from: 0, to: v.count, by: 4).map { SIMD4(v[$0], v[$0 + 1], v[$0 + 2], v[$0 + 3]) }
        #expect(Kit.maxDiff(px, flat) <= 1 / 255 + 1e-4, "\(Kit.maxDiff(px, flat))")
    }

    @Test func sixteenBitToJPEGWarnsDepth() throws {
        let r = try Kit.export(Kit.single(.rgb, .u16, false), "a.jpg")
        #expect(r.warnings.contains { $0.lowercased().contains("bit") }, "\(r.warnings)")
    }

    @Test func alphaToJPEGWarns() throws {
        let r = try Kit.export(Kit.single(.rgb, .u8, true), "a.jpg")
        #expect(r.warnings.count >= 2, "\(r.warnings)")
    }

    @Test func cmykLayeredToPNGWarnsConversion() throws {
        let r = try Kit.export(genDoc(.cmyk, .u8, .pixels), "a.png")
        #expect(r.warnings.contains { $0.contains("RGB") }, "\(r.warnings)")
    }

    @Test func effectsAreWrittenToPSDAndReadBack() throws {
        var d = genDoc(.rgb, .u8, .pixels)
        d.layers[1].effects.items.append(.colorOverlay(Effect.ColorOverlay(common: FxCommon(.normal, 1), color: .black)))
        d.layers[1].effects.items.append(Effect.defaultDropShadow())
        let r = try Kit.export(d, "a.psd")
        #expect(!r.warnings.contains { $0.contains("effects") }, "\(r.warnings)")
        let back = try Kit.importFile("a.psd", r.bytes).document
        #expect(back.layers[1].effects.items.count == 2)
        #expect(back.layers[1].effects.psdRaw != nil)
    }

    @Test func unknownExtensionErrors() {
        let e = Kit.error { try DocumentIO.export(Kit.single(.rgb, .u8, false), as: "a.xyz", options: Kit.options()) }
        guard case .unknownFormat? = e as? PCIOError else {
            Issue.record("expected unknownFormat, got \(String(describing: e))")
            return
        }
    }

    @Test func garbageImportErrors() {
        #expect(throws: (any Error).self) { try Kit.importFile("x", Array("definitely not an image".utf8)) }
        let e = Kit.error { try Kit.importFile("x.psd", Array("8BPS".utf8) + [0, 1]) }
        guard case .psd? = e as? PCIOError else {
            Issue.record("expected a PSD error, got \(String(describing: e))")
            return
        }
    }

    @Test func extensionForms() throws {
        let d = Kit.single(.rgb, .u8, false)
        for e in ["png", ".png", "a/b/c.PNG", "C:\\x\\y.png"] {
            let r = try Kit.export(d, e)
            #expect(r.bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]), "\(e)")
        }
    }

    /// How a flat file opened: the locked Background when opaque, a normal "Layer 0" (as in
    /// Photoshop) when it has transparency (flat.rs `assert_opens_as`).
    static func expectOpensAs(_ what: String, _ d: Document, transparent: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        guard d.layers.count == 1, let l = d.layers.first else {
            Issue.record("\(what): \(d.layers.count) layers", sourceLocation: sourceLocation)
            return
        }
        if transparent {
            #expect(l.name == "Layer 0", "\(what)", sourceLocation: sourceLocation)
            #expect(!l.locks.transparency && !l.locks.position, "\(what): unlocked", sourceLocation: sourceLocation)
        } else {
            #expect(l.name == "Background", "\(what)", sourceLocation: sourceLocation)
            #expect(l.locks.transparency && l.locks.position, "\(what): locked", sourceLocation: sourceLocation)
        }
    }

    @Test func backgroundLockFollowsAlpha() throws {
        let opaque = try Kit.export(Kit.single(.rgb, .u8, false), "png")
        Self.expectOpensAs("opaque PNG", try Kit.importFile("a.png", opaque.bytes).document, transparent: false)
        let rgba = try Kit.export(Kit.single(.rgb, .u8, true), "png")
        Self.expectOpensAs("RGBA PNG", try Kit.importFile("a.png", rgba.bytes).document, transparent: true)
    }

    @Test func transparentFlatImagesOpenAsLayer0() throws {
        let (w, h) = (6, 4)
        let n = w * h
        func enc(_ model: Kit.Model, alpha: Bool, bpc: Int, _ type: UTType) throws -> [UInt8] {
            let ch = (model == .gray ? 1 : 3) + (alpha ? 1 : 0)
            let vals: [UInt16] = (0 ..< n * ch).map { i in (i + 1) % ch == 0 && i < ch * 5 ? 0 : (bpc == 8 ? 200 : 50000) }
            let bytes = bpc == 8 ? vals.map { UInt8($0) } : Kit.be16(vals)
            return try #require(Kit.imageIO(bytes, width: w, height: h, bpc: bpc, model: model, alpha: alpha, type: type))
        }
        let indices = Array([[UInt8]](repeating: [0, 1], count: n / 2).joined())
        let cases: [(String, [UInt8], Bool)] = [
            ("a.png", try enc(.rgb, alpha: true, bpc: 8, .png), true),
            ("a16.png", try enc(.rgb, alpha: true, bpc: 16, .png), true),
            ("ga.png", try enc(.gray, alpha: true, bpc: 8, .png), true),
            ("a.tif", try enc(.rgb, alpha: true, bpc: 8, .tiff), true),
            ("ga.tif", try enc(.gray, alpha: true, bpc: 16, .tiff), true),
            ("pal.png", try Kit.indexedPNG(w, h, indices, [[255, 0, 0], [0, 0, 255]], transparent: 0), true),
            ("pal_opaque.png", try Kit.indexedPNG(w, h, indices, [[255, 0, 0], [0, 0, 255]], transparent: nil), false),
            ("rgb.png", try enc(.rgb, alpha: false, bpc: 8, .png), false),
            ("g.png", try enc(.gray, alpha: false, bpc: 16, .png), false),
            ("rgb.tif", try enc(.rgb, alpha: false, bpc: 8, .tiff), false),
            ("rgb.jpg", try enc(.rgb, alpha: false, bpc: 8, .jpeg), false),
        ]
        for (name, bytes, transparent) in cases {
            let d = try Kit.importFile(name, bytes).document
            Self.expectOpensAs(name, d, transparent: transparent)
            // Photoshop numbers the next new layer after "Layer 0" as "Layer 1".
            #expect(d.nextLayerName("Layer") == "Layer 1", "\(name)")
        }
    }

    @Test func layer0SavesBackToPNGAndReopensAsLayer0() throws {
        let r = try Kit.export(Kit.single(.rgb, .u8, true), "png")
        let d = try Kit.importFile("a.png", r.bytes).document
        Self.expectOpensAs("first open", d, transparent: true)
        let again = try Kit.export(d, "b.png")
        #expect(again.warnings.allSatisfy { !$0.contains("flattened") }, "a lone Layer 0 is written natively: \(again.warnings)")
        let back = try Kit.importFile("b.png", again.bytes).document
        Self.expectOpensAs("reopened", back, transparent: true)
        #expect(Kit.pixelDiff(d, back) == 0)
    }

    @Test func psdToPNGToPSDChain() throws {
        let d = genDoc(.rgb, .u16, .all)
        let psd = try Kit.export(d, "a.psd")
        let d2 = try Kit.importFile("a.psd", psd.bytes).document
        let png = try Kit.export(d2, "a.png")
        let d3 = try Kit.importFile("a.png", png.bytes).document
        #expect(d3.depth == .u16)
        let psd2 = try Kit.export(d3, "b.psd")
        #expect((try? PSDFile(bytes: psd2.bytes)) != nil)
    }

    /// Formats without alpha get the document composited over white, as flattening does, instead
    /// of its alpha dropped (which shows the colours stored under transparent pixels).
    @Test func transparencyIsCompositedOverWhiteForFormatsWithoutAlpha() throws {
        let rgb: [[Float]] = [[0, 0, 0, 0], [0, 0, 1, 0.5], [0, 0.63, 0, 1]]
        let overWhite: [[Float]] = [[1, 1, 1], [0.5, 0.5, 1], [0, 0.63, 0]]
        let gray: [[Float]] = [[0, 0], [0, 0.5]]
        // CMYK white is no ink.
        let cmyk: [[Float]] = [[1, 1, 1, 1, 0], [0, 0, 0, 1, 0.5]]
        let cases: [(ColorMode, SampleType, [[Float]], [[Float]])] = [
            (.rgb, .u8, rgb, overWhite), (.rgb, .u16, rgb, overWhite), (.rgb, .f32, rgb, overWhite),
            (.grayscale, .u8, gray, [[1], [0.5]]),
            (.cmyk, .u8, cmyk, [[0, 0, 0, 0], [0, 0, 0, 0.5]]),
        ]
        for (mode, depth, cols, want) in cases {
            let what = "\(mode) \(depth)"
            let d = Kit.columns(mode, depth, cols)
            let r = try Kit.export(d, "a.jpg")
            let back = try Kit.importFile("a.jpg", r.bytes).document
            #expect(r.warnings.contains { $0.contains("composited over white") }, "\(what): \(r.warnings)")
            #expect(Kit.colorsMatch(Kit.columnPixels(back, cols.count), want, 0.03), "\(what): got \(Kit.columnPixels(back, cols.count)), want \(want)")
            #expect(!r.warnings.contains { $0.contains("alpha will be discarded") }, "\(what): \(r.warnings)")
            #expect(back.mode == mode, "\(what)")
            // PNG keeps the transparency itself.
            let p = try Kit.export(d, "a.png")
            #expect(!p.warnings.contains { $0.contains("composited") }, "\(what): \(p.warnings)")
            let pb = try Kit.importFile("a.png", p.bytes).document
            let alpha = Kit.columnPixels(pb, cols.count)[1].last ?? -1
            #expect(abs(alpha - 0.5) <= 1 / 255, "\(what): alpha \(alpha)")
        }
        // Opaque documents are written as before.
        let r = try Kit.export(Kit.columns(.rgb, .u8, [[0.2, 0.4, 0.6, 1]]), "a.jpg")
        #expect(!r.warnings.contains { $0.contains("composited") }, "\(r.warnings)")
    }

    /// The PNG half of photocraft's `non_srgb_rgb_is_converted_to_srgb_for_formats_without_a_profile`:
    /// formats that embed the profile keep it and the values. (The BMP, GIF, QOI and TGA halves,
    /// converted to sRGB because those formats can't embed a profile, are PCPlatform's codec layer.)
    @Test func nonSRGBRGBKeepsItsProfileAndValuesInPNG() throws {
        let cols: [[Float]] = [[0, 0.05, 0, 1], [0.2, 0.5, 0.8, 1], [1, 0.25, 0, 1]]
        let linear = [UInt8](try #require(CGColorSpace(name: CGColorSpace.linearSRGB)?.copyICCData()) as Data)
        let p3 = [UInt8](try #require(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData()) as Data)
        for (name, profile, depth) in [("linear sRGB", linear, SampleType.f32), ("linear sRGB", linear, .u16), ("Display P3", p3, .u8)] {
            var d = Kit.columns(.rgb, depth, cols)
            d.iccProfile = profile
            let stored = Kit.columnPixels(d, cols.count)
            let r = try Kit.export(d, "a.png")
            let back = try Kit.importFile("a.png", r.bytes).document
            #expect(back.iccProfile == d.iccProfile, "\(name) \(depth)")
            #expect(Kit.colorsMatch(Kit.columnPixels(back, cols.count), stored, 1e-4), "\(name) \(depth) png: \(Kit.columnPixels(back, cols.count))")
        }
    }

    /// #518: a JPEG cut off inside its image data opens with a warning, never silently.
    @Test func truncatedJPEGImportsWithAWarning() throws {
        for mode in [ColorMode.rgb, .grayscale] {
            let full = try Kit.export(Kit.smooth(mode), "jpg").bytes
            #expect(try Kit.importFile("x.jpg", full).warnings == [], "\(mode)")
            // Cut inside the scan data (most of this small file is headers).
            let r = try Kit.importFile("x.jpg", Array(full.dropLast(4)))
            #expect(r.document.size == PixelSize(width: 32, height: 16))
            #expect(r.warnings.first?.hasPrefix("JPEG data ends early") == true, "\(mode): \(r.warnings)")
        }
    }

    /// A GIF of `frames` identical 1×1 black frames.
    static func gifFrames(_ frames: Int) -> [UInt8] {
        var b = Array("GIF89a".utf8) + [0x01, 0, 0x01, 0, 0x80, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF]
        for _ in 0 ..< frames { b += [0x2C, 0, 0, 0, 0, 0x01, 0, 0x01, 0, 0, 0x02, 0x02, 0x44, 0x01, 0] }
        b.append(0x3B)
        return b
    }

    /// #523: an animation opens its first frame, unchanged, with a warning that the rest was left out.
    @Test func animationImportsTheFirstFrameWithAWarning() throws {
        let one = try Kit.importFile("a.gif", Self.gifFrames(1))
        #expect(one.warnings == [])
        let three = try Kit.importFile("a.gif", Self.gifFrames(3))
        #expect(three.warnings == ["only the first of 3 frames was imported"])
        #expect(Kit.pixelDiff(one.document, three.document) == 0)
    }
}
