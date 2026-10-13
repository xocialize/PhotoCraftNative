// Port of photocraft-io (crates/io/tests/psd_type_bounds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Imported type-layer geometry (#148): PSD type layers built the way Photoshop writes them (a
// `TySh` with the text-space → document transform, `EngineData` with `StyleRun`/`ParagraphRun`
// sizes in text-space units, `BoxBounds` for paragraph text, `bounds`/`boundingBox`) must come
// back from a whole-file export and import with the right model, with the layer's pixels
// (Photoshop's cache) keeping their full extent, and with a composite equal to the file's merged
// image. The TySh-level model checks are PCIOTextTests' PSDTypeBoundsIOTests.
//
// PCIO has no font renderer: "Photoshop's pixels" are a stand-in raster (an opaque block at the
// text origin, MapsKit's `standInText`), and the import-time rendering of layers without pixels
// goes through that injected renderer. Not ported: the glyph checks (re-rendering the imported
// model lands on Photoshop's pixels with IoU > 0.97, `point_text_height_follows_the_type_size`,
// the 256 Mpx precondition of the hostile sizes) — they measure the text engine, not PCIO;
// `blank_engine_text_is_not_rendered_on_import` is TySh-level (PSDTypeBoundsIOTests).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
@testable import PCIOText
import PCPSD
import PCRender
import Testing
@testable import PCIO

@Suite struct PSDTypeBoundsTests {
    init() { ExportSweep.install() }
    /// One character run: (UTF-16 length, font size in text-space units, explicit leading).
    struct Run {
        var len: Int
        var size: Double
        var leading: Double?
    }

    /// A run's style sheet data with every key Photoshop writes (PCIOText's full set, Photoshop's
    /// defaults), the size and leading in text-space units, black fill.
    static func style(_ size: Double, _ leading: Double?) -> PSDEngineData {
        var d = PSDText.styleSheetData(CharStyle(), 0, 1)
        d.put("FontSize", .real(size))
        d.put("AutoLeading", .bool(leading == nil))
        d.put("Leading", .real(leading ?? 0))
        d.put("FillColor", .d([("Type", .int(1)), ("Values", .array([.real(1), .real(0), .real(0), .real(0)]))]))
        return d
    }

    /// Photoshop-shaped EngineData for `text` (paragraphs separated by `\r`), with every structure
    /// Photoshop writes and needs to open the file (PCPSD `missingPhotoshopStructures()` is empty:
    /// without them Photoshop 27.11 crashes on open or refuses the file).
    static func engineData(_ text: String, _ runs: [Run], _ boxBounds: [Double]?, _ font: String) -> PSDEngineData {
        let edText = text + "\r"
        let n16 = Int64(edText.utf16.count)
        var sruns: [PSDEngineData] = []
        var slens: [PSDEngineData] = []
        for (i, r) in runs.enumerated() {
            sruns.append(.d([("StyleSheet", .d([("StyleSheetData", style(r.size, r.leading))]))]))
            slens.append(.int(Int64(r.len) + (i + 1 == runs.count ? 1 : 0)))
        }
        var para = PSDText.paragraphProperties(ParagraphStyle(), 1)
        para.put("Justification", .int(0))
        para.put("AutoLeading", .real(1.2))
        let shapeType: Int64 = boxBounds == nil ? 0 : 1
        var photoshop: [(String, PSDEngineData)] = [("ShapeType", .int(shapeType))]
        if let b = boxBounds { photoshop.append(("BoxBounds", .array(b.map { .real($0) }))) } else { photoshop.append(("PointBase", .array([.real(0), .real(0)]))) }
        photoshop.append(("Base", .d([("ShapeType", .int(shapeType)), ("TransformPoint0", .array([.real(1), .real(0)])),
                                      ("TransformPoint1", .array([.real(0), .real(1)])), ("TransformPoint2", .array([.real(0), .real(0)]))])))
        let shape = PSDEngineData.d([("ShapeType", .int(shapeType)), ("Procession", .int(0)),
                                     ("Lines", .d([("WritingDirection", .int(0)), ("Children", .array([]))])),
                                     ("Cookie", .d([("Photoshop", .d(photoshop))]))])
        let resources = PSDEngineData.d([
            ("FontSet", .array([PSDText.fontEntry(font)])),
            ("StyleSheetSet", .array([.d([("Name", .string("Normal RGB")), ("StyleSheetData", style(12, nil))])])),
            ("ParagraphSheetSet", .array([.d([("Name", .string("Normal RGB")), ("DefaultStyleSheet", .int(0)), ("Properties", para)])])),
            ("TheNormalStyleSheet", .int(0)),
            ("TheNormalParagraphSheet", .int(0)),
        ])
        return .d([
            ("EngineDict", .d([
                ("Editor", .d([("Text", .string(edText))])),
                ("ParagraphRun", .d([("RunArray", .array([.d([("ParagraphSheet", .d([("DefaultStyleSheet", .int(0)), ("Properties", para)]))])])),
                                     ("RunLengthArray", .array([.int(n16)])), ("IsJoinable", .int(1))])),
                ("StyleRun", .d([("RunArray", .array(sruns)), ("RunLengthArray", .array(slens)), ("IsJoinable", .int(2))])),
                ("GridInfo", .d([("GridIsOn", .bool(false)), ("ShowGrid", .bool(false)), ("GridSize", .real(18)), ("GridLeading", .real(22))])),
                ("AntiAlias", .int(3)),
                ("UseFractionalGlyphWidths", .bool(true)),
                ("Rendered", .d([("Version", .int(1)), ("Shapes", .d([("WritingDirection", .int(0)), ("Children", .array([shape]))]))])),
            ])),
            ("ResourceDict", resources),
            ("DocumentResources", resources),
        ])
    }

