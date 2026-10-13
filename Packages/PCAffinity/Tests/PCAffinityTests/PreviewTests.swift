// Port of photocraft-affinity (crates/affinity/src/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// The embedded preview (`mod preview` in photocraft's tests.rs): the indexed thumbnail record and its
// strictly validated PNG.

import Testing
@testable import PCAffinity

@Suite struct PreviewTests {
    static func fixture() -> [UInt8] {
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        png += be(UInt32(13)) + ascii("IHDR") + be(UInt32(2)) + be(UInt32(1)) + [8, 6, 0, 0, 0]
        png += be(crc(png[12...]))
        png += [0, 0, 0, 0] + ascii("IDAT") + be(crc(ascii("IDAT")))
        png += [0, 0, 0, 0] + ascii("IEND") + be(crc(ascii("IEND")))
        var b = [UInt8](repeating: 0, count: 72)
        b.put(Affinity.magic, at: 0)
        b.put(le(UInt16(12)), at: 4)
        b.put(ascii("nsrP"), at: 8)
        b.put(ascii("#Inf"), at: 12)
        b.put(le(UInt64(72)), at: 24)
        b.put(ascii("Prot"), at: 64)
        b += [0xFF, 0xFF, 0xFF, 0xFF] + ascii("Thmb")
        b += le(UInt32(1)) + le(UInt32(png.count + 13)) + le(UInt32(29)) + le(UInt32(0)) + le(UInt32(png.count))
        b.append(1)
        b += png
        return b
    }

    /// Rewrite the record's two PNG length fields after the PNG grew or shrank.
    static func fixLengths(_ b: inout [UInt8]) {
        let length = UInt32(b.count - 101)
        b.put(le(length + 13), at: 84)
        b.put(le(length), at: 96)
    }

    @Test func indexedPreviewAndHeader() throws {
        let b = Self.fixture()
        #expect(try Affinity.header(b).version == 12)
        let p = try Affinity.preview(b)
        #expect(p.width == 2 && p.height == 1)
        #expect(p.png == Array(b[101...]))
        #expect(p.range == 101..<b.count)
    }

    @Test func everyTruncationIsRejected() {
        let b = Self.fixture()
        for end in 0..<b.count {
            #expect(failure { try Affinity.preview(Array(b[..<end])) } != nil, "\(end)")
        }
    }

    @Test func rejectsAssetsVersionsOffsetsLengthsAndBombs() {
        let b = Self.fixture()
        let edits: [(Int, [UInt8])] = [
            (4, le(UInt64(13))),
            (8, ascii("urBR")),
            (24, le(UInt64.max)),
            (24, le(UInt64(1))),
            (24, le(UInt64(0))),
            (84, le(UInt32.max)),
            (88, le(UInt32(30))),
            (96, le(UInt32.max)),
            (117, be(UInt32(5000))),
        ]
        for (offset, value) in edits {
            var broken = b
            broken.put(value, at: offset)
            #expect(failure { try Affinity.preview(broken) } != nil, "offset \(offset)")
        }
        // Versions 8 to 11 store the same record (checked on public Affinity 1 and 2 files).
        for version in UInt16(8)..<12 {
            var legacy = b
            legacy.put(le(version), at: 4)
            #expect(failure { try Affinity.preview(legacy) } == nil)
        }
        // Flags 4 and 8 occur in real files; the low two bits mark other container variants.
        for (flags, ok) in [(UInt16(4), true), (8, true), (1, false), (2, false)] {
            var variant = b
            variant.put(le(flags), at: 6)
            #expect((failure { try Affinity.preview(variant) } == nil) == ok, "flags \(flags)")
        }
        var old = b
        old.put(le(UInt16(7)), at: 4)
        #expect(isUnsupported(failure { try Affinity.preview(old) }))
    }

