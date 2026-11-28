// Tests of the adjustment-block mapping.
// Port of photocraft-io (crates/io/src/adjust_map.rs, `#[cfg(test)] mod tests`), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import Testing
@testable import PCIOMaps

private typealias A = Adjustment

private func parse(_ key: FourCC, _ data: [UInt8], _ ch: AdjustMap.Channels = .rgb, cged: [UInt8]? = nil) -> Adjustment {
    AdjustMap.parse(key, data, cged, ch)
}

private func isUnsupported(_ a: Adjustment) -> Bool {
    if case .unsupported = a { return true }
    return false
}

private func be(_ v: [Int16]) -> [UInt8] { v.flatMap { [UInt8(UInt16(bitPattern: $0) >> 8), UInt8(UInt16(bitPattern: $0) & 0xFF)] } }

private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

private func vdesc(_ d: PSDDescriptor) -> [UInt8] { Blocks.versionedBytes(d) }

private func gms(_ t: Float, _ c: SIMD3<Float>) -> GradientMapStop { GradientMapStop(t, c) }

/// A two-stop `grdm` (version 1) whose stops are the colour structures `a` and `b`.
private func grdmWith(_ a: (UInt16, [UInt16]), _ b: (UInt16, [UInt16])) -> [UInt8] {
    var v = AdjustMap.writeGradientMap([gms(0, .zero), gms(1, .one)], false, false)
    // Header 4 + name length 4 + "Custom\0" 14 + stop count 2; 20 bytes per stop.
    for (i, (space, c)) in [a, b].enumerated() {
        let at = 24 + 20 * i + 8
        v.replaceSubrange(at ..< at + 2, with: be16(space))
        for (k, x) in c.enumerated() { v.replaceSubrange(at + 2 + 2 * k ..< at + 4 + 2 * k, with: be16(x)) }
    }
    return v
}

private func ends(_ a: Adjustment) -> (SIMD3<Float>, SIMD3<Float>)? {
    guard case let .gradientMap(g) = a, let f = g.stops.first, let l = g.stops.last else { return nil }
    return (f.rgb, l.rgb)
}

/// The colour of a gradient map at `t` (linear between its stops).
private func gradientAt(_ data: [UInt8], _ t: Float) -> SIMD3<Float>? {
    guard case let .gradientMap(g) = parse("grdm", data) else { return nil }
    let s = g.stops
    guard let i = (0 ..< max(s.count - 1, 0)).first(where: { s[$0].location <= t && t <= s[$0 + 1].location }) else { return nil }
    let (x, y) = (s[i], s[i + 1])
    let u = (t - x.location) / max(y.location - x.location, 1e-6)
    return x.rgb + (y.rgb - x.rgb) * u
}

private func rt(_ a: Adjustment, sourceLocation: SourceLocation = #_sourceLocation) {
    let blocks = AdjustMap.write(a)
    #expect(!blocks.isEmpty, "\(a)", sourceLocation: sourceLocation)
    guard let first = blocks.first else { return }
    let cged = blocks.first { $0.key == "CgEd" }?.data
    let back = AdjustMap.parse(first.key, first.data, cged, .rgb)
    #expect(back == a, sourceLocation: sourceLocation)
}

private func pts(_ v: [(UInt8, UInt8)]) -> [CurvePoint] { v.map { CurvePoint(input: Float($0.0) / 255, output: Float($0.1) / 255) } }

private func lc(_ a: UInt16, _ b: UInt16) -> LevelsChannel {
    LevelsChannel(inBlack: Float(a) / 255, inWhite: Float(b) / 255, gamma: 1.2, outBlack: 0, outWhite: 1)
}

private func phflV3(_ xyz: [UInt32], _ density: UInt32, _ preserve: Bool) -> [UInt8] {
    var d: [UInt8] = [0, 3]
    for x in xyz { d += be32(x) }
    d += be32(density)
    d += [preserve ? 1 : 0, 0]
    return d
}

private func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float) -> Bool { (0 ..< 3).allSatisfy { abs(a[$0] - b[$0]) < tol } }

