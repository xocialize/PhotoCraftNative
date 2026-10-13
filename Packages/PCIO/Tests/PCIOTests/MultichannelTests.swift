// Port of photocraft-io (crates/io/tests/multichannel.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Multichannel PSDs: alpha-type channels and the document's resources and global blocks survive an
// import → export → import round trip (saved in both record shapes).
//
// Not ported: `corpus_multichannel_round_trip_keeps_channels_and_resources` (photocraft's external
// psd-tools `4x4_16bit_multichannel.psd`; the PCPSD_CORPUS files are all RGB).

import Foundation
import PCDocument
import PCFoundation
import PCPSD
import Testing
@testable import PCIO

@Suite struct MultichannelTests {
    init() { ExportSweep.install() }
    /// DisplayInfo (1077) record: RGB colour, opacity (0...100) and kind (0/1 alpha, 2 spot).
    static func displayRecord(_ out: inout [UInt8], _ rgb: [UInt16], _ opacity: UInt16, _ kind: UInt8) {
        out += [0, 0]
        for v in rgb + [0] { out += [UInt8(v >> 8), UInt8(v & 0xFF)] }
        out += [UInt8(opacity >> 8), UInt8(opacity & 0xFF), kind]
    }

    /// A two-channel Multichannel file: a cyan spot ink and an alpha channel (masked areas, red 50 %).
    static func file(_ depth: UInt16) throws -> PSDFile {
        var f = try PSDKit.mergedOnly(.psd, .multichannel, depth, .rle, 9, 5)
        var info: [UInt8] = [0, 0, 0, 1]
        displayRecord(&info, [0, 65535, 65535], 0, 2)
        displayRecord(&info, [65535, 0, 0], 50, 1)
        f.resources.append(PSDImageResource(id: 1077, data: Data(info)))
        return f
    }

    static func roundtrip(_ d: Document, _ photoshop: Bool) throws -> (PSDFile, Document) {
        let out = try PSDKit.export(d, "x.psd", PSDKit.options(photoshop))
        let back = try PSDFile(bytes: out.bytes)
        return (back, try PSDKit.psdToDocument(back).document)
    }

    @Test(arguments: PSDKit.conventions) func alphaTypeChannelsImportAsAlphaAndRoundTrip(_ photoshop: Bool) throws {
        for depth: UInt16 in [8, 16] {
            let f = try MultichannelTests.file(depth)
            let (d, _) = try PSDKit.psdToDocument(f)
            #expect(d.channels.count == 2)
            guard d.channels.count == 2 else { return }
            #expect(d.channels[0].spot?.color.rgb == SIMD3(0, 1, 1))
            let a = d.channels[1]
            #expect(a.spot == nil, "an alpha-type channel is not a spot ink (\(depth)-bit)")
            #expect(a.color.rgb == SIMD3(1, 0, 0))
            #expect(abs(a.opacity - 0.5) < 1e-6)
            #expect(a.indicates == .maskedAreas)

            // It still prints as black ink, so the composite is what a black spot channel gives.
            var asInk = d
            asInk.channels[1].spot = SpotInk(color: .black, solidity: 0)
            #expect(try PSDKit.flatten(d) == PSDKit.flatten(asInk))

            // Saved back unchanged: same DisplayInfo, same planes, same channels on reopening.
            let (back, d2) = try MultichannelTests.roundtrip(d, photoshop)
            #expect(back.resource(1077)?.data == f.resource(1077)?.data)
            #expect(try back.decodeMerged() == f.decodeMerged())
            guard d2.channels.count == 2 else { Issue.record("channels \(d2.channels.count)"); return }
            #expect(d2.channels[1].spot == nil)
            #expect(d2.channels[1].indicates == .maskedAreas)
            #expect(abs(d2.channels[1].opacity - 0.5) < 1e-6)
            #expect(d2.channels[0].spot != nil)
        }
    }

    @Test(arguments: PSDKit.conventions) func resourcesAndGlobalBlocksSurviveASave(_ photoshop: Bool) throws {
        var f = try MultichannelTests.file(8)
        let iptc: [UInt8] = [0x1C, 2, 0, 0, 2, 0, 4]
        let printFlags: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 1, 0]
        let seed: [UInt8] = [0, 0, 0, 7]
        let alphaIds: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 1]
        f.resources.append(PSDImageResource(id: 1028, data: Data(iptc)))
        f.resources.append(PSDImageResource(id: 1011, data: Data(printFlags)))
        f.resources.append(PSDImageResource(id: 1044, data: Data(seed)))
        f.resources.append(PSDImageResource(id: 1053, data: Data(alphaIds)))
        // A target-layer index describes layers, which a Multichannel document doesn't have.
        f.resources.append(PSDImageResource(id: 1024, data: Data([0, 0])))
        // Photoshop's shape: a 10-byte colour space, then the opacity (u16).
        let fmsk: [UInt8] = [0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 50]
        f.globalBlocks.append(PSDTaggedBlock(key: "FMsk", bytes: fmsk))
        var (d, _) = try PSDKit.psdToDocument(f)
        d.guides.horizontal.append(2)
        d.guides.vertical.append(3)
        d.globalLight.angle = 60
        let path = VectorPath([Subpath(closed: true, knots: [.corner(1, 1), .corner(8, 1), .corner(4, 4)], op: .combine)])
        d.paths.append(NamedPath(name: "Outline", path: path, psdRaw: nil))

        let (back, d2) = try MultichannelTests.roundtrip(d, photoshop)
        func res(_ id: UInt16) -> [UInt8]? { back.resource(id).map { [UInt8]($0.data) } }
        #expect(res(1028) == iptc)
        #expect(res(1011) == printFlags)
        #expect(res(1044) == seed)
        #expect(res(1053) == alphaIds)
        #expect(res(1024) == nil)
        let blocks = back.globalBlocks.filter { $0.key == "FMsk" }
        #expect(blocks.count == 1)
        #expect(blocks.first.map { [UInt8]($0.data) } == fmsk)
        #expect(d2.guides.horizontal == [2])
        #expect(d2.guides.vertical == [3])
        #expect(d2.globalLight.angle == 60)
        // The file's own saved path and the new one.
        #expect(d2.paths.map(\.name) == ["Path 1", "Outline"])
        func anchors(_ p: VectorPath) -> [PCPoint] { p.subpaths.flatMap { $0.knots.map(\.anchor) } }
        if let got = d2.paths.last.map({ anchors($0.path) }) {
            let want = anchors(path)
            #expect(got.count == want.count)
            #expect(zip(got, want).allSatisfy { abs($0.x - $1.x) < 1e-3 && abs($0.y - $1.y) < 1e-3 }, "\(got)")
        }
        #expect(try back.decodeMerged() == f.decodeMerged())

        // Alpha identifiers that no longer match the channels are not written.
        d.channels.removeLast()
        let (back2, _) = try MultichannelTests.roundtrip(d, photoshop)
        #expect(back2.resource(1053) == nil)
    }
}
