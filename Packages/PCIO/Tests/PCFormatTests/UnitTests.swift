// Unit tests of the format's modules.
// Port of photocraft-format's inline tests (crates/format/src/migrate.rs, finite.rs, convert.rs,
// read.rs, manifest.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
@testable import PCFormat
import PCDocument
import PCFoundation
import Testing

@Suite struct MigrateTests {
    static let renameTitle: Migrate.Step = { (v: inout JSONTree) throws(FormatError) in
        var d = v["document"]
        let t = d["title"].take()
        d["title"] = .null
        d["name"] = t
        v["document"] = d
    }
    static let addField: Migrate.Step = { (v: inout JSONTree) throws(FormatError) in v["document"]["added"] = .bool(true) }

    static func json(_ s: String) throws -> JSONTree { try JSONTree.parse(Array(s.utf8)) }

    @Test func chainedStepsRunInOrder() throws {
        var v = try MigrateTests.json(#"{"format_version": 1, "document": {"title": "old"}}"#)
        let found = try Migrate.migrateWith(&v, [MigrateTests.renameTitle, MigrateTests.addField], target: 3)
        #expect(found == 1)
        #expect(v["format_version"] == .number("3"))
        #expect(v["document"]["name"] == .string("old"))
        #expect(v["document"]["added"] == .bool(true))
    }

    @Test func partialChainFromMiddle() throws {
        var v = try MigrateTests.json(#"{"format_version": 2, "document": {}}"#)
        try Migrate.migrateWith(&v, [MigrateTests.renameTitle, MigrateTests.addField], target: 3)
        #expect(v["document"]["added"] == .bool(true))
        #expect(v["document"].get("name") == nil)
    }

    @Test func tooNewAndInvalidVersions() throws {
        var v = try MigrateTests.json(#"{"format_version": 99}"#)
        #expect { try Migrate.migrate(&v) } throws: { e in
            if case FormatError.tooNew(found: 99, supported: _) = e { return true }
            return false
        }
        for s in [#"{"format_version": 0}"#, "{}", #"{"format_version": 1.0}"#, #"{"format_version": -1}"#] {
            var w = try MigrateTests.json(s)
            #expect(throws: FormatError.self, "\(s)") { try Migrate.migrate(&w) }
        }
        var w = try MigrateTests.json(#"{"format_version": 1}"#)
        #expect(throws: FormatError.self) { try Migrate.migrateWith(&w, [], target: 2) }
    }

    @Test func currentVersionIsNoop() throws {
        var v = try MigrateTests.json(#"{"format_version": \#(PcraftFormat.formatVersion)}"#)
        #expect(try Migrate.migrate(&v) == PcraftFormat.formatVersion)
    }

    /// A migration step changes nothing it doesn't touch: u64 ids and floats keep their text.
    @Test func migrationKeepsNumbersExact() throws {
        let text = #"{"format_version":1,"document":{"id":18446744073709551615,"x":0.30000001192092896,"title":"t"}}"#
        var v = try MigrateTests.json(text)
        try Migrate.migrateWith(&v, [MigrateTests.addField], target: 2)
        #expect(String(decoding: v.bytes, as: UTF8.self).contains("18446744073709551615"))
        #expect(String(decoding: v.bytes, as: UTF8.self).contains("0.30000001192092896"))
    }
}

@Suite struct JSONTreeTests {
    @Test func parsesAndRejectsLikeSerdeJSON() throws {
        let ok = [#"{"a":[1,2.5,-3e2,"x\n\u00e9\ud83d\ude00"],"b":null,"c":true}"#, "  [ ]  ", "0", "\"s\""]
        for s in ok { _ = try JSONTree.parse(Array(s.utf8)) }
        let bad = ["{", "[1,]", "{\"a\":1,}", "01", "1.", "-", "\"\\x\"", "\"\u{1}\"", "nul", "{} x", "\"\\ud800\"", "{1:2}"]
        for s in bad { #expect(throws: JSONTree.ParseError.self, "\(s)") { try JSONTree.parse(Array(s.utf8)) } }
        #expect(throws: JSONTree.ParseError.self) { try JSONTree.parse([0x22, 0xFF, 0x22]) }
    }

    @Test func roundTripsText() throws {
        let s = #"{"a":[1,2.5,"x\"y\\z\n"],"b":{"c":null,"d":false}}"#
        let t = try JSONTree.parse(Array(s.utf8))
        #expect(String(decoding: t.bytes, as: UTF8.self) == s)
        var pretty: [UInt8] = []
        t.writePretty(&pretty, indent: 0)
        #expect(try JSONTree.parse(pretty) == t)
        #expect(String(decoding: pretty, as: UTF8.self).contains("\"c\": null"))
    }
}

@Suite struct FiniteTests {
    struct Inner: Encodable {
        var gamma: Float
        var offsets: [Double]
    }

    enum Content: Encodable {
        case exposure(Float)
        case levels(Double, Double)

        // serde's externally tagged form: {"Exposure":{"exposure":…}}, {"Levels":[…, …]}.
        enum Tag: String, CodingKey { case Exposure, Levels }
        enum Field: String, CodingKey { case exposure }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Tag.self)
            switch self {
            case .exposure(let e):
                var n = c.nestedContainer(keyedBy: Field.self, forKey: .Exposure)
                try n.encode(e, forKey: .exposure)
            case let .levels(a, b):
                var n = c.nestedUnkeyedContainer(forKey: .Levels)
                try n.encode(a)
                try n.encode(b)
            }
        }
    }

    struct Outer: Encodable {
        var dpi: Float
        var inner: Inner?
        var layers: [Content]
        var named: [String: Float]
    }

    static func outer() -> Outer {
        Outer(dpi: 72, inner: Inner(gamma: 1, offsets: [0, 1.5]), layers: [.levels(0, 1), .exposure(0.5)], named: ["blur": 2])
    }

    static func path<T: Encodable>(_ v: T) -> String {
        do throws(Finite.Problem) {
            try Finite.check(v)
            return "<finite>"
        } catch {
            if case .nonFinite(let p) = error { return p }
            return "<other: \(error)>"
        }
    }

    @Test func finiteValuesPassAndEachPositionIsNamed() throws {
        try Finite.check(FiniteTests.outer())
        var o = FiniteTests.outer()
        o.dpi = .nan
        #expect(FiniteTests.path(o) == "dpi")
        o = FiniteTests.outer()
        o.inner?.offsets[1] = .infinity
        #expect(FiniteTests.path(o) == "inner.offsets[1]")
        o = FiniteTests.outer()
        o.layers[1] = .exposure(-.infinity)
        #expect(FiniteTests.path(o) == "layers[1].Exposure.exposure")
        o = FiniteTests.outer()
        o.layers[0] = .levels(0, .nan)
        #expect(FiniteTests.path(o) == "layers[0].Levels[1]")
        o = FiniteTests.outer()
        o.named["blur"] = .nan
        #expect(FiniteTests.path(o) == "named.blur")
        #expect(FiniteTests.path(Float.nan) == "")
    }

    /// The per-layer manifest walk names nested layers the way the whole-tree walk would.
    @Test func nestedLayerPathsMatchTheTreeWalk() throws {
        var doc = Document(name: "n", size: PixelSize(width: 2, height: 2), mode: .rgb, depth: .u8)
        var adj = Layer(name: "adj", content: .adjustment(.exposure(.init(exposure: 0, offset: 0, gamma: 1))))
        adj.opacity = .nan
        doc.layers = [Layer.group("g", [Layer.raster("r", format: doc.pixelFormat), adj])]
        let m = Manifest(formatVersion: 1, generator: "t", document: Convert.docM(doc, Collect(PcraftWriter())))
        do throws(Finite.Problem) {
            try Finite.checkManifest(m)
            Issue.record("non-finite opacity passed")
        } catch {
            #expect(error == .nonFinite(path: "document.layers[0].content.children[1].opacity"))
        }
        #expect(FiniteTests.path(m) == "document.layers[0].content.children[1].opacity")
    }
}

@Suite struct ConvertTests {
    @Test func unhexRejectsLeadingPlus() {
        // An integer parser accepts a leading `+`; unhex must not (photocraft #1818).
        for s in ["+5", "ab+5", "+5cd"] { #expect(throws: FormatError.self, "\(s)") { try Convert.unhex(s) } }
    }

    @Test func unhexRejectsNonHexCharacters() {
        for s in ["zz", " 1", "g0"] { #expect(throws: FormatError.self, "\(s)") { try Convert.unhex(s) } }
    }

    @Test func unhexAcceptsValidHex() throws {
        #expect(try Convert.unhex("00") == [0x00])
        #expect(try Convert.unhex("ff") == [0xFF])
        #expect(try Convert.unhex("0123456789abcdef") == [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF])
        #expect(try Convert.unhex("FF") == [0xFF])
    }

    @Test func unhexRejectsOddLength() {
        for s in ["0", "abc"] { #expect(throws: FormatError.self, "\(s)") { try Convert.unhex(s) } }
    }

    @Test func olderChannelsLoadWithDefaultOptions() throws {
        let fmt = String(decoding: try JSONEncoder().encode(PixelFormat.gray8), as: UTF8.self)
        let old = #"{"name":"Alpha 1","surface":{"format":\#(fmt),"default":"00","tiles":[]},"spot":null}"#
        let c = try JSONDecoder().decode(ChannelM.self, from: Data(old.utf8))
        #expect(c.color == AlphaChannel.defaultColor)
        #expect(c.opacity == 0.5)
        #expect(c.indicates == .maskedAreas)
    }
}

@Suite struct ReadTests {
    static func temp(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let dir = tempDir("read-\(name)")
        let p = dir.appendingPathComponent("f.bin")
        try Data(bytes).write(to: p)
        return p
    }

    @Test func readsWholeFileAcrossManyChunks() throws {
        let data = (0 ..< 100_003).map { UInt8($0 * 7 % 251) }
        let p = try ReadTests.temp("chunks", data)
        for chunk in [1, 7, 4096, 100_003, 1 << 20] { #expect(try FileRead.readFile(p, chunk: chunk) == data, "chunk \(chunk)") }
        #expect(try FileRead.readFile(p) == data)
        #expect(try FileRead.readFile(p, chunk: 0) == data, "a zero chunk still makes progress")
        // From an open reader, whatever the hint says.
        for hint: UInt64 in [0, 10, UInt64(data.count), 1 << 20] {
            var r = MemoryChunkReader(data)
            #expect(try FileRead.readAll(&r, sizeHint: hint) == data, "hint \(hint)")
        }
        remove(p.deletingLastPathComponent())
    }

    @Test func emptyAndMissingFiles() throws {
        let p = try ReadTests.temp("empty", [])
        #expect(try FileRead.readFile(p).isEmpty)
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("photocraft-read-does-not-exist.psb")
        #expect { try FileRead.readFile(missing) } throws: { ($0 as? IOError)?.kind == .notFound }
        remove(p.deletingLastPathComponent())
    }

    @Test func aFileTooLargeForMemoryIsAClearError() throws {
        // More than any address space can hold.
        #expect { try FileRead.bufferFor(.max) } throws: { e in
            guard let e = e as? IOError else { return false }
            return e.kind == .outOfMemory && e.message.contains("18446744.07 TB")
        }
        #expect { try FileRead.bufferFor(1 << 62) } throws: { ($0 as? IOError)?.kind == .outOfMemory }
        #expect(try FileRead.bufferFor(1024).capacity >= 1024)
    }

    @Test func sizesReadLikeTheOSShowsThem() {
        #expect(FileRead.sizeText(512) == "512 bytes")
        #expect(FileRead.sizeText(4_750_000_000) == "4.75 GB")
        #expect(FileRead.sizeText(759_000_000) == "759.00 MB")
    }
}
