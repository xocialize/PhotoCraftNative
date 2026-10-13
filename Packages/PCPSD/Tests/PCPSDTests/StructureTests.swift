// Structure unit tests: descriptors, tagged blocks, layer records and masks, resources, paths,
// slices, filter effects, metadata, HDR toning.
// Port of the inline tests of photocraft-psd (crates/psd/src/descriptor.rs, tagged.rs, layer.rs,
// resources.rs, path.rs, slices.rs, filter_effects.rs, metadata.rs, hdr.rs) and the descriptor
// proptests (as seeded loops), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import Testing
@testable import PCPSD

enum Samples {
    static func cls(_ name: String, _ id: String) -> PSDDescriptor.ClassRef { PSDDescriptor.ClassRef(name: PSDUnicodeString(name), classID: PSDDescriptor.ID(id)) }

    static func descriptor() -> PSDDescriptor {
        PSDDescriptor()
            .with("Nm  ", .text(.nulTerminated("Hello \u{1F600}")))
            .with("Opct", .unitFloat(unit: "#Prc", value: 75.5))
            .with("enab", .boolean(true))
            .with("long", .integer(-5))
            .with("comp", .largeInteger(1 << 40))
            .with("doub", .double(0.25))
            .with("Md  ", .enumerated(type: "BlnM", value: "Mltp"))
            .with("artboardRect", .descriptor(PSDDescriptor(classID: "classFloatRect").with("Top ", .double(1))))
            .with("list", .list([.integer(1), .text("x")]))
            .with("null", .reference([
                .property(cls("", "Lyr "), key: "Nm  "), .classRef(cls("", "Dcmn")),
                .enumerated(cls("", "Lyr "), type: "Ordn", value: "Trgt"), .offset(cls("", "Lyr "), -1),
                .identifier(7), .index(2), .name(cls("", "Lyr "), "Bg"),
            ]))
            .with("type", .classType(cls("c", "Clr ")))
            .with("glbc", .globalClass(cls("c", "RGBC")))
            .with("glbo", .globalObject(PSDDescriptor()))
            .with("alis", .alias(Data([1, 2, 3])))
            .with("tdta", .rawData(Data([0xDE, 0xAD])))
            .with("pth ", .path(Data([9, 9])))
            .with("ObAr", .objectArray(PSDDescriptor.ObjectArray(prefix: 16, body: PSDDescriptor(classID: "rationalPoint")
                    .with("Hrzn", .unitFloats(unit: "#Pxl", values: [1, 2])))))
    }
}

@Suite struct DescriptorTests {
    @Test func roundTripAllTypes() throws {
        let d = Samples.descriptor()
        let b = d.serialized()
        let p = try PSDDescriptor(bytes: b)
        #expect(p == d)
        #expect(p.serialized() == b)
    }

    @Test func stringIDsWrittenAsStrings() throws {
        for name in PSDDescriptor.stringIDs {
            #expect(PSDDescriptor.ID(name) == .string(Array(name.utf8)))
            let d = PSDDescriptor(classID: PSDDescriptor.ID(name)).with(name, .integer(1))
            let b = [UInt8](d.serialized())
            #expect(Array(b[4 ..< 12]) == [0, 0, 0, 4] + Array(name.utf8))
            #expect(Array(b[16 ..< 24]) == [0, 0, 0, 4] + Array(name.utf8))
            let back = try PSDDescriptor(bytes: b)
            #expect(back == d && back.classID.is(name) && back[name] != nil)
            var coded = b
            coded.replaceSubrange(16 ..< 24, with: [0, 0, 0, 0] + Array(name.utf8))
            let back2 = try PSDDescriptor(bytes: coded)
            #expect(back2[name] == .integer(1))
            #expect([UInt8](back2.serialized()) == coded)
        }
        #expect(PSDDescriptor.ID("view") == .code("view"))
    }

    @Test func versionedRoundTripAndPrefix() throws {
        let v = PSDVersionedDescriptor(Samples.descriptor())
        let b = v.serialized()
        #expect(Array(b.prefix(4)) == [0, 0, 0, 16])
        #expect(try PSDVersionedDescriptor(bytes: b) == v)
        var withTail = b
        withTail.append(contentsOf: [1, 2, 3])
        let (p, used) = try PSDVersionedDescriptor.parsePrefix(withTail)
        #expect(p == v && used == b.count)
        var bad = [UInt8](b)
        bad[3] = 15
        #expect(throws: PSDError.self) { try PSDVersionedDescriptor(bytes: Data(bad)) }
    }

    @Test func idEncoding() throws {
        var w = ByteWriter()
        PSDDescriptor.ID("Nm  ").write(&w)
        #expect(w.bytes == [0, 0, 0, 0] + Array("Nm  ".utf8))
        var w2 = ByteWriter()
        PSDDescriptor.ID("abc").write(&w2)
        #expect(w2.bytes == [0, 0, 0, 3] + Array("abc".utf8))
        let explicit: [UInt8] = [0, 0, 0, 4] + Array("abcd".utf8)
        let id = try explicit.withByteReader { try PSDDescriptor.ID.read(&$0) }
        #expect(id == .string(Array("abcd".utf8)))
        var w3 = ByteWriter()
        id.write(&w3)
        #expect(w3.bytes == explicit)
    }

