// Port of photocraft-io (crates/io/src/pdn/tests.rs, and the parts of
// crates/io/tests/pdn_corpus.rs that run without the native format), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors. photocraft's proptest cases run here as
// deterministic pseudo-random loops.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIOFormats

@Suite("PaintDotNet")
struct PaintDotNetTests {
    typealias Kit = ContainerTestKit

    enum Field {
        case int(Int32), long(Int64), byte(UInt8), bool(Bool), ref(Int32)
    }

    struct Writer {
        var b: [UInt8]

        mutating func int(_ n: Int32) {
            let u = UInt32(bitPattern: n)
            b += [UInt8(u & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u >> 16 & 0xFF), UInt8(u >> 24)]
        }

        mutating func string(_ s: String) {
            var len = s.utf8.count
            while len >= 128 {
                b.append(UInt8(len & 127) | 128)
                len >>= 7
            }
            b.append(UInt8(len))
            b += Array(s.utf8)
        }

        mutating func object(_ id: Int32, _ cls: String, _ fields: [(String, Field)]) {
            b.append(5)
            int(id)
            string(cls)
            int(Int32(fields.count))
            for (name, _) in fields { string(name) }
            for (_, f) in fields {
                if case .ref = f { b.append(2) } else { b.append(0) }
            }
            for (_, f) in fields {
                switch f {
                case .int: b.append(8)
                case .long: b.append(9)
                case .byte: b.append(2)
                case .bool: b.append(1)
                case .ref: break
                }
            }
            int(1)
            for (_, f) in fields {
                switch f {
                case .int(let n): int(n)
                case .long(let n): for k in 0 ..< 8 { b.append(UInt8(truncatingIfNeeded: n >> (8 * k))) }
                case .byte(let n): b.append(n)
                case .bool(let v): b.append(v ? 1 : 0)
                case .ref(let id):
                    b.append(9)
                    int(id)
                }
            }
        }
    }

    /// Independent synthetic PDN writer: padded rows, forward references, a root cycle, spare
    /// ArrayList capacity, and reversed gzip/raw chunks. There is no production PDN writer.
    static func fixture(_ modes: [Int32], legacy: Bool, compressed: Bool, metadata: Bool = false) -> [UInt8] {
        var w = Writer(b: Array("PDN3".utf8) + [0, 0, 0, 0, 1])
        w.b.append(0)
        for n: Int32 in [1, -1, 1, 0] { w.int(n) }
        w.b.append(12)
        w.int(1)
        w.string("PaintDotNet.Data")
        var root: [(String, Field)] = [("width", .int(2)), ("height", .int(2)), ("layers", .ref(2))]
        if metadata { root.append(("userMetadataItems", .ref(90))) }
        w.object(1, "PaintDotNet.Document", root)
        w.object(2, "PaintDotNet.LayerList", [("parent", .ref(1)), ("ArrayList+_size", .int(Int32(modes.count))), ("ArrayList+_items", .ref(3))])
        w.b.append(16)
        w.int(3)
        w.int(Int32(modes.count) + 2)
        for i in modes.indices {
            w.b.append(9)
            w.int(16 + Int32(i) * 10)
        }
        w.b += [13, 2]
        for (i, mode) in modes.enumerated() {
            let id = 16 + Int32(i) * 10
            w.object(id, "PaintDotNet.BitmapLayer", [("Layer+width", .int(2)), ("Layer+height", .int(2)), ("surface", .ref(id + 1)),
                                                     ("Layer+properties", .ref(id + 2)), ("properties", .ref(id + 3))])
            w.object(id + 1, "PaintDotNet.Surface", [("width", .int(2)), ("height", .int(2)), ("stride", .int(12)), ("scan0", .ref(id + 7))])
            var fields: [(String, Field)] = [("name", .ref(id + 4)), ("opacity", .byte(i == 0 ? 255 : 128)), ("visible", .bool(i != 1)),
                                             ("isBackground", .bool(i == 0))]
            if !legacy { fields.append(("blendMode", .ref(id + 5))) }
            w.object(id + 2, "PaintDotNet.Layer+LayerProperties", fields)
            w.object(id + 3, "PaintDotNet.BitmapLayer+BitmapLayerProperties", [("blendOp", .ref(id + 6))])
            w.b.append(6)
            w.int(id + 4)
            w.string("Läyer \(i)")
            w.object(id + 5, "PaintDotNet.LayerBlendMode", [("value__", .int(mode))])
            let old = mode >= 0 && Int(mode) < PaintDotNet.oldModes.count ? PaintDotNet.oldModes[Int(mode)] : "Unknown"
            w.object(id + 6, "PaintDotNet.UserBlendOps+\(old)BlendOp", [])
            w.object(id + 7, "PaintDotNet.MemoryBlock", [("length64", .long(24)), ("hasParent", .bool(false)), ("deferred", .bool(true))])
        }
        if metadata {
            // A one-item array of a string (ArraySingleObject, BinaryObjectString).
            w.b.append(16)
            w.int(90)
            w.int(1)
            w.b.append(6)
            w.int(91)
            w.string("key")
        }
        w.b.append(11)
        for _ in modes {
            w.b.append(compressed ? 0 : 1)
            w.b += [0, 0, 0, 12]
            for index: UInt32 in [1, 0] {
                let raw: [UInt8] = index == 0 ? [30, 20, 10, 255, 60, 50, 40, 128, 99, 99, 99, 99] : [90, 80, 70, 64, 120, 110, 100, 0, 99, 99, 99, 99]
                let data = compressed ? ((try? Deflate.gzip(raw)) ?? []) : raw
                w.b += [UInt8(index >> 24), UInt8(index >> 16 & 0xFF), UInt8(index >> 8 & 0xFF), UInt8(index & 0xFF)]
                let n = UInt32(data.count)
                w.b += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
                w.b += data
            }
        }
        return w.b
    }

