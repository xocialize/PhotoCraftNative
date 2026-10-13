// Port of photocraft-io crates/io/tests/svg.rs and the tests of crates/io/src/svg.rs (`mod
// tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors. The composite is
// PCIOCore's `StoredPixelsCompositor` (stored pixels, Normal blending, opacity), standing in for
// photocraft-compose's `flatten`.

import CoreGraphics
import Foundation
import ImageIO
import PCDocument
import PCFoundation
import PCIOCore
import Testing
import UniformTypeIdentifiers
@testable import PCIOFormats

private let svgNS = "xmlns=\"http://www.w3.org/2000/svg\""

private func svgOpen(_ svg: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> ImportResult {
    try SVGImport.importDocument(name: "drawing.svg", bytes: Array(svg.utf8))
}

/// The composite at (x, y) as straight RGBA.
private func svgPx(_ d: Document, _ x: Int, _ y: Int) -> [Float] {
    (try? StoredPixelsCompositor().composite(d, rect: PixelRect(x0: Int32(x), y0: Int32(y), x1: Int32(x + 1), y1: Int32(y + 1)))) ?? [0, 0, 0, 0]
}

private func svgClose(_ a: [Float], _ b: [Float]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) < 0.03 } }

private func svgShape(_ l: Layer) -> ShapeLayer? { if case let .shape(s) = l.content { s } else { nil } }
private func svgGroup(_ l: Layer) -> LayerGroup? { if case let .group(g) = l.content { g } else { nil } }
private func svgIsRaster(_ l: Layer) -> Bool { if case .raster = l.content { true } else { false } }

private func svgErrorMessage(_ e: any Error) -> String? {
    if case let PCIOError.format(f, m) = e, f == "SVG" { return m }
    return nil
}

/// A 2×2 PNG (red, green / blue, white) as a data URL, for `<image>`.
private func svgPNGDataURL() -> String {
    let px: [UInt8] = [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]
    let provider = CGDataProvider(data: Data(px) as CFData)!
    let img = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 6, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                      shouldInterpolate: false, intent: .defaultIntent)!
    let out = NSMutableData()
    let dst = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
    return "data:image/png;base64," + (out as Data).base64EncodedString()
}

private func svgNested(_ depth: Int) -> String {
    "<svg \(svgNS) width=\"8\" height=\"8\">\(String(repeating: "<g>", count: depth))<rect width=\"8\" height=\"8\"/>\(String(repeating: "</g>", count: depth))</svg>"
}

@Suite struct SVGImportTests {
    // MARK: crates/io/src/svg.rs tests

    @Test func sniffingAcceptsSVGAndRejectsOtherXML() {
        #expect(SVGImport.isSVG(Array("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)))
        #expect(SVGImport.isSVG(Array("\u{FEFF}<?xml version=\"1.0\"?>\n<!-- hi -->\n<svg/>".utf8)))
        #expect(SVGImport.isSVG(Array("<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"x\"><svg/>".utf8)))
        #expect(!SVGImport.isSVG(Array("<?xml version=\"1.0\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8)))
        #expect(!SVGImport.isSVG([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]))
        #expect(!SVGImport.isSVG([]))
    }

    @Test func quadraticsBecomeCubicsAndClosingMergesTheStartKnot() {
        let p = CGMutablePath()
        p.move(to: .zero)
        p.addQuadCurve(to: CGPoint(x: 10, y: 0), control: CGPoint(x: 5, y: 10))
        p.addLine(to: .zero)
        p.closeSubpath()
        p.move(to: CGPoint(x: 20, y: 20))
        p.addLine(to: CGPoint(x: 30, y: 20))
        let sp = SVGImport.knots(p)
        #expect(sp.count == 2)
        #expect(sp[0].closed && !sp[1].closed)
        // The explicit line back to the start was merged into the first knot.
        #expect(sp[0].knots.count == 2)
        let (a, b) = (sp[0].knots[0], sp[0].knots[1])
        #expect(abs(a.outCtrl.x - 10.0 / 3) < 1e-9 && abs(a.outCtrl.y - 20.0 / 3) < 1e-9)
        #expect(abs(b.inCtrl.x - 20.0 / 3) < 1e-9 && abs(b.inCtrl.y - 20.0 / 3) < 1e-9)
        #expect(b.anchor == PCPoint(10, 0))
        #expect(sp[1].knots.count == 2)
        #expect(sp[1].op == .join)
    }

