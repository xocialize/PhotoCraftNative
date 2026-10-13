// Port of photocraft-io (crates/io/tests/psd_thumbnail.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Preferences › File Handling › Image Previews: PSD/PSB saves embed Photoshop's thumbnail resource
// (1036: 28-byte header + JFIF, ≤ 160 px) unless the previews are turned off. The JFIF stream is
// decoded with ImageIO (photocraft: photocraft-codecs).

import CoreGraphics
import Foundation
import ImageIO
import PCDocument
import PCFoundation
import PCPSD
import Testing
@testable import PCIO

@Suite struct PSDThumbnailTests {
    init() { ExportSweep.install() }
    /// A `w`×`h` document of `mode`/`depth` holding one layer of `rgba` (straight sRGB-ish RGBA
    /// converted to the document's model), covering the left `cover` fraction.
    static func doc(_ mode: ColorMode, _ depth: SampleType, _ w: Int, _ h: Int, _ rgba: SIMD4<Float>, _ cover: Float) -> Document {
        var d = Document(name: "thumb", size: PixelSize(width: w, height: h), mode: mode, depth: depth)
        let fmt = d.pixelFormat
        let px = fmt.components(fromRGBA: rgba)
        var layer = Layer.raster("pixels", format: fmt)
        let right = max(Int32((Float(w) * cover).rounded()), 1)
        layer.withRaster { $0.fill(rect(0, 0, right, Int32(h)), with: px) }
        d.layers.append(layer)
        return d
    }

    struct Thumbnail {
        var width: Int
        var height: Int
        var px: [SIMD3<Float>]
    }

