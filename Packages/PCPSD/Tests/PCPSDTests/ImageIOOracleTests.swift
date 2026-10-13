// Third-party oracle tests against macOS ImageIO:
// (b) writer acceptance — every file the builder produces (layered documents in every mode/depth it
//     writes, every compression, PSD and PSB) must open in ImageIO with the composite we wrote;
// (c) ImageIO as a third-party *writer* — files it writes (8/16-bit RGB/RGBA, Gray, CMYK) must parse,
//     rewrite byte for byte and decode to what ImageIO reads back.
// Fixtures go to the scratch directory (PCPSD_FIXTURES), never the repository.

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PCPSD

/// Deterministic test pixels.
enum Pixels {
    static func pattern(_ w: Int, _ h: Int, spp: Int, depth: UInt16, seed: Int, alpha: AlphaKind) -> PSDPixels {
        func v(_ x: Int, _ y: Int, _ c: Int) -> Double {
            Double((x * 37 + y * 23 + c * 61 + seed * 11) % 256) / 255
        }
        func a(_ x: Int, _ y: Int) -> Double {
            switch alpha {
            case .opaque: 1
            case .partial: (x + y) % 4 == 0 ? 0 : Double(128 + (x * 13 + y * 7) % 128) / 255
            }
        }
        var d: [Double] = []
        for y in 0 ..< h {
            for x in 0 ..< w {
                for c in 0 ..< spp - 1 { d.append(v(x, y, c)) }
                d.append(a(x, y))
            }
        }
        switch depth {
        case 8: return .u8(d.map { UInt8(($0 * 255).rounded()) })
        case 16: return .u16(d.map { UInt16(($0 * 65535).rounded()) })
        default: return .f32(d.map { Float($0) })
        }
    }

    enum AlphaKind { case opaque, partial }
}

@Suite struct ImageIOOracleTests {
    /// A layered document: background, a group with a masked layer, a clipped layer, the merged
    /// composite supplied (here: the background, which the other layers' content does not have to
    /// match for the oracle — ImageIO reads the merged image).
    static func document(mode: PSDColorMode, depth: UInt16, version: PSDVersion, compression: PSDCompression, alpha: Pixels.AlphaKind) throws -> PSDBuilder {
        let (w, h) = (23, 17)
        let spp = (mode == .grayscale ? 1 : mode == .cmyk ? 4 : 3) + 1
        var b = PSDBuilder(width: w, height: h, colorMode: mode, depth: depth, version: version)
        b.compression = compression
        b.pushLayer(PSDLayerSpec(name: "Background", left: 0, top: 0, width: w, height: h,
                                 pixels: Pixels.pattern(w, h, spp: spp, depth: depth, seed: 1, alpha: .opaque)))
        try b.pushGroup(PSDGroupSpec(name: "Group ✓")) { g in
            var l = PSDLayerSpec(name: "Masked", left: -3, top: 2, width: 12, height: 9,
                                 pixels: Pixels.pattern(12, 9, spp: spp, depth: depth, seed: 2, alpha: .partial))
            l.mask = PSDMaskSpec(rect: PSDRect(x: 0, y: 3, width: 6, height: 5), data: (0 ..< 30).map { UInt8($0 * 8) })
            l.blendMode = .multiply
            l.opacity = 200
            g.pushLayer(l)
            var c = PSDLayerSpec(name: "Clipped", left: 4, top: 4, width: 5, height: 5,
                                 pixels: Pixels.pattern(5, 5, spp: spp, depth: depth, seed: 3, alpha: .opaque))
            c.clipping = true
            g.pushLayer(c)
        }
        b.setComposite(Pixels.pattern(w, h, spp: spp, depth: depth, seed: 9, alpha: alpha))
        return b
    }

