// Port of photocraft-io (crates/io/tests/tiff_layers.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Layered TIFF (Photoshop layer data in tags 37724 / 34377) through `DocumentIO`: Document → TIFF →
// Document round trips in every mode and depth, equivalence with the PSD path, the flat fall-backs
// and malformed input. The container and transcoder halves are PCIOFormats' TIFFSVG tests.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCIOFormats
import PCPSD
import Testing
@testable import PCIO

@Suite struct TIFFLayersTests {
    init() { ExportSweep.install() }
    typealias Kit = FlatKit

    static func tiff(_ doc: Document, layers: Bool, forcePSB: Bool = false) throws -> ExportResult {
        try Kit.export(doc, "x.tif", options: Kit.options(tiffLayers: layers, forcePSB: forcePSB))
    }

    /// photocraft `roundtrip`: a layered TIFF export, checked, and opened again.
    static func roundtrip(_ doc: Document, sourceLocation: SourceLocation = #_sourceLocation) throws -> Document {
        let r = try tiff(doc, layers: true)
        let (resources, layers) = Kit.tags(r.bytes)
        let data = try #require(layers, "layer data", sourceLocation: sourceLocation)
        #expect(resources.map { !$0.isEmpty } == true, "image resources", sourceLocation: sourceLocation)
        // The layer data matches the container's byte order and is byte-stable through the transcoder.
        let order: PSDTIFF.ByteOrder = LayeredTIFF.writesLittleEndian ? .little : .big
        let (isd, w) = try PSDTIFF.ImageSourceData.fromBytes(data)
        #expect(w.isEmpty, "\(w)", sourceLocation: sourceLocation)
        #expect(isd.byteOrder == order, sourceLocation: sourceLocation)
        #expect(try isd.toBytes(order).bytes == data, sourceLocation: sourceLocation)
        // The TIFF is a plain image to any other reader: the composite at the document's size.
        let flat = try ImageIOCodec().decode(r.bytes)
        #expect(flat.width == doc.size.width && flat.height == doc.size.height, sourceLocation: sourceLocation)
        // A TIFF holds one transparency channel: extra alpha channels (and a Quick Mask) are not
        // kept, and the export says so.
        let extra = doc.channels.count + (doc.quickMask == nil ? 0 : 1)
        #expect(r.warnings.contains { $0.contains("alpha channel(s) are not written") } == (extra > 0), "\(r.warnings)", sourceLocation: sourceLocation)
        return try Kit.importFile("x.tif", r.bytes).document
    }

    /// `doc` as a layered TIFF round trip returns it: without extra alpha channels or a Quick Mask.
    static func expected(_ doc: Document) -> Document {
        var d = doc
        d.channels.removeAll()
        d.quickMask = nil
        return d
    }

    /// photocraft `assert_docs_eq`, with the known PCIO differences reported as known issues.
    static func expectSame(_ a: Document, _ b: Document, _ ctx: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        let problems = DocDiff.of(a, b)
        let icc = problems.filter { $0 == "icc" }
        let resources = problems.filter { $0.hasPrefix("resources ") }
        let exif = problems.filter { $0 == "exif" }
        let rest = problems.filter { $0 != "icc" && $0 != "exif" && !$0.hasPrefix("resources ") }
        #expect(rest.isEmpty, "\(ctx): \(rest.prefix(8))", sourceLocation: sourceLocation)
        withKnownIssue("PCIO bug: TIFFLayers.importIfLayered takes the profile from ImageIOCodec.decode (ImageIO's assumed or re-serialised colour space) instead of the TIFF's own ICC tag 34675", isIntermittent: true) {
            #expect(icc.isEmpty, "\(ctx)", sourceLocation: sourceLocation)
        }
        withKnownIssue("PCIO bug: TIFFLayers.exportLayered keeps the alpha-channel resources (1006/1045/1077) of the channels it drops; they reopen as unknown resources", isIntermittent: true) {
            #expect(resources.isEmpty, "\(ctx): \(resources)", sourceLocation: sourceLocation)
        }
        withKnownIssue("PCIO bug: ImageIOCodec's PNG writer adds an EXIF block to a document that has none", isIntermittent: true) {
            #expect(exif.isEmpty, "\(ctx)", sourceLocation: sourceLocation)
        }
    }

