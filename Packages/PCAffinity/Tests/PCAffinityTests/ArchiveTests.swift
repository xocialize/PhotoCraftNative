// Port of photocraft-affinity (crates/affinity/src/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// The archive and the object stream (`mod archive` in photocraft's tests.rs): every storage method,
// checksums, budgets, cycles, hostile streams and allocation bombs.

import Testing
@testable import PCAffinity
import PCAffinitySynth

@Suite struct ArchiveTests {
    static func doc() -> [UInt8] {
        Synth.stream([
            ("Desc", .str("Document")),
            ("Visi", .bool(true)),
            ("Xfrm", .f64s([1, 0, 5, 0, 1, -2])),
            ("Colr", .def(7, ["RGBA"], [("_col", .structure([UInt8](repeating: 0, count: 16)))])),
            ("Same", .ref(7)),
            ("Null", .null),
            ("Kids", .shared([.def(8, ["Grup", "Node"], [("Desc", .str("g"))]), .ref(8)])),
            ("Crvs", .obj("PCvD", [("Data", .pos([.u8(0), .u32(1), .bool(true), .records(18, Array(repeating: [UInt8](repeating: 0, count: 18), count: 4))]))])),
            ("Enum", .enumeration(2, 1)),
            ("Tile", .entry("d/3")),
            ("Stat", .u8s([4, 0, 2])),
        ])
    }

    @Test func everyMethodRoundTripsWithChecksums() throws {
        let d = Self.doc()
        for method in Synth.Method.allCases {
            let file = Synth.container([("doc.dat", d, method), ("d/3", ascii("tile"), method)])
            var a = try Affinity.Archive(file)
            #expect(a.header.version == 12)
            #expect(try a.read("doc.dat") == d)
            #expect(try a.read("d/3") == ascii("tile"))
            #expect(a.extracted == d.count + 4)
            #expect(failure { try a.read("missing") } != nil)
            #expect(a.entryNames == ["d/3", "doc.dat"])
            #expect(a.entry("d/3")?.size == 4)
        }
    }

    @Test func theStreamParsesIntoSharedObjectsAndLinks() throws {
        let s = try Affinity.Stream.parse(Self.doc())
        let root = s.objects[s.root]
        #expect(root.classTag == "Pers")
        #expect(root.get("Desc") == .str("Document"))
        #expect(root.get("Xfrm") == .floats([1, 0, 5, 0, 1, -2]))
        guard case .obj(let a?)? = root.get("Colr"), case .obj(let b?)? = root.get("Same") else {
            Issue.record("Colr and Same are not linked objects")
            return
        }
        #expect(a == b)
        #expect(s.objects[a].classTag == "RGBA")
        #expect(s.objects[a].kind == .shared)
        guard case .array(let kids)? = root.get("Kids"), kids.count == 2, case .obj(let g?) = kids[0] else {
            Issue.record("Kids is not an array of objects")
            return
        }
        #expect(kids[0] == kids[1])
        #expect(s.objects[g].chain == ["Grup", "Node"])
        #expect(root.get("Enum") == .enumeration(id: 2, version: 1))
        #expect(root.get("Tile") == .entry("d/3"))
        #expect(root.get("Null") == .obj(nil))
        #expect(root.get("Stat") == .array([.uint(4), .uint(0), .uint(2)]))
        // The positional curve data: u8, u32, bool, then an array of 18-byte records.
        guard let crvs = s.obj(s.root, "Crvs"), let data = s.obj(crvs, "Data") else {
            Issue.record("no curve data")
            return
        }
        let fields = s.positional(data)
        #expect(fields.count == 4)
        #expect(fields.first == .uint(0))
        #expect(s.objects[data].kind == .positional)
    }

    @Test func checksumsSizesAndBudgetsAreEnforced() throws {
        let d = Self.doc()
        let file = Synth.container([("doc.dat", d, .zstd)])
        // Flip a byte inside the compressed payload, past the "#Fil" tag at offset 72.
        var broken = file
        broken[90] ^= 0x55
        var a = try Affinity.Archive(broken)
        #expect(failure { try a.read("doc.dat") } != nil)
        a = try Affinity.Archive(file, limits: Affinity.Limits(maxEntry: d.count - 1, maxTotal: Int.max))
        #expect(isLimit(failure { try a.read("doc.dat") }))
        a = try Affinity.Archive(file, limits: Affinity.Limits(maxEntry: Int.max, maxTotal: d.count + 1))
        _ = try a.read("doc.dat")
        #expect(isLimit(failure { try a.read("doc.dat") }))
        // A damaged byte in a stored entry fails the CRC.
        var stored = Synth.container([("doc.dat", d, .stored)])
        stored[80] ^= 0x01
        a = try Affinity.Archive(stored)
        #expect(failure { try a.read("doc.dat") } == .malformed("archive entry checksum mismatch"))
    }

