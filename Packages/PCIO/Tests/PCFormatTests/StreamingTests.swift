// Streamed single-file saves and file-backed loads (AB-T-0249): a single-file `.pcraft` is written
// entry by entry into its temporary file and read entry by entry through its central directory,
// with the same bytes, versions and errors as the in-memory archive.

import Foundation
@testable import PCFormat
import PCDocument
import PCFoundation
import PCIOCore
import Testing

@Suite struct StreamingTests {
    static let previews = SaveOptions(thumbnail: RGBA8Image(width: 3, height: 2, data: (0 ..< 24).map { UInt8($0 * 10) }),
                                      composite: RGBA8Image(width: 2, height: 2))

    /// A layer of `count` 16-bit RGBA noise tiles (512 KiB each, incompressible).
    static func noiseDoc(tiles count: Int, seed: UInt64 = 1) -> Document {
        let format = PixelFormat(mode: .rgb, sample: .u16, alpha: true)
        let tileBytes = Int(tileSize) * Int(tileSize) * format.bytesPerPixel
        var surface = Surface(format: format)
        surface.putTiles((0 ..< count).map { i in
            var r = Rng(seed &* 0x9E37_79B9 &+ UInt64(i) &+ 1)
            var bytes = [UInt8](repeating: 0, count: tileBytes)
            bytes.withUnsafeMutableBytes { p in
                let words = p.bindMemory(to: UInt64.self)
                for k in words.indices { words[k] = r.next() }
            }
            return (TileCoord(tx: Int32(i % 16), ty: Int32(i / 16)), Tile(bytes: bytes))
        })
        let side = 16 * Int(tileSize)
        var doc = Document(name: "noise", size: PixelSize(width: side, height: side), mode: .rgb, depth: .u16)
        doc.layers = [Layer.raster("Noise", surface: surface)]
        return doc
    }

    static func manifestText(_ bytes: [UInt8]) throws -> String {
        String(decoding: try ZipReader(bytes).read(named: "manifest.json", max: .max), as: UTF8.self)
    }

    static func unzipTests(_ url: URL) throws -> Bool? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip") else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-tqq", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// The single file is byte for byte the archive `saveZip` builds in memory, classic or ZIP64,
    /// with the same statistics, and it reopens equal.
    @Test(arguments: [false, true])
    func singleFileIsTheInMemoryArchive(forceZip64: Bool) throws {
        let dir = tempDir("stream-parity")
        defer { remove(dir) }
        for (k, doc) in [richDoc(.rgb, .u8), richDoc(.cmyk, .u16), richDoc(.rgb, .f32), Document(name: "empty", size: PixelSize(width: 1, height: 1), mode: .rgb, depth: .u8)].enumerated() {
            let url = dir.appendingPathComponent("\(k).pcraft")
            let file = PcraftWriter(), memory = PcraftWriter()
            file.forceZip64 = forceZip64
            memory.forceZip64 = forceZip64
            let stats = try file.save(doc, to: url, as: .singleFile, Self.previews)
            let (bytes, expected) = try memory.saveZip(doc, Self.previews)
            #expect(try [UInt8](Data(contentsOf: url)) == bytes, "\(k)")
            #expect(stats == expected)
            #expect(try ZipReader(bytes).isZip64 == forceZip64)
            #expect(try Self.manifestText(bytes).contains("\"format_version\": \(forceZip64 ? 2 : 1),"))
            #expect(try PcraftFormat.load(contentsOf: url) == doc)
            #expect(try load(bytes) == doc)
        }
        // Nothing but the saved files: no temporary file is left behind.
        #expect(try FS.list(dir.path).sorted() == ["0.pcraft", "1.pcraft", "2.pcraft", "3.pcraft"])
    }

    /// Objects beyond one batch (several batches compressed while earlier ones are written), and a
    /// writer cache smaller than the document: the next save reuses exactly the objects that fit,
    /// compresses the rest again, and writes the same bytes.
    @Test func batchesAndABoundedCacheWriteTheSameArchive() throws {
        let doc = Self.noiseDoc(tiles: 80)
        let dir = tempDir("stream-batches")
        defer { remove(dir) }
        let url = dir.appendingPathComponent("a.pcraft")
        let w = PcraftWriter()
        w.setZipCacheBudget(10 << 20)
        let first = try w.save(doc, to: url, as: .singleFile)
        #expect(first.tilesWritten == 80 && first.tilesReused == 0)
        let firstBytes = try [UInt8](Data(contentsOf: url))
        let cached = w.compressedObjects.values.reduce(0) { $0 + $1.data.count + PcraftWriter.zipCacheEntryCost }
        #expect(w.compressedObjects.count == 19, "10 MiB holds 19 tiles of 512 KiB plus framing")
        #expect(cached <= 10 << 20)
        let second = try w.save(doc, to: url, as: .singleFile)
        #expect(second.tilesReused == 19 && second.tilesWritten == 61)
        #expect(try [UInt8](Data(contentsOf: url)) == firstBytes)
        #expect(try Self.unzipTests(url) != false)
        #expect(try PcraftFormat.load(contentsOf: url) == doc)
        // A zero budget keeps nothing; a one-off save keeps nothing either.
        w.setZipCacheBudget(0)
        #expect(w.compressedObjects.isEmpty)
        #expect(try w.save(doc, to: url, as: .singleFile).tilesWritten == 80)
        #expect(w.compressedObjects.isEmpty)
    }

