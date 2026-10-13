// Real Photoshop-authored corpus (read from PCPSD_CORPUS; skipped when absent): byte-stable rewrite,
// lazy channel decode, typed parsers, and the merged composite against macOS ImageIO.
// Mirrors photocraft-psd tests/corpus.rs (MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors), with the third-party ImageIO oracle photocraft lacks (FILE-216-4).

import Foundation
import Testing
@testable import PCPSD

@Suite(.enabled(if: Corpus.directory != nil, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)"))
struct CorpusTests {
    @Test func everyFileRewritesByteForByte() throws {
        var stable = 0
        for url in Corpus.files {
            let data = try Data(contentsOf: url)
            let f = try PSDFile(data: data)
            let out = try f.serialized()
            #expect(out == data, "\(url.lastPathComponent): rewrite differs")
            if out == data { stable += 1 }
            #expect(try PSDFile(data: out) == f)
        }
        print("CORPUS byte-stable rewrite: \(stable)/\(Corpus.files.count)")
    }

    @Test func everyChannelDecodes() throws {
        var channels = 0
        for url in Corpus.files {
            let f = try PSDFile(contentsOf: url)
            for (i, l) in f.layers.enumerated() {
                for c in l.channels {
                    _ = try l.decodeChannel(c.id, depth: f.header.depth, version: f.header.version)
                    channels += 1
                }
                _ = try f.layer(i)!.rgba8()
                if let m = f.layer(i)!.userMask() { _ = try m.get() }
            }
            _ = try f.decodeMerged()
            #expect(f.warnings.isEmpty, "\(url.lastPathComponent): \(f.warnings)")
        }
        print("CORPUS decoded \(channels) layer channels")
    }

    @Test func compositeMatchesImageIO() throws {
        var worst = 0
        var exact = 0
        var unmatteWorst = 0
        var lines: [String] = []
        for url in Corpus.files {
            let data = try Data(contentsOf: url)
            let f = try PSDFile(data: data)
            let ours = try f.compositeRGBA8(unmatte: false)
            guard let oracle = ImageIOOracle.decode(data) else {
                Issue.record("ImageIO could not decode \(url.lastPathComponent)")
                continue
            }
            let (d, interp) = ImageIOOracle.compare(stored: ours, unmatted: try f.compositeRGBA8(), oracle: oracle)
            worst = max(worst, d)
            if d == 0 { exact += 1 }
            lines.append("  \(d)\t\(interp.rawValue)\t\(url.lastPathComponent.suffix(48))\t\(oracle.description)")
            #expect(d <= 1, "\(url.lastPathComponent): max difference \(d) [\(oracle.description)]")
            unmatteWorst = max(unmatteWorst, ImageIOOracle.maxDifference(ours: try f.compositeRGBA8(), oracle: oracle, premultiply: oracle.hasAlpha))
        }
        print("CORPUS ImageIO keeps the white matte: our matte-removed composite differs by up to \(unmatteWorst)")
        print("CORPUS ImageIO composite: \(exact)/\(Corpus.files.count) exact, worst max-channel difference \(worst)")
        for l in lines { print(l) }
    }

    @Test func typedViewsParse() throws {
        var blocks = 0, typed = 0, structural = 0
        var resources = 0, typedResources = 0
        var failures: [String] = []
        for url in Corpus.files {
            let f = try PSDFile(contentsOf: url)
            for b in f.layers.flatMap(\.blocks) + f.globalBlocks {
                blocks += 1
                do {
                    if try b.parsed() != nil { typed += 1 }
                    try b.checkStructure()
                    structural += 1
                } catch {
                    failures.append("\(url.lastPathComponent) \(b.key): \(error)")
                }
            }
            for r in f.resources {
                resources += 1
                do {
                    if try r.parsed() != nil { typedResources += 1 }
                } catch {
                    failures.append("\(url.lastPathComponent) resource \(r.id): \(error)")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(10))")
        print("CORPUS blocks \(blocks) (simple-typed \(typed), structure-checked \(structural)); resources \(resources) (typed \(typedResources))")
    }

    /// The builder's record conventions are the ones Photoshop itself writes: every builder record
    /// shape (flags, blending-range size, lsct size, block order) occurs in the corpus.
    @Test func builderRecordsMatchPhotoshopConventions() throws {
        func shape(_ r: PSDLayerRecord) -> String {
            let keys = r.blocks.map(\.key.string).filter { !["shmd", "lyvr", "sn2P"].contains($0) }
            return "\(r.kind) flags=\(r.flags.rawValue) br=\(r.blendingRanges.data.count) lsct=\(r.block("lsct")?.data.count ?? 0) lnsr=\(r.block("lnsr").map { FourCC(bytes: $0.data).string } ?? "-") keys=\(keys)"
        }
        var photoshop = Set<String>()
        for url in Corpus.files {
            let f = try PSDFile(contentsOf: url)
            guard f.header.colorMode == .rgb else { continue }
            for r in f.layers { photoshop.insert(shape(r)) }
        }
        var b = PSDBuilder(width: 2, height: 2)
        b.pushLayer(PSDLayerSpec(name: "a", left: 0, top: 0, width: 1, height: 1, pixels: .u8([1, 2, 3, 255])))
        var hidden = PSDLayerSpec(name: "b", left: 0, top: 0, width: 1, height: 1, pixels: .u8([1, 2, 3, 255]))
        hidden.visible = false
        b.pushLayer(hidden)
        try b.pushGroup(PSDGroupSpec(name: "open")) { $0.pushLayer(PSDLayerSpec(name: "c", left: 0, top: 0, width: 1, height: 1, pixels: .u8([1, 2, 3, 255]))) }
        var closed = PSDGroupSpec(name: "closed")
        closed.open = false
        closed.visible = false
        try b.pushGroup(closed) { _ in }
        let built = try PSDFile(data: b.build().serialized())
        let missing = built.layers.map(shape).filter { !photoshop.contains($0) }
        #expect(missing.isEmpty, "builder record shapes not seen in Photoshop files: \(missing)")
        print("CONVENTIONS builder record shapes all seen in corpus: \(built.layers.count) records, \(photoshop.count) Photoshop shapes")
    }
}
