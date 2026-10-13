// Port of photocraft-io (crates/io/tests/color.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// ICC profiles through import and export: byte-exact PSD round trips with real profiles, PNG/JPEG
// embedding and extraction, colour-managed CMYK → RGB for formats without CMYK, CMYK fills and
// gradient-map stops. photocraft's built-in and synthetic profiles (photocraft-cms) are replaced
// by CoreGraphics' named colour spaces (Generic CMYK stands in for the synthetic CMYK profile),
// and its colour engine by ColorSync. `uncached_cmyk_gradient_corpus_roundtrip` needs a
// psd-tools corpus file that is not in the corpus here.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCIOMaps
import PCPSD
import Testing
@testable import PCIO

@Suite struct ColorTests {
    init() { ExportSweep.install() }
    typealias Kit = FlatKit

    /// photocraft's `Builtin::ALL` plus the system Generic CMYK and Adobe RGB profiles.
    static func realProfiles() -> [(String, [UInt8])] {
        let names: [(String, CFString)] = [
            ("sRGB", CGColorSpace.sRGB), ("Display P3", CGColorSpace.displayP3), ("Adobe RGB", CGColorSpace.adobeRGB1998),
            ("ProPhoto", CGColorSpace.rommrgb), ("linear sRGB", CGColorSpace.linearSRGB), ("Gray 2.2", CGColorSpace.genericGrayGamma2_2),
            ("linear Gray", CGColorSpace.linearGray), ("Generic CMYK", CGColorSpace.genericCMYK), ("Generic Lab", CGColorSpace.genericLab),
        ]
        return names.compactMap { n, c in Kit.icc(c).map { (n, $0) } }
    }

    @Test func psdICCRoundtripByteExact() throws {
        for (name, icc) in Self.realProfiles() {
            let mode: ColorMode = switch Kit.iccSpace(icc) {
            case "CMYK": .cmyk
            case "GRAY": .grayscale
            case "Lab ": .lab
            default: .rgb
            }
            var d = genDoc(mode, .u8, .pixels)
            d.iccProfile = icc
            let r = try Kit.export(d, "x.psd")
            let back = try Kit.importFile("x.psd", r.bytes).document
            #expect(back.iccProfile == icc, "\(name)")
        }
    }

    @Test func pngAndJPEGEmbedAndExtractICC() throws {
        for (name, space) in [("sRGB", CGColorSpace.sRGB), ("Display P3", CGColorSpace.displayP3), ("Adobe RGB", CGColorSpace.adobeRGB1998),
                              ("ProPhoto", CGColorSpace.rommrgb)] {
            let icc = try #require(Kit.icc(space))
            for (file, alpha) in [("x.png", true), ("x.jpg", false)] {
                var d = Kit.single(.rgb, .u8, alpha)
                d.iccProfile = icc
                let r = try Kit.export(d, file)
                let back = try Kit.importFile(file, r.bytes).document
                #expect(back.iccProfile == icc, "\(name) \(file)")
                #expect(back.iccProfile.flatMap(Kit.iccDescription) == Kit.iccDescription(icc), "\(name) \(file)")
            }
        }
        // Gray PNG with a gray profile.
        let icc = try #require(Kit.icc(CGColorSpace.genericGrayGamma2_2))
        var d = Kit.single(.grayscale, .u16, false)
        d.iccProfile = icc
        let r = try Kit.export(d, "g.png")
        #expect(try Kit.importFile("g.png", r.bytes).document.iccProfile == icc)
    }

    @Test func cmykToPNGIsColourManagedAndTaggedSRGB() throws {
        // Native single-layer CMYK document written to PNG: converted through the CMYK profile.
        var d = Kit.single(.cmyk, .u8, false)
        d.iccProfile = Kit.icc(CGColorSpace.genericCMYK)
        let r = try Kit.export(d, "c.png")
        #expect(r.warnings.contains { $0.contains("sRGB") }, "\(r.warnings)")
        let back = try Kit.importFile("c.png", r.bytes).document
        #expect(back.mode == .rgb)
        let icc = try #require(back.iccProfile, "tagged")
        #expect(Kit.iccDescription(icc) == Kit.icc(CGColorSpace.sRGB).flatMap(Kit.iccDescription), "\(String(describing: Kit.iccDescription(icc)))")
        // Lab documents never write Lab numbers as RGB.
        let lab = try Kit.export(Kit.single(.lab, .u8, false), "l.png")
        let labBack = try Kit.importFile("l.png", lab.bytes).document
        #expect(labBack.iccProfile.map(Kit.iccSpace) == "RGB ")
    }

