// The pixels PCIO writes for a fill layer are the ones the compositor draws for it: PCIO renders
// them with PCRender's `FillLayerRenderer` (in the document's model, at its depth), so a reader
// that shows the stored pixels (Photoshop before it re-renders, ImageIO, a fill cache) sees the
// live fill. New in the port; MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import PCPSD
import Testing
@testable import PCIO

@Suite struct FillLayerPixelsTests {
    init() { ExportSweep.install() }

    static let modes: [(ColorMode, SampleType)] = [(.rgb, .u8), (.rgb, .u16), (.cmyk, .u8), (.cmyk, .u16), (.lab, .u8), (.lab, .u16),
                                                   (.grayscale, .u8), (.grayscale, .u16)]

    /// Colours a document of `mode` holds: neutral in Grayscale (PCRender's live compositor
    /// draws an RGB fill colour in colour even in a Grayscale document; the written pixels are
    /// grey, as Photoshop's are).
    static func fills(_ mode: ColorMode, _ dots: Pattern) -> [(String, Fill)] {
        let gray = mode == .grayscale
        let a = gray ? PCColor.rgb(0.7, 0.7, 0.7) : PCColor.rgb(0.9, 0.3, 0.1), b = gray ? PCColor.rgb(0.2, 0.2, 0.2) : PCColor.rgb(0.1, 0.4, 0.8)
        return [
            ("solid", .solid(mode == .cmyk ? PCColor(mode: .cmyk, c: SIMD4(0.2, 0.4, 0.6, 0.3), alpha: 1) : a)),
            ("linear", .gradient(GradientFill(stops: [ColorStop(0, a), ColorStop(1, b)], angle: 30, scale: 0.8, style: .linear, reverse: false,
                                              opacityStops: [OpacityStop(0, 1), OpacityStop(1, 0.5)]))),
            ("radial", .gradient(GradientFill(stops: [ColorStop(0, b), ColorStop(0.6, a)], angle: 0, scale: 1, style: .radial, reverse: true))),
            ("pattern", .pattern(PatternFill(name: dots.name, scale: 1, id: dots.id))),
        ]
    }

    @Test(arguments: modes.indices) func exportedFillPixelsMatchTheLiveComposite(_ i: Int) throws {
        let (mode, depth) = Self.modes[i]
        let dots = Pattern(name: "Dots", surface: pattern(PixelFormat(mode: .rgb, sample: .u8, alpha: true), PixelRect(x0: 0, y0: 0, x1: 5, y1: 3), 7, true),
                           width: 5, height: 3)
        for (name, fill) in Self.fills(mode, dots) {
            var doc = Document(name: "fill", size: PixelSize(width: 20, height: 12), mode: mode, depth: depth)
            doc.patterns = [dots]
            doc.layers = [Layer(name: name, content: .fill(fill))]
            let r = try DocumentIO.export(doc, as: "f.psd", options: IOOptions(compositor: MapsKit.compositor))
            #expect(!r.warnings.contains { $0.contains("without pixels") }, "\(r.warnings)")
            let back = try DocumentIO.importFile(name: "f.psd", bytes: r.bytes, options: IOOptions(compositor: StoredPixelsCompositor())).document
            let stored = try #require(back.layers.first?.fillCache?.surface, "\(mode) \(depth) \(name): fill pixels")
            // The stored pixels as a plain pixel layer composite like the live fill.
            var raster = doc
            raster.layers = [Layer(name: name, content: .raster(stored))]
            let d = MapsKit.maxDiff(try MapsKit.flatten(doc).px, try MapsKit.flatten(raster).px)
            // 16-bit Lab: PSD's a*/b* scale has 65280 steps to the document's 65535, so a value
            // off PSD's grid moves by up to one code in the file.
            let tolerance: Float = mode == .lab && depth == .u16 ? 5e-5 : 1e-6
            #expect(d <= tolerance, "\(mode) \(depth) \(name): stored pixels differ from the live fill by \(d)")
        }
    }

    /// A solid colour's alpha travels as the layer's fill opacity (`SoCo` has no alpha); its pixels
    /// are the opaque colour, so the stored pixels and the fill opacity are not applied twice.
    @Test func solidAlphaIsNotWrittenTwice() throws {
        var doc = Document(name: "fill", size: PixelSize(width: 6, height: 4), mode: .cmyk, depth: .u8)
        doc.layers = [Layer(name: "solid", content: .fill(.solid(PCColor(mode: .cmyk, c: SIMD4(0.2, 0.4, 0.6, 0.3), alpha: 0.7))))]
        let r = try DocumentIO.export(doc, as: "f.psd", options: IOOptions(compositor: MapsKit.compositor))
        let rec = try #require(try PSDFile(bytes: r.bytes).layers.first)
        #expect(rec.fillOpacity == 179)
        let back = try DocumentIO.importFile(name: "f.psd", bytes: r.bytes, options: IOOptions(compositor: StoredPixelsCompositor())).document
        let stored = try #require(back.layers.first?.fillCache?.surface)
        #expect(stored.readRegion(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1)).last == 1, "opaque pixels")
        #expect(MapsKit.maxDiff(try MapsKit.flatten(doc).px, try MapsKit.flatten(back).px) <= 0.5 / 255 + 1e-6)
    }
}
