// Port of photocraft-io (crates/io/tests/psd_block_layout.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// #200: PSD export must write tagged blocks that re-parse strictly. Third-party files re-saved by
// PhotoCraft had `soLD` data under the `PlLd` key, global blocks padded only to even, a layer info
// body not padded to 4 and, in PSB, `cinf`/`lnkE` read and written with 4-byte lengths; psd-tools
// rejected or misaligned all of them. Re-saves run in photocraft's record shape and Photoshop's.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import Testing
@testable import PCIO

@Suite struct PSDBlockLayoutTests {
    init() { ExportSweep.install() }
    /// `PlLd` data per the Adobe spec ("Placed Layer"): `plcL`, version 3, Pascal uuid, page,
    /// total pages, anti-alias policy, layer type, 8 transform doubles, warp version, warp
    /// descriptor.
    static func plld(_ uuid: String) -> [UInt8] {
        var w = BEWriter()
        w.put(Array("plcL".utf8))
        w.u32(3)
        w.u8(UInt8(uuid.utf8.count))
        w.put(Array(uuid.utf8))
        for v: UInt32 in [1, 1, 16, 2] { w.u32(v) }
        for v in [0.0, 0, 4, 0, 4, 3, 0, 3] { w.f64(v) }
        w.u32(0)
        w.put([UInt8](PSDVersionedDescriptor(PSDDescriptor(classID: "warp")).serialized()))
        // Photoshop pads the data to 4 inside the block length.
        var d = w.bytes
        while d.count % 4 != 0 { d.append(0) }
        return d
    }

    /// `SoLd` data per the Adobe spec ("Placed Layer Data"): `soLD`, version 4, descriptor.
    static func sold(_ uuid: String) -> [UInt8] {
        var d = Array("soLD".utf8) + [0, 0, 0, 4]
        // The strict check wants what Photoshop needs to place the layer: its file id and transform.
        let quad: [PSDDescriptor.Value] = [0.0, 0, 4, 0, 4, 4, 0, 4].map { .double($0) }
        let desc = PSDDescriptor(classID: "null").with("Idnt", .text(.nulTerminated(uuid))).with("Trnf", .list(quad))
        d += [UInt8](PSDVersionedDescriptor(desc).serialized())
        while d.count % 4 != 0 { d.append(0) }
        return d
    }

    @Test(arguments: PSDKit.conventions) func placedLayerBlocksKeepTheirKeys(_ photoshop: Bool) throws {
        let uuid = "5b0c0b42-1b9c-11e0-a5b7-d0b1b2c3d4e5"
        var f = try PSDKit.small(.psd, .raw)
        // Photoshop's order: PlLd before SoLd. The importer keeps SoLd as the principal block.
        f.layers.append(PSDLayerRecord(name: Array("smart".utf8), blocks: [.unicodeName("smart"), PSDTaggedBlock(key: "PlLd", bytes: PSDBlockLayoutTests.plld(uuid)),
                                                                          PSDTaggedBlock(key: "SoLd", bytes: PSDBlockLayoutTests.sold(uuid))]))
        for b in try #require(f.layers.last).blocks { try b.checkStructure() }
        // A hand-built placed layer without its file: not part of the Photoshop acceptance set.
        let out = try ExportSweep.excluded { try PSDKit.viaDocBytes(f, photoshop: photoshop) }
        #expect(PSDKit.strictBlockErrors(out) == [])
        let back = try PSDFile(bytes: out)
        let rec = try #require(back.layers.first { $0.block("SoLd") != nil })
        // Before the fix the SoLd data overwrote the PlLd block.
        #expect(rec.block("PlLd").map { [UInt8]($0.data) } == PSDBlockLayoutTests.plld(uuid))
        // The fixture's SoLd holds only Idnt and Trnf and no linked-file item carries its id:
        // Photoshop refuses that file (PCPSD `placedLayerWithoutLinkedData`), so the export
        // completes the placement with Photoshop's keys, keeping its id and transform.
        let sold = try PSDPlacedLayerData(bytes: try #require(rec.block("SoLd")).data)
        let original = try PSDPlacedLayerData(bytes: Data(PSDBlockLayoutTests.sold(uuid)))
        #expect(sold.uniqueID == original.uniqueID)
        #expect(sold.descriptor.descriptor["Trnf"] == original.descriptor.descriptor["Trnf"])
        #expect(["placed", "Type", "Sz  ", "Rslt", "warp"].allSatisfy { sold.descriptor.descriptor[$0] != nil })
        #expect(!back.compatibilityIssues().contains { $0.rule == .placedLayerWithoutLinkedData })
    }

    @Test func checkStructureRejectsSwappedPlacedData() {
        let uuid = "u"
        #expect(throws: (any Error).self) { try PSDTaggedBlock(key: "PlLd", bytes: PSDBlockLayoutTests.sold(uuid)).checkStructure() }
        #expect(throws: (any Error).self) { try PSDTaggedBlock(key: "SoLd", bytes: PSDBlockLayoutTests.plld(uuid)).checkStructure() }
        var short = PSDBlockLayoutTests.plld(uuid)
        short.removeLast(3)
        #expect(throws: (any Error).self) { try PSDTaggedBlock(key: "PlLd", bytes: short).checkStructure() }
        let long = PSDBlockLayoutTests.sold(uuid) + [1, 2, 3, 4, 5]
        #expect(throws: (any Error).self) { try PSDTaggedBlock(key: "SoLd", bytes: long).checkStructure() }
        // Bad linked-file chain: a length past the end of the block.
        let lnk: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 100] + Array("liFD".utf8)
        #expect(throws: (any Error).self) { try PSDTaggedBlock(key: "lnk2", bytes: lnk).checkStructure() }
        // Unchecked keys and empty data never trap.
        for key: FourCC in ["PlLd", "SoLd", "SoLE", "lnk2", "lfx2", "zzzz"] { _ = try? PSDTaggedBlock(key: key, bytes: []).checkStructure() }
    }

