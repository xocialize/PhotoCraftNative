// Port of photocraft-io (crates/io/tests/pattern_fill_psd.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// A Pattern Fill layer looks the same after a PSD or layered-TIFF save and reopen in every
// colour mode and depth (#1907): the pixels written for it are the pattern, not transparency.
// photocraft renders the fill's pixels with its own compositor; PCIO asks the injected renderer
// (here PCRender through MapsKit.Renderer) and composites with PCRender.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIO

@Suite struct PatternFillPSDTests {
    init() { ExportSweep.install() }
    static let checkerId = "059289fb-0000-4000-8000-000000000001"

    /// An RGB checkerboard (as the default patterns are), whatever the document's mode.
    static func checker() -> Pattern {
        var s = Surface(format: .rgba8)
        s.fill(rect(0, 0, 8, 8), with: [0.8, 0.8, 0.8, 1])
        s.fill(rect(0, 0, 4, 4), with: [0.2, 0.4, 0.9, 1])
        s.fill(rect(4, 4, 8, 8), with: [0.2, 0.4, 0.9, 1])
        return Pattern(id: checkerId, name: "Checker", width: 8, height: 8, surface: s)
    }

    static func doc(_ mode: ColorMode, _ depth: SampleType) -> Document {
        var d = Document(name: "p", size: PixelSize(width: 40, height: 24), mode: mode, depth: depth)
        d.patterns.append(checker())
        let fill = Fill.pattern(PatternFill(name: "Checker", scale: 1, id: checkerId, angle: 0, link: true, phase: .zero))
        d.layers.append(Layer(name: "Pattern Fill 1", content: .fill(fill)))
        return d
    }

    /// How far `back`'s composite is from `d`'s pattern stored in `d`'s pixel format (the pattern
    /// as Edit › Fill would paint it: an RGB pattern is grey in a Grayscale document).
    static func maxDiff(_ d: Document, _ back: Document) throws -> Float {
        let fmt = d.pixelFormat
        var s = Surface(format: fmt)
        s.writeRGBA(d.bounds, try MapsKit.flatten(d).px)
        let want = s.readRGBA(d.bounds)
        let got = try MapsKit.flatten(back).px
        var m: Float = 0
        for (p, q) in zip(want, got) { for c in 0 ..< 4 { m = max(m, abs(p[c] - q[c])) } }
        return m
    }

    static func isPatternFill(_ l: Layer) -> Bool { if case .fill(.pattern) = l.content { true } else { false } }

    @Test(arguments: [ColorMode.rgb, .grayscale, .cmyk, .lab]) func patternFillSurvivesPSDAndLayeredTIFFInEveryMode(_ mode: ColorMode) throws {
        for depth in [SampleType.u8, .u16, .f32] {
            let d = Self.doc(mode, depth)
            let before = try MapsKit.flatten(d)
            #expect(before.px.allSatisfy { $0.w > 0.99 }, "\(mode)/\(depth): the pattern renders before saving")
            var tiff = MapsKit.options()
            tiff.tiffLayers = true
            for (path, opts) in [("x.psd", MapsKit.options()), ("x.psd", MapsKit.options(photoshop: true)), ("x.tif", tiff)] {
                if mode == .lab && path == "x.tif" { continue } // Lab documents are saved as a flat TIFF (with a warning).
                // 32-bit CMYK and Lab are written at 16 bits (Photoshop has no such modes): lint-clean.
                let r = try MapsKit.export(d, path, options: opts)
                let back = try MapsKit.importFile(r.bytes, path, options: opts).document
                guard let l = back.layers.first(where: { $0.name == "Pattern Fill 1" }) else {
                    Issue.record("\(mode)/\(depth) \(path): layers \(back.layers.map(\.name)), warnings \(r.warnings)")
                    continue
                }
                #expect(Self.isPatternFill(l), "\(mode)/\(depth) \(path)")
                let diff = try Self.maxDiff(d, back)
                #expect(diff < 0.02, "\(mode)/\(depth) \(path): the reopened pattern fill differs by \(diff)")
            }
        }
    }

    /// A pattern fill seen through a vector mask (Photoshop's pattern-filled shape) stays a pattern
    /// fill layer after a save and reopen: its stored pixels are the unclipped fill, which must not
    /// turn it into a shape layer drawing the pattern over the whole canvas (psd-tools
    /// adjustment-fillers.psd).
    @Test(arguments: [ColorMode.rgb, .cmyk]) func vectorMaskedPatternFillSurvivesPSD(_ mode: ColorMode) throws {
        for photoshop in [false, true] {
            var d = Self.doc(mode, .u8)
            let fmt = d.pixelFormat
            var white = Layer.raster("Background", format: fmt)
            white.withRaster { $0.fill(rect(0, 0, 40, 24), with: fmt.components(fromRGBA: SIMD4(1, 1, 1, 1))) }
            d.layers.insert(white, at: 0)
            d.layers[1].vectorMask = VectorMask(path: MapsKit.rectPath(8, 4, 16, 12))
            let o = MapsKit.options(photoshop: photoshop)
            let r = try MapsKit.export(d, "x.psd", options: o)
            let back = try MapsKit.importFile(r.bytes, "x.psd", options: o).document
            let l = try #require(back.layers.first { $0.name == "Pattern Fill 1" }, "layer")
            #expect(Self.isPatternFill(l), "\(mode): reopened as a pattern fill")
            #expect(l.vectorMask != nil, "\(mode): keeps its vector mask")
            let diff = try Self.maxDiff(d, back)
            #expect(diff < 0.02, "\(mode): the reopened layer differs by \(diff)")
        }
    }
}
