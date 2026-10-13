// Port of photocraft-compose (crates/compose/src/tests.rs fill-layer round trips: `render_fill_content` against the live composite), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Fill layers render at the document's depth, so a live fill composites exactly like the pixels
// `FillLayerRenderer` gives a PSD writer for it, in every colour model.

import Foundation
import Testing
import PCDocument
import PCFoundation
@testable import PCRender

@Suite struct FillLayerTests {
    static let gradient = Fill.gradient(GradientFill(stops: [ColorStop(0, .rgb(0.9, 0.2, 0.1, 1)), ColorStop(1, .rgb(0.1, 0.4, 0.8, 1))],
                                                     angle: 35, scale: 0.8, style: .radial, reverse: true,
                                                     opacityStops: [OpacityStop(0, 0.6), OpacityStop(1, 0.9)], midpoints: [0.3],
                                                     offset: SIMD2(0.1, -0.2), dither: false))

    @Test(arguments: [ColorMode.rgb, .cmyk, .lab, .grayscale])
    func liveFillMatchesItsRenderedPixels(_ mode: ColorMode) throws {
        for depth in [SampleType.u8, .u16] {
            for fill in [Self.gradient, .solid(.rgb(0.3, 0.6, 0.2, 0.7))] {
                var live = Document(name: "f", size: PixelSize(width: 13, height: 9), mode: mode, depth: depth)
                let layer = Layer(name: "fill", content: .fill(fill))
                live.layers.append(layer)
                let pixels = FillLayerRenderer.render(layer, fill: fill, canvas: live.bounds, patterns: [], format: live.pixelFormat)
                var baked = live
                baked.layers = [Layer.raster("fill", surface: pixels)]
                let comp = DocumentCompositor(backend: .cpu)
                let a = try comp.compositeToSurface(live, format: live.pixelFormat).readRegion(live.bounds)
                let b = try comp.compositeToSurface(baked, format: live.pixelFormat).readRegion(live.bounds)
                let d = zip(a, b).map { abs($0 - $1) }.max() ?? 0
                #expect(d <= 1e-6, "\(mode) \(depth) \(fill): \(d)")
            }
        }
    }

    @Test func fillsRoundToTheDocumentDepth() throws {
        var d = Document(name: "f", size: PixelSize(width: 4, height: 4), mode: .rgb, depth: .u8)
        d.layers.append(Layer(name: "fill", content: .fill(.solid(.rgb(0.3001, 0.6, 0.2, 1)))))
        let px = try DocumentCompositor(backend: .cpu).render(d, region: d.bounds).px[5]
        #expect(px.x == (0.3001 * 255).rounded() / 255)
    }
}