    @Test func aDeclaredSizeSmallerThanTheDataIsRejectedNotTruncated() throws {
        let big = [UInt8](repeating: 7, count: 1 << 20)
        for method in [Synth.Method.zlib, .zstd] {
            var file = Synth.container([("doc.dat", big, method)])
            // Rewrite the declared size in the table to 1 KiB: decoding must stop and fail.
            let fat = Int(file[16..<24].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
            let sizeAt = fat + 59 + 5 + 8
            file.put(le(UInt64(1024)), at: sizeAt)
            var a = try Affinity.Archive(file)
            #expect(failure { try a.read("doc.dat") } == .malformed("archive entry size mismatch"), "\(method)")
        }
    }

    @Test func librariesAndCyclicTablesAreRejected() throws {
        let d = Self.doc()
        var file = Synth.container([("doc.dat", d, .stored)])
        var library = file
        library.put(ascii("rAsA"), at: 8)
        #expect(isUnsupported(failure { try Affinity.Archive(library) }))
        let fat = file[16..<24].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        file.put(le(fat), at: Int(fat) + 4)
        #expect(failure { try Affinity.Archive(file) } == .malformed("allocation tables form a cycle"))
    }

    @Test func hostileStreamsFailCleanly() {
        // Building and encoding a 2000-level tree recurses per level; parsing it must stop at 384.
        let deep = onLargeStack { () -> [UInt8] in
            var fields: [(Tag, F)] = []
            for _ in 0..<2000 { fields = [("Chld", .obj("Grup", fields))] }
            return Synth.stream(fields)
        }
        #expect(failure { try Affinity.Stream.parse(deep) } == .limit("objects nested too deeply"))
        // An array claiming four billion elements in a few bytes.
        let huge = Synth.stream([("Big_", .raw([0x81] + ascii("_giB") + [0xFF, 0xFF, 0xFF, 0xFF, 0]))])
        #expect(failure { try Affinity.Stream.parse(huge) } == .malformed("array longer than its data"))
        let forward = Synth.stream([("Link", .ref(99))])
        #expect(failure { try Affinity.Stream.parse(forward) } != nil)
        let twice = Synth.stream([("A___", .def(1, ["RGBA"], [])), ("B___", .def(1, ["RGBA"], []))])
        #expect(failure { try Affinity.Stream.parse(twice) } != nil)
        let unknown = Synth.stream([("X___", .raw([0x0B, 1, 2, 3, 4]))])
        #expect(isUnsupported(failure { try Affinity.Stream.parse(unknown) }))
        let d = Self.doc()
        for end in 0..<d.count {
            #expect(failure { try Affinity.Stream.parse(Array(d[..<end])) } != nil, "\(end)")
        }
    }

    @Test func aSmallCompressedEntryCannotMakeTheStreamAllocateGigabytes() throws {
        // Each decoded value takes tens of bytes, and a bool array packs eight in a byte: 16 MiB of
        // zero bits, a few KiB once compressed, would ask for 2^27 values (several GiB). An array of
        // one-byte values just past the budget fails the same way, before allocating.
        func field(_ code: UInt8, _ n: UInt32, _ data: Int) -> F {
            .raw([0x80 | code] + le(Tag("Big_").rawValue) + le(n) + [UInt8](repeating: 0, count: data))
        }
        let bools = UInt32(1) << 27
        let bytes = UInt32(Affinity.Stream.maxValues) + 1
        for f in [field(0x29, bools, Int(bools / 8)), field(0x01, bytes, Int(bytes))] {
            let d = Synth.stream([("Big_", f)])
            let file = Synth.container([("doc.dat", d, .zstd)])
            #expect(file.count < d.count / 100, "\(file.count) of \(d.count)")
            var a = try Affinity.Archive(file)
            let entry = try a.read("doc.dat")
            #expect(failure { try Affinity.Stream.parse(entry) } == .limit("too many values in the document stream"))
        }
    }

    @Test func mutatedContainersAndStreamsNeverTrap() {
        var rng = SeededRNG(seed: 3)
        let d = Self.doc()
        for _ in 0..<512 {
            let edits = (0..<Int.random(in: 1..<24, using: &rng)).map { _ in
                (Int.random(in: 0..<4096, using: &rng), UInt8.random(in: 0...255, using: &rng))
            }
            for method in Synth.Method.allCases {
                var file = Synth.container([("doc.dat", d, method)])
                for (i, v) in edits { file[i % file.count] = v }
                if var a = try? Affinity.Archive(file), let bytes = try? a.read("doc.dat") {
                    _ = failure { try Affinity.Stream.parse(bytes) }
                }
            }
            var s = d
            for (i, v) in edits { s[i % s.count] = v }
            _ = failure { try Affinity.Stream.parse(s) }
        }
    }

    @Test func predictorsUndoByteAnd16BitDeltas() throws {
        // 0x40: byte delta.
        var b: [UInt8] = [1, 1, 1, 253]
        try Affinity.unpredict(&b, 0x41)
        #expect(b == [1, 2, 3, 0])
        // 0x80: 16-bit little-endian delta (a trailing odd byte is left alone).
        var w: [UInt8] = [1, 0, 1, 0, 0xFF, 0xFF, 9]
        try Affinity.unpredict(&w, 0x80)
        #expect(w == [1, 0, 2, 0, 1, 0, 9])
        // 0xA0: byte delta, then a 64 KiB tile's high and low planes are interleaved.
        var tile = [UInt8](repeating: 0, count: 0x10000)
        tile[0] = 0xAB  // high byte of sample 0 (after the delta, every byte becomes 0xAB)
        try Affinity.unpredict(&tile, 0xA0)
        #expect(Array(tile[0..<4]) == [0xAB, 0xAB, 0xAB, 0xAB])
        var planes = [UInt8](repeating: 0, count: 0x10000)
        planes[0] = 0x12  // high of sample 0
        planes[1] = 0xEE  // high of sample 1 (delta: 0x12 + 0xEE = 0x00)
        try Affinity.unpredict(&planes, 0xA0)
        #expect(Array(planes[0..<4]) == [0x00, 0x12, 0x00, 0x00])
        var unknown: [UInt8] = [0]
        #expect(isUnsupported(failure { try Affinity.unpredict(&unknown, 0xC1) }))
    }

    @Test func olderTablesNumberTheirMethodsAndLaterSavesWin() throws {
        // Two tables: the newer (first in the chain) replaces entry 1 and deletes entry 2.
        let d = ascii("new")
        let old = ascii("old!")
        var out = [UInt8](repeating: 0, count: 72)
        out.put(Affinity.magic, at: 0)
        out.put(le(UInt16(9)), at: 4)
        out.put(ascii("nsrP"), at: 8)
        out.put(ascii("#Inf"), at: 12)
        out.put(ascii("Prot"), at: 64)
        let newAt = UInt64(out.count)
        out += ascii("#Fil") + d
        let oldAt = UInt64(out.count)
        out += ascii("#Fil") + old
        func record(_ id: UInt32, _ flag: UInt8, _ offset: UInt64, _ data: [UInt8], name: String?) -> [UInt8] {
            var r = le(id) + [flag]
            if flag != 2 {
                r += le(offset) + le(UInt64(data.count)) + le(UInt64(data.count)) + le(crc(data)) + [0] + le(UInt32(0))
            }
            if let name { r += le(UInt16(name.utf8.count)) + ascii(name) }
            return r
        }
        func table(_ tag: String, next: UInt64, date: UInt64, _ records: [[UInt8]]) -> [UInt8] {
            ascii(tag) + le(next) + le(date) + [UInt8](repeating: 0, count: 24) + le(UInt32(records.count))
                + [UInt8](repeating: 0, count: 8) + le(UInt16(0)) + [0] + records.flatMap { $0 }
        }
        let olderAt = UInt64(out.count)
        out += table("#FT2", next: 0, date: 1, [record(1, 0, oldAt, old, name: "doc.dat"), record(2, 0, oldAt, old, name: "gone")])
        let newerAt = UInt64(out.count)
        out += table("#FT2", next: olderAt, date: 2, [record(1, 1, newAt, d, name: nil), record(2, 2, 0, [], name: nil)])
        out.put(le(newerAt), at: 16)
        var a = try Affinity.Archive(out)
        #expect(a.revisions == 2)
        #expect(a.entryNames == ["doc.dat"])
        #expect(try a.read("doc.dat") == d)
    }
}