@Suite struct AdjustMapTests {
    @Test func gradientMapV3MethodsAndSmoothness() throws {
        let classic = [gms(0, SIMD3(0, 0, 1)), gms(1, SIMD3(1, 1, 0))]
        let v1 = AdjustMap.writeGradientMap(classic, false, false)
        // Version 3 inserts the interpolation method after reverse/dither.
        func v3(_ m: String) -> [UInt8] {
            var v = v1
            v[1] = 3
            v.insert(contentsOf: Array(m.utf8), at: 4)
            return v
        }
        let c = try #require(gradientAt(v3("Gcls"), 0.5))
        #expect(abs(c.x - 0.5) < 1e-3 && abs(c.z - 0.5) < 1e-3, "classic = sRGB lerp \(c)")
        let p = try #require(gradientAt(v3("Perc"), 0.5))
        #expect(abs(p.x - c.x) > 0.02, "perceptual differs from classic \(p)")
        // Smoothness 100 % (4096) bends a three-stop ramp.
        let three = [gms(0, .zero), gms(0.25, SIMD3(1, 0, 0)), gms(0.75, SIMD3(0, 0, 1)), gms(1, .one)]
        var smooth = AdjustMap.writeGradientMap(three, false, false)
        let at = smooth.count - 2 - 16 - 2 - 4 - 2 - 2 - 4 - 2 - 2 - 2
        smooth.replaceSubrange(at ..< at + 2, with: be16(4096))
        let a = try #require(gradientAt(AdjustMap.writeGradientMap(three, false, false), 0.4))
        let b = try #require(gradientAt(smooth, 0.4))
        #expect((0 ..< 3).contains { abs(a[$0] - b[$0]) > 1e-3 }, "\(a) \(b)")
        // Noise gradients (no colour stops) stay unsupported.
        #expect(isUnsupported(parse("grdm", [0, 1, 0, 0, 0, 0, 0, 0, 0, 0])))
    }

    @Test func pencilCurvesReadAndWriteTheMapForm() throws {
        // Photoshop's pencil-drawn curves: map flag 1, then 256 output bytes per channel.
        var block: [UInt8] = [1, 0, 1, 0, 0, 0, 0b1111]
        let maps: [[UInt8]] = [
            (0 ... 255).reversed().map { UInt8($0) },
            (0 ... 255).map { $0 < 128 ? 0 : 255 },
            (0 ... 255).map { UInt8($0) },
            (0 ... 255).map { UInt8($0 / 2) },
        ]
        for m in maps { block += m }
        let a = parse("curv", block)
        guard case let .curves(c) = a else { Issue.record("\(a)"); return }
        #expect(c.pencil)
        #expect(c.master.count == curveMapLength)
        #expect(c.master[0].output == 1 && c.master[255].output == 0)
        #expect(c.perChannel[0][127].output == 0 && c.perChannel[0][128].output == 1)
        #expect(AdjustMap.write(a)[0].data == block)
    }

    @Test func gradientMapStopsInEveryColourSpace() throws {
        let whiteRGB: (UInt16, [UInt16]) = (0, [65535, 65535, 65535, 0])
        // CMYK, stored inverted: 65535 = no ink. Full K only.
        let kOnly = grdmWith((2, [65535, 65535, 65535, 0]), whiteRGB)
        let expected = PCColor(mode: .cmyk, c: SIMD4(0, 0, 0, 1), alpha: 1).rgb
        for channels in [AdjustMap.Channels.cmyk, .rgb, .lab] {
            let (first, last) = try #require(ends(parse("grdm", kOnly, channels)))
            #expect(near(first, expected, 1e-5), "\(first) vs \(expected)")
            #expect(first.x < 0.4 && abs(first.x - first.z) < 0.05, "K-only black is a dark neutral: \(first)")
            #expect(last == SIMD3(repeating: 1))
        }
        // Lab: L 50, a 0, b 0 is a neutral mid grey; L 100 white.
        let (lf, ll) = try #require(ends(parse("grdm", grdmWith((7, [5000, 0, 0, 0]), (7, [10000, 0, 0, 0])), .lab)))
        #expect((0 ..< 3).allSatisfy { abs(lf[$0] - 0.466) < 0.01 }, "\(lf)")
        #expect((0 ..< 3).allSatisfy { ll[$0] > 0.99 }, "\(ll)")
        // Lab with chroma: a = +60 is reddish (a and b are signed hundredths).
        let (red, _) = try #require(ends(parse("grdm", grdmWith((7, [5000, 6000, 0, 0]), whiteRGB), .lab)))
        #expect(red.x > red.y + 0.2, "\(red)")
        // Grayscale: 0...10000 is ink coverage (10000 = black).
        let gray = try #require(ends(parse("grdm", grdmWith((8, [10000, 0, 0, 0]), (8, [0, 0, 0, 0])), .gray)))
        #expect(gray.0 == .zero && gray.1 == .one)
        // HSB: hue 240 degrees (2/3 of 65535), full saturation and brightness = blue.
        let (hsb, _) = try #require(ends(parse("grdm", grdmWith((1, [43690, 65535, 65535, 0]), whiteRGB))))
        #expect(hsb.x < 1e-3 && hsb.y < 1e-3 && abs(hsb.z - 1) < 1e-3, "\(hsb)")
        // Book colours and unknown ids are not guessed: the block stays raw.
        for space: UInt16 in [3, 9, 0xFFFF] {
            #expect(isUnsupported(parse("grdm", grdmWith((space, [1, 2, 3, 4]), whiteRGB))), "space \(space)")
        }
        // Truncated stops never trap.
        for n in 0 ..< kOnly.count { _ = parse("grdm", Array(kOnly[..<n]), .cmyk) }
    }

