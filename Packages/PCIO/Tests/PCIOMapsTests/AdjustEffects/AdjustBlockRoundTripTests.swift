// Block-level parts of photocraft's adjustment integration tests: every adjustment kind through
// `write` → `parse` (the exporter's keep-or-regenerate rule), the unreadable-adjustment reasons the
// importer warns with, and Gradient Map stops in CMYK / Lab / Gray documents.
// Port of photocraft-io (crates/io/tests/adjust_blend_roundtrip.rs, adjust_warnings.rs, color.rs:
// the parts that need only adjust_map), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import Testing
@testable import PCIOMaps

private typealias A = Adjustment

private func g8(_ v: UInt8) -> Float { Float(v) / 255 }
private func q16(_ v: UInt16) -> Float { Float(v) / 65535 }

private func kindName(_ a: Adjustment) -> String { a.label }

/// Every `Adjustment` kind with representative settings, and whether its PSD encoding is lossless
/// (the document model comes back equal) or only renders the same (adjust_blend_roundtrip.rs).
private func adjustments() -> [(Adjustment, Bool)] {
    func pts(_ v: [(UInt8, UInt8)]) -> [CurvePoint] { v.map { CurvePoint(input: g8($0.0), output: g8($0.1)) } }
    func lc(_ a: UInt8, _ b: UInt8, _ gamma: Float) -> LevelsChannel {
        LevelsChannel(inBlack: g8(a), inWhite: g8(b), gamma: gamma, outBlack: g8(5), outWhite: g8(250))
    }
    let lut = AdjustMap.LutFile.fromFn("t", 5) { c in SIMD3(c.y, c.z * 0.5, 1 - c.x) }
    return [
        (.brightnessContrast(A.BrightnessContrast(brightness: 30, contrast: -20, legacy: false)), true),
        (.brightnessContrast(A.BrightnessContrast(brightness: -40, contrast: 50, legacy: true)), true),
        (.brightnessContrast(A.BrightnessContrast(brightness: 25, contrast: 35, mode: .modern)), true),
        (.brightnessContrast(A.BrightnessContrast(contrast: 35, mode: .light, exposure: 0.5, whites: 10, blacks: -5, highlights: 20, shadows: -15)), true),
        (.levels(A.Levels(master: lc(10, 240, 1.2), perChannel: [lc(0, 255, 1), lc(5, 250, 0.8), lc(20, 200, 1.5)], space: .rgb, black: LevelsChannel())), true),
        (.curves(A.Curves(master: pts([(0, 0), (128, 150), (255, 255)]),
                          perChannel: [pts([(0, 10), (255, 255)]), pts([(0, 0), (255, 245)]), pts([(0, 0), (64, 32), (255, 255)])],
                          space: .rgb, black: [], pencil: false)), true),
        (.exposure(A.Exposure(exposure: 0.75, offset: -0.0125, gamma: 0.9)), true),
        (.vibrance(A.Vibrance(vibrance: 60, saturation: -25)), true),
        (.hueSaturation(A.HueSaturation(hue: 40, saturation: -30, lightness: 10, colorize: false, ranges: HueRange.defaults)), true),
        (.hueSaturation(A.HueSaturation(hue: 200, saturation: 50, lightness: -10, colorize: true, ranges: HueRange.defaults)), true),
        (.colorBalance(A.ColorBalance(shadows: SIMD3(20, -10, 5), midtones: SIMD3(-15, 10, 30), highlights: SIMD3(0, 5, -20), preserveLuminosity: true)), true),
        (.colorBalance(A.ColorBalance(shadows: SIMD3(60, 0, 0), midtones: .zero, highlights: SIMD3(0, 0, 40), preserveLuminosity: false)), true),
        (.blackWhite(A.BlackWhite(weights: [40, 60, 40, 60, 20, 80], tint: nil)), true),
        (.blackWhite(A.BlackWhite(weights: [70, 20, 50, -10, 90, 130], tint: SIMD3(0.9, 0.7, 0.5))), true),
        (.photoFilter(A.PhotoFilter(color: SIMD3(q16(60620), q16(35455), q16(0)), density: 0.4, preserveLuminosity: true)), true),
        (.photoFilter(A.PhotoFilter(color: SIMD3(q16(0), q16(39321), q16(65535)), density: 0.3, preserveLuminosity: false)), true),
        (.channelMixer(A.ChannelMixer(matrix: [SIMD4(0.5, 0.3, 0.2, 0), SIMD4(0.1, 0.8, 0.1, 0.05), SIMD4(0, 0.2, 0.9, -0.05)], monochrome: false)), true),
        (.channelMixer(A.ChannelMixer(matrix: [SIMD4(0.4, 0.4, 0.2, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0)], monochrome: true)), true),
        (.colorLookup(A.ColorLookup(name: "Look.cube", lut: lut.data, size: 5, tetrahedral: false, dither: false)), true),
        // No table chosen: written as Photoshop writes it (an empty descriptor), read back the same.
        (.colorLookup(A.ColorLookup(name: "", lut: nil, size: 0, tetrahedral: false, dither: false)), true),
        (.invert, true),
        (.posterize(levels: 4), true),
        (.threshold(level: g8(140)), true),
        (.gradientMap(A.GradientMap(stops: [GradientMapStop(0, SIMD3(q16(6554), 0, q16(19661))), GradientMapStop(0.5, SIMD3(1, 0.2, 0)),
                                            GradientMapStop(1, SIMD3(1, 1, 0.8))], reverse: false, dither: false)), true),
        (.gradientMap(A.GradientMap(stops: [GradientMapStop(0, SIMD3(0, 0, 1)), GradientMapStop(1, SIMD3(1, 1, 0))], reverse: true, dither: false)), true),
        // Fewer than two stops: written as the equivalent two-stop gradient.
        (.gradientMap(A.GradientMap(stops: [], reverse: false, dither: false)), false),
        (.gradientMap(A.GradientMap(stops: [GradientMapStop(0.4, SIMD3(0.2, 0.6, 0.4))], reverse: false, dither: false)), false),
        (.selectiveColor(A.SelectiveColor(relative: true, adjustments: (0 ..< 9).map { SIMD4(Float($0) * 10 - 40, 5, -30, 20) })), true),
        (.selectiveColor(A.SelectiveColor(relative: false, adjustments: (0 ..< 9).map { SIMD4(0, Float($0) * 5, 0, -10) })), true),
        // A block this version cannot read (a truncated Selective Color) is kept verbatim.
        (.unsupported(psdKey: "selc", raw: [0, 1, 0, 0]), true),
    ]
}

