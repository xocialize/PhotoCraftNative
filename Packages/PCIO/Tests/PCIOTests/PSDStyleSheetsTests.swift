// Port of photocraft-io (crates/io/tests/psd_style_sheets.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// #3795: a PSD type layer's alignment and character attributes can come from its style sheets
// rather than its runs. The reading of the sheets (`alignment_from_the_paragraph_style_the_run_names`,
// `run_overrides_win_and_bad_references_fall_back_to_normal`,
// `character_attributes_from_the_style_sheets`) is TySh-level and lives in PCIOTextTests'
// PSDStyleSheetsIOTests (their layout assertions need the text engine). These are the halves that
// go through whole-file export and import. The layers are saved without pixels (no font renderer).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
@testable import PCIOText
import PCPSD
import Testing
@testable import PCIO

@Suite struct PSDStyleSheetsTests {
    init() { ExportSweep.install() }
    /// Photoshop-shaped EngineData for one paragraph of point text (Normal sheets at index 0).
    static func engine(_ text: String, _ para: PSDEngineData, _ style: PSDEngineData, _ paraSet: [PSDEngineData], _ styleSet: [PSDEngineData]) -> PSDEngineData {
        let edText = text + "\r"
        let n = Int64(edText.utf16.count)
        let res = PSDEngineData.d([
            ("FontSet", .array([.d([("Name", .string("Inter-Regular")), ("Script", .int(0)), ("FontType", .int(1)), ("Synthetic", .int(0))])])),
            ("StyleSheetSet", .array(styleSet)),
            ("ParagraphSheetSet", .array(paraSet)),
            ("TheNormalStyleSheet", .int(0)),
            ("TheNormalParagraphSheet", .int(0)),
        ])
        return .d([
            ("EngineDict", .d([
                ("Editor", .d([("Text", .string(edText))])),
                ("ParagraphRun", .d([("RunArray", .array([.d([("ParagraphSheet", para)])])), ("RunLengthArray", .array([.int(n)]))])),
                ("StyleRun", .d([("RunArray", .array([.d([("StyleSheet", style)])])), ("RunLengthArray", .array([.int(n)]))])),
                ("Rendered", .d([("Shapes", .d([("Children", .array([.d([
                    ("ShapeType", .int(0)),
                    ("Cookie", .d([("Photoshop", .d([("ShapeType", .int(0)), ("PointBase", .array([.real(0), .real(0)]))]))])),
                ])]))]))])),
            ])),
            ("ResourceDict", res),
        ])
    }

    static func normalChar(_ size: Double) -> PSDEngineData {
        .d([("Name", .string("Normal RGB")), ("StyleSheetData", .d([("Font", .int(0)), ("FontSize", .real(size)), ("AutoLeading", .bool(true))]))])
    }

    static func paraSheet(_ name: String, _ justification: Int64, _ defaultStyle: Int64) -> PSDEngineData {
        .d([("Name", .string(name)), ("DefaultStyleSheet", .int(defaultStyle)), ("Properties", .d([("Justification", .int(justification))]))])
    }

    /// A type layer read from a `TySh` built around `ed`, keeping the block as an import does.
    static func layer(_ text: String, _ ed: PSDEngineData) throws -> TextLayer {
        let desc = PSDDescriptor(classID: "TxLr")
            .with("Txt ", .text(.nulTerminated(text)))
            .with("Ornt", .enumerated(type: "Ornt", value: "Hrzn"))
            .with("TextIndex", .integer(0))
            .with("EngineData", .rawData(Data(PSDText.engineDataBytes(ed))))
        let data = PSDText.writeTySh(PSDText.TySh(transform: .translate(450, 300), text: desc))
        var t = try #require(PSDText.textLayer(fromTySh: data, dpi: 72), "parses")
        t.psdRaw = data
        return t
    }

    /// The Title paragraph style (centred, default character style Big = 48 pt) the runs inherit.
    static func titleEngine() -> PSDEngineData {
        engine(
            "LOREM IPSUM",
            .d([("Name", .string("Title")), ("DefaultStyleSheet", .int(1)), ("Properties", .emptyDict)]),
            .d([("StyleSheetData", .emptyDict)]),
            [paraSheet("Normal RGB", 0, 0), paraSheet("Title", 2, 1)],
            [normalChar(12), .d([("Name", .string("Big")), ("StyleSheetData", .d([("FontSize", .real(48))]))])]
        )
    }

    static func roundTrip(_ t: TextLayer, photoshop: Bool) throws -> TextLayer {
        var doc = Document(name: "t", size: PixelSize(width: 900, height: 600), mode: .rgb, depth: .u8)
        doc.resolutionDpi = 72
        doc.layers.append(Layer(name: "t", content: .text(t)))
        let o = MapsKit.options(photoshop: photoshop)
        let bytes = try MapsKit.export(doc, "t.psd", options: o).bytes
        let back = try MapsKit.importFile(bytes, "t.psd", options: o).document
        guard case let .text(bt)? = back.layers.first?.content else { throw PCIOError.unsupported("not a type layer") }
        return bt
    }

    /// Export writes every run fully resolved and keeps the sheet sets: a round trip reads the
    /// same alignment and size.
    @Test(arguments: [false, true]) func stylesFromSheetsSurviveARoundTrip(_ photoshop: Bool) throws {
        let bt = try Self.roundTrip(try Self.layer("LOREM IPSUM", Self.titleEngine()), photoshop: photoshop)
        #expect(bt.paragraphs.first?.style.align == .center)
        #expect(abs((bt.runs.first?.style.sizePt ?? 0) - 48) < 0.01, "\(bt.runs.first?.style.sizePt ?? 0)")
    }

    /// A layer that inherits its alignment and size from sheets it no longer links to (a document
    /// without those styles) keeps them through export: runs are written with what they inherited.
    @Test(arguments: [false, true]) func unlinkedRunsKeepTheirInheritedStyleOnExport(_ photoshop: Bool) throws {
        let t = try Self.layer("LOREM IPSUM", Self.titleEngine())
        #expect(t.psdRaw != nil)
        // No `TextStylesMap.importStyles`: the document has no styles and the runs link to none.
        let bt = try Self.roundTrip(t, photoshop: photoshop)
        #expect(bt.paragraphs.first?.style.align == .center)
        #expect(abs((bt.runs.first?.style.sizePt ?? 0) - 48) < 0.01, "\(bt.runs.first?.style.sizePt ?? 0)")
    }
}
