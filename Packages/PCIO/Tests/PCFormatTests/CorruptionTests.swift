// Damaged or hostile bundles must fail cleanly, never trap.
// Port of photocraft-format (crates/format/tests/corruption.rs), MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors. The proptest properties run as seeded random cases.

import Foundation
@testable import PCFormat
import PCDocument
import PCFoundation
import PCIOCore
import Testing

/// The bundle most corruption tests damage (photocraft's `sample()`), saved once.
let corruptionSample: [UInt8] = (try? save(richDoc(.rgb, .u8))) ?? []

func isCorrupt(_ e: Error) -> Bool { if case FormatError.corrupt = e { true } else { false } }
func isLimit(_ e: Error) -> Bool { if case FormatError.limitExceeded = e { true } else { false } }
func isJSON(_ e: Error) -> Bool { if case FormatError.json = e { true } else { false } }

@Suite struct CorruptionTests {
    @Test func olderBundlesWithoutTextMetadataStillLoad() throws {
        var doc = richDoc(.rgb, .u8)
        let bytes = try save(doc)
        let old = try withManifest(bytes) { m in
            var d = m["document"] as? [String: Any] ?? [:]
            var md = d["metadata"] as? [String: Any] ?? [:]
            #expect(md.removeValue(forKey: "text") != nil)
            d["metadata"] = md
            m["document"] = d
        }
        doc.metadata.text = []
        #expect(try load(old) == doc)
    }

    /// photocraft #8893 `manifest_with_too_many_values_is_refused`: a manifest of millions of tiny values (`[0,0,…]`
    /// deflates about 1000:1) is refused before it is parsed into a tree.
    @Test func manifestWithTooManyValuesIsRefused() throws {
        let n = (4 << 20) + 16
        var m: [UInt8] = [0x5B]
        m.reserveCapacity(2 * n + 1)
        for i in 0 ..< n { m += i == 0 ? [0x30] : [0x2C, 0x30] }
        m.append(0x5D)
        let b = try rebuild(corruptionSample) { name, d in name == "manifest.json" ? m : d }
        #expect { try load(b) } throws: { isLimit($0) }
    }

    /// photocraft `87da091f2`: two layers with one id are refused; layer comp and slice targets would be ambiguous.
    @Test func duplicateLayerIdsAreRefused() throws {
        var doc = Document(name: "ids", size: PixelSize(width: 4, height: 4), mode: .rgb, depth: .u8)
        doc.layers.append(Layer.raster("A", format: doc.pixelFormat))
        doc.layers.append(Layer.group("G", [Layer.raster("B", format: doc.pixelFormat)]))
        let bytes = try save(doc)
        #expect(try load(bytes).layers.count == 2)
        let twice = try withManifest(bytes) { m in
            var d = m["document"] as? [String: Any] ?? [:]
            var layers = d["layers"] as? [[String: Any]] ?? []
            let first = try #require(layers.first?["id"])
            // The nested layer takes the first layer's id.
            var content = layers[1]["content"] as? [String: Any] ?? [:]
            var group = content["group"] as? [String: Any] ?? content
            var children = group["children"] as? [[String: Any]] ?? []
            #expect(children.count == 1)
            children[0]["id"] = first
            group["children"] = children
            if content["group"] != nil { content["group"] = group } else { content = group }
            layers[1]["content"] = content
            d["layers"] = layers
            m["document"] = d
        }
        #expect { try load(twice) } throws: { isCorrupt($0) }
    }

    @Test func truncationNeverTrapsAndFails() {
        let b = corruptionSample
        let step = max(b.count / 200, 1)
        for cut in stride(from: 0, to: b.count, by: step) {
            #expect(throws: (any Error).self, "cut at \(cut)") { try load(Array(b[..<cut])) }
        }
    }

    @Test func byteFlipsDetected() {
        let b = corruptionSample
        var rng = Rng(9)
        var failures = 0
        for _ in 0 ..< 300 {
            var c = b
            let i = Int(rng.next() % UInt64(c.count))
            c[i] ^= 0x20
            if (try? load(c)) == nil { failures += 1 }
        }
        // Some flips hit unused header fields; most must be caught (CRC + hashes).
        #expect(failures > 200, "\(failures)")
    }

    @Test func missingTileIsError() throws {
        let b = try rebuild(corruptionSample) { n, d in n.hasPrefix("tiles/") ? nil : d }
        #expect { try load(b) } throws: { isCorrupt($0) }
    }

