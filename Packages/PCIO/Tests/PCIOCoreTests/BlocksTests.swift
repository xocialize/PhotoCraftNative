// Tests ported from photocraft-io (crates/io/src/blocks.rs, pixels.rs, gradient_bake.rs inline
// tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import simd
import PCDocument
import PCFoundation
import PCPSD
import Testing
@testable import PCIOCore

private func at(_ stops: [ColorStop], _ t: Float) -> SIMD3<Float> {
    let i = (0 ..< stops.count - 1).first { t >= stops[$0].location && t <= stops[$0 + 1].location } ?? 0
    let (a, b) = (stops[i], stops[i + 1])
    let u = (t - a.location) / (b.location - a.location)
    return a.color.rgb + (b.color.rgb - a.color.rgb) * u
}

@Suite struct GradientBakeTests {
    @Test func classicWithoutSmoothnessIsUntouched() {
        let s = [ColorStop(0, .black), ColorStop(1, .white)]
        #expect(GradientBake.bake(s, [0.5], 0, .classic) == s)
    }

    @Test func smoothnessEasesBetweenTwoStops() {
        let s = GradientBake.bake([ColorStop(0, .black), ColorStop(1, .white)], [0.5], 1, .classic)
        for t: Float in [0.1, 0.25, 0.5, 0.75, 0.9] {
            let ss = t * t * (3 - 2 * t)
            let want = t + 0.5 * (ss - t)
            #expect(abs(at(s, t).x - want) < 2e-3)
        }
    }

    @Test func smoothnessDoesNotOvershootAFlatStopSegment() {
        func gray(_ v: Float) -> PCColor { .rgb(v, v, v) }
        let dark: Float = 28 / 255
        let stops = [ColorStop(0, gray(202 / 255)), ColorStop(0.27, gray(dark)), ColorStop(0.53, gray(dark)), ColorStop(0.72, gray(148 / 255))]
        let baked = GradientBake.bake(stops, [0.5, 0.5, 0.5], 1, .classic)
        let sample = at(baked, 0.4)
        #expect(abs(sample.x - dark) < 1e-4 && abs(sample.y - dark) < 1e-4 && abs(sample.z - dark) < 1e-4)
    }