/// A two-stop version 1 `grdm` block whose stops are the PSD colour structures `a` and `b` (color.rs).
private func grdmBlock(_ a: (UInt16, [UInt16]), _ b: (UInt16, [UInt16])) -> [UInt8] {
    var w = BEWriter()
    w.put([0, 1, 0, 0])
    w.u32(1) // name: just the terminator
    w.put([0, 0])
    w.u16(2)
    for (t, (space, c)) in [(UInt32(0), a), (4096, b)] {
        w.u32(t)
        w.u32(50)
        w.u16(space)
        for x in c { w.u16(x) }
        w.put([0, 0])
    }
    w.u16(2)
    for t: UInt32 in [0, 4096] {
        w.u32(t)
        w.u32(50)
        w.u16(255)
    }
    w.u16(2) // expansion count
    w.u16(0) // smoothness
    return w.bytes
}

@Suite struct AdjustBlockRoundTripTests {
    /// Every kind is written as exactly one adjustment block (+ `CgEd`), parses back equal when its
    /// encoding is lossless (so the exporter keeps the block), and a second generation is a fixed
    /// point.
    @Test(arguments: [AdjustMap.Channels.rgb, .gray, .cmyk, .lab])
    func everyAdjustmentKindRoundTrips(_ channels: AdjustMap.Channels) {
        for (adj, lossless) in adjustments() {
            let blocks = AdjustMap.write(adj)
            let adjBlocks = blocks.filter { AdjustMap.adjustmentKeys.contains($0.key) }
            #expect(adjBlocks.count == 1, "\(adj): adjustment blocks written")
            guard let b = adjBlocks.first else { continue }
            let cged = blocks.first { $0.key == "CgEd" }?.data
            let back = AdjustMap.parse(b.key, b.data, cged, channels)
            if channels == .rgb {
                if lossless {
                    #expect(back == adj, "\(adj)")
                } else {
                    #expect(kindName(back) == kindName(adj), "\(adj): kind")
                }
            } else if case .unsupported = adj {
                #expect(back == adj)
            } else {
                #expect(kindName(back) == kindName(adj), "\(adj) @ \(channels): kind")
            }
            // A second generation is a fixed point for the document model.
            let again = AdjustMap.write(back)
            let cged2 = again.first { $0.key == "CgEd" }?.data
            #expect(AdjustMap.parse(again[0].key, again[0].data, cged2, channels) == back, "\(adj) @ \(channels): second generation")
        }
    }

