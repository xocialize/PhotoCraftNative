// Port of photocraft-io (crates/io/tests/psd32_export.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// 32-bit-per-channel PSD export (#291): the layout Photoshop requires to open the file. Photoshop
// 2026 refuses ("the open options are incorrect") any 32-bit PSD whose Color Mode Data lacks the
// HDR toning records it writes itself. These tests pin the whole structure of a 32-bit export
// against what Photoshop saves: header depth, toning records, required resources, layer info in an
// `Lr32` global block with an empty classic layer info, channel compression codes valid for 32-bit
// data, and a raw big-endian float merged image. Run in both record shapes.
//
// Not ported: `photoshop_32bit_corpus_round_trip` (photocraft's external `corpus/photoshop/
// adjustments/{rgb32,gray32}` oracles; the PCPSD_CORPUS files are all 8-bit RGB).

import Foundation
import PCDocument
import PCFoundation
import PCPSD
import Testing
@testable import PCIO

@Suite struct PSD32ExportTests {
    init() { ExportSweep.install() }
    /// Walks the raw file: (classic layer info length, keys of the global blocks).
    static func rawLayerSection(_ b: [UInt8]) -> (liLength: UInt32, keys: [String])? {
        func be32(_ at: Int) -> UInt32? { at >= 0 && at + 4 <= b.count ? PSDKit.be32(b, at) : nil }
        var p = 26
        guard let cmd = be32(p) else { return nil }
        p += 4 + Int(cmd) // colour mode data
        guard let res = be32(p) else { return nil }
        p += 4 + Int(res) // image resources
        guard let lm = be32(p), lm > 0 else { return nil }
        p += 4
        let end = p + Int(lm)
        guard let li = be32(p) else { return nil }
        p += 4 + Int(li)
        guard let glm = be32(p) else { return nil }
        p += 4 + Int(glm) // global layer mask
        var keys: [String] = []
        while p + 12 <= end, p + 12 <= b.count {
            let sig = String(decoding: b[p ..< p + 4], as: UTF8.self)
            guard sig == "8BIM" || sig == "8B64" else { keys.append("<bad signature at \(p)>"); break }
            keys.append(String(decoding: b[p + 4 ..< p + 8], as: UTF8.self))
            guard let n = be32(p + 8) else { break }
            // Global blocks are padded to 4 bytes.
            p += 12 + (Int(n) + 3) / 4 * 4
        }
        return (li, keys)
    }

    /// The structure problems of a 32-bit PSD written by the exporter (empty: Photoshop's layout).
    static func layoutProblems(_ name: String, _ bytes: [UInt8]) -> [String] {
        let f: PSDFile
        do { f = try PSDFile(bytes: bytes) } catch { return ["\(name): \(error)"] }
        var p: [String] = []
        func check(_ ok: Bool, _ what: @autoclosure () -> String) { if !ok { p.append("\(name): \(what())") } }
        check(f.header.depth == 32, "depth")
        check(f.colorModeData == PSDHDRToning.defaultData(), "HDR toning colour mode data")
        for id: UInt16 in [1005, 1057] { check(f.resource(id) != nil, "resource \(id) missing") }
        check(f.hasRealMergedData == true, "1057 real merged data")
        // Merged image: raw big-endian IEEE floats, finite.
        check(f.imageData.compression == .raw, "merged compression \(f.imageData.compression)")
        let n = Int(f.header.width) * Int(f.header.height) * Int(f.header.channels)
        check(f.imageData.data.count == n * 4, "merged size \(f.imageData.data.count) for \(n * 4)")
        check(PSDSamples.f32([UInt8](f.imageData.data)).allSatisfy(\.isFinite), "non-finite merged sample")
        if f.layers.isEmpty { return p }
        // Layers live in an `Lr32` global block; the classic layer info is empty.
        if case let .globalBlock(_, signature, key, _, _) = f.layerInfoPlacement {
            check(key == "Lr32" && signature == "8BIM", "placement \(signature.string) \(key.string)")
        } else {
            p.append("\(name): placement \(f.layerInfoPlacement)")
        }
        if let (li, keys) = rawLayerSection(bytes) {
            check(li == 0, "classic layer info length \(li)")
            check(keys.first == "Lr32", "global blocks \(keys)")
        } else {
            p.append("\(name): no layer section")
        }
        // Channel data: raw or ZIP (RLE is not valid for 32-bit samples), decodable.
        for (i, rec) in f.layers.enumerated() {
            for ch in rec.channels {
                let c = ch.compression ?? .raw
                check([.raw, .zip, .zipPrediction].contains(c), "layer \(i) channel \(ch.id) uses \(c)")
                do { _ = try rec.decodeChannel(ch.id, depth: 32, version: f.header.version) } catch { p.append("\(name): layer \(i) channel \(ch.id): \(error)") }
            }
        }
        p += PSDKit.strictBlockErrors(bytes).map { "\(name): \($0)" }
        return p
    }