    /// photocraft `render_tiled(doc, bounds, 3)`: the composite rendered 3×3 pixels at a time.
    static func renderTiled(_ doc: Document) throws -> [SIMD4<Float>] {
        let b = doc.bounds
        var out = [SIMD4<Float>](repeating: .zero, count: b.area)
        for y0 in stride(from: b.y0, to: b.y1, by: 3) {
            for x0 in stride(from: b.x0, to: b.x1, by: 3) {
                let r = PixelRect(x0: x0, y0: y0, x1: min(x0 + 3, b.x1), y1: min(y0 + 3, b.y1))
                let px = try Kit.flattenRegion(doc, r)
                for y in r.y0 ..< r.y1 {
                    for x in r.x0 ..< r.x1 { out[Int(y - b.y0) * b.width + Int(x - b.x0)] = px[Int(y - r.y0) * r.width + Int(x - r.x0)] }
                }
            }
        }
        return out
    }

    @Test func cmykFillsSurvivePSDRoundtripAtEveryDepth() throws {
        let icc = try #require(Kit.icc(CGColorSpace.genericCMYK))
        let a = PCColor(mode: .cmyk, c: SIMD4(0.2, 0.4, 0.6, 0.3), alpha: 0.7)
        let b = PCColor(mode: .cmyk, c: SIMD4(0.6, 0.2, 0.3, 0.1), alpha: 0.4)
        for depth in [SampleType.u8, .u16, .f32] {
            for profile in [nil, icc] {
                for style in [nil, GradientStyle.linear, .radial, .angle, .reflected, .diamond] {
                    let fill: Fill
                    if let style {
                        fill = .gradient(GradientFill(stops: [ColorStop(1, b), ColorStop(0, a)], angle: 35, scale: 0.8, style: style, reverse: true,
                                                      opacityStops: [OpacityStop(0, 0.6), OpacityStop(1, 0.9)], midpoints: [0.25],
                                                      offset: SIMD2(0.1, -0.2), dither: true))
                    } else {
                        fill = .solid(a)
                    }
                    let what = "\(depth) \(String(describing: style)) profile \(profile != nil)"
                    var doc = Document(name: "CMYK fill", size: PixelSize(width: 9, height: 6), mode: .cmyk, depth: depth)
                    doc.iccProfile = profile
                    doc.layers.append(Layer(name: "Fill", content: .fill(fill)))
                    let expected = try Kit.flatten(doc)
                    #expect(Kit.maxDiff(expected, try Self.renderTiled(doc)) <= 1e-6, "\(what): tiled")
                    let bytes = try Kit.export(doc, "x.psd").bytes
                    let back = try Kit.importFile("x.psd", bytes).document
                    let diff = Kit.maxDiff(expected, try Kit.flatten(back))
                    // A solid fill's colour alpha travels as the layer's 8-bit opacity (`SoCo` has no
                    // alpha), so it comes back within half an 8-bit step once the compositor honours it.
                    let tolerance: Float = style == nil ? 0.5 / 255 + 1e-6 : 1e-6
                    // The fill pixels come from PCRender's `FillLayerRenderer`, so the reopened layer
                    // composites like the live fill at 8 and 16 bits.
                    withKnownIssue("PCIO writes 32-bit CMYK as a 16-bit PSD (Photoshop has no 32-bit CMYK mode)") {
                        #expect(diff <= tolerance, "\(what): round-trip error \(diff)")
                    } when: { depth == .f32 && style != nil }
                    #expect(back.iccProfile == doc.iccProfile, "\(what)")
                    if style == nil {
                        // The colour's alpha is the layer's fill opacity; the pixels are the opaque inks.
                        #expect(back.layers.first?.fillOpacity == Float(179) / 255, "\(what)")
                        let native = Surface(format: doc.pixelFormat, defaultPixel: [a.c.x, a.c.y, a.c.z, a.c.w, 1]).readRegion(doc.bounds)
                        let actual = try #require(back.layers.first?.fillCache, "\(what): fill cache").surface.readRegion(doc.bounds)
                        // `FillLayerRenderer` quantises the inks as the compositor draws them
                        // (black as 1 − k): a value on a rounding tie (0.3 · 255 = 76.5) lands
                        // one code from direct quantisation.
                        let tolerance: Float = depth == .f32 ? 1e-6 : depth == .u8 ? 1 / 255 + 1e-6 : 1 / 65535 + 1e-7
                        withKnownIssue("PCIO writes 32-bit CMYK documents as 16-bit PSDs (Photoshop has no 32-bit CMYK mode); photocraft keeps 32 bits") {
                            #expect(zip(actual, native).allSatisfy { abs($0 - $1) <= tolerance }, "\(what): \(Array(actual.prefix(5))) vs \(Array(native.prefix(5)))")
                        } when: { depth == .f32 }
                    }
                }
            }
        }
    }