    @Test func gradientMapReverseAndDitherKeepTheStopsBlock() throws {
        let original = grdmWith((2, [65535, 65535, 65535, 0]), (7, [10000, 0, 0, 0]))
        guard case let .gradientMap(g) = parse("grdm", original, .cmyk) else { Issue.record("not a gradient map"); return }
        var data = original
        let target = A.gradientMap(A.GradientMap(stops: g.stops, reverse: true, dither: true))
        #expect(AdjustMap.retargetGradientMap(&data, target, .cmyk))
        #expect(Array(data[2 ..< 4]) == [1, 1])
        #expect(Array(data[4...]) == Array(original[4...]), "the stops keep their colour spaces")
        #expect(parse("grdm", data, .cmyk) == target)
        // Edited stops are not patched in.
        var edited = g.stops
        edited[0].rgb = SIMD3(repeating: 0.5)
        var data2 = original
        let target2 = A.gradientMap(A.GradientMap(stops: edited, reverse: false, dither: false))
        #expect(!AdjustMap.retargetGradientMap(&data2, target2, .cmyk))
        #expect(data2 == original)
        var empty: [UInt8] = []
        #expect(!AdjustMap.retargetGradientMap(&empty, target2, .cmyk))
        #expect(!AdjustMap.retargetGradientMap(&data2, .invert, .cmyk))
    }

    /// photocraft #7065 `hue2_writes_each_triplet_in_its_own_slot`: Photoshop keeps the colorize
    /// triplet at byte 4 and the master triplet at byte 10 and fills the inactive one with its
    /// defaults, colorize (30, 25, 0) and master (0, 0, 0). The colorize hue is stored signed.
    @Test func hue2WritesEachTripletInItsOwnSlot() {
        func triplets(_ a: Adjustment) -> [Int16] {
            let d = AdjustMap.write(a)[0].1
            return (0 ..< 6).map { i in Int16(bitPattern: UInt16(d[4 + 2 * i]) << 8 | UInt16(d[5 + 2 * i])) }
        }
        let on = Adjustment.hueSaturation(A.HueSaturation(hue: 200, saturation: 40, lightness: 10, colorize: true, ranges: HueRange.defaults))
        #expect(triplets(on) == [-160, 40, 10, 0, 0, 0])
        let off = Adjustment.hueSaturation(A.HueSaturation(hue: -30, saturation: 20, lightness: 5, colorize: false, ranges: HueRange.defaults))
        #expect(triplets(off) == [30, 25, 0, -30, 20, 5])
    }

