// Ports photocraft-cms's integration tests (crates/cms/tests/cms.rs) onto ColorSync. Tolerances are
// photocraft's where ColorSync meets them; every measured value is printed with a `MEASURE` prefix
// so PORT-NOTES can record it. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import Foundation
import simd
import Metal
import PCFoundation
import Testing
@testable import PCPlatform

private var srgb: ICCProfile { BuiltinProfile.srgb.profile }
private var lab: ICCProfile { BuiltinProfile.labD50.profile }
private var cmyk: ICCProfile { BuiltinProfile.coatedCMYK.profile }

private func toLab(_ p: ICCProfile, _ dev: [Float], _ intent: RenderingIntent = .relativeColorimetric) throws -> SIMD3<Double> {
    try ColorMath.lab(dev, in: p, intent: intent)
}

func measure(_ s: String) { print("MEASURE \(s)") }

@Suite("Colour (ColorSync replaces photocraft-cms)")
struct ColorTests {
    @Test func builtinsLoadDescribeAndReparse() throws {
        for b in BuiltinProfile.allCases {
            let p = b.profile
            #expect(!p.profileDescription.isEmpty, "\(b)")
            let q = try ICCProfile(data: p.data)
            #expect(q.data == p.data, "\(b) bytes are kept verbatim")
            #expect(q.colorSpace == p.colorSpace)
            #expect(BuiltinProfile.from(id: b.id) == b)
            _ = try ColorTransform(source: p, destination: lab)
            _ = try ColorTransform(source: lab, destination: p)
            measure("builtin \(b.id): \(p.profileDescription) [\(p.colorSpace)] v\(p.version.major).\(p.version.minor) \(p.data.count) B — \(b.source)")
        }
        #expect(BuiltinProfile.from(id: "Adobe RGB (1998)") == .adobeRGB)
        #expect(BuiltinProfile.srgb.profile.colorSpace == .rgb)
        #expect(BuiltinProfile.sGray.profile.colorSpace == .gray)
        #expect(BuiltinProfile.coatedCMYK.profile.colorSpace == .cmyk)
        #expect(BuiltinProfile.coatedCMYK.profile.profileDescription.contains("Coated"))
    }

    @Test func srgbKnownLabValues() throws {
        let w = try toLab(srgb, [1, 1, 1])
        #expect(abs(w.x - 100) < 0.01 && abs(w.y) < 0.01 && abs(w.z) < 0.01, "white \(w)")
        let k = try toLab(srgb, [0, 0, 0])
        #expect(abs(k.x) < 0.01, "black \(k)")
        let r = try toLab(srgb, [1, 0, 0]), g = try toLab(srgb, [0, 1, 0]), b = try toLab(srgb, [0, 0, 1])
        let dr = ColorMath.deltaE76(r, SIMD3(54.29, 80.80, 69.89))
        let dg = ColorMath.deltaE76(g, SIMD3(87.82, -79.29, 80.99))
        let db = ColorMath.deltaE76(b, SIMD3(29.57, 68.30, -112.03))
        measure("sRGB primaries → Lab D50 ΔE76 vs photocraft expectations: red \(dr) green \(dg) blue \(db) (photocraft tolerance 0.15/0.3/0.3)")
        #expect(dr < 0.15, "red \(r)")
        #expect(dg < 0.3, "green \(g)")
        #expect(db < 0.3, "blue \(b)")
        var worstGray = 0.0
        for bi in [BuiltinProfile.srgb, .displayP3, .adobeRGB, .proPhoto, .linearSRGB, .rec2020] {
            let m = try toLab(bi.profile, [0.5, 0.5, 0.5])
            worstGray = max(worstGray, max(abs(m.y), abs(m.z)))
            #expect(abs(m.y) < 0.02 && abs(m.z) < 0.02, "\(bi) gray \(m)")
        }
        measure("RGB built-ins 50% gray worst |a*|,|b*| = \(worstGray) (photocraft tolerance 0.02)")
    }

