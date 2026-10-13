// Tests ported from photocraft-io (crates/io/src/linked.rs `#[cfg(test)]`, and the linked-block
// parts of crates/io/tests/smart_contents_identity.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import Foundation
import PCDocument
import PCIOCore
@testable import PCIOSmart
import PCPSD
import Testing

@Suite struct LinkedTests {
    typealias LF = Linked.LinkedFile

    @Test func roundTripsAndFindsByUuid() {
        let a = LF(uuid: "abc-1", fileName: "a.png", bytes: [1, 2, 3])
        let b = LF(uuid: "def-2", fileName: "b.psd", bytes: [UInt8](repeating: 9, count: 10))
        let data = Linked.encodeLinkedFile(a) + Linked.encodeLinkedFile(b)
        #expect(Linked.parseLinkedFiles(data) == [a, b])
        var meta = Metadata()
        meta.psdGlobalBlocks.append(PSDGlobalBlock(signature: "8BIM", key: "lnk2", data: data))
        #expect(Linked.findLinkedFile(meta, "def-2") == b)
        #expect(Linked.findLinkedFile(meta, "zzz") == nil)
        #expect(Linked.findLinkedFile(meta, "") == nil)
        // Only lnk2/lnk3/lnkD are searched.
        var external = Metadata()
        external.psdGlobalBlocks.append(PSDGlobalBlock(signature: "8BIM", key: "lnkE", data: data))
        #expect(Linked.findLinkedFile(external, "def-2") == nil)
    }

    @Test func blocksArePrunedAndExtended() throws {
        let a = LF(uuid: "a", fileName: "a.png", bytes: [0x89, 0x50, 0x4E, 0x47, 1])
        let b = LF(uuid: "b", fileName: "b.psb", bytes: Array("8BPS".utf8) + [0, 2] + Array("rest".utf8))
        let c = LF(uuid: "c", fileName: "c", bytes: [7, 7, 7])
        let data = Linked.encodeLinkedFile(a) + Linked.encodeLinkedFile(b)
        #expect(Linked.blockUuids(data) == ["a", "b"])
        #expect(Linked.rebuildBlock(data, { _ in true }, []) == nil)
        let out = try #require(Linked.rebuildBlock(data, { $0 != "a" }, [c]))
        #expect(Linked.parseLinkedFiles(out) == [b, c])
        try PSDTaggedBlock(key: "lnk2", bytes: out).checkStructure()
        #expect(Linked.fileType(b.bytes) == "8BPB")
        #expect(Linked.fileType(a.bytes) == "PNGf")
        #expect(Linked.fileType(Array("8BPS".utf8) + [0, 1]) == "8BPS")
        #expect(Linked.fileType([0xFF, 0xD8, 0xFF]) == "JPEG")
        #expect(Linked.fileType([0x4D, 0x4D, 0, 42]) == "TIFF")
        #expect(Linked.fileType(Array("GIF89a".utf8)) == "GIFf")
        #expect(Linked.fileType([1]) == "    ")
        // A malformed tail is kept as is.
        let bad = Linked.encodeLinkedFile(a) + [0, 0, 0, 0, 0, 0, 1, 0, 9]
        let kept = try #require(Linked.rebuildBlock(bad, { _ in true }, [c]))
        #expect(kept.starts(with: bad))
    }

    @Test func malformedDataIsIgnored() {
        #expect(Linked.parseLinkedFiles([0, 0, 0, 0, 0, 0, 0, 200, 1, 2]).isEmpty)
        #expect(Linked.parseLinkedFiles([]).isEmpty)
        var d = Linked.encodeLinkedFile(LF(uuid: "x", fileName: "f", bytes: [5, 5, 5, 5]))
        d.removeLast(6)
        #expect(Linked.parseLinkedFiles(d).isEmpty)
        #expect(Linked.blockUuids([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0]).isEmpty)
        #expect(Linked.copyItem([1, 2, 3], "x", "y") == nil)
    }

    @Test func copyingLinkedItemPreservesUnknownExternalPayload() throws {
        var raw = Linked.encodeLinkedFile(LF(uuid: "old", fileName: "missing.psb", bytes: [7, 7, 7, 7, 7]))
        raw.replaceSubrange(8 ..< 12, with: Array("liFE".utf8))
        let copy = try #require(Linked.copyItem(raw, "old", "independent-copy"))
        #expect(Linked.blockUuids(copy) == ["independent-copy"])
        func len(_ b: [UInt8]) -> Int { Int(b.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }) }
        let (originalLen, copiedLen) = (len(raw), len(copy))
        #expect(copy[8 ..< 16] == raw[8 ..< 16])
        #expect(copy[(17 + "independent-copy".count) ..< (8 + copiedLen)] == raw[20 ..< (8 + originalLen)])
        #expect(copy.count % 4 == 0)
        #expect(Linked.copyItem(raw, "missing", "new") == nil)
        #expect(Linked.copyItem(raw, "old", String(repeating: "u", count: 256)) == nil, "a uuid longer than 255 bytes")
    }

    /// An opaque external item keeps its uuid (listed) without embedded bytes (not parsed), and a
    /// rebuilt block keeps it first (`independent_unavailable_link_retains_separate_preserved_record`).
    @Test func externalItemsAreListedButNotParsed() throws {
        var block = Linked.encodeLinkedFile(LF(uuid: "orig", fileName: "contents.psb", bytes: [1, 2, 3, 4]))
        block.replaceSubrange(8 ..< 12, with: Array("liFE".utf8))
        #expect(Linked.parseLinkedFiles(block).isEmpty)
        #expect(Linked.blockUuids(block) == ["orig"])
        let added = LF(uuid: "independent", fileName: "copy.psb", bytes: [9, 9])
        let rebuilt = try #require(Linked.rebuildBlock(block, { _ in true }, [added]))
        #expect(rebuilt.starts(with: block))
        #expect(Linked.blockUuids(rebuilt) == ["orig", "independent"])
        #expect(Linked.parseLinkedFiles(rebuilt) == [added])
    }

    /// Our writer and PCPSD's lenient reader agree on every field of an item.
    @Test func encodedItemsReadInPCPSD() throws {
        let f = LF(uuid: "6f1c2c3e-uuid", fileName: "Ünïcode name.psb", bytes: Array("8BPS".utf8) + [0, 2, 9, 9])
        let parsed = try PSDLinkedFiles(bytes: Data(Linked.encodeLinkedFile(f)))
        let info = try #require(parsed.items.first?.info)
        #expect(info.kind == "liFD" && info.version == 7 && info.uniqueID == f.uuid && info.fileName == f.fileName)
        #expect([UInt8](info.data) == f.bytes)
        #expect(info.fileType == "8BPB" && info.creator == "8BIM")
        #expect(Linked.parseLinkedFiles([UInt8](parsed.serialized())) == [f])
    }
}