    @Test func hugeDrawingsScaleToTheSideLimit() throws {
        let p = try SVGImport.parse(Array("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100000 50000\"/>".utf8))
        var w: [String] = []
        let cv = SVGImport.canvas(p.size, &w)
        #expect(cv.size == PixelSize(width: Int(SVGImport.maxSide), height: Int(SVGImport.maxSide / 2)))
        #expect(w.count == 1)
    }

    // MARK: crates/io/tests/svg.rs

    @Test func basicShapesBecomeShapeLayersWithTheirFillsAndStrokes() throws {
        let r = try svgOpen("<svg \(svgNS) width=\"100\" height=\"60\">"
            + "<rect id=\"box\" x=\"10\" y=\"10\" width=\"30\" height=\"20\" fill=\"#ff0000\"/>"
            + "<circle cx=\"70\" cy=\"30\" r=\"15\" fill=\"rgb(0,0,255)\" stroke=\"#000\" stroke-width=\"4\" stroke-linecap=\"round\" stroke-linejoin=\"bevel\"/>"
            + "</svg>")
        let d = r.document
        #expect(d.size == PixelSize(width: 100, height: 60))
        try #require(d.layers.count == 2, "\(d.layers.map(\.name))")
        #expect(d.layers[0].name == "box")
        #expect(d.layers[1].name == "Shape 1", "unnamed shapes are numbered")
        let sh = try #require(svgShape(d.layers[0]))
        #expect(sh.fill == .solid(PCColor.rgb(1, 0, 0, 1)))
        #expect(sh.stroke == nil)
        #expect(sh.path.subpaths.count == 1)
        #expect(sh.path.subpaths[0].closed)
        let c = try #require(svgShape(d.layers[1]))
        let st = try #require(c.stroke)
        #expect(abs(st.width - 4) < 1e-3)
        #expect(st.cap == .round && st.join == .bevel)
        #expect(st.paint == .solid(PCColor.rgb(0, 0, 0, 1)))
        // The composite: red inside the box, blue inside the circle, black on its edge, nothing else.
        #expect(svgClose(svgPx(d, 20, 20), [1, 0, 0, 1]), "\(svgPx(d, 20, 20))")
        #expect(svgClose(svgPx(d, 70, 30), [0, 0, 1, 1]), "\(svgPx(d, 70, 30))")
        #expect(svgClose(svgPx(d, 55, 30), [0, 0, 0, 1]), "\(svgPx(d, 55, 30))")
        #expect(svgPx(d, 3, 3)[3] < 0.01 && svgPx(d, 95, 55)[3] < 0.01)
        #expect(r.warnings.isEmpty, "\(r.warnings)")
    }

    @Test func groupsKeepOpacityBlendAndNestingWhilePlainGroupsVanish() throws {
        let r = try svgOpen("<svg \(svgNS) width=\"40\" height=\"40\">"
            + "<g transform=\"translate(5,5)\">"
            + "<g id=\"art\" opacity=\"0.5\" style=\"mix-blend-mode:multiply\">"
            + "<rect width=\"10\" height=\"10\" fill=\"#00ff00\"/>"
            + "<g id=\"inner\"><rect x=\"10\" width=\"10\" height=\"10\" fill=\"#0000ff\"/></g>"
            + "</g></g></svg>")
        let d = r.document
        try #require(d.layers.count == 1, "the transform-only group is not a layer")
        let art = d.layers[0]
        #expect(art.name == "art")
        #expect(abs(art.opacity - 0.5) < 1e-6)
        #expect(art.blend == .multiply)
        let g = try #require(svgGroup(art))
        #expect(g.children.count == 2)
        #expect(svgShape(g.children[0]) != nil)
        #expect(g.children[1].name == "inner")
        // The translate was baked into the paths: the green square now starts at (5, 5).
        #expect(svgPx(d, 3, 3)[3] < 0.01)
        let p = svgPx(d, 7, 7)
        #expect(p[1] > 0.9 && abs(p[3] - 0.5) < 0.03, "\(p)")
    }

