// Diagnostics for the acceptance failures (opt-in): rewrite a rejected PCPSD file in controlled
// variants so Photoshop can tell which difference it objects to. Run with
//   PSO_VARIANTS_OUT=<dir under the scratch root> swift test --filter DebugTests
// then `ps-oracle accept <dir>`.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import PCPSD
@testable import PSOracleKit

@Suite struct DebugTests {
    static let fixtures = Fixtures.path + "/pcpsd-fixtures"

    static func variants(of name: String, into out: URL) throws {
        let f = try PSDFile(contentsOf: URL(fileURLWithPath: fixtures + "/" + name))
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard case let .globalBlock(_, sig, key, pad, over) = f.layerInfoPlacement, var info = f.layerInfo else { return }
        let matte = f.globalBlocks.filter { $0.key.string.hasPrefix("Mt") }
        let others = f.globalBlocks.filter { !$0.key.string.hasPrefix("Mt") }
        func write(_ tag: String, _ g: PSDFile) throws {
            try g.write(to: out.appendingPathComponent("\(stem)--\(tag).\(ext)"))
        }
        // A: Photoshop's block order (matte block first), count still negative.
        var a = f
        a.globalBlocks = matte + others
        a.layerInfoPlacement = .globalBlock(index: matte.count, signature: sig, key: key, padding: pad, longLengthOverride: over)
        try write("A-matte-first", a)
        // B: positive layer count, original order.
        var b = f
        info.mergedAlpha = false
        b.layerInfo = info
        try write("B-positive-count", b)
        // C: both — Photoshop's layout.
        var c = a
        c.layerInfo = info
        try write("C-matte-first-positive", c)
        // D: no matte block, negative count.
        var d = f
        d.globalBlocks = others
        d.layerInfoPlacement = .globalBlock(index: 0, signature: sig, key: key, padding: pad, longLengthOverride: over)
        try write("D-no-matte", d)
        // E: no matte block, positive count.
        var e = d
        e.layerInfo = info
        try write("E-no-matte-positive", e)
    }

    /// Merged-only TestGen files: add the HDR toning colour-mode data, drop the stand-in ICC/path resources.
    static func mergedOnlyVariants(of name: String, into out: URL) throws {
        let f = try PSDFile(contentsOf: URL(fileURLWithPath: fixtures + "/" + name))
        let stem = (name as NSString).deletingPathExtension
        var a = f
        a.colorModeData = PSDHDRToning.colorModeData(depth: f.header.depth)
        try a.write(to: out.appendingPathComponent("\(stem)--F-hdrt.psd"))
        var b = f
        b.resources.removeAll { $0.id == 1039 || $0.id == 2000 }
        try b.write(to: out.appendingPathComponent("\(stem)--G-no-icc-path.psd"))
        var c = a
        c.resources = b.resources
        try c.write(to: out.appendingPathComponent("\(stem)--H-hdrt-no-icc-path.psd"))
    }

    /// Duotone colour-mode data in the `.ado` (Duotone Options) layout: version 1, plate count, four
    /// colour records, four Pascal names (64 bytes), four 13-point transfer curves (0…1000, −1 unset),
    /// dot gain, eleven overprint colours.
    static func duotoneData(inks: [(String, [UInt16])]) -> Data {
        var d = Data()
        func u16(_ v: Int) { d.append(UInt8(v >> 8 & 0xFF)); d.append(UInt8(v & 0xFF)) }
        u16(1)
        u16(inks.count)
        for i in 0 ..< 4 {
            u16(0) // RGB colour space
            let c = i < inks.count ? inks[i].1 : [0, 0, 0]
            for k in 0 ..< 4 { u16(k < 3 ? Int(c[k]) : 0) }
        }
        for i in 0 ..< 4 {
            let name = Array((i < inks.count ? inks[i].0 : "").utf8.prefix(63))
            var block = [UInt8(name.count)] + name
            block += [UInt8](repeating: 0, count: 64 - block.count)
            d.append(contentsOf: block)
        }
        for _ in 0 ..< 4 { for p in 0 ..< 13 { u16(p == 0 ? 0 : p == 12 ? 1000 : 0xFFFF) } }
        u16(20)
        for _ in 0 ..< 11 { u16(0); for _ in 0 ..< 4 { u16(0) } }
        return d
    }

    static func duotoneVariants(into out: URL) throws {
        let ado = duotoneData(inks: [("Black", [0, 0, 0]), ("PSO Orange", [61680, 30840, 5140])])
        var f = try PSDFile(contentsOf: URL(fileURLWithPath: fixtures + "/merged-Duotone-8.psd"))
        f.colorModeData = ado
        try f.write(to: out.appendingPathComponent("merged-Duotone-8--I-ado.psd"))
        // A fresh merged-only duotone: a horizontal ramp.
        let (w, h) = (64, 16)
        let header = PSDHeader(version: .psd, width: UInt32(w), height: UInt32(h), channels: 1, depth: 8, colorMode: .duotone)
        let plane = (0 ..< w * h).map { UInt8(($0 % w) * 255 / (w - 1)) }
        let img = try PSDImageData.encode(.rle, decoded: plane, header: header)
        let g = PSDFile(header: header, colorModeData: ado, resources: [PSDVersionInfo.resource(hasRealMergedData: true)], imageData: img)
        try g.write(to: out.appendingPathComponent("duotone-ado-ramp.psd"))
    }