    /// A `TySh` block as Photoshop writes it, whose runs use the font with PostScript name `font`.
    static func tysh(_ text: String, _ runs: [Run], _ boxBounds: [Double]?, _ transform: PCAffine, _ ink: [Double], font: String = "Inter-Regular") -> [UInt8] {
        func rect(_ cls: String) -> PSDDescriptor.Value {
            .descriptor(PSDDescriptor(classID: PSDDescriptor.ID(cls))
                .with("Left", .unitFloat(unit: "#Pnt", value: ink[0]))
                .with("Top ", .unitFloat(unit: "#Pnt", value: ink[1]))
                .with("Rght", .unitFloat(unit: "#Pnt", value: ink[2]))
                .with("Btom", .unitFloat(unit: "#Pnt", value: ink[3])))
        }
        let desc = PSDDescriptor(classID: "TxLr")
            .with("Txt ", .text(.nulTerminated(text)))
            .with("textGridding", .enumerated(type: "textGridding", value: "None"))
            .with("Ornt", .enumerated(type: "Ornt", value: "Hrzn"))
            .with("AntA", .enumerated(type: "Annt", value: "AnSm"))
            .with("bounds", rect("bounds"))
            .with("boundingBox", rect("boundingBox"))
            .with("TextIndex", .integer(0))
            .with("EngineData", .rawData(Data(PSDText.engineDataBytes(engineData(text, runs, boxBounds, font)))))
        // Unwarped type: Photoshop writes four zero f32s after the warp descriptor.
        return PSDText.writeTySh(PSDText.TySh(transform: transform, text: desc))
    }

    struct Case {
        var name: String
        var dpi: Float
        var text: String
        var runs: [Run]
        var boxBounds: [Double]?
        var transform: PCAffine
        /// Expected Character-panel size of the first run, in points.
        var sizePt: Float
    }