    static func exportPSD(_ d: Document, _ photoshop: Bool) throws -> [UInt8] {
        try PSDKit.export(d, "t.psd", PSDKit.options(photoshop)).bytes
    }

    @Test(arguments: PSDKit.conventions) func flat32BitExportLayout(_ photoshop: Bool) throws {
        for mode in [ColorMode.rgb, .grayscale] {
            let d = Document(name: "flat", size: PixelSize(width: 9, height: 7), mode: mode, depth: .f32)
            let p = PSD32ExportTests.layoutProblems("flat \(mode)", try PSD32ExportTests.exportPSD(d, photoshop))
            #expect(p.isEmpty, "\(p)")
        }
    }

    @Test(arguments: PSDKit.conventions) func layered32BitExportLayout(_ photoshop: Bool) throws {
        for mode in [ColorMode.rgb, .grayscale] {
            for (label, features) in [("pixels", Features.pixels), ("all", Features.all)] {
                let d = genDoc(mode, .f32, features)
                let p = PSD32ExportTests.layoutProblems("\(mode) \(label)", try PSD32ExportTests.exportPSD(d, photoshop))
                #expect(p.isEmpty, "\(p.prefix(6))")
            }
        }
    }

    @Test(arguments: PSDKit.conventions) func only32BitExportsCarryToningData(_ photoshop: Bool) throws {
        for depth in [SampleType.u8, .u16] {
            let f = try PSDFile(bytes: try PSD32ExportTests.exportPSD(genDoc(.rgb, depth, .pixels), photoshop))
            #expect(f.colorModeData.isEmpty, "\(depth)")
        }
    }

    @Test(arguments: PSDKit.conventions) func layered32BitExportReimportsRenderEqual(_ photoshop: Bool) throws {
        for mode in [ColorMode.rgb, .grayscale] {
            let d = genDoc(mode, .f32, .all)
            let back = try PSDKit.importFile("t.psd", try PSD32ExportTests.exportPSD(d, photoshop), photoshop: photoshop).document
            let (a, b) = (try PSDKit.flatten(d), try PSDKit.flatten(back))
            #expect(a.count == b.count)
            let m = PSDKit.maxDiff(a, b)
            #expect(m <= 1e-4, "\(mode): render differs by \(m)")
        }
    }

    // Independent float merged planes: using the RGBA8 preview as the oracle silently clips these
    // samples, even though Photoshop stores the full range.
    @Test func mergedOraclePreservesSignedHDRSamples() throws {
        let values: [Float] = [-0.125, 0.123456, 4]
        for mode in [ColorMode.rgb, .grayscale] {
            for alpha: Float in [1, 0.5] {
                let d = Document(name: "float merged", size: PixelSize(width: 3, height: 1), mode: mode, depth: .f32)
                var file = try PSDFile(bytes: try PSD32ExportTests.exportPSD(d, true))
                let cc: UInt16 = mode == .rgb ? 3 : 1
                file.layerInfo = nil
                file.header.channels = cc + (alpha != 1 ? 1 : 0)
                file.imageData.compression = .raw
                // Photoshop's merged pixels are matted against white when alpha is present.
                var samples: [Float] = []
                for _ in 0 ..< cc { samples += values.map { $0 * alpha + 1 - alpha } }
                if alpha != 1 { samples += [alpha, alpha, alpha] }
                file.imageData.data = Data(PSDSamples.bytes(f32: samples))
                let pixels = try MergedImage.composite(file)
                #expect(pixels.count == 3)
                for (p, value) in zip(pixels, values) {
                    let want = SIMD4(value, value, value, alpha)
                    #expect((0 ..< 4).allSatisfy { abs(p[$0] - want[$0]) < 1e-6 }, "\(mode), alpha \(alpha): \(p)")
                }
            }
        }
    }

    @Test func mergedOracleDoesNotTreatExtraChannelsAsTransparency() throws {
        for mode in [ColorMode.rgb, .grayscale] {
            let d = Document(name: "extra channel", size: PixelSize(width: 1, height: 1), mode: mode, depth: .f32)
            var file = try PSDFile(bytes: try PSD32ExportTests.exportPSD(d, true))
            let cc: UInt16 = mode == .rgb ? 3 : 1
            file.header.channels = cc + 1
            file.layerInfo = PSDLayerInfo(mergedAlpha: false, layers: [], padding: nil)
            file.imageData.compression = .raw
            file.imageData.data = Data(PSDSamples.bytes(f32: [Float](repeating: 2, count: Int(cc)) + [0]))
            #expect(!file.mergedHasAlpha)
            #expect(try MergedImage.composite(file) == [SIMD4<Float>(2, 2, 2, 1)], "\(mode)")
        }
    }
}
