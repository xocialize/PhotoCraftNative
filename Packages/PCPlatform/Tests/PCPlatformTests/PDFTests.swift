// PDF read/write (photocraft gap #2541 / FILE-215-10): multi-page vector + raster write, page
// rasterisation at any DPI and depth, vector import, text extraction, and media-bridge's rasteriser
// as a cross-check. MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import CoreText
import Foundation
import PCDocument
import PCFoundation
import Testing
@testable import PCPlatform

@Suite("PDF (CoreGraphics/PDFKit fill photocraft #2541)")
struct PDFTests {
    func sample() throws -> Data {
        let red = ShapeLayer(path: VectorPath([.polygon([(20, 20), (120, 20), (120, 70), (20, 70)])]), fill: .solid(.rgb(1, 0, 0)))
        let ring = ShapeLayer(path: LiveShape.ellipse(rect: SIMD4(140, 20, 50, 50)).path, fill: nil,
                              stroke: ShapeStroke(width: 6, paint: .solid(.rgb(0, 0, 1))))
        // A gradient paint has no vector equivalent here: it is placed rasterised.
        let grad = ShapeLayer(path: VectorPath([.polygon([(20, 80), (60, 80), (60, 95), (20, 95)])]),
                              fill: .gradient(GradientFill(stops: [ColorStop(0, .rgb(0, 1, 0)), ColorStop(1, .rgb(0, 1, 0))], angle: 0, scale: 1, style: .linear, reverse: false)))
        let page1 = PDFPageSpec(width: 200, height: 100, dpi: 72, shapes: [red, ring, grad])
        let page2 = PDFPageSpec(width: 100, height: 100, dpi: 72, raster: Fixtures.raster(.rgb8Opaque, width: 100, height: 100))
        return try PDFDocumentIO.write(pages: [page1, page2], title: "PCPlatform test")
    }

    @Test func multiPageVectorAndRasterRoundTrip() throws {
        let pdf = try sample()
        #expect(ImageFormat.detect(pdf) == .pdf)
        #expect(try PDFDocumentIO.pageCount(data: pdf) == 2)
        let sizes = try PDFDocumentIO.pageSizes(data: pdf, dpi: 144)
        #expect(sizes == [PixelSize(width: 400, height: 200), PixelSize(width: 200, height: 200)])
        let p1 = try PDFDocumentIO.rasterize(data: pdf, page: 0, dpi: 144)
        #expect((p1.width, p1.height) == (400, 200))
        func px(_ r: RasterBuffer, _ x: Int, _ y: Int) -> [Float] { Array(r.floats()[((y * r.width + x) * 4)..<((y * r.width + x) * 4 + 4)]) }
        let inRed = px(p1, 140, 90), bg = px(p1, 10, 190), ring = px(p1, 330, 40 + 3)
        #expect(inRed[0] > 0.95 && inRed[1] < 0.05, "\(inRed) (vector rect at 2×)")
        #expect(bg[0] > 0.95 && bg[1] > 0.95, "flattened on white")
        #expect(ring[2] > 0.5 && ring[0] < 0.5, "\(ring) stroke on the circle's top")
        let green = px(p1, 80, 175)
        #expect(green[1] > 0.9 && green[0] < 0.1, "\(green) rasterised gradient shape")
        // Transparency and depth.
        let clear = try PDFDocumentIO.rasterize(data: pdf, page: 0, dpi: 72, sample: .u16, transparent: true)
        #expect(clear.format == .rgba16 && px(clear, 5, 95)[3] == 0 && px(clear, 70, 45)[3] > 0.99)
        let float = try PDFDocumentIO.rasterize(data: pdf, page: 1, dpi: 72, sample: .f32)
        #expect(float.format == .rgba32f)
        let raster = Fixtures.raster(.rgb8Opaque, width: 100, height: 100)
        let page2 = ImageCodecs.stripAlpha(try PDFDocumentIO.rasterize(data: pdf, page: 1, dpi: 72))
        let mean = Fixtures.meanDiff(raster, page2)
        measure("raster page written to PDF and rasterised back at the same DPI: mean |Δ| \(mean * 255)/255")
        #expect(mean < 3.0 / 255)
        // Through the codec registry.
        let d = try ImageCodecs.decode(pdf)
        #expect(d.format == .pdf && d.frameCount == 2 && d.warnings == [.morePages(total: 2)])
        #expect(try ImageCodecs.frames(pdf).count == 2)
    }

    @Test func vectorImportRecoversThePaths() throws {
        let shapes = try PDFDocumentIO.vectorShapes(data: try sample(), page: 0, dpi: 72)
        measure("vector import: \(shapes.count) shapes, fills \(shapes.map { $0.fill?.rgb.description ?? "–" })")
        #expect(shapes.count >= 2)
        let red = try #require(shapes.first { ($0.fill?.rgb.x ?? 0) > 0.9 && ($0.fill?.rgb.y ?? 1) < 0.1 })
        let b = try #require(red.path.controlRect)
        #expect(abs(b.minX - 20) < 0.5 && abs(b.minY - 20) < 0.5 && abs(b.maxX - 120) < 0.5 && abs(b.maxY - 70) < 0.5, "\(b) — y down, at 72 dpi")
        let area = VectorRasterizer.fillCoverage(red.path, rect: PixelRect(x: 0, y: 0, width: 200, height: 100)).reduce(0, +)
        #expect(abs(area - 5000) < 2)
        // As a document shape layer, it renders like the original.
        let layer = red.shapeLayer
        #expect(layer.fill == .solid(red.fill!) && layer.stroke == nil)
        #expect(VectorRasterizer.rasterize(layer, format: .rgba8, clip: PixelRect(x: 0, y: 0, width: 200, height: 100)).pixel(x: 70, y: 45) == [1, 0, 0, 1])
        let at2x = try PDFDocumentIO.vectorShapes(data: try sample(), page: 0, dpi: 144)
        #expect(abs((at2x.first { ($0.fill?.rgb.x ?? 0) > 0.9 }?.path.controlRect?.maxX ?? 0) - 240) < 0.5)
    }

    @Test func textExtractionAndMediaBridgeRasteriser() throws {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 100)
        let ctx = try #require(CGContext(consumer: CGDataConsumer(data: out)!, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Hello PDF text", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        ctx.textPosition = CGPoint(x: 20, y: 40)
        CTLineDraw(line, ctx)
        ctx.endPDFPage(); ctx.closePDF()
        let pdf = out as Data
        #expect(PDFDocumentIO.text(data: pdf)?.contains("Hello PDF text") == true)
        let url = Fixtures.url("pcplatform-text.pdf")
        try pdf.write(to: url)
        let bridge = try PDFDocumentIO.rasterizeViaImageBridge(url: url, dpi: 144)
        let ours = try PDFDocumentIO.rasterize(data: pdf, dpi: 144)
        #expect(bridge.count == 1 && (bridge[0].width, bridge[0].height) == (ours.width, ours.height))
        let mean = Fixtures.meanDiff(ours, bridge[0])
        measure("PDF page at 144 dpi: PCPlatform raster vs media-bridge ImageBridge raster mean |Δ| \(mean * 255)/255")
        #expect(mean < 1.0 / 255)
    }
}