    static func cases() -> [Case] {
        func r(_ len: Int, _ size: Double) -> Run { Run(len: len, size: size, leading: nil) }
        func t(_ x: Double, _ y: Double) -> PCAffine { .translate(x, y) }
        // Photoshop keeps the font size in text space and the scale in the transform.
        func scaled(_ s: Double, _ x: Double, _ y: Double) -> PCAffine { PCAffine(m: [s, 0, 0, s, x, y]) }
        func rotated(_ deg: Double, _ s: Double, _ x: Double, _ y: Double) -> PCAffine {
            let (sn, cs) = (sin(deg * .pi / 180), cos(deg * .pi / 180))
            return PCAffine(m: [s * cs, s * sn, -s * sn, s * cs, x, y])
        }
        return [
            Case(name: "point 36pt @72", dpi: 72, text: "Headline 105: Autumn collection", runs: [r(31, 36)], boxBounds: nil, transform: t(40, 80), sizePt: 36),
            Case(name: "point 36pt @300", dpi: 300, text: "Headline 105: Autumn collection", runs: [r(31, 150)], boxBounds: nil, transform: t(40, 200), sizePt: 36),
            Case(name: "point 12×3 scaled", dpi: 72, text: "Headline 105: Autumn collection", runs: [r(31, 12)], boxBounds: nil, transform: scaled(3, 40, 80), sizePt: 12),
            Case(name: "point rotated", dpi: 72, text: "Autumn collection", runs: [r(17, 18)], boxBounds: nil, transform: rotated(-20, 2, 60, 300), sizePt: 18),
            Case(name: "point multi-line", dpi: 72, text: "Headline\rAutumn collection\rgy", runs: [Run(len: 29, size: 36, leading: 50)], boxBounds: nil,
                 transform: t(40, 60), sizePt: 36),
            Case(name: "point mixed sizes", dpi: 72, text: "Big small Big", runs: [r(4, 60), r(6, 14), r(3, 60)], boxBounds: nil, transform: t(30, 120), sizePt: 60),
            Case(name: "paragraph box", dpi: 72, text: "Paragraph text that wraps over several lines in its box", runs: [r(55, 24)],
                 boxBounds: [0, 0, 260, 200], transform: t(20, 20), sizePt: 24),
            Case(name: "paragraph box scaled", dpi: 144, text: "Paragraph text that wraps over several lines in its box", runs: [r(55, 20)],
                 boxBounds: [0, 0, 200, 150], transform: scaled(1.5, 20, 20), sizePt: 10),
        ]
    }

    /// A stand-in for the text engine's raster: an opaque block at the text origin, as tall as the
    /// first run's size and 0.6 em per character, scaled by the transform; nil when it would exceed
    /// `maxPixels` (the engine's guard).
    static let standInText: @Sendable (TextLayer, PixelFormat, Float, UInt64) -> Surface? = { t, fmt, dpi, maxPixels in
        let tr = t.transform
        let scale = abs(tr.a * tr.d - tr.b * tr.c).squareRoot()
        let em = Double(t.runs.first?.style.sizePt ?? t.sizePt) * Double(dpi) / 72 * scale
        let w = em * 0.6 * Double(max(t.text.count, 1)), h = em
        guard w.isFinite, h.isFinite, w * h <= Double(maxPixels), tr.e.isFinite, tr.f.isFinite, abs(tr.e) < 1e6, abs(tr.f) < 1e6 else { return nil }
        let r = PixelRect(x: Int(tr.e.rounded()), y: Int((tr.f - h).rounded()), width: max(Int(w.rounded()), 1), height: max(Int(h.rounded()), 1))
        var s = Surface(format: fmt)
        var px = [Float](repeating: 0, count: fmt.channels)
        px[fmt.channels - 1] = 1
        s.fill(r, with: px)
        return s
    }

    static func renderer() -> MapsKit.Renderer { MapsKit.Renderer(text: standInText) }