    @Test func roundtrips() {
        rt(.invert)
        rt(.threshold(level: 128.0 / 255.0))
        rt(.posterize(levels: 4))
        rt(.brightnessContrast(A.BrightnessContrast(brightness: 20, contrast: -10, legacy: false)))
        rt(.brightnessContrast(A.BrightnessContrast(brightness: -150, contrast: 100, legacy: true)))
        rt(.brightnessContrast(A.BrightnessContrast(brightness: 25, contrast: 35, mode: .modern)))
        rt(.brightnessContrast(A.BrightnessContrast(contrast: 35, mode: .light, exposure: -1.25, whites: 10, blacks: -5, highlights: 20, shadows: -15)))
        rt(.hueSaturation(A.HueSaturation(hue: 30, saturation: -20, lightness: 5, colorize: false, ranges: HueRange.defaults)))
        rt(.hueSaturation(A.HueSaturation(hue: 200, saturation: 50, lightness: 0, colorize: true, ranges: HueRange.defaults)))
        var ranges = HueRange.defaults
        ranges[0] = HueRange(hue: 15, saturation: -40, lightness: 10, bounds: SIMD4(-60, -20, 10, 30))
        ranges[4].saturation = 25
        rt(.hueSaturation(A.HueSaturation(hue: -10, saturation: 0, lightness: 0, colorize: false, ranges: ranges)))
        rt(.exposure(A.Exposure(exposure: 1.5, offset: -0.01, gamma: 0.9)))
        rt(.levels(A.Levels(master: lc(10, 240), perChannel: [lc(0, 255), lc(5, 250), lc(20, 200)], space: .rgb, black: LevelsChannel())))
        rt(.curves(A.Curves(master: pts([(0, 0), (128, 150), (255, 255)]),
                            perChannel: [pts([(0, 10), (255, 255)]), pts([(0, 0), (255, 245)]), pts([(0, 0), (64, 32), (255, 255)])],
                            space: .rgb, black: [], pencil: false)))
        // CMYK ink curves and levels keep their black record.
        let ink = A.curves(A.Curves(master: pts([(0, 0), (255, 255)]),
                                    perChannel: [pts([(0, 0), (255, 255)]), pts([(0, 30), (255, 255)]), pts([(0, 0), (255, 255)])],
                                    space: .cmyk, black: pts([(0, 0), (128, 100), (255, 255)]), pencil: false))
        let b = AdjustMap.write(ink)
        #expect(parse(b[0].key, b[0].data, .cmyk) == ink)
        let inkl = A.levels(A.Levels(master: lc(0, 255), perChannel: [lc(0, 255), lc(5, 250), lc(0, 255)], space: .cmyk, black: lc(30, 255)))
        let bl = AdjustMap.write(inkl)
        #expect(parse(bl[0].key, bl[0].data, .cmyk) == inkl)
        rt(.unsupported(psdKey: "selc", raw: [1, 2, 3]))
        rt(.gradientMap(A.GradientMap(stops: [gms(0, .zero), gms(0.5, SIMD3(1, 0, 0)), gms(1, .one)], reverse: true, dither: false)))
        rt(.gradientMap(A.GradientMap(stops: [gms(0, .zero), gms(1, .one)], reverse: false, dither: true)))
        rt(.selectiveColor(A.SelectiveColor(relative: true, adjustments: (0 ..< 9).map { SIMD4(Float($0) * 10 - 40, 5, -100, 100) })))
        rt(.selectiveColor(A.SelectiveColor(relative: false, adjustments: Array(repeating: .zero, count: 9))))
        rt(.vibrance(A.Vibrance(vibrance: 35, saturation: -12)))
        rt(.vibrance(A.Vibrance(vibrance: 0, saturation: 0)))
        rt(.colorBalance(A.ColorBalance(shadows: SIMD3(20, -10, 5), midtones: SIMD3(-15, 10, 30), highlights: SIMD3(0, 5, -100), preserveLuminosity: true)))
        rt(.colorBalance(A.ColorBalance(shadows: .zero, midtones: SIMD3(100, 0, 0), highlights: .zero, preserveLuminosity: false)))
        rt(.blackWhite(A.BlackWhite(weights: [40, 60, 40, 60, 20, 80], tint: nil)))
        rt(.blackWhite(A.BlackWhite(weights: [-200, 300, 0, 10, 90, 30], tint: SIMD3(0.9, 0.7, 0.5))))
        func q(_ v: UInt16) -> Float { Float(v) / 65535 }
        rt(.photoFilter(A.PhotoFilter(color: SIMD3(q(60000), q(30000), q(0)), density: 0.25, preserveLuminosity: true)))
        rt(.photoFilter(A.PhotoFilter(color: SIMD3(q(0), q(40000), q(65535)), density: 1, preserveLuminosity: false)))
        rt(.channelMixer(A.ChannelMixer(matrix: [SIMD4(0.5, 0.3, 0.2, 0), SIMD4(0.1, 0.8, 0.1, 0.05), SIMD4(0, 0.2, 0.9, -0.05)], monochrome: false)))
        rt(.channelMixer(A.ChannelMixer(matrix: [SIMD4(0.4, 0.4, 0.2, 0.1), SIMD4(0, 1, 0, 0), SIMD4(-2, 0, 2, 0)], monochrome: true)))
        let id = AdjustMap.LutFile.identity(5)
        rt(.colorLookup(A.ColorLookup(name: "Look.cube", lut: id.data, size: 5, tetrahedral: false, dither: true)))
    }

    @Test func selectiveColorSyntheticBlock() {
        // Absolute; reds = (+10, -20, +30, -40), blacks = (0, 0, 0, 25).
        var d: [UInt8] = [0, 1, 0, 1] + [UInt8](repeating: 0, count: 8)
        for r in 0 ..< 9 {
            let rec: [Int16] = r == 0 ? [10, -20, 30, -40] : (r == 8 ? [0, 0, 0, 25] : [0, 0, 0, 0])
            d += be(rec)
        }
        let a = parse("selc", d)
        guard case let .selectiveColor(s) = a else { Issue.record("\(a)"); return }
        #expect(!s.relative)
        #expect(s.adjustments[0] == SIMD4(10, -20, 30, -40))
        #expect(s.adjustments[8] == SIMD4(0, 0, 0, 25))
        // Written back byte-exact.
        #expect(AdjustMap.write(a)[0].data == d)
    }

