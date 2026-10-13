// Port of photocraft-io's Krita tests (crates/io/src/kra.rs `mod tests`, and the parts of
// crates/io/tests/krita_corpus.rs that run without a compositor), MIT OR Apache-2.0, © ArtCraft
// Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIOFormats

@Suite("Krita")
struct KritaTests {
    typealias Kit = ContainerTestKit

    static func png() -> [UInt8] {
        let rect = PixelRect(x0: 0, y0: 0, x1: 2, y1: 1)
        let s = Surface(format: .rgba8, rect: rect, interleaved: [255, 0, 0, 255, 0, 0, 255, 128])
        return (try? ImageIOCodec().encode(s, rect: rect, as: .png, quality: nil, iccProfile: nil)) ?? []
    }

    static func archive(_ mime: [UInt8], _ withMerged: Bool) -> [UInt8] {
        var entries: [(String, [UInt8])] = [("maindoc.xml", Array("<DOC/>".utf8))]
        if withMerged { entries.append(("mergedimage.png", png())) }
        return Kit.archive(mime, entries)
    }

    @Test func importsKritaCompositeWithoutClaimingToPreserveLayers() throws {
        let bytes = Self.archive(Krita.mimetype, true)
        #expect(Krita.isKRA(bytes))
        #expect(!OpenRaster.isORA(bytes))
        // The mimetype is authoritative even without a .kra extension.
        for name in ["scene.kra", "download"] {
            let r = try Krita.importDocument(name: name, bytes: bytes, codec: ImageIOCodec(), interrupt: .none)
            #expect(r.document.size == PixelSize(width: 2, height: 1))
            #expect(r.document.name == name)
            #expect(r.document.layers.count == 1)
            #expect(r.document.layers[0].name == "Layer 0", "alpha-bearing composite")
            let pixels = try #require(r.document.layers[0].surface)
            #expect(pixels.rgba(x: 0, y: 0).x > 0.99)
            #expect(pixels.rgba(x: 1, y: 0).z > 0.99)
            #expect(abs(pixels.rgba(x: 1, y: 0).w - 128 / 255) < 0.01)
            #expect(r.sourceReadOnly, ".kra must not be overwritten by a flat save")
            #expect(!r.previewOnly, "the flattened image is editable")
            #expect(r.warnings.contains { $0.contains("layers") && $0.contains("not imported") })
        }
    }

    @Test func malformedOrNonKritaArchivesDoNotOpenAsKrita() {
        let wrong = Self.archive(Array("image/openraster".utf8), true)
        #expect(!Krita.isKRA(wrong))
        #expect(throws: (any Error).self) { try Krita.importDocument(name: "wrong.kra", bytes: wrong, codec: ImageIOCodec(), interrupt: .none) }
        #expect(throws: (any Error).self) {
            try Krita.importDocument(name: "missing.kra", bytes: Self.archive(Krita.mimetype, false), codec: ImageIOCodec(), interrupt: .none)
        }
        #expect(throws: (any Error).self) {
            try Krita.importDocument(name: "broken.kra", bytes: Array("not a zip".utf8), codec: ImageIOCodec(), interrupt: .none)
        }
        // A merged image that is not a PNG is refused before decoding.
        let jpegish = Kit.archive(Krita.mimetype, [("mergedimage.png", [0xFF, 0xD8, 0xFF, 0xE0, 0, 0])])
        let e = Kit.error { try Krita.importDocument(name: "x.kra", bytes: jpegish, codec: ImageIOCodec(), interrupt: .none) }
        #expect(e as? PCIOError == .format("Krita", "mergedimage.png is not a PNG image"))
    }

    @Test func aPNGWithAMisleadingKraExtensionIsNotKrita() {
        // photocraft's dispatch opens it as a PNG; the content check is what decides.
        #expect(!Krita.isKRA(Self.png()))
    }

    @Test func opaqueCompositesOpenAsALockedBackgroundAtTheirDepth() throws {
        let rect = PixelRect(x0: 0, y0: 0, x1: 3, y1: 2)
        var bytes: [UInt8] = []
        for i in 0 ..< 6 { bytes += [UInt8(i * 40), 0, UInt8(255 - i * 40)] }
        let rgb = Surface(format: PixelFormat(mode: .rgb, sample: .u8, alpha: false), rect: rect, interleaved: bytes)
        let png = try ImageIOCodec().encode(rgb, rect: rect, as: .png, quality: nil, iccProfile: nil)
        let r = try Krita.importDocument(name: "opaque.kra", bytes: Kit.archive(Krita.mimetype, [("mergedimage.png", png)]), codec: ImageIOCodec(),
                                         interrupt: .none)
        let bg = try #require(r.document.background)
        #expect(bg.name == "Background")
        #expect(bg.locks.transparency && bg.locks.position)
        #expect(r.document.depth == .u8)
        #expect(r.document.mode == .rgb)
        // A 16-bit merged image keeps its depth.
        let rgba16 = Surface(format: .rgba16, rect: rect, interleaved: [UInt8](repeating: 0x80, count: 6 * 8))
        let png16 = try ImageIOCodec().encode(rgba16, rect: rect, as: .png, quality: nil, iccProfile: nil)
        let r16 = try Krita.importDocument(name: "deep.kra", bytes: Kit.archive(Krita.mimetype, [("mergedimage.png", png16)]), codec: ImageIOCodec(),
                                           interrupt: .none)
        #expect(r16.document.depth == .u16)
    }

    @Test func oversizedMergedImagesAreRefusedBeforeDecoding() {
        var forged = Self.png()
        forged.replaceSubrange(16 ..< 24, with: [0, 0x05, 0x00, 0x00, 0, 0x05, 0x00, 0x00])
        let e = Kit.error {
            try Krita.importDocument(name: "x.kra", bytes: Kit.archive(Krita.mimetype, [("mergedimage.png", forged)]), codec: ImageIOCodec(),
                                     interrupt: .none)
        }
        #expect((e as? PCIOError)?.description.contains("limit exceeded") == true, "\(String(describing: e))")
    }

    @Test func importCanBeCancelled() {
        #expect(throws: PCIOError.cancelled) {
            try Krita.importDocument(name: "x.kra", bytes: Self.archive(Krita.mimetype, true), codec: ImageIOCodec(), interrupt: .cancelOnly { true })
        }
    }

    /// photocraft `krita_corpus` (needs `KRITA_TEST_DIR` with Krita-authored `.ora` files from
    /// photocraft-corpus): every file opens, its canvas matches Krita's merged image, and the
    /// layer count is reported. The rendering comparison against `mergedimage.png` needs the
    /// engine's compositor (PCRender) and is left to PCIO's integration tests.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KRITA_TEST_DIR"] != nil))
    func kritaOraFilesOpen() throws {
        let root = try #require(ProcessInfo.processInfo.environment["KRITA_TEST_DIR"])
        let names = try FileManager.default.contentsOfDirectory(atPath: root).filter { $0.lowercased().hasSuffix(".ora") }.sorted()
        #expect(!names.isEmpty, "no .ora files found")
        for name in names {
            let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(name)))
            let r = try OpenRaster.importDocument(name: name, bytes: bytes, codec: ImageIOCodec(), interrupt: .none)
            let merged = try ImageIOCodec().decode(try ZipReader(bytes).read(named: "mergedimage.png", max: 1 << 28))
            #expect(r.document.size == PixelSize(width: merged.width, height: merged.height), "\(name)")
            print("\(name): \(r.document.layers.count) layers\(r.warnings.isEmpty ? "" : "; warnings: " + r.warnings.joined(separator: "; "))")
        }
    }
}