    @Test func groupRasterizationThresholdIsConfigurableAndClamped() throws {
        let source = Array(("<svg \(svgNS) width=\"20\" height=\"20\"><g id=\"outer\"><rect width=\"2\" height=\"2\" fill=\"blue\"/>"
            + "<g id=\"inner\"><rect width=\"10\" height=\"10\" fill=\"red\"/><rect x=\"12\" width=\"5\" height=\"5\" fill=\"green\"/></g></g></svg>").utf8)
        let shallow = try SVGImport.importDocument(name: "nested.svg", bytes: source, maxGroupDepth: 1)
        let outer = try #require(svgGroup(shallow.document.layers[0]), "outer group should remain editable")
        #expect(outer.children.contains(where: svgIsRaster), "the subtree past the setting should be rasterized")
        #expect(shallow.warnings.contains { $0.contains("nested too deeply") })

        let unlimited = try SVGImport.importDocument(name: "nested.svg", bytes: source, maxGroupDepth: 0)
        let outer2 = try #require(svgGroup(unlimited.document.layers[0]), "outer group should remain editable")
        #expect(outer2.children.contains { svgGroup($0) != nil }, "zero disables the preference threshold")

        let clamped = try SVGImport.importDocument(name: "nested.svg", bytes: source, maxGroupDepth: .max)
        #expect(svgGroup(clamped.document.layers[0]) != nil, "out-of-range settings clamp to the document's hard group limit")
    }

    @Test func transformsCurvesAndFillRulesAreInTheKnots() throws {
        let r = try svgOpen("<svg \(svgNS) width=\"60\" height=\"60\">"
            + "<g transform=\"translate(10,20) scale(2)\"><rect width=\"5\" height=\"5\" fill=\"black\"/></g>"
            + "<path d=\"M30 10 Q 40 0 50 10 L 50 20 Z\" fill=\"black\"/>"
            + "<path d=\"M0 40 h20 v20 h-20 z M5 45 h10 v10 h-10 z\" fill=\"black\" fill-rule=\"evenodd\"/>"
            + "</svg>")
        let d = r.document
        let rect = try #require(svgShape(d.layers[0]))
        let xs = rect.path.subpaths[0].knots.map(\.anchor.x), ys = rect.path.subpaths[0].knots.map(\.anchor.y)
        #expect(xs.min() == 10 && xs.max() == 20)
        #expect(ys.min() == 20 && ys.max() == 30)
        let curve = try #require(svgShape(d.layers[1]))
        let k = curve.path.subpaths[0].knots
        try #require(k.count == 3)
        // The quadratic became a cubic: the first knot's leaving handle moved off its anchor.
        #expect(k[0].outCtrl != k[0].anchor && k[1].inCtrl != k[1].anchor)
        #expect(k[1].outCtrl == k[1].anchor, "the straight segment keeps retracted handles")
        let ring = try #require(svgShape(d.layers[2]))
        #expect(ring.path.fillRule == .evenOdd)
        #expect(ring.path.subpaths.count == 2)
        #expect(svgPx(d, 2, 42)[3] > 0.99 && svgPx(d, 10, 50)[3] < 0.01, "even-odd leaves the hole empty")
    }

    @Test func gradientsAreApproximatedWithAWarning() throws {
        let r = try svgOpen("<svg \(svgNS) width=\"100\" height=\"20\">"
            + "<defs><linearGradient id=\"g\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"0\">"
            + "<stop offset=\"0\" stop-color=\"#ff0000\"/><stop offset=\"1\" stop-color=\"#0000ff\" stop-opacity=\"0.5\"/>"
            + "</linearGradient></defs>"
            + "<rect width=\"100\" height=\"20\" fill=\"url(#g)\"/>"
            + "</svg>")
        let sh = try #require(svgShape(r.document.layers[0]))
        guard case let .gradient(g)? = sh.fill else {
            Issue.record("\(String(describing: sh.fill))")
            return
        }
        #expect(g.stops.count == 2)
        #expect(abs(g.stops[1].color.alpha - 0.5) < 1e-6)
        #expect(abs(g.angle) < 1e-3, "left to right is 0°, got \(g.angle)")
        #expect(r.warnings.contains { $0.contains("gradient") }, "\(r.warnings)")
        // Red on the left, bluish on the right.
        let (l, rr) = (svgPx(r.document, 2, 10), svgPx(r.document, 97, 10))
        #expect(l[0] > 0.8 && l[2] < 0.2, "\(l)")
        #expect(rr[2] > rr[0], "\(rr)")
    }