    /// Builds a one-layer document whose type layer carries the Photoshop-shaped `TySh` and
    /// "Photoshop's" pixels (the stand-in raster of the parsed model), exports it to PSD and imports
    /// it back: (drawn bounds, imported layer, imported document, the file's merged image).
    static func importCase(_ c: Case, photoshop: Bool = false) throws -> (PixelRect, TextLayer, Document, [SIMD4<Float>]) {
        var doc = Document(name: "t", size: PixelSize(width: 900, height: 700), mode: .rgb, depth: .u8)
        doc.resolutionDpi = c.dpi
        let data = tysh(c.text, c.runs, c.boxBounds, c.transform, [0, 0, 0, 0])
        var t = try #require(PSDText.textLayer(fromTySh: data, dpi: c.dpi), "\(c.name)")
        let pixels: Surface = try #require(standInText(t, doc.pixelFormat, c.dpi, TextImport.maxRenderPixels))
        t.cache = pixels
        let drawn = t.cache?.contentBounds ?? .empty
        t.psdRaw = data
        doc.layers.append(Layer(name: c.name, content: .text(t)))
        let o = MapsKit.options(photoshop: photoshop, renderer: renderer())
        let bytes = try MapsKit.export(doc, "t.psd", options: o).bytes
        let file = try PSDFile(bytes: bytes)
        let merged = try mergedPixels(file, doc)
        let n = doc.pixelFormat.channels
        let px = (0 ..< doc.size.width * doc.size.height).map { i in SIMD4(merged[i * n], merged[i * n + 1], merged[i * n + 2], merged[i * n + 3]) }
        let back = try MapsKit.importFile(bytes, "t.psd", options: o).document
        guard case let .text(bt) = back.layers.first?.content else { throw PCIOError.unsupported("\(c.name): not a type layer") }
        return (drawn, bt, back, px)
    }

    @Test(arguments: [false, true]) func importedTypeLayersKeepTheirFullBounds(_ photoshop: Bool) throws {
        for c in Self.cases() {
            let (drawn, t, doc, merged) = try Self.importCase(c, photoshop: photoshop)
            #expect(!drawn.isEmpty, "\(c.name): nothing drawn")
            // Model: size in points at the document resolution, transform and shape as written.
            #expect(abs(t.runs[0].style.sizePt - c.sizePt) < 0.01, "\(c.name): size \(t.runs[0].style.sizePt) pt, want \(c.sizePt)")
            #expect(t.transform == c.transform, "\(c.name)")
            switch (c.boxBounds, t.shape) {
            case (nil, .point): break
            case let (b?, .box(box)): #expect([box.x, box.y, box.x + box.width, box.y + box.height].map(Double.init) == b, "\(c.name)")
            default: Issue.record("\(c.name): shape \(t.shape), want box \(String(describing: c.boxBounds))")
            }
            // The imported pixels (what the canvas shows, and what Properties measures) are the
            // whole of Photoshop's rendering.
            #expect(t.cache?.contentBounds == drawn, "\(c.name): imported pixels clipped")
            #expect(LayerGeometry.layerBounds(doc.layers[0], canvas: doc.bounds) == drawn, "\(c.name): layer bounds")
            // And the document composite is the file's merged composite.
            let worst = MapsKit.maxDiff(try MapsKit.flatten(doc).px, merged)
            #expect(worst <= 2.0 / 255, "\(c.name): composite differs from the merged image by \(worst)")
        }
    }

    @Test func typeLayersWithoutPixelsAreRenderedOnImport() throws {
        // ag-psd, GIMP and other writers leave type layers without image data (Photoshop re-renders
        // them on open). The model must import and the layer must be drawn from it by the injected
        // renderer, not shown as empty pixels until it is edited.
        let c = Self.cases()[0]
        var doc = Document(name: "t", size: PixelSize(width: 900, height: 700), mode: .rgb, depth: .u8)
        doc.resolutionDpi = c.dpi
        let data = Self.tysh(c.text, c.runs, c.boxBounds, c.transform, [40, 50, 400, 110])
        var t = try #require(PSDText.textLayer(fromTySh: data, dpi: c.dpi))
        t.cache = nil
        t.psdRaw = data
        doc.layers.append(Layer(name: c.name, content: .text(t)))
        let o = MapsKit.options(renderer: Self.renderer())
        let bytes = try MapsKit.export(doc, "t.psd", options: o).bytes
        let back = try MapsKit.importFile(bytes, "t.psd", options: o).document
        guard case let .text(bt) = back.layers.first?.content else {
            Issue.record("not a type layer")
            return
        }
        #expect(bt.text == c.text)
        let drawn = try #require(bt.cache, "rendered on import").contentBounds
        #expect(!drawn.isEmpty, "nothing rendered")
        // The same model rendered again lands on the same pixels.
        #expect(Self.standInText(bt, back.pixelFormat, back.resolutionDpi, TextImport.maxRenderPixels)?.contentBounds == drawn)
        // With pixels in the file, they stay the cache (Photoshop's rendering is authoritative).
        let (fileDrawn, kept, _, _) = try Self.importCase(c)
        #expect(kept.cache?.contentBounds == fileDrawn)
    }

