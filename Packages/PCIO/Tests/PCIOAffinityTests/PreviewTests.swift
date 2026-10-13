// Port of photocraft-io (crates/io/tests/affinity.rs, the preview tests before `mod native`),
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// The embedded preview only as a warned fallback that keeps its pixels and alpha; never written back.
// photocraft also exports the result (PNG, .pcraft, refused Affinity names): that is the PCIO
// dispatch's job, so these tests assert on the document instead.

import Foundation
import PCAffinity
import PCAffinitySynth
@testable import PCIOAffinity
import PCDocument
import PCFoundation
import PCIOCore
import Testing

@Suite struct PreviewTests {
    @Test func previewIsNamedAndWarnsAtItsActualSize() throws {
        let r = try importAF("art.af", file(png()))
        #expect(r.document.size == PixelSize(width: 2, height: 1))
        #expect(r.document.layers.count == 1)
        let l = r.document.layers[0]
        #expect(l.name == "Affinity preview")
        #expect(l.locks == Locks())
        #expect(r.sourceReadOnly && r.previewOnly)
        #expect(r.warnings[0].contains("2×1"))
        #expect(r.warnings[0].contains("native Affinity document could not be read") && r.warnings[0].contains("no layers"), "\(r.warnings[0])")
        // The pixels and alpha of the PNG, exactly.
        #expect(r.document.mode == .rgb && r.document.depth == .u8)
        #expect(bytes(l.surface, PixelRect(x0: 0, y0: 0, x1: 2, y1: 1)) == [220, 40, 60, 255, 0, 0, 0, 0])
        for ext in AffinityImport.extensions {
            #expect(AffinityImport.hasExtension("copy.\(ext)"))
        }
    }

    @Test func magicWinsOverTheNameAndRenamedLegacyFilesAreRejected() throws {
        // The PCIO dispatch routes by magic first; the importer itself ignores the name.
        #expect(AffinityImport.isAffinity(file(png())) && !AffinityImport.hasExtension("renamed.png"))
        #expect(try importAF("renamed.png", file(png())).sourceReadOnly)
        #expect(try importAF("unknown", file(png())).sourceReadOnly)
        #expect(!AffinityImport.isAffinity(png()))
        #expect(importError("fake.af", png()) != nil)
        // Affinity 1 and 2 (container versions 8 to 11) store the same preview record.
        var legacy = file(png())
        legacy.replaceSubrange(4..<6, with: le(UInt16(10)))
        #expect(try importAF("legacy.afphoto", legacy).previewOnly)
        legacy.replaceSubrange(4..<6, with: le(UInt16(13)))
        let e = importError("future.af", legacy)
        #expect(e?.contains("unknown container version") == true, "\(String(describing: e))")
    }

    @Test func previewDecoderPreserves16BitGrayAndAlpha() throws {
        // Gray + alpha, 16 bits: (12345, 65535) and (0, 0), big-endian samples.
        let encoded = makePNG(width: 2, height: 1, bitDepth: 16, colorType: 4, rows: [be(UInt16(12345)) + be(UInt16(65535)) + be(UInt16(0)) + be(UInt16(0))])
        let expected: [Float] = [Float(12345) / 65535, 1, 0, 0]
        // The decoder's picture becomes the document as it is: depth, mode, samples, alpha.
        var s = Surface(format: PixelFormat(mode: .grayscale, sample: .u16, alpha: true))
        s.writeRegion(PixelRect(x0: 0, y0: 0, x1: 2, y1: 1), expected)
        let stub = StubCodec(image: DecodedImage(surface: s, width: 2, height: 1, hasAlpha: true))
        let r = try AffinityImport.importDocument(name: "gray.af", bytes: file(encoded), renderer: nil, codec: stub)
        #expect(r.document.depth == .u16)
        #expect(r.document.mode == .grayscale)
        #expect(r.document.layers[0].surface?.readRegion(PixelRect(x0: 0, y0: 0, x1: 2, y1: 1)) == expected)
        // Through the default codec (gray + alpha is read from the image's own samples).
        let viaImageIO = try importAF("gray.af", file(encoded))
        #expect(viaImageIO.document.depth == .u16 && viaImageIO.document.mode == .grayscale)
        #expect(viaImageIO.document.layers[0].surface?.readRegion(PixelRect(x0: 0, y0: 0, x1: 2, y1: 1)) == expected)
    }

    @Test func previewlessCurrentFilesReturnAnExportFallback() {
        var b = file(png())
        b.replaceSubrange(24..<32, with: [UInt8](repeating: 0, count: 8))
        let e = importError("no-preview.af", b)
        #expect(e?.contains("no embedded preview") == true, "\(String(describing: e))")
    }

    @Test func corruptionAndEveryTruncationFailWithoutADocument() {
        let b = file(png())
        for end in 0..<b.count {
            #expect(importError("bad.af", Array(b[..<end])) != nil, "\(end)")
        }
        var badCRC = b
        // IHDR's CRC; the envelope reader rejects every PNG chunk's bad CRC.
        badCRC[130] ^= 1
        #expect(importError("bad.af", badCRC) != nil)
    }

