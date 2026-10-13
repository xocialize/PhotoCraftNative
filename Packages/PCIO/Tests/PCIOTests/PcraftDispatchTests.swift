// `.pcraft` through the import/export dispatch: every mode and depth, the previews written next
// to the document, and the Photoshop corpus carried through `.pcraft` unchanged.
// Port of photocraft-io's `.pcraft` dispatch (crates/io/src/lib.rs `export`/`import`), MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFormat
import PCFoundation
import PCIOCore
import PCPSD
import Testing
@testable import PCIO

@Suite struct PcraftDispatchTests {
    init() { ExportSweep.install() }
    static let cases: [(ColorMode, SampleType)] = [(.rgb, .u8), (.rgb, .u16), (.rgb, .f32), (.grayscale, .u8), (.grayscale, .f32), (.cmyk, .u8), (.cmyk, .u16), (.lab, .u16)]

    @Test(arguments: cases.indices) func everyModeRoundTripsThroughPcraft(_ i: Int) throws {
        let (mode, depth) = Self.cases[i]
        let d = genDoc(mode, depth, .all)
        let r = try DocumentIO.export(d, as: "x.pcraft", options: IOOptions(compositor: StoredPixelsCompositor()))
        #expect(PcraftFormat.isPcraft(r.bytes))
        let back = try DocumentIO.importFile(name: "x.pcraft", bytes: r.bytes).document
        expectDocsEqual(d, back, "\(mode) \(depth)")
        #expect(back.name == d.name)
    }

    @Test func previewsAreWrittenAtTheirSizes() throws {
        var d = Document(name: "p", size: PixelSize(width: 2048, height: 512), mode: .rgb, depth: .u8)
        var l = Layer.raster("a", format: d.pixelFormat)
        l.withRaster { $0.fill(PixelRect(x0: 0, y0: 0, x1: 2048, y1: 512), with: [0, 0, 1, 1]) }
        d.layers = [l]
        let r = try DocumentIO.export(d, as: "big.pcraft", options: IOOptions(compositor: StoredPixelsCompositor()))
        let thumb = try #require(try PcraftFormat.readThumbnail(r.bytes))
        let img = try ImageIOCodec().decode(thumb)
        #expect(max(img.width, img.height) == 256)
        #expect(img.width == 256 && img.height == 64)
        let manifest = try PcraftFormat.readManifest(r.bytes)
        #expect(manifest.composite != nil)
    }

    @Test func malformedBundlesKeepTheirFormatError() {
        // A declared `.pcraft` reaches the loader, which names the problem.
        #expect {
            try DocumentIO.importFile(name: "broken.pcraft", bytes: Array("PK\u{3}\u{4}garbage".utf8))
        } throws: { e in
            guard case let .format(name, _) = e as? PCIOError else { return false }
            return name == "pcraft"
        }
    }

    /// Corpus files open, save as `.pcraft` and reopen as the same document; a PSD saved from that
    /// reopened document keeps every layer block. Returns (files, equal, blocks kept, blocks, failed).
    static func run(_ label: String, _ files: [URL]) -> (n: Int, equal: Int, kept: Int, blocks: Int, failed: [String]) {
        var equal = 0, blocksKept = 0, blocks = 0
        var failed: [String] = []
        for url in files {
            do {
                let doc = try DocumentIO.importFile(contentsOf: url, options: IOOptions(compositor: StoredPixelsCompositor())).document
                let bundle = try DocumentIO.export(doc, as: "x.pcraft", options: IOOptions(compositor: StoredPixelsCompositor())).bytes
                let back = try DocumentIO.importFile(name: "x.pcraft", bytes: bundle).document
                let diff = DocDiff.of(doc, back)
                if diff.isEmpty { equal += 1 } else { print("DETAIL \(label) pcraft \(url.lastPathComponent): \(diff.prefix(4))") }
                let original = try PSDFile(contentsOf: url)
                let px = try mergedPixels(original, doc)
                let resaved = try ExportSweep.$name.withValue(Corpus.sweepName(url, ".pcraft-reexport.psd")) {
                    try PSDFile(bytes: try DocumentIO.export(back, as: "x.psd", options: IOOptions(compositor: FixedCompositor(pixels: px, size: doc.size))).bytes)
                }
                for (a, b) in zip(original.layers, resaved.layers) {
                    for blk in a.blocks where !["luni", "lyid", "lsct", "lsdk", "iOpa", "lspf", "lclr"].contains(blk.key) {
                        blocks += 1
                        if b.blocks.contains(where: { $0.key == blk.key && $0.data == blk.data }) { blocksKept += 1 }
                    }
                }
            } catch {
                failed.append("\(url.lastPathComponent): \(error)")
                print("DETAIL \(label) pcraft \(url.lastPathComponent): error \(error)")
            }
        }
        print("MEASURE \(label) pcraft: \(files.count) files; re-imported equal \(equal)/\(files.count); PSD → .pcraft → PSD layer blocks kept \(blocksKept)/\(blocks); failed \(failed.count)")
        return (files.count, equal, blocksKept, blocks, failed)
    }

    @Test(.enabled(if: Corpus.available, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)")) func corpusSurvivesPcraft() throws {
        let r = PcraftDispatchTests.run("psd-corpus", Corpus.files)
        #expect(r.failed.isEmpty)
        #expect(r.equal == r.n)
        #expect(r.kept == r.blocks)
    }

    /// The Photoshop-generated corpus through `.pcraft`: measured and reported.
    @Test(.enabled(if: Corpus.psAvailable, "Photoshop corpus not present (set PHOTOCRAFT_FIXTURES or PCIO_PS_CORPUS)")) func photoshopCorpusSurvivesPcraft() throws {
        _ = PcraftDispatchTests.run("ps-corpus", Corpus.psFiles)
    }
}