    /// Opening a file whose adjustment layer can't be read warns with the reason (#1763): the parts
    /// of adjust_warnings.rs that need only adjust_map.
    @Test func unreadableAdjustmentsHaveAReason() throws {
        // A Color Lookup whose block has an unknown version: kept verbatim, not applied.
        let profile: [UInt8] = [0, 2, 0, 0]
        #expect(AdjustMap.parse("clrL", profile, nil, .rgb) == .unsupported(psdKey: "clrL", raw: profile))
        #expect(AdjustMap.label("clrL") == "Color Lookup")
        #expect(try #require(AdjustMap.unreadableReason("clrL", profile)).contains("version 2"))
        // Another kind without a specific reason still names the adjustment.
        #expect(AdjustMap.parse("levl", [0, 9], nil, .rgb) == .unsupported(psdKey: "levl", raw: [0, 9]))
        #expect(AdjustMap.unreadableReason("levl", [0, 9]) == nil)
        #expect(AdjustMap.label("levl") == "Levels")
        #expect(AdjustMap.label("hue ") == "adjustment")
    }

    @Test func readableAdjustmentsHaveNoReason() {
        let lut: [Float] = (0 ..< 8).flatMap { i in [Float(i & 1), Float((i >> 1) & 1), Float((i >> 2) & 1)] }
        let lookup = A.colorLookup(A.ColorLookup(name: "id.cube", lut: lut, size: 2, tetrahedral: false, dither: false))
        for adj in [lookup, .invert] {
            let b = AdjustMap.write(adj)[0]
            if case .unsupported = AdjustMap.parse(b.key, b.data, nil, .rgb) { Issue.record("\(adj) became unsupported") }
            #expect(AdjustMap.unreadableReason(b.key, b.data) == nil)
        }
    }

    /// Photoshop's `clrL` has no interpolation setting: tetrahedral comes back trilinear (#1347).
    @Test func colorLookupTetrahedralComesBackTrilinear() {
        let lut = AdjustMap.LutFile.fromFn("t", 2) { $0 == SIMD3(repeating: 1) ? SIMD3(repeating: 1) : .zero }
        let adj = A.colorLookup(A.ColorLookup(name: "test.cube", lut: lut.data, size: 2, tetrahedral: true, dither: false))
        let b = AdjustMap.write(adj)[0]
        guard case let .colorLookup(back) = AdjustMap.parse(b.key, b.data, nil, .rgb) else { Issue.record("lookup lost"); return }
        #expect(!back.tetrahedral && back.size == 2 && back.lut == lut.data)
    }