    /// ColorSync's conversion of `components` (with alpha last) from `src` to `dst`, relative
    /// colorimetric with black point compensation (photocraft-cms `Transform`).
    static func convert(_ components: [CGFloat], _ src: CGColorSpace, _ dst: CGColorSpace) -> [Float]? {
        let options = [CGColor.conversionBlackPointCompensation: true] as CFDictionary
        guard let c = CGColor(colorSpace: src, components: components), let out = c.converted(to: dst, intent: .relativeColorimetric, options: options),
              let comps = out.components else { return nil }
        return comps.dropLast().map { Float($0) }
    }

    @Test func rgbFillColoursSeparateThroughTheDocumentCMYKProfile() throws {
        let icc = try #require(Kit.icc(CGColorSpace.genericCMYK))
        let cmyk = try #require(CGColorSpace(iccData: Data(icc) as CFData))
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let rgb: [Float] = [0.2, 0.4, 0.6]
        let expected = try #require(Self.convert(rgb.map { CGFloat($0) } + [1], srgb, cmyk))
        for depth in [SampleType.u8, .u16, .f32] {
            var doc = Document(name: "RGB fill", size: PixelSize(width: 1, height: 1), mode: .cmyk, depth: depth)
            doc.iccProfile = icc
            doc.layers.append(Layer(name: "Fill", content: .fill(.solid(.rgb(rgb[0], rgb[1], rgb[2])))))
            // The document's own profile reaches the fill renderer through the injected converter
            // (`IOOptions.cmykConverter`, PCPlatform's ColorSync one in the app).
            let bytes = try Kit.export(doc, "x.psd", options: Kit.cmykProfileOptions()).bytes
            let back = try Kit.importFile("x.psd", bytes).document
            let samples = try #require(back.layers.first?.fillCache, "\(depth): fill cache").surface.readRegion(back.bounds)
            // 32-bit CMYK is written as 16-bit (Photoshop has no 32-bit CMYK mode).
            let tolerance: Float = depth == .u8 ? 1 / 255 : 1 / 65535
            #expect(zip(samples, expected).allSatisfy { abs($0 - $1) <= tolerance }, "\(depth): \(samples) vs \(expected)")
            // Without a converter the process-wide conversion is used (the app always injects one).
            let plain = try Kit.importFile("x.psd", try Kit.export(doc, "x.psd").bytes).document
            let generic = try #require(plain.layers.first?.fillCache).surface.readRegion(plain.bounds)
            #expect(!zip(generic, expected).allSatisfy { abs($0 - $1) <= tolerance }, "\(depth): the process-wide conversion differs from the profile's")
        }
    }

    /// A two-stop version 1 `grdm` block whose stops are the PSD colour structures `a` and `b`.
    static func grdmBlock(_ a: (UInt16, [UInt16]), _ b: (UInt16, [UInt16])) -> [UInt8] {
        func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
        var v: [UInt8] = [0, 1, 0, 0]
        v += Kit.be32(1) // name: just the terminator
        v += [0, 0]
        v += be16(2)
        for (t, stop) in [(UInt32(0), a), (4096, b)] {
            v += Kit.be32(t) + Kit.be32(50) + be16(stop.0) + stop.1.flatMap(be16) + [0, 0]
        }
        v += be16(2)
        for t: UInt32 in [0, 4096] { v += Kit.be32(t) + Kit.be32(50) + be16(255) }
        v += be16(2) // expansion count
        v += be16(0) // smoothness
        // The rest of a version 1 block, as Photoshop writes it (photocraft's fixture stops after
        // the smoothness, a truncated block Photoshop refuses): noise length, mode, seed,
        // transparency and vector-colour flags, roughness, colour model, min/max, then the pad that
        // makes the length a multiple of 4.
        v += be16(32) + be16(0) + Kit.be32(0) + be16(0) + be16(0) + Kit.be32(2048) + be16(3)
        for x: UInt16 in [0, 0, 0, 0, 0x8000, 0x8000, 0x8000, 0x8000] { v += be16(x) }
        v += be16(0)
        v += [UInt8](repeating: 0, count: (4 - v.count % 4) % 4)
        return v
    }

    static func savedGrdm(_ bytes: [UInt8]) throws -> [UInt8] {
        let f = try PSDFile(bytes: bytes)
        return try #require(f.layers.lazy.compactMap { $0.block("grdm") }.first.map { [UInt8]($0.data) }, "grdm block")
    }