    @Test func colorLookupSyntheticBlock() throws {
        let cube = Array("TITLE \"t\"\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".utf8)
        let desc = PSDDescriptor(classID: "null")
            .with("lookupType", Blocks.enumValue("colorLookupType", "3DLUT"))
            .with("NM  ", Blocks.text("Id"))
            .with("Dthr", .boolean(true))
            .with("LUTFormat", Blocks.enumValue("LUTFormatType", "LUTFormatCUBE"))
            .with("LUT3DFileData", .rawData(Data(cube)))
        let d: [UInt8] = [0, 1] + vdesc(desc)
        let a = parse("clrL", d)
        guard case let .colorLookup(l) = a, let t = l.lut else { Issue.record("\(a)"); return }
        #expect(l.size == 2 && l.dither)
        #expect(l.name == "Id")
        #expect(Array(t[..<6]) == [0, 0, 0, 1, 0, 0])
        // A profile-based lookup (no table) is preserved raw.
        let p: [UInt8] = [0, 1] + vdesc(PSDDescriptor(classID: "null").with("lookupType", Blocks.enumValue("colorLookupType", "abstractProfile")))
        #expect(isUnsupported(parse("clrL", p)))
        // Each way a lookup can't be read has a reason for the import warning (#1763).
        #expect(AdjustMap.unreadableReason("clrL", d) == nil)
        #expect(try #require(AdjustMap.unreadableReason("clrL", p)).contains("colour profile"))
        #expect(try #require(AdjustMap.unreadableReason("clrL", [0])).contains("truncated"))
        #expect(try #require(AdjustMap.unreadableReason("clrL", [0, 2, 0, 0])).contains("version 2"))
        #expect(try #require(AdjustMap.unreadableReason("clrL", [0, 1, 9])).contains("unreadable settings"))
        let bad = PSDDescriptor(classID: "null").with("LUTFormat", Blocks.enumValue("LUTFormatType", "LUTFormat3DL"))
            .with("LUT3DFileData", .rawData(Data("not a lut".utf8)))
        let bb: [UInt8] = [0, 1] + vdesc(bad)
        #expect(isUnsupported(parse("clrL", bb)))
        let reason = AdjustMap.unreadableReason("clrL", bb)
        #expect(reason?.contains("3DL LUT can't be read") == true, "\(String(describing: reason))")
        #expect(AdjustMap.label("clrL") == "Color Lookup")
        #expect(isUnsupported(parse("clrL", [0, 1, 9])))
        #expect(isUnsupported(parse("selc", [0, 1, 0, 0])))
    }

