// AB-T-0328: a single-file save holds less per tile while it streams. Hashes are 32-byte digests until the manifest
// or a path spells them, paths are made as objects are written, the manifest model isn't kept, and the manifest text
// is let go once written: its format 2 version is patched in place. The bytes must be what they were. MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
@testable import PCFormat
import PCFoundation
import PCIOCore
import Testing

@Suite struct SaveMemoryTests {
    /// A digest spells the hex `Convert.hex` does, and orders as that hex.
    @Test func digestsSpellAndOrderAsTheirHex() {
        var r = Rng(7)
        let bytes = (0 ..< 200).map { k in (0 ..< 32).map { j in k < 8 ? UInt8(j == 31 ? k : 0) : UInt8(truncatingIfNeeded: r.next()) } }
        let digests = bytes.map(ContentDigest.init)
        for (d, b) in zip(digests, bytes) { #expect(d.hex == Convert.hex(b)) }
        #expect(digests.sorted().map(\.hex) == bytes.map(Convert.hex).sorted())
        #expect(PcraftCodec.digest(Array("abc".utf8)).hex == PcraftCodec.hash(Array("abc".utf8)))
    }

    /// The version patched into the text is what encoding the model again with that version writes, even when a
    /// document's own strings hold something like the member.
    @Test(arguments: allModes, allDepths) func formatVersionPatchIsTheEncodersText(_ mode: ColorMode, _ depth: SampleType) throws {
        var doc = richDoc(mode, depth)
        doc.name = "x\n  \"format_version\": 1,\n"
        var m = try PcraftWriter().prepareWithModel(doc, SaveOptions()).model
        let text = try ManifestJSON.encode(m)
        m.formatVersion = pcraftZip64FormatVersion
        #expect(ManifestJSON.withFormatVersion(text, pcraftZip64FormatVersion) == (try ManifestJSON.encode(m)))
        #expect(ManifestJSON.withFormatVersion(text, 10) == nil, "a longer number changes the length")
        #expect(ManifestJSON.formatVersionRange(Array("{\n  \"generator\": \"g\"\n}".utf8)) == nil)
    }

    /// Objects come out in path order (blobs, then tiles, each by hash), named by their content's hash.
    @Test func objectsAreInPathOrder() throws {
        let p = try PcraftWriter().prepare(richDoc(.rgb, .u8), SaveOptions())
        let paths = p.objects.map(\.name.path)
        #expect(paths == paths.sorted())
        #expect(Set(paths).count == paths.count)
        #expect(p.objects.contains { !$0.object.isTile } && p.objects.contains { $0.object.isTile })
        for (name, object) in p.objects {
            #expect(name.isTile == object.isTile)
            #expect(name.digest == PcraftCodec.digest(object.content))
            #expect(name.path.utf8.count == ObjectName.pathLength)
        }
    }

    /// The writer's hash cache keeps this save's tiles and no others, as before, and a resave reuses it.
    @Test func hashCacheFollowsTheDocument() throws {
        var doc = richDoc(.rgb, .u8)
        let w = PcraftWriter()
        _ = try w.saveZip(doc)
        var generations = Set<UInt64>()
        Convert.forEachSurface(doc) { s in s.forEachTile { _, t in generations.insert(t.generation) } }
        #expect(Set(w.hashCache.keys) == generations)
        let first = w.hashCache
        doc.layers.removeLast()
        let (bytes, _) = try w.saveZip(doc)
        var left = Set<UInt64>()
        Convert.forEachSurface(doc) { s in s.forEachTile { _, t in left.insert(t.generation) } }
        #expect(Set(w.hashCache.keys) == left)
        for g in left { #expect(w.hashCache[g] == first[g]) }
        #expect(try PcraftFormat.load(bytes) == doc)
    }

    /// A save handed its prepared bundle writes what one given a copy writes, forced ZIP64 included.
    @Test(arguments: [false, true]) func handedOverPreparedWritesTheSameBytes(_ forceZip64: Bool) throws {
        let doc = richDoc(.rgb, .u16)
        let w = PcraftWriter()
        w.forceZip64 = forceZip64
        w.setZipCacheBudget(0)
        let kept = try w.prepare(doc, SaveOptions())
        let copy = try w.writeZip(kept, into: ZipMemorySink()).0.bytes
        var handed: Prepared? = try w.prepare(doc, SaveOptions())
        let moved = try w.writeZip(handed.take()!, into: ZipMemorySink()).0.bytes
        #expect(moved == copy)
        #expect(kept.manifest.count > 0, "a copy keeps its manifest")
        #expect(try PcraftFormat.load(moved) == doc)
    }
}
