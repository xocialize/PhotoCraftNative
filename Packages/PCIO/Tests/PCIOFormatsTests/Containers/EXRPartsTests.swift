// Tests for the multi-part EXR import. Ported: photocraft-engine's exr_cmds.rs tests (the
// exr_parts API they drive), photocraft-codecs' tests/exr_multipart.rs and the listing half of
// tests/exr_cryptomatte.rs (MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors).
// Added: every block compression round-tripped through `EXRTestWriter`, scan-line and tiled
// layouts, and a bit-exact comparison with ImageIO on the EXR files shipped with macOS and Xcode
// (skipped where absent).

import CoreGraphics
import Foundation
import ImageIO
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIOFormats

@Suite("EXRParts")
struct EXRPartsTests {
    typealias Kit = ContainerTestKit

    static func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 1e-6 }

    /// A square part of float channels (photocraft's `layer_f32`).
    static func layerF32(_ name: String, _ comp: EXRParts.Compression, _ chans: [(String, [Float])]) -> Kit.EXRPart {
        let n = chans.first { !$0.1.isEmpty }?.1.count ?? 0
        let side = Int(Double(n).squareRoot().rounded())
        return Kit.EXRPart(name: name, width: side, height: side, compression: comp,
                           channels: chans.map { Kit.EXRChannel(name: $0.0, type: .float, values: $0.1) })
    }

    /// Three parts as an AOV-heavy render might write them: a depth-only `Z` part first, the
    /// `beauty` RGBA part second and a `diffuse` RGB part third, each with its own compression.
    static func aovFile() -> [UInt8] {
        let n = 16
        let z = (0 ..< n).map { Float($0) }
        let beauty: [[Float]] = (0 ..< 4).map { c in
            (0 ..< n).map { i in [Float(i) / 15, 1 - Float(i) / 15, 0.25, 1][c] }
        }
        let diffuse: [[Float]] = (0 ..< 3).map { c in [Float](repeating: [0.3, 0.6, 0.9][c], count: n) }
        return Kit.exr([
            layerF32("Z", .none, [("Z", z)]),
            layerF32("beauty", .zips, [("R", beauty[0]), ("G", beauty[1]), ("B", beauty[2]), ("A", beauty[3])]),
            layerF32("diffuse", .rle, [("R", diffuse[0]), ("G", diffuse[1]), ("B", diffuse[2])]),
        ])
    }

    static func stereoFile() -> [UInt8] {
        func px(_ k: Float) -> [(String, [Float])] {
            ["R", "G", "B", "A"].enumerated().map { c, name in (name, (0 ..< 4).map { i in c == 0 ? Float(i) / 3 * k : k }) }
        }
        var left = layerF32("beauty_left", .none, px(0.1))
        left.view = "left"
        var right = layerF32("beauty_right", .none, px(0.9))
        right.view = "right"
        return Kit.exr([left, right])
    }

    // MARK: - photocraft-codecs tests/exr_multipart.rs

    @Test func infoListsEveryPart() throws {
        let parts = try EXRParts.info(Self.aovFile())
        #expect(parts.count == 3)
        #expect(parts.map(\.name) == ["Z", "beauty", "diffuse"])
        let z = parts[0]
        #expect(z.width == 4 && z.height == 4)
        #expect(!z.deep && !z.tiled)
        #expect(z.channels.map(\.name) == ["Z"])
        #expect(!z.channels[0].isHalf)
        let beauty = parts[1]
        // OpenEXR stores the channel list alphabetically; the info shows the file as-is.
        #expect(beauty.channels.map(\.name) == ["A", "B", "G", "R"])
        #expect(beauty.channels.allSatisfy { $0.type == .float })
        #expect(beauty.compression == .zips)
        // The colour ranking photocraft's plain decode picks a part with.
        #expect(parts.map(\.colorRank) == [1, 4, 3])
    }

    @Test func partsDecodeByIndex() throws {
        let bytes = Self.aovFile()
        // The depth part opens as a grayscale image instead of failing the file.
        let z = try EXRParts.decodePart(bytes, 0)
        #expect(z.layout == .gray)
        for i in 0 ..< 16 { #expect(Self.near(z.samples[i], Float(i)), "pixel \(i)") }
        let beauty = try EXRParts.decodePart(bytes, 1)
        #expect(beauty.layout == .rgba)
        for i in 0 ..< 16 {
            #expect(Self.near(beauty.samples[i * 4], Float(i) / 15) && Self.near(beauty.samples[i * 4 + 1], 1 - Float(i) / 15))
            #expect(Self.near(beauty.samples[i * 4 + 2], 0.25) && Self.near(beauty.samples[i * 4 + 3], 1))
        }
        let diffuse = try EXRParts.decodePart(bytes, 2)
        #expect(diffuse.layout == .rgb)
        #expect(Self.near(diffuse.samples[(2 * 4 + 1) * 3 + 2], 0.9))
        #expect(!diffuse.half)
    }

    @Test func partIndexOutOfRangeErrors() {
        let e = Kit.error { try EXRParts.decodePart(Self.aovFile(), 3) }
        let m = (e as? PCIOError)?.description ?? ""
        #expect(m.contains("out of range") && m.contains("3 parts"), "\(m)")
    }

    @Test func viewsAreListed() throws {
        let bytes = Self.stereoFile()
        let parts = try EXRParts.info(bytes)
        #expect(parts.map(\.view) == ["left", "right"])
        let left = try EXRParts.decodePart(bytes, 0)
        #expect(Self.near(left.samples[3 * 4], 0.1) && Self.near(left.samples[1], 0.1))
        let right = try EXRParts.decodePart(bytes, 1)
        #expect(Self.near(right.samples[3 * 4 + 1], 0.9), "right's G is 0.9 everywhere")
    }

    @Test func singleYChannelPartsDecodeAsGray() throws {
        let v = (0 ..< 4).map { Float($0) / 3 }
        let bytes = Kit.exr([Self.layerF32("main", .zips, [("Y", v)])])
        let img = try EXRParts.decodePart(bytes, 0)
        #expect(img.layout == .gray)
        #expect(img.samples == v)
    }

    @Test func halfFloatPartsStayHalf() throws {
        let chans = ["R", "G", "B"].enumerated().map { c, n in Kit.EXRChannel(name: n, type: .half, values: [Float](repeating: [0.5, 0.25, 1][c], count: 4)) }
        let bytes = Kit.exr([Kit.EXRPart(name: "half", width: 2, height: 2, channels: chans)])
        let img = try EXRParts.decodePart(bytes, 0)
        #expect(img.half)
        #expect(Self.near(img.samples[3 * 3], 0.5))
    }

    @Test func truncatedFilesErrorNeverPanic() {
        let bytes = Self.aovFile()
        for end in stride(from: 8, to: bytes.count, by: 5) {
            let cut = Array(bytes[..<end])
            _ = try? EXRParts.info(cut)
            _ = try? EXRParts.decodePart(cut, 1)
            _ = try? EXRParts.entries(cut)
            _ = try? EXRParts.importDocument(name: "x", bytes: cut, selection: .init(parts: ["beauty"]))
        }
        var rng = Kit.XorShift(state: 0xC0FF_EE11)
        // Headers, offset tables and chunk headers of multi-part files.
        for base in [bytes, Self.cryptomatteFile("crypto_asset"), Self.writeGrouped()] {
            for _ in 0 ..< 300 {
                var b = base
                for _ in 0 ..< 2 { b[Int(rng.next() % UInt32(b.count))] ^= UInt8(truncatingIfNeeded: rng.next()) | 1 }
                _ = try? EXRParts.entries(b)
                _ = try? EXRParts.importDocument(name: "x", bytes: b, selection: .init(parts: ["beauty", "main"], groups: ["diffuse"]))
            }
        }
        for comp in [EXRParts.Compression.piz, .rle, .zip, .pxr24, .b44] {
            let base = Self.compressionFixture(comp, tiled: false)
            for _ in 0 ..< 200 {
                var b = base
                for _ in 0 ..< 3 { b[Int(rng.next() % UInt32(b.count))] ^= UInt8(truncatingIfNeeded: rng.next()) | 1 }
                _ = try? EXRParts.decodePart(b, 0)
            }
        }
    }

    @Test func partsAreCappedTogether() throws {
        // Each part fits the limits alone (30000² samples of 4 bytes) but the three together don't.
        var header = Kit.LE()
        header.u32(20_000_630)
        header.u32(2 | 0x1000)
        for i in 0 ..< 3 {
            var chlist = Kit.LE()
            chlist.cString("Y"); chlist.i32(2); chlist.b += [0, 0, 0, 0]; chlist.i32(1); chlist.i32(1); chlist.b.append(0)
            header.attribute("channels", "chlist", chlist.b)
            header.attribute("compression", "compression", [0])
            var box = Kit.LE()
            for v in [0, 0, 29_999, 29_999] { box.i32(Int32(v)) }
            header.attribute("dataWindow", "box2i", box.b)
            header.attribute("name", "string", Array("p\(i)".utf8))
            header.attribute("type", "string", Array("scanlineimage".utf8))
            header.b.append(0)
        }
        header.b.append(0)
        let e = Kit.error { try EXRParts.info(header.b) }
        #expect((e as? PCIOError)?.description.contains("across 3 parts") == true, "\(String(describing: e))")
        // A single oversized part is refused on its own.
        var one = Kit.LE()
        one.u32(20_000_630); one.u32(2)
        var chlist = Kit.LE()
        chlist.cString("Y"); chlist.i32(2); chlist.b += [0, 0, 0, 0]; chlist.i32(1); chlist.i32(1); chlist.b.append(0)
        one.attribute("channels", "chlist", chlist.b)
        one.attribute("compression", "compression", [0])
        var box = Kit.LE()
        for v in [0, 0, 299_999, 1] { box.i32(Int32(v)) }
        one.attribute("dataWindow", "box2i", box.b)
        one.b.append(0)
        let e2 = Kit.error { try EXRParts.info(one.b) }
        #expect((e2 as? PCIOError)?.description.contains("exceed max 262144x262144") == true, "\(String(describing: e2))")
    }

    /// Two ZIPS parts of 4×4 RGBA; every chunk of part 0 is then overwritten with garbage.
    static func fileWithCorruptFirstPart() throws -> [UInt8] {
        func px(_ k: Float) -> [(String, [Float])] { ["R", "G", "B", "A"].map { ($0, [Float](repeating: k, count: 16)) } }
        var bytes = Kit.exr([layerF32("first", .zips, px(0.25)), layerF32("second", .zips, px(0.75))])
        let file = try EXRParts.File.parse(bytes)
        let table = file.tablesStart
        // Part 0 owns the first four of the eight chunks (one scan line per ZIPS block).
        for i in 0 ..< 4 {
            var r = EXRParts.LEReader(bytes, at: table + i * 8)
            let offset = Int(try r.u64())
            var c = EXRParts.LEReader(bytes, at: offset + 8)
            let size = Int(try c.i32())
            for k in offset + 12 ..< offset + 12 + size { bytes[k] = 0xA5 }
        }
        return bytes
    }

    @Test func decodingOnePartDoesNotDecodeTheOthers() throws {
        let bytes = try Self.fileWithCorruptFirstPart()
        // Part 0 is unreadable ...
        #expect(throws: (any Error).self) { try EXRParts.decodePart(bytes, 0) }
        // ... but asking for part 1 must not touch it.
        let img = try EXRParts.decodePart(bytes, 1)
        #expect(img.width == 4 && img.height == 4)
        #expect(img.samples.allSatisfy { Self.near($0, 0.75) }, "wrong pixels")
    }

    // MARK: - photocraft-engine exr_cmds.rs tests (the exr_parts API)

    static func writeMultipart() -> [UInt8] {
        func mk(_ n: String, _ v: Float) -> Kit.EXRChannel { Kit.EXRChannel(name: n, type: .float, values: [Float](repeating: v, count: 16)) }
        let beauty = [mk("R", 0.8), mk("G", 0.4), mk("B", 0.2), mk("A", 1)]
        return Kit.exr([Kit.EXRPart(name: "Z", width: 4, height: 4, channels: [mk("Z", 5)]),
                        Kit.EXRPart(name: "beauty", width: 4, height: 4, channels: beauty)])
    }

    static func writeGrouped() -> [UInt8] {
        func mk(_ n: String, _ v: Float) -> Kit.EXRChannel { Kit.EXRChannel(name: n, type: .float, values: [Float](repeating: v, count: 16)) }
        // Two AOV groups (each with alpha) plus the beauty RGBA, in ONE part.
        let list = [mk("diffuse.R", 0.3), mk("diffuse.G", 0.3), mk("diffuse.B", 0.3), mk("diffuse.A", 0.5),
                    mk("specular.R", 0.6), mk("specular.G", 0.6), mk("specular.B", 0.6), mk("specular.A", 0.25),
                    mk("R", 0.9), mk("G", 0.9), mk("B", 0.9), mk("A", 1)]
        return Kit.exr([Kit.EXRPart(name: "main", width: 4, height: 4, channels: list)])
    }

    @Test func exrPartsListsPartsGroupsAndViews() throws {
        let info = try EXRParts.entries(Self.writeMultipart())
        #expect(info.map(\.kind) == [.part, .part])
        #expect(info[0].name == "Z")
        #expect(info[1].name == "beauty")
        #expect(info[1].channels == 4)
        #expect(info[1].width == 4 && info[1].height == 4)
        #expect(info[1].view == nil && info[1].objects == nil)
    }

    @Test func openExrPartsImportsTheChosenPartAsALayer() throws {
        let r = try EXRParts.importDocument(name: "aov", bytes: Self.writeMultipart(), selection: .init(parts: ["beauty"]))
        #expect(r.warnings.isEmpty, "\(r.warnings)")
        let doc = r.document
        #expect(doc.layers.count == 1)
        #expect(doc.layers[0].name == "beauty")
        #expect(doc.depth == .f32 && doc.mode == .rgb)
        #expect(doc.iccProfile != nil, "linear sRGB")
        // The beauty pixels survived (R 0.8 at pixel 0).
        let px = try #require(doc.layers[0].surface).pixel(x: 0, y: 0)
        #expect(abs(px[0] - 0.8) < 1e-4, "\(px)")
    }

    @Test func openExrPartsRefusesAnEmptySelectionAndUnknownNames() {
        let bytes = Self.writeMultipart()
        let e = Kit.error { try EXRParts.importDocument(name: "aov", bytes: bytes, selection: .init()) }
        #expect((e as? PCIOError)?.description.contains("no parts or groups selected") == true, "\(String(describing: e))")
        let e2 = Kit.error { try EXRParts.importDocument(name: "aov", bytes: bytes, selection: .init(parts: ["nope"])) }
        #expect((e2 as? PCIOError)?.description.contains("no flat part named nope") == true, "\(String(describing: e2))")
        let e3 = Kit.error { try EXRParts.importDocument(name: "aov", bytes: bytes, selection: .init(groups: ["nope"])) }
        #expect((e3 as? PCIOError)?.description.contains("no channel group named nope") == true, "\(String(describing: e3))")
    }

    @Test func channelGroupsImportFromTheirOwnChannels() throws {
        let bytes = Self.writeGrouped()
        let info = try EXRParts.entries(bytes)
        #expect(info.map(\.name) == ["main", "diffuse", "specular"])
        // The part counts every R/G/B/A/Y channel, prefixed or not (as photocraft does).
        #expect(info[0].channels == 12)
        #expect(info[1].kind == .group && info[1].channels == 4)
        let r = try EXRParts.importDocument(name: "grouped", bytes: bytes, selection: .init(groups: ["diffuse"]))
        let doc = r.document
        #expect(doc.layers.count == 1)
        #expect(doc.layers[0].name == "diffuse")
        let px = try #require(doc.layers[0].surface).pixel(x: 0, y: 0)
        // The channels import as stored (straight here): values are untouched.
        #expect(abs(px[0] - 0.3) < 1e-4 && abs(px[3] - 0.5) < 1e-4, "\(px)")
    }

    @Test func precompSumsTheLightPathSetAndRefusesAnIncompleteOne() throws {
        // diffuse + specular make the set incomplete: emission is missing.
        let e = Kit.error { try EXRParts.importDocument(name: "g", bytes: Self.writeGrouped(), selection: .init(groups: ["diffuse"]), precomp: true) }
        let m = (e as? PCIOError)?.description ?? ""
        #expect(m.contains("missing") && m.contains("emission"), "\(m)")
        // A complete set: direct/indirect diffuse+specular and emission.
        let aovs: [(String, Float, Float)] = [("direct_diffuse", 0.10, 1), ("indirect_diffuse", 0.20, 1), ("direct_specular", 0.05, 1),
                                              ("indirect_specular", 0.15, 1), ("emission", 0.30, 1)]
        var list: [Kit.EXRChannel] = []
        var expect: Float = 0
        for (name, v, a) in aovs {
            for (c, value) in [("R", v), ("G", v), ("B", v), ("A", a)] {
                list.append(Kit.EXRChannel(name: "\(name).\(c)", type: .float, values: [Float](repeating: value, count: 16)))
            }
            expect += v * a
        }
        let full = Kit.exr([Kit.EXRPart(name: "main", width: 4, height: 4, channels: list)])
        let r = try EXRParts.importDocument(name: "full", bytes: full, selection: .init(), precomp: true)
        #expect(r.warnings.contains { $0.contains("precomp") }, "\(r.warnings)")
        let precomp = try #require(r.document.layers.first { $0.name == "beauty (precomp)" })
        let px = try #require(precomp.surface).pixel(x: 0, y: 0)
        #expect(abs(px[0] - expect) < 1e-3, "\(px) vs \(expect)")
        #expect(r.document.mode == .rgb)
    }

    @Test func viewFilterAndGrayDocuments() throws {
        let bytes = Self.stereoFile()
        let e = Kit.error { try EXRParts.importDocument(name: "s", bytes: bytes, selection: .init(parts: ["beauty_left"], view: "right")) }
        #expect((e as? PCIOError)?.description.contains("is of the Some(\"left\") view, the filter is right") == true, "\(String(describing: e))")
        let r = try EXRParts.importDocument(name: "s", bytes: bytes, selection: .init(parts: ["beauty_left", "beauty_left"], view: "LEFT"))
        #expect(r.document.layers.count == 1, "a part is imported once")
        // Gray-only selections make a grayscale document, without a colour profile.
        let g = try EXRParts.importDocument(name: "z", bytes: Self.aovFile(), selection: .init(parts: ["Z"]))
        #expect(g.document.mode == .grayscale && g.document.iccProfile == nil)
        #expect(g.document.layers[0].surface?.format == PixelFormat(mode: .grayscale, sample: .f32, alpha: true))
        // Mixed sizes: the document takes the largest extent.
        var small = Self.layerF32("small", .none, [("Y", [1, 2, 3, 4])])
        small.x0 = 5
        let big = Self.layerF32("big", .none, [("R", [Float](repeating: 1, count: 9)), ("G", [Float](repeating: 1, count: 9)), ("B", [Float](repeating: 1, count: 9))])
        let mixed = try EXRParts.importDocument(name: "m", bytes: Kit.exr([small, big]), selection: .init(parts: ["small", "big"]))
        #expect(mixed.document.size == PixelSize(width: 3, height: 3))
        #expect(mixed.document.mode == .rgb)
    }

    @Test func halfPartsWarnOnceAndDeepFilesAreRefused() throws {
        let chans = ["R", "G", "B", "A"].map { Kit.EXRChannel(name: $0, type: .half, values: [0.5, 0.5, 0.5, 0.5]) }
        let bytes = Kit.exr([Kit.EXRPart(name: "a", width: 2, height: 2, channels: chans), Kit.EXRPart(name: "b", width: 2, height: 2, channels: chans)])
        let r = try EXRParts.importDocument(name: "h", bytes: bytes, selection: .init(parts: ["a", "b"]))
        #expect(r.warnings == ["16-bit float samples are stored as 32-bit float"])
        // A file whose only part is deep lists nothing and refuses to decode.
        var deep = Kit.EXRPart(name: "d", width: 2, height: 2, channels: chans)
        deep.type = "deepscanline"
        let deepBytes = Kit.exr([deep], multipart: true)
        #expect(try EXRParts.info(deepBytes).first?.deep == true)
        #expect(Kit.isUnsupported(Kit.error { try EXRParts.entries(deepBytes) }))
        #expect(throws: (any Error).self) { try EXRParts.decodePart(deepBytes, 0) }
    }

    // MARK: - Cryptomatte (photocraft-codecs tests/exr_cryptomatte.rs, listing)

    @Test func mm3HashMatchesTheOfficialVectors() {
        // The values are the f32 IDs the reference implementation produces.
        let vectors: [(String, Double)] = [
            ("hello", 6.0705627102400005616e-17),
            ("cube", -4.08461912519e+15),
            ("sphere", 2.79018604383e+15),
            ("plane", 3.66557617593e-11),
            ("равнина", -1.3192631212399999468e-25),
            ("mädchen", 6.2361298211599995797e+25),
        ]
        for (name, want) in vectors {
            #expect(EXRParts.cryptomatteID(name).bitPattern == Float(want).bitPattern, "ID bits of \(name)")
        }
        for name in ["", "a", "hello", "CryptoAsset", "very long object name with ünïcödé"] {
            let id = EXRParts.cryptomatteID(name)
            #expect(id.isFinite && abs(id) >= Float.leastNormalMagnitude, "\(name) -> \(id)")
        }
        let key = EXRParts.cryptomatteKey("CryptoAsset")
        #expect(key.count == 7 && key.allSatisfy(\.isHexDigit))
        let full = String(EXRParts.cryptomatteID("CryptoAsset").bitPattern, radix: 16)
        #expect(key == String((String(repeating: "0", count: 8 - full.count) + full).prefix(7)))
    }

    static func cryptomatteFile(_ name: String) -> [UInt8] {
        let cube = EXRParts.cryptomatteID("cube"), sphere = EXRParts.cryptomatteID("sphere")
        let s0 = [Float](repeating: cube, count: 16), s0c = [Float](repeating: 0.6, count: 16)
        let s1 = (0 ..< 16).map { $0 % 4 == 0 ? sphere : 0 }, s1c = (0 ..< 16).map { $0 % 4 == 0 ? Float(0.25) : 0 }
        func mk(_ n: String, _ v: [Float]) -> Kit.EXRChannel { Kit.EXRChannel(name: n, type: .float, values: v) }
        let key = EXRParts.cryptomatteKey("CryptoAsset")
        func hex(_ f: Float) -> String { let h = String(f.bitPattern, radix: 16); return String(repeating: "0", count: 8 - h.count) + h }
        let manifest = "{\"cube\":\"\(hex(cube))\",\"sphere\":\"\(hex(sphere))\",\"broken\":12}"
        let part = Kit.EXRPart(name: "main", width: 4, height: 4, compression: .zips,
                               channels: [mk("\(name)00.red", s0), mk("\(name)00.green", s0c), mk("\(name)01.red", s1), mk("\(name)01.green", s1c),
                                          mk("R", s0c), mk("G", s0c), mk("B", s0c)],
                               strings: [("cryptomatte/\(key)/name", "CryptoAsset"), ("cryptomatte/\(key)/hash", "MurmurHash3_32"),
                                         ("cryptomatte/\(key)/conversion", "uint32_to_float32"), ("cryptomatte/\(key)/manifest", manifest)])
        return Kit.exr([part])
    }

    @Test func cryptomatteLayersAreListedFromTheHeaders() throws {
        let bytes = Self.cryptomatteFile("crypto_asset")
        let layers = try EXRParts.cryptomatteLayers(bytes)
        #expect(layers.count == 1)
        let l = try #require(layers.first)
        #expect(l.name == "CryptoAsset" && l.part == 0)
        #expect(l.key == EXRParts.cryptomatteKey("CryptoAsset"))
        #expect(l.conversion == "uint32_to_float32")
        #expect(l.channels == ["crypto_asset00", "crypto_asset01"])
        #expect(l.manifest.map(\.name) == ["cube", "sphere"], "the non-string entry is skipped")
        #expect(l.manifest.first?.id == EXRParts.cryptomatteID("cube"))
        // The chooser lists the part, no channel groups (stream prefixes end in digits), and the layer.
        let entries = try EXRParts.entries(bytes)
        #expect(entries.map(\.kind) == [.part, .cryptomatte])
        #expect(entries[1].channels == 2 && entries[1].objects == 2)
        // Names that differ in case and separators still match their streams.
        #expect(try EXRParts.cryptomatteLayers(Self.cryptomatteFile("CryptoAsset")).first?.channels == ["CryptoAsset00", "CryptoAsset01"])
    }

    // MARK: - Block compressions

    /// A part exercising every channel type: half RGBA ramps, a float Z, a uint ID, with a data
    /// window away from the origin. Tiled parts use 16×8 tiles; scan-line ones add a 2×2
    /// subsampled channel.
    static func compressionPart(_ comp: EXRParts.Compression, tiled: Bool, lossyFloat: Bool = false, smooth: Bool = false) -> Kit.EXRPart {
        let (w, h) = (37, 45)
        func ramp(_ k: Int) -> [Float] {
            (0 ..< w * h).map { i in
                let (x, y) = (i % w, i / w)
                // Gentle gradients (what B44 keeps), else detail with repeats so every coder has
                // runs and a spread of symbols.
                if smooth { return 0.5 + Float(x) * 0.01 + Float(y) * Float(k + 1) * 0.002 }
                return Float((x * (k + 3) + y * (2 * k + 1)) % 97) / 64 - 0.25 + (x / 9 == 2 ? 0 : Float(k) / 8)
            }
        }
        var chans = ["R", "G", "B", "A"].enumerated().map { k, n in Kit.EXRChannel(name: n, type: .half, values: ramp(k)) }
        // Floats with a 15-bit mantissa survive PXR24 unchanged.
        chans.append(Kit.EXRChannel(name: "Z", type: .float, values: (0 ..< w * h).map { Float($0 % 53) * (lossyFloat ? 0.1 : 0.5) + 1000 }))
        chans.append(Kit.EXRChannel(name: "id", type: .uint, values: (0 ..< w * h).map { Float(($0 / 7) % 300 + 70000) }))
        if !tiled {
            let sw = EXRParts.numSamples(2, -5, -5 + w - 1), sh = EXRParts.numSamples(2, 7, 7 + h - 1)
            chans.append(Kit.EXRChannel(name: "sub", type: .half, xSampling: 2, ySampling: 2, values: (0 ..< sw * sh).map { smooth ? 1 + Float($0 % sw) / 256 : Float($0 % 11) / 4 }))
        }
        var part = Kit.EXRPart(name: "p", x0: -5, y0: 7, width: w, height: h, compression: comp, channels: chans)
        if tiled { part.tile = (16, 8) }
        return part
    }

    static func compressionFixture(_ comp: EXRParts.Compression, tiled: Bool) -> [UInt8] {
        Kit.exr([compressionPart(comp, tiled: tiled)])
    }

    /// The channel values as a writer stores them (half channels rounded to half).
    static func stored(_ c: Kit.EXRChannel) -> [Float] {
        c.type == .half ? c.values.map { EXRParts.halfToFloat(Kit.floatToHalf($0)) } : c.values
    }

    static let losslessCompressions: [EXRParts.Compression] = [.none, .rle, .zips, .zip, .piz, .pxr24]

    @Test(arguments: losslessCompressions, [false, true])
    func losslessCompressionsRoundTrip(_ comp: EXRParts.Compression, _ tiled: Bool) throws {
        let part = Self.compressionPart(comp, tiled: tiled)
        let bytes = Kit.exr([part])
        let info = try #require(try EXRParts.info(bytes).first)
        #expect(info.compression == comp && info.tiled == tiled)
        #expect(info.width == 37 && info.height == 45)
        let file = try EXRParts.File.parse(bytes)
        let sorted = Kit.sorted(part.channels)
        let planes = try file.decodePlanes(0, Array(sorted.indices))
        for (k, c) in sorted.enumerated() {
            let want = Self.stored(c)
            #expect(planes[k].count == want.count, "\(comp) \(c.name)")
            let same = zip(planes[k], want).allSatisfy { $0.bitPattern == $1.bitPattern }
            #expect(same, "\(comp) tiled \(tiled): channel \(c.name)")
        }
        // The colour channels as an image.
        let img = try EXRParts.decodePart(bytes, 0)
        #expect(img.layout == .rgba && img.half)
        let r = Self.stored(sorted.first { $0.name == "R" }!)
        #expect(img.samples[100 * 4] == r[100])
    }

    @Test(arguments: [false, true])
    func decreasingLineOrderAndPIZOnLongBlocks(_ tiled: Bool) throws {
        var part = Self.compressionPart(.piz, tiled: tiled)
        part.lineOrder = 1
        let bytes = Kit.exr([part])
        let img = try EXRParts.decodePart(bytes, 0)
        let g = Self.stored(part.channels[1])
        #expect(zip(stride(from: 1, to: img.samples.count, by: 4).map { img.samples[$0] }, g).allSatisfy { $0 == $1 })
    }

    @Test func pxr24RoundsFloatsTo24Bits() throws {
        let part = Self.compressionPart(.pxr24, tiled: false, lossyFloat: true)
        let file = try EXRParts.File.parse(Kit.exr([part]))
        let sorted = Kit.sorted(part.channels)
        let zi = try #require(sorted.firstIndex { $0.name == "Z" })
        let z = try file.decodePlanes(0, [zi])[0]
        for (got, v) in zip(z, sorted[zi].values) {
            #expect(got.bitPattern == Kit.float24(v.bitPattern) << 8)
        }
    }

    @Test(arguments: [EXRParts.Compression.b44, .b44a], [false, true])
    func b44DecodesWithinItsPrecision(_ comp: EXRParts.Compression, _ tiled: Bool) throws {
        let part = Self.compressionPart(comp, tiled: tiled, smooth: true)
        let file = try EXRParts.File.parse(Kit.exr([part]))
        let sorted = Kit.sorted(part.channels)
        let planes = try file.decodePlanes(0, Array(sorted.indices))
        for (k, c) in sorted.enumerated() {
            let want = Self.stored(c)
            if c.type == .half {
                // B44 is lossy: within a few half steps of the value.
                let worst = zip(planes[k], want).map { abs($0 - $1) / max(1, abs($1)) }.max() ?? 0
                #expect(worst < 0.02, "\(comp) \(c.name): \(worst)")
            } else {
                #expect(zip(planes[k], want).allSatisfy { $0.bitPattern == $1.bitPattern }, "\(comp) \(c.name)")
            }
        }
        // Blocks whose 4×4 values are close enough decode exactly, and B44A's flat blocks too.
        let flat = Kit.EXRChannel(name: "Y", type: .half, values: (0 ..< 64).map { i in i < 32 ? 0.75 : 0.5 + Float(i % 8) / 2048 })
        let exact = Kit.exr([Kit.EXRPart(name: "f", width: 8, height: 8, compression: comp, channels: [flat])])
        let y = try EXRParts.decodePart(exact, 0)
        #expect(y.samples == Self.stored(flat))
    }

    @Test func mipmappedTilesDecodeLevelZero() throws {
        var part = Self.compressionPart(.zip, tiled: true)
        part.mipmap = true
        let bytes = Kit.exr([part])
        let file = try EXRParts.File.parse(bytes)
        // Six levels for 45 px: 6 + 3 + 2 + 1 + 1 + 1 tiles' worth of chunks... the table holds them all.
        #expect(file.chunkCount(0) > 3 * 6)
        let img = try EXRParts.decodePart(bytes, 0)
        #expect(img.width == 37 && img.height == 45)
        let a = Self.stored(part.channels[3])
        #expect(stride(from: 3, to: img.samples.count, by: 4).map { img.samples[$0] } == a)
    }

    @Test func tiledChunkCountsFollowTheLevelModes() {
        var h = EXRParts.Header()
        h.x0 = -3; h.y0 = 2; h.x1 = -3 + 36; h.y1 = 2 + 44
        h.tiled = true
        func count(_ mode: UInt8, _ rounding: UInt8) -> Int {
            h.tiles = EXRParts.TileDescription(xSize: 16, ySize: 8, levelMode: mode, roundingMode: rounding)
            return EXRParts.File.computedChunks(h)
        }
        #expect(count(0, 0) == 18)
        #expect(count(1, 0) == 29)   // 37×45, 18×22, 9×11, 4×5, 2×2, 1×1
        #expect(count(1, 1) == 30)   // 37×45, 19×23, 10×12, 5×6, 3×3, 2×2, 1×1
        #expect(count(2, 0) == 126)  // (3+2+1+1+1+1) × (6+3+2+1+1+1)
        h.tiled = false
        h.compression = .piz
        #expect(EXRParts.File.computedChunks(h) == 2)
        h.compression = .zips
        #expect(EXRParts.File.computedChunks(h) == 45)
    }

    @Test func subsampledColourChannelsAreRefused() {
        let chans = [Kit.EXRChannel(name: "R", type: .half, values: [Float](repeating: 1, count: 16)),
                     Kit.EXRChannel(name: "G", type: .half, values: [Float](repeating: 1, count: 16)),
                     Kit.EXRChannel(name: "B", type: .half, xSampling: 2, ySampling: 2, values: [Float](repeating: 1, count: 4))]
        let bytes = Kit.exr([Kit.EXRPart(name: "yc", width: 4, height: 4, channels: chans)])
        let e = Kit.error { try EXRParts.decodePart(bytes, 0) }
        #expect((e as? PCIOError)?.description.contains("subsampled") == true, "\(String(describing: e))")
    }

    @Test func unsupportedCompressionsListButRefuseToDecode() throws {
        var bytes = Self.compressionFixture(.zip, tiled: false)
        // Patch the compression attribute's value to DWAA.
        let marker = Array("compression\0compression\0".utf8)
        let at = try #require((0 ... bytes.count - marker.count).first { Array(bytes[$0 ..< $0 + marker.count]) == marker })
        bytes[at + marker.count + 4] = EXRParts.Compression.dwaa.rawValue
        let info = try EXRParts.info(bytes)
        #expect(info.first?.compression == .dwaa)
        #expect(!EXRParts.Compression.dwaa.isDecodable)
        let e = Kit.error { try EXRParts.decodePart(bytes, 0) }
        #expect((e as? PCIOError)?.description.contains("DWAA") == true, "\(String(describing: e))")
    }

    // MARK: - Real files: bit-exact against ImageIO

    static let systemFiles = [
        "/Applications/Xcode.app/Contents/SystemFrameworks/CoreRE.framework/Versions/A/Resources/flare.exr",
        "/Applications/Xcode.app/Contents/SystemFrameworks/CoreRE.framework/Versions/A/Resources/twinkle.exr",
        "/Applications/Xcode.app/Contents/SystemFrameworks/CoreRE.framework/Versions/A/Resources/spatial_media_4channel_map_sq.exr",
        "/System/Library/ExtensionKit/Extensions/WallpaperSequoiaExtension.appex/Contents/Resources/dawn.exr",
        "/System/Library/PrivateFrameworks/CoreUSDEdit.framework/Versions/A/Resources/config/angie/previz/ibls/night.exr",
        "/System/Library/PrivateFrameworks/CoreUSDEdit.framework/Versions/A/Resources/config/angie/previz/ibls/studio.exr",
    ]

    /// ImageIO's decode of part 0 as raw interleaved floats (RGBA, RGBX or gray, as stored).
    static func imageIO(_ bytes: [UInt8]) -> (width: Int, height: Int, channels: Int, samples: [Float])? {
        guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary),
              img.bitmapInfo.contains(.floatComponents), let data = img.dataProvider?.data as Data? else { return nil }
        let comps = img.bitsPerPixel / img.bitsPerComponent
        var out = [Float](repeating: 0, count: img.width * img.height * comps)
        data.withUnsafeBytes { p in
            for y in 0 ..< img.height {
                for i in 0 ..< img.width * comps {
                    let o = y * img.bytesPerRow + i * img.bitsPerComponent / 8
                    out[y * img.width * comps + i] = img.bitsPerComponent == 16
                        ? EXRParts.halfToFloat(p.loadUnaligned(fromByteOffset: o, as: UInt16.self))
                        : p.loadUnaligned(fromByteOffset: o, as: Float.self)
                }
            }
        }
        return (img.width, img.height, comps, out)
    }

    @Test(arguments: systemFiles)
    func agreesWithImageIOOnShippedFiles(_ path: String) throws {
        guard let data = FileManager.default.contents(atPath: path) else { return }
        let bytes = [UInt8](data)
        let info = try EXRParts.info(bytes)
        let img = try EXRParts.decodePart(bytes, 0)
        let reference = try #require(Self.imageIO(bytes))
        #expect(reference.width == img.width && reference.height == img.height, "\(path)")
        let mismatches = Self.mismatches(img, reference)
        #expect(mismatches == 0, "\(path) (\(info[0].compression.name), tiled \(info[0].tiled)): \(mismatches) samples differ")
    }

    /// Colour samples that differ bit-wise between our decode and ImageIO's (Int.max when the
    /// sizes differ).
    static func mismatches(_ img: EXRParts.Image, _ reference: (width: Int, height: Int, channels: Int, samples: [Float])) -> Int {
        guard reference.width == img.width, reference.height == img.height else { return .max }
        let ours = img.layout.channels
        var n = 0
        for p in 0 ..< img.width * img.height {
            for c in 0 ..< min(ours, reference.channels) {
                let (a, b) = (img.samples[p * ours + c], reference.samples[p * reference.channels + c])
                if a.bitPattern != b.bitPattern && !(a.isNaN && b.isNaN) { n += 1 }
            }
        }
        return n
    }

    /// A multi-part file written by Apple's AppleEXR encoder, an implementation independent of
    /// this reader (`PCIO_EXR_FIXTURES`, made by the scratchpad tool `exrgen/multipart.c`): four
    /// parts (ZIP RGBA half with a view, uncompressed float Z, a `diffuse.*` RGBA layer with a
    /// view, ZIP uint IDs) whose samples follow `value(part, channel, x, y)`, the channel being
    /// the R, G, B, A order the data was handed over in.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PCIO_EXR_FIXTURES"] != nil))
    func readsAppleEXRMultipartFiles() throws {
        let dir = try #require(ProcessInfo.processInfo.environment["PCIO_EXR_FIXTURES"])
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("appleexr-multipart.exr")))
        func value(_ part: Int, _ ch: Int, _ x: Int, _ y: Int) -> Float { Float((x * 3 + y * 5 + ch * 7 + part * 11) % 64) / 32 }
        let info = try EXRParts.info(bytes)
        #expect(info.map(\.name) == ["beauty", "depth", "aov", "ids"])
        #expect(info.map(\.view) == ["left", nil, "right", nil])
        #expect(info.allSatisfy { $0.width == 64 && $0.height == 48 })
        let entries = try EXRParts.entries(bytes)
        #expect(entries.filter { $0.kind == .group }.map(\.name) == ["diffuse"])
        let beauty = try EXRParts.decodePart(bytes, 0)
        #expect(beauty.layout == .rgba && beauty.half)
        let z = try EXRParts.decodePart(bytes, 1)
        let ids = try EXRParts.decodePart(bytes, 3)
        let diffuse = try EXRParts.decodeChannels(bytes, 2, ["diffuse.B", "diffuse.G", "diffuse.R"])
        #expect(diffuse.layout == .rgb)
        let diffuseA = try EXRParts.decodeChannels(bytes, 2, ["diffuse.A", "diffuse.R", "diffuse.G", "diffuse.B"])
        #expect(diffuseA.layout == .rgba)
        var bad = 0
        for y in 0 ..< 48 {
            for x in 0 ..< 64 {
                let i = y * 64 + x
                for c in 0 ..< 4 where beauty.samples[i * 4 + c] != value(0, c, x, y) { bad += 1 }
                if z.samples[i] != value(1, 0, x, y) + 1000 { bad += 1 }
                for c in 0 ..< 3 where diffuse.samples[i * 3 + c] != value(2, c, x, y) { bad += 1 }
                if diffuseA.samples[i * 4 + 3] != value(2, 3, x, y) { bad += 1 }
                if ids.samples[i] != Float(x + y * 100 + 3) { bad += 1 }
            }
        }
        #expect(bad == 0, "\(bad) samples differ")
        let doc = try EXRParts.importDocument(name: "apple", bytes: bytes, selection: .init(parts: ["beauty"], groups: ["diffuse"], view: "both"))
        #expect(doc.document.layers.map(\.name) == ["beauty", "diffuse"])
        let e = Kit.error { try EXRParts.importDocument(name: "apple", bytes: bytes, selection: .init(groups: ["diffuse"], view: "left")) }
        #expect(Kit.isUnsupported(e))
    }

    /// Optional corpus (`PCIO_EXR_DIR`): every `.exr` lists, and each flat part decodes or fails
    /// cleanly with an unsupported compression.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PCIO_EXR_DIR"] != nil))
    func exrCorpusOpens() throws {
        let root = try #require(ProcessInfo.processInfo.environment["PCIO_EXR_DIR"])
        let names = (FileManager.default.enumerator(atPath: root)?.compactMap { $0 as? String } ?? []).filter { $0.lowercased().hasSuffix(".exr") }
        for name in names.sorted() {
            let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(name)))
            let parts = try EXRParts.info(bytes)
            for p in parts where !p.deep && p.compression.isDecodable {
                if p.colorRank > 0 { _ = try EXRParts.decodePart(bytes, p.index) }
            }
            // Single-part files: part 0 matches ImageIO's decode bit for bit.
            var agreement = ""
            if parts.count == 1, parts[0].compression.isDecodable, parts[0].colorRank > 0, let reference = Self.imageIO(bytes) {
                let n = Self.mismatches(try EXRParts.decodePart(bytes, 0), reference)
                #expect(n == 0, "\(name): \(n) samples differ from ImageIO")
                agreement = n == 0 ? ", same as ImageIO" : ", \(n) samples differ from ImageIO"
            }
            print("\(name): \(parts.count) parts, \(parts.map { $0.compression.name })\(agreement)")
        }
    }
}