    @Test(.enabled(if: Fixtures.optIn("PSO_DUOTONE_OUT"), Fixtures.reason("PSO_DUOTONE_OUT"))) func writeDuotone() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PSO_DUOTONE_OUT"]!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Self.duotoneVariants(into: out)
    }

    @Test(.enabled(if: Fixtures.optIn("PSO_VARIANTS_OUT"), Fixtures.reason("PSO_VARIANTS_OUT"))) func writeVariants() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PSO_VARIANTS_OUT"]!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for n in ["builder-RGB-16-psd-RLE-partial.psd", "builder-RGB-32-psd-RLE-partial.psd", "builder-Grayscale-16-psb-ZIP-partial.psb"] {
            try Self.variants(of: n, into: out)
        }
        for n in ["merged-RGB-32.psd", "merged-Grayscale-32.psd"] { try Self.mergedOnlyVariants(of: n, into: out) }
    }

    /// Where PCPSD's compact EngineData rewrite of a `Txt2` block first differs from Photoshop's bytes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PSO_TXT2_FILE"] != nil)) func txt2Difference() throws {
        let f = try PSDFile(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["PSO_TXT2_FILE"]!))
        guard let b = f.globalBlocks.first(where: { $0.key == "Txt2" }) else { Issue.record("no Txt2"); return }
        let orig = [UInt8](b.data)
        let out = [UInt8](try PSDEngineData.parseBare(b.data).serializedCompactBare())
        let n = min(orig.count, out.count)
        let first = (0 ..< n).first { orig[$0] != out[$0] } ?? n
        func show(_ a: [UInt8], _ at: Int) -> String {
            let lo = max(0, at - 60), hi = min(a.count, at + 60)
            return String(decoding: a[lo ..< hi].map { $0 < 0x20 || $0 > 0x7E ? UInt8(ascii: ".") : $0 }, as: UTF8.self)
        }
        print("TXT2 photoshop \(orig.count) bytes, rewrite \(out.count) bytes, first difference at \(first)")
        print("TXT2 photoshop: \(show(orig, first))")
        print("TXT2 rewrite:   \(show(out, first))")
        print("TXT2 photoshop bytes at diff: \(orig[first ..< min(orig.count, first + 16)].map { String(format: "%02x", $0) }.joined(separator: " "))")
        print("TXT2 rewrite bytes at diff:   \(out[first ..< min(out.count, first + 16)].map { String(format: "%02x", $0) }.joined(separator: " "))")
    }

    /// ImageIO (an independent decoder) against PCPSD on a corpus file's merged image.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PSO_IMAGEIO_FILE"] != nil)) func mergedAgreesWithImageIO() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PSO_IMAGEIO_FILE"]!)
        let f = try PSDFile(contentsOf: url)
        let ours = try PixelCompare.mergedPlanes(f)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let data = img.dataProvider?.data as Data? else { Issue.record("ImageIO cannot decode"); return }
        let bytes = [UInt8](data)
        let bpc = img.bitsPerComponent, spp = img.bitsPerPixel / bpc, w = img.width
        var worst = 0.0
        for y in 0 ..< img.height {
            for x in 0 ..< w {
                for c in 0 ..< 3 {
                    let o = y * img.bytesPerRow + (x * spp + c) * bpc / 8
                    let v = bpc == 16 ? Double(Int(bytes[o]) | Int(bytes[o + 1]) << 8) : Double(bytes[o])
                    worst = max(worst, abs(v - ours[c][y * w + x]))
                }
            }
        }
        print("IMAGEIO vs PCPSD merged: \(img.bitsPerComponent)-bit order \(img.bitmapInfo.rawValue), worst difference \(worst) (native units)")
    }

    /// PCIO's rejected gradient-map files: which change to the `grdm` block makes Photoshop accept them?
    @Test(.enabled(if: Fixtures.optIn("PSO_GRDM_FILE"), Fixtures.reason("PSO_GRDM_FILE"))) func gradientMapVariants() throws {
        let env = ProcessInfo.processInfo.environment
        let src = URL(fileURLWithPath: env["PSO_GRDM_FILE"]!)
        let out = URL(fileURLWithPath: env["PSO_GRDM_OUT"]!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let f = try PSDFile(contentsOf: src)
        let photoshop = try PSDFile(contentsOf: URL(fileURLWithPath: Fixtures.path + "/ps-corpus/adj-gradientMap.psd"))
        let psBlock = try #require(photoshop.layers.compactMap { $0.block("grdm") }.first)
        func variant(_ tag: String, _ edit: (inout [UInt8]) -> Void) throws {
            var g = f
            for i in g.layers.indices {
                guard var b = g.layers[i].block("grdm") else { continue }
                var d = [UInt8](b.data)
                edit(&d)
                b.data = Data(d)
                g.layers[i].setBlock(b)
            }
            try g.write(to: out.appendingPathComponent("grdm-\(tag).psd"))
        }
        try variant("v1-padded-to-4") { d in d += [UInt8](repeating: 0, count: (4 - d.count % 4) % 4) }
        try variant("v3-smoo") { d in d[1] = 3; d.insert(contentsOf: Array("Smoo".utf8), at: 4) }
        // v3 + Smoo + Photoshop's smoothness (4096): the 40-byte tail starts with the expansion
        // count (2), then the smoothness.
        try variant("v3-smoo-smooth4096") { d in
            d[1] = 3
            d.insert(contentsOf: Array("Smoo".utf8), at: 4)
            let tail = d.count - 40
            d[tail + 2] = 0x10
            d[tail + 3] = 0x00
        }
        try variant("photoshop-block") { d in d = [UInt8](psBlock.data) }
        try variant("v1-not-reversed") { d in d[2] = 0 }
        try variant("v3-smoo-not-reversed") { d in d[1] = 3; d[2] = 0; d.insert(contentsOf: Array("Smoo".utf8), at: 4) }
    }

    /// A refused PCIO pattern-fill export: without its pattern data block, and without its pattern-fill layer.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PSO_PATTERN_FILE"] != nil)) func patternVariants() throws {
        let env = ProcessInfo.processInfo.environment
        let f = try PSDFile(contentsOf: URL(fileURLWithPath: env["PSO_PATTERN_FILE"]!))
        let out = URL(fileURLWithPath: env["PSO_PATTERN_OUT"]!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var a = f
        a.globalBlocks.removeAll { ["Patt", "Pat2", "Pat3"].contains($0.key.string) }
        try a.write(to: out.appendingPathComponent("pattern-no-pattern-block.psd"))
        var b = f
        guard var info = b.layerInfo else { return }
        info.layers.removeAll { $0.block("PtFl") != nil }
        try info.pad(to: 4, version: f.header.version)
        b.layerInfo = info
        try b.write(to: out.appendingPathComponent("pattern-no-fill-layer.psd"))
    }

    /// PCIO's Indexed→RGB / Bitmap→Gray re-export: is its merged image or its layer the wrong one?
    /// Both against Photoshop's original composite (decoded through the palette / bits by PCPSD).
    @Test(.enabled(if: Fixtures.optIn("PSO_REEXPORT_DIAG"), Fixtures.reason("PSO_REEXPORT_DIAG"))) func reexportModeConversion() throws {
        let scr = Fixtures.path
        for name in ["mode-indexed-8", "mode-bitmap-1"] {
            let orig = try PSDFile(contentsOf: URL(fileURLWithPath: scr + "/ps-corpus/\(name).psd"))
            let re = try PSDFile(contentsOf: URL(fileURLWithPath: scr + "/ps-oracle/pcio-snapshot/\(name).psd.reexport.psd"))
            let truth = PSDRender.rgba8(try orig.normalizedComposite())
            let merged = try re.compositeRGBA8(unmatte: false).data
            let layer = try re.layer(0).map { try $0.rgba8() }
            var worstMerged = 0, worstLayer = 0
            for i in 0 ..< truth.count / 4 { for k in 0 ..< 3 { worstMerged = max(worstMerged, abs(Int(truth[i * 4 + k]) - Int(merged[i * 4 + k]))) } }
            if let l = layer, l.width == Int(orig.header.width), l.height == Int(orig.header.height) {
                for i in 0 ..< truth.count / 4 { for k in 0 ..< 3 { worstLayer = max(worstLayer, abs(Int(truth[i * 4 + k]) - Int(l.data[i * 4 + k]))) } }
            }
            print("REEXPORT \(name): re-export is \(PCPSDFacts.modeName(re.header.colorMode)) \(re.header.depth)-bit, \(re.layers.count) record(s); vs Photoshop's original composite: merged image worst \(worstMerged), layer 0 worst \(layer == nil ? "-" : String(worstLayer)) (rect \(re.layers.first?.rect.description ?? "-"))")
        }
    }

    /// How Photoshop stored the Satin contour of the corpus file (built by naming the preset only).
    @Test(.enabled(if: Fixtures.optIn("PSO_SATIN_DIAG"), Fixtures.reason("PSO_SATIN_DIAG"))) func satinContourAsStored() throws {
        let f = try PSDFile(contentsOf: URL(fileURLWithPath: Fixtures.path + "/ps-corpus/fx-satin.psd"))
        for r in f.layers {
            guard let fx = r.objectEffects else { continue }
            for e in fx.effects where e.key == "ChFX" {
                print("SATIN keys: \(e.descriptor.items.map(\.key.name))")
                if let c = e.descriptor.descriptor("MpgS") { print("SATIN MpgS: \(c)") }
            }
        }
    }
}