    @Test func lookupsAndStrings() {
        let d = Samples.descriptor()
        #expect(d["long"] == .integer(-5))
        #expect(d["nope"] == nil)
        #expect(d.number("Opct") == 75.5 && d.bool("enab") == true && d.enumValue("Md  ") == "Mltp")
        #expect(PSDUnicodeString.nulTerminated("ab").string == "ab")
        #expect(PSDUnicodeString(units: [0xD800, 0x41]).string == "\u{FFFD}A")
    }

    @Test func malformedDescriptors() throws {
        let b = [UInt8](Samples.descriptor().serialized())
        for cut in 0 ..< b.count { #expect(throws: PSDError.self) { try PSDDescriptor(bytes: Array(b[0 ..< cut])) } }
        #expect(throws: PSDError.self) { try PSDDescriptor(bytes: b + [0]) }
        var unknown = [UInt8](PSDDescriptor().serialized())
        unknown[unknown.count - 1] = 1
        unknown += [0, 0, 0, 0] + Array("key ????".utf8)
        #expect(throws: PSDError.unsupported("descriptor OSType ????")) { try PSDDescriptor(bytes: unknown) }
        var deep = PSDDescriptor()
        for _ in 0 ..< PSDLimits.maxDescriptorDepth + 5 { deep = PSDDescriptor().with("in  ", .descriptor(deep)) }
        #expect(throws: PSDError.limitExceeded("descriptor nesting too deep")) { try PSDDescriptor(bytes: deep.serialized()) }
        var huge = ByteWriter()
        huge.u32(0); huge.u32(0); huge.put(Array("null".utf8)); huge.u32(UInt32.max)
        #expect(throws: PSDError.self) { try PSDDescriptor(bytes: huge.bytes) }
    }

    @Test func largeListParsesWithoutCountPreallocation() throws {
        var w = ByteWriter()
        w.u32(1_000_000)
        for _ in 0 ..< 1_000_000 { w.put(Array("bool".utf8)); w.u8(1) }
        let v = try w.bytes.withByteReader { try PSDDescriptor.readTypedValue(&$0, type: "VlLs", depth: 0) }
        #expect(v.list?.count == 1_000_000)
    }

    /// Seeded replacement for photocraft's descriptor proptests.
    @Test func seededDescriptorsRoundTrip() throws {
        var rng = SeededRandom(99)
        func id() -> PSDDescriptor.ID { rng.bool() ? .code(FourCC(rawValue: UInt32(truncatingIfNeeded: rng.next()))) : .string(rng.bytes(rng.int(1 ..< 12))) }
        func ustr() -> PSDUnicodeString { PSDUnicodeString(units: (0 ..< rng.int(0 ..< 8)).map { _ in UInt16(truncatingIfNeeded: rng.next()) }) }
        func finite() -> Double { Double(Int64(truncatingIfNeeded: rng.next()) % 1_000_000_000_000) }
        func leaf() -> PSDDescriptor.Value {
            switch rng.int(0 ..< 13) {
            case 0: .double(finite())
            case 1: .unitFloat(unit: FourCC(rawValue: UInt32(truncatingIfNeeded: rng.next())), value: finite())
            case 2: .unitFloats(unit: "#Pxl", values: (0 ..< rng.int(0 ..< 4)).map { _ in finite() })
            case 3: .text(ustr())
            case 4: .enumerated(type: id(), value: id())
            case 5: .integer(Int32(truncatingIfNeeded: rng.next()))
            case 6: .largeInteger(Int64(bitPattern: rng.next()))
            case 7: .boolean(rng.bool())
            case 8: .classType(PSDDescriptor.ClassRef(name: ustr(), classID: id()))
            case 9: .alias(Data(rng.bytes(rng.int(0 ..< 8))))
            case 10: .rawData(Data(rng.bytes(rng.int(0 ..< 8))))
            case 11: .path(Data(rng.bytes(rng.int(0 ..< 8))))
            default: .reference([.identifier(UInt32(truncatingIfNeeded: rng.next())), .index(3)])
            }
        }
        func value(_ depth: Int) -> PSDDescriptor.Value {
            if depth > 2 || rng.int(0 ..< 3) > 0 { return leaf() }
            switch rng.int(0 ..< 3) {
            case 0: return .list((0 ..< rng.int(0 ..< 4)).map { _ in value(depth + 1) })
            case 1: return .descriptor(PSDDescriptor(classID: id(), name: ustr(), items: (0 ..< rng.int(0 ..< 4)).map { _ in .init(id(), value(depth + 1)) }))
            default: return .objectArray(.init(prefix: UInt32(truncatingIfNeeded: rng.next()), body: PSDDescriptor(classID: id(), items: [.init(id(), value(depth + 1))])))
            }
        }
        for _ in 0 ..< 300 {
            let d = PSDDescriptor(classID: id(), name: ustr(), items: (0 ..< rng.int(0 ..< 6)).map { _ in .init(id(), value(0)) })
            let b = d.serialized()
            let p = try PSDDescriptor(bytes: b)
            #expect(p == d)
            #expect(p.serialized() == b)
            _ = try? PSDDescriptor(bytes: Data(rng.bytes(rng.int(0 ..< 256))))
            _ = try? PSDVersionedDescriptor(bytes: Data(rng.bytes(rng.int(0 ..< 256))))
        }
    }
}

@Suite struct TaggedBlockTests {
    func rt(_ blocks: [PSDTaggedBlock], _ v: PSDVersion) throws -> [UInt8] {
        var s = MemorySink()
        try writeBlocks(blocks, to: &s, version: v, alignment: 2)
        let (back, trailing) = try s.data.withByteReader { try readBlocks(&$0, version: v, alignment: 2) }
        #expect(back == blocks)
        #expect(trailing.isEmpty)
        return [UInt8](s.data)
    }

