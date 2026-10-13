// Layer tagged blocks are 4-aligned inside their length, as Photoshop writes all of them.
// Photoshop 27.11 refuses a `grdm` whose length is not a multiple of 4: a 126-byte block failed,
// and the same block with 2 zero bytes added opened. Covers the `layerBlockNotFourAligned` linter
// rule, the generating paths (builder, `fourAligned`, adjustment/fill block constructors), and
// byte-identity of preserved blocks.

import Foundation
import Testing
@testable import PCPSD

@Suite struct BlockAlignmentTests {
    /// A gradient map of 126 bytes (black to white, "Custom"), the size Photoshop refused.
    static func gradientMap126() -> Data {
        var g = ByteWriter()
        g.u16(1); g.u8(0); g.u8(1); g.unicodeUnits(Array("Custom".utf16) + [0]); g.u16(2)
        for (l, v): (UInt32, UInt16) in [(0, 0), (4096, 65535)] { g.u32(l); g.u32(50); PSDColorRecord(space: 0, components: [v, v, v, 0]).write(&g); g.u16(0) }
        g.u16(2); for l: UInt32 in [0, 4096] { g.u32(l); g.u32(50); g.u16(255) }
        g.u16(2); g.u16(2048); g.u16(32); g.u16(0); g.u32(0); g.u16(0); g.u16(0); g.u32(2048); g.u16(3); g.zeros(16); g.u16(0)
        return g.data
    }

    static func file(extra: [PSDTaggedBlock]) throws -> PSDFile {
        var f = try PSDFile(data: {
            var b = PSDBuilder(width: 2, height: 2)
            b.pushLayer(PSDLayerSpec(name: "a", left: 0, top: 0, width: 1, height: 1, pixels: .u8([1, 2, 3, 255])))
            return try b.serialized()
        }())
        f.layers[0].blocks += extra // as a writer that preserves blocks verbatim would
        try f.layerInfo?.pad(to: 4, version: .psd)
        return try PSDFile(data: f.serialized())
    }

    @Test func unalignedGradientMapIsAnError() throws {
        let raw = Self.gradientMap126()
        #expect(raw.count == 126)
        let issues = try Self.file(extra: [PSDTaggedBlock(key: "grdm", data: raw)]).compatibilityIssues()
        #expect(issues.count == 1, "\(issues)")
        #expect(issues.first?.rule == .layerBlockNotFourAligned && issues.first?.severity == .error && issues.first?.layerIndex == 0)
        #expect(issues.first?.message.hasPrefix("PHOTOSHOP REFUSES THE FILE") == true)
        // Two zero bytes inside the length: what made Photoshop open it.
        let fixed = PSDTaggedBlock(key: "grdm", data: raw).fourAligned()
        #expect(fixed.data.count == 128 && fixed.data.prefix(126) == raw && fixed.data.suffix(2) == Data([0, 0]))
        #expect(try Self.file(extra: [fixed]).compatibilityIssues().isEmpty)
        // The typed path: lossless `serialized()`, aligned `taggedBlock(key:)`.
        let adj = try #require(try PSDAdjustment.parse(key: "grdm", data: raw))
        #expect(adj.serialized() == raw)
        #expect(adj.taggedBlock(key: "grdm").data.count == 128)
        #expect(try PSDAdjustment.parse(key: "grdm", data: adj.taggedBlock(key: "grdm").data) != nil)
    }

    @Test func otherUnalignedLayerBlocksWarn() throws {
        let issues = try Self.file(extra: [PSDTaggedBlock(key: "zOdd", data: Data([1, 2, 3, 4, 5, 6]))]).compatibilityIssues()
        #expect(issues.map(\.rule) == [.layerBlockNotFourAligned])
        #expect(issues.first?.severity == .warning)
    }

    @Test func preservedBlocksStayByteIdentical() throws {
        let f = try Self.file(extra: [PSDTaggedBlock(key: "grdm", data: Self.gradientMap126()), PSDTaggedBlock(key: "zOdd", data: Data([7]))])
        let bytes = try f.serialized()
        let back = try PSDFile(data: bytes)
        #expect(back.layers[0].block("grdm")?.data.count == 126)
        #expect(back.layers[0].block("zOdd")?.data == Data([7]))
        #expect(try back.serialized() == bytes)
    }

    @Test func builderAlignsEveryLayerBlock() throws {
        var b = PSDBuilder(width: 4, height: 4)
        var s = PSDLayerSpec(name: "Gradient Map 1", left: 0, top: 0, width: 1, height: 1, pixels: .u8([1, 2, 3, 255]))
        s.extraBlocks = [PSDTaggedBlock(key: "grdm", data: Self.gradientMap126()), PSDTaggedBlock(key: "zOdd", data: Data([1, 2, 3]))]
        s.fillOpacity = 128
        s.mask = PSDMaskSpec(rect: PSDRect(x: 0, y: 0, width: 1, height: 1), data: [255])
        b.pushLayer(s)
        var g = PSDGroupSpec(name: "Gruppe \u{E4}")
        g.extraBlocks = [PSDFillSetting.solid(.rgb(red: 1, green: 0, blue: 0)), PSDTaggedBlock(key: "zTwo", data: Data([1, 2]))]
        try b.pushGroup(g) { $0.pushLayer(PSDLayerSpec(name: "x", left: 0, top: 0, width: 1, height: 1, pixels: .u8([1, 2, 3, 255]))) }
        let f = try PSDFile(data: b.serialized())
        for rec in f.layers {
            for blk in rec.blocks { #expect(blk.data.count % 4 == 0, "\(rec.displayName) \(blk.key) \(blk.data.count)") }
        }
        let grdm = try #require(f.layers[0].block("grdm"))
        #expect(grdm.data.count == 128 && grdm.data.prefix(126) == Self.gradientMap126())
        #expect(f.layers[0].block("zOdd")?.data == Data([1, 2, 3, 0]))
        #expect(f.compatibilityIssues().isEmpty)
        #expect(PSDFillSetting.solid(.rgb(red: 0, green: 0, blue: 1)).data.count % 4 == 0)
    }

    @Test(.enabled(if: Corpus.directory != nil, "PSD corpus not present (set PHOTOCRAFT_FIXTURES or PCPSD_CORPUS)"))
    func photoshopLayerBlocksAreFourAligned() throws {
        var blocks = 0
        for url in Corpus.files {
            let f = try PSDFile(contentsOf: url)
            for rec in f.layers {
                blocks += rec.blocks.count
                for b in rec.blocks { #expect(b.data.count % 4 == 0, "\(url.lastPathComponent) \(rec.displayName) \(b.key) \(b.data.count)") }
            }
            #expect(!f.compatibilityIssues().contains { $0.rule == .layerBlockNotFourAligned }, "\(url.lastPathComponent)")
        }
        print("ALIGNMENT corpus: \(blocks) layer blocks, all 4-aligned, 0 linter hits")
    }
}