    @Test func perceptualMatchesPhotoshopSample() {
        let s = GradientBake.bake([ColorStop(0, .rgb(0.882, 0.602, 0.201)), ColorStop(1, .rgb(0.164, 0.568, 0.851))], [0.5], 1, .perceptual)
        let p = at(s, 0.491)
        for (got, want) in zip([p.x, p.y, p.z], [0.592 as Float, 0.612, 0.596]) { #expect(abs(got - want) < 0.01) }
        let q = at(s, 0.113)
        for (got, want) in zip([q.x, q.y, q.z], [0.839 as Float, 0.608, 0.290]) { #expect(abs(got - want) < 0.012) }
    }

    /// Photoshop 27.11's Smooth Gradient Map with three stops (ps-corpus `adj-gradientMap.psd`:
    /// (30, 0, 80) → (230, 90, 40) at 50 % → (255, 250, 200)), read off its composite at the
    /// input luminances (0.30/0.59/0.11) below. Straight segments with an easing were up to 8
    /// levels off around the middle stop.
    @Test func smoothThroughAnInteriorStopMatchesPhotoshop() {
        func c(_ r: Float, _ g: Float, _ b: Float) -> PCColor { .rgb(r / 255, g / 255, b / 255) }
        let s = GradientBake.bake([ColorStop(0, c(30, 0, 80)), ColorStop(0.5, c(230, 90, 40)), ColorStop(1, c(255, 250, 200))], [0.5, 0.5], 1, .smooth)
        let measured: [(Int, SIMD3<Float>)] = [(20, SIMD3(50.3, 22, 82)), (60, SIMD3(114, 54, 80)), (100, SIMD3(187, 73, 59)), (110, SIMD3(205, 77, 50)),
                                               (120, SIMD3(220.5, 83.5, 42)), (140, SIMD3(240, 105, 53)), (150, SIMD3(245, 118, 63)),
                                               (170, SIMD3(248, 145.3, 93)), (200, SIMD3(251, 184, 134))]
        for (k, want) in measured {
            let got = at(s, Float(k) / 255) * 255
            #expect(simd_reduce_max(simd_abs(got - want)) <= 1.5, "\(k): \(got) vs \(want)")
        }
    }

    @Test func smoothMatchesPhotoshop() {
        let measured: [(SIMD3<Float>, SIMD3<Float>, [[Int]])] = [
            (SIMD3(repeating: 0), SIMD3(repeating: 1), [[0, 0, 0], [4, 4, 4], [29, 29, 29], [63, 63, 63], [99, 99, 99], [137, 137, 137], [179, 179, 179], [221, 221, 221]]),
            (SIMD3(1, 0, 0), SIMD3(0, 0, 1), [[255, 0, 0], [232, 51, 67], [202, 71, 105], [171, 81, 136], [140, 83, 162], [109, 80, 188], [76, 69, 213], [41, 49, 236]]),
        ]
        for (a, b, want) in measured {
            let s = GradientBake.bake([ColorStop(0, .rgb(a.x, a.y, a.z)), ColorStop(1, .rgb(b.x, b.y, b.z))], [0.5], 1, .smooth)
            for (k, w) in want.enumerated() {
                let got = at(s, (Float(k * 32) + 0.5) / 256)
                for c in 0 ..< 3 { #expect(abs(Int((got[c] * 255).rounded()) - w[c]) <= 2) }
            }
        }
    }

    @Test func classicLabStopsInterpolateInLab() {
        func lab(_ l: Float, _ a: Float, _ b: Float) -> PCColor { PCColor(mode: .lab, c: SIMD4(l / 100, (a + 128) / 255, (b + 128) / 255, 0)) }
        let s = GradientBake.bake([ColorStop(0, lab(19.07, 52.29, -85.08)), ColorStop(1, lab(54.29, 80.81, 69.91))], [0.5], 0, .classic)
        #expect(s.count > 2 && s.allSatisfy { $0.color.mode == .lab })
        let mid = s.first { abs($0.location - 0.5) < 1e-6 }!.color
        let want = lab(36.68, 66.55, -7.585)
        for i in 0 ..< 3 { #expect(abs(mid.c[i] - want.c[i]) < 1e-4) }
    }

    @Test func midpointShiftsTheHalfWayColour() {
        let s = GradientBake.bake([ColorStop(0, .black), ColorStop(1, .white)], [0.25], 0, .classic)
        #expect(abs(at(s, 0.25).x - 0.5) < 0.01)
    }
}

@Suite struct PixelsTests {
    @Test func interleaveMatchesASequentialReference() {
        func seqInterleave(_ planes: [[UInt8]?], _ fill: [[UInt8]], _ n: Int, _ s: SampleType, _ invert: [Bool]) -> [UInt8] {
            let bps = s.bytes, ch = planes.count
            var out = [UInt8](repeating: 0, count: n * ch * bps)
            for (c, plane) in planes.enumerated() {
                for i in 0 ..< n {
                    let dst = (i * ch + c) * bps
                    if let p = plane, p.count >= (i + 1) * bps {
                        for k in 0 ..< bps { out[dst + k] = p[i * bps + bps - 1 - k] }
                        if invert[c] {
                            out.withUnsafeMutableBytes { PSDPixels.invertSample($0, dst, s) }
                        }
                    } else {
                        for k in 0 ..< bps { out[dst + k] = fill[c][k] }
                    }
                }
            }
            return out
        }
        for n in [1, 7, 64, 1000] {
            for s in SampleType.allCases {
                let bps = s.bytes
                let planes: [[UInt8]] = (0 ..< 4).map { c in (0 ..< n * bps).map { UInt8(truncatingIfNeeded: $0 * 13 + c * 5) } }
                var refs: [[UInt8]?] = planes
                refs[2] = nil
                let fill: [[UInt8]] = (0 ..< 4).map { [UInt8](repeating: UInt8($0 * 40), count: bps) }
                let invert = [false, true, false, true]
                let got = PSDPixels.interleave(refs, fill, n, s, invert)
                #expect(got == seqInterleave(refs, fill, n, s, invert))
                let back = PSDPixels.deinterleave(got, 4, s, invert)
                #expect(back[0] == planes[0])
                if s != .f32 { #expect(back[1] == planes[1]) }
            }
        }
    }

    @Test func missingPlanesUseFill() {
        #expect(PSDPixels.interleave([nil, [5, 6]], [[9], [0]], 2, .u8, [false, false]) == [9, 5, 9, 6])
    }

    @Test func lab16ChromaScaleRoundTrips() {
        var all: [UInt8] = []
        all.reserveCapacity(65536 * 6)
        for v in 0 ... Int(UInt16.max) {
            let b = withUnsafeBytes(of: UInt16(v)) { Array($0) }
            all += b + b + b
        }
        let orig = all
        PSDPixels.lab16Chroma(&all, 3, toDoc: true)
        func px(_ b: [UInt8], _ i: Int, _ c: Int) -> UInt16 { UInt16(b[(i * 3 + c) * 2]) | UInt16(b[(i * 3 + c) * 2 + 1]) << 8 }
        #expect(px(all, 32768, 0) == 32768)
        #expect(px(all, 32768, 1) == UInt16((32768.0 * 65535.0 / 65280.0).rounded()))
        #expect(px(all, 65280, 2) == 65535)
        PSDPixels.lab16Chroma(&all, 3, toDoc: false)
        var ok = true
        for i in 0 ... 65280 where px(all, i, 1) != px(orig, i, 1) { ok = false }
        #expect(ok)
        var short: [UInt8] = [1, 2, 3]
        PSDPixels.lab16Chroma(&short, 3, toDoc: true)
        PSDPixels.lab16Chroma(&short, 1, toDoc: true)
        #expect(short == [1, 2, 3])
    }

    @Test func beCodec() {
        var v: [UInt8] = []
        PSDPixels.encodeBE(1, .u16, &v)
        #expect(v == [0xFF, 0xFF])
        #expect(PSDPixels.decodeBE(v, 0, .u16) == 1)
        var f: [UInt8] = []
        PSDPixels.encodeBE(2.5, .f32, &f)
        #expect(PSDPixels.decodeBE(f, 0, .f32) == 2.5)
    }
}

@Suite struct BlocksTests {
    @Test func gradientFillOpacityStopsRoundTrip() throws {
        let red = PCColor.rgb(1, 0, 0)
        var clear = red
        clear.alpha = 0
        let f = Fill.gradient(GradientFill(stops: [ColorStop(0, red), ColorStop(1, clear)], angle: 90, scale: 1, style: .linear, reverse: false))
        let (k, data) = Blocks.writeFill(f)
        guard case let .gradient(back)? = Blocks.parseFill(k, data) else { Issue.record("gradient"); return }
        #expect(back.opacityStops == [OpacityStop(0, 1), OpacityStop(1, 0)])
        #expect(back.stops.allSatisfy { $0.color.c[0] == 1 && $0.color.c[1] == 0 })
        let (k2, d2) = Blocks.writeFill(.gradient(GradientFill(stops: [ColorStop(0, red), ColorStop(1, .white)], angle: 0, scale: 1, style: .linear, reverse: false)))
        guard case let .gradient(g2)? = Blocks.parseFill(k2, d2) else { Issue.record("gradient"); return }
        #expect(g2.opacityStops.isEmpty)
    }

    @Test func gradientFillReadsTheInterpolationMethod() throws {
        let f = Fill.gradient(GradientFill(stops: [ColorStop(0, .black), ColorStop(1, .white)], angle: 0, scale: 1, style: .linear, reverse: false))
        let (k, data) = Blocks.writeFill(f)
        let d = try #require(Blocks.parsePrefixVersioned(data))
        func baked(_ code: String) -> Bool {
            let dd = d.with("gradientsInterpolationMethod", Blocks.enumValue("gradientInterpolationMethodType", code))
            guard case let .gradient(g)? = Blocks.fillFromDesc(k, dd) else { return false }
            return g.stops.count > 2
        }
        // Classic keeps the stops editable; the other methods bake Photoshop's curve.
        #expect(!baked("Gcls"))
        #expect(baked("Lnr "))
        #expect(baked("Perc"))
        #expect(baked("Smoo"))
    }

    @Test func labDescriptorColoursRoundTrip() throws {
        let d = PSDDescriptor(classID: "LbCl").with("Lmnc", .double(19.07)).with("A   ", .double(52.29)).with("B   ", .double(-85.08))
        let c = try #require(Blocks.colorFromDesc(d))
        #expect(c.mode == .lab)
        #expect(abs(c.c[0] - 0.1907) < 1e-5 && abs(c.c[1] * 255 - 128 - 52.29) < 1e-3 && abs(c.c[2] * 255 - 128 + 85.08) < 1e-3)
        let back = try #require(Blocks.colorFromDesc(Blocks.colorToDesc(c)))
        #expect(back.mode == .lab)
        for i in 0 ..< 3 { #expect(abs(back.c[i] - c.c[i]) < 1e-6) }
        #expect(Blocks.colorFromDesc(PSDDescriptor(classID: "LbCl").with("Lmnc", .double(50))) == nil)
    }

    @Test func blendingRangesMapToBlendIf() {
        #expect(Blocks.blendIfFromRanges(.full(channels: 3)) == BlendIf())
        #expect(Blocks.blendIfFromRanges(PSDBlendingRanges()) == BlendIf())
        var data = PSDBlendingRanges.full(channels: 3).data
        data.replaceSubrange(0 ..< 4, with: [10, 40, 255, 255])
        data.replaceSubrange(3 * 8 + 4 ..< 3 * 8 + 8, with: [0, 0, 200, 200])
        let b = Blocks.blendIfFromRanges(PSDBlendingRanges(data: data))
        #expect(b.get(0) == BlendRangePair(BlendRange(black: SIMD2(10, 40), white: SIMD2(255, 255)), .full))
        #expect(b.get(3) == BlendRangePair(.full, BlendRange(black: SIMD2(0, 0), white: SIMD2(200, 200))))
        #expect(b.ranges.count == 4)
        #expect(Blocks.rangesFromBlendIf(b, 3).data == data)
        #expect(Blocks.rangesFromBlendIf(BlendIf(), 4) == .full(channels: 4))
        var short = BlendIf()
        short.set(0, BlendRangePair(BlendRange(black: SIMD2(5, 5), white: SIMD2(255, 255)), .full))
        let r = Blocks.rangesFromBlendIf(short, 3)
        #expect(r.data.count == 4 * 8)
        #expect(Array(r.data[..<8]) == [5, 5, 255, 255, 0, 0, 255, 255])
        #expect(Array(r.data[8...]) == PSDBlendingRanges.full(channels: 2).data)
    }

    @Test func advancedBlendingBlocksRoundTrip() {
        let a = AdvancedBlending(knockout: .deep, blendInterior: true, blendClipped: false, transparencyShapes: false,
                                 layerMaskHidesEffects: true, vectorMaskHidesEffects: true)
        var raw: RawBlocks = []
        Blocks.putAdvanced(a, &raw)
        #expect(raw.count == 6)
        #expect(raw.contains { $0.key == "knko" && $0.data == [2, 0, 0, 0] })
        #expect(raw.contains { $0.key == "clbl" && $0.data == [0, 0, 0, 0] })
        #expect(Blocks.advancedFromBlocks { k in raw.first { $0.key == k }?.data } == a)
        var plain: RawBlocks = []
        Blocks.putAdvanced(AdvancedBlending(), &plain)
        #expect(plain.isEmpty)
        var kept: RawBlocks = [("luni", [0, 0, 0, 0]), ("knko", [1, 0, 0, 0]), ("clbl", [1])]
        Blocks.putAdvanced(AdvancedBlending(), &kept)
        #expect(kept.map(\.key) == ["luni", "knko", "clbl"])
        #expect(kept[1].data == [0, 0, 0, 0] && kept[2].data == [1, 0, 0, 0])
        #expect(Blocks.advancedFromBlocks { _ in nil }.isDefault)
        #expect(Blocks.advancedFromBlocks { _ in [] }.isDefault)
        #expect(Blocks.advancedFromBlocks { $0 == "knko" ? [1] : nil }.knockout == .shallow)
    }

    @Test func brstRoundTrip() {
        #expect(Blocks.parseBrst([0, 0, 0, 2]) == 0b100)
        #expect(Blocks.parseBrst([0, 0, 0, 0, 0, 0, 0, 1]) == 0b11)
        #expect(Blocks.brstData(0b101) == [0, 0, 0, 0, 0, 0, 0, 2])
        #expect(Blocks.brstData(0) == nil)
    }

    private func sold(_ d: PSDDescriptor) -> [UInt8] {
        var v = Array("soLD".utf8) + [0, 0, 0, 4]
        v += Blocks.versionedBytes(d)
        return v
    }

    @Test func placedLayerWarpIsRead() throws {
        let bounds = PSDDescriptor(classID: "Rctn").with("Top ", Blocks.unit("#Pxl", 0)).with("Left", Blocks.unit("#Pxl", 0))
            .with("Btom", Blocks.unit("#Pxl", 30)).with("Rght", Blocks.unit("#Pxl", 60))
        let arc = PSDDescriptor(classID: "warp").with("warpStyle", Blocks.enumValue("warpStyle", "warpArc")).with("warpValue", .double(40))
            .with("warpPerspective", .double(0)).with("warpPerspectiveOther", .double(0)).with("warpRotate", Blocks.enumValue("Ornt", "Hrzn"))
            .with("bounds", .descriptor(bounds))
        let w = try #require(Blocks.parsePlacedWarp("SoLd", sold(PSDDescriptor(classID: "null").with("warp", .descriptor(arc)))))
        #expect(w.style == .arc && w.bend == 40 && w.bounds == SIMD4(0, 0, 60, 30))
        var xs: [Double] = [], ys: [Double] = []
        for j in 0 ..< 4 { for i in 0 ..< 4 { xs.append(Double(i) * 20 + (i == 3 && j == 3 ? 7 : 0)); ys.append(Double(j) * 10) } }
        let mesh = PSDDescriptor(classID: "null").with("Hrzn", .unitFloats(unit: "#Pxl", values: xs)).with("Vrtc", .unitFloats(unit: "#Pxl", values: ys))
        let custom = PSDDescriptor(classID: "warp").with("warpStyle", Blocks.enumValue("warpStyle", "warpCustom")).with("bounds", .descriptor(bounds))
            .with("customEnvelopeWarp", .descriptor(PSDDescriptor(classID: "customEnvelopeWarp").with("meshPoints", .objectArray(.init(prefix: 16, body: mesh)))))
        let cw = try #require(Blocks.parsePlacedWarp("SoLd", sold(PSDDescriptor(classID: "null").with("warp", .descriptor(custom)))))
        #expect(cw.style == .custom)
        #expect(cw.mesh?.points[15] == SIMD2(67, 30))
        #expect(Blocks.parsePlacedWarp("PlLd", [UInt8](repeating: 0, count: 20)) == nil)
    }

    @Test func locksAndLabels() {
        for bits: UInt32 in [0, 1, 2, 4, 8, 0x0D, 0x8000_0000, 0x8000_000F] { #expect(Blocks.lspfFromLocks(Blocks.locksFromLspf(bits)) == bits) }
        #expect(Blocks.locksFromLspf(0x10).artboard)
        #expect(Blocks.lspfFromLocks(Blocks.locksFromLspf(0x10)) == 0x08)
        for i: UInt16 in 0 ..< 8 { #expect(Blocks.labelIndex(Blocks.labelFromIndex(i)) == i) }
    }

    @Test func fillsRoundTrip() {
        let fills: [Fill] = [
            .solid(.rgb(1, 0.5, 0)),
            .solid(PCColor(mode: .cmyk, c: SIMD4(0.1, 0.2, 0.3, 0.4))),
            .solid(.gray(0.25)),
            .gradient(GradientFill(stops: [ColorStop(0, .rgb(1, 0, 0)), ColorStop(1, .rgb(0, 0, 1))], angle: 45, scale: 1, style: .reflected, reverse: true)),
            .gradient(GradientFill(stops: [ColorStop(0, .rgb(1, 0, 0)), ColorStop(0.5, .rgb(0, 1, 0)), ColorStop(1, .rgb(0, 0, 1))], angle: -33.5,
                                   scale: 2.25, style: .radial, reverse: false, opacityStops: [OpacityStop(0, 1), OpacityStop(0.25, 0.5), OpacityStop(1, 0)],
                                   midpoints: [0.25, 0.75], offset: SIMD2(0.125, -0.375), dither: true, align: false)),
            .pattern(PatternFill(name: "Bubbles", scale: 0.5, id: "abc", angle: 30, link: false, phase: SIMD2(3, -2))),
        ]
        for f in fills {
            let (k, d) = Blocks.writeFill(f)
            let back = Blocks.parseFill(k, d)
            if case let .solid(a) = f, case let .solid(b)? = back {
                #expect(a.mode == b.mode)
                for i in 0 ..< 4 { #expect(abs(a.c[i] - b.c[i]) < 1e-5) }
            } else {
                #expect(back == f)
            }
        }
    }

    @Test func floatRGBColoursParse() throws {
        let d = PSDDescriptor(classID: "RGBC").with("redFloat", .double(1)).with("greenFloat", .double(0.5)).with("blueFloat", .double(0.25))
        #expect(try #require(Blocks.colorFromDesc(d)).rgb == SIMD3(1, 0.5, 0.25))
    }

    private func soldWithWarp(_ trnf: [Double], _ pts: [SIMD2<Double>]?) -> [UInt8] {
        var d = PSDDescriptor(classID: "null").with("Idnt", Blocks.text("uuid-1")).with("Trnf", .list(trnf.map { .double($0) }))
            .with("Sz  ", .descriptor(PSDDescriptor(classID: "Pnt ").with("Wdth", .double(50)).with("Hght", .double(25))))
        if let pts {
            let bounds = PSDDescriptor(classID: "Rctn").with("Top ", .double(0)).with("Left", .double(0)).with("Btom", .double(25)).with("Rght", .double(50))
            let mesh = PSDDescriptor(classID: "null").with("Hrzn", .unitFloats(unit: "#Pxl", values: pts.map(\.x)))
                .with("Vrtc", .unitFloats(unit: "#Pxl", values: pts.map(\.y)))
            let warp = PSDDescriptor(classID: "warp").with("warpStyle", Blocks.enumValue("warpStyle", "warpCustom")).with("bounds", .descriptor(bounds))
                .with("customEnvelopeWarp", .descriptor(PSDDescriptor(classID: "customEnvelopeWarp").with("meshPoints", .objectArray(.init(prefix: 16, body: mesh)))))
            d = d.with("warp", .descriptor(warp))
        }
        return sold(d)
    }

    @Test func smartTransformFromSold() {
        let d = PSDDescriptor(classID: "null").with("Idnt", Blocks.text("uuid-1"))
            .with("Trnf", .list([10, 20, 110, 20, 110, 70, 10, 70].map { .double($0) }))
            .with("Sz  ", .descriptor(PSDDescriptor(classID: "Pnt ").with("Wdth", .double(50)).with("Hght", .double(25))))
        let data = sold(d) + [0, 0]
        let (id, a) = Blocks.parseSmart("SoLd", data)
        #expect(id == "uuid-1")
        #expect(a.m == [2, 0, 0, 2, 10, 20])
        #expect(Blocks.parseSmart("PlLd", data).id == "")
    }

    @Test func smartTransformMapsTheWarpControlBoxOntoTheQuad() {
        var pts = BezierMesh.identity(bounds: SIMD4(0, 0, 50, 25), cols: 1, rows: 1).points
        pts[0] = SIMD2(-10, -5)
        pts[15] = SIMD2(60, 25)
        let quad: [Double] = [100, 200, 240, 200, 240, 260, 100, 260]
        #expect(Blocks.parseSmart("SoLd", soldWithWarp(quad, pts)).transform.m == [2, 0, 0, 2, 120, 210])
        #expect(Blocks.parseSmart("SoLd", soldWithWarp(quad, nil)).transform.m == [2.8, 0, 0, 2.4, 100, 200])
    }

    @Test func smartTransformWithADegenerateWarpBoxUsesTheSourceRect() {
        let quad: [Double] = [100, 200, 240, 200, 240, 260, 100, 260]
        #expect(Blocks.parseSmart("SoLd", soldWithWarp(quad, Array(repeating: SIMD2(7, 7), count: 16))).transform.m == [2.8, 0, 0, 2.4, 100, 200])
        var warp = Warp.preset(.custom, bend: 0, bounds: SIMD4(0, 0, 50, 25))
        warp.mesh = BezierMesh(us: [0, 1], vs: [0, 1], points: Array(repeating: SIMD2(.nan, 1), count: 16))
        #expect(Blocks.placedFrame(warp, 50, 25) == SIMD4(0, 0, 50, 25))
        #expect(Blocks.placedFrame(nil, 50, 25) == SIMD4(0, 0, 50, 25))
    }

    @Test func effectsSwitch() {
        let lfx = [UInt8](repeating: 0, count: 4) + Blocks.versionedBytes(PSDDescriptor(classID: "null").with("masterFXSwitch", .boolean(false)))
        #expect(!Blocks.effectsEnabled(lfx))
        #expect(Blocks.effectsEnabled([0, 0, 0, 0]))
    }

    @Test func tyshGarbageIsNil() {
        #expect(Blocks.parseTySh([UInt8](repeating: 0, count: 10)) == nil)
    }

    @Test func perspectivePlacementIsProjective() throws {
        let d = PSDDescriptor(classID: "null").with("Idnt", Blocks.text("p"))
            .with("Trnf", .list([0, 0, 100, 10, 90, 90, 10, 100].map { .double($0) }))
            .with("Sz  ", .descriptor(PSDDescriptor(classID: "Pnt ").with("Wdth", .double(50)).with("Hght", .double(50))))
        let m = try #require(Blocks.parseSmartPerspective("SoLd", sold(d)))
        let h = Homography(m)
        let p = h.apply(50, 50)
        #expect(abs(p.x - 90) < 1e-9 && abs(p.y - 90) < 1e-9)
        let affine = PSDDescriptor(classID: "null").with("Trnf", .list([0, 0, 100, 0, 100, 100, 0, 100].map { .double($0) }))
            .with("Sz  ", .descriptor(PSDDescriptor(classID: "Pnt ").with("Wdth", .double(50)).with("Hght", .double(50))))
        #expect(Blocks.parseSmartPerspective("SoLd", sold(affine)) == nil)
    }
}
