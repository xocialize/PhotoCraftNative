// Round-trip and byte-stability tests over generated files.
// Port of photocraft-psd (crates/psd/tests/roundtrip.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import Foundation
import Testing
@testable import PCPSD

func assertStable(_ file: PSDFile, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let bytes = try file.serialized()
    let parsed = try PSDFile(data: bytes)
    #expect(parsed == file, "\(name): model round trip", sourceLocation: sourceLocation)
    #expect(try parsed.serialized() == bytes, "\(name): byte stability", sourceLocation: sourceLocation)
}

@Suite struct RoundTripTests {
    @Test func allGeneratedCasesRoundTrip() throws {
        let cases = TestGen.allCases()
        #expect(cases.count > 100)
        for c in cases { try assertStable(c.file, c.name) }
    }

    @Test func allGeneratedChannelsDecode() throws {
        for c in TestGen.allCases() {
            let f = c.file
            let merged = try f.decodeMerged()
            #expect(merged.count == f.header.rowBytes * Int(f.header.height) * Int(f.header.channels), "\(c.name)")
            for layer in f.layers {
                for ch in layer.channels {
                    _ = try layer.decodeChannel(ch.id, depth: f.header.depth, version: f.header.version)
                }
            }
        }
    }

    @Test func mergedOnlyDecodesToPattern() throws {
        for mode in TestGen.modes {
            for depth in TestGen.modeDepths(mode) {
                for c in PSDCompression.all {
                    let f = TestGen.mergedOnly(.psd, mode, depth, c, 9, 5)
                    var expect: [UInt8] = []
                    for ch in 0 ..< TestGen.modeChannels(mode) { expect += TestGen.patternPlane(9, 5, depth, UInt32(ch)) }
                    #expect(try f.decodeMerged() == expect, "\(mode) \(depth) \(c)")
                }
            }
        }
    }