    @Test func malformedFallsBackToUnsupported() {
        #expect(isUnsupported(parse("levl", [0, 2, 1])))
        #expect(isUnsupported(parse("curv", [0, 0, 9])))
        #expect(isUnsupported(parse("thrs", [])))
        #expect(isUnsupported(parse("blnc", [UInt8](repeating: 0, count: 18))))
        #expect(isUnsupported(parse("vibA", [0, 0, 0, 15, 0])))
        #expect(isUnsupported(parse("blwh", [])))
        #expect(isUnsupported(parse("mixr", [0, 2, 0, 0])))
        // A CMYK mixer (black source used) stays raw in CMYK documents; our own RGB layout maps.
        var cmyk = be([1, 0])
        for r in 0 ..< 4 { cmyk += be((0 ..< 5).map { $0 == r ? 100 : 0 }) }
        #expect(isUnsupported(parse("mixr", cmyk, .cmyk)))
        #expect(isUnsupported(parse("mixr", cmyk, .other)))
        let ours = AdjustMap.write(.channelMixer(A.ChannelMixer(matrix: [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0)], monochrome: false)))
        if case .channelMixer = parse("mixr", ours[0].data, .cmyk) {} else { Issue.record("cmyk") }
        if case .channelMixer = parse("mixr", ours[0].data, .other) {} else { Issue.record("other") }
        #expect(isUnsupported(parse("mixr", [0, 1, 0, 0, 0, 100])))
        // Photo Filter: unknown version, HSB colour space, out-of-range version-3 XYZ, truncated.
        #expect(isUnsupported(parse("phfl", [0, 4, 0, 0])))
        #expect(isUnsupported(parse("phfl", [0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 25, 1])))
        for bad: [UInt32] in [[200_000, 0, 0], [0, UInt32.max, 0]] {
            var xyz: [UInt8] = [0, 3]
            for x in bad { xyz += be32(x) }
            xyz += [0, 0, 0, 25, 1]
            #expect(isUnsupported(parse("phfl", xyz)))
        }
        #expect(isUnsupported(parse("phfl", [0, 2, 0, 0, 0, 0])))
        // Arbitrary bytes never trap, whatever the key.
        for key in AdjustMap.adjustmentKeys {
            for len in 0 ..< 64 {
                let d = (0 ..< len).map { UInt8(truncatingIfNeeded: $0 * 37 + len) }
                _ = AdjustMap.parse(key, d, d, .rgb)
                _ = AdjustMap.parse(key, d, nil, .other)
            }
        }
    }

    /// Hand-built blocks laid out per the Adobe spec (no file written by Photoshop involved).
    @Test func colorBalanceGoldenBlock() {
        let d = be([-30, 20, 0, 10, -5, 100, 0, 0, -100]) + [1, 0]
        let a = parse("blnc", d)
        #expect(a == .colorBalance(A.ColorBalance(shadows: SIMD3(-30, 20, 0), midtones: SIMD3(10, -5, 100), highlights: SIMD3(0, 0, -100), preserveLuminosity: true)))
        let w = AdjustMap.write(a)
        #expect(w.count == 1 && w[0].key == "blnc" && w[0].data == d)
        // The 19-byte form (no trailing pad) parses the same.
        #expect(parse("blnc", Array(d[..<19])) == a)
    }

    @Test func photoFilterGoldenBlocks() throws {
        // Version 2, RGB colour structure (65535, 32768, 0), density 40 %, preserve luminosity.
        let v2: [UInt8] = be([2, 0]) + [0xFF, 0xFF, 0x80, 0x00, 0, 0, 0, 0] + be32(40) + [1, 0, 0, 0]
        #expect(v2.count == 20, "Photo Filter must occupy 20 bytes")
        #expect(Array(v2[17...]) == [0, 0, 0], "padding is included inside the block length")
        let a = parse("phfl", v2)
        guard case let .photoFilter(p) = a, p.preserveLuminosity else { Issue.record("\(a)"); return }
        #expect(p.color == SIMD3<Float>(1, 32768.0 / 65535.0, 0))
        #expect(p.density == 0.4)
        #expect(AdjustMap.write(a)[0].data == v2, "version 2 RGB is written back byte-exact")
        // Older PhotoCraft files used only one padding byte (18 bytes); keep importing them, but
        // never produce that Photoshop-incompatible length again.
        #expect(parse("phfl", Array(v2[..<18])) == a)
        for preserve in [false, true] {
            for density: Float in [0, 0.14, 1] {
                let adj = A.photoFilter(A.PhotoFilter(color: SIMD3(0.8, 0.4, 0.2), density: density, preserveLuminosity: preserve))
                let blocks = AdjustMap.write(adj)
                #expect(blocks.count == 1 && blocks[0].key == "phfl" && blocks[0].data.count == 20)
                #expect(Array(blocks[0].data[17...]) == [0, 0, 0])
                guard case let .photoFilter(r) = parse("phfl", blocks[0].data) else { Issue.record("written phfl must parse"); continue }
                #expect(near(r.color, SIMD3(0.8, 0.4, 0.2), 1.0 / 65535.0 + 1e-7))
                #expect(abs(r.density - density) < 0.00001)
                #expect(r.preserveLuminosity == preserve)
            }
        }
        // Version 2, Lab colour structure: L 50, a 0, b 0 is mid gray.
        let lab = be([2, 7, 5000, 0, 0, 0]) + be32(25) + [0]
        guard case let .photoFilter(l) = parse("phfl", lab), !l.preserveLuminosity else { Issue.record("lab"); return }
        #expect((0 ..< 3).allSatisfy { abs(l.color[$0] - 0.466) < 0.01 }, "\(l.color)")
        #expect(l.density == 0.25)
        // Version 3: D50 XYZ, 1.0 = 32768. The ICC sRGB white point (D50) is white.
        guard case let .photoFilter(w) = parse("phfl", phflV3([31595, 32768, 27040], 100, true)), w.preserveLuminosity else { Issue.record("v3"); return }
        #expect((0 ..< 3).allSatisfy { abs(w.color[$0] - 1) < 0.005 }, "\(w.color)")
        #expect(w.density == 1)
        // Photoshop's Warming Filter (85) preset, sRGB #EC8A00, is D50 XYZ (15193, 12086, 1192).
        guard case let .photoFilter(warm) = parse("phfl", phflV3([15193, 12086, 1192], 25, false)), !warm.preserveLuminosity else { Issue.record("warm"); return }
        let want = SIMD3<Float>(0xEC, 0x8A, 0x00) / 255
        #expect(near(warm.color, want, 1.5 / 255), "\(warm.color)")
        #expect(warm.density == 0.25)
        // The block from #3777 (Photoshop CS2): a warm yellow, density 63 %, preserve luminosity.
        let issue: [UInt8] = [0, 3, 0, 0, 0x5E, 0x7F, 0, 0, 0x61, 0xAA, 0, 0, 0x0E, 0xF3, 0, 0, 0, 0x3F, 1, 0]
        guard case let .photoFilter(cs2) = parse("phfl", issue), cs2.preserveLuminosity else { Issue.record("issue"); return }
        let c = cs2.color
        #expect(c.x > c.y && c.y > c.z && c.y > 0.8 && c.z < 0.3, "\(c)")
        #expect(cs2.density == 0.63)
        // The 19-byte form (no trailing pad) parses the same.
        #expect(parse("phfl", Array(issue[..<19])) == parse("phfl", issue))
        // Version 3 is read, never written: an edited filter is saved as version 2 and keeps its colour.
        let wr = AdjustMap.write(parse("phfl", issue))
        #expect(Array(wr[0].data[..<2]) == [0, 2])
        guard case let .photoFilter(back) = parse("phfl", wr[0].data) else { Issue.record("back"); return }
        #expect(near(back.color, c, 1.0 / 65535.0 + 1e-7))
    }

    @Test func channelMixerGoldenBlocks() {
        // RGB: red = 100 % R + 20 % const; green = 50 % R + 50 % G; blue = -50 % G + 150 % B - 10 % const.
        let d = be([1, 0]) + be([100, 0, 0, 0, 20, 50, 50, 0, 0, 0, 0, -50, 150, 0, -10])
        let a = parse("mixr", d)
        #expect(a == .channelMixer(A.ChannelMixer(matrix: [SIMD4(1, 0, 0, 0.2), SIMD4(0.5, 0.5, 0, 0), SIMD4(0, -0.5, 1.5, -0.1)], monochrome: false)))
        // Written with the trailing gray record (a copy of the first row).
        let w = AdjustMap.write(a)[0].data
        #expect(Array(w[..<d.count]) == d)
        #expect(Array(w[d.count...]) == be([100, 0, 0, 0, 20]))
        // Monochrome with only the gray record: 30/59/11.
        let m = be([1, 1]) + be([30, 59, 11, 0, 0])
        guard case let .channelMixer(x) = parse("mixr", m), x.monochrome else { Issue.record("mono"); return }
        #expect(x.matrix[0] == SIMD4(0.3, 0.59, 0.11, 0))
    }

    @Test func vibranceGoldenBlock() {
        let d = vdesc(PSDDescriptor(classID: "null").with("vibrance", .integer(-40)).with("Strt", .integer(25)))
        #expect(Array(d[..<4]) == [0, 0, 0, 16], "descriptor version 16")
        #expect(parse("vibA", d) == .vibrance(A.Vibrance(vibrance: -40, saturation: 25)))
        // Photoshop omits zero values.
        let only = vdesc(PSDDescriptor(classID: "null").with("Strt", .integer(10)))
        #expect(parse("vibA", only) == .vibrance(A.Vibrance(vibrance: 0, saturation: 10)))
        // Other descriptor versions are rejected (kept raw).
        var v = d
        v[3] = 17
        #expect(isUnsupported(parse("vibA", v)))
    }

    @Test func blackWhiteGoldenBlock() {
        let tint = PSDDescriptor(classID: "RGBC").with("Rd  ", .double(255)).with("Grn ", .double(127.5)).with("Bl  ", .double(0))
        var desc = PSDDescriptor(classID: "null")
        for (k, w) in zip(AdjustMap.bwKeys, [10, 20, 30, 40, 50, 60] as [Int32]) { desc = desc.with(k, .integer(w)) }
        let d = vdesc(desc.with("useTint", .boolean(true)).with("tintColor", .descriptor(tint)).with("bwPresetKind", .integer(1)))
        #expect(parse("blwh", d) == .blackWhite(A.BlackWhite(weights: [10, 20, 30, 40, 50, 60], tint: SIMD3(1, 0.5, 0))))
        // useTint off: no tint, even with a stored colour.
        let off = vdesc(desc.with("useTint", .boolean(false)).with("tintColor", .descriptor(tint)))
        if case let .blackWhite(b) = parse("blwh", off) { #expect(b.tint == nil) } else { Issue.record("off") }
        // Missing weights take Photoshop's defaults.
        #expect(parse("blwh", vdesc(PSDDescriptor(classID: "null"))) == .blackWhite(A.BlackWhite(weights: AdjustMap.bwDefault, tint: nil)))
    }

    @Test func degenerateAdjustmentsStillGetAnEncoding() {
        // Gradient maps with fewer than two stops render as gray (none) or one colour.
        let cases: [([GradientMapStop], [GradientMapStop])] = [
            ([], [gms(0, .zero), gms(1, .one)]),
            ([gms(0.3, SIMD3(0.2, 0.4, 0.6))], [gms(0, SIMD3(0.2, 0.4, 0.6)), gms(1, SIMD3(0.2, 0.4, 0.6))]),
        ]
        for (stops, want) in cases {
            let b = AdjustMap.write(.gradientMap(A.GradientMap(stops: stops, reverse: true, dither: false)))
            guard case let .gradientMap(back) = parse(b[0].key, b[0].data), back.reverse else { Issue.record("\(stops)"); continue }
            #expect(back.stops.count == want.count)
            for (s, w) in zip(back.stops, want) {
                #expect(abs(s.location - w.location) < 1e-6 && near(s.rgb, w.rgb, 1e-4), "\(s) vs \(w)")
            }
        }
        // A colour lookup without a (usable) table is written as Photoshop writes one with no
        // table chosen (Photoshop opened the identity cube PCIO wrote before as a pixel layer):
        // it reads back as a lookup without a table, which renders as the identity.
        for lut in [nil, [Float](repeating: 0.5, count: 7)] {
            let b = AdjustMap.write(.colorLookup(A.ColorLookup(name: "L", lut: lut, size: 3, tetrahedral: false, dither: true)))
            #expect(b.first?.data == AdjustMap.photoshopEmptyLookup)
            guard case let .colorLookup(back) = parse(b[0].key, b[0].data), back.lut == nil, back.size == 0, !back.dither else { Issue.record("lookup"); continue }
            #expect(back.name.isEmpty)
        }
        // Every kind except a malformed unsupported key has an encoding.
        #expect(AdjustMap.write(.unsupported(psdKey: "abc", raw: [])).isEmpty)
    }

    @Test func nonRGBIgnoresChannelRecords() {
        let c = LevelsChannel(inBlack: 0.1)
        let b = AdjustMap.write(.levels(A.Levels(master: LevelsChannel(), perChannel: [c, c, c], space: .rgb, black: LevelsChannel())))
        guard case let .levels(l) = parse(b[0].key, b[0].data, .other) else { Issue.record("levels"); return }
        #expect(l.perChannel == Array(repeating: LevelsChannel(), count: 3))
    }

    @Test func grayUsesFirstChannelRecordForAll() {
        let c = LevelsChannel(inBlack: 44.0 / 255.0)
        let b = AdjustMap.write(.levels(A.Levels(master: LevelsChannel(), perChannel: [c, LevelsChannel(), LevelsChannel()], space: .rgb, black: LevelsChannel())))
        guard case let .levels(l) = parse(b[0].key, b[0].data, .gray) else { Issue.record("levels"); return }
        #expect(l.perChannel == [c, c, c])
    }

    @Test func legacyBritWithoutCgEd() {
        #expect(parse("brit", [0, 10, 0xFF, 0xF6, 0, 127, 0]) == .brightnessContrast(A.BrightnessContrast(brightness: 10, contrast: -10, legacy: true)))
    }
}