    /// The 1036 resource of a saved file, its header checked.
    static func thumbnail(_ bytes: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) throws -> Thumbnail? {
        let file = try PSDFile(bytes: bytes)
        #expect(!file.resources.contains { $0.id == PSDResourceID.thumbnailPS4 }, "only the RGB (1036) thumbnail is written", sourceLocation: sourceLocation)
        let found = file.resources.filter { $0.id == PSDResourceID.thumbnail }
        guard let r = found.first else { return nil }
        #expect(found.count == 1, "one thumbnail resource", sourceLocation: sourceLocation)
        let d = [UInt8](r.data)
        guard d.count >= 28 else {
            Issue.record("thumbnail resource of \(d.count) bytes", sourceLocation: sourceLocation)
            return nil
        }
        func u(_ i: Int) -> Int { Int(PSDKit.be32(d, i)) }
        let (format, w, h, widthBytes, total, compressed) = (u(0), u(4), u(8), u(12), u(16), u(20))
        #expect(format == 1, "kJpegRGB", sourceLocation: sourceLocation)
        #expect(w >= 1 && h >= 1 && max(w, h) <= 160, "\(w)x\(h)", sourceLocation: sourceLocation)
        #expect(widthBytes == (w * 24 + 31) / 32 * 4, sourceLocation: sourceLocation)
        #expect(total == widthBytes * h, sourceLocation: sourceLocation)
        #expect(compressed == d.count - 28, sourceLocation: sourceLocation)
        #expect(Array(d[24 ..< 28]) == [0, 24, 0, 1], "24 bits per pixel, 1 plane", sourceLocation: sourceLocation)
        let jfif = Array(d[28...])
        #expect(jfif.starts(with: [0xFF, 0xD8, 0xFF, 0xE0]) && jfif.count > 11 && Array(jfif[6 ..< 11]) == Array("JFIF\0".utf8), "a JFIF stream",
                sourceLocation: sourceLocation)
        guard let src = CGImageSourceCreateWithData(Data(jfif) as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let rgba = imageIORGBA8(jfif) else {
            Issue.record("the JFIF stream does not decode", sourceLocation: sourceLocation)
            return nil
        }
        #expect(img.width == w && img.height == h, sourceLocation: sourceLocation)
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        #expect(props?[kCGImagePropertyColorModel] as? String == "RGB" && (props?[kCGImagePropertyHasAlpha] as? Bool ?? false) == false, "RGB JPEG",
                sourceLocation: sourceLocation)
        let px = (0 ..< rgba.width * rgba.height).map { i in SIMD3(Float(rgba.data[i * 4]), Float(rgba.data[i * 4 + 1]), Float(rgba.data[i * 4 + 2])) / 255 }
        return Thumbnail(width: w, height: h, px: px)
    }

    static func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float) -> Bool { (0 ..< 3).allSatisfy { abs(a[$0] - b[$0]) <= tol } }

    static func noPreviews() -> IOOptions {
        var o = IOOptions()
        o.imagePreviews = false
        return o
    }

    @Test func alwaysEmbedsA160pxJFIFThumbnail() throws {
        let d = PSDThumbnailTests.doc(.rgb, .u8, 640, 320, SIMD4(1, 0, 0, 1), 1)
        let out = try PSDKit.export(d, "x.psd")
        let t = try #require(try PSDThumbnailTests.thumbnail(out.bytes), "Always Save writes the thumbnail")
        #expect(t.width == 160 && t.height == 80)
        let mid = t.px[40 * 160 + 80]
        #expect(PSDThumbnailTests.near(mid, SIMD3(1, 0, 0), 0.08), "\(mid)")
        #expect(out.warnings.allSatisfy { !$0.contains("preview") }, "\(out.warnings)")
    }

    @Test func smallDocumentsKeepTheirSize() throws {
        let d = PSDThumbnailTests.doc(.rgb, .u8, 37, 5, SIMD4(0, 0, 1, 1), 1)
        let t = try #require(try PSDThumbnailTests.thumbnail(try PSDKit.export(d, "x.psd").bytes))
        #expect(t.width == 37 && t.height == 5)
    }

    @Test func neverWritesNoThumbnail() throws {
        let d = PSDThumbnailTests.doc(.rgb, .u8, 64, 64, SIMD4(0, 1, 0, 1), 1)
        for name in ["x.psd", "x.psb"] {
            let out = try PSDKit.export(d, name, PSDThumbnailTests.noPreviews())
            #expect(try PSDThumbnailTests.thumbnail(out.bytes) == nil, "\(name)")
        }
    }

    @Test func psbGetsTheThumbnailToo() throws {
        let d = PSDThumbnailTests.doc(.rgb, .u8, 300, 600, SIMD4(0, 1, 0, 1), 1)
        let out = try PSDKit.export(d, "x.psb")
        #expect(out.bytes[5] == 2)
        let t = try #require(try PSDThumbnailTests.thumbnail(out.bytes))
        #expect(t.width == 80 && t.height == 160)
    }

    @Test func transparencyIsShownOverWhite() throws {
        let d = PSDThumbnailTests.doc(.rgb, .u8, 160, 160, SIMD4(0, 0, 0, 1), 0.5)
        let t = try #require(try PSDThumbnailTests.thumbnail(try PSDKit.export(d, "x.psd").bytes))
        let row = 80 * t.width
        #expect(PSDThumbnailTests.near(t.px[row + 20], SIMD3(repeating: 0), 0.08), "\(t.px[row + 20])")
        #expect(PSDThumbnailTests.near(t.px[row + 140], SIMD3(repeating: 1), 0.08), "\(t.px[row + 140])")
    }

    @Test func everyDepthAndModeGetsAnRGBThumbnail() throws {
        for mode in [ColorMode.rgb, .grayscale, .cmyk, .lab] {
            for depth in [SampleType.u8, .u16, .f32] {
                if depth == .f32 && (mode == .cmyk || mode == .lab) { continue } // Photoshop has no 32-bit CMYK or Lab.
                let d = PSDThumbnailTests.doc(mode, depth, 200, 100, SIMD4(1, 1, 1, 1), 1)
                let out = try PSDKit.export(d, "x.psd")
                guard let t = try PSDThumbnailTests.thumbnail(out.bytes) else {
                    Issue.record("\(mode) \(depth): no thumbnail")
                    continue
                }
                #expect(t.width == 160 && t.height == 80, "\(mode) \(depth)")
                let mid = t.px[40 * 160 + 80]
                // White paper is white in every model (CMYK through its profile, with BPC).
                #expect(PSDThumbnailTests.near(mid, SIMD3(repeating: 1), 0.1), "\(mode) \(depth): \(mid)")
            }
        }
    }

    @Test func cmykAnd16BitColoursSurviveTheConversion() throws {
        for (mode, depth) in [(ColorMode.rgb, SampleType.u16), (.rgb, .f32), (.cmyk, .u8), (.lab, .u16)] {
            let d = PSDThumbnailTests.doc(mode, depth, 100, 100, SIMD4(1, 0, 0, 1), 1)
            let t = try #require(try PSDThumbnailTests.thumbnail(try PSDKit.export(d, "x.psd").bytes))
            let p = t.px[50 * 100 + 50]
            #expect(p.x > 0.7 && p.y < 0.35 && p.z < 0.35, "\(mode) \(depth): red reads as \(p)")
        }
    }

    @Test func savedFilesRoundTripAndResaveAFreshThumbnail() throws {
        let d = PSDThumbnailTests.doc(.rgb, .u8, 120, 60, SIMD4(1, 0, 0, 1), 1)
        let first = try PSDKit.export(d, "x.psd")
        let back = try PSDKit.importFile("x.psd", first.bytes).document
        #expect(back.size == PixelSize(width: 120, height: 60))
        // The thumbnail is regenerated, never kept as an opaque resource that would go stale.
        #expect(back.metadata.psdResources.allSatisfy { $0.id != PSDResourceID.thumbnail })
        let again = try PSDKit.export(back, "x.psd")
        #expect(try PSDThumbnailTests.thumbnail(again.bytes) != nil, "one fresh thumbnail")
        let off = try PSDKit.export(back, "x.psd", PSDThumbnailTests.noPreviews())
        #expect(try PSDThumbnailTests.thumbnail(off.bytes) == nil)
    }

    @Test func theDocumentProfileIsHonoured() throws {
        // Mid gray in a linear-sRGB document is sRGB ≈ 0.735, not 0.5: the thumbnail goes through
        // the embedded profile rather than assuming sRGB.
        var d = PSDThumbnailTests.doc(.rgb, .u16, 50, 50, SIMD4(0.5, 0.5, 0.5, 1), 1)
        let icc = try #require(CGColorSpace(name: CGColorSpace.linearSRGB)?.copyICCData() as Data?)
        d.iccProfile = [UInt8](icc)
        let t = try #require(try PSDThumbnailTests.thumbnail(try PSDKit.export(d, "x.psd").bytes))
        let mid = t.px[25 * 50 + 25]
        #expect(PSDThumbnailTests.near(mid, SIMD3(repeating: 0.735), 0.03), "\(mid)")
    }
}

extension PSDThumbnailTests.Thumbnail: Equatable {}