    @Test func unicodeNameTyped() throws {
        let b = PSDTaggedBlock.unicodeName("Ebene \u{E4}\u{1F600}")
        #expect(b.data.count % 4 == 0)
        #expect(b.typed == .unicodeName("Ebene \u{E4}\u{1F600}"))
        _ = try rt([b], .psd)
    }

    @Test func sectionDividerVariants() throws {
        let cases: [(PSDSectionType, PSDBlendMode?, UInt32?, Int)] = [(.openFolder, nil, nil, 4), (.closedFolder, .passThrough, nil, 12), (.boundingDivider, .multiply, 1, 16)]
        for (kind, bm, st, len) in cases {
            let b = PSDTaggedBlock.sectionDivider(kind, blendMode: bm, subType: st)
            #expect(b.data.count == len)
            #expect(b.typed == .sectionDivider(PSDSectionDivider(kind: kind, blendMode: bm, subType: st)))
        }
        var b = PSDTaggedBlock.sectionDivider(.openFolder, blendMode: .normal)
        var d = [UInt8](b.data); d[4] = UInt8(ascii: "X"); b.data = Data(d)
        #expect(throws: PSDError.self) { try b.parsed() }
        var lsdk = PSDTaggedBlock.sectionDivider(.openFolder)
        lsdk.key = "lsdk"
        #expect(lsdk.typed == .sectionDivider(PSDSectionDivider(kind: .openFolder)))
        for v: UInt32 in 0 ..< 6 { #expect(PSDSectionType(code: v).code == v) }
        #expect(PSDSectionType.openFolder.isFolder && !PSDSectionType.boundingDivider.isFolder)
    }

    @Test func simpleTypedBlocks() throws {
        #expect(PSDTaggedBlock.layerID(7).typed == .layerID(7))
        #expect(PSDTaggedBlock.nameSource("cont").typed == .nameSource("cont"))
        #expect(PSDTaggedBlock.blendClippedAsGroup(true).typed == .blendClippedAsGroup(true))
        #expect(PSDTaggedBlock.blendInteriorElements(false).typed == .blendInteriorElements(false))
        #expect(PSDTaggedBlock.knockout(2).typed == .knockout(2))
        #expect(PSDTaggedBlock.transparencyShapes(false).typed == .transparencyShapes(false))
        #expect(PSDTaggedBlock.layerMaskHidesEffects(true).typed == .layerMaskHidesEffects(true))
        #expect(PSDTaggedBlock.vectorMaskHidesEffects(true).typed == .vectorMaskHidesEffects(true))
        #expect(PSDTaggedBlock.vectorMaskHidesEffects(true).data == Data([1, 0, 0, 0]))
        #expect(throws: PSDError.self) { try PSDTaggedBlock(key: "tsly", bytes: []).parsed() }
        #expect(PSDTaggedBlock.protection(0x8000_0000).typed == .protection(0x8000_0000))
        #expect(PSDTaggedBlock.sheetColor(3).typed == .sheetColor(3))
        #expect(PSDTaggedBlock.fillOpacity(128).typed == .fillOpacity(128))
        #expect(PSDTaggedBlock(key: "shmd", bytes: [0, 0, 0, 0]).typed == .metadataSetting(Data([0, 0, 0, 0])))
        #expect(try PSDTaggedBlock(key: "lfx2", bytes: []).parsed() == nil)
        #expect(throws: PSDError.self) { try PSDTaggedBlock(key: "lyid", bytes: [1]).parsed() }
    }

    @Test func paddingVariants() throws {
        let b = PSDTaggedBlock(key: "abcd", bytes: [1, 2, 3])
        #expect(try rt([b, b], .psd).count == 2 * (12 + 4))
        var a = PSDTaggedBlock(key: "abcd", bytes: [1, 2, 3]); a.padding = [0, 0, 0]
        var c = PSDTaggedBlock(key: "efgh", bytes: [1, 2]); c.padding = [0, 0]
        var e = PSDTaggedBlock(key: "ijkl", bytes: [1]); e.padding = []
        _ = try rt([a, c, e], .psd)
        var b64 = PSDTaggedBlock(key: "Lr16", bytes: [0, 0, 0, 0, 0, 0]); b64.signature = "8B64"
        _ = try rt([b64], .psb)
    }

    @Test func psbLongKeyTable() throws {
        for key in psbLongKeys {
            #expect(usesLongLength(.psb, key) && !usesLongLength(.psd, key))
            let b = PSDTaggedBlock(key: key, bytes: [7, 7, 7, 7])
            let out = try rt([b], .psb)
            #expect(out.count == 8 + 8 + 4)
            #expect(b.encodedLength(.psb) == out.count)
            #expect(try rt([b], .psd).count == 8 + 4 + 4)
        }
        #expect(!usesLongLength(.psb, "luni"))
    }

    /// Beyond photocraft: an unknown PSB key written with an 8-byte length is detected (and kept).
    @Test func psbUnknownLongKeyDetected() throws {
        var w = ByteWriter()
        w.put(Array("8BIMzNew".utf8)); w.u64(6); w.put([1, 2, 3, 4, 5, 6]); w.zeros(2)
        w.put(Array("8BIMluni".utf8)); w.u32(4); w.put([0, 0, 0, 0])
        let (blocks, trailing) = try w.bytes.withByteReader { try readBlocks(&$0, version: .psb, alignment: 2) }
        #expect(trailing.isEmpty)
        #expect(blocks.count == 2)
        #expect(blocks[0].longLengthOverride == true && blocks[0].data == Data([1, 2, 3, 4, 5, 6]))
        var s = MemorySink()
        try writeBlocks(blocks, to: &s, version: .psb, alignment: 2)
        #expect([UInt8](s.data) == w.bytes)
    }

    @Test func trailingBytes() throws {
        var s = MemorySink()
        try writeBlocks([.layerID(1)], to: &s, version: .psd, alignment: 2)
        var b8 = [UInt8](s.data) + [UInt8](repeating: 0, count: 8)
        let (blocks, trailing) = try b8.withByteReader { try readBlocks(&$0, version: .psd, alignment: 2) }
        #expect(blocks.count == 1 && trailing == [UInt8](repeating: 0, count: 8))
        b8 = [UInt8](s.data) + [0, 0]
        let (blocks2, trailing2) = try b8.withByteReader { try readBlocks(&$0, version: .psd, alignment: 2) }
        #expect(blocks2[0].padding == [0, 0] && trailing2.isEmpty)
        var over = ByteWriter()
        over.put(Array("8BIMabcd".utf8)); over.u32(100); over.zeros(4)
        #expect(throws: PSDError.self) { try over.bytes.withByteReader { try readBlocks(&$0, version: .psd, alignment: 2) } }
    }

    @Test func checkStructure() throws {
        var lfx = Data([0, 0, 0, 0]); lfx.append(TestGen.sampleDescriptor().serialized())
        try PSDTaggedBlock(key: "lfx2", data: lfx).checkStructure()
        var bad = lfx; bad.append(contentsOf: [1, 2, 3, 4])
        #expect(throws: PSDError.self) { try PSDTaggedBlock(key: "lfx2", data: bad).checkStructure() }
        try PSDTaggedBlock(key: "zzzz", bytes: [1]).checkStructure()
    }
}

@Suite struct LayerRecordTests {
    func sampleRecord(_ v: PSDVersion) throws -> PSDLayerRecord {
        let px = (0 ..< 20).map { UInt8($0) }
        var channels: [PSDChannel] = []
        for (id, comp) in [(Int16(-1), PSDCompression.rle), (0, .raw), (1, .zip), (2, .zipPrediction)] {
            channels.append(try PSDChannel.encode(id: id, compression: comp, decoded: px, width: 5, height: 4, depth: 8, version: v))
        }
        channels.append(try PSDChannel.encode(id: -2, compression: .rle, decoded: [1, 2, 3, 4], width: 2, height: 2, depth: 8, version: v))
        return PSDLayerRecord(rect: PSDRect(x: -3, y: 2, width: 5, height: 4), channels: channels, blendMode: .screen, opacity: 200, clipping: 1,
                              flags: .hidden, mask: .mask(PSDLayerMask(rect: PSDRect(x: 0, y: 0, width: 2, height: 2), defaultColor: 255, flags: PSDLayerMask.flagRelative)),
                              blendingRanges: .full(channels: 3), name: Array("abc".utf8), blocks: [.unicodeName("\u{E4}bc"), .layerID(5)])
    }