/// Photoshop 27.11's Brightness/Contrast descriptor layouts (PCRender phase 5: the M2 PSDs and
/// ps-corpus adj-brightnessContrast / adj-brightnessContrast-b25c35), and the mode a file without
/// `brightnessMode` gets.
@Suite struct BrightnessContrastModeTests {
    func keys(_ a: Adjustment) -> [String] {
        guard let c = AdjustMap.write(a).first(where: { $0.key == "CgEd" }), let d = Blocks.parsePrefixVersioned(c.data) else { return [] }
        return d.items.map(\.key.name)
    }

    @Test func layoutsMatchPhotoshop() {
        #expect(keys(.brightnessContrast(A.BrightnessContrast(contrast: 35, mode: .light)))
            == ["Vrsn", "brightnessExposure", "Brgh", "Cntr", "brightnessWhites", "brightnessBlacks", "brightnessHighlights", "brightnessShadows",
                "means", "Lab ", "brightnessMode", "useLegacy", "Auto"])
        #expect(keys(.brightnessContrast(A.BrightnessContrast(brightness: 25, contrast: 35, mode: .modern)))
            == ["Vrsn", "Brgh", "Cntr", "means", "Lab ", "brightnessMode", "useLegacy", "Auto"])
        #expect(keys(.brightnessContrast(A.BrightnessContrast(brightness: 25, contrast: 35, legacy: true)))
            == ["Vrsn", "Brgh", "Cntr", "means", "Lab ", "useLegacy", "Auto"])
    }

    @Test func aFileWithoutTheModeKeepsTodaysMapping() {
        func cged(_ legacy: Bool) -> [UInt8] {
            Blocks.versionedBytes(PSDDescriptor(classID: "null").with("Vrsn", .integer(1)).with("Brgh", .integer(25)).with("Cntr", .integer(35))
                .with("means", .integer(127)).with("Lab ", .boolean(false)).with("useLegacy", .boolean(legacy)).with("Auto", .boolean(false)))
        }
        let brit: [UInt8] = [0, 25, 0, 35, 0, 127, 0]
        #expect(parse("brit", brit, cged: cged(false)) == .brightnessContrast(A.BrightnessContrast(brightness: 25, contrast: 35, mode: .modern)))
        #expect(parse("brit", brit, cged: cged(true)) == .brightnessContrast(A.BrightnessContrast(brightness: 25, contrast: 35, mode: .legacy)))
        let light = Blocks.versionedBytes(PSDDescriptor(classID: "null").with("Vrsn", .integer(1)).with("brightnessExposure", .double(0))
            .with("Brgh", .integer(0)).with("Cntr", .integer(35)).with("brightnessWhites", .integer(0)).with("brightnessBlacks", .integer(0))
            .with("brightnessHighlights", .integer(0)).with("brightnessShadows", .integer(0)).with("means", .integer(127)).with("Lab ", .boolean(false))
            .with("brightnessMode", Blocks.enumValue("brightnessModeType", "brightnessModeLight")).with("useLegacy", .boolean(false)).with("Auto", .boolean(false)))
        #expect(parse("brit", [0, 0, 0, 35, 0, 127, 0], cged: light) == .brightnessContrast(A.BrightnessContrast(contrast: 35, mode: .light)))
    }
}