    /// Gradient Maps with CMYK / Lab / Gray stops import, and Reverse/Dither edits keep the block
    /// (color.rs `gradient_maps_with_cmyk_lab_gray_stops_import_and_keep_their_space`; the CMYK
    /// stop goes through whatever CMYK converter is installed, here none: the naive formula).
    @Test func gradientMapsWithCMYKLabGrayStopsKeepTheirSpace() throws {
        let cmykStop: (UInt16, [UInt16]) = (2, [65535 - 39321, 65535, 65535, 65535 - 26214])
        let paper: (UInt16, [UInt16]) = (2, [65535, 65535, 65535, 65535])
        let labDark: (UInt16, [UInt16]) = (7, [2000, 0, 0, 0])
        let labRed: (UInt16, [UInt16]) = (7, [5000, 6000, 2000, 0])
        let grayBlack: (UInt16, [UInt16]) = (8, [10000, 0, 0, 0])
        let grayWhite: (UInt16, [UInt16]) = (8, [0, 0, 0, 0])
        let cases: [(AdjustMap.Channels, (UInt16, [UInt16]), (UInt16, [UInt16]))] =
            [(.cmyk, cmykStop, paper), (.lab, labDark, labRed), (.gray, grayWhite, grayBlack)]
        for (channels, s0, s1) in cases {
            let block = grdmBlock(s0, s1)
            guard case var .gradientMap(g) = AdjustMap.parse("grdm", block, nil, channels), let f = g.stops.first, let l = g.stops.last else {
                Issue.record("\(channels): not a gradient map")
                continue
            }
            let (first, last) = (f.rgb, l.rgb)
            switch channels {
            case .cmyk:
                let expected = PCColor(mode: .cmyk, c: SIMD4(0.6, 0, 0, 0.4), alpha: 1).rgb
                #expect((0 ..< 3).allSatisfy { abs(first[$0] - expected[$0]) < 1e-4 }, "\(first) vs \(expected)")
            case .lab:
                #expect((0 ..< 3).allSatisfy { abs(first[$0] - first[0]) < 1e-3 } && first[0] < 0.3, "\(first)")
                #expect(last[0] > last[1] + 0.2, "a = +60 is reddish: \(last)")
            default:
                // An inverting map, white to black.
                #expect(first == .one && last == .zero)
            }
            // The exporter keeps the block (and so the stops' colour space) byte for byte...
            let current = A.gradientMap(g)
            #expect(AdjustMap.parse("grdm", block, nil, channels) == current)
            // ...and toggling Reverse and Dither only flips their flags.
            g.reverse = true
            g.dither = true
            var flipped = block
            #expect(AdjustMap.retargetGradientMap(&flipped, .gradientMap(g), channels))
            #expect(Array(flipped[2 ..< 4]) == [1, 1])
            #expect(Array(flipped[4...]) == Array(block[4...]), "\(channels): stops keep their colour space")
            #expect(AdjustMap.parse("grdm", flipped, nil, channels) == .gradientMap(g))
        }
    }

    /// A Photo Filter block saved by older PhotoCraft (18 bytes) still parses to the same filter
    /// that is written back as the 20-byte form; a version-3 block stays readable and is written as
    /// version 2 once edited (psd_export.rs tests, block level).
    @Test func photoFilterLegacyAndVersion3Blocks() {
        let color = SIMD3<Float>(60000, 30000, 0) / 65535
        let adj = A.photoFilter(A.PhotoFilter(color: color, density: 0.14, preserveLuminosity: true))
        let full = AdjustMap.write(adj)[0].data
        #expect(full.count == 20 && Array(full[..<2]) == [0, 2] && Array(full[17...]) == [0, 0, 0])
        #expect(AdjustMap.parse("phfl", Array(full[..<18]), nil, .rgb) == adj)
        let v3: [UInt8] = [0, 3, 0, 0, 0x5E, 0x7F, 0, 0, 0x61, 0xAA, 0, 0, 0x0E, 0xF3, 0, 0, 0, 0x3F, 1, 0]
        guard case let .photoFilter(p) = AdjustMap.parse("phfl", v3, nil, .rgb) else { Issue.record("v3"); return }
        let edited = A.photoFilter(A.PhotoFilter(color: p.color, density: 0.5, preserveLuminosity: true))
        let saved = AdjustMap.write(edited)[0].data
        #expect(Array(saved[..<2]) == [0, 2])
        guard case let .photoFilter(back) = AdjustMap.parse("phfl", saved, nil, .rgb) else { Issue.record("saved"); return }
        #expect((0 ..< 3).allSatisfy { abs(back.color[$0] - p.color[$0]) <= 1.0 / 65535.0 })
        #expect(back.density == 0.5)
    }
}
