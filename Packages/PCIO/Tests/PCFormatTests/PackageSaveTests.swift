// Package saves without the per-object wait (AB-T-0259): new objects are checked and written on
// all cores with one full flush (the manifest's), damaged ones among many are found and rewritten,
// nothing temporary is left, and previews that didn't change aren't encoded again.

import Foundation
@testable import PCFormat
import PCDocument
import PCFoundation
import PCIOCore
import Testing

@Suite struct PackageSaveTests {
    /// One RGBA8 layer of `side`² pixels of noise: (side / 256)² distinct tiles.
    static func noise(_ side: Int, seed: UInt64) -> Document {
        var d = Document(name: "noise", size: PixelSize(width: side, height: side), mode: .rgb, depth: .u8)
        var l = Layer.raster("noise", format: d.pixelFormat)
        var r = Rng(seed)
        let rect = PixelRect(x0: 0, y0: 0, x1: Int32(side), y1: Int32(side))
        l.withRaster { $0.writeRegion(rect, (0 ..< side * side * 4).map { _ in r.f() }) }
        d.layers = [l]
        return d
    }

    static func files(_ dir: URL) throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: dir.path).sorted()
    }

    @Test func manyObjectsAreWrittenAndDamagedOnesRewritten() throws {
        let dir = tempDir("package-parallel")
        defer { remove(dir) }
        let url = dir.appendingPathComponent("doc.pcraft")
        let doc = Self.noise(1024, seed: 3)
        let w = PcraftWriter()
        let first = try w.saveDir(doc, url)
        #expect(first.tilesTotal == 16 && first.tilesWritten == 16)
        #expect(try PcraftFormat.load(contentsOf: url) == doc)
        let listing = try Self.files(url)
        #expect(!listing.contains { $0.hasSuffix(".pcsave.tmp") }, "no temporary file is left")
        #expect(listing.filter { $0.hasPrefix("tiles/") && $0.hasSuffix(".zst") }.count == 16)

        // Three objects damaged in place; a writer that never saw this folder checks every object.
        let tiles = listing.filter { $0.hasPrefix("tiles/") && $0.hasSuffix(".zst") }
        for name in tiles.prefix(3) {
            let path = url.appendingPathComponent(name)
            var bytes = try Data(contentsOf: path)
            bytes[bytes.count / 2] ^= 0xFF
            try bytes.write(to: path)
        }
        let fresh = PcraftWriter()
        let again = try fresh.saveDir(doc, url)
        #expect(again.tilesWritten == 3 && again.tilesReused == 13)
        #expect(try PcraftFormat.load(contentsOf: url) == doc)
        #expect(try Self.files(url) == listing)
        // Saved again, everything is trusted from its signature.
        let third = try fresh.saveDir(doc, url)
        #expect(third.tilesWritten == 0 && third.tilesReused == 16)
    }

    @Test func unchangedPreviewsAreNotEncodedAgain() throws {
        let w = PcraftWriter()
        let doc = Self.noise(256, seed: 1)
        var image = RGBA8Image(width: 16, height: 8)
        for i in image.data.indices { image.data[i] = UInt8(truncatingIfNeeded: i &* 7) }
        let a = try w.prepare(doc, SaveOptions(thumbnail: image, composite: image))
        let encoded = try #require(w.previewPNGs[Store.thumb]?.png)
        let b = try w.prepare(doc, SaveOptions(thumbnail: image, composite: image))
        #expect(a.previews.map(\.data) == b.previews.map(\.data))
        #expect(w.previewPNGs[Store.thumb]?.png == encoded)
        var changed = image
        changed.data[0] ^= 0xFF
        let c = try w.prepare(doc, SaveOptions(thumbnail: changed, composite: image))
        #expect(c.previews.first?.data != a.previews.first?.data && c.previews.last?.data == a.previews.last?.data)
        #expect(c.previews.first?.data == (try Store.png(changed)))
    }

    /// The previews a bundle holds read back as they were saved, from a package and a single file.
    @Test func previewsReadBackAsSaved() throws {
        let dir = tempDir("package-previews")
        defer { remove(dir) }
        var thumbnail = RGBA8Image(width: 32, height: 16), composite = RGBA8Image(width: 64, height: 32)
        for i in thumbnail.data.indices { thumbnail.data[i] = UInt8(truncatingIfNeeded: i &* 13) }
        for i in composite.data.indices { composite.data[i] = UInt8(truncatingIfNeeded: i &* 7 &+ 3) }
        let doc = Self.noise(256, seed: 2)
        let package = dir.appendingPathComponent("p.pcraft"), single = dir.appendingPathComponent("s.pcraft")
        try PcraftWriter().save(doc, to: package, as: .package, SaveOptions(thumbnail: thumbnail, composite: composite))
        try PcraftWriter().save(doc, to: single, as: .singleFile, SaveOptions(thumbnail: thumbnail, composite: composite))
        for url in [package, single] {
            let read = try PcraftFormat.readPreviews(contentsOf: url)
            #expect(read.thumbnail == thumbnail && read.composite == composite, "\(url.lastPathComponent)")
        }
        try PcraftWriter().save(doc, to: package, as: .package)
        let none = try PcraftFormat.readPreviews(contentsOf: package)
        #expect(none.thumbnail == nil && none.composite == nil)
    }
}
