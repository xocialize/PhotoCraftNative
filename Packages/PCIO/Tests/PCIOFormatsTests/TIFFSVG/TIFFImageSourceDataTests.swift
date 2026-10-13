// Port of the tests of photocraft-psd (crates/psd/src/tiff.rs, `mod tests`), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCPSD
import Testing
@testable import PCIOFormats

private typealias TIFFISD = PSDTIFF.ImageSourceData

/// Keys the generator plants that the transcoder (rightly) does not know.
private let tiffUnknownKeys: [FourCC] = ["zOdd", "zNop", "Txt2"]

/// `d` without the blocks a little-endian round trip drops, and without the layer-info padding
/// (which follows the body length, so it changes when blocks are dropped).
private func tiffKnown(_ d: TIFFISD) -> TIFFISD {
    var d = d
    d.byteOrder = .big
    d.globalBlocks.removeAll { tiffUnknownKeys.contains($0.key) }
    if d.layerInfo == nil { d.layerInfoKey = "Layr" }
    if var info = d.layerInfo {
        info.padding = nil
        for i in info.layers.indices { info.layers[i].blocks.removeAll { tiffUnknownKeys.contains($0.key) } }
        d.layerInfo = info
    }
    return d
}

private func tiffRoundtrip(_ d: TIFFISD, _ name: String = "") throws -> TIFFISD {
    let (big, w0) = try d.toBytes(.big)
    #expect(w0.isEmpty, "\(name) \(w0)")
    let (little, w1) = try d.toBytes(.little)
    #expect(w1.allSatisfy { w in tiffUnknownKeys.contains { w.hasPrefix($0.string) } }, "\(name) \(w1)")
    if w1.isEmpty { #expect(big.count == little.count, "\(name)") }
    if big.count > 36 {
        #expect(big != little, "\(name)")
        #expect(Array(little[36 ..< 40]) == Array("MIB8".utf8), "\(name)")
    }
    let (backBig, w2) = try TIFFISD.fromBytes(big)
    #expect(w2.isEmpty, "\(name) \(w2)")
    let (backLittle, w3) = try TIFFISD.fromBytes(little)
    #expect(w3.isEmpty, "\(name) \(w3)")
    if little.count > 36 { #expect(backLittle.byteOrder == .little, "\(name)") }
    #expect(tiffKnown(backLittle) == tiffKnown(backBig), "\(name)")
    // The little-endian bytes are a fixed point (from the second generation on when blocks were
    // dropped, since the layer-info padding then follows the shorter body).
    let little2 = try backLittle.toBytes(.little).bytes
    let little3 = try TIFFISD.fromBytes(little2).data.toBytes(.little).bytes
    #expect(little3 == little2, "\(name)")
    return backBig
}

private func tiffSampleLayers() -> TIFFISD {
    TIFFISD.fromPSD(TIFFTestGen.layered(.psd, .rgb, 8, .rle))
}

/// One global block through both orders: the little-endian bytes parse back to the same data
/// and re-serialize to the same big-endian bytes.
@discardableResult
private func tiffBlockRoundtrip(_ key: FourCC, _ data: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) throws -> (big: [UInt8], little: [UInt8]) {
    let d = TIFFISD(globalBlocks: [PSDTaggedBlock(key: key, bytes: data)])
    let (big, _) = try d.toBytes(.big)
    let (little, w) = try d.toBytes(.little)
    #expect(w.isEmpty, "\(key) \(w)", sourceLocation: sourceLocation)
    let (back, w2) = try TIFFISD.fromBytes(little)
    #expect(w2.isEmpty, "\(key) \(w2)", sourceLocation: sourceLocation)
    #expect(back.globalBlocks.first.map { [UInt8]($0.data) } == data, "\(key)", sourceLocation: sourceLocation)
    #expect(try back.toBytes(.big).bytes == big, "\(key)", sourceLocation: sourceLocation)
    return (big, little)
}

@Suite struct TIFFImageSourceDataTests {
    @Test func generatedFilesSurviveBothOrders() throws {
        for c in TIFFTestGen.allCases() {
            let d = TIFFISD.fromPSD(c.file)
            let back = try tiffRoundtrip(d, c.name)
            #expect(back.version == d.version, "\(c.name)")
            #expect(tiffKnown(back) == tiffKnown(d), "\(c.name)")
            // Nothing but the planted unknown blocks is lost on the little-endian path.
            let (little, _) = try d.toBytes(.little)
            let (back2, _) = try TIFFISD.fromBytes(little)
            #expect(tiffKnown(back2) == tiffKnown(d), "\(c.name)")
        }
    }

    @Test func sameOrderTranscodingIsTheIdentity() throws {
        for c in TIFFTestGen.allCases() {
            let d = TIFFISD.fromPSD(c.file)
            let (big, _) = try d.toBytes(.big)
            let (same, w) = try PSDTIFF.Transcode.transcodeBlocks(Array(big[36...]), d.version, .big, .big)
            #expect(w.isEmpty)
            #expect(same == Array(big[36...]), "\(c.name)")
        }
    }

    @Test func signatureSelectsTheVersion() throws {
        var d = tiffSampleLayers()
        let (b, _) = try d.toBytes(.big)
        #expect(Array(b.prefix(36)) == PSDTIFF.signature)
        d.version = .psb
        let (b2, _) = try d.toBytes(.big)
        #expect(Array(b2.prefix(36)) == PSDTIFF.signaturePSB)
        #expect(try TIFFISD.fromBytes(b2).data.version == .psb)
        _ = try tiffRoundtrip(d)
    }

    @Test func layerKeyFollowsDepth() throws {
        #expect(PSDTIFF.layerInfoKey(8) == "Layr")
        #expect(PSDTIFF.layerInfoKey(16) == "Lr16")
        #expect(PSDTIFF.layerInfoKey(32) == "Lr32")
        for (depth, comp) in [(UInt16(16), PSDCompression.zipPrediction), (32, .zipPrediction), (16, .rle)] {
            let file = TIFFTestGen.layered(.psd, .rgb, depth, comp)
            let d = TIFFISD.fromPSD(file)
            #expect(d.layerInfoKey == PSDTIFF.layerInfoKey(depth))
            let back = try tiffRoundtrip(d)
            #expect(back.layerInfoKey == d.layerInfoKey)
            // The 16/32-bit model goes back into a PSD as a global block, like Photoshop's.
            let psd = back.intoPSD(header: file.header, resources: file.resources, imageData: file.imageData)
            guard case .globalBlock = psd.layerInfoPlacement else {
                Issue.record("placement \(psd.layerInfoPlacement)")
                continue
            }
            let again = try PSDFile(data: try psd.serialized())
            #expect(tiffKnown(TIFFISD.fromPSD(again)).layerInfo == tiffKnown(d).layerInfo)
            let (little, _) = try d.toBytes(.little)
            let (back2, _) = try TIFFISD.fromBytes(little)
            #expect(tiffKnown(back2).layerInfo == tiffKnown(d).layerInfo, "depth \(depth)")
        }
    }

    @Test func blocksArePaddedToFour() throws {
        let (b, _) = try tiffSampleLayers().toBytes(.big)
        var at = 36
        while at < b.count {
            #expect(Array(b[at ..< at + 4]) == Array("8BIM".utf8))
            let len = Int(UInt32(b[at + 8]) << 24 | UInt32(b[at + 9]) << 16 | UInt32(b[at + 10]) << 8 | UInt32(b[at + 11]))
            at += 12 + len
            at += (4 - at % 4) % 4
        }
        #expect(at == b.count)
    }

    @Test func descriptorBlocksSwapKeysAndNumbers() throws {
        var desc = PSDDescriptor(classID: "null")
        desc.items.append(.init("Opct", .unitFloat(unit: "#Prc", value: 75.5)))
        desc.items.append(.init("Nm  ", .text(.nulTerminated("Drop Shadow"))))
        desc.items.append(.init("enab", .boolean(true)))
        desc.items.append(.init("Md  ", .enumerated(type: "BlnM", value: "Mltp")))
        desc.items.append(.init("list", .list([.integer(-3), .double(1.5), .largeInteger(7)])))
        desc.items.append(.init("longKeyName", .descriptor(PSDDescriptor(classID: "innr"))))
        var data: [UInt8] = [0, 0, 0, 0]
        data += [UInt8](PSDVersionedDescriptor(desc).serialized())
        let (big, little) = try tiffBlockRoundtrip("lfx2", data)
        // Keys are reversed and the version field swapped in the little-endian bytes.
        #expect(Array(little[36 ..< 44]) == Array("MIB82xfl".utf8))
        let bodyAt = 48
        #expect(Array(little[bodyAt ..< bodyAt + 4]) == [0, 0, 0, 0])
        #expect(Array(little[bodyAt + 4 ..< bodyAt + 8]) == [16, 0, 0, 0])
        #expect(Array(big[bodyAt + 4 ..< bodyAt + 8]) == [0, 0, 0, 16])
        #expect(little.tiffContains(Array("crP#".utf8)), "unit key reversed")
        #expect(little.tiffContains(Array("longKeyName".utf8)), "string ids are not reversed")
    }

    @Test func typeBlockLayout() throws {
        var w = TIFFBytes()
        w.u16(1)
        for v in [1.0, 0.0, 0.0, 1.0, 12.5, -3.0] { w.f64(v) }
        w.u16(50)
        w.put([UInt8](PSDVersionedDescriptor(PSDDescriptor(classID: "TxLr")).serialized()))
        w.u16(1)
        w.put([UInt8](PSDVersionedDescriptor(PSDDescriptor(classID: "warp")).serialized()))
        for v in [0.0, 0.0, 100.0, 20.0] { w.f64(v) }
        let (_, little) = try tiffBlockRoundtrip("TySh", w.b)
        #expect(Array(little[48 ..< 50]) == [1, 0])
        #expect(Array(little[50 ..< 58]) == withUnsafeBytes(of: (1.0).bitPattern.littleEndian) { Array($0) })
    }

    @Test func legacyEffectsAndAdjustments() throws {
        // lrFX with a drop shadow and a solid fill.
        var fx = TIFFBytes()
        fx.u16(0)
        fx.u16(3)
        fx.put("8BIMcmnS")
        fx.u32(7)
        fx.u32(0)
        fx.u8(1)
        fx.u16(0)
        fx.put("8BIMdsdw")
        var sh = TIFFBytes()
        sh.u32(2)
        for v: Int32 in [5 << 16, 75 << 16, 120 << 16, 7 << 16] { sh.i32(v) }
        for _ in 0 ..< 5 { sh.u16(0) }
        sh.put("8BIMmul ")
        sh.u8(1)
        sh.u8(1)
        sh.u8(191)
        sh.u16(0)
        sh.u16(0x1234)
        sh.u16(0)
        sh.u16(0)
        sh.u16(0)
        fx.u32(UInt32(sh.b.count))
        fx.put(sh.b)
        fx.put("8BIMsofi")
        var so = TIFFBytes()
        so.u32(2)
        so.put("8BIMnorm")
        so.u16(0)
        so.u16(0xFFFF)
        so.u16(0)
        so.u16(0)
        so.u16(0)
        so.u8(255)
        so.u8(1)
        so.u16(0)
        so.u16(0xFFFF)
        so.u16(0)
        so.u16(0)
        so.u16(0)
        fx.u32(UInt32(so.b.count))
        fx.put(so.b)
        let (_, little) = try tiffBlockRoundtrip("lrFX", fx.b)
        #expect(little.tiffContains(Array("MIB8wdsd".utf8)), "effect keys reversed")
        #expect(little.tiffContains([0x34, 0x12]), "colour component swapped")

        // levl: version + 29 records + the Lvls extension.
        var lv = TIFFBytes()
        lv.u16(2)
        for i in 0 ..< 29 * 5 { lv.u16(UInt16(i)) }
        lv.put("Lvls")
        lv.u16(3)
        lv.u16(33)
        for i in 0 ..< 4 * 5 { lv.u16(1000 + UInt16(i)) }
        let (_, littleLv) = try tiffBlockRoundtrip("levl", lv.b)
        #expect(littleLv.tiffContains(Array("slvL".utf8)))

        // curv with the Crv extension.
        var cv = TIFFBytes()
        cv.u8(0)
        cv.u16(1)
        cv.u32(0b101)
        for v: UInt16 in [2, 0, 0, 255, 255, 1, 128, 100] { cv.u16(v) }
        cv.put("Crv ")
        cv.u16(4)
        cv.u32(1)
        for v: UInt16 in [2, 1, 7, 9] { cv.u16(v) }
        try tiffBlockRoundtrip("curv", cv.b)

        var expA = TIFFBytes()
        expA.u16(1)
        expA.f32(0.5)
        expA.f32(0)
        expA.f32(1)
        var fxrp = TIFFBytes()
        fxrp.f64(1.5)
        fxrp.f64(2.5)
        var lsct = TIFFBytes()
        lsct.u32(3)
        lsct.put("8BIMpass")
        let cases: [(FourCC, [UInt8])] = [
            ("hue2", [0, 2, 0, 0, 0, 10, 0, 20, 0, 30, 0, 40, 0, 50, 0, 60]),
            ("brit", [0, 10, 0, 20, 0, 30, 1, 0]),
            ("thrs", [0, 128, 0, 0]),
            ("post", [0, 4, 0, 0]),
            ("nvrt", []),
            ("expA", expA.b),
            ("blnc", [UInt8](repeating: 0, count: 20)),
            ("mixr", [0, 1, 0, 0, 0, 100, 0, 0, 0, 0, 0, 0, 0, 0]),
            ("selc", [0, 1, 0, 0, 0, 5, 0, 6, 0, 7, 0, 8]),
            ("phfl", [0, 3, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 25, 1, 0]),
            ("phfl", [0, 2, 0, 0, 1, 0, 2, 0, 3, 0, 4, 0, 0, 0, 25, 1, 0]),
            ("lclr", [0, 1, 0, 0, 0, 0, 0, 0]),
            ("fxrp", fxrp.b),
            ("brst", [0, 0, 0, 1, 0, 0, 0, 2]),
            ("FMsk", [0, 0, 255, 255, 0, 0, 0, 0, 0, 0, 0, 50]),
            ("lsct", lsct.b),
            ("lspf", [0, 0, 0, 5]),
            ("lnsr", Array("layr".utf8)),
            ("knko", [1, 0, 0, 0]),
            ("knko", [2, 0, 0, 0]),
            ("infx", [1, 0, 0, 0]),
            ("clbl", [0, 0, 0, 0]),
            ("tsly", [0, 0, 0, 0]),
            ("lmgm", [1, 0, 0, 0]),
            ("vmgm", [1, 0, 0, 0]),
            ("iOpa", [128, 0, 0, 0]),
        ]
        for (key, data) in cases {
            let (big, little) = try tiffBlockRoundtrip(key, data)
            if data.count >= 2, key != "nvrt" { #expect(big != little, "\(key)") }
        }
    }

    @Test func globalLayerMaskBlock() throws {
        let d = TIFFISD(globalLayerMask: PSDGlobalLayerMask(data: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 50, 128, 0]))
        let (little, w) = try d.toBytes(.little)
        #expect(w.isEmpty)
        #expect(Array(little[36 ..< 44]) == Array("MIB8ksML".utf8))
        let (back, _) = try TIFFISD.fromBytes(little)
        #expect(back.globalLayerMask == d.globalLayerMask)
        #expect(back.globalLayerMask?.opacity == 50)
    }

    @Test func gradientMapLayout() throws {
        var g = TIFFBytes()
        g.u16(3)
        g.u8(0)
        g.u8(1)
        g.put("Lnr ")
        g.u32(2)
        g.u16(UInt16(UInt8(ascii: "a")))
        g.u16(0)
        g.u16(2)
        for (loc, mid): (UInt32, UInt32) in [(0, 50), (4096, 50)] {
            g.u32(loc)
            g.u32(mid)
            for v: UInt16 in [0, 0x1111, 0x2222, 0x3333, 0, 0] { g.u16(v) }
        }
        g.u16(2)
        for loc: UInt32 in [0, 4096] {
            g.u32(loc)
            g.u32(50)
            g.u16(100)
        }
        for v: UInt16 in [2, 1, 32, 0] { g.u16(v) }
        g.u32(0xDEAD_BEEF)
        for _ in 0 ..< 12 { g.u16(0) }
        let (_, little) = try tiffBlockRoundtrip("grdm", g.b)
        #expect(little.tiffContains([0xEF, 0xBE, 0xAD, 0xDE]))
        #expect(little.tiffContains(Array(" rnL".utf8)))
    }

    @Test func vectorMaskRecords() throws {
        var v = TIFFBytes()
        v.u32(3)
        v.u32(0)
        // Closed length record, then two linked knots.
        v.u16(0)
        v.u16(2)
        v.i16(1)
        v.put([UInt8](repeating: 0, count: 20))
        for sel: UInt16 in [1, 1] {
            v.u16(sel)
            for i: Int32 in 0 ..< 6 { v.i32((i + 1) * 0x0010_0000) }
        }
        let (_, little) = try tiffBlockRoundtrip("vmsk", v.b)
        #expect(little.tiffContains([0, 0, 0x10, 0]), "fixed-point coordinate swapped")
    }

    @Test func patternBlock() throws {
        let plane: [UInt8] = Array(0 ..< 16)
        let p = PSDPattern(mode: 3, width: 4, height: 4, name: "dots", id: "abc", palette: nil, depth: 8,
                           channels: [plane, plane, plane], alpha: plane)
        let data = [UInt8](try PSDPattern.writeBlock([p]))
        try tiffBlockRoundtrip("Patt", data)
        // Little-endian pattern data parses back into the same pattern.
        let d = TIFFISD(globalBlocks: [PSDTaggedBlock(key: "Patt", bytes: data)])
        let (little, _) = try d.toBytes(.little)
        let (back, _) = try TIFFISD.fromBytes(little)
        #expect(try PSDPattern.parseBlock(back.globalBlocks[0].data) == [p])
    }

    @Test func filterEffectsBlock() throws {
        let plane = try PSDEffectsPlane.encode(.rle, decoded: [1, 2, 3, 4, 5, 6], width: 3, height: 2, depth: 8)
        let mask = try PSDEffectsPlane.encode(.raw, decoded: [UInt8](repeating: 9, count: 6), width: 3, height: 2, depth: 8)
        let rect = PSDRect(top: 0, left: 0, bottom: 2, right: 3)
        let fx = PSDFilterEffects(version: 1, items: [
            PSDFilterEffectsItem(id: "x", version: 1, rect: rect, depth: 8, maxChannels: 1, slots: [plane, nil, plane], mask: (rect, mask)),
        ])
        let data = [UInt8](fx.serialized())
        try tiffBlockRoundtrip("FEid", data)
        let d = TIFFISD(globalBlocks: [PSDTaggedBlock(key: "FEid", bytes: data)])
        let (little, _) = try d.toBytes(.little)
        let (back, _) = try TIFFISD.fromBytes(little)
        #expect(try PSDFilterEffects(bytes: back.globalBlocks[0].data) == fx)
    }

    @Test func metadataSettingItems() throws {
        let desc = PSDVersionedDescriptor(PSDDescriptor(classID: "null")).serialized()
        try tiffBlockRoundtrip("shmd", [UInt8](PSDMetadataItem.serialize([PSDMetadataItem(key: "cmls", data: desc)])))
        // An unknown item cannot be converted: it is dropped on its own, the rest stays.
        let items = [
            PSDMetadataItem(key: "zzzz", data: Data([1, 2, 3, 4, 5, 6, 7, 8])),
            PSDMetadataItem(key: "mdyn", data: Data([0, 0, 0, 1])),
            PSDMetadataItem(key: "cmls", data: desc),
        ]
        let d = TIFFISD(globalBlocks: [PSDTaggedBlock(key: "shmd", data: PSDMetadataItem.serialize(items))])
        let (little, w) = try d.toBytes(.little)
        #expect(w.count == 1, "\(w)")
        #expect(w.first?.hasPrefix("shmd item zzzz dropped") == true, "\(w)")
        let (back, w2) = try TIFFISD.fromBytes(little)
        #expect(w2.isEmpty)
        #expect(try PSDMetadataItem.parse(back.globalBlocks[0].data) == Array(items[1...]))
    }

    @Test func unknownDescriptorShapedBlocksAreConverted() throws {
        // A key the transcoder has never heard of, holding a versioned descriptor (as every block
        // Photoshop added since CS6 does): converted, not dropped.
        let desc = PSDDescriptor(classID: "null").with("Nm  ", .text(.nulTerminated("x")))
        let data = [UInt8](PSDVersionedDescriptor(desc).serialized())
        try tiffBlockRoundtrip("Qqqq", data)
        try tiffBlockRoundtrip("Qqqq", [0, 0, 0, 3] + data)
        // Empty data needs no conversion either.
        try tiffBlockRoundtrip("Mt32", [])
    }

    @Test func linkedLayerItems() throws {
        // One embedded file (liFD, version 7) as photocraft-io writes it.
        var item = TIFFBytes()
        item.put("liFD")
        item.u32(7)
        item.u8(4)
        item.put("uuid")
        let units = Array("a.png\0".utf16)
        item.u32(UInt32(units.count))
        for u in units { item.u16(u) }
        item.put("png ")
        item.put("8BIM")
        let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3]
        item.u64(UInt64(bytes.count))
        item.u8(0)
        item.put(bytes)
        item.u32(0)
        item.f64(0)
        item.u8(0)
        var data = TIFFBytes()
        data.u64(UInt64(item.b.count))
        data.put(item.b)
        while data.b.count % 4 != 0 { data.u8(0) }
        let (_, little) = try tiffBlockRoundtrip("lnk2", data.b)
        #expect(little.tiffContains(Array("DFil".utf8)), "item type key reversed")
        #expect(little.tiffContains(bytes), "file bytes untouched")
    }

    @Test func annotationBlock() throws {
        var a = TIFFBytes()
        a.u16(2)
        a.u16(1)
        a.u32(1)
        var item = TIFFBytes()
        item.put("txtA")
        item.u8(0)
        item.u8(1)
        item.u16(0)
        for v: Int32 in [10, 20, 30, 40, 50, 60, 70, 80] { item.i32(v) }
        item.u16(0)
        for v: UInt16 in [0xFFFF, 0, 0, 0] { item.u16(v) }
        for s in ["me", "note", "2026"] {
            item.u8(UInt8(s.utf8.count))
            item.put(s)
            if (1 + s.utf8.count) % 2 == 1 { item.u8(0) }
        }
        let text: [UInt8] = [0xFE, 0xFF, 0, UInt8(ascii: "h"), 0, UInt8(ascii: "i")]
        var d = TIFFBytes()
        d.put("txtC")
        d.u32(UInt32(text.count))
        d.put(text)
        item.u32(UInt32(d.b.count + 4))
        item.put(d.b)
        a.u32(UInt32(item.b.count + 4))
        a.put(item.b)
        let (_, little) = try tiffBlockRoundtrip("Anno", a.b)
        #expect(little.tiffContains(Array("Atxt".utf8)))
        #expect(little.tiffContains(text), "text kept as stored")
    }

    @Test func unknownBlocksKeptInBigDroppedInLittle() throws {
        var d = tiffSampleLayers()
        d.globalBlocks.append(PSDTaggedBlock(key: "Zzzz", bytes: [1, 2, 3, 4, 5]))
        let (big, w) = try d.toBytes(.big)
        #expect(w.isEmpty)
        let (back, w2) = try TIFFISD.fromBytes(big)
        #expect(w2.isEmpty)
        #expect(back.globalBlocks == d.globalBlocks)
        // Big-endian data of unknown layout cannot go into a little-endian file.
        let (little, w3) = try d.toBytes(.little)
        #expect(w3.filter { $0.hasPrefix("Zzzz block (5 bytes) dropped") }.count == 1, "\(w3)")
        let (back2, w4) = try TIFFISD.fromBytes(little)
        #expect(w4.isEmpty)
        #expect(back2.globalBlocks.map(\.key) == ["Patt", "FMsk"])
        #expect(tiffKnown(back2).layerInfo == tiffKnown(d).layerInfo)
    }

    @Test func unknownBlocksFromALittleEndianFileAreKeptWithTheirByteOrder() throws {
        let d = tiffSampleLayers()
        let (little, _) = try d.toBytes(.little)
        // A little-endian file with a block of unknown layout, among tiffKnown ones.
        var raw = little
        raw += Array("MIB8zzzZ".utf8)
        raw += [6, 0, 0, 0]
        raw += [9, 8, 7, 6, 5, 4, 0, 0]
        raw += Array("MIB8diyl".utf8)
        raw += [4, 0, 0, 0]
        raw += [7, 0, 0, 0]
        let (back, w) = try TIFFISD.fromBytes(raw)
        #expect(w.isEmpty, "\(w)")
        #expect(tiffKnown(back).layerInfo == tiffKnown(d).layerInfo)
        let kept = try #require(back.globalBlocks.first { $0.key == "Zzzz" })
        #expect(PSDTIFF.isForeignOrder(kept))
        #expect(kept.signature == "MIB8")
        #expect([UInt8](kept.data) == [9, 8, 7, 6, 5, 4])
        // The tiffKnown block after it was still converted.
        #expect(back.globalBlocks.first { $0.key == "lyid" }.map { [UInt8]($0.data) } == [0, 0, 0, 7])
        // Written back to a little-endian TIFF, the bytes are exactly what was read.
        let (again, w2) = try back.toBytes(.little)
        #expect(w2.isEmpty, "\(w2)")
        let tail = Array(raw[(raw.count - 18 - 16)...])
        #expect(again.tiffContains(tail), "foreign-order block restored verbatim")
        #expect(try TIFFISD.fromBytes(again).data.globalBlocks == back.globalBlocks)
        // The big-endian (PSD) model keeps the marker, so a PSD writer can tell it apart.
        let (big, _) = try back.toBytes(.big)
        #expect(big.tiffContains(Array("MIB8Zzzz".utf8)))
        #expect(try TIFFISD.fromBytes(big).data.globalBlocks == back.globalBlocks)
    }

    @Test func rleCountsFollowTheContainerAndSamplesDoNot() throws {
        let file = TIFFTestGen.layered(.psd, .rgb, 16, .rle)
        let d0 = TIFFISD.fromPSD(file)
        let (big, _) = try d0.toBytes(.big)
        let (little, _) = try d0.toBytes(.little)
        let (back, _) = try TIFFISD.fromBytes(little)
        let d = tiffKnown(d0)
        let a = try #require(d.layerInfo), b = try #require(back.layerInfo)
        for (la, lb) in zip(a.layers, b.layers) {
            for (ca, cb) in zip(la.channels, lb.channels) {
                #expect(ca == cb)
                let (w, h) = try la.channelRect(ca.id).size()
                #expect(try ca.decode(width: w, height: h, depth: 16, version: .psd) == cb.decode(width: w, height: h, depth: 16, version: .psd))
            }
        }
        // The encoded samples (after the count table) are identical bytes in both files, while
        // the count table itself is swapped.
        var found: (PSDLayerRecord, PSDChannel)?
        for l in a.layers where found == nil {
            for c in l.channels where c.id >= -1 && c.compression == .rle {
                if l.rect.height > 1, c.data.count > Int(l.rect.height) * 2 + 8 { found = (l, c); break }
            }
        }
        let (rec, ch) = try #require(found)
        let table = Int(rec.rect.height) * 2
        let data = [UInt8](ch.data)
        let samples = Array(data[table...])
        #expect(big.tiffContains(samples))
        #expect(little.tiffContains(samples))
        let counts = Array(data[..<table])
        var swapped: [UInt8] = []
        for i in stride(from: 0, to: counts.count, by: 2) { swapped += [counts[i + 1], counts[i]] }
        #expect(little.tiffContains(swapped + samples))
    }

    @Test func blendingRangesAreBytesInEitherOrder() throws {
        var file = TIFFTestGen.layered(.psd, .rgb, 8, .rle)
        let ranges = [UInt8](repeating: 0, count: 0) + Array([[UInt8]](repeating: [0, 0, 255, 255], count: 10).joined())
        let marked: [UInt8] = Array(1 ... 40)
        for i in file.layers.indices { file.layers[i].blendingRanges.data = i == 0 ? marked : ranges }
        let d = TIFFISD.fromPSD(file)
        let (little, _) = try d.toBytes(.little)
        // Written verbatim (what Photoshop writes in an `II` TIFF), not swapped per u32.
        #expect(little.tiffContains(marked))
        let (back, _) = try TIFFISD.fromBytes(little)
        for (a, b) in zip(d.layerInfo?.layers ?? [], back.layerInfo?.layers ?? []) { #expect(a.blendingRanges == b.blendingRanges) }
    }

    @Test func psbSizedDataUsesLongLengthsAndCounts() throws {
        let file = TIFFTestGen.layered(.psb, .cmyk, 8, .rle)
        let d = TIFFISD.fromPSD(file)
        #expect(d.version == .psb)
        let back = try tiffRoundtrip(d)
        // photocraft compares the layer info as is; its padding follows the body length, which
        // depends on the generator, so the padding is normalised here.
        var a = back.layerInfo, b = d.layerInfo
        a?.padding = nil
        b?.padding = nil
        #expect(a == b)
        let (little, _) = try d.toBytes(.little)
        #expect(Array(little[36 ..< 40]) == Array("MIB8".utf8))
        let (back2, _) = try TIFFISD.fromBytes(little)
        #expect(tiffKnown(back2).layerInfo == tiffKnown(d).layerInfo)
    }

    @Test func resourcesBothOrders() throws {
        let res = [
            PSDImageResource(id: 1005, data: Data([0, 72, 0, 0, 0, 1, 0, 1, 0, 72, 0, 0, 0, 1, 0, 1])),
            PSDImageResource(id: 1037, data: Data([0, 0, 0, 120])),
            PSDImageResource(id: 1039, data: Data([1, 2, 3])),
            PSDImageResource(id: 1026, data: Data([0, 1, 0, 1, 0, 0]), name: Array("grp".utf8)),
        ]
        let big = try PSDTIFF.resourcesToBytes(res)
        let (back, w) = try PSDTIFF.resourcesFromBytes(big)
        #expect(w.isEmpty)
        #expect(back == res)
        let (little, w2) = try PSDTIFF.Transcode.transcodeResources(big, .big, .little)
        #expect(w2.isEmpty)
        #expect(Array(little.prefix(4)) == Array("MIB8".utf8))
        #expect(little.count == big.count)
        #expect(Array(little[4 ..< 6]) == [0xED, 3])
        let (back2, w3) = try PSDTIFF.resourcesFromBytes(little)
        #expect(w3.isEmpty)
        #expect(back2 == res)
        // The ICC blob is untouched by the swap.
        #expect(little.tiffContains([1, 2, 3]))
        // An odd trailing pad byte is tolerated.
        #expect(try PSDTIFF.resourcesFromBytes(big + [0]).resources == res)
    }

    @Test func malformedInputErrorsWithoutTrapping() throws {
        #expect(throws: (any Error).self) { try TIFFISD.fromBytes([]) }
        #expect(throws: (any Error).self) { try TIFFISD.fromBytes(Array("Adobe Photoshop Document Data Block".utf8)) }
        #expect(throws: (any Error).self) { try TIFFISD.fromBytes(PSDTIFF.signature + Array("XXXXLayr".utf8)) }
        let d = tiffSampleLayers()
        for order in PSDTIFF.ByteOrder.allCases {
            let (bytes, _) = try d.toBytes(order)
            for cut in Array(stride(from: 0, to: bytes.count, by: 7)) + Array(max(0, bytes.count - 8) ..< bytes.count) {
                _ = try? TIFFISD.fromBytes(Array(bytes[..<cut]))
            }
            // Bit flips in the structure (not the signature).
            for i in stride(from: 36, to: bytes.count, by: 13) {
                var b = bytes
                b[i] ^= 0x5A
                _ = try? TIFFISD.fromBytes(b)
            }
        }
        // A block that claims more data than exists.
        var huge = PSDTIFF.signature
        huge += Array("8BIMluni".utf8)
        huge += [0xFF, 0xFF, 0xFF, 0xFF]
        #expect(throws: (any Error).self) { try TIFFISD.fromBytes(huge) }
        #expect(throws: (any Error).self) { try PSDTIFF.resourcesFromBytes(Array("8BIM".utf8) + [0x03, 0xED, 0x00]) }
    }

    @Test func intoPSDRoundtripsThroughThePSDWriter() throws {
        let file = TIFFTestGen.layered(.psd, .grayscale, 8, .zip)
        let d = TIFFISD.fromPSD(file)
        let (little, _) = try d.toBytes(.little)
        let (back, _) = try TIFFISD.fromBytes(little)
        let psd = back.intoPSD(header: file.header, resources: file.resources, imageData: file.imageData)
        let again = try PSDFile(data: try psd.serialized())
        let expected = tiffKnown(TIFFISD.fromPSD(file))
        #expect(tiffKnown(TIFFISD.fromPSD(again)).layerInfo == expected.layerInfo)
        #expect(again.globalBlocks == expected.globalBlocks)
        #expect(again.layerTree().count == file.layerTree().count)
    }
}
