// The structure readers and writers exposed for other containers (PCIO's layered TIFF), the
// `MIB8`/`46B8` foreign-order signatures, NaN-safe fixed point, and Photoshop's NUL-terminated
// linked-file names. Uses only the public API (no `@testable`), as a client package would.

import CoreGraphics
import Foundation
import PCPSD
import Testing

@Suite struct PublicAPITests {
    // MARK: Fixed point

    @Test func nanFixedPointEncodesAsZero() throws {
        #expect(PSDFixed.fromDouble(.nan) == 0)
        #expect(PSDFixed.fromDouble(-.nan) == 0)
        #expect(PSDFixed.fromDouble(.infinity) == Int32.max)
        #expect(PSDFixed.fromDouble(-.infinity) == Int32.min)
        #expect(PSDFixed.fromDouble(0.5) == 1 << 23)
        #expect(PSDResolutionInfo(dpi: .nan).hResFixed == 0)
        // A vector knot at NaN writes as 0 instead of saturating.
        let knot = PSDKnot(linked: true, pre: CGPoint(x: Double.nan, y: 0.5), anchor: CGPoint(x: 0.25, y: Double.nan), post: .zero)
        let path = PSDPathData(subpaths: [PSDSubpath(closed: true, knots: [knot])], initialFill: false)
        let back = try PSDPathData(bytes: path.serialized())
        let k = try #require(back.subpaths.first?.knots.first)
        #expect(k.pre.x == 0 && k.pre.y == 0.5 && k.anchor.y == 0 && k.anchor.x == 0.25)
        // Gradient stops at NaN write location 0.
        let grd = PSDGrd.write([.init(name: "n", stops: [.init(location: .nan, midpoint: .nan, color: .rgb(1, 0, 0)), .init(location: 1, midpoint: 0.5, color: .rgb(0, 0, 1))])])
        #expect(try PSDGrd.parse(grd).first?.stops.first?.location == 0)
    }

    // MARK: Linked files

    @Test func embeddedLinkedFileNameIsNulTerminatedAndStrict() throws {
        let item = PSDLinkedFile.embedded(uniqueID: "abc-1", fileName: "a.png", fileType: "PNGf", data: Data([0x89, 0x50, 0x4E, 0x47]))
        let raw = [UInt8](item.raw)
        // liFD, version, Pascal "abc-1" (1 + 5), then the name: count 6 = "a.png" + NUL.
        let at = 4 + 4 + 6
        #expect(Array(raw[at ..< at + 4]) == [0, 0, 0, 6])
        #expect(Array(raw[at + 4 + 10 ..< at + 4 + 12]) == [0, 0])
        let info = try #require(item.strictInfo)
        #expect(info.fileName == "a.png")
        #expect(info.data == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(info.version == 7 && !info.lenient)
        // Round trip through a linked-file block.
        let block = PSDLinkedFiles(items: [item]).serialized()
        #expect(try PSDLinkedFiles(bytes: block).items.first?.strictInfo?.uniqueID == "abc-1")
    }