    @Test(arguments: [
        (PSDVersion.psd, PSDColorMode.rgb, UInt16(8)), (.psd, .rgb, 16), (.psd, .rgb, 32), (.psb, .rgb, 8), (.psb, .rgb, 16), (.psb, .rgb, 32),
        (.psd, .grayscale, 8), (.psd, .grayscale, 16), (.psd, .grayscale, 32), (.psd, .cmyk, 8), (.psd, .cmyk, 16), (.psb, .cmyk, 8),
        (.psd, .lab, 8), (.psb, .lab, 16),
    ])
    func layeredCases(version: PSDVersion, mode: PSDColorMode, depth: UInt16) throws {
        for c in PSDCompression.all {
            let f = TestGen.layered(version, mode, depth, c)
            try assertStable(f, "layered \(version) \(mode) \(depth) \(c)")
            #expect(f.layers.count > 30)
            if case .globalBlock = f.layerInfoPlacement { #expect(depth != 8) } else { #expect(depth == 8) }
        }
    }

    @Test func mergedCases() throws {
        for mode in TestGen.modes {
            for depth in TestGen.modeDepths(mode) {
                for v in PSDVersion.allCases {
                    for c in PSDCompression.all {
                        let f = TestGen.mergedOnly(v, mode, depth, c, 31, 3)
                        try assertStable(f, "merged \(mode) \(depth)")
                        #expect(f.layerInfo == nil)
                    }
                }
            }
        }
    }

    @Test func psbUsesLongSectionLengths() throws {
        let psd = try TestGen.small(.psd, .raw).serialized()
        let psb = try TestGen.small(.psb, .raw).serialized()
        let nch = TestGen.small(.psd, .raw).layers.reduce(0) { $0 + $1.channels.count }
        #expect(psb.count == psd.count + 8 + nch * 4)
        #expect(psb[psb.startIndex + 5] == 2)
    }

    @Test func psbRLECountsAreU32() {
        let psd = TestGen.mergedOnly(.psd, .grayscale, 8, .rle, 5, 4)
        let psb = TestGen.mergedOnly(.psb, .grayscale, 8, .rle, 5, 4)
        #expect(psb.imageData.data.count == psd.imageData.data.count + 4 * 2)
    }

    @Test func psbLongKeyGlobalBlock() throws {
        var f = TestGen.small(.psb, .rle)
        f.globalBlocks.append(PSDTaggedBlock(key: "FMsk", bytes: [1, 2, 3, 4]))
        f.globalBlocks.append(PSDTaggedBlock(key: "Alph", bytes: [5, 6]))
        let b = try f.serialized()
        #expect(try PSDFile(data: b) == f)
        var asPSD = [UInt8](b)
        asPSD[5] = 1
        if let q = try? PSDFile(bytes: asPSD) { #expect(q != f) }
    }

    @Test func editsAreReencoded() throws {
        var f = TestGen.small(.psd, .rle)
        let v = f.header.version
        var layers = f.layers
        let (w, h) = try layers[0].rect.size()
        let new = [UInt8](repeating: 7, count: w * h)
        let i = layers[0].channels.firstIndex { $0.id == 0 }!
        try layers[0].channels[i].setDecoded(new, compression: .zipPrediction, width: w, height: h, depth: 8, version: v)
        f.layers = layers
        let p = try PSDFile(data: try f.serialized())
        #expect(try p.layers[0].decodeChannel(0, depth: 8, version: v) == new)
        #expect(p.layers[0].channel(0)?.compression == .zipPrediction)
    }

    @Test func renamingChangesLuniAndRoundTrips() throws {
        var f = TestGen.small(.psd, .raw)
        f.layers[0].setBlock(.unicodeName("Renamed \u{263A}"))
        let p = try PSDFile(data: try f.serialized())
        #expect(p.layers[0].displayName == "Renamed \u{263A}")
    }

    @Test func unknownBlocksAndResourcesPassThrough() throws {
        var f = TestGen.small(.psd, .rle)
        f.resources.append(PSDImageResource(id: 9999, data: Data([1, 2, 3, 4, 5])))
        f.globalBlocks.append(PSDTaggedBlock(key: "Q3Dx", bytes: (0 ... 255).map { UInt8($0) }))
        f.layers[0].blocks.append(PSDTaggedBlock(key: "Vid!", bytes: [UInt8](repeating: 0xAB, count: 7)))
        f.layers[0].blendMode = .unknown("new!")
        try assertStable(f, "unknown passthrough")
        let p = try PSDFile(data: try f.serialized())
        #expect(p.layers[0].blendMode == .unknown("new!"))
        #expect(p.globalBlock("Q3Dx")?.data.count == 256)
    }

    @Test func unknownColorModePassThrough() throws {
        var f = TestGen.mergedOnly(.psd, .grayscale, 8, .raw, 2, 2)
        f.header.colorMode = .unknown(5)
        try assertStable(f, "unknown mode")
    }

    @Test func unknownCompressionPassThrough() throws {
        var f = TestGen.small(.psd, .raw)
        f.layers[0].channels[0].compression = .unknown(9)
        try assertStable(f, "unknown channel compression")
        #expect(throws: PSDError.self) { try f.layers[0].decodeChannel(f.layers[0].channels[0].id, depth: 8, version: .psd) }
    }

    @Test func trailingSectionBytesPreserved() throws {
        var f = TestGen.small(.psd, .raw)
        f.layerMaskTrailing = [0, 0, 0, 0, 0, 0]
        try assertStable(f, "layer mask trailing")
        f.layers[1].extraTrailing = [0, 0, 0, 0, 0]
        try assertStable(f, "record trailing")
        f.layerInfo?.padding = [0, 0, 0, 0]
        f.layers[1].extraTrailing = []
        try assertStable(f, "layer info padding")
    }

    @Test func globalMaskAccessors() {
        let f = TestGen.layered(.psd, .rgb, 8, .raw)
        let gm = f.globalLayerMask!
        #expect(gm.overlayColorSpace == 0)
        #expect(gm.colorComponents == [0xFFFF, 0, 0, 0])
        #expect(gm.opacity == 50)
        #expect(gm.kind == 128)
        #expect(PSDGlobalLayerMask().kind == nil)
    }

    @Test func fileAccessors() throws {
        let f = TestGen.layered(.psd, .rgb, 8, .rle)
        #expect(abs(f.resolution!.hRes - 72) < 1e-9)
        #expect(f.iccProfile?.count == 13)
        #expect(f.hasRealMergedData == true)
        #expect(f.mergedHasAlpha)
        try f.validate()
        let lfx = f.layers.compactMap { $0.block("lfx2") }.first!
        let d = try PSDVersionedDescriptor(bytes: lfx.data.dropFirst(4))
        #expect(d == TestGen.sampleDescriptor())
    }

    @Test func validateRejectsBadModels() throws {
        var f = TestGen.mergedOnly(.psd, .indexed, 8, .raw, 2, 2)
        try f.validate()
        f.colorModeData = f.colorModeData.dropLast()
        #expect(throws: PSDError.self) { try f.validate() }
        var g = TestGen.mergedOnly(.psd, .rgb, 8, .raw, 2, 2)
        g.header.width = 40000
        #expect(throws: PSDError.self) { try g.validate() }
        g.header.version = .psb
        try g.validate()
    }

    @Test func rleRowsOver65535RejectedForPSDOnly() throws {
        let row = (0 ..< 70000).map { UInt8($0 % 251) }
        #expect(throws: PSDError.self) { try PlaneCodec.encode(.rle, row, layout: PlaneLayout(planes: 1, width: 70000, height: 1, depth: 8, version: .psd)) }
        _ = try PlaneCodec.encode(.rle, row, layout: PlaneLayout(planes: 1, width: 70000, height: 1, depth: 8, version: .psb))
    }

    @Test func saveAndOpen() throws {
        let f = TestGen.small(.psd, .rle)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pcpsd-test-\(UUID().uuidString).psd")
        defer { try? FileManager.default.removeItem(at: url) }
        try f.write(to: url)
        #expect(try PSDFile(contentsOf: url) == f)
        #expect(try Data(contentsOf: url) == f.serialized())
    }

    /// A density-only mask record in the spec's order must survive as a model (photocraft #949).
    @Test func specOrderDensityOnlyMaskRoundTripsAsModel() throws {
        var f = TestGen.small(.psd, .raw)
        f.layers[0].mask = .mask(PSDLayerMask(rect: PSDRect(x: 0, y: 0, width: 1, height: 1), defaultColor: 255, flags: PSDLayerMask.flagParameters,
                                              parameters: PSDMaskParameters(flags: 1, userDensity: 64),
                                              real: PSDRealMask(flags: 0, background: 0, rect: PSDRect(x: 0, y: 0, width: 1, height: 1)),
                                              trailing: [], realFirst: false))
        let i = f.layers[0].channels.firstIndex { $0.id == -2 }!
        f.layers[0].channels[i] = try PSDChannel.encode(id: -2, compression: .raw, decoded: [64], width: 1, height: 1, depth: 8, version: .psd)
        let b = try f.serialized()
        let g = try PSDFile(data: b)
        #expect(g == f)
        #expect(try g.layers[0].decodeChannel(-2, depth: 8, version: .psd) == [64])
        #expect(try g.serialized() == b)
    }

    // From photocraft file.rs write_tests.

    @Test func globalBlocksDefaultToFourBytePadding() throws {
        for version in PSDVersion.allCases {
            for len in 1 ..< 8 {
                var file = TestGen.small(version, .raw)
                file.globalBlocks = [PSDTaggedBlock(key: "TEST", bytes: [UInt8](repeating: 7, count: len)), PSDTaggedBlock(key: "NEXT", bytes: [8, 8, 8, 8])]
                let bytes = [UInt8](try file.serialized())
                let start = find(bytes, Array("8BIMTEST".utf8))! + 12
                let next = find(bytes, Array("8BIMNEXT".utf8))!
                #expect(next - start == (len + 3) / 4 * 4)
                #expect(try PSDFile(bytes: bytes) == file)
            }
        }
    }

    @Test func streamedLayerInfoEqualsMaterializedBlock() throws {
        for version in PSDVersion.allCases {
            for key: FourCC in ["Lr16", "Lr32", "Layr"] {
                for index in [0, 1, 2, Int.max] {
                    for padding: [UInt8]? in [nil, [], [42], [1, 2, 3]] {
                        var file = TestGen.small(version, .raw)
                        file.globalBlocks = [PSDTaggedBlock(key: "zz01", bytes: [11]), PSDTaggedBlock(key: "zz02", bytes: [12, 13])]
                        file.layerInfoPlacement = .globalBlock(index: index, signature: "8B64", key: key, padding: padding, longLengthOverride: nil)
                        file.layerInfo?.padding = [77]
                        let actual = try file.serialized()
                        var materialized = file
                        let data = try materialized.layerInfo!.bodyBytes(version)
                        materialized.layerInfo = nil
                        var block = PSDTaggedBlock(key: key, data: data, signature: "8B64")
                        block.padding = padding
                        materialized.globalBlocks.insert(block, at: min(index, materialized.globalBlocks.count))
                        materialized.layerInfoPlacement = .section
                        #expect(actual == (try materialized.serialized()), "\(version) \(key) \(index)")
                    }
                }
            }
        }
    }

    @Test func overBudgetZipMergedImageOpensWithoutInflating() throws {
        var bytes = [UInt8](try TestGen.small(.psb, .zip).serialized())
        for (at, v) in [(14, UInt32(300_000)), (18, UInt32(300_000))] {
            bytes[at] = UInt8(v >> 24); bytes[at + 1] = UInt8(v >> 16 & 0xFF); bytes[at + 2] = UInt8(v >> 8 & 0xFF); bytes[at + 3] = UInt8(v & 0xFF)
        }
        let file = try PSDFile(bytes: bytes)
        #expect(!file.layers.isEmpty)
        #expect(throws: PSDError.self) { try file.decodeMerged() }
    }

    @Test func globalLayerInfoSerializationPropagatesLayerLimit() throws {
        var file = TestGen.small(.psd, .raw)
        file.layerInfo = PSDLayerInfo(layers: [PSDLayerRecord](repeating: PSDLayerRecord(), count: 32768))
        file.layerInfoPlacement = .globalBlock(index: Int.max, signature: "8BIM", key: "Lr16", padding: nil, longLengthOverride: nil)
        #expect(throws: PSDError.self) { try file.serialized() }
    }

    @Test func globalLayersPreserveOrderPaddingAndFirstCandidate() throws {
        for version in PSDVersion.allCases {
            for depth: UInt16 in [16, 32] {
                var file = TestGen.layered(version, .rgb, depth, .raw)
                let key: FourCC = depth == 16 ? "Lr16" : "Lr32"
                file.globalBlocks = [PSDTaggedBlock(key: "BEFR", bytes: [1]), PSDTaggedBlock(key: "AFTR", bytes: [2, 3])]
                file.layerInfoPlacement = .globalBlock(index: 1, signature: "8B64", key: key, padding: [7, 8], longLengthOverride: nil)
                file.layerMaskTrailing = [9, 9, 9, 9]
                let bytes = try file.serialized()
                let parsed = try PSDFile(data: bytes)
                #expect(parsed == file)
                #expect(try parsed.serialized() == bytes)
                let duplicate = try file.layerInfo!.bodyBytes(version)
                file.globalBlocks.append(PSDTaggedBlock(key: key, data: duplicate))
                #expect(try PSDFile(data: try file.serialized()) == file)
                file.globalBlocks.insert(PSDTaggedBlock(key: key, bytes: [255]), at: 0)
                let bytes2 = try file.serialized()
                let parsed2 = try PSDFile(data: bytes2)
                #expect(parsed2.layerInfo == nil)
                #expect(parsed2.globalBlocks.count == 5)
                #expect(try parsed2.serialized() == bytes2)
                #expect(parsed2.unreadableLayerBlock() != nil)
            }
        }
    }

    /// photocraft tests/layer_block_order.rs: the global layer block keeps its position and its
    /// opaque neighbours.
    @Test func globalLayerBlockRoundTripsWithOpaqueNeighbours() throws {
        for version in PSDVersion.allCases {
            for depth: UInt16 in [16, 32] {
                for index in 0 ... 2 {
                    for signature: FourCC in ["8BIM", "8B64"] {
                        var file = TestGen.layered(version, .rgb, depth, .raw)
                        file.globalBlocks = [PSDTaggedBlock(key: "zz01", bytes: [7, 8, 9]), PSDTaggedBlock(key: "zz02", bytes: [10, 11])]
                        file.layerInfoPlacement = .globalBlock(index: index, signature: signature, key: depth == 16 ? "Lr16" : "Lr32",
                                                               padding: [31, 32, 33], longLengthOverride: nil)
                        let bytes = try file.serialized()
                        let parsed = try PSDFile(data: bytes)
                        #expect(parsed == file, "\(version) \(depth) \(index) \(signature)")
                        #expect(try parsed.serialized() == bytes)
                    }
                }
            }
        }
    }
}

func find(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
    guard needle.count <= hay.count else { return nil }
    for i in 0 ... hay.count - needle.count where hay[i ..< i + needle.count].elementsEqual(needle) { return i }
    return nil
}