    func rt(_ info: PSDLayerInfo, _ v: PSDVersion) throws -> [UInt8] {
        let out = try info.bodyBytes(v)
        let back = try out.withByteReader { try PSDLayerInfo.readBody(&$0, version: v) }
        #expect(back == info)
        #expect(try back.bodyBytes(v) == out)
        return [UInt8](out)
    }

    @Test func emptyLayerInfo() throws { #expect(try rt(PSDLayerInfo(), .psd) == [0, 0]) }

    @Test func recordRoundTripPSDandPSB() throws {
        for v in PSDVersion.allCases {
            let out = try rt(PSDLayerInfo(mergedAlpha: true, layers: [try sampleRecord(v), PSDLayerRecord()]), v)
            #expect(out.count % 2 == 0)
            #expect(Array(out[0 ..< 2]) == [0xFF, 0xFE])
        }
    }

    @Test func psbChannelLengthsAre8Bytes() throws {
        let info = PSDLayerInfo(layers: [PSDLayerRecord(channels: [PSDChannel(id: 0, compression: .raw, data: Data())])])
        #expect(try rt(info, .psb).count == (try rt(info, .psd).count) + 4)
    }

    @Test func channelDecodeAndAccessors() throws {
        let rec = try sampleRecord(.psd)
        for id: Int16 in [-1, 0, 1, 2] { #expect(try rec.decodeChannel(id, depth: 8, version: .psd) == (0 ..< 20).map { UInt8($0) }) }
        #expect(try rec.decodeChannel(-2, depth: 8, version: .psd) == [1, 2, 3, 4])
        #expect(throws: PSDError.self) { try rec.decodeChannel(7, depth: 8, version: .psd) }
        #expect(rec.displayName == "\u{E4}bc")
        #expect(!rec.isVisible && rec.layerID == 5 && rec.fillOpacity == 255 && rec.sectionType == .other)
        #expect(rec.layerMask != nil)
        #expect(rec.channelRect(-2) == PSDRect(x: 0, y: 0, width: 2, height: 2) && rec.channelRect(0) == rec.rect)
        var plain = PSDLayerRecord(name: Array("legacy".utf8))
        #expect(plain.displayName == "legacy")
        plain.blocks.append(.fillOpacity(10))
        #expect(plain.fillOpacity == 10)
        let decoded = try rec.decodeChannels([-1, 0, 1, 2, -2], depth: 8, version: .psd)
        #expect(decoded[-2] == [1, 2, 3, 4] && decoded.count == 5)
    }

    func maskBytes(_ m: PSDLayerMask) -> [UInt8] {
        var w = ByteWriter()
        m.write(&w)
        return w.bytes
    }

    @Test func maskVariantsRoundTrip() throws {
        let base = PSDLayerMask(rect: PSDRect(x: 1, y: 2, width: 3, height: 4), defaultColor: 0, flags: 0)
        var withReal = base; withReal.real = PSDRealMask(flags: 1, background: 255, rect: PSDRect(x: 0, y: 0, width: 9, height: 9)); withReal.trailing = []
        var withParams = base
        withParams.flags = PSDLayerMask.flagParameters
        withParams.parameters = PSDMaskParameters(flags: 0b1111, userDensity: 128, userFeather: 2.5, vectorDensity: 64, vectorFeather: 0.5)
        withParams.real = PSDRealMask()
        var partial = base
        partial.flags = PSDLayerMask.flagParameters
        partial.parameters = PSDMaskParameters(flags: 0b0010, userFeather: 1)
        partial.trailing = []
        for m in [base, withReal, withParams, partial] { #expect(try PSDLayerMask.parse(maskBytes(m)) == m) }
        #expect(maskBytes(base).count == 20)
        #expect(maskBytes(PSDLayerMask(rect: .zero, defaultColor: 0, flags: 0, parameters: nil, real: PSDRealMask(), trailing: [], realFirst: true)).count == 36)
    }

    /// Photoshop stores the real-mask fields before the parameters.
    @Test func realMaskBeforeParametersPhotoshopLayout() throws {
        var w = ByteWriter()
        PSDRect(x: 15, y: -1, width: 18, height: 10).write(&w)
        w.put([0, PSDLayerMask.flagParameters | 8, 0, 255])
        PSDRect(x: 0, y: 0, width: 32, height: 8).write(&w)
        w.put([0b0101, 64, 64, 0])
        let m = try PSDLayerMask.parse(w.bytes)
        #expect(m.real?.rect == PSDRect(x: 0, y: 0, width: 32, height: 8) && m.real?.background == 255)
        #expect(m.parameters?.userDensity == 64 && m.parameters?.vectorDensity == 64)
        #expect(m.trailing == [0] && m.realFirst)
        #expect(maskBytes(m) == w.bytes)
    }

    /// photocraft #949: a density-only record in the spec's order is not read as Photoshop's.
    @Test func densityOnlySpecLayout() throws {
        for (density, right) in [(UInt8(64), UInt32(1)), (200, 1), (64, 300), (1, 7)] {
            var w = ByteWriter()
            PSDRect(x: 0, y: 0, width: 1, height: 1).write(&w)
            w.put([255, PSDLayerMask.flagParameters, 0b0001, density, 0, 0])
            PSDRect(x: 0, y: 0, width: right, height: 1).write(&w)
            let m = try PSDLayerMask.parse(w.bytes)
            #expect(!m.realFirst)
            #expect(m.parameters?.userDensity == density)
            #expect(m.real == PSDRealMask(flags: 0, background: 0, rect: PSDRect(x: 0, y: 0, width: right, height: 1)))
            #expect(m.trailing.isEmpty && maskBytes(m) == w.bytes)
        }
        var w = ByteWriter()
        PSDRect(x: 0, y: 0, width: 1, height: 1).write(&w)
        w.put([255, PSDLayerMask.flagParameters, 0, 255])
        PSDRect(x: 0, y: 0, width: 1, height: 1).write(&w)
        w.put([0b0001, 64])
        let m = try PSDLayerMask.parse(w.bytes)
        #expect(m.realFirst && m.parameters?.userDensity == 64 && m.real?.background == 255 && maskBytes(m) == w.bytes)
    }

    @Test func specOrderRealAfterParameters() throws {
        var w = ByteWriter()
        PSDRect(x: 1, y: 2, width: 3, height: 4).write(&w)
        w.put([255, PSDLayerMask.flagParameters, 0b0011, 200]); w.f64(1.5); w.put([0, 255])
        PSDRect(x: 0, y: 0, width: 3, height: 3).write(&w)
        let m = try PSDLayerMask.parse(w.bytes)
        #expect(!m.realFirst && m.real?.rect == PSDRect(x: 0, y: 0, width: 3, height: 3) && m.parameters?.userFeather == 1.5)
        #expect(maskBytes(m) == w.bytes)
        var w2 = ByteWriter()
        PSDRect(x: 1, y: 2, width: 3, height: 4).write(&w2)
        w2.put([255, PSDLayerMask.flagParameters, 0b1010]); w2.f64(1); w2.f64(2); w2.put([0, 0])
        let m2 = try PSDLayerMask.parse(w2.bytes)
        #expect(m2.real == nil && m2.parameters?.userFeather == 1 && m2.parameters?.vectorFeather == 2)
    }

    @Test func shortMaskKeptRawAndFlags() throws {
        _ = try rt(PSDLayerInfo(layers: [PSDLayerRecord(mask: .raw([1, 2, 3]))]), .psd)
        var f = PSDLayerFlags()
        f.isHidden = true
        f.insert(.transparencyProtected)
        #expect(f.isHidden && f.contains(.transparencyProtected))
        f.setPixelDataIrrelevant(true)
        #expect(f.contains(.bit4Useful) && f.contains(.pixelDataIrrelevant))
        f.isHidden = false
        #expect(!f.isHidden)
        let br = PSDBlendingRanges.full(channels: 3)
        #expect(br.data.count == 32 && br.ranges.count == 4 && br.ranges[0].source == [0, 0, 255, 255])
    }

    @Test func rectHelpers() throws {
        let r = PSDRect(x: -5, y: -6, width: 10, height: 3)
        #expect(r.width == 10 && r.height == 3 && !r.isEmpty)
        #expect(try r.size() == (10, 3))
        let bad = PSDRect(top: 5, left: 0, bottom: 0, right: 1)
        #expect(throws: PSDError.self) { try bad.size() }
        #expect(bad.isEmpty)
        #expect(throws: PSDError.self) { try PSDRect(top: 0, left: Int32.min, bottom: 1, right: Int32.max).size() }
    }

    @Test func truncationAndBadSignature() throws {
        let out = try PSDLayerInfo(layers: [try sampleRecord(.psd)]).bodyBytes(.psd)
        for cut in 0 ..< out.count - 1 {
            #expect(throws: PSDError.self) { try out.prefix(cut).withByteReader { try PSDLayerInfo.readBody(&$0, version: .psd) } }
        }
        var b = [UInt8](try PSDLayerInfo(layers: [PSDLayerRecord()]).bodyBytes(.psd))
        b[20] = UInt8(ascii: "X")
        #expect(throws: PSDError.self) { try b.withByteReader { try PSDLayerInfo.readBody(&$0, version: .psd) } }
        #expect(throws: PSDError.self) { try [UInt8]([0x03, 0xE8]).withByteReader { try PSDLayerInfo.readBody(&$0, version: .psd) } }
    }

    @Test func zeroLengthChannelAndPadding() throws {
        let info = PSDLayerInfo(layers: [PSDLayerRecord(channels: [PSDChannel(id: 0, compression: nil, data: Data())])])
        _ = try rt(info, .psd)
        #expect(try info.layers[0].decodeChannel(0, depth: 8, version: .psd) == [])
        #expect(try rt(PSDLayerInfo(padding: [0, 0]), .psd).count == 4)
        _ = try rt(PSDLayerInfo(layers: [PSDLayerRecord(blendMode: .unknown("wxyz"), blocks: [PSDTaggedBlock(key: "Zzzz", bytes: [1, 2, 3, 4, 5])])]), .psd)
    }

    @Test func padToFourIsCanonical() throws {
        for v in PSDVersion.allCases {
            for c in [PSDCompression.raw, .rle] {
                var info = TestGen.layered(v, .rgb, 8, c).layerInfo!
                for align: UInt64 in [1, 2, 4, 8] {
                    var p = info
                    try p.pad(to: align, version: v)
                    let body = try p.bodyBytes(v)
                    #expect(UInt64(body.count) % max(2, align) == 0 || align == 1)
                    #expect(try body.withByteReader { try PSDLayerInfo.readBody(&$0, version: v) } == p, "canonical padding \(align)")
                }
                info.padding = [7, 7]
                #expect(try info.bodyBytes(v).suffix(2) == Data([7, 7]))
            }
        }
    }
}

@Suite struct ResourceTests {
    func rt(_ res: [PSDImageResource]) throws -> [UInt8] {
        var w = ByteWriter()
        try writeResourceSection(&w, res, trailing: [])
        let (back, trailing, warnings) = try w.bytes.withByteReader { try readResourceSection(&$0) }
        #expect(back == res && trailing.isEmpty && warnings.isEmpty)
        return w.bytes
    }

    @Test func sections() throws {
        #expect(try rt([]) == [0, 0, 0, 0])
        let out = try rt([PSDImageResource(id: 1000, data: Data([1, 2, 3]))])
        #expect(out.count == 4 + 4 + 2 + 2 + 4 + 4 && out.last == 0)
        _ = try rt([PSDImageResource(id: 2000, data: Data(repeating: 9, count: 4), name: Array("path".utf8)),
                    PSDImageResource(id: 2001, data: Data(), name: Array("abc".utf8), signature: "MeSa")])
        var w = ByteWriter()
        try writeResourceSection(&w, [PSDImageResource(id: 1005, data: PSDResolutionInfo(dpi: 72).serialized())], trailing: [])
        for cut in 0 ..< w.count { #expect(throws: PSDError.self) { try Array(w.bytes[0 ..< cut]).withByteReader { try readResourceSection(&$0) } } }
    }

    @Test func typedViews() throws {
        let ri = PSDResolutionInfo(dpi: 300)
        guard case let .resolutionInfo(p)? = PSDImageResource(id: 1005, data: ri.serialized()).typed else { Issue.record("no resolution"); return }
        #expect(p == ri && abs(p.hRes - 300) < 1e-9 && abs(p.vRes - 300) < 1e-9)
        #expect(PSDImageResource(id: 1037, data: Data([0, 0, 0, 120])).typed == .globalAngle(120))
        #expect(PSDImageResource(id: 1049, data: Data([0, 0, 0, 30])).typed == .globalAltitude(30))
        #expect(PSDImageResource(id: 1024, data: Data([0, 2])).typed == .layerState(2))
        #expect(PSDImageResource(id: 1026, data: Data([0, 1, 0, 2])).typed == .layerGroupInfo([1, 2]))
        #expect(throws: PSDError.self) { try PSDImageResource(id: 1026, data: Data([0])).parsed() }
        #expect(PSDImageResource(id: 1039, data: Data([1])).typed == .iccProfile(Data([1])))
        #expect(PSDImageResource(id: 1058, data: Data([2])).typed == .exif(Data([2])))
        #expect(PSDImageResource(id: 1060, data: Data("<x/>".utf8)).typed == .xmp("<x/>"))
        #expect(PSDImageResource(id: 1047, data: Data([0, 5])).typed == .transparentIndex(5))
        #expect(try PSDImageResource(id: 4242, data: Data()).parsed() == nil)
        var g = PSDGridAndGuides(guides: [.init(location: 32 * 10, direction: 0), .init(location: 32 * 5 + 16, direction: 1)])
        g.trailing = [1]
        guard case let .gridAndGuides(back)? = PSDImageResource(id: 1032, data: g.serialized()).typed else { Issue.record("no guides"); return }
        #expect(back == g && back.guides[1].pixels == 5.5)
    }

    @Test func versionInfoMatchesPhotoshopBytes() throws {
        let r = PSDVersionInfo.resource(hasRealMergedData: true)
        var want: [UInt8] = [0, 0, 0, 1, 1]
        for s in ["Adobe Photoshop", "Adobe Photoshop 2026"] {
            want += [0, 0, 0, UInt8(s.utf16.count)]
            for u in s.utf16 { want += [UInt8(u >> 8), UInt8(u & 0xFF)] }
        }
        want += [0, 0, 0, 1]
        #expect([UInt8](r.data) == want)
        guard case let .versionInfo(v)? = PSDVersionInfo.resource(hasRealMergedData: false).typed else { Issue.record("no version info"); return }
        #expect(!v.hasRealMergedData)
    }

    @Test func thumbnailHeader() throws {
        let r = PSDThumbnail.resource(jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]), width: 10, height: 4)
        guard case let .thumbnail(t)? = r.typed else { Issue.record("no thumbnail"); return }
        #expect(t.format == 1 && t.width == 10 && t.height == 4 && t.imageData == Data([0xFF, 0xD8, 0xFF, 0xD9]) && t.bitsPerPixel == 24)
    }
}

@Suite struct PathSliceEffectsMetadataTests {
    static func sampleSubpaths() -> [PSDSubpath] {
        [
            PSDSubpath(closed: true, operation: 1, knots: [
                PSDKnot(linked: false, pre: CGPoint(x: 0.25, y: 0.25), anchor: CGPoint(x: 0.25, y: 0.25), post: CGPoint(x: 0.25, y: 0.25)),
                PSDKnot(linked: true, pre: CGPoint(x: 0.625, y: 0.125), anchor: CGPoint(x: 0.75, y: 0.25), post: CGPoint(x: 0.875, y: 0.375)),
                PSDKnot(linked: false, pre: CGPoint(x: 0.5, y: 0.75), anchor: CGPoint(x: 0.5, y: 0.75), post: CGPoint(x: 0.5, y: 0.75)),
            ]),
            PSDSubpath(closed: false, operation: 2, knots: [PSDKnot(linked: false, pre: CGPoint(x: -0.5, y: 1.5), anchor: CGPoint(x: 0, y: 1), post: CGPoint(x: 0.0625, y: 0.9375))]),
        ]
    }

    @Test func pathsRoundTrip() throws {
        let p = PSDPathData(subpaths: Self.sampleSubpaths(), initialFill: true)
        let bytes = p.serialized()
        #expect(bytes.count == 8 * 26)
        let q = try PSDPathData(bytes: bytes)
        #expect(q.serialized() == bytes && q.subpaths == Self.sampleSubpaths() && q.initialFill)
        let vm = PSDVectorMask(flags: PSDVectorMask.flagInvert, path: PSDPathData(subpaths: Self.sampleSubpaths(), initialFill: false))
        #expect(try PSDVectorMask(bytes: vm.serialized()) == vm)
        #expect(throws: PSDError.self) { try PSDVectorMask(bytes: Data(count: 4)) }
        #expect(PSDFixed.fromDouble(1) == 1 << 24 && PSDFixed.toDouble(-(1 << 23)) == -0.5 && PSDFixed.fromDouble(1e12) == Int32.max)
        var lenient = PSDPathData(subpaths: Self.sampleSubpaths(), initialFill: false)
        lenient.records.removeAll { $0.isLength }
        #expect(lenient.subpaths.count == 2 && lenient.subpaths[0].knots.count == 3)
        let cg = vm.path.cgPath(documentWidth: 100, documentHeight: 100)
        #expect(!cg.isEmpty)
    }

    @Test func pathsDoNotPreallocateFromCounts() throws {
        var w = ByteWriter()
        for _ in 0 ..< 100_000 { w.u16(0); w.u16(0xFFFF); w.zeros(22) }
        let subs = try PSDPathData(bytes: w.data).subpaths
        #expect(subs.count == 100_000 && subs.allSatisfy { $0.knots.isEmpty })
    }

    static func sampleSlices() -> PSDSlices {
        var s = PSDSlices()
        s.bounds = [0, 0, 80, 100]
        s.groupName = "site"
        var a = PSDSlice(); a.id = 0; a.origin = 0; a.kind = 1; a.rect = [0, 0, 100, 10]
        var b = PSDSlice(); b.id = 1; b.origin = 2; b.name = "logo"; b.kind = 1; b.rect = [20, 10, 60, 30]
        b.url = "https://example.org/"; b.target = "_blank"; b.message = "hi"; b.alt = "Logo"; b.cellTextIsHTML = true
        b.cellText = "<b>x</b>"; b.horizontalAlign = 1; b.verticalAlign = 2; b.color = [255, 10, 20, 30]
        var c = PSDSlice(); c.id = 2; c.origin = 1; c.layerID = 7; c.kind = 0; c.rect = [5, 40, 25, 70]; c.outsets = [1, 2, 3, 4]
        s.slices = [a, b, c]
        return s
    }

    @Test func slicesV6AndV7() throws {
        let s = Self.sampleSlices()
        let bytes = s.serialized()
        let back = try PSDSlices(bytes: bytes)
        #expect(back == s && back.serialized() == bytes)
        let v7 = try PSDSlices(bytes: s.descriptorBytes())
        #expect(v7.version == 7 && v7.groupName == "site" && v7.bounds == s.bounds && v7.slices.count == 3)
        #expect(v7.slices[1].rect == [20, 10, 60, 30] && v7.slices[1].alt == "Logo" && v7.slices[1].target == "_blank")
        #expect(v7.slices[2].origin == 1 && v7.slices[2].layerID == 7 && v7.slices[2].kind == 0 && v7.slices[2].outsets == [1, 2, 3, 4])
        for cut in [0, 3, 10, 30, 120] { #expect(throws: PSDError.self) { try PSDSlices(bytes: bytes.prefix(cut)) } }
        var huge = ByteWriter(); huge.u32(6); huge.zeros(16); huge.u32(0); huge.u32(UInt32.max)
        #expect(throws: PSDError.self) { try PSDSlices(bytes: huge.data) }
        #expect(throws: PSDError.self) { try PSDSlices(bytes: Data([0, 0, 0, 9])) }
    }

    static func fxItem(_ id: String, mask: Bool) throws -> PSDFilterEffectsItem {
        let rect = PSDRect(top: 1, left: 2, bottom: 5, right: 6)
        func plane(_ v: UInt8) throws -> PSDEffectsPlane { try .encode(.rle, decoded: [UInt8](repeating: v, count: 16), width: 4, height: 4, depth: 8) }
        var slots = [PSDEffectsPlane?](repeating: nil, count: 26)
        slots[0] = try plane(10)
        slots[25] = try plane(255)
        return PSDFilterEffectsItem(id: id, rect: rect, depth: 8, maxChannels: 24, slots: slots, mask: mask ? (rect, try plane(128)) : nil)
    }

    @Test func filterEffects() throws {
        let fx = PSDFilterEffects(version: 3, items: [try Self.fxItem("a-1", mask: true), try Self.fxItem("b-2", mask: false)])
        let bytes = fx.serialized()
        let back = try PSDFilterEffects(bytes: bytes)
        #expect(back == fx)
        #expect(back.items[0].decodedMask()?.1 == [UInt8](repeating: 128, count: 16))
        #expect(try back.items[0].slots[0]!.decode(width: 4, height: 4, depth: 8) == [UInt8](repeating: 10, count: 16))
        #expect(try PSDFilterEffects(bytes: PSDFilterEffects(version: 3).serialized()) == PSDFilterEffects(version: 3))
        var padded = bytes; padded.append(contentsOf: [0, 0])
        _ = try PSDFilterEffects(bytes: padded)
        padded.append(7)
        #expect(throws: PSDError.self) { try PSDFilterEffects(bytes: padded) }
        var rng = SeededRandom(0x9E37_79B9_7F4A_7C15)
        let base = [UInt8](bytes)
        for _ in 0 ..< 1000 {
            var b = base
            for _ in 0 ..< 1 + rng.int(0 ..< 4) { b[rng.int(0 ..< b.count)] = rng.byte() }
            if let f = try? PSDFilterEffects(bytes: Data(b)) {
                for it in f.items { _ = it.decodedMask(); for p in it.slots.compactMap({ $0 }) { _ = try? p.decode(width: 4, height: 4, depth: 8) } }
                _ = f.serialized()
            }
        }
        var bad = base; bad[3] = 9
        #expect(throws: PSDError.self) { try PSDFilterEffects(bytes: Data(bad)) }
    }

    @Test func metadataItems() throws {
        var items = [PSDMetadataItem(key: "cmls", data: Data([1, 2, 3])), PSDMetadataItem(key: "cust", data: Data(repeating: 9, count: 4))]
        items[1].copyOnSheetDuplication = true
        #expect(items[0].data.count == 4)
        let bytes = PSDMetadataItem.serialize(items)
        #expect(try PSDMetadataItem.parse(bytes) == items)
        #expect(PSDMetadataItem.serialize(try PSDMetadataItem.parse(bytes)) == bytes)
        #expect(throws: PSDError.self) { try PSDMetadataItem.parse(Data()) }
        #expect(throws: PSDError.self) { try PSDMetadataItem.parse(Data([0, 0, 0, 9])) }
        var b = PSDMetadataItem.serialize([PSDMetadataItem(key: "cmls", data: Data(count: 2))])
        b.append(0)
        #expect(throws: PSDError.self) { try PSDMetadataItem.parse(b) }
    }

    @Test func hdrToningDefault() {
        let d = PSDHDRToning.defaultData()
        #expect(d.count == 110 && PSDHDRToning.isToningData(d))
        let b = [UInt8](d)
        #expect(Array(b[72 ..< 76]) == PSDHDRToning.extraKey.bytes)
        #expect(Array(b[4 ..< 8]) == [0, 0, 0, 3] && Array(b[76 ..< 80]) == [0, 0, 0, 6])
        #expect(PSDHDRToning.colorModeData(depth: 8).isEmpty && PSDHDRToning.colorModeData(depth: 32) == d)
    }
}