    @Test func builderOutputOpensInImageIOWithTheCompositeWeWrote() throws {
        var accepted = 0, total = 0, worst = 0
        var interpretations: [String: Int] = [:]
        var rejected: [String] = []
        let combos: [(PSDColorMode, UInt16)] = [(.rgb, 8), (.rgb, 16), (.rgb, 32), (.grayscale, 8), (.grayscale, 16), (.grayscale, 32),
                                                 (.cmyk, 8), (.cmyk, 16), (.lab, 8), (.lab, 16)]
        for (mode, depth) in combos {
            for version in PSDVersion.allCases {
                for compression in PSDCompression.all {
                    for alpha in [Pixels.AlphaKind.opaque, .partial] where !(mode != .rgb && mode != .grayscale && alpha == .partial) {
                        total += 1
                        let name = "builder-\(mode)-\(depth)-\(version)-\(compression)-\(alpha)".replacingOccurrences(of: "+", with: "p")
                        let file = try Self.document(mode: mode, depth: depth, version: version, compression: compression, alpha: alpha).build()
                        let data = try file.serialized()
                        try Corpus.saveFixture(data, as: name + (version == .psb ? ".psb" : ".psd"))
                        // Our own reader: byte-stable, model-stable.
                        let back = try PSDFile(data: data)
                        #expect(back == file, "\(name)")
                        #expect(try back.serialized() == data, "\(name)")
                        for l in back.layers { try l.channels.forEach { _ = try l.decodeChannel($0.id, depth: depth, version: version) } }
                        guard let oracle = ImageIOOracle.decode(data) else {
                            rejected.append(name)
                            continue
                        }
                        accepted += 1
                        if mode == .rgb || mode == .grayscale {
                            let (d, interp) = ImageIOOracle.compare(stored: try back.compositeRGBA8(unmatte: false), unmatted: try back.compositeRGBA8(), oracle: oracle)
                            interpretations[interp.rawValue, default: 0] += 1
                            worst = max(worst, d)
                            #expect(d <= 1, "\(name): ImageIO composite differs by \(d) [\(oracle.description)]")
                        }
                    }
                }
            }
        }
        print("WRITER ImageIO acceptance: \(accepted)/\(total) open; worst RGB/Gray composite difference \(worst) (ImageIO alpha presentation: \(interpretations)); not opened: \(rejected)")
    }

    static func makeImageIOFixture(_ name: String, space: CGColorSpace, bpc: Int, info: UInt32, fill: (CGContext) -> Void) -> URL? {
        let (w, h) = (19, 11)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: bpc, bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        fill(ctx)
        guard let img = ctx.makeImage() else { return nil }
        let url = Corpus.workDirectory.appendingPathComponent("imageio-\(name).psd")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.adobe.photoshop-image" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    static func gradientFill(_ ctx: CGContext, alpha: Bool) {
        let space = ctx.colorSpace!
        let colors: [CGColor]
        switch space.model {
        case .monochrome: colors = [CGColor(gray: 0.05, alpha: 1), CGColor(gray: 0.95, alpha: 1)]
        case .cmyk: colors = [CGColor(colorSpace: space, components: [0.9, 0.1, 0.2, 0.0, 1])!, CGColor(colorSpace: space, components: [0.1, 0.7, 0.3, 0.4, 1])!]
        default: colors = [CGColor(red: 0.9, green: 0.1, blue: 0.2, alpha: alpha ? 0.3 : 1), CGColor(red: 0.1, green: 0.8, blue: 0.6, alpha: 1)]
        }
        let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: ctx.width, y: ctx.height), options: [])
        if alpha {
            ctx.setBlendMode(.clear)
            ctx.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        }
    }

    @Test func imageIOWrittenPSDsParseRewriteAndDecode() throws {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        let cmyk = CGColorSpace(name: CGColorSpace.genericCMYK)!
        let le16 = CGBitmapInfo.byteOrder16Little.rawValue
        let configs: [(String, CGColorSpace, Int, UInt32, Bool)] = [
            ("rgb8", srgb, 8, CGImageAlphaInfo.noneSkipLast.rawValue, false),
            ("rgba8", srgb, 8, CGImageAlphaInfo.premultipliedLast.rawValue, true),
            ("rgb16", srgb, 16, CGImageAlphaInfo.noneSkipLast.rawValue | le16, false),
            ("rgba16", srgb, 16, CGImageAlphaInfo.premultipliedLast.rawValue | le16, true),
            ("gray8", gray, 8, CGImageAlphaInfo.none.rawValue, false),
            ("gray16", gray, 16, CGImageAlphaInfo.none.rawValue | le16, false),
            ("cmyk8", cmyk, 8, CGImageAlphaInfo.none.rawValue, false),
        ]
        var lines: [String] = []
        for (name, space, bpc, info, alpha) in configs {
            guard let url = Self.makeImageIOFixture(name, space: space, bpc: bpc, info: info, fill: { Self.gradientFill($0, alpha: alpha) }) else {
                Issue.record("ImageIO could not write \(name)")
                continue
            }
            let data = try Data(contentsOf: url)
            let f = try PSDFile(data: data)
            #expect(try f.serialized() == data, "\(name): rewrite")
            // ImageIO's writer emits damaged layer channels (the first 8 bytes of row 0 of each RLE
            // colour channel overwritten; 16-bit ZIP layer streams undecodable). ImageIO only reads
            // the merged image, so it never notices; count them instead of failing.
            var badChannels = 0
            for l in f.layers {
                for c in l.channels {
                    if (try? l.decodeChannel(c.id, depth: f.header.depth, version: f.header.version)) == nil { badChannels += 1 }
                }
            }
            guard let oracle = ImageIOOracle.decode(data) else {
                Issue.record("ImageIO cannot read back its own \(name)")
                continue
            }
            let d: Int
            if f.header.colorMode == .cmyk {
                let img = try f.normalizedComposite()
                var worst = 0
                for i in 0 ..< img.width * img.height {
                    for k in 0 ..< 4 { worst = max(worst, abs(Int((img.planes[k][i] * 255).rounded()) - Int(oracle.samples[i * 4 + k]))) }
                }
                d = worst
            } else {
                d = ImageIOOracle.compare(stored: try f.compositeRGBA8(unmatte: false), unmatted: try f.compositeRGBA8(), oracle: oracle).0
            }
            lines.append("\(name): \(f.header.colorMode) \(f.header.depth)-bit \(f.imageData.compression), \(f.layers.count) layers (\(badChannels) undecodable channels written by ImageIO), max diff \(d)")
            #expect(d <= 1, "\(name): max difference \(d)")
        }
        print("IMAGEIO-WRITTEN fixtures:\n  " + lines.joined(separator: "\n  "))
    }
}