    static let rtCases: [(String, ColorMode, SampleType, Bool)] = [
        ("rt_rgb8_all", .rgb, .u8, true), ("rt_rgb16_all", .rgb, .u16, true), ("rt_rgb32_all", .rgb, .f32, true),
        ("rt_gray8_all", .grayscale, .u8, true), ("rt_gray16_all", .grayscale, .u16, true), ("rt_gray32_all", .grayscale, .f32, true),
        ("rt_cmyk8_all", .cmyk, .u8, true), ("rt_cmyk16_all", .cmyk, .u16, true),
        ("rt_rgb8_pixels", .rgb, .u8, false), ("rt_gray16_pixels", .grayscale, .u16, false), ("rt_cmyk8_pixels", .cmyk, .u8, false),
    ]

    @Test(arguments: rtCases.indices) func rtCase(_ i: Int) throws {
        let (name, mode, depth, all) = Self.rtCases[i]
        let d = genDoc(mode, depth, all ? .all : .pixels)
        let back = try Self.roundtrip(d)
        Self.expectSame(Self.expected(d), back, "\(name)")
    }

    @Test func tiffAndPSDOpenAsTheSameDocument() throws {
        for (mode, depth) in [(ColorMode.rgb, SampleType.u8), (.cmyk, .u16), (.grayscale, .f32)] {
            let d = genDoc(mode, depth, .all)
            let psd = try Kit.export(d, "x.psd")
            let fromPSD = try Kit.importFile("x.psd", psd.bytes).document
            let fromTIF = try Self.roundtrip(d)
            Self.expectSame(Self.expected(fromPSD), fromTIF, "\(mode) \(depth)")
            // The composite the TIFF carries is what the document looks like.
            let tif = try Self.tiff(d, layers: true)
            let img = try ImageIOCodec().decode(tif.bytes)
            let rect = PixelRect(x0: 0, y0: 0, x1: Int32(img.width), y1: Int32(img.height))
            let surface = img.hasAlpha ? img.surface : Kit.withoutAlpha(img.surface, rect)
            let reencoded = try ImageIOCodec().encode(surface, rect: rect, as: .tiff, quality: nil, iccProfile: img.iccProfile)
            let flat = try Kit.importFile("flat.tif", reencoded).document
            let (a, b) = (try Kit.flatten(d), try Kit.flatten(flat))
            #expect(Kit.maxDiff(a, b) <= 2 / 255, "\(mode) \(depth): composite differs by \(Kit.maxDiff(a, b))")
        }
    }

    /// photocraft writes the TIFF with each `TiffCompression` (`opts.encode.tiff_compression`);
    /// PCIO's IOOptions has no compression choice, so the layered file is written again by
    /// `LayeredTIFF.write` with each compression it offers (no LZW).
    @Test func everyCompressionKeepsTheLayers() throws {
        let d = genDoc(.rgb, .u16, .pixels)
        let r = try Self.tiff(d, layers: true)
        for c in LayeredTIFF.Compression.allCases {
            let bytes = try Kit.rewriteTIFF(r.bytes, compression: c)
            let back = try Kit.importFile("x.tiff", bytes).document
            Self.expectSame(d, back, "\(c)")
        }
    }

    /// The Artist tag's text, and the bytes every EXIF assertion looks for.
    static let artist = Array("fixture-artist".utf8)

    /// A minimal little-endian EXIF (TIFF) block with a single Artist tag and no Orientation.
    static func exif() -> [UInt8] {
        let a = artist + [0]
        var v: [UInt8] = [0x49, 0x49, 0x2A, 0, 8, 0, 0, 0]
        v += [1, 0] // one entry
        v += [0x3B, 0x01, 2, 0] // Artist, ASCII
        v += [UInt8(a.count), 0, 0, 0]
        v += [26, 0, 0, 0] // value offset: 8 + 2 + 12 + 4
        v += [0, 0, 0, 0] // no next IFD
        return v + a
    }

    /// #1545: a layered TIFF carries EXIF as Photoshop resource 1058 and reads it back, so it must
    /// not report a loss it never makes. A flat TIFF really does lose the tags and still says so.
    @Test func layeredTIFFKeepsEXIFWithoutClaimingALoss() throws {
        var d = genDoc(.rgb, .u8, .pixels)
        d.metadata.exif = Self.exif()
        let r = try Self.tiff(d, layers: true)
        #expect(!r.warnings.contains { $0.contains("EXIF") }, "a layered TIFF keeps EXIF: \(r.warnings)")
        let back = try Kit.importFile("x.tif", r.bytes).document
        let kept = try #require(back.metadata.exif, "EXIF survives the layered export")
        #expect(kept.indices.contains { kept[$0...].starts(with: Self.artist) }, "the Artist tag did not survive: \(kept)")
        // The control from the issue: the flat path drops it for real, and keeps reporting that.
        let flat = try Self.tiff(d, layers: false)
        #expect(flat.warnings.contains { $0.contains("EXIF") }, "a flat TIFF really does lose EXIF: \(flat.warnings)")
    }