    /// Every linked item Photoshop wrote reads strictly, with a counted NUL after its file name.
    @Test(.enabled(if: Corpus.directory != nil, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)"))
    func photoshopLinkedItemsReadStrictly() throws {
        var items = 0, strict = 0, nul = 0
        for url in Corpus.files {
            let f = try PSDFile(contentsOf: url)
            for b in f.globalBlocks where ["lnk2", "lnk3", "lnkD", "lnkE"].contains(b.key) {
                for item in try PSDLinkedFiles(bytes: b.data).items {
                    items += 1
                    if item.strictInfo != nil { strict += 1 }
                    let raw = [UInt8](item.raw)
                    let at = 8 + 1 + Int(raw[8])
                    let n = Int(raw[at]) << 24 | Int(raw[at + 1]) << 16 | Int(raw[at + 2]) << 8 | Int(raw[at + 3])
                    if n > 0, raw[at + 4 + 2 * n - 2] == 0, raw[at + 4 + 2 * n - 1] == 0 { nul += 1 }
                }
            }
        }
        #expect(items == 86 && strict == items && nul == items)
        print("LINKED items: \(items), strict \(strict), NUL-terminated names \(nul)")
    }

    @Test func strictReaderRejectsWhatTheLenientOneSalvages() throws {
        // A CS2-style item without the open-descriptor flag, its data running to the item's end.
        var w = [UInt8]()
        w += Array("liFD".utf8) + [0, 0, 0, 2] + [3] + Array("uid".utf8)
        w += [0, 0, 0, 1, 0, 0x61] + Array("PNGf8BIM".utf8) + [0, 0, 0, 0, 0, 0, 0, 3] + [9, 8, 7]
        let item = PSDLinkedFile(raw: Data(w))
        #expect(item.strictInfo == nil)
        #expect(throws: (any Error).self) { try item.parsedInfo(strict: true) }
        let lenient = try #require(item.info)
        #expect(lenient.lenient && lenient.fileName == "a" && lenient.data == Data([9, 8, 7]))
        // Version outside 1–16 fails the strict reader.
        var bad = PSDLinkedFile.embedded(uniqueID: "u", fileName: "f", fileType: "PNGf", data: Data([1]))
        var raw = [UInt8](bad.raw)
        raw[4 ..< 8] = [0, 0, 0, 99]
        bad.raw = Data(raw)
        #expect(bad.strictInfo == nil)
    }

    // MARK: Signatures and block readers

    @Test func foreignOrderSignaturesAreBlocks() throws {
        let blocks = [
            PSDTaggedBlock(key: "luni", data: Data([0, 0, 0, 1, 0, 0x41, 0, 0])),
            PSDTaggedBlock(key: "ryaL", data: Data([1, 2, 3]), signature: "MIB8"),
            PSDTaggedBlock(key: "Patt", data: Data([4, 5]), signature: "46B8"),
            PSDTaggedBlock(key: "lyid", data: Data([0, 0, 0, 7])),
        ]
        #expect(PSDTaggedBlock.isBlockSignature(Array("MIB8".utf8)) && PSDTaggedBlock.isBlockSignature(Array("46B8x".utf8)))
        #expect(PSDTaggedBlock.isBlockSignature(Array("8BIM".utf8)) && !PSDTaggedBlock.isBlockSignature(Array("8BPS".utf8)))
        #expect(!PSDTaggedBlock.isBlockSignature([0x38, 0x42]))
        for version in PSDVersion.allCases {
            for alignment in [2, 4] {
                let data = try PSDTaggedBlock.serialize(blocks, version: version, alignment: alignment)
                let (back, trailing) = try PSDTaggedBlock.readBlocks(data, version: version, alignment: alignment)
                #expect(back.map(\.signature) == ["8BIM", "MIB8", "46B8", "8BIM"])
                #expect(back.map(\.isForeignOrder) == [false, true, true, false])
                #expect(back.map(\.data) == blocks.map(\.data))
                #expect(trailing.isEmpty)
                #expect(try PSDTaggedBlock.serialize(back, version: version, alignment: alignment) == data)
            }
        }
        #expect(try blocks[1].serialized(version: .psd).count == 12 + 3 + 1)
        // Bytes that are not a block stay trailing.
        let (none, rest) = try PSDTaggedBlock.readBlocks(Data("8BPSxxxxxxxxxxxx".utf8), version: .psd)
        #expect(none.isEmpty && rest.count == 16)
    }

    @Test func linterFlagsForeignOrderBlocks() throws {
        var b = PSDBuilder(width: 2, height: 2)
        var spec = PSDLayerSpec(name: "a", left: 0, top: 0, width: 1, height: 1, pixels: .u8([1, 2, 3, 255]))
        spec.extraBlocks = [PSDTaggedBlock(key: "zzzz", data: Data([1, 2, 3, 4]), signature: "MIB8")]
        b.pushLayer(spec)
        let f = try PSDFile(data: b.build().serialized())
        #expect(f.layers[0].blocks.last?.isForeignOrder == true)
        #expect(f.compatibilityIssues().contains { $0.severity == .error && $0.message.contains("little-endian") })
    }

    // MARK: Layer info, records, masks and resources

    @Test func layerInfoRecordAndMaskReadersRoundTrip() throws {
        for c in PSDTestGen.allCases() {
            guard let info = c.file.layerInfo, !info.layers.isEmpty else { continue }
            let version = c.file.header.version
            let body = try info.serializedBody(version: version)
            let back = try PSDLayerInfo(body: body, version: version)
            #expect(back == info, "\(c.name)")
            #expect(try back.serializedBody(version: version) == body, "\(c.name)")
            let unpadded = try info.serializedUnpaddedBody(version: version)
            #expect(UInt64(unpadded.count) == (try info.unpaddedLength(version)), "\(c.name)")

            for rec in info.layers {
                let bytes = try rec.serializedRecord(version: version)
                let (r, lens, n) = try PSDLayerRecord.readRecord(bytes + Data([0xAA, 0xBB]), version: version)
                #expect(n == bytes.count)
                #expect(lens == rec.channels.map { UInt64($0.data.count) + ($0.compression == nil ? 0 : 2) })
                #expect(r.blocks == rec.blocks && r.name == rec.name && r.mask == rec.mask, "\(c.name)")
                if case let .mask(m) = rec.mask {
                    let mb = m.serialized()
                    #expect(try PSDLayerMask(bytes: mb) == m)
                    if m.parameters != nil, m.real != nil { #expect(PSDLayerMask.storesRealBeforeParameters(mb) == m.realFirst) }
                }
            }
        }
        #expect(PSDLayerRecord.legacyName("Grüße") == Array("Gr??e".utf8))
        #expect(PSDLayerRecord.decodedLegacyName(Array("Gr\u{FC}".utf8)) == "Grü")
    }

    @Test func resourceBlocksRoundTrip() throws {
        let file = try #require(PSDTestGen.allCases().first { !$0.file.resources.isEmpty }?.file)
        let data = try PSDImageResource.serialize(file.resources)
        let (back, trailing, warnings) = try PSDImageResource.readBlocks(data)
        #expect(back == file.resources && trailing.isEmpty && warnings.isEmpty)
        #expect(try PSDImageResource.serialize(back) == data)
        #expect(try file.resources[0].serializedBlock() == PSDImageResource.serialize([file.resources[0]]))
        #expect(PSDImageResource.resourceSignatures.contains("8BIM"))
        // A truncated tail is kept raw (or thrown when strict).
        let cut = data.prefix(data.count - 3)
        let (some, tail, warn) = try PSDImageResource.readBlocks(Data(cut))
        #expect(some.count == back.count - 1 && !tail.isEmpty && warn.count == 1)
        #expect(throws: (any Error).self) { try PSDImageResource.readBlocks(Data(cut), strict: true) }
    }
}