    @Test func anUnindexedPNGOrResourceIsNeverUsed() {
        var b = Self.fixture()
        b.put(le(UInt64(0)), at: 24)
        #expect(failure { try Affinity.preview(b) } != nil)
        b.put(le(UInt64(72)), at: 24)
        b.put(ascii("Meta"), at: 76)
        #expect(failure { try Affinity.preview(b) } != nil)
    }

    @Test func everyChunkChecksumIncludingTheEndIsChecked() {
        let b = Self.fixture()
        for at in [130, b.count - 1] {
            var damaged = b
            damaged[at] ^= 1
            #expect(failure { try Affinity.preview(damaged) } == .malformed("PNG chunk checksum"))
        }
        let ancillary = [0, 0, 0, 0] + ascii("tEXt") + be(crc(ascii("tEXt")))
        var withAncillary = b
        let at = b.count - 12
        withAncillary.insert(contentsOf: ancillary, at: at)
        Self.fixLengths(&withAncillary)
        #expect(failure { try Affinity.preview(withAncillary) } == nil)
        withAncillary[at + 8] ^= 1
        #expect(failure { try Affinity.preview(withAncillary) } == .malformed("PNG chunk checksum"))
    }

    @Test func compressedMetadataAndAnimationAreNotPreviewSupport() {
        for kind in ["zTXt", "iTXt", "iCCP", "acTL", "fcTL", "fdAT"] {
            var b = Self.fixture()
            b.insert(contentsOf: [0, 0, 0, 0] + ascii(kind) + be(crc(ascii(kind))), at: b.count - 12)
            Self.fixLengths(&b)
            #expect(isUnsupported(failure { try Affinity.preview(b) }), "\(kind)")
        }
    }

    @Test func criticalChunksFollowASingleCompletePNGLayout() {
        func withChunks(_ kinds: [String]) -> [UInt8] {
            // File, record and complete first IHDR.
            var b = Array(Self.fixture()[..<134])
            for kind in kinds {
                b += [0, 0, 0, 0] + ascii(kind) + be(crc(ascii(kind)))
            }
            Self.fixLengths(&b)
            return b
        }
        #expect(failure { try Affinity.preview(withChunks(["IDAT", "IDAT", "IEND"])) } == nil)
        // PNG readers must not reject an otherwise valid unknown ancillary chunk just because its
        // reserved (third-letter) bit is set; future versions can define it.
        #expect(failure { try Affinity.preview(withChunks(["abct", "IDAT", "IEND"])) } == nil)
        for kinds in [
            ["IEND"],
            ["IDAT", "IHDR", "IEND"],
            ["PLTE", "PLTE", "IDAT", "IEND"],
            ["IDAT", "PLTE", "IEND"],
            ["IDAT", "tEXt", "IDAT", "IEND"],
            ["ABCD", "IDAT", "IEND"],
            ["IDAT", "IEND", "tEXt"],
        ] {
            #expect(failure { try Affinity.preview(withChunks(kinds)) } != nil, "\(kinds)")
        }
    }

    // photocraft's proptests, as seeded loops.

    @Test func arbitraryInputNeverTraps() {
        var rng = SeededRNG(seed: 1)
        for _ in 0..<256 {
            let n = Int.random(in: 0..<2048, using: &rng)
            var b = (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
            // Half the cases start with the signature so they reach past the first check.
            if Bool.random(using: &rng), b.count >= 4 { b.put(Affinity.magic, at: 0) }
            _ = failure { try Affinity.header(b) }
            _ = failure { try Affinity.preview(b) }
        }
    }

    @Test func mutationsNeverTrap() {
        var rng = SeededRNG(seed: 2)
        for _ in 0..<256 {
            var b = Self.fixture()
            for _ in 0..<Int.random(in: 0..<32, using: &rng) {
                let i = Int.random(in: 0..<200, using: &rng)
                if i < b.count { b[i] = UInt8.random(in: 0...255, using: &rng) }
            }
            _ = failure { try Affinity.preview(b) }
        }
    }
}
