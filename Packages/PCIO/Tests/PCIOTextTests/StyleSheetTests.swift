// Character/paragraph style sheets in EngineData, and the document's text styles.
// Port of photocraft-text (crates/text/src/psd_styles.rs inline tests) and the parts of
// photocraft-io's tests/psd_style_sheets.rs and tests/text_styles.rs that need no PSD container
// (the export → import pipeline of a type layer is emulated with the functions the PSD exporter
// and importer call: `buildTySh`, `TextStylesMap.exportTySh`, `setTextIndex`,
// `textLayer(fromTySh:)`, `TextStylesMap.importStyles`), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCPSD
import Testing
@testable import PCIOText

@Suite struct PSDStylesTests {
    @Test func namedSheetsRoundTrip() throws {
        var styles = TextStyles()
        styles.character.append(CharacterStyleDef(id: 4, name: "Emphasis", attrs: diffAttrs(charStyle(size: 30) { $0.underline = true }, CharStyle())))
        styles.paragraph.append(ParagraphStyleDef(id: 2, name: "Centered", paraAttrs: diffAttrs(ParagraphStyle(align: .center), ParagraphStyle())))
        let base = charStyle(family: defaultFamily)
        let emph = styles.resolveChar(para: 2, chr: 4, defaultFamily: defaultFamily)
        var layer = TextLayer(text: "plain bold")
        layer.runs = [TextRun(len: 6, style: base), TextRun(len: 4, style: emph)]
        layer.paragraphs = [ParagraphRun(len: 10, style: styles.resolvePara(2))]
        layer.syncSummary()
        let tysh = build(layer)
        #expect(!PSDStyles.hasNamedSheets(tysh))
        let out = try #require(PSDStyles.writeStyleSheets(tysh, layer, styles, dpi: 72))
        #expect(PSDStyles.hasNamedSheets(out))
        let r = try #require(PSDStyles.readStyleSheets(out, dpi: 72))
        #expect(r.charSheets.count == 1)
        #expect(r.charSheets[0].name == "Emphasis")
        #expect(r.charSheets[0].style.sizePt == 30 && r.charSheets[0].style.underline)
        #expect(r.paraSheets[0].name == "Centered")
        #expect(r.paraSheets[0].style.align == .center)
        #expect(r.runChar == [nil, 1])
        #expect(r.runPara == [1])
        // The text itself still reads back the same.
        let back = try #require(load(out))
        #expect(back.text == layer.text)
        #expect(back.charRuns()[1].style.sizePt == 30)
        // No styles: the sets shrink back to the normal sheets.
        let plain = try #require(PSDStyles.writeStyleSheets(out, layer, TextStyles(), dpi: 72))
        #expect(!PSDStyles.hasNamedSheets(plain))
        #expect(try #require(PSDStyles.readStyleSheets(plain, dpi: 72)).runChar.allSatisfy { $0 == nil })
    }

    @Test func malformedInput() {
        #expect(PSDStyles.readStyleSheets([], dpi: 72) == nil)
        #expect(PSDStyles.readStyleSheets([UInt8](repeating: 0, count: 60), dpi: 72) == nil)
        #expect(!PSDStyles.hasNamedSheets(bytes("junk")))
        #expect(PSDStyles.writeStyleSheets([1, 2, 3], TextLayer(), TextStyles(), dpi: 72) == nil)
        #expect(TextStylesMap.exportTySh([1, 2, 3], TextLayer(), TextStyles(), dpi: 72) == nil)
    }
}

// MARK: - psd_style_sheets.rs (#3795)

