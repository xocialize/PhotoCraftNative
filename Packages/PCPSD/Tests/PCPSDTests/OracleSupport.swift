// Third-party oracle: macOS ImageIO reads (and writes) PSD. Helpers to decode a file through
// ImageIO into raw 8-bit samples without colour conversion, and to locate the test corpus (under
// the fixtures root, `Fixtures.swift`).

import CoreGraphics
import Foundation
import ImageIO
@testable import PCPSD

enum Corpus {
    /// The Unity corpus (36 Photoshop PSDs): `PCPSD_CORPUS`, default `<fixtures>/psd-corpus`.
    static var directory: URL? { Fixtures.directory("PCPSD_CORPUS", default: "psd-corpus") }

    /// The oracle's data (sweep reports and the export snapshots it judged): `PCPSD_PS_ORACLE`,
    /// default `<fixtures>/ps-oracle`.
    static var psOracle: URL? { Fixtures.directory("PCPSD_PS_ORACLE", default: "ps-oracle") }

    static var files: [URL] {
        guard let dir = directory, let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { ["psd", "psb"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Where generated fixtures are saved for the Photoshop oracle: only when `PCPSD_FIXTURES` is set
    /// (`$PHOTOCRAFT_FIXTURES/pcpsd-fixtures` refreshes the kept set). Unset, nothing is saved.
    static let fixtureDirectory: URL? = {
        guard let p = ProcessInfo.processInfo.environment["PCPSD_FIXTURES"], !p.isEmpty else { return nil }
        let url = URL(fileURLWithPath: p)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Saves a generated fixture when `PCPSD_FIXTURES` is set.
    static func saveFixture(_ data: Data, as name: String) throws {
        guard let dir = fixtureDirectory else { return }
        try data.write(to: dir.appendingPathComponent(name))
    }

    /// A folder for files a test must put on disk: `PCPSD_FIXTURES` when set (so they are saved as
    /// fixtures too), else a temporary folder (never the repo or the fixtures root).
    static var workDirectory: URL {
        if let dir = fixtureDirectory { return dir }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pcpsd-fixtures")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// The Photoshop-authored oracle corpus: 153 files written by Photoshop 27.11 for this port, with
/// `manifest.json` listing each file's features. Opt-in, separate from the Unity corpus:
/// `PCPSD_PS_CORPUS`, default `<fixtures>/ps-corpus`; tests skip when it is absent.
enum PSCorpus {
    static var directory: URL? { Fixtures.directory("PCPSD_PS_CORPUS", default: "ps-corpus") }

    static var files: [URL] {
        guard let dir = directory, let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { ["psd", "psb"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// File name → features (`effect:colorOverlay`, `mask:vector`, `depth:16`, …) from `manifest.json`.
    static var features: [String: Set<String>] {
        guard let dir = directory, let data = FileManager.default.contents(atPath: dir.appendingPathComponent("manifest.json").path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let files = json["files"] as? [[String: Any]] else { return [:] }
        var out: [String: Set<String>] = [:]
        for f in files {
            guard let name = f["file"] as? String else { continue }
            out[name] = Set((f["features"] as? [String]) ?? [])
        }
        return out
    }

    static func url(_ name: String) -> URL? { directory?.appendingPathComponent(name) }
}

struct OracleImage {
    var width: Int
    var height: Int
    /// Interleaved samples as ImageIO delivers them (no colour conversion), 8 bits per sample.
    var samples: [UInt8]
    var samplesPerPixel: Int
    var hasAlpha: Bool
    var alphaPremultiplied: Bool
    var colorModel: CGColorSpaceModel
    var bitsPerComponent: Int
    var description: String
}

enum ImageIOOracle {
    /// The composite ImageIO decodes, as 8-bit samples in the image's own colour space.
    static func decode(_ data: Data) -> OracleImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        let model = img.colorSpace?.model ?? .unknown
        let alphaInfo = img.alphaInfo
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(alphaInfo)
        let desc = "label \(alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast ? "premultiplied" : "straight") bpc \(img.bitsPerComponent) bpp \(img.bitsPerPixel) alpha \(alphaInfo.rawValue) model \(model.rawValue) order \(img.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue) float \(img.bitmapInfo.contains(.floatComponents))"
        if let direct = readDirect(img, model: model, hasAlpha: hasAlpha, description: desc) { return direct }
        // Redraw into a known layout in the same colour space (an identity conversion).
        let cc: Int
        switch model {
        case .monochrome: cc = 1
        case .cmyk: cc = 4
        default: cc = 3
        }
        guard let space = img.colorSpace else { return nil }
        let spp = cc + (hasAlpha ? 1 : 0)
        var buf = [UInt8](repeating: 0, count: w * h * max(spp, cc == 3 ? 4 : spp))
        let bpr: Int
        let info: UInt32
        if cc == 3 {
            bpr = w * 4
            info = hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        } else if cc == 1 {
            bpr = w * (hasAlpha ? 2 : 1)
            info = hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.none.rawValue
        } else {
            bpr = w * 4
            info = CGImageAlphaInfo.none.rawValue
        }
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: space, bitmapInfo: info) else { return false }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        let outSpp = cc == 3 ? 4 : (cc == 1 && hasAlpha ? 2 : cc)
        return OracleImage(width: w, height: h, samples: Array(buf.prefix(w * h * outSpp)), samplesPerPixel: outSpp, hasAlpha: hasAlpha,
                           alphaPremultiplied: hasAlpha, colorModel: model, bitsPerComponent: img.bitsPerComponent, description: desc)
    }

    /// Reads 8/16-bit integer RGB(A)/Gray(A) provider bytes as they are. ImageIO always delivers
    /// PSD colour premultiplied by the stored alpha but labels it inconsistently (premultiplied for
    /// Photoshop files carrying IPTC 1028 + print info 1082, straight otherwise), so the samples are
    /// read directly instead of being redrawn (which would premultiply a second time).
    static func readDirect(_ img: CGImage, model: CGColorSpaceModel, hasAlpha: Bool, description: String) -> OracleImage? {
        guard model == .rgb || model == .monochrome, img.bitsPerComponent == 8 || img.bitsPerComponent == 16,
              !img.bitmapInfo.contains(.floatComponents), let data = img.dataProvider?.data as Data? else { return nil }
        let cc = model == .rgb ? 3 : 1
        let bps = img.bitsPerComponent / 8
        let comps = img.bitsPerPixel / img.bitsPerComponent
        let ai = img.alphaInfo
        let alphaFirst = ai == .premultipliedFirst || ai == .first || ai == .noneSkipFirst
        let order = img.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        let little16 = order == CGBitmapInfo.byteOrder16Little.rawValue
        let little32 = order == CGBitmapInfo.byteOrder32Little.rawValue
        guard comps == cc || comps == cc + 1, !little32 else { return nil }
        let w = img.width, h = img.height
        let outSpp = cc == 3 ? 4 : (hasAlpha ? 2 : 1)
        var out = [UInt8](repeating: 255, count: w * h * outSpp)
        let bytes = [UInt8](data)
        func sample(_ at: Int) -> UInt8 {
            if bps == 1 { return bytes[at] }
            let v = little16 ? UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 : UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
            return UInt8((UInt32(v) * 255 + 32767) / 65535)
        }
        for y in 0 ..< h {
            for x in 0 ..< w {
                let base = y * img.bytesPerRow + x * comps * bps
                let colorStart = (comps == cc + 1 && alphaFirst) ? 1 : 0
                for k in 0 ..< cc { out[(y * w + x) * outSpp + k] = sample(base + (colorStart + k) * bps) }
                if hasAlpha {
                    let ai = alphaFirst ? 0 : cc
                    out[(y * w + x) * outSpp + outSpp - 1] = sample(base + ai * bps)
                }
            }
        }
        return OracleImage(width: w, height: h, samples: out, samplesPerPixel: outSpp, hasAlpha: hasAlpha, alphaPremultiplied: hasAlpha,
                           colorModel: model, bitsPerComponent: img.bitsPerComponent, description: description + " direct")
    }

    /// How ImageIO presented the alpha of a decoded composite.
    enum Interpretation: String, CaseIterable {
        /// Stored colour, straight alpha (ImageIO at 16/32 bits).
        case storedStraight = "stored straight"
        /// Stored colour premultiplied by alpha (ImageIO 8-bit RGB, whatever the alpha label says).
        case storedPremultiplied = "stored premultiplied"
        /// White matte removed, premultiplied (ImageIO 8-bit gray).
        case unmattedPremultiplied = "unmatted premultiplied"
    }

    /// Smallest max per-channel difference between ImageIO's samples and one of the interpretations
    /// of our decode (`stored`: the composite as stored; `unmatted`: white matte removed).
    static func compare(stored: PSDRGBA8Image, unmatted: PSDRGBA8Image, oracle: OracleImage) -> (Int, Interpretation) {
        var best = (Int.max, Interpretation.storedStraight)
        for interp in Interpretation.allCases {
            if !oracle.hasAlpha, interp != .storedStraight { continue }
            let ours = interp == .unmattedPremultiplied ? unmatted : stored
            let d = maxDifference(ours: ours, oracle: oracle, premultiply: interp != .storedStraight)
            if d < best.0 { best = (d, interp) }
        }
        return best
    }

    static func maxDifference(ours: PSDRGBA8Image, oracle: OracleImage, premultiply: Bool) -> Int {
        guard ours.width == oracle.width, ours.height == oracle.height else { return 255 }
        var worst = 0
        let n = ours.width * ours.height
        for i in 0 ..< n {
            let a = Int(ours.data[i * 4 + 3])
            func v(_ k: Int) -> Int {
                let c = Int(ours.data[i * 4 + k])
                return premultiply ? (c * a + 127) / 255 : c
            }
            switch oracle.samplesPerPixel {
            case 4:
                // Colour of fully transparent pixels is unspecified.
                if oracle.hasAlpha, a == 0, Int(oracle.samples[i * 4 + 3]) == 0 { continue }
                for k in 0 ..< 3 { worst = max(worst, abs(v(k) - Int(oracle.samples[i * 4 + k]))) }
                if oracle.hasAlpha { worst = max(worst, abs(a - Int(oracle.samples[i * 4 + 3]))) }
            case 2:
                if a == 0, Int(oracle.samples[i * 2 + 1]) == 0 { continue }
                worst = max(worst, abs(v(0) - Int(oracle.samples[i * 2])), abs(a - Int(oracle.samples[i * 2 + 1])))
            case 1:
                worst = max(worst, abs(v(0) - Int(oracle.samples[i])))
            default:
                return 255
            }
        }
        return worst
    }
}
