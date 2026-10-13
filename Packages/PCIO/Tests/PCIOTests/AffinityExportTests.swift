// Port of photocraft-io (crates/io/tests/affinity.rs and affinity_artboards.rs: the halves that
// need the PCIO dispatch, export and compositor), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
// An imported Affinity document (native or its preview) saves as PNG, `.pcraft` and PSD, never back
// as Affinity, and its composite keeps artboard clipping through those saves. The import halves
// (document model, warnings, malformed input, mutations) are PCIOAffinityTests' PreviewTests and
// NativeTests; `current_properties_mark_converted_curve_artboards_too` and
// `other_properties_do_not_turn_ordinary_shapes_into_artboards` are import-only and live there.
// Shape caches are drawn by the injected renderer (the CoreGraphics stand-in for photocraft-vector)
// and composites by PCRender.

import Foundation
import PCAffinitySynth
import PCDocument
import PCFoundation
import PCIOAffinity
import PCIOCore
import Testing
@testable import PCIO

@Suite struct AffinityExportTests {
    init() { ExportSweep.install() }
    /// A PNG export decoded back to its samples (straight, normalised).
    static func decode(_ png: [UInt8]) throws -> (DecodedImage, [Float]) {
        let img = try ImageIOCodec().decode(png)
        return (img, img.surface.readRegion(PixelRect(x: 0, y: 0, width: img.width, height: img.height)))
    }

    /// The composite as exported to PNG, as 8-bit RGBA (photocraft `pixels`).
    static func pixels(_ doc: Document, sourceLocation: SourceLocation = #_sourceLocation) throws -> [UInt8] {
        let bytes = try MapsKit.export(doc, "boards.png", sourceLocation: sourceLocation).bytes
        let (img, _) = try decode(bytes)
        return img.surface.readInterleaved(PixelRect(x: 0, y: 0, width: img.width, height: img.height))
    }

    static func boards(_ doc: Document) -> [String] { doc.artboards.map { "\($0.name) \($0.artboard.rect)" } }

    static func exportError(_ doc: Document, _ name: String) -> String? {
        do {
            _ = try DocumentIO.export(doc, as: name, options: MapsKit.options())
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test func previewExportsAsPNGAndPcraftButNeverAsAffinity() throws {
        let r = try MapsKit.importFile(MapsKit.previewFile(MapsKit.png()), "art.af")
        #expect(r.sourceReadOnly && r.previewOnly)
        let out = try MapsKit.export(r.document, "copy.png")
        let (img, _) = try Self.decode(out.bytes)
        #expect(img.surface.readInterleaved(PixelRect(x: 0, y: 0, width: 2, height: 1)) == [220, 40, 60, 255, 0, 0, 0, 0])
        let native = try MapsKit.export(r.document, "copy.pcraft")
        let back = try MapsKit.importFile(native.bytes, "copy.pcraft")
        #expect(back.document.size == r.document.size)
        #expect(!back.sourceReadOnly && !back.previewOnly)
        for ext in AffinityImport.extensions {
            let e = Self.exportError(r.document, ext)
            #expect(e?.contains("Affinity export") == true, "\(ext): \(String(describing: e))")
        }
    }

    @Test func previewDecoderPreserves16BitGrayAndAlphaThroughPNG() throws {
        // 2×1 gray+alpha, 16-bit: (12345, opaque), (0, transparent).
        let row: [UInt8] = MapsKit.beBytes(UInt16(12345)) + MapsKit.beBytes(UInt16(65535)) + [0, 0, 0, 0]
        let encoded = MapsKit.makePNG(width: 2, height: 1, bitDepth: 16, colorType: 4, rows: [row])
        let r = try MapsKit.importFile(MapsKit.previewFile(encoded), "gray.af")
        #expect(r.document.depth == .u16)
        #expect(r.document.mode == .grayscale)
        let out = try MapsKit.export(r.document, "copy.png")
        let (img, v) = try Self.decode(out.bytes)
        #expect(img.surface.format.sample == .u16)
        let want: [Float] = [Float(12345) / 65535, 1, 0, 0]
        #expect(v.count == want.count, "\(img.surface.format)")
        for (a, b) in zip(v, want) { #expect(abs(a - b) <= 0.5 / 65535, "\(v) vs \(want)") }
    }

    @Test(arguments: Synth.Method.allCases) func nativeDocumentsSaveAsPcraftAndPSDButNotAffinity(_ method: Synth.Method) throws {
        let r = try MapsKit.importFile(MapsKit.ringDocument(method), "native.af")
        #expect(r.sourceReadOnly && !r.previewOnly, "\(r.warnings)")
        let d = r.document
        // Saved as a native PhotoCraft document and opened again.
        let saved = try MapsKit.export(d, "copy.pcraft")
        let back = try MapsKit.importFile(saved.bytes, "copy.pcraft")
        #expect(back.document.layers.count == d.layers.count)
        #expect(throws: Never.self) { try MapsKit.export(d, "copy.psd") }
        #expect(Self.exportError(d, "copy.af") != nil)
    }

    @Test(arguments: Synth.Method.allCases) func currentPropertyArtboardsKeepBoundsClippingAndRoundtrips(_ method: Synth.Method) throws {
        for marker in [MapsKit.Marker.legacy, .current] {
            let loaded = try MapsKit.importFile(MapsKit.boardsDocument(marker, curve: false, method), "synthetic.af")
            #expect(!loaded.previewOnly && loaded.sourceReadOnly)
            let d = loaded.document
            #expect(Self.boards(d) == ["Board 100 \(rect(0, 0, 16, 16))", "Board 200 \(rect(24, 0, 40, 16))"], "\(marker)")
            let expected = try Self.pixels(d)
            #expect(expected.count == 40 * 16 * 4)
            var wrong = 0
            for i in 0 ..< min(expected.count / 4, 40 * 16) {
                let x = i % 40
                let want: [UInt8] = (16 ..< 24).contains(x) ? [0, 0, 0, 0] : [255, 0, 0, 255]
                if Array(expected[i * 4 ..< i * 4 + 4]) != want { wrong += 1 }
            }
            #expect(wrong == 0, "\(marker): \(wrong) pixels not clipped at the board edges")
            for name in ["copy.pcraft", "copy.psd"] {
                let bytes = try MapsKit.export(d, name).bytes
                let reopened = try MapsKit.importFile(bytes, name).document
                #expect(Self.boards(reopened) == Self.boards(d), "\(marker) \(name)")
                #expect(try Self.pixels(reopened) == expected, "\(marker) \(name)")
            }
        }
    }
}