/// Photoshop-shaped EngineData for one paragraph of point text. `para` is the paragraph run's
/// `ParagraphSheet`, `style` the character run's `StyleSheet`; the sheet sets are the
/// `ResourceDict`'s, with Normal at index 0.
private func engine(_ text: String, _ para: E, _ style: E, _ paraSet: [E], _ styleSet: [E]) -> E {
    let edText = text + "\r"
    let n = Int64(edText.utf16.count)
    let res = E.d([
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

private func normalChar(_ size: Double) -> E {
    .d([("Name", .string("Normal RGB")), ("StyleSheetData", .d([("Font", .int(0)), ("FontSize", .real(size)), ("AutoLeading", .bool(true))]))])
}

private func paraSheet(_ name: String, _ justification: Int64, _ defaultStyle: Int64) -> E {
    .d([("Name", .string(name)), ("DefaultStyleSheet", .int(defaultStyle)), ("Properties", .d([("Justification", .int(justification))]))])
}

/// A type layer read from a `TySh` built around `ed`, keeping the block as an import does.
private func layer(_ text: String, _ ed: E) -> TextLayer {
    let desc = PSDDescriptor(classID: "TxLr")
        .with("Txt ", .text(.nulTerminated(text)))
        .with("Ornt", .enumerated(type: "Ornt", value: "Hrzn"))
        .with("TextIndex", .integer(0))
        .with("EngineData", .rawData(Data(PSDText.engineDataBytes(ed))))
    let data = PSDText.writeTySh(PSDText.TySh(transform: .translate(450, 300), text: desc))
    var t = PSDText.textLayer(fromTySh: data, dpi: 72)!
    t.psdRaw = data
    return t
}

/// What a PSD export then import does to a type layer that has `psdRaw` (the exporter writes
/// `psdRaw`, with its style sheets regenerated when the document or the data has named styles,
/// and renumbers `TextIndex`; the importer reads the block back).
private func exportImport(_ t: TextLayer, _ styles: TextStyles, dpi: Float = 72) -> TextLayer {
    // As photocraft's `psd_export` writes a type layer (with text index 0).
    let generated = t.psdRaw == nil ? PSDText.buildTySh(t, dpi: dpi, ink: nil) : nil
    let src = t.psdRaw ?? generated!
    let styled = TextStylesMap.exportTySh(src, t, styles, dpi: dpi)
    let rewrite = styled ?? generated ?? (PSDText.textIndex(src) != 0 ? src : nil)
    let fresh = rewrite.flatMap { PSDText.setTextIndex($0, 0) }
    let out = fresh ?? styled ?? src
    var back = PSDText.textLayer(fromTySh: out, dpi: dpi)!
    back.psdRaw = out
    return back
}

@Suite struct PSDStyleSheetsIOTests {
    /// The paragraph run names a centred (or right-aligned) paragraph style and overrides nothing.
    @Test func alignmentFromTheParagraphStyleTheRunNames() {
        for (j, want) in [(Int64(2), TextAlign.center), (1, .right)] {
            let ed = engine(
                "LOREM IPSUM",
                .d([("Name", .string("Title")), ("DefaultStyleSheet", .int(0)), ("Properties", .emptyDict)]),
                .d([("StyleSheetData", .emptyDict)]),
                [paraSheet("Normal RGB", 0, 0), paraSheet("Title", j, 0)],
                [normalChar(48)]
            )
            #expect(layer("LOREM IPSUM", ed).paragraphs[0].style.align == want, "Justification \(j) from the paragraph style")
        }
    }

    /// A run's own value still wins over its paragraph style, and an unknown style name or an
    /// out-of-range sheet index falls back to Normal.
    @Test func runOverridesWinAndBadReferencesFallBackToNormal() {
        var ed = engine(
            "Text",
            .d([("Name", .string("Title")), ("DefaultStyleSheet", .int(0)), ("Properties", .d([("Justification", .int(1))]))]),
            .d([("StyleSheetData", .emptyDict)]),
            [paraSheet("Normal RGB", 0, 0), paraSheet("Title", 2, 0)],
            [normalChar(48)]
        )
        #expect(layer("Text", ed).paragraphs[0].style.align == .right)
        ed = engine(
            "Text",
            .d([("Name", .string("Missing")), ("DefaultStyleSheet", .int(9)), ("Properties", .emptyDict)]),
            .d([("Name", .string("Missing")), ("StyleSheetData", .emptyDict)]),
            [paraSheet("Normal RGB", 2, 0)],
            [normalChar(30)]
        )
        let t = layer("Text", ed)
        #expect(t.paragraphs[0].style.align == .center, "Normal's alignment")
        #expect(abs(t.runs[0].style.sizePt - 30) < 0.01, "Normal's size")
    }

    /// Character attributes from the paragraph's default character style (`DefaultStyleSheet`)
    /// and from a character style the run names.
    @Test func characterAttributesFromTheStyleSheets() {
        let big = E.d([("Name", .string("Big")), ("StyleSheetData", .d([("FontSize", .real(72))]))])
        var ed = engine("Text", .d([("DefaultStyleSheet", .int(1)), ("Properties", .emptyDict)]), .d([("StyleSheetData", .emptyDict)]),
                        [paraSheet("Normal RGB", 0, 0)], [normalChar(12), big])
        #expect(abs(layer("Text", ed).runs[0].style.sizePt - 72) < 0.01, "the paragraph's default character style")
        ed = engine("Text", .d([("DefaultStyleSheet", .int(0)), ("Properties", .emptyDict)]), .d([("Name", .string("Big")), ("StyleSheetData", .emptyDict)]),
                    [paraSheet("Normal RGB", 0, 0)], [normalChar(12), big])
        let t = layer("Text", ed)
        #expect(abs(t.runs[0].style.sizePt - 72) < 0.01, "the named character style")
        // Other attributes still come from Normal.
        let normal = layer("Text", engine("Text", .d([("Properties", .emptyDict)]), .d([("StyleSheetData", .emptyDict)]), [paraSheet("Normal RGB", 0, 0)], [normalChar(12)]))
        #expect(t.runs[0].style.fontFamily == normal.runs[0].style.fontFamily)
    }

    /// Export writes every run fully resolved and keeps the sheet sets: a round trip reads the
    /// same alignment and size. (photocraft's `styles_from_sheets_survive_a_round_trip` and
    /// `unlinked_runs_keep_their_inherited_style_on_export`: a document without styles, runs
    /// linked to none.)
    @Test func stylesFromSheetsSurviveARoundTrip() {
        let ed = engine(
            "LOREM IPSUM",
            .d([("Name", .string("Title")), ("DefaultStyleSheet", .int(1)), ("Properties", .emptyDict)]),
            .d([("StyleSheetData", .emptyDict)]),
            [paraSheet("Normal RGB", 0, 0), paraSheet("Title", 2, 1)],
            [normalChar(12), .d([("Name", .string("Big")), ("StyleSheetData", .d([("FontSize", .real(48))]))])]
        )
        let t = layer("LOREM IPSUM", ed)
        #expect(t.psdRaw != nil)
        let bt = exportImport(t, TextStyles())
        #expect(bt.paragraphs[0].style.align == .center)
        #expect(abs(bt.runs[0].style.sizePt - 48) < 0.01)
    }
}

// MARK: - text_styles.rs

@Suite struct TextStylesMapTests {
    static func styles() -> TextStyles {
        var s = TextStyles()
        s.character.append(CharacterStyleDef(id: 3, name: "Loud", attrs: diffAttrs(charStyle(size: 30) { $0.underline = true }, CharStyle())))
        s.paragraph.append(ParagraphStyleDef(id: 1, name: "Middle", paraAttrs: diffAttrs(ParagraphStyle(align: .center), ParagraphStyle())))
        return s
    }

    static func layer(_ styles: TextStyles, link: Bool) -> TextLayer {
        let base = charStyle(family: "Inter")
        let loud = link ? styles.resolveChar(para: nil, chr: 3, defaultFamily: "Inter") : base
        let para = link ? styles.resolvePara(1) : ParagraphStyle()
        var t = TextLayer(text: "calm LOUD")
        t.runs = [TextRun(len: 5, style: base), TextRun(len: 4, style: loud)]
        t.paragraphs = [ParagraphRun(len: 9, style: para)]
        t.transform = .translate(4, 40)
        t.syncSummary()
        return t
    }

    /// A document with one type layer: export (`exportImport`) then the importer's style pass.
    static func roundTrip(_ t: TextLayer, _ styles: TextStyles) -> Document {
        var doc = Document(name: "t", size: PixelSize(width: 200, height: 80), mode: .rgb, depth: .u8)
        doc.layers.append(Layer(name: "t", content: .text(exportImport(t, styles, dpi: doc.resolutionDpi))))
        let warnings = TextStylesMap.importStyles(&doc)
        #expect(warnings.isEmpty)
        return doc
    }

    static func text(_ doc: Document) -> TextLayer {
        guard case let .text(t)? = doc.layers.first?.content else { fatalError("not text") }
        return t
    }

    @Test func namedStylesRoundTripThroughPSD() {
        let back = Self.roundTrip(Self.layer(Self.styles(), link: true), Self.styles())
        let st = back.textStyles
        #expect(st.character.count == 1)
        #expect(st.character.first?.name == "Loud")
        #expect(st.character.first?.attrs["size_pt"] == .number(30))
        #expect(st.character.first?.attrs["underline"] == .bool(true))
        #expect(st.paragraph.first?.name == "Middle")
        #expect(st.paragraph.first?.paraAttrs["align"] == .string("Center"))
        let t = Self.text(back)
        let runs = t.charRuns()
        #expect(runs[0].style.styleSheet == nil)
        #expect(runs[1].style.styleSheet == st.character.first?.id)
        #expect(t.paragraphRuns()[0].style.styleSheet == st.paragraph.first?.id)
        // Export again: stable.
        let back2 = Self.roundTrip(t, st)
        #expect(back2.textStyles.character.count == 1)
        #expect(back2.textStyles.paragraph.count == 1)
    }

    @Test func documentsWithoutStylesKeepTheirTypeData() {
        let back = Self.roundTrip(Self.layer(TextStyles(), link: false), TextStyles())
        #expect(back.textStyles.isEmpty)
        // Re-export of an imported layer without styles keeps TySh byte-exact (only `TextIndex`
        // could change, and it is already 0).
        let raw = Self.text(back).psdRaw
        let back2 = Self.roundTrip(Self.text(back), TextStyles())
        #expect(Self.text(back2).psdRaw == raw)
        #expect(TextStylesMap.exportTySh(raw!, Self.text(back), TextStyles(), dpi: 72) == nil)
        // Deleting every style removes the named sheets on the next save.
        var styled = Self.roundTrip(Self.layer(Self.styles(), link: true), Self.styles())
        styled.textStyles = TextStyles()
        let cleared = Self.roundTrip(Self.text(styled), TextStyles())
        #expect(cleared.textStyles.character.isEmpty && cleared.textStyles.paragraph.isEmpty)
    }

    @Test func importMergesStylesByNameAcrossLayers() throws {
        let styles = Self.styles()
        let a = exportImport(Self.layer(styles, link: true), styles)
        let b = exportImport(Self.layer(styles, link: true), styles)
        var doc = Document(name: "t", size: PixelSize(width: 200, height: 80), mode: .rgb, depth: .u8)
        doc.layers = [Layer(name: "a", content: .text(a)), Layer(name: "b", content: .text(b))]
        #expect(TextStylesMap.importStyles(&doc).isEmpty)
        #expect(doc.textStyles.character.map(\.name) == ["Loud"])
        #expect(doc.textStyles.paragraph.map(\.name) == ["Middle"])
        for l in doc.layers {
            guard case let .text(t) = l.content else { Issue.record("not text"); continue }
            #expect(t.charRuns()[1].style.styleSheet == doc.textStyles.character[0].id)
        }
    }
}