    @Test func discardLayersWritesAFlatFile() throws {
        let d = genDoc(.rgb, .u8, .pixels)
        let r = try Self.tiff(d, layers: false)
        let t = Kit.tags(r.bytes)
        #expect(t.resources == nil && t.layers == nil)
        #expect(r.warnings.contains { $0.contains("flattened") }, "\(r.warnings)")
        let back = try Kit.importFile("x.tif", r.bytes).document
        #expect(back.layers.count == 1)
        #expect(!TIFFLayers.wouldWriteLayers(back))
    }

    @Test func aPlainBackgroundNeedsNoLayerData() throws {
        let png = try Kit.export(genDoc(.rgb, .u8, .pixels), "x.png")
        let d = try Kit.importFile("x.png", png.bytes).document
        #expect(d.layers.count == 1)
        #expect(!TIFFLayers.wouldWriteLayers(d))
        let r = try Self.tiff(d, layers: true)
        let t = Kit.tags(r.bytes)
        #expect(t.resources == nil && t.layers == nil)
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        let back = try Kit.importFile("x.tif", r.bytes).document
        Self.expectSame(d, back)
    }

    @Test func labDocumentsAreSavedFlatWithAWarning() throws {
        let d = genDoc(.lab, .u8, .pixels)
        let r = try Self.tiff(d, layers: true)
        let t = Kit.tags(r.bytes)
        #expect(t.resources == nil && t.layers == nil)
        #expect(r.warnings.contains { $0.contains("Lab") && $0.contains("layers are not kept") }, "\(r.warnings)")
        #expect((try? Kit.importFile("x.tif", r.bytes)) != nil)
    }

    @Test func transparencyIsStraightInTheComposite() throws {
        // A translucent layer over nothing: the TIFF's composite keeps its colour under the alpha
        // instead of being matted against white like a PSD's merged image.
        var d = Document(name: "t", size: PixelSize(width: 4, height: 4), mode: .rgb, depth: .u8)
        var l = rasterLayer("Red", d.pixelFormat, rect(0, 0, 4, 4), 0, false)
        l.withRaster { $0.writeRegion(rect(0, 0, 4, 4), Array([[Float]](repeating: [1, 0, 0, 0.5], count: 16).joined())) }
        d.layers.append(l)
        let r = try Self.tiff(d, layers: true)
        let flat = try ImageIOCodec().decode(r.bytes)
        #expect(flat.hasAlpha)
        let px = flat.surface.pixel(x: 0, y: 0).map { UInt8(($0 * 255).rounded()) }
        #expect(px == [255, 0, 0, 128])
        let back = try Kit.importFile("x.tif", r.bytes).document
        Self.expectSame(d, back)
    }

    @Test func bigDocumentsUseThePSBSignature() throws {
        // Forcing PSB stands in for a > 30000 px document.
        let d = genDoc(.rgb, .u8, .pixels)
        let r = try Self.tiff(d, layers: true, forcePSB: true)
        let layers = try #require(Kit.tags(r.bytes).layers)
        #expect(layers.starts(with: PSDTIFF.signaturePSB))
        let back = try Kit.importFile("x.tif", r.bytes).document
        Self.expectSame(d, back)
    }

    /// Advanced Blending, fill opacity, channel restrictions and Blend If survive a layered TIFF
    /// with its layer data in either byte order: the encoder's own, and the other one made by
    /// transcoding the tag (the same length, spliced in place).
    @Test func advancedBlendingSurvivesLayeredTIFFInBothByteOrders() throws {
        for depth in [SampleType.u8, .u16, .f32] {
            var d = genDoc(.rgb, depth, .pixels)
            let adv = AdvancedBlending(knockout: .deep, blendInterior: true, blendClipped: false, transparencyShapes: false,
                                       layerMaskHidesEffects: true, vectorMaskHidesEffects: true)
            d.layers[1].advanced = adv
            let fill: Float = 64 / 255
            d.layers[1].fillOpacity = fill
            d.layers[1].excludedChannels = 0b010
            d.layers[1].blendIf.set(0, BlendRangePair(BlendRange(black: SIMD2(10, 40), white: SIMD2(200, 250)),
                                                      BlendRange(black: SIMD2(0, 0), white: SIMD2(128, 128))))
            d.layers[2].advanced.knockout = .shallow
            let r = try Self.tiff(d, layers: true)
            let layers = try #require(Kit.tags(r.bytes).layers)
            let (isd, w) = try PSDTIFF.ImageSourceData.fromBytes(layers)
            #expect(w.isEmpty, "\(w)")
            let native = isd.byteOrder
            let other: PSDTIFF.ByteOrder = native == .little ? .big : .little
            let (swapped, w2) = try isd.toBytes(other)
            #expect(w2.isEmpty, "\(depth): blocks dropped while transcoding: \(w2)")
            #expect(swapped.count == layers.count)
            let at = try #require(r.bytes.indices.first { r.bytes[$0...].starts(with: layers) }, "tag data in the file")
            var flipped = r.bytes
            flipped.replaceSubrange(at ..< at + layers.count, with: swapped)
            for (order, bytes) in [(native, r.bytes), (other, flipped)] {
                let back = try Kit.importFile("x.tif", bytes).document
                let l = back.layers[1]
                #expect(l.advanced == adv, "\(depth) \(order)")
                #expect(l.fillOpacity == fill, "\(depth) \(order)")
                #expect(l.excludedChannels == 0b010, "\(depth) \(order)")
                #expect(l.blendIf == d.layers[1].blendIf, "\(depth) \(order)")
                #expect(back.layers[2].advanced.knockout == .shallow, "\(depth) \(order)")
                Self.expectSame(Self.expected(d), back, "\(depth) \(order)")
            }
        }
    }