extension ImageIOOracleTests {
    /// Reader breadth against ImageIO: merged-only files in every colour mode and depth (written by
    /// our writer from the generator's patterns) decoded by both. ImageIO reads PSD with its own
    /// code, so agreement checks our mode decoding (bitmap bit order, indexed palette layout, CMYK
    /// inversion, 16/32-bit scaling) independently.
    @Test func everyModeAndDepthDecodesLikeImageIO() throws {
        var lines: [String] = []
        for mode in TestGen.modes {
            for depth in TestGen.modeDepths(mode) {
                let f = TestGen.mergedOnly(.psd, mode, depth, .rle, 13, 7)
                let data = try f.serialized()
                try Corpus.saveFixture(data, as: "merged-\(mode)-\(depth).psd")
                guard let oracle = ImageIOOracle.decode(data) else {
                    lines.append("\(mode) \(depth)-bit: ImageIO cannot open")
                    continue
                }
                let d: Int
                if oracle.colorModel == .cmyk {
                    let img = try f.normalizedComposite()
                    var worst = 0
                    for i in 0 ..< img.width * img.height {
                        for k in 0 ..< 4 { worst = max(worst, abs(Int((img.planes[k][i] * 255).rounded()) - Int(oracle.samples[i * 4 + k]))) }
                    }
                    d = worst
                } else {
                    d = ImageIOOracle.compare(stored: try f.compositeRGBA8(unmatte: false), unmatted: try f.compositeRGBA8(), oracle: oracle).0
                }
                lines.append("\(mode) \(depth)-bit: max diff \(d) [\(oracle.description)]")
                if mode != .multichannel && mode != .duotone && !(mode == .grayscale && depth == 32) && !(mode == .rgb && depth == 32) {
                    #expect(d <= 1, "\(mode) \(depth)-bit differs from ImageIO by \(d)")
                }
            }
        }
        print("MODES vs ImageIO:\n  " + lines.joined(separator: "\n  "))
    }
}