    @Test func rgbLabRgbRoundTripFloatAnd16Bit() throws {
        let to = try ColorTransform(source: srgb, destination: lab)
        let back = try ColorTransform(source: lab, destination: srgb)
        var src8: [UInt8] = []
        for r in stride(from: 0, to: 256, by: 5) { for g in stride(from: 0, to: 256, by: 7) { for b in stride(from: 0, to: 256, by: 9) {
            src8 += [UInt8(r), UInt8(g), UInt8(b)]
        } } }
        let n = src8.count / 3
        let f = src8.map { Float($0) / 255 }
        let labF = to.convert(f, pixelCount: n)
        let rgbF = back.convert(labF, pixelCount: n)
        var worst8: Float = 0, worstF: Float = 0
        for i in 0..<f.count {
            worst8 = max(worst8, abs(Float(src8[i]) - rgbF[i] * 255))
            worstF = max(worstF, abs(f[i] - rgbF[i]))
        }
        measure("sRGB→Lab→sRGB float round trip: max \(worstF) (photocraft < 1e-4), max in 8-bit levels \(worst8) (photocraft ≤ 1)")
        #expect(worst8 <= 1)
        #expect(worstF < 1e-3)
        // 8-bit RGB → 8-bit sRGB through ColorSync's integer path vs the float path.
        let r8 = RasterBuffer(width: n, height: 1, format: PixelFormat(mode: .rgb, sample: .u8, alpha: false), bytes: src8)
        let ident = try ColorTransform(source: srgb, destination: BuiltinProfile.adobeRGB.profile)
        let viaInt = try ident.convert(r8)
        let viaFloat = ident.convert(f, pixelCount: n)
        var worstPath: Float = 0
        for i in 0..<f.count { worstPath = max(worstPath, abs(Float(viaInt.bytes[i]) - min(max(viaFloat[i], 0), 1) * 255)) }
        measure("sRGB→Adobe RGB 8-bit integer path vs float eval: max \(worstPath) levels (photocraft ≤ 0.6 for its own integer tables)")
        #expect(worstPath <= 1.0)
    }

    @Test func rgbToRGBMatrixShaperIntegerPathsAgree() throws {
        var worst: [String: Float] = [:]
        for dst in [BuiltinProfile.adobeRGB, .proPhoto, .displayP3, .linearSRGB] {
            let t = try ColorTransform(source: srgb, destination: dst.profile)
            let src: [UInt8] = (0...255).flatMap { v in [UInt8(v), UInt8(v / 2), UInt8(255 - v)] }
            let out = try t.convert(RasterBuffer(width: 256, height: 1, format: PixelFormat(mode: .rgb, sample: .u8, alpha: false), bytes: src))
            var w: Float = 0
            for i in 0..<256 {
                let e = t.eval([Float(src[i * 3]) / 255, Float(src[i * 3 + 1]) / 255, Float(src[i * 3 + 2]) / 255])
                for k in 0..<3 { w = max(w, abs(Float(out.bytes[i * 3 + k]) - min(max(e[k], 0), 1) * 255)) }
            }
            worst[dst.id] = w
            #expect(w <= 1.0, "\(dst)")
        }
        measure("8-bit integer vs float, sRGB → matrix/TRC destinations (levels): \(worst.sorted { $0.key < $1.key }) (photocraft ≤ 0.6)")
    }