    /// The cache budget counts what the cached objects hold: a tile that compresses well keeps
    /// an array of its compressed size, not the encoder's working buffer.
    @Test func cachedObjectsHoldOnlyTheirBytes() throws {
        var doc = Document(name: "flat", size: PixelSize(width: 1024, height: 1024), mode: .rgb, depth: .u8)
        var layer = Layer.raster("L", format: doc.pixelFormat)
        layer.withRaster { $0.fill(PixelRect(x: 0, y: 0, width: 1024, height: 1024), with: [0.25, 0.5, 0.75, 1]) }
        layer.withRaster { $0.setPixel(x: 300, y: 300, [1, 0, 0, 1]) }
        doc.layers = [layer]
        let w = PcraftWriter()
        _ = try w.saveZip(doc)
        #expect(!w.compressedObjects.isEmpty)
        for (path, o) in w.compressedObjects {
            #expect(o.data.capacity <= o.data.count + o.data.count / 8 + 64, "\(path): \(o.data.count) bytes in \(o.data.capacity)")
        }
        let tile = [UInt8](repeating: 7, count: 65536) + [1]
        let z = PcraftCodec.compress(tile)
        #expect(z.capacity <= z.count + z.count / 8 + 64)
        #expect(try PcraftCodec.decompress(z, expected: tile.count, what: "t") == tile)
    }

    /// More than 65,535 entries make the archive ZIP64 only once most of it is written: the
    /// manifest, written first as format 1, is rewritten in place as format 2.
    @Test func anArchiveThatOutgrowsClassicZipSaysFormat2() throws {
        var doc = Document(name: "many", size: PixelSize(width: 8, height: 8), mode: .rgb, depth: .u8)
        var layer = Layer.raster("blocks", format: doc.pixelFormat)
        layer.psdBlocks = (0 ..< 66_000).map { i in PSDLayerBlock(key: "lnsr", data: withUnsafeBytes(of: UInt32(i).littleEndian) { Array($0) }) }
        doc.layers = [layer]
        let dir = tempDir("stream-zip64")
        defer { remove(dir) }
        let url = dir.appendingPathComponent("many.pcraft")
        try PcraftWriter().save(doc, to: url, as: .singleFile)
        let bytes = try [UInt8](Data(contentsOf: url))
        let zip = try ZipReader(bytes)
        #expect(zip.isZip64 && zip.entries.count == 66_001)
        #expect(zip.entries.first?.name == "manifest.json")
        #expect(try Self.manifestText(bytes).contains("\"format_version\": 2,"))
        #expect(try PcraftFormat.save(doc) == bytes)
        #expect(try PcraftFormat.load(contentsOf: url) == doc)
        #expect(try Self.unzipTests(url) != false)
    }

    /// A save that fails part-way leaves the destination as it was and no temporary file; a
    /// document that can't be saved fails before any file is created.
    @Test func aFailedStreamingSaveChangesNothing() throws {
        let dir = tempDir("stream-fail")
        defer { remove(dir) }
        let url = dir.appendingPathComponent("doc.pcraft")
        try Data("previous".utf8).write(to: url)
        #expect {
            try AtomicSave.atomicWriteStreaming(url) { fd throws(FormatError) in
                let part = [UInt8](repeating: 1, count: 3 << 20)
                do throws(IOError) { try AtomicSave.writeAll(fd, part, 0, part.count, "test") } catch { throw .io(error) }
                throw .io(IOError(.storageFull, "disk full"))
            }
        } throws: { e in
            guard case FormatError.io(let io) = e else { return false }
            return io.kind == .storageFull && io.message.contains(AtomicSave.unchanged)
        }
        #expect(throws: FormatError.unsupported("x")) {
            try AtomicSave.atomicWriteStreaming(url) { _ throws(FormatError) in throw .unsupported("x") }
        }
        var bad = richDoc(.rgb, .u8)
        bad.layers[1].opacity = .nan
        #expect { try PcraftWriter().save(bad, to: url, as: .singleFile) } throws: { e in
            if case FormatError.nonFinite = e { return true }
            return false
        }
        #expect(try Data(contentsOf: url) == Data("previous".utf8))
        #expect(try FS.list(dir.path) == ["doc.pcraft"])
        // And a successful one replaces it, keeping its permissions.
        chmod(url.path, 0o600)
        let good = richDoc(.rgb, .u8)
        try PcraftWriter().save(good, to: url, as: .singleFile)
        #expect(try PcraftFormat.load(contentsOf: url) == good)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
    }

    /// Opening from a file fails exactly as opening the same bytes from memory: truncated, flipped
    /// and missing files alike.
    @Test func damagedFilesFailAsTheyDoInMemory() throws {
        let dir = tempDir("stream-damaged")
        defer { remove(dir) }
        let b = corruptionSample
        var variants: [[UInt8]] = stride(from: 0, to: b.count, by: max(b.count / 40, 1)).map { Array(b[..<$0]) }
        var rng = Rng(42)
        for _ in 0 ..< 60 {
            var c = b
            c[Int(rng.next() % UInt64(c.count))] ^= 0x20
            variants.append(c)
        }
        for (k, bytes) in variants.enumerated() {
            let url = dir.appendingPathComponent("\(k).pcraft")
            try Data(bytes).write(to: url)
            let fromMemory = Result { () throws(FormatError) in try PcraftFormat.load(bytes) }
            let fromFile = Result { () throws(FormatError) in try PcraftFormat.load(contentsOf: url) }
            switch (fromMemory, fromFile) {
            case let (.success(a), .success(b)): #expect(a == b, "variant \(k)")
            case let (.failure(a), .failure(b)): #expect(a == b, "variant \(k)")
            default: Issue.record("variant \(k): memory \(fromMemory), file \(fromFile)")
            }
            remove(url)
        }
        #expect { try PcraftFormat.load(contentsOf: dir.appendingPathComponent("missing.pcraft")) } throws: { e in
            if case FormatError.io(let io) = e { return io.kind == .notFound }
            return false
        }
    }
}
