// Port of photocraft-io (crates/io/tests/text_styles.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Character and paragraph styles through PSD: named sheets in the type layers' engine data, run
// references, and untouched files staying byte-exact — through whole-file export and import (the
// emulated pipeline is PCIOTextTests' TextStylesMapTests). The layers are saved without pixels
// (no font renderer).

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Testing
@testable import PCIO

@Suite struct TextStylesTests {
    init() { ExportSweep.install() }
    static func styles() -> TextStyles {
        var s = TextStyles()
        var loud = CharStyle()
        loud.sizePt = 30
        loud.underline = true
        s.character.append(CharacterStyleDef(id: 3, name: "Loud", attrs: diffAttrs(loud, CharStyle())))
        s.paragraph.append(ParagraphStyleDef(id: 1, name: "Middle", paraAttrs: diffAttrs(ParagraphStyle(align: .center), ParagraphStyle())))
        return s
    }

    static func docWith(_ styles: TextStyles, link: Bool) -> Document {
        var doc = Document(name: "t", size: PixelSize(width: 200, height: 80), mode: .rgb, depth: .u8)
        var base = CharStyle()
        base.fontFamily = "Inter"
        let loud = link ? styles.resolveChar(para: nil, chr: 3, defaultFamily: "Inter") : base
        let para = link ? styles.resolvePara(1) : ParagraphStyle()
        var t = TextLayer(text: "calm LOUD")
        t.runs = [TextRun(len: 5, style: base), TextRun(len: 4, style: loud)]
        t.paragraphs = [ParagraphRun(len: 9, style: para)]
        t.transform = .translate(4, 40)
        t.syncSummary()
        doc.layers.append(Layer(name: "t", content: .text(t)))
        doc.textStyles = styles
        return doc
    }

    static func text(_ doc: Document) throws -> TextLayer {
        guard case let .text(t)? = doc.layers.first?.content else { throw PCIOError.unsupported("not text") }
        return t
    }

    static func roundTrip(_ doc: Document, _ o: IOOptions) throws -> Document {
        try MapsKit.importFile(MapsKit.export(doc, "t.psd", options: o).bytes, "t.psd", options: o).document
    }

    @Test(arguments: [false, true]) func namedStylesRoundTripThroughPSD(_ photoshop: Bool) throws {
        let o = MapsKit.options(photoshop: photoshop)
        let back = try Self.roundTrip(Self.docWith(Self.styles(), link: true), o)
        let st = back.textStyles
        #expect(st.character.count == 1)
        #expect(st.character.first?.name == "Loud")
        #expect(st.character.first?.attrs["size_pt"] == .number(30))
        #expect(st.character.first?.attrs["underline"] == .bool(true))
        #expect(st.paragraph.first?.name == "Middle")
        #expect(st.paragraph.first?.paraAttrs["align"] == .string("Center"))
        let t = try Self.text(back)
        let runs = t.charRuns()
        #expect(runs.first?.style.styleSheet == nil)
        #expect(runs.count > 1 && runs[1].style.styleSheet == st.character.first?.id)
        #expect(t.paragraphRuns().first?.style.styleSheet == st.paragraph.first?.id)
        // Export again: stable.
        let back2 = try Self.roundTrip(back, o)
        #expect(back2.textStyles.character.count == 1)
        #expect(back2.textStyles.paragraph.count == 1)
    }

    @Test(arguments: [false, true]) func documentsWithoutStylesKeepTheirTypeData(_ photoshop: Bool) throws {
        let o = MapsKit.options(photoshop: photoshop)
        let back = try Self.roundTrip(Self.docWith(TextStyles(), link: false), o)
        #expect(back.textStyles.isEmpty)
        // Re-export of an imported file without styles keeps TySh byte-exact.
        let raw = try #require(try Self.text(back).psdRaw)
        let back2 = try Self.roundTrip(back, o)
        #expect(try Self.text(back2).psdRaw == raw)
        // Deleting every style removes the named sheets on the next save.
        var styled = try Self.roundTrip(Self.docWith(Self.styles(), link: true), o)
        styled.textStyles = TextStyles()
        let cleared = try Self.roundTrip(styled, o)
        #expect(cleared.textStyles.character.isEmpty && cleared.textStyles.paragraph.isEmpty)
    }
}