    @Test func postscriptFontNamesResolveToTheInstalledFamilyOnImport() throws {
        // The family guessed from a PostScript name is not always the installed one: JetBrains Mono
        // is "JetBrainsMono-Regular", which splits into "Jet Brains Mono". The run must name the
        // family the font database (the injected renderer's) really has.
        let c = Self.cases()[0]
        var doc = Document(name: "t", size: PixelSize(width: 900, height: 700), mode: .rgb, depth: .u8)
        doc.resolutionDpi = c.dpi
        let data = Self.tysh(c.text, c.runs, c.boxBounds, c.transform, [40, 50, 400, 110], font: "JetBrainsMono-Regular")
        var t = try #require(PSDText.textLayer(fromTySh: data, dpi: c.dpi))
        #expect(t.runs[0].style.fontFamily == "Jet Brains Mono", "the guess the import must correct")
        t.cache = nil
        t.psdRaw = data
        doc.layers.append(Layer(name: c.name, content: .text(t)))
        let fonts = MapsKit.Renderer(text: Self.standInText, families: ["JetBrains Mono", "Inter"],
                                     postscript: ["JetBrainsMono-Regular": ResolvedFont(family: "JetBrains Mono", weight: 400, italic: false, exact: true)])
        let o = MapsKit.options(renderer: fonts)
        let bytes = try MapsKit.export(doc, "t.psd", options: o).bytes
        let back = try MapsKit.importFile(bytes, "t.psd", options: o).document
        guard case let .text(bt) = back.layers.first?.content else {
            Issue.record("not a type layer")
            return
        }
        #expect(bt.runs[0].style.fontFamily == "JetBrains Mono")
        #expect(bt.runs[0].style.postscriptName == "JetBrainsMono-Regular")
        #expect(bt.cache.map { !$0.contentBounds.isEmpty } == true)
    }

    @Test func hostileTypeSizesWithoutPixelsImportWithoutAHugeRender() throws {
        // The import renders type layers that come without pixels; the model is untrusted, so an
        // absurd size or scale must not make opening the file allocate gigabytes (or fail): the
        // renderer gets the import's limit and an empty cache stands in when it refuses.
        func scaled(_ s: Double) -> PCAffine { PCAffine(m: [s, 0, 0, s, 10, 10]) }
        for (size, transform) in [(12.0, scaled(1100)), (1.0e30, scaled(1)), (12, scaled(1.0e12)), (Double.greatestFiniteMagnitude, scaled(.greatestFiniteMagnitude))] {
            let data = Self.tysh("M", [Run(len: 1, size: size, leading: nil)], nil, transform, [10, 10, 20, 20])
            var t = try #require(PSDText.textLayer(fromTySh: data, dpi: 72), "\(size)")
            t.cache = nil
            t.psdRaw = data
            var doc = Document(name: "t", size: PixelSize(width: 64, height: 64), mode: .rgb, depth: .u8)
            doc.layers.append(Layer(name: "hostile", content: .text(t)))
            let o = MapsKit.options(renderer: Self.renderer())
            // Hostile on purpose: Photoshop rasterizes such type (1e30 pt), with a modal for
            // Double.max; not part of the Photoshop acceptance set.
            let bytes = try ExportSweep.excluded {
                try MapsKit.export(doc, "t.psd", options: o, knownLintIssue: "hostile on purpose: PCPSD typeSizeOutOfRange (PHOTOSHOP RASTERIZES THE TYPE LAYER)").bytes
            }
            let back = try MapsKit.importFile(bytes, "t.psd", options: o).document
            guard case let .text(bt) = back.layers.first?.content else {
                Issue.record("not a type layer")
                continue
            }
            let cache = try #require(bt.cache, "a cache, even if empty")
            #expect(cache.contentBounds.isEmpty, "size \(size): drew \(cache.contentBounds)")
        }
        #expect(TextImport.maxRenderPixels == 64 * 1024 * 1024)
    }
}