    static func importPDN(_ bytes: [UInt8], _ ctl: Interrupt = .none) throws -> ImportResult {
        try PaintDotNet.importDocument(name: "sample", bytes: bytes, interrupt: ctl)
    }

    @Test func allPdnBlendModesAndLayerPropertiesImport() throws {
        let modes = (0 ..< 14).map { Int32($0) }
        for legacy in [false, true] {
            for compressed in [false, true] {
                let bytes = Self.fixture(modes, legacy: legacy, compressed: compressed)
                // Detection must work without an extension too.
                #expect(PaintDotNet.isPDN(bytes))
                let imported = try Self.importPDN(bytes)
                #expect(imported.sourceReadOnly)
                #expect(!imported.previewOnly)
                #expect(imported.warnings.isEmpty)
                let doc = imported.document
                #expect(doc.layers.count == 14)
                #expect(doc.size == PixelSize(width: 2, height: 2))
                #expect(doc.mode == .rgb && doc.depth == .u8)
                for (i, layer) in doc.layers.enumerated() {
                    #expect(layer.name == "Läyer \(i)")
                    #expect(layer.blend == PaintDotNet.modes[i])
                    #expect(layer.visible == (i != 1))
                    #expect(layer.opacity == (i == 0 ? 1 : Float(128) / 255))
                    #expect(!layer.locks.all && !layer.locks.pixels && !layer.locks.position)
                    let surface = try #require(layer.surface)
                    for (x, y, expected) in [(0, 0, [10, 20, 30, 255]), (1, 0, [40, 50, 60, 128]), (0, 1, [70, 80, 90, 64]), (1, 1, [100, 110, 120, 0])] {
                        let p = surface.pixel(x: Int32(x), y: Int32(y))
                        #expect(p.map { Int(($0 * 255).rounded()) } == expected)
                    }
                }
            }
        }
    }

    @Test func truncationUnknownModesAndCorruptChunksFailWithoutPanicking() throws {
        let raw = Self.fixture([0], legacy: false, compressed: false)
        #expect(throws: Never.self) { try Self.importPDN(raw) }
        for len in 0 ..< raw.count {
            #expect(throws: (any Error).self, "length \(len)") { try Self.importPDN(Array(raw[..<len])) }
        }
        #expect(throws: (any Error).self) { try Self.importPDN(Self.fixture([999], legacy: false, compressed: false)) }
        var corrupt = raw
        let block = corrupt.count - 45
        // Zero chunk size.
        corrupt.replaceSubrange(block + 1 ..< block + 5, with: [0, 0, 0, 0])
        #expect(throws: (any Error).self) { try Self.importPDN(corrupt) }
        var duplicate = raw
        // Both row chunks claim index 1.
        duplicate.replaceSubrange(block + 25 ..< block + 29, with: [0, 0, 0, 1])
        #expect(throws: (any Error).self) { try Self.importPDN(duplicate) }
        var zipped = Self.fixture([0], legacy: false, compressed: true)
        zipped[zipped.count - 1] ^= 1
        #expect(throws: (any Error).self) { try Self.importPDN(zipped) }
    }

    @Test func pdnImportCanBeCancelledDuringParsingAndPixelDecode() {
        let bytes = Self.fixture([0, 1], legacy: false, compressed: true)
        for limit in [0, 10] {
            let checks = Kit.Counter()
            #expect(throws: PCIOError.cancelled) { try Self.importPDN(bytes, .cancelOnly { checks.next() >= limit }) }
        }
        let flag = Kit.Counter()
        let ctl = Interrupt(cancel: { flag.get() != 0 }, progress: { _ in flag.set(1) })
        #expect(throws: PCIOError.cancelled) { try Self.importPDN(bytes, ctl) }
    }

    @Test func arbitrarySerializedDataReturnsAnErrorWithoutPanicking() {
        var rng = Kit.XorShift(state: 0xA5A5_1234)
        for _ in 0 ..< 256 {
            var bytes = Array("PDN3".utf8) + [0, 0, 0, 0, 1]
            let n = Int(rng.next() % 4096)
            for _ in 0 ..< n { bytes.append(UInt8(truncatingIfNeeded: rng.next())) }
            _ = try? Self.importPDN(bytes)
        }
    }

