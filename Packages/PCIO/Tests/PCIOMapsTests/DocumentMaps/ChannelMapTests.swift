// Tests for ChannelMap. Port of photocraft-io (crates/io/src/channel_map.rs `#[cfg(test)]`), MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
@testable import PCIOMaps
import Testing

@Suite struct ChannelMapTests {
    static func channel(_ name: String) -> AlphaChannel { AlphaChannel(name: name, surface: Surface(format: .gray8)) }

    @Test func displayInfoRoundtrip() {
        var a = Self.channel("A")
        a.color = .rgb(0, 1, 0)
        a.opacity = 0.3
        a.indicates = .selectedAreas
        var s = Self.channel("S")
        s.spot = SpotInk(color: .rgb(1, 0, 1), solidity: 0.8)
        let bytes = ChannelMap.displayInfo([a, s], false)
        // 13 bytes per channel, as every corpus file (Photoshop's included) lays out 1077.
        #expect(bytes.count == 4 + 2 * 13)
        var back = [Self.channel("A"), Self.channel("S")]
        ChannelMap.applyDisplayInfo(bytes, true, 0, &back)
        #expect(back[0].color == a.color)
        #expect(abs(back[0].opacity - 0.3) < 1e-6)
        #expect(back[0].indicates == .selectedAreas)
        #expect(back[1].spot == s.spot)
        // With the merged transparency's record first, the channels still get their own.
        let withT = ChannelMap.displayInfo([a, s], true)
        #expect(withT.count == 4 + 3 * 13)
        back = [Self.channel("A"), Self.channel("S")]
        ChannelMap.applyDisplayInfo(withT, true, 1, &back)
        #expect(back[0].indicates == .selectedAreas)
        #expect(back[1].spot == s.spot)
        // Truncated data is ignored rather than misread.
        var c = [Self.channel("x")]
        ChannelMap.applyDisplayInfo(Array(bytes[..<10]), true, 0, &c)
        #expect(c[0].opacity == 0.5)
        // The older 14-byte layout (1007) without a version.
        var old: [UInt8] = []
        for r in stride(from: 4, to: bytes.count, by: 13) { old += bytes[r ..< r + 13] + [0] }
        back = [Self.channel("A"), Self.channel("S")]
        ChannelMap.applyDisplayInfo(old, false, 0, &back)
        #expect(back[0].color == a.color && back[1].spot == s.spot)
        #expect(ChannelMap.displayInfo == 1077 && ChannelMap.displayInfoOld == 1007 && ChannelMap.quickMaskInfo == 1022)
    }

    @Test func decodesOtherSpaces() {
        let g = ChannelMap.decodeColor(8, [10000, 0, 0, 0])
        #expect(g.rgb == SIMD3(repeating: 0))
        let lab = ChannelMap.decodeColor(7, [10000, 0, 0, 0]).rgb
        #expect(lab.x > 0.95 && lab.y > 0.95 && lab.z > 0.95, "\(lab)")
        // HSB: hue 120 degrees (65535 / 3), full saturation and brightness is pure green.
        let green = ChannelMap.decodeColor(1, [21845, 65535, 65535, 0]).rgb
        #expect(abs(green.x) < 1e-3 && abs(green.y - 1) < 1e-3 && abs(green.z) < 1e-3, "\(green)")
        let half = ChannelMap.decodeColor(1, [0, 0, 32768, 0]).rgb
        #expect(abs(half.x - 0.5) < 1e-3 && abs(half.y - 0.5) < 1e-3 && abs(half.z - 0.5) < 1e-3, "\(half)")
        // Unknown spaces (book colours) are not guessed.
        #expect(ChannelMap.decodeKnownColor(3, [1, 2, 3, 4]) == nil)
        #expect(ChannelMap.decodeKnownColor(0, [65535, 0, 0, 0]) == .rgb(1, 0, 0))
        // decodeColor reads unknown spaces as RGB; short component lists read as zero.
        #expect(ChannelMap.decodeColor(3, [65535, 0, 65535, 9]) == .rgb(1, 0, 1))
        #expect(ChannelMap.decodeColor(0, [65535]) == .rgb(1, 0, 0))
        // Non-finite hues fall back to red's sector.
        #expect(ChannelMap.hsbToRGB(.nan, 1, 1) == SIMD3(1, 0, 0))
    }
}