    @Test func missingManifestIsError() throws {
        let b = try rebuild(corruptionSample) { n, d in n == "manifest.json" ? nil : d }
        #expect(throws: (any Error).self) { try load(b) }
    }

    @Test func swappedTileContentFailsHashCheck() throws {
        let b = corruptionSample
        let r = try ZipReader(b)
        let tiles = r.entries.filter { $0.name.hasPrefix("tiles/") }.map(\.name)
        let other = try r.read(named: tiles[1], max: .max)
        let first = tiles[0]
        let b2 = try rebuild(b) { n, d in n == first ? other : d }
        #expect { try load(b2) } throws: { "\($0)".contains("hash") }
    }

    @Test func badManifestJSON() throws {
        let b = try rebuild(corruptionSample) { n, d in n == "manifest.json" ? Array("{not json".utf8) : d }
        #expect { try load(b) } throws: { isJSON($0) }
    }

    /// Hostile nesting fails with an error instead of overflowing the stack; nesting as deep as
    /// the deepest groups a bundle may hold (three JSON levels each) parses, and is then rejected
    /// for lacking a format version.
    @Test func overDeepManifestFailsCleanly() throws {
        func nested(_ n: Int) -> [UInt8] { Array((String(repeating: "[", count: n) + String(repeating: "]", count: n)).utf8) }
        func withManifest(_ m: [UInt8]) throws -> [UInt8] { try rebuild(corruptionSample) { n, d in n == "manifest.json" ? m : d } }
        #expect { try load(try withManifest(nested(100_000))) } throws: { isLimit($0) }
        #expect { try load(try withManifest(nested(3 * PcraftFormat.maxGroupDepth))) } throws: { isCorrupt($0) }
        // Brackets inside strings (escaped quotes included) don't count.
        let s = "{\"x\":\"" + String(repeating: "[", count: 100_000) + "\\\"" + String(repeating: "{", count: 10) + "\"}"
        #expect { try load(try withManifest(Array(s.utf8))) } throws: { isCorrupt($0) }
    }