    @Test func damagedLayerDataOpensFlattened() throws {
        let d = genDoc(.rgb, .u8, .pixels)
        let r = try Self.tiff(d, layers: true)
        let layers = try #require(Kit.tags(r.bytes).layers)
        let at = try #require(r.bytes.indices.first { r.bytes[$0...].starts(with: layers) })
        // Garbage after the signature: no layers, a warning, the composite as one layer.
        var bad = r.bytes
        for i in at + 36 ..< at + 36 + 24 { bad[i] ^= 0xA5 }
        let r2 = try Kit.importFile("x.tif", bad)
        #expect(r2.document.layers.count == 1)
        #expect(r2.warnings.contains { $0.contains("could not be read") }, "\(r2.warnings)")
        // Every truncation and a sweep of bit flips through the whole file: never a trap.
        for cut in stride(from: 0, to: r.bytes.count, by: 11) { _ = try? Kit.importFile("x.tif", Array(r.bytes[..<cut])) }
        for i in stride(from: 0, to: r.bytes.count, by: 29) {
            var b = r.bytes
            b[i] ^= 0x5A
            _ = try? Kit.importFile("x.tif", b)
        }
    }

    @Test func defaultExportOptionsWriteAFlatTIFF() throws {
        // Scripted and agent saves build on the defaults: layers only on request.
        let d = genDoc(.rgb, .u8, .pixels)
        #expect(TIFFLayers.wouldWriteLayers(d))
        let r = try Kit.export(d, "x.tif")
        let t = Kit.tags(r.bytes)
        #expect(t.resources == nil && t.layers == nil)
        #expect(try Kit.importFile("x.tif", r.bytes).document.layers.count == 1)
    }

    /// #2940: layered TIFF data whose groups nest past the document's cap is rejected with the same
    /// limit error as a PSD, instead of being converted.
    @Test func layeredTIFFNestedPastTheCapIsRejected() throws {
        func tiffNested(_ levels: Int) throws -> [UInt8] {
            var b = PSDBuilder(width: 4, height: 4)
            for _ in 0 ..< levels { b.beginGroup(PSDGroupSpec(name: "g")) }
            b.pushLayer(PSDLayerSpec(name: "deep", left: 0, top: 0, width: 1, height: 1, pixels: .u8([1, 2, 3, 4])))
            for _ in 0 ..< levels { try b.endGroup() }
            let file = try PSDFile(data: try b.serialized())
            let order: PSDTIFF.ByteOrder = LayeredTIFF.writesLittleEndian ? .little : .big
            let layers = try PSDTIFF.ImageSourceData.fromPSD(file).toBytes(order).bytes
            let flat = try Self.tiff(genDoc(.rgb, .u8, .pixels), layers: false)
            return try Kit.rewriteTIFF(flat.bytes, layers: layers)
        }
        let e = Kit.error { try Kit.importFile("deep.tif", try tiffNested(101)) }
        #expect(e.map { "\($0)".contains("nested deeper than 100") } == true, "\(String(describing: e))")
        // PCIO bug: `PSDImport` `Importer.build` recurses once per group with a large frame, and at
        // the allowed depth of 100 overflows a Swift Testing worker thread's stack (SIGBUS in debug
        // builds). Opened on a thread with an 8 MiB stack, like a main thread, until it is fixed.
        let hundred = try tiffNested(100)
        let r = try Kit.onLargeStack { try Kit.importFile("hundred.tif", hundred) }
        #expect(r.document.maxGroupDepth == 100)
    }
}