    @Test func identityTransformIsIdentityWithAlphaCopied() throws {
        let t = try ColorTransform(source: srgb, destination: srgb, intent: .relativeColorimetric, blackPointCompensation: true)
        let src: [UInt8] = (0...255).flatMap { v in [UInt8(v), UInt8(255 - v), UInt8(v / 3), 77] }
        let out = try t.convert(RasterBuffer(width: 256, height: 1, format: .rgba8, bytes: src))
        let diff = zip(src, out.bytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
        measure("sRGB→sRGB 8-bit identity max diff \(diff) (photocraft: exact)")
        #expect(diff <= 1)
        #expect((0..<256).allSatisfy { out.bytes[$0 * 4 + 3] == 77 }, "alpha copied")
    }

    @Test func cmykProfileIsMonotonicAndInRange() throws {
        for ink in 0..<4 {
            var prev = Double.infinity
            for i in 0...32 {
                var v: [Float] = [0.1, 0.1, 0.1, 0.1]
                v[ink] = Float(i) / 32
                let l = try toLab(cmyk, v).x
                #expect(l <= prev + 0.05, "ink \(ink) at \(i): \(l) > \(prev)")
                prev = l
            }
        }
        let w = try toLab(cmyk, [0, 0, 0, 0])
        measure("coated CMYK paper (relative) Lab \(w): ΔE vs (100,0,0) = \(ColorMath.deltaE76(w, SIMD3(100, 0, 0))) (photocraft < 0.5)")
        #expect(ColorMath.deltaE76(w, SIMD3(100, 0, 0)) < 0.5)
        var worstNeutral = 0.0, worstTAC: Float = 0
        for intent in [RenderingIntent.perceptual, .relativeColorimetric] {
            let t = try ColorTransform(source: srgb, destination: cmyk, intent: intent, blackPointCompensation: true)
            let back = try ColorTransform(source: cmyk, destination: lab)
            var prevK: Float = -1, prevL = Double.infinity
            for v in stride(from: 255, through: 0, by: -5) {
                let g = Float(v) / 255
                let o = t.eval([g, g, g])
                #expect(o.allSatisfy { $0 >= -1e-6 && $0 <= 1 + 1e-6 }, "\(o)")
                worstTAC = max(worstTAC, o.reduce(0, +))
                #expect(o.reduce(0, +) <= 3.02, "TAC \(o)")
                #expect(o[3] >= prevK - 0.01, "\(intent) K not monotonic at \(v): \(o)")
                prevK = o[3]
                let l = back.eval(o)
                let lv = LabEncoding.colorSync.decode(SIMD3(l[0], l[1], l[2]))
                #expect(lv.x <= prevL + 0.3, "\(intent) L* not monotonic at \(v)")
                worstNeutral = max(worstNeutral, max(abs(lv.y), abs(lv.z)))
                #expect(abs(lv.y) < 3 && abs(lv.z) < 3, "\(intent) gray \(v) not neutral: \(lv)")
                prevL = lv.x
            }
        }
        measure("sRGB gray ramp → coated CMYK: max TAC \(worstTAC) (limit 3.0), worst |a*|,|b*| \(worstNeutral) (photocraft < 3)")
    }

    @Test func inGamutColoursSurviveCMYKRoundTrip() throws {
        var worst = 0.0
        for target in [SIMD3<Double>(50, 0, 0), SIMD3(70, 10, 10), SIMD3(60, -20, -20), SIMD3(80, 0, 40), SIMD3(40, 30, -10)] {
            let c = try ColorMath.device(fromLab: target, in: cmyk)
            let back = try toLab(cmyk, c)
            worst = max(worst, ColorMath.deltaE76(back, target))
            #expect(ColorMath.deltaE76(back, target) < 2, "\(target) → \(c) → \(back)")
        }
        measure("Lab → coated CMYK → Lab in-gamut worst ΔE76 \(worst) (photocraft < 2)")
    }

    @Test func intentsDifferAsExpected() throws {
        let per = try ColorTransform(source: srgb, destination: cmyk, intent: .perceptual)
        let rel = try ColorTransform(source: srgb, destination: cmyk, intent: .relativeColorimetric)
        let sat = try ColorTransform(source: srgb, destination: cmyk, intent: .saturation)
        let a = per.eval([0, 0.2, 1]), b = rel.eval([0, 0.2, 1]), s = sat.eval([0, 0.2, 1])
        let d = zip(a, b).map { abs($0 - $1) }.reduce(0, +)
        measure("out-of-gamut blue → CMYK: perceptual \(a) relative \(b) saturation \(s), Σ|Δ| = \(d) (photocraft > 0.03)")
        #expect(d > 0.03)
        let relW = try ColorTransform(source: cmyk, destination: srgb, intent: .relativeColorimetric).eval([0, 0, 0, 0])
        let absW = try ColorTransform(source: cmyk, destination: srgb, intent: .absoluteColorimetric).eval([0, 0, 0, 0])
        #expect(relW.allSatisfy { $0 > 0.995 }, "\(relW)")
        #expect(absW[0] < 0.97 && absW[2] > absW[0], "\(absW)")
        let paper = try toLab(cmyk, [0, 0, 0, 0], .absoluteColorimetric)
        measure("coated CMYK paper absolute Lab \(paper): ΔE vs (95,0,−2) = \(ColorMath.deltaE76(paper, SIMD3(95, 0, -2))) (photocraft < 0.6); relative white in sRGB \(relW), absolute \(absW)")
        #expect(ColorMath.deltaE76(paper, SIMD3(95, 0, -2)) < 0.6)
    }

    /// sRGB bytes with the `wtpt` XYZ replaced.
    private func srgbWithWtpt(_ xyz: [Int32]) throws -> ICCProfile {
        var b = [UInt8](srgb.data)
        func be32(_ at: Int) -> Int { Int(UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])) }
        let count = be32(128)
        let rec = try #require((0..<count).map { 132 + 12 * $0 }.first { String(decoding: b[$0..<$0 + 4], as: UTF8.self) == "wtpt" })
        let off = be32(rec + 4)
        for (i, v) in xyz.enumerated() {
            let u = UInt32(bitPattern: v)
            for k in 0..<4 { b[off + 8 + 4 * i + k] = UInt8((u >> (24 - 8 * UInt32(k))) & 0xFF) }
        }
        return try ICCProfile(data: Data(b))
    }

    @Test func absoluteColorimetricRefusesADegenerateMediaWhite() throws {
        let zero = try srgbWithWtpt([0, 0, 0])
        #expect(zero.mediaWhitePoint == SIMD3(0, 0, 0))
        let negative = try srgbWithWtpt([-0x10000, 0x10000, 0x10000])
        for bad in [zero, negative] {
            #expect(throws: PlatformError.self) { try ColorTransform(source: srgb, destination: bad, intent: .absoluteColorimetric) }
            #expect(throws: PlatformError.self) { try ColorTransform(source: bad, destination: srgb, intent: .absoluteColorimetric) }
            #expect(throws: PlatformError.self) { try ColorTransform.proof(source: srgb, proof: bad, display: srgb, simulatePaper: true) }
            let t = try ColorTransform.proof(source: srgb, proof: bad, display: srgb, simulatePaper: false)
            #expect(t.eval([0.2, 0.4, 0.6]).allSatisfy { $0.isFinite })
            let r = try ColorTransform(source: srgb, destination: bad, intent: .relativeColorimetric)
            #expect(r.eval([0.2, 0.4, 0.6]).allSatisfy { $0.isFinite })
        }
        let d50 = try srgbWithWtpt([0xF6D6, 0x10000, 0xD32D])
        let t = try ColorTransform(source: srgb, destination: d50, intent: .absoluteColorimetric)
        #expect(t.eval([0.2, 0.4, 0.6]).allSatisfy { $0.isFinite })
    }

    @Test func blackPointCompensation() throws {
        let bp = try ColorMath.blackPoint(cmyk)
        let bl = ColorMath.xyzToLab(SIMD3(bp * 0.9642, bp, bp * 0.8249)).x
        measure("coated CMYK black point L* \(bl) (photocraft 4…20); sRGB black point Y \(try ColorMath.blackPoint(srgb))")
        #expect(bl > 4 && bl < 20)
        #expect(try ColorMath.blackPoint(srgb) < 1e-3)
        let with = try ColorTransform(source: srgb, destination: cmyk, intent: .relativeColorimetric, blackPointCompensation: true)
        let without = try ColorTransform(source: srgb, destination: cmyk, intent: .relativeColorimetric, blackPointCompensation: false)
        let back = try ColorTransform(source: cmyk, destination: lab)
        func lOf(_ t: ColorTransform, _ v: Float) -> Double {
            let c = t.eval([v, v, v]); let l = back.eval(c)
            return LabEncoding.colorSync.decode(SIMD3(l[0], l[1], l[2])).x
        }
        let (w0, w1) = (lOf(with, 0), lOf(with, 0.08)), (n0, n1) = (lOf(without, 0), lOf(without, 0.08))
        measure("BPC sRGB→CMYK shadows: with BPC L*(0)=\(w0) L*(0.08)=\(w1); without \(n0) \(n1) (photocraft: with-BPC gap > 1.5 and > without)")
        #expect(w1 - w0 > 1.5)
        #expect(abs(n1 - n0) < w1 - w0)
        let dark = with.eval([0, 0, 0])
        let a = try ColorTransform(source: cmyk, destination: srgb, intent: .relativeColorimetric, blackPointCompensation: true).eval(dark)
        let b = try ColorTransform(source: cmyk, destination: srgb, intent: .relativeColorimetric, blackPointCompensation: false).eval(dark)
        measure("darkest CMYK → sRGB: with BPC \(a), without \(b) (photocraft: with G < 0.03, without > with + 0.03)")
        #expect(a[1] < 0.03 && b[1] > a[1] + 0.03)
    }

    @Test func proofAndDisplayLUT() throws {
        let p = try ColorTransform.proof(source: srgb, proof: cmyk, display: srgb)
        var o = p.eval([0.5, 0.5, 0.5])
        #expect(abs(o[0] - o[1]) < 0.02 && abs(o[1] - o[2]) < 0.03, "\(o)")
        o = p.eval([0, 0, 1])
        #expect(o[0] > 0.1 || o[1] > 0.1, "\(o)")
        let sim = try ColorTransform.proof(source: srgb, proof: cmyk, display: srgb, simulatePaper: true)
        let white = sim.eval([1, 1, 1])
        measure("proof sRGB→coated CMYK→sRGB: gray \(p.eval([0.5, 0.5, 0.5])), blue \(o), paper-simulated white \(white) (photocraft white R < 0.97)")
        #expect(white[0] < 0.97)

        let t = try ColorTransform(source: srgb, destination: BuiltinProfile.displayP3.profile)
        let lut = try DisplayLUT(transform: t, size: 33)
        #expect(lut.rgba16fBytes().count == 33 * 33 * 33 * 8)
        var worst: Float = 0
        for i in 0..<500 {
            let c = SIMD3(Float(i * 7 % 101) / 100, Float(i * 13 % 101) / 100, Float(i * 29 % 101) / 100)
            let e = t.eval([c.x, c.y, c.z])
            let s = lut.sample(c)
            for k in 0..<3 { worst = max(worst, abs(s[k] - e[k])) }
        }
        measure("33³ display LUT sRGB→P3 trilinear vs exact: max \(worst * 255) /255 (photocraft < 2/255)")
        #expect(worst < 2.0 / 255)
        #expect(try DisplayLUT.canvas(document: srgb, monitor: srgb) == nil, "no LUT for sRGB on sRGB")
        let warn = try #require(try DisplayLUT.canvas(document: srgb, monitor: srgb, proof: ProofSettings(profile: cmyk), gamutWarningColor: SIMD3(0.5, 0.5, 0.5)))
        #expect(warn.sample(SIMD3(0, 0, 1)) == SIMD3(0.5, 0.5, 0.5), "pure blue shows the warning gray")
        if let dev = MTLCreateSystemDefaultDevice() {
            let tex = try #require(lut.makeTexture(device: dev))
            #expect(tex.textureType == .type3D && tex.width == 33 && tex.depth == 33)
        }
    }

    @Test func grayProfiles() throws {
        let t = try ColorTransform(source: BuiltinProfile.sGray.profile, destination: srgb)
        var worst: Float = 0
        for v: Float in [0, 0.2, 0.5, 0.9, 1] {
            for c in t.eval([v]) { worst = max(worst, abs(c - v)) }
        }
        measure("sGray → sRGB max deviation \(worst) (photocraft < 1e-3)")
        #expect(worst < 2e-3)
        let g = try ColorTransform(source: srgb, destination: BuiltinProfile.grayGamma22.profile)
        #expect(abs(g.eval([1, 1, 1])[0] - 1) < 1e-3)
        #expect(abs(g.eval([0, 0, 0])[0]) < 1e-3)
        // Dot Gain 20 %: 50 % ink is darker than an ideal (no-gain) dot would be (L* 76.07).
        let l50 = try toLab(BuiltinProfile.dotGain20.profile, [0.5]).x
        measure("Dot Gain 20% (parabolic TVI, ideal ink): 50% gray L* \(l50)")
        #expect(l50 < 70 && l50 > 55)
    }

    @Test func hdrFloatsSurviveMatrixTransforms() throws {
        let lin = BuiltinProfile.linearSRGB.profile
        let to = try ColorTransform(source: lin, destination: BuiltinProfile.rec2020.profile,
                                    options: .init(intent: .relativeColorimetric, extendedRange: true))
        let back = try ColorTransform(source: BuiltinProfile.rec2020.profile, destination: lin,
                                      options: .init(intent: .relativeColorimetric, extendedRange: true))
        let src: [Float] = [4, 2, 0.5]
        let mid = to.eval(src), out = back.eval(mid)
        let err = zip(src, out).map { abs($0 - $1) / max($0, 1) }.max()!
        measure("HDR linear sRGB (4, 2, 0.5) → Rec.2020 → back: \(mid) → \(out), rel err \(err) (photocraft < 1e-3)")
        #expect(err < 1e-2)
    }

    @Test func malformedProfilesAreRejectedWithoutCrashing() {
        #expect(throws: PlatformError.self) { try ICCProfile(data: Data()) }
        #expect(throws: PlatformError.self) { try ICCProfile(data: Data(count: 200)) }
        let good = srgb.data
        for cut in [100, 131, 140, 200, good.count - 20] { _ = try? ICCProfile(data: good.prefix(cut)) }
        var bad = [UInt8](good)
        for i in stride(from: 128, to: bad.count, by: 7) {
            bad[i] ^= 0x5A
            _ = try? ICCProfile(data: Data(bad))
        }
        var c = [UInt8](cmyk.data)
        for i in stride(from: 128, to: 400, by: 3) {
            c[i] = 0xFF
            if let p = try? ICCProfile(data: Data(c)) { _ = try? ColorTransform(source: p, destination: srgb, intent: .perceptual, blackPointCompensation: true) }
        }
    }

    @Test func systemProfiles() throws {
        var seen = 0
        for dir in ["/System/Library/ColorSync/Profiles", "/Library/ColorSync/Profiles"] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.lowercased().hasSuffix(".icc") || name.lowercased().hasSuffix(".icm") {
                let p = try ICCProfile(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name))
                seen += 1
                guard [ProfileClass.input, .display, .output, .colorSpace].contains(p.deviceClass) else { continue }
                #expect(!p.profileDescription.isEmpty, "\(name)")
                guard [ProfileColorSpace.rgb, .gray, .cmyk, .lab].contains(p.colorSpace) else { continue }
                for intent in RenderingIntent.allCases {
                    let o = try ColorTransform(source: p, destination: lab, intent: intent, blackPointCompensation: true)
                        .eval([Float](repeating: 0.5, count: p.channels))
                    #expect(o.allSatisfy { $0.isFinite }, "\(name)")
                }
                if p.colorSpace == .rgb {
                    let w = try toLab(p, [1, 1, 1])
                    #expect(abs(w.x - 100) < 1.5, "\(name) white \(w)")
                }
                if p.colorSpace == .cmyk {
                    let w = try toLab(p, [0, 0, 0, 0]), k = try toLab(p, [0, 0, 0, 1])
                    #expect(w.x > 90 && k.x < w.x, "\(name): \(w) \(k)")
                }
            }
        }
        measure("parsed \(seen) system profiles through ColorSync")
        #expect(seen > 5)
    }

    @Test func sameColorsAndRenderingIntentParsing() throws {
        let cg = try #require(ICCProfile(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        #expect(cg.sameColors(as: srgb))
        #expect(!srgb.sameColors(as: BuiltinProfile.displayP3.profile))
        #expect(RenderingIntent(parsing: "Relative Colorimetric") == .relativeColorimetric)
        #expect(RenderingIntent(parsing: "absolute") == .absoluteColorimetric)
        #expect(RenderingIntent(parsing: "2") == .saturation)
        #expect(RenderingIntent(parsing: "bogus") == nil)
    }

    @Test func cmykConverterInstallsAndInterpolatesCloseToColorSync() throws {
        let conv = try ColorManagement.install()
        #expect(ColorManagement.installed != nil)
        var worstToRGB: Float = 0, worstToCMYK: Float = 0, sumToRGB: Float = 0, sumToCMYK: Float = 0
        var seed: UInt32 = 12345
        func rnd() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed >> 8) / Float(1 << 24) }
        let n = 4000
        for _ in 0..<n {
            let c = SIMD4<Float>(rnd(), rnd(), rnd(), rnd())
            let a = abs(conv.cmykToRGB(c) - simd_clamp(conv.exactCMYKToRGB(c), .zero, .one)).max()
            worstToRGB = max(worstToRGB, a); sumToRGB += a
            let r = SIMD3<Float>(rnd(), rnd(), rnd())
            let b = abs(conv.rgbToCMYK(r) - simd_clamp(conv.exactRGBToCMYK(r), .zero, .one)).max()
            worstToCMYK = max(worstToCMYK, b); sumToCMYK += b
        }
        measure("ColorConvert.cmyk grid interpolation vs exact ColorSync over \(n) random colours: CMYK→sRGB (17⁴) mean \(sumToRGB / Float(n) * 255)/255 max \(worstToRGB * 255)/255; sRGB→CMYK (33³) mean \(sumToCMYK / Float(n) * 255)/255 max \(worstToCMYK * 255)/255 (maxima sit on gamut-clipping kinks)")
        #expect(sumToRGB / Float(n) < 0.5 / 255 && worstToRGB < 8.0 / 255)
        #expect(sumToCMYK / Float(n) < 1.0 / 255 && worstToCMYK < 20.0 / 255)
        // The batch path (PCFoundation `CMYKConverter.cmykToRGB(batch:)`) is one exact ColorSync call,
        // and `Surface.readRGBA` uses it for CMYK.
        let colours = (0..<500).map { _ in SIMD4<Float>(rnd(), rnd(), rnd(), rnd()) }
        let batch = conv.cmykToRGB(batch: colours)
        let exactMax = zip(batch, colours).map { abs($0 - simd_clamp(conv.exactCMYKToRGB($1), .zero, .one)).max() }.max()!
        #expect(exactMax < 1e-5)
        let toInk = conv.rgbToCMYK(batch: batch.prefix(50).map { $0 })
        #expect(toInk.count == 50 && toInk.allSatisfy { $0.min() >= 0 && $0.max() <= 1 })
        var cs = Surface(format: PixelFormat(mode: .cmyk, sample: .f32, alpha: false))
        cs.writeRegion(PixelRect(x: 0, y: 0, width: 500, height: 1), colours.flatMap { [$0.x, $0.y, $0.z, $0.w] })
        let viaSurface = cs.readRGBA(PixelRect(x: 0, y: 0, width: 500, height: 1))
        let surfMax = zip(viaSurface, batch).map { abs(SIMD3($0.x, $0.y, $0.z) - $1).max() }.max()!
        measure("CMYK batch conversion (one ColorSync call) vs exact per colour: max \(exactMax); Surface.readRGBA through it: max \(surfMax)")
        #expect(surfMax < 1e-5, "Surface.readRGBA uses the installed batch path")
        // PCFoundation colours now convert through the profile.
        let red = PCColor.rgb(1, 0, 0).converted(to: .cmyk)
        #expect(red.c.y > 0.8 && red.c.z > 0.8 && red.c.x < 0.2, "\(red.c)")
        let back = red.rgb
        #expect(back.x > 0.8 && back.y < 0.3, "\(back)")
    }

    @Test func gamutCheck() throws {
        let g = try GamutCheck(source: srgb, proof: cmyk)
        let blue = g.deltaE([0, 0, 1]), gray = g.deltaE([0.5, 0.5, 0.5])
        measure("gamut check sRGB vs coated CMYK: blue ΔE \(blue), 50% gray ΔE \(gray), threshold 4")
        #expect(g.isOutOfGamut([0, 0, 1]))
        #expect(!g.isOutOfGamut([0.5, 0.5, 0.5]))
        let m = g.mask(RasterBuffer(width: 2, height: 1, format: .rgba8, bytes: [0, 0, 255, 255, 128, 128, 128, 255]))
        #expect(m == [1, 0])
    }

    @Test func surfaceModeConversionRoundTrips() throws {
        var s = Surface(format: .rgba16)
        s.fill(PixelRect(x: 0, y: 0, width: 300, height: 10), with: [0.6, 0.4, 0.3, 1])
        s.setPixel(x: 5, y: 5, [0.1, 0.8, 0.2, 0.5])
        let toC = try ColorTransform(source: srgb, destination: cmyk, options: .photoshopDefault)
        let c = try toC.convert(s)
        #expect(c.format == PixelFormat(mode: .cmyk, sample: .u16, alpha: true))
        let backT = try ColorTransform(source: cmyk, destination: srgb, options: .photoshopDefault)
        let r = try backT.convert(c)
        let p = r.pixel(x: 100, y: 3)
        #expect(abs(p[0] - 0.6) < 0.02 && abs(p[1] - 0.4) < 0.02 && abs(p[2] - 0.3) < 0.02, "\(p)")
        #expect(abs(r.pixel(x: 5, y: 5)[3] - 0.5) < 1e-3, "alpha carried")
        // Lab document model through the float path.
        let toLab = try ColorTransform(source: srgb, destination: lab)
        let l = try toLab.convert(s, to: .f32)
        let lp = LabEncoding.normalized.decode(SIMD3(l.pixel(x: 100, y: 3)[0], l.pixel(x: 100, y: 3)[1], l.pixel(x: 100, y: 3)[2]))
        let expect = ColorConvert.srgbToLab(SIMD3(0.6, 0.4, 0.3))
        measure("sRGB (0.6,0.4,0.3) → Lab via ColorSync \(lp) vs PCFoundation's analytic \(expect): ΔE \(ColorMath.deltaE76(lp, SIMD3(Double(expect.x), Double(expect.y), Double(expect.z))))")
        #expect(ColorMath.deltaE76(lp, SIMD3(Double(expect.x), Double(expect.y), Double(expect.z))) < 0.5)
    }

    @MainActor @Test func displayProfilesReadNatively() {
        let all = DisplayProfiles.all()
        measure("displays: \(all.map { "\($0.name): \($0.profile?.profileDescription ?? "none") EDR \($0.maximumEDRValue)" })")
        for d in all { #expect(d.profile != nil, "\(d.name)") }
    }
}