    @Test func tooNewVersionRejected() throws {
        let b = try withManifest(corruptionSample) { $0["format_version"] = 999 }
        #expect { try load(b) } throws: { e in
            if case FormatError.tooNew(found: 999, supported: _) = e { return true }
            return false
        }
    }

    @Test func invalidHashStringsRejected() throws {
        let b = try rebuild(corruptionSample) { n, d in
            guard n == "manifest.json" else { return d }
            var s = d
            let needle = Array("\"hash\": \"".utf8)
            guard let i = (0 ..< s.count - needle.count).first(where: { Array(s[$0 ..< $0 + needle.count]) == needle }) else { return d }
            s[i + needle.count] = UInt8(ascii: "/")
            return s
        }
        #expect(b != corruptionSample)
        #expect(throws: (any Error).self) { try load(b) }
    }

    @Test func manifestSizeLimit() {
        #expect { try load(corruptionSample, LoadOptions(maxManifestBytes: 100)) } throws: { isLimit($0) }
    }

    @Test func totalSizeLimit() {
        #expect { try load(corruptionSample, LoadOptions(maxTotalBytes: 1000)) } throws: { isLimit($0) }
    }

    /// A hostile manifest may name one stored tile at very many coordinates. The load decodes and
    /// charges it once, each reference only shares the decoded tile, and the budget still bounds
    /// the distinct bytes (photocraft #3315).
    @Test func manyReferencesToOneTileLoadWithinTheBudget() throws {
        var doc = Document(name: "d", size: PixelSize(width: 256, height: 256), mode: .rgb, depth: .u8)
        var l = Layer.raster("solid", format: doc.pixelFormat)
        l.withRaster { $0.fill(PixelRect(x0: 0, y0: 0, x1: 256, y1: 256), with: [1, 0, 0, 1]) }
        doc.layers.append(l)
        let bytes = try save(doc)
        let hostile = try withManifest(bytes) { m in
            var d = m["document"] as? [String: Any] ?? [:]
            var layers = d["layers"] as? [[String: Any]] ?? []
            var content = layers[0]["content"] as? [String: Any] ?? [:]
            var surface = content["surface"] as? [String: Any] ?? [:]
            let hash = (surface["tiles"] as? [[String: Any]])?.first?["hash"] ?? ""
            surface["tiles"] = (0 ..< 256 * 256).map { i -> [String: Any] in ["tx": i % 256, "ty": i / 256, "hash": hash] }
            content["surface"] = surface
            layers[0]["content"] = content
            d["layers"] = layers
            m["document"] = d
        }
        let oneTile: UInt64 = 256 * 256 * 4
        let back = try load(hostile, LoadOptions(maxTotalBytes: oneTile))
        let s = try #require(back.layers[0].surface)
        #expect(s.tileCount == 256 * 256)
        let first = try #require(s.tile(TileCoord(tx: 0, ty: 0)))
        var shared = true
        s.forEachTile { _, t in if t.generation != first.generation { shared = false } }
        #expect(shared)
        // The one distinct tile is still charged against the budget.
        #expect { try load(hostile, LoadOptions(maxTotalBytes: oneTile - 1)) } throws: { isLimit($0) }
    }

    @Test func directoryBundleResaveRepairsTamperedObjects() throws {
        let doc = richDoc(.rgb, .u8)
        let dir = tempDir("tamper")
        let writer = PcraftWriter()
        try writer.saveDir(doc, dir)
        for objectDir in ["tiles", "blobs"] {
            let folder = dir.appendingPathComponent(objectDir)
            let object = folder.appendingPathComponent(try FS.list(folder.path).sorted()[0])
            let original = [UInt8](try Data(contentsOf: object))
            var decoded = try PcraftCodec.decompressBounded(original, max: 1 << 30, exact: nil, what: "object")
            if decoded.isEmpty { decoded.append(1) } else { decoded[0] ^= 1 }
            let hashMismatched = ZstdEncoder.compress(decoded)
            for damaged in [hashMismatched, Array("garbage".utf8)] {
                try Data(damaged).write(to: object)
                #expect(throws: (any Error).self) { try PcraftFormat.load(contentsOf: dir) }
                let stats = try writer.saveDir(doc, dir)
                if objectDir == "tiles" { #expect(stats.tilesWritten == 1) } else { #expect(stats.blobsWritten == 1) }
                #expect(try PcraftFormat.load(contentsOf: dir) == doc)
            }
        }
        remove(dir)
    }

    /// Damages one object in place without changing its length or modification time, the case a
    /// size-and-mtime cache alone would trust. Returns the damaged file's path.
    static func damageInPlaceKeepingSizeAndMtime(_ dir: URL) throws -> URL {
        let tiles = dir.appendingPathComponent("tiles")
        let object = tiles.appendingPathComponent(try FS.list(tiles.path).sorted()[0])
        let original = [UInt8](try Data(contentsOf: object))
        var st = stat()
        stat(object.path, &st)
        let times = [st.st_atimespec, st.st_mtimespec]
        func mtime() -> timespec {
            var s = stat()
            stat(object.path, &s)
            return s.st_mtimespec
        }
        for at in Array(original.count / 2 ..< original.count) + Array(0 ..< original.count / 2) {
            var damaged = original
            damaged[at] ^= 0x5A
            try Data(damaged).write(to: object)
            _ = times.withUnsafeBufferPointer { utimensat(AT_FDCWD, object.path, $0.baseAddress, 0) }
            if (try? PcraftFormat.load(contentsOf: dir)) == nil {
                var now = stat()
                stat(object.path, &now)
                #expect(now.st_size == off_t(original.count))
                #expect(mtime().tv_sec == times[1].tv_sec && mtime().tv_nsec == times[1].tv_nsec)
                return object
            }
        }
        Issue.record("no single-byte change made the bundle fail to load")
        return object
    }

    @Test func sameSizeSameMtimeTamperIsRepairedOnTheNextSave() throws {
        let doc = richDoc(.rgb, .u8)
        let dir = tempDir("tamper-same-size")
        let writer = PcraftWriter()
        try writer.saveDir(doc, dir)
        // A second save trusts every object it verified in the first one.
        try writer.saveDir(doc, dir)
        _ = try CorruptionTests.damageInPlaceKeepingSizeAndMtime(dir)
        // The sample bundle is far below the default re-verify budget, so the rolling re-check
        // reads every cached object again (and the change time differs as well).
        let stats = try writer.saveDir(doc, dir)
        #expect(stats.tilesWritten == 1)
        #expect(try PcraftFormat.load(contentsOf: dir) == doc)
        remove(dir)
    }

    @Test func rollingReverifyReachesEveryObjectWithATinyBudget() throws {
        let doc = richDoc(.rgb, .u8)
        let dir = tempDir("tamper-rolling")
        let writer = PcraftWriter()
        try writer.saveDir(doc, dir)
        let objects = try FS.list(dir.appendingPathComponent("tiles").path).count + FS.list(dir.appendingPathComponent("blobs").path).count

        // One object per save: the oldest-checked one.
        writer.setReverifyBudget(1)
        _ = try CorruptionTests.damageInPlaceKeepingSizeAndMtime(dir)
        var repaired = false
        for _ in 0 ... objects {
            if try writer.saveDir(doc, dir).tilesWritten == 1 {
                repaired = true
                break
            }
        }
        #expect(repaired, "a damaged object was not re-verified within \(objects) saves")
        #expect(try PcraftFormat.load(contentsOf: dir) == doc)

        // A zero budget re-reads nothing whose signature is unchanged; a fresh writer still
        // verifies everything on its first save.
        let fresh = PcraftWriter()
        fresh.setReverifyBudget(0)
        _ = try CorruptionTests.damageInPlaceKeepingSizeAndMtime(dir)
        #expect(try fresh.saveDir(doc, dir).tilesWritten == 1)
        #expect(try PcraftFormat.load(contentsOf: dir) == doc)
        remove(dir)
    }

    @Test func deflatedZipEntriesAreReadable() throws {
        // Re-zip with DEFLATE (as a user's zip tool might): it must still load.
        let b = corruptionSample
        let r = try ZipReader(b)
        var z = ZipWriter()
        for e in r.entries { try z.add(e.name, try r.read(e, max: .max), compress: true) }
        let out = try z.finish()
        #expect(try ZipReader(out).entries.contains { $0.method == 8 })
        #expect(try load(out) == load(b))
    }

    @Test func randomBytesNeverTrap() {
        var rng = Rng(1)
        for _ in 0 ..< 300 {
            let n = Int(rng.next() % 4096)
            let data = (0 ..< n).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            _ = try? load(data)
            _ = try? PcraftFormat.readManifest(data)
        }
    }

    @Test func randomManifestNeverTraps() throws {
        var rng = Rng(2)
        let alphabet = Array("{}[]\":,0123456789.-+eEtrufalsn \\/abcxyz_é雪\u{0}\n".unicodeScalars)
        for _ in 0 ..< 300 {
            let n = Int(rng.next() % 301)
            var s = String.UnicodeScalarView()
            for _ in 0 ..< n { s.append(alphabet[Int(rng.next() % UInt64(alphabet.count))]) }
            var z = ZipWriter()
            try z.add("manifest.json", Array(String(s).utf8))
            _ = try? load(try z.finish())
        }
    }

    @Test func randomTilePayloadNeverTraps() throws {
        let b = corruptionSample
        let r = try ZipReader(b)
        let tiles = r.entries.filter { $0.name.hasPrefix("tiles/") }.map(\.name)
        var rng = Rng(3)
        for _ in 0 ..< 60 {
            let n = Int(rng.next() % 512)
            let data = (0 ..< n).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            let target = tiles[Int(rng.next() % 8) % tiles.count]
            let b2 = try rebuild(b) { name, d in name == target ? data : d }
            #expect(throws: (any Error).self) { try load(b2) }
        }
    }

    /// Moves the first tile of the first top-level layer that has pixels to `(tx, ty)`; returns
    /// that layer's index.
    static func moveFirstTile(_ m: inout [String: Any], _ tx: Int64, _ ty: Int64) -> Int? {
        var d = m["document"] as? [String: Any] ?? [:]
        var layers = d["layers"] as? [[String: Any]] ?? []
        for i in layers.indices {
            guard var content = layers[i]["content"] as? [String: Any], var surface = content["surface"] as? [String: Any],
                  var tiles = surface["tiles"] as? [[String: Any]], !tiles.isEmpty else { continue }
            tiles[0]["tx"] = tx
            tiles[0]["ty"] = ty
            surface["tiles"] = tiles
            content["surface"] = surface
            layers[i]["content"] = content
            d["layers"] = layers
            m["document"] = d
            return i
        }
        return nil
    }

    @Test func tileCoordinatesOutsideTheInt32PixelRangeAreRejected() throws {
        // photocraft #938: a tile index whose rectangle overflows Int32 must be refused at load.
        func withTileAt(_ tx: Int64, _ ty: Int64) throws -> ([UInt8], Int) {
            var layer: Int?
            let b = try withManifest(corruptionSample) { layer = CorruptionTests.moveFirstTile(&$0, tx, ty) }
            return (b, try #require(layer, "the sample has a raster layer with a tile"))
        }
        let lo = Int64(Int32.min / 256), hi = Int64(Int32.max / 256 - 1)
        for (tx, ty) in [(hi + 1, 0), (0, hi + 1), (lo - 1, 0), (0, lo - 1), (Int64(Int32.max), 0), (0, Int64(Int32.min))] {
            #expect { try load(try withTileAt(tx, ty).0) } throws: { "\($0)".contains("outside the coordinate range") }
        }
        // The extreme valid indices still load, and the layer's bounds can be computed.
        for (tx, ty) in [(hi, hi), (lo, lo), (hi, lo)] {
            let (b, i) = try withTileAt(tx, ty)
            let doc = try load(b)
            let s = try #require(doc.layers[i].surface)
            #expect(s.tileCoords.contains { Int64($0.tx) == tx && Int64($0.ty) == ty }, "(\(tx), \(ty))")
            #expect(!s.contentBounds.isEmpty)
        }
    }

    @Test func anUnlimitedBlobBudgetStillLoadsBlobs() throws {
        let doc = richDoc(.rgb, .u8)
        #expect(try load(try save(doc), LoadOptions(maxBlobBytes: .max)) == doc)
    }

    /// Rewrites the first pattern's declared size (its tiles stay as saved).
    static func withPatternSize(_ w: Int, _ h: Int) throws -> [UInt8] {
        try withManifest(corruptionSample) { m in
            var d = m["document"] as? [String: Any] ?? [:]
            var patterns = d["patterns"] as? [[String: Any]] ?? []
            #expect(!patterns.isEmpty, "the sample has a pattern")
            patterns[0]["width"] = w
            patterns[0]["height"] = h
            d["patterns"] = patterns
            m["document"] = d
        }
    }

    @Test func patternSizesFromTheFileAreChecked() throws {
        // A pattern can claim any size without tiles; painting it would allocate per pixel.
        #expect { try load(try CorruptionTests.withPatternSize(65_535, 65_535)) } throws: { isLimit($0) }
        #expect { try load(try CorruptionTests.withPatternSize(0, 24)) } throws: { isCorrupt($0) }
        _ = try load(try CorruptionTests.withPatternSize(32, 24))
    }

    /// A canvas is a few bytes of manifest JSON; one past the budget is refused before any work
    /// (photocraft #2935). The default budget is the largest canvas the app creates.
    @Test func declaredCanvasOutsideTheBudgetIsRefused() throws {
        func withSize(_ w: UInt64, _ h: UInt64) throws -> [UInt8] {
            try withManifest(corruptionSample) { m in
                var d = m["document"] as? [String: Any] ?? [:]
                d["size"] = ["width": w, "height": h]
                m["document"] = d
            }
        }
        for (w, h) in [(UInt64(300_001), UInt64(1)), (1, 300_001), (300_001, 300_001), (UInt64(UInt32.max), UInt64(UInt32.max))] {
            #expect { try load(try withSize(w, h)) } throws: { isLimit($0) }
        }
        #expect(throws: (any Error).self) { try load(try withSize(0, 64)) }
        // The largest creatable canvas loads, without allocating anything for its area: the layers
        // keep only the tiles the bundle holds.
        let edge = try withSize(300_000, 300_000)
        let small = try load(corruptionSample)
        let big = try load(edge)
        #expect(big.size == PixelSize(width: 300_000, height: 300_000))
        func tiles(_ d: Document) -> Int { d.layers.compactMap(\.surface).map(\.tileCount).reduce(0, +) }
        #expect(tiles(big) == tiles(small))
        // A caller may lower the budget.
        #expect { try load(edge, LoadOptions(maxCanvasPixels: 1 << 20)) } throws: { isLimit($0) }
        #expect { try load(try withSize(65_537, 1), LoadOptions(maxCanvasSide: 65_536)) } throws: { isLimit($0) }
    }
}