    @Test func mutatedLayeredDocumentsNeverPanic() {
        var rng = Kit.XorShift(state: 0x0BAD_F00D)
        let base = Self.fixture([0, 5, 13], legacy: false, compressed: true)
        for _ in 0 ..< 512 {
            var bytes = base
            for _ in 0 ..< Int(1 + rng.next() % 7) {
                bytes[Int(rng.next() % UInt32(bytes.count))] = UInt8(truncatingIfNeeded: rng.next())
            }
            _ = try? Self.importPDN(bytes)
        }
    }

    @Test func malformedPdnReportsAFormatError() {
        let cases: [[UInt8]] = [[], Array("PDN3".utf8), Array("PDN3".utf8) + [0xFF, 0xFF, 0xFF], Array("PDN4".utf8) + [0, 0, 0]]
        for bytes in cases {
            let e = Kit.error { try Self.importPDN(bytes) }
            if case .format("PDN", _)? = e as? PCIOError {} else { Issue.record("\(bytes): \(String(describing: e))") }
        }
    }

    @Test func serializedCountsDepthAndReferencesAreBounded() {
        func header() -> Writer {
            var w = Writer(b: [0])
            for n: Int32 in [1, -1, 1, 0] { w.int(n) }
            return w
        }
        var oversized = header()
        oversized.b.append(16)
        oversized.int(1)
        oversized.int(1_000_001)
        var nested = header()
        for id: Int32 in 1 ... 66 {
            nested.b.append(16)
            nested.int(id)
            nested.int(1)
        }
        nested.b += [10, 11]
        var duplicate = header()
        for _ in 0 ..< 2 {
            duplicate.b.append(6)
            duplicate.int(1)
            duplicate.string("duplicate")
        }
        duplicate.b.append(11)
        var nullRun = header()
        nullRun.b.append(16)
        nullRun.int(1)
        nullRun.int(1)
        nullRun.b += [13, 2, 11]
        var missingClass = header()
        missingClass.b.append(1)
        missingClass.int(1)
        missingClass.int(999)
        var missingRoot = header()
        missingRoot.b.append(11)
        for w in [oversized, nested, duplicate, nullRun, missingClass, missingRoot] {
            var reader = PaintDotNet.NRBF.Reader(w.b)
            #expect(throws: (any Error).self) { try PaintDotNet.NRBF.parse(&reader, .none) }
        }
    }

    @Test func truncatedUncompressedPixelsAreRejectedBeforeAllocating() {
        // A raw (version 1) block of 256 MiB chunks that declares 1 GiB of pixels but holds a few bytes.
        var reader = PaintDotNet.NRBF.Reader([1, 0x10, 0, 0, 0, 0, 0, 0, 0])
        let e = Kit.error { try PaintDotNet.pixels(&reader, 1 << 30, .none) }
        #expect((e as? PCIOError)?.description.contains("uncompressed pixel data is truncated") == true, "\(String(describing: e))")
    }

    @Test func userMetadataIsReported() throws {
        let r = try Self.importPDN(Self.fixture([0], legacy: false, compressed: false, metadata: true))
        #expect(r.warnings == ["Paint.NET document metadata was not imported"])
    }

    /// photocraft `pdn_corpus` (needs `PDN_TEST_DIR`: PDNs with same-named PNG exports): every
    /// document opens, and documents whose layers all blend Normal match their PNG export within
    /// 3/255 through the stand-in compositor (other modes need PCRender). The `.pcraft`
    /// round trip belongs to PCFormat's tests.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PDN_TEST_DIR"] != nil))
    func realPdnLayers() throws {
        let root = try #require(ProcessInfo.processInfo.environment["PDN_TEST_DIR"])
        let all = FileManager.default.enumerator(atPath: root)?.compactMap { $0 as? String } ?? []
        let paths = all.filter { $0.lowercased().hasSuffix(".pdn") }.sorted()
        #expect(!paths.isEmpty, "no PDN files found")
        for path in paths {
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            let doc = try PaintDotNet.importDocument(name: path, bytes: [UInt8](try Data(contentsOf: url)), interrupt: .none).document
            guard doc.layers.allSatisfy({ $0.blend == .normal }),
                  let png = try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("png")) else {
                print("\(path): \(doc.layers.count) layers")
                continue
            }
            let oracle = try ImageIOCodec().decode([UInt8](png))
            #expect(doc.size == PixelSize(width: oracle.width, height: oracle.height))
            let ours = Kit.flatten(doc)
            let theirs = OpenRaster.rgbaFloats(oracle.surface, doc.bounds)
            var worst: Float = 0
            for i in 0 ..< ours.count / 4 {
                for c in 0 ..< 4 {
                    let e = c == 3 ? abs(ours[i * 4 + 3] - theirs[i * 4 + 3]) : abs(ours[i * 4 + c] * ours[i * 4 + 3] - theirs[i * 4 + c] * theirs[i * 4 + 3])
                    worst = max(worst, e)
                }
            }
            print("\(path): \(doc.layers.count) layers, max PNG error \(worst * 255)/255")
            #expect(worst <= 3 / 255, "\(path)")
        }
    }
}