    @Test(arguments: PSDKit.conventions) func globalBlocksArePaddedToFour(_ photoshop: Bool) throws {
        var f = try PSDKit.small(.psd, .raw)
        // A 77-byte global block (Content Credentials `CAI ` has this shape in the wild), stored
        // with Photoshop's 4-byte padding.
        var cai = PSDTaggedBlock(key: "CAI ", bytes: [UInt8](repeating: 7, count: 77))
        cai.padding = [0, 0, 0]
        f.globalBlocks.append(cai)
        f.globalBlocks.append(PSDTaggedBlock(key: "zEnd", bytes: [1, 2, 3, 4]))
        // The stand-in `CAI ` bytes are not Content Credentials Photoshop can read: not swept.
        let out = try ExportSweep.excluded { try PSDKit.viaDocBytes(f, photoshop: photoshop) }
        #expect(PSDKit.strictBlockErrors(out) == [])
        let back = try PSDFile(bytes: out)
        #expect(back.globalBlock("CAI ").map { [UInt8]($0.data) } == [UInt8](repeating: 7, count: 77))
        #expect(back.globalBlock("zEnd") != nil)
    }

    @Test(arguments: PSDKit.conventions) func deepDocumentsPadTheLayerInfoBlock(_ photoshop: Bool) throws {
        for depth in [SampleType.u16, .f32] {
            var d = Document(name: "d", size: PixelSize(width: 5, height: 3), mode: .rgb, depth: depth)
            let fmt = d.pixelFormat
            // Odd sizes so the unpadded layer info length is not a multiple of 4.
            d.layers.append(rasterLayer("a", fmt, rect(0, 0, 5, 3), 1, true))
            d.layers.append(rasterLayer("b", fmt, rect(1, 1, 3, 1), 2, true))
            let out = try PSDKit.export(d, "out.psd", PSDKit.options(photoshop)).bytes
            #expect(PSDKit.strictBlockErrors(out) == [], "\(depth)")
        }
    }

    @Test(arguments: PSDKit.conventions) func oddLayerBlocksCarryTheirPadInsideTheLength(_ photoshop: Bool) throws {
        var f = try PSDKit.small(.psd, .raw)
        var odd = PSDTaggedBlock(key: "zOdd", bytes: [1, 2, 3])
        odd.padding = [0]
        f.layers[0].blocks.append(odd)
        let out = try PSDKit.viaDocBytes(f, photoshop: photoshop)
        #expect(PSDKit.strictBlockErrors(out) == [])
    }

    @Test func psbLongLengthKeysAreReadAndWrittenWithEightBytes() throws {
        var f = try PSDKit.small(.psb, .raw)
        var cinf = PSDTaggedBlock(key: "cinf", bytes: [0, 0, 0, 16] + [UInt8](PSDDescriptor(classID: "null").serialized()))
        cinf.signature = "8B64"
        f.globalBlocks.append(cinf)
        let bytes = [UInt8](try f.serialized())
        // The length field is 8 bytes: the 4 bytes after the key are the high half (0).
        let marker = Array("8B64cinf".utf8)
        let at = try #require((0 ... bytes.count - marker.count).first { Array(bytes[$0 ..< $0 + 8]) == marker })
        let n = UInt64(cinf.data.count)
        #expect(Array(bytes[at + 8 ..< at + 16]) == (0 ..< 8).map { UInt8(truncatingIfNeeded: n >> (56 - 8 * UInt64($0))) })
        let back = try PSDFile(bytes: bytes)
        #expect(back.layerMaskTrailing.isEmpty)
        #expect(back.globalBlock("cinf")?.data == cinf.data)
        #expect([UInt8](try back.serialized()) == bytes)
    }
}
