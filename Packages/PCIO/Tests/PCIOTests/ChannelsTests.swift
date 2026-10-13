// Port of photocraft-io (crates/io/tests/channels.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Alpha / spot channels, channel options and the Quick Mask through PSD (both record shapes).

import Foundation
import PCDocument
import PCFoundation
import PCPSD
import Testing
@testable import PCIO

@Suite struct ChannelsTests {
    init() { ExportSweep.install() }
    static func channel(_ depth: SampleType, _ x1: Int32) -> Surface {
        var s = Surface(format: PixelFormat(mode: .grayscale, sample: depth, alpha: false))
        s.fill(rect(0, 0, x1, 8), with: [1])
        return s
    }

    @Test(arguments: PSDKit.conventions) func channelOptionsSpotAndQuickMaskRoundtrip(_ photoshop: Bool) throws {
        for depth in SampleType.allCases {
            var d = Document.withBackground(name: "c", size: PixelSize(width: 16, height: 8), mode: .rgb, depth: depth, fill: .white)
            var a = AlphaChannel(name: "Alpha 1", surface: ChannelsTests.channel(depth, 4))
            a.color = .rgb(0, 0, 1)
            a.opacity = 0.7
            a.indicates = .selectedAreas
            d.channels.append(a)
            var spot = AlphaChannel(name: "PANTONE X", surface: ChannelsTests.channel(depth, 8))
            spot.spot = SpotInk(color: .rgb(1, 0, 1), solidity: 0.25)
            d.channels.append(spot)
            d.quickMask = AlphaChannel(name: "Quick Mask", surface: ChannelsTests.channel(depth, 12))
            let (back, warnings) = try PSDKit.psdToDocument(PSDKit.documentToPSD(d, photoshop: photoshop))
            #expect(warnings.isEmpty, "\(warnings)")
            #expect(back.channels.count == 2, "\(depth)")
            guard back.channels.count == 2 else { continue }
            let (x, s) = (back.channels[0], back.channels[1])
            #expect(x.name == "Alpha 1" && x.color == .rgb(0, 0, 1) && x.indicates == .selectedAreas, "\(x.name) \(x.color) \(x.indicates)")
            #expect(abs(x.opacity - 0.7) < 1e-6)
            #expect(x.surface.pixel(x: 2, y: 2)[0] == 1)
            #expect(x.surface.pixel(x: 6, y: 2)[0] == 0)
            #expect(s.name == "PANTONE X")
            #expect(s.spot == SpotInk(color: .rgb(1, 0, 1), solidity: 0.25))
            let q = try #require(back.quickMask, "quick mask restored")
            #expect(q.surface.pixel(x: 10, y: 2)[0] == 1)
            #expect(q.surface.pixel(x: 14, y: 2)[0] == 0)
            // Re-exporting doesn't duplicate the display-info resources.
            let f2 = PSDKit.documentToPSD(back, photoshop: photoshop)
            #expect(f2.resources.filter { $0.id == 1077 }.count == 1)
            #expect(f2.resources.filter { $0.id == 1022 }.count == 1)
        }
    }

    @Test(arguments: PSDKit.conventions) func aFullChannelListDropsTheQuickMask(_ photoshop: Bool) throws {
        var full = Document.withBackground(name: "full", size: PixelSize(width: 1, height: 1), mode: .rgb, depth: .u8, fill: .white)
        full.channels = (0 ..< 53).map { AlphaChannel(name: "Alpha \($0)", surface: Surface(format: .gray8)) }
        full.quickMask = AlphaChannel(name: "Quick Mask", surface: Surface(format: .gray8))
        let out = try PSDKit.export(full, "full.psd", PSDKit.options(photoshop))
        #expect(out.warnings.contains { $0.contains("Quick Mask") }, "\(out.warnings)")
        let file = try PSDFile(bytes: out.bytes)
        #expect(file.header.channels == 56)
        #expect(file.resources.allSatisfy { $0.id != 1022 })
    }
}