    @Test func gradientMapsWithCMYKLabGrayStopsImportAndKeepTheirSpace() throws {
        let icc = try #require(Kit.icc(CGColorSpace.genericCMYK))
        let cmykSpace = try #require(CGColorSpace(iccData: Data(icc) as CFData))
        let srgbSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let toSRGB = try #require(Self.convert([0.6, 0, 0, 0.4, 1], cmykSpace, srgbSpace))
        // First stop 60 % cyan + 40 % black (stored inverted), second paper white.
        let cmykStop: (UInt16, [UInt16]) = (2, [65535 - 39321, 65535, 65535, 65535 - 26214])
        let paper: (UInt16, [UInt16]) = (2, [65535, 65535, 65535, 65535])
        let labDark: (UInt16, [UInt16]) = (7, [2000, 0, 0, 0])
        let labRed: (UInt16, [UInt16]) = (7, [5000, 6000, 2000, 0])
        let grayBlack: (UInt16, [UInt16]) = (8, [10000, 0, 0, 0])
        let grayWhite: (UInt16, [UInt16]) = (8, [0, 0, 0, 0])
        for depth in [SampleType.u8, .u16, .f32] {
            for (mode, stops) in [(ColorMode.cmyk, (cmykStop, paper)), (.lab, (labDark, labRed)), (.grayscale, (grayWhite, grayBlack))] {
                let what = "\(mode) \(depth)"
                // Photoshop has no Gradient Map in 32-bit Grayscale (it opens the layer as a pixel
                // layer): those saves test PCIO only and stay out of the Photoshop acceptance set.
                let offered = AdjustMap.photoshopOffers("grdm", mode: mode, depth: depth == .f32 && mode != .grayscale ? .u16 : depth)
                func save(_ d: Document) throws -> [UInt8] {
                    offered ? try Kit.export(d, "x.psd", options: Kit.cmykProfileOptions()).bytes
                        : try ExportSweep.excluded { try Kit.export(d, "x.psd", options: Kit.cmykProfileOptions()).bytes }
                }
                let block = Self.grdmBlock(stops.0, stops.1)
                var doc = Document(name: "map", size: PixelSize(width: 4, height: 2), mode: mode, depth: depth)
                if mode == .cmyk { doc.iccProfile = icc }
                doc.layers.append(rasterLayer("Background", doc.pixelFormat, doc.bounds, 3, false))
                doc.layers.append(Layer(name: "Map", content: .adjustment(.unsupported(psdKey: "grdm", raw: block))))
                let bytes = try save(doc)
                // CMYK stops are read through the document's own profile (the injected converter).
                var back = try Kit.importFile("x.psd", bytes, options: Kit.cmykProfileOptions()).document
                guard case let .adjustment(.gradientMap(map)) = back.layers[1].content, let first = map.stops.first?.rgb, let last = map.stops.last?.rgb else {
                    Issue.record("\(what): \(back.layers[1].content)")
                    continue
                }
                switch mode {
                case .cmyk:
                    // Through the document's own profile, not the built-in CMYK conversion.
                    #expect((0 ..< 3).allSatisfy { abs(first[$0] - toSRGB[$0]) < 1e-4 }, "\(what): \(first) vs \(toSRGB)")
                    let builtin = ColorConvert.cmykToRGB(SIMD4(0.6, 0, 0, 0.4))
                    #expect((0 ..< 3).contains { abs(first[$0] - builtin[$0]) > 1e-3 }, "\(what): the document profile is used")
                case .lab:
                    #expect((0 ..< 3).allSatisfy { abs(first[$0] - first[0]) < 1e-3 } && first[0] < 0.3, "\(what): \(first)")
                    #expect(last[0] > last[1] + 0.2, "\(what): a = +60 is reddish: \(last)")
                default:
                    // An inverting map, white to black.
                    #expect(first == SIMD3(1, 1, 1) && last == SIMD3(0, 0, 0), "\(what): \(first) \(last)")
                }
                // The layer now renders: the composite differs from the background alone.
                let withMap = try Kit.flatten(back)
                var hidden = back
                hidden.layers[1].visible = false
                #expect(Kit.maxDiff(withMap, try Kit.flatten(hidden)) > 0.01, "\(what)")
                // Saving again keeps the block (and so the stops' colour space) byte for byte...
                #expect(try Self.savedGrdm(try save(back)) == block, "\(what)")
                // ...and so does toggling Reverse and Dither, which only flip their flags.
                if case var .adjustment(.gradientMap(m)) = back.layers[1].content {
                    m.reverse = true
                    m.dither = true
                    back.layers[1].content = .adjustment(.gradientMap(m))
                }
                let flippedFile = try save(back)
                let flipped = try Self.savedGrdm(flippedFile)
                #expect(Array(flipped[2 ..< 4]) == [1, 1], "\(what)")
                #expect(Array(flipped[4...]) == Array(block[4...]), "\(what): stops keep their colour space")
                let reopened = try Kit.importFile("x.psd", flippedFile, options: Kit.cmykProfileOptions()).document
                #expect(reopened.layers[1].content == back.layers[1].content, "\(what)")
            }
        }
    }
}
