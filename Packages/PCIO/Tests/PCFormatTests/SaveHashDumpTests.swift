// An opt-in hash dump of `.pcraft` saves, for checking that a change to the writer leaves its bytes as they were
// (AB-T-0255 against 2b43d81, as AB-T-0249 compared against 2e24b80). With `PCRAFT_HASH_DUMP=<file>`, each case
// appends `name manifest-sha256 file-sha256` to that file; run the same test at both commits and diff the files.
// PCIOTests' `CorpusHashDumpTests` does the format corpus. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.

import CryptoKit
import Foundation
@testable import PCFormat
import PCDocument
import PCFoundation
import Testing

enum SaveHashDump {
    static let file = ProcessInfo.processInfo.environment["PCRAFT_HASH_DUMP"]

    static func sha(_ bytes: [UInt8]) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    static func record(_ name: String, manifest: [UInt8], file bytes: [UInt8]) throws {
        let line = "\(name) \(sha(manifest)) \(sha(bytes)) \(manifest.count) \(bytes.count)\n"
        let url = URL(fileURLWithPath: try #require(file))
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(line.utf8))
        try h.close()
    }
}

@Suite(.serialized) struct SaveHashDumpTests {
    static let previews = SaveOptions(thumbnail: RGBA8Image(width: 2, height: 1, data: [255, 0, 0, 255, 0, 0, 255, 128]),
                                      composite: RGBA8Image(width: 1, height: 1, data: [1, 2, 3, 4]))

    /// Every way a document is saved: ZIP (classic and forced ZIP64, a resave from the same writer, previews), the
    /// streamed single file, and the package's manifest.
    static func dump(_ name: String, _ doc: Document) throws {
        let w = PcraftWriter()
        let (model0, p) = try w.prepareWithModel(doc, SaveOptions())
        let (zip, _) = try w.saveZip(doc)
        try SaveHashDump.record("\(name).zip", manifest: p.manifest, file: zip)
        let (again, _) = try w.saveZip(doc)
        try SaveHashDump.record("\(name).resave", manifest: p.manifest, file: again)
        let (withPreviews, _) = try PcraftWriter().saveZip(doc, previews)
        try SaveHashDump.record("\(name).previews", manifest: p.manifest, file: withPreviews)
        let z64 = PcraftWriter()
        z64.forceZip64 = true
        let (forced, _) = try z64.saveZip(doc)
        var model = model0
        model.formatVersion = max(model.formatVersion, pcraftZip64FormatVersion)
        try SaveHashDump.record("\(name).zip64", manifest: try ManifestJSON.encode(model), file: forced)
        let dir = tempDir("hash-dump")
        defer { remove(dir) }
        let single = dir.appendingPathComponent("single.pcraft"), package = dir.appendingPathComponent("package.pcraft")
        try PcraftWriter().save(doc, to: single, as: .singleFile)
        try SaveHashDump.record("\(name).stream", manifest: p.manifest, file: [UInt8](try Data(contentsOf: single)))
        try PcraftWriter().save(doc, to: package, as: .package)
        let m = [UInt8](try Data(contentsOf: package.appendingPathComponent(Store.manifest)))
        try SaveHashDump.record("\(name).package", manifest: m, file: m)
    }

    @Test(.enabled(if: SaveHashDump.file != nil, "set PCRAFT_HASH_DUMP")) func richDocsInEveryModeAndDepth() throws {
        for mode in allModes {
            for depth in allDepths { try Self.dump("richDoc-\(mode)-\(depth)", richDoc(mode, depth)) }
        }
    }

    /// 70,000 tile references (16 distinct tiles) on one layer, a mask and a channel: a manifest of tile lists.
    @Test(.enabled(if: SaveHashDump.file != nil, "set PCRAFT_HASH_DUMP")) func manyTiles() throws {
        let side = 265
        var doc = Document(name: "Tiles", size: PixelSize(width: side * Int(tileSize), height: side * Int(tileSize)), mode: .grayscale, depth: .u8)
        func tiles(_ bpp: Int) -> [Tile] {
            (0 ..< 16).map { k in Tile(bytes: (0 ..< Int(tileSize) * Int(tileSize) * bpp).map { UInt8(truncatingIfNeeded: $0 &* (k + 1) >> 3) }) }
        }
        let pixels = tiles(doc.pixelFormat.bytesPerPixel), coverage = tiles(1)
        var gray = Surface(format: doc.pixelFormat)
        gray.putTiles((0 ..< side * side - 225).map { i in (TileCoord(tx: Int32(i % side) - 7, ty: Int32(i / side)), pixels[i % 16]) })
        var layer = Layer.raster("Gray", surface: gray)
        var mask = LayerMask.revealAll()
        mask.surface.putTiles((0 ..< 300).map { (TileCoord(tx: Int32($0 % 20), ty: Int32($0 / 20)), coverage[$0 % 16]) })
        layer.mask = mask
        doc.layers = [layer]
        try Self.dump("manyTiles", doc)
    }
}