    @Test func crcFailuresAfterIDATCannotBeToleratedAsPartialPNGs() throws {
        var badIEND = file(png())
        badIEND[badIEND.count - 1] ^= 1
        #expect(importError("bad-iend.af", badIEND)?.contains("PNG chunk checksum") == true)

        var encoded = png()
        let text = chunk("tEXt", ascii("note\0preview"))
        let end = encoded.count - 12
        encoded.insert(contentsOf: text, at: end)
        #expect(try importAF("valid-ancillary.af", file(encoded)).previewOnly)
        encoded[end + text.count - 1] ^= 1
        #expect(importError("bad-ancillary.af", file(encoded))?.contains("PNG chunk checksum") == true)
    }

    @Test func compressedMetadataAndAPNGFailBeforeReachingTheDecoder() {
        for kind in ["zTXt", "iTXt", "iCCP", "acTL", "fcTL", "fdAT"] {
            var encoded = png()
            // A tiny declared payload stands in for arbitrarily large inflated metadata. It must
            // return the format's unsupported error, not be passed to a decompressor.
            let end = encoded.count - 12
            encoded.insert(contentsOf: chunk(kind, ascii("preview\0\0") + [0x78, 0x9C]), at: end)
            let e = importError("unsupported.af", file(encoded)) ?? ""
            #expect(e.contains("unsupported Affinity file"), "\(kind): \(e)")
            #expect(e.contains("PNG metadata") || e.contains("animated PNG"), "\(e)")
        }
    }

    @Test func manyValidCompressedTextChunksCannotBypassTheTotalMemoryBudget() {
        let compressed = Synth.zlib([UInt8](repeating: UInt8(ascii: "x"), count: 1024 * 1024))
        #expect(compressed.count < 4096)
        let one = chunk("zTXt", ascii("note\0") + [0] + compressed)
        var encoded = png()
        let end = encoded.count - 12
        // A few MiB of encoded PNG would otherwise carry 1 GiB of aggregate text.
        encoded.insert(contentsOf: Array([[UInt8]](repeating: one, count: 1024).joined()), at: end)
        let e = importError("text-bomb.af", file(encoded)) ?? ""
        #expect(e.contains("compressed PNG metadata"), "\(e)")
    }

    @Test func invalidCriticalChunksAfterIDATFailBeforePNGFinish() {
        let original = png()
        for trailing in [chunk("IHDR", Array(original[16..<29])), chunk("PLTE", [0, 0, 0]), chunk("ABCD", [])] {
            var encoded = original
            encoded.insert(contentsOf: trailing, at: encoded.count - 12)
            let e = importError("bad-order.af", file(encoded)) ?? ""
            #expect(e.contains("Affinity file"), "\(e)")
        }
        var encoded = original
        encoded.insert(contentsOf: chunk("tEXt", ascii("note\0preview")) + chunk("IDAT", []), at: encoded.count - 12)
        #expect(importError("split-idat.af", file(encoded))?.contains("non-contiguous PNG image data") == true)
    }

    /// photocraft's proptest (128 cases): random edits in the first 300 bytes never trap.
    @Test func previewAndDecoderSurviveMutations() {
        var rng = SeededRNG(seed: 1)
        let base = file(png())
        for _ in 0..<128 {
            var b = base
            for _ in 0..<Int.random(in: 0..<16, using: &rng) {
                let i = Int.random(in: 0..<300, using: &rng)
                if i < b.count { b[i] = UInt8.random(in: 0...255, using: &rng) }
            }
            _ = importError("mutated.af", b)
        }
    }

    /// The reason comes first and is the only warning of a plain RGBA preview; the decoder's
    /// resolution and profile are kept.
    @Test func previewWarningAndDecoderMetadata() throws {
        let r = try importAF("broken.af", file(png()))
        #expect(r.warnings.count == 1)
        #expect(r.warnings[0].hasPrefix("The native Affinity document could not be read (damaged Affinity file") || r.warnings[0].hasPrefix("The native Affinity document could not be read (unsupported Affinity file"), "\(r.warnings[0])")
        #expect(r.warnings[0].contains("Opened only its embedded 2×1 PNG preview"))
        var s = Surface(format: .rgba8)
        s.writeRegion(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1), [1, 0, 0, 1])
        let stub = StubCodec(image: DecodedImage(surface: s, width: 1, height: 1, hasAlpha: false, iccProfile: [1, 2, 3], dpi: (300, 150)))
        let d = try AffinityImport.importDocument(name: "dpi.af", bytes: file(png()), renderer: nil, codec: stub)
        #expect(d.document.resolutionDpi == 300 && d.document.iccProfile == [1, 2, 3])
        #expect(d.warnings.count == 2 && d.warnings[1].contains("vertical resolution"))
        // An opaque picture: the Background's locks are cleared with its new name.
        #expect(d.document.layers[0].name == "Affinity preview" && d.document.layers[0].locks == Locks())
        // A decoder returning more than photocraft's 4096 px a side is refused.
        let big = StubCodec(image: DecodedImage(surface: s, width: 4097, height: 1, hasAlpha: true))
        #expect(throws: PCIOError.self) { try AffinityImport.importDocument(name: "big.af", bytes: file(png()), renderer: nil, codec: big) }
    }
}