    @Test func clipPathsMasksFiltersPatternsAndImagesAreRasterised() throws {
        let r = try svgOpen("<svg \(svgNS) width=\"60\" height=\"30\">"
            + "<defs>"
            + "<clipPath id=\"c\"><rect width=\"10\" height=\"30\"/></clipPath>"
            + "<pattern id=\"p\" width=\"4\" height=\"4\" patternUnits=\"userSpaceOnUse\"><rect width=\"2\" height=\"4\" fill=\"black\"/></pattern>"
            + "</defs>"
            + "<g id=\"clipped\" clip-path=\"url(#c)\"><rect width=\"30\" height=\"30\" fill=\"#ff0000\"/></g>"
            + "<rect id=\"striped\" x=\"30\" width=\"30\" height=\"30\" fill=\"url(#p)\"/>"
            + "</svg>")
        let d = r.document
        try #require(d.layers.count == 2)
        #expect(svgIsRaster(d.layers[0]), "clipped group is pixels")
        #expect(svgIsRaster(d.layers[1]), "pattern paint is pixels")
        #expect(d.layers.map(\.name) == ["clipped", "striped"])
        #expect(svgClose(svgPx(d, 5, 15), [1, 0, 0, 1]), "\(svgPx(d, 5, 15))")
        #expect(svgPx(d, 20, 15)[3] < 0.01, "clipped away")
        // 4 px tiles with a 2 px bar from the pattern origin: x = 32 is a bar, x = 34 a gap.
        #expect(svgPx(d, 32, 15)[3] > 0.99 && svgPx(d, 34, 15)[3] < 0.01, "stripes: \(svgPx(d, 32, 15)) \(svgPx(d, 34, 15))")
        #expect(r.warnings.contains { $0.contains("clip-path") } && r.warnings.contains { $0.contains("pattern") }, "\(r.warnings)")
        // Masks and filters too.
        let m = try svgOpen("<svg \(svgNS) width=\"20\" height=\"20\"><defs><mask id=\"m\"><rect width=\"10\" height=\"20\" fill=\"white\"/></mask>"
            + "<filter id=\"f\" x=\"-1\" y=\"-1\" width=\"3\" height=\"3\"><feGaussianBlur stdDeviation=\"2\"/></filter></defs>"
            + "<rect id=\"masked\" width=\"20\" height=\"20\" fill=\"blue\" mask=\"url(#m)\"/>"
            + "<rect id=\"blurred\" x=\"8\" y=\"8\" width=\"4\" height=\"4\" fill=\"red\" filter=\"url(#f)\"/></svg>")
        #expect(m.document.layers.map(\.name) == ["masked", "blurred"])
        #expect(m.document.layers.allSatisfy(svgIsRaster))
        #expect(svgClose(svgPx(m.document, 3, 3), [0, 0, 1, 1]) && svgPx(m.document, 15, 3)[3] < 0.01, "\(svgPx(m.document, 3, 3)) \(svgPx(m.document, 15, 3))")
        // The blur spreads past the 4 px square, inside the filter region.
        if let b = m.document.layers[1].surface { #expect(b.contentBounds.width > 6, "\(b.contentBounds)") }
        #expect(m.warnings.contains { $0.contains("mask") } && m.warnings.contains { $0.contains("filter") }, "\(m.warnings)")
    }

    @Test func embeddedRasterImagesBecomePixelLayers() throws {
        let r = try svgOpen("<svg \(svgNS) width=\"20\" height=\"20\"><image id=\"photo\" x=\"0\" y=\"0\" width=\"20\" height=\"20\" href=\"\(svgPNGDataURL())\" style=\"image-rendering:pixelated\"/></svg>")
        let d = r.document
        try #require(d.layers.count == 1)
        #expect(d.layers[0].name == "photo")
        #expect(svgIsRaster(d.layers[0]))
        #expect(svgClose(svgPx(d, 3, 3), [1, 0, 0, 1]), "\(svgPx(d, 3, 3))")
        #expect(svgClose(svgPx(d, 16, 3), [0, 1, 0, 1]), "\(svgPx(d, 16, 3))")
        #expect(svgClose(svgPx(d, 16, 16), [1, 1, 1, 1]), "\(svgPx(d, 16, 16))")
    }

    @Test func textBecomesOutlineShapesOrWarnsWithoutAFont() throws {
        let r = try svgOpen("<svg \(svgNS) width=\"120\" height=\"60\"><text x=\"5\" y=\"45\" font-size=\"48\" font-family=\"Arial, DejaVu Sans, Helvetica, sans-serif\" fill=\"black\">II</text></svg>")
        let d = r.document
        if d.layers.isEmpty {
            #expect(r.warnings.contains { $0.contains("font") }, "\(r.warnings)")
            return
        }
        #expect(d.layers[0].name == "II", "the text names its group")
        let g = try #require(svgGroup(d.layers[0]))
        #expect(!g.children.isEmpty && g.children.allSatisfy { svgShape($0) != nil })
        let dark = (0 ..< 120).filter { svgPx(d, $0, 30)[3] > 0.5 }.count
        #expect(dark > 4, "glyph strokes cross the middle row: \(dark)")
        // Nothing above the cap height or below the baseline.
        #expect((0 ..< 120).allSatisfy { svgPx(d, $0, 50)[3] < 0.01 })
    }

    @Test func sizeComesFromTheViewBoxAndHugeDrawingsShrinkToFit() throws {
        let r = try svgOpen("<svg \(svgNS) viewBox=\"0 0 300 150\"><rect width=\"300\" height=\"150\"/></svg>")
        #expect(r.document.size == PixelSize(width: 300, height: 150))
        let r2 = try svgOpen("<svg \(svgNS) viewBox=\"0 0 100000 50000\"><rect x=\"50000\" width=\"50000\" height=\"50000\" fill=\"black\"/></svg>")
        let d = r2.document
        #expect(d.size == PixelSize(width: Int(SVGImport.maxSide), height: Int(SVGImport.maxSide / 2)))
        #expect(r2.warnings.contains { $0.contains("scaled") }, "\(r2.warnings)")
        // The right half is still the right half.
        let (w, h) = (d.size.width, d.size.height)
        #expect(svgPx(d, w / 4, h / 2)[3] < 0.01 && svgPx(d, 3 * w / 4, h / 2)[3] > 0.99)
    }

    /// 8 000 nested groups is an error, found before the parser runs.
    @Test func deeplyNestedMarkupIsAnErrorNotAStackOverflow() throws {
        let deep = svgNested(8000)
        let gz = try Deflate.gzip(Array(deep.utf8))
        for (name, bytes) in [("deep.svg", Array(deep.utf8)), ("deep.svgz", gz)] {
            do {
                _ = try SVGImport.importDocument(name: name, bytes: bytes)
                Issue.record("\(name) opened")
            } catch {
                let m = svgErrorMessage(error)
                #expect(m?.contains("nested") == true && m?.contains("\(SVGImport.maxXMLDepth)") == true, "\(name): \(error)")
            }
        }
        // Just inside the limit still opens, the empty groups folded away.
        let r = try svgOpen(svgNested(SVGImport.maxXMLDepth - 1))
        #expect(r.document.layers.count == 1)
    }

    /// The depth check reads the markup: it must not count `<` in comments, CDATA, processing
    /// instructions or the DOCTYPE, nor end a tag at a `>` inside quotes.
    @Test func theDepthCheckSkipsCommentsCDATADoctypeAndQuotedMarkup() throws {
        let g = String(repeating: "<g>", count: SVGImport.maxXMLDepth + 10)
        let svg = "<?xml version=\"1.0\"?><!-- \(g) --><!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd\">"
            + "<svg \(svgNS) width=\"8\" height=\"8\"><desc><![CDATA[ \(g) ]]></desc><?pi \(g) ?>"
            + "<g id='a>b' data-x=\"c/>d\"><rect width=\"8\" height=\"8\" fill=\"#ff0000\"/></g><!-- \(g) --></svg>"
        let r = try svgOpen(svg)
        #expect(r.document.layers.count == 1)
        #expect(svgClose(svgPx(r.document, 4, 4), [1, 0, 0, 1]))
    }

    @Test func svgzIsInflatedWithASizeCap() throws {
        let plain = "<svg \(svgNS) width=\"8\" height=\"8\"><rect width=\"8\" height=\"8\" fill=\"#0000ff\"/></svg>"
        let r = try SVGImport.importDocument(name: "drawing.svgz", bytes: try Deflate.gzip(Array(plain.utf8)))
        #expect(r.document.layers.count == 1)
        #expect(svgClose(svgPx(r.document, 4, 4), [0, 0, 1, 1]))
        // A bomb: a few hundred KB of gzip holding more than the cap of whitespace.
        var bomb = Array("<svg \(svgNS) width=\"8\" height=\"8\">".utf8)
        bomb += [UInt8](repeating: 0x20, count: Int(SVGImport.maxInflatedBytes) + 1024 - bomb.count)
        bomb += Array("</svg>".utf8)
        let gz = try Deflate.gzip(bomb)
        #expect(gz.count < 2 << 20, "\(gz.count) bytes compressed")
        do {
            _ = try SVGImport.importDocument(name: "bomb.svgz", bytes: gz)
            Issue.record("the bomb opened")
        } catch {
            #expect(svgErrorMessage(error)?.contains("inflates past") == true, "\(error)")
        }
        // Corrupt gzip is an error too.
        #expect(throws: PCIOError.self) { try SVGImport.importDocument(name: "bad.svgz", bytes: [0x1F, 0x8B, 0x08, 0x00, 0xFF, 0xFF]) }
    }

    @Test func sniffedAndRefusedWhenMalformed() throws {
        let svg = "<?xml version=\"1.0\"?>\n<svg \(svgNS) width=\"8\" height=\"8\"><rect width=\"8\" height=\"8\"/></svg>"
        #expect(SVGImport.isSVG(Array(svg.utf8)))
        #expect(try SVGImport.importDocument(name: "mystery.bin", bytes: Array(svg.utf8)).document.layers.count == 1)
        for bad in ["<svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect", "not xml at all", "", "<html/>"] {
            do {
                _ = try SVGImport.importDocument(name: "x.svg", bytes: Array(bad.utf8))
                Issue.record("\(bad) opened")
            } catch {
                #expect(svgErrorMessage(error) != nil, "\(bad): \(error)")
            }
        }
        let empty = try svgOpen("<svg \(svgNS) width=\"8\" height=\"8\"/>")
        #expect(empty.document.layers.isEmpty)
        #expect(empty.warnings.contains { $0.contains("nothing") }, "\(empty.warnings)")
    }

    @Test func rasterizeRendersTheWholeDrawingAtAScale() throws {
        let svg = Array("<svg \(svgNS) width=\"20\" height=\"10\"><rect x=\"0\" y=\"4\" width=\"20\" height=\"0.5\" fill=\"black\"/></svg>".utf8)
        let b = try SVGImport.rasterize(svg, 10)
        #expect(b.width == 200 && b.height == 100)
        func a(_ x: Int, _ y: Int) -> Float { b.pixels[y * b.width + x].w }
        // The half-unit line is a crisp 5 px band at 10×.
        #expect(a(100, 39) < 0.01 && a(100, 42) > 0.99 && a(100, 45) < 0.01, "\(a(100, 39)) \(a(100, 42)) \(a(100, 45))")
        let one = try SVGImport.rasterize(svg, 1)
        #expect(one.width == 20 && one.height == 10)
        let huge = Array("<svg \(svgNS) width=\"10000\" height=\"10000\"><rect width=\"10\" height=\"10\"/></svg>".utf8)
        #expect(throws: PCIOError.self, "a render past the pixel cap is an error, not an allocation") { try SVGImport.rasterize(huge, 64) }
    }

    @Test func imageHrefsToLocalFilesAreNeverRead() throws {
        // A real PNG on disk, referenced by absolute path and as a file URL: opening an untrusted
        // drawing must not pull it in (only `data:` URLs resolve).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svg-local-image-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("secret.png")
        let b64 = String(svgPNGDataURL().dropFirst("data:image/png;base64,".count))
        try Data(base64Encoded: b64)!.write(to: file)
        let path = file.path
        for href in [path, "file://\(path)", "secret.png"] {
            let r = try svgOpen("<svg \(svgNS) width=\"20\" height=\"20\"><image x=\"0\" y=\"0\" width=\"20\" height=\"20\" href=\"\(href)\"/></svg>")
            let d = r.document
            #expect(d.layers.allSatisfy { !svgIsRaster($0) }, "\(href): \(d.layers.count)")
            #expect(svgPx(d, 10, 10)[3] < 0.01, "\(href): \(svgPx(d, 10, 10))")
        }
        // The same picture as a data URL still loads.
        let ok = try svgOpen("<svg \(svgNS) width=\"20\" height=\"20\"><image width=\"20\" height=\"20\" href=\"\(svgPNGDataURL())\"/></svg>")
        #expect(ok.document.layers.first.map(svgIsRaster) == true)
        // Not even inside a rasterised group (CoreSVG would read the file).
        let g = try svgOpen("<svg \(svgNS) width=\"20\" height=\"20\"><defs><filter id=\"f\"><feOffset/></filter></defs>"
            + "<g filter=\"url(#f)\"><image width=\"20\" height=\"20\" xlink:href=\"file://\(path)\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"/>"
            + "<rect width=\"1\" height=\"1\"/></g></svg>")
        #expect(svgPx(g.document, 10, 10)[3] < 0.01)
    }

    @Test func tooManyElementsOpenAsOnePixelLayer() throws {
        var many = "<svg \(svgNS) width=\"100\" height=\"100\">"
        for i in 0 ... SVGImport.maxNodes { many += "<rect x=\"\(i % 100)\" y=\"\(i / 100)\" width=\"1\" height=\"1\"/>" }
        many += "</svg>"
        let r = try svgOpen(many)
        #expect(r.document.layers.map(\.name) == ["Background"])
        #expect(svgIsRaster(r.document.layers[0]))
        #expect(r.warnings.contains { $0.contains("more than \(SVGImport.maxNodes) elements") }, "\(r.warnings)")
        #expect(svgPx(r.document, 5, 5)[3] > 0.99 && svgPx(r.document, 50, 50)[3] < 0.01)
    }

    // MARK: Beyond photocraft's tests: the native front end

    @Test func cssStyleSheetsUseAndSymbols() throws {
        let r = try svgOpen("<svg \(svgNS) xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"40\" height=\"20\">"
            + "<style>/* sheet */ .red { fill: #f00 } g > #b { fill: rgb(0, 255, 0) !important } rect.big { stroke: none }</style>"
            + "<defs><rect id=\"tile\" width=\"5\" height=\"5\"/></defs>"
            + "<rect id=\"a\" class=\"red big\" width=\"5\" height=\"5\"/>"
            + "<g><rect id=\"b\" x=\"10\" width=\"5\" height=\"5\" style=\"fill:blue\"/></g>"
            + "<use id=\"u\" xlink:href=\"#tile\" x=\"20\" fill=\"hsl(240, 100%, 50%)\"/>"
            + "<rect id=\"cc\" x=\"30\" width=\"5\" height=\"5\" style=\"color: #ff00ff\" fill=\"currentColor\"/>"
            + "</svg>")
        let d = r.document
        #expect(d.layers.map(\.name) == ["a", "b", "u", "cc"], "\(d.layers.map(\.name))")
        #expect(svgClose(svgPx(d, 2, 2), [1, 0, 0, 1]), "class selector: \(svgPx(d, 2, 2))")
        #expect(svgClose(svgPx(d, 12, 2), [0, 1, 0, 1]), "!important beats style: \(svgPx(d, 12, 2))")
        #expect(svgClose(svgPx(d, 22, 2), [0, 0, 1, 1]), "use inherits and translates: \(svgPx(d, 22, 2))")
        #expect(svgClose(svgPx(d, 32, 2), [1, 0, 1, 1]), "currentColor: \(svgPx(d, 32, 2))")
        // A symbol through `use` is a clipped viewport: pixels, like usvg's clip.
        let s = try svgOpen("<svg \(svgNS) width=\"20\" height=\"20\"><defs><symbol id=\"s\" viewBox=\"0 0 10 10\"><rect width=\"10\" height=\"10\" fill=\"lime\"/></symbol></defs>"
            + "<use href=\"#s\" x=\"5\" y=\"5\" width=\"10\" height=\"10\"/></svg>")
        #expect(s.document.layers.count == 1 && svgIsRaster(s.document.layers[0]))
        #expect(svgClose(svgPx(s.document, 10, 10), [0, 1, 0, 1]) && svgPx(s.document, 2, 2)[3] < 0.01, "\(svgPx(s.document, 10, 10))")
        // Cyclic references are dropped, not followed.
        let cyc = try svgOpen("<svg \(svgNS) width=\"8\" height=\"8\"><g id=\"x\"><use href=\"#x\"/><rect width=\"8\" height=\"8\"/></g></svg>")
        #expect(cyc.document.layers.count == 1)
    }

    @Test func rasterisedElementsKeepTheirPlaceAndPercentLengths() throws {
        // A clipped group drawn left of its parent's origin, sized in `%` of the drawing.
        let r = try svgOpen("<svg \(svgNS) width=\"100\" height=\"20\"><defs><clipPath id=\"c\"><rect x=\"-40\" width=\"30\" height=\"20\"/></clipPath></defs>"
            + "<g transform=\"translate(60,0)\"><g id=\"k\" clip-path=\"url(#c)\"><rect x=\"-40\" width=\"80\" height=\"100%\" fill=\"red\"/></g></g></svg>")
        let d = r.document
        #expect(d.layers.map(\.name) == ["k"])
        #expect(svgClose(svgPx(d, 25, 10), [1, 0, 0, 1]) && svgClose(svgPx(d, 25, 18), [1, 0, 0, 1]), "\(svgPx(d, 25, 10)) \(svgPx(d, 25, 18))")
        #expect(svgPx(d, 15, 10)[3] < 0.01 && svgPx(d, 55, 10)[3] < 0.01, "clipped to 20...50")
    }

    @Test func arcsDashesOpacityAndEntities() throws {
        let r = try svgOpen("<?xml version=\"1.0\"?><!DOCTYPE svg [<!ENTITY red \"#ff0000\">]>"
            + "<svg \(svgNS) width=\"40\" height=\"40\">"
            + "<path id=\"arc\" d=\"M10 20 A10 10 0 0 1 30 20 Z\" fill=\"&red;\"/>"
            + "<line id=\"dash\" x1=\"0\" y1=\"35\" x2=\"40\" y2=\"35\" stroke=\"black\" stroke-width=\"2\" stroke-dasharray=\"4 2\" stroke-dashoffset=\"1\"/>"
            + "<rect id=\"half\" x=\"30\" width=\"10\" height=\"10\" fill=\"blue\" opacity=\"0.5\"/>"
            + "</svg>")
        let d = r.document
        #expect(d.layers.map(\.name) == ["arc", "dash", "half"])
        #expect(svgClose(svgPx(d, 20, 15), [1, 0, 0, 1]), "arc: \(svgPx(d, 20, 15))")
        #expect(svgPx(d, 20, 25)[3] < 0.01)
        let dash = try #require(svgShape(d.layers[1])?.stroke)
        #expect(dash.dashes == [2, 1] && dash.dashOffset == 0.5)
        #expect(abs(d.layers[2].opacity - 0.5) < 1e-6)
    }
}
