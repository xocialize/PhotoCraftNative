// The parts of photocraft-io's type-layer tests that need only the TySh/Txt2 mapping:
// tests/psd_kerning.rs (EngineData pair fields, hostile kerning, Txt2 extras), tests/
// psd_type_bounds.rs (the imported model of Photoshop-shaped blocks; the pixel and composite
// checks need the renderer and the PSD container), tests/text_corpus.rs
// (`created_text_layer_roundtrips_through_psd`, model part). MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCPSD
import Testing
@testable import PCIOText

/// `(AutoKerning, Kerning)` of every UTF-16 unit of the engine text of a `TySh` block.
private func kerningFields(_ tysh: [UInt8]) -> [String] {
    guard let t = PSDText.parseTySh(tysh), let e = PSDText.engineData(t.text),
          let runs = e.at("EngineDict", "StyleRun", "RunArray")?.arr, let lens = e.at("EngineDict", "StyleRun", "RunLengthArray")?.arr else { return [] }
    var out: [String] = []
    for (r, n) in zip(runs, lens) {
        let d = r.at("StyleSheet", "StyleSheetData")
        let f = "\(d?.get("AutoKerning")?.flag ?? true)/\(d?.get("Kerning")?.i64 ?? 0)"
        out += Array(repeating: f, count: Int(n.i64 ?? 0))
    }
    return out
}

/// Per character: (mode, manual kern).
private func chars(_ t: TextLayer) -> [String] {
    var out: [String] = []
    let b = Array(t.text.utf8)
    var at = 0
    for r in t.charRuns() {
        let n = at + r.len <= b.count ? String(decoding: b[at ..< at + r.len], as: UTF8.self).unicodeScalars.count : 0
        out += Array(repeating: "\(r.style.kerning)/\(r.style.kern)", count: n)
        at += r.len
    }
    return out
}

private func kernLayer(_ text: String, _ runs: [(Int, Kerning, Float)]) -> TextLayer {
    var t = TextLayer(text: text)
    t.runs = runs.map { len, kerning, kern in TextRun(len: len, style: charStyle(family: "Inter", size: 24) { $0.kerning = kerning; $0.kern = kern }) }
    t.syncSummary()
    return t
}

@Suite struct PSDKerningIOTests {
    /// EngineData fields follow Photoshop's form: a manual kern after character c sits on c + 1;
    /// "no automatic kerning" on c is `AutoKerning false` on c + 2. The model survives the trip.
    @Test func manualAndOffKerningRoundTrip() throws {
        // "AVATAR Wave": +100 after A, -50 after T, characters 6..8 without automatic kerning.
        let t = kernLayer("AVATAR Wave", [(1, .off, 100), (2, .metrics, 0), (1, .off, -50), (2, .metrics, 0), (3, .off, 0), (2, .metrics, 0)])
        let tysh = build(t)
        #expect(chars(try #require(load(tysh))) == chars(t))
        let f = kerningFields(tysh)
        // 11 characters + the trailing paragraph break.
        #expect(f.count == 12)
        #expect(f[1] == "false/100", "kern after A on V, Photoshop's form")
        #expect(f[4] == "true/-50", "kern after T on A; character 2 isn't manual")
        for j in [8, 9, 10] { #expect(f[j].hasPrefix("false/"), "character \(j - 2) without automatic kerning") }
        for (j, x) in f.enumerated() where ![1, 4, 8, 9, 10].contains(j) { #expect(x == "true/0", "\(j)") }
    }

    /// #1348: Optical survives through `Txt2` (one object per `TextIndex`).
    @Test func opticalKerningRoundTripsThroughTxt2() throws {
        let t1 = kernLayer("AVATAR", [(4, .optical, 0), (2, .metrics, 0)])
        let t2 = kernLayer("Wave", [(2, .metrics, 0), (2, .optical, 0)])
        let objects: [(index: Int32, layer: TextLayer)] = [(0, t1), (1, t2)]
        #expect(PSDText.needsTxt2(objects))
        let txt2 = try #require(PSDText.parseTxt2(PSDText.buildTxt2(objects, previous: nil)))
        #expect(txt2.at("1", "1")?.arr?.count == 2)
        for (i, want) in [t1, t2].enumerated() {
            let tysh = try #require(PSDText.setTextIndex(build(want), Int32(i)))
            var back = try #require(load(tysh))
            PSDText.applyTxt2(&back, tysh: tysh, txt2: txt2)
            #expect(chars(back) == chars(want), "\(i)")
        }
    }

    /// A save must not drop what the file held beyond the style runs: pen positions (`/21 /1`)
    /// survive a resave of unchanged text and go away with the text they described.
    @Test func txt2ExtrasSurviveAResaveOfUnchangedText() throws {
        let obj = E.d([
            ("0", .d([("0", .string("AV\r")), ("6", .d([("0", .array([]))]))])),
            ("21", .d([("1", .array([.real(10), .real(20)]))])),
        ])
        let prev = PSDText.engineDataBareBytes([E.Entry("98", .d([("0", .int(14))])), E.Entry("0", .emptyDict), E.Entry("1", .d([("1", .array([obj]))]))])
        func save(_ text: String) throws -> E {
            try #require(PSDText.parseTxt2(PSDText.buildTxt2([(0, kernLayer(text, [(text.utf8.count, .metrics, 0)]))], previous: prev)))
        }
        #expect(try save("AV").at("1", "1")?.arr?.first?.at("21", "1")?.arr?.count == 2, "pen positions survive")
        #expect(try save("AX").at("1", "1")?.arr?.first?.get("21") == nil, "positions of another text are dropped")
    }

    /// Kerning that can't be represented (non-finite) and bad PSD fields never trap and stay sane.
    @Test func hostileKerningValues() throws {
        let t = kernLayer("AV", [(1, .off, .nan), (1, .metrics, .infinity)])
        let tysh = build(t)
        #expect(kerningFields(tysh).allSatisfy { $0.hasSuffix("/0") })
        #expect(chars(try #require(load(tysh))).allSatisfy { $0.hasSuffix("/0.0") })
        // Huge values clamp.
        let huge = kernLayer("AV", [(1, .off, 1e30), (1, .metrics, 0)])
        #expect(kerningFields(build(huge))[1] == "false/10000")
    }
}

// MARK: - psd_type_bounds.rs

fileprivate struct Run {
    var len: Int
    var size: Double
    var leading: Double?
}

fileprivate func style(_ size: Double, _ leading: Double?) -> E {
    .d([
        ("Font", .int(0)),
        ("FontSize", .real(size)),
        ("AutoLeading", .bool(leading == nil)),
        ("Leading", .real(leading ?? 0)),
        ("FillColor", .d([("Type", .int(1)), ("Values", .array([.real(1), .real(0), .real(0), .real(0)]))])),
    ])
}

/// Photoshop-shaped EngineData for `text` (paragraphs separated by `\r`).
fileprivate func engineData(_ text: String, _ runs: [Run], _ boxBounds: [Double]?, _ font: String) -> E {
    let edText = text + "\r"
    let n16 = Int64(edText.utf16.count)
    var sruns: [E] = []
    var slens: [E] = []
    for (i, r) in runs.enumerated() {
        sruns.append(.d([("StyleSheet", .d([("StyleSheetData", style(r.size, r.leading))]))]))
        slens.append(.int(Int64(r.len) + (i + 1 == runs.count ? 1 : 0)))
    }
    let para = E.d([("Justification", .int(0)), ("AutoLeading", .real(1.2))])
    var photoshop: [(String, E)] = [("ShapeType", .int(boxBounds == nil ? 0 : 1))]
    if let b = boxBounds { photoshop.append(("BoxBounds", .array(b.map { .real($0) }))) } else { photoshop.append(("PointBase", .array([.real(0), .real(0)]))) }
    let shape = E.d([("ShapeType", .int(boxBounds == nil ? 0 : 1)), ("Cookie", .d([("Photoshop", .d(photoshop))]))])
    let resources = E.d([
        ("FontSet", .array([.d([("Name", .string(font)), ("Script", .int(0))])])),
        ("StyleSheetSet", .array([.d([("Name", .string("Normal RGB")), ("StyleSheetData", style(12, nil))])])),
        ("ParagraphSheetSet", .array([.d([("Name", .string("Normal RGB")), ("Properties", para)])])),
    ])
    return .d([
        ("EngineDict", .d([
            ("Editor", .d([("Text", .string(edText))])),
            ("ParagraphRun", .d([("RunArray", .array([.d([("ParagraphSheet", .d([("Properties", para)]))])])), ("RunLengthArray", .array([.int(n16)]))])),
            ("StyleRun", .d([("RunArray", .array(sruns)), ("RunLengthArray", .array(slens))])),
            ("Rendered", .d([("Shapes", .d([("Children", .array([shape]))]))])),
        ])),
        ("ResourceDict", resources),
    ])
}

/// A `TySh` block as Photoshop writes it, whose runs use the font with PostScript name `font`.
fileprivate func tysh(_ text: String, _ runs: [Run], _ boxBounds: [Double]?, _ transform: PCAffine, _ ink: [Double], font: String = "Inter-Regular") -> [UInt8] {
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

@Suite fileprivate struct PSDTypeBoundsIOTests {
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
            Case(name: "point multi-line", dpi: 72, text: "Headline\rAutumn collection\rgy", runs: [Run(len: 29, size: 36, leading: 50)], boxBounds: nil, transform: t(40, 60), sizePt: 36),
            Case(name: "point mixed sizes", dpi: 72, text: "Big small Big", runs: [r(4, 60), r(6, 14), r(3, 60)], boxBounds: nil, transform: t(30, 120), sizePt: 60),
            Case(name: "paragraph box", dpi: 72, text: "Paragraph text that wraps over several lines in its box", runs: [r(55, 24)], boxBounds: [0, 0, 260, 200], transform: t(20, 20), sizePt: 24),
            Case(name: "paragraph box scaled", dpi: 144, text: "Paragraph text that wraps over several lines in its box", runs: [r(55, 20)], boxBounds: [0, 0, 200, 150], transform: scaled(1.5, 20, 20), sizePt: 10),
        ]
    }

    /// The model of Photoshop-shaped type: size in points at the document resolution, transform
    /// and shape as written (photocraft's `imported_type_layers_keep_their_full_bounds`, model).
    @Test func importedTypeLayerModels() throws {
        for c in Self.cases() {
            let t = try #require(PSDText.textLayer(fromTySh: tysh(c.text, c.runs, c.boxBounds, c.transform, [0, 0, 0, 0]), dpi: c.dpi), "\(c.name)")
            #expect(abs(t.runs[0].style.sizePt - c.sizePt) < 0.01, "\(c.name): size \(t.runs[0].style.sizePt) pt, want \(c.sizePt)")
            #expect(t.transform == c.transform, "\(c.name)")
            switch (c.boxBounds, t.shape) {
            case (nil, .point): break
            case let (b?, .box(box)): #expect([box.x, box.y, box.x + box.width, box.y + box.height].map(Double.init) == b, "\(c.name)")
            default: Issue.record("\(c.name): shape \(t.shape), want box \(String(describing: c.boxBounds))")
            }
            if c.name == "point multi-line" { #expect(t.runs[0].style.leadingPt == 50, "explicit leading") }
        }
    }

    /// The family guessed from a PostScript name (the import then corrects it against the font
    /// database, which is not here).
    @Test func postscriptFontNameGuess() throws {
        let c = Self.cases()[0]
        let probe = try #require(PSDText.textLayer(fromTySh: tysh(c.text, c.runs, c.boxBounds, c.transform, [40, 50, 400, 110], font: "JetBrainsMono-Regular"), dpi: c.dpi))
        #expect(probe.runs[0].style.fontFamily == "Jet Brains Mono")
        #expect(probe.runs[0].style.postscriptName == "JetBrainsMono-Regular")
    }

    /// Absurd sizes and scales import as a model without trapping.
    @Test func hostileTypeSizesImport() {
        for (size, s) in [(12.0, 1100.0), (1.0e30, 1), (12, 1.0e12), (Double.greatestFiniteMagnitude, .greatestFiniteMagnitude), (.nan, .infinity)] {
            let data = tysh("M", [Run(len: 1, size: size, leading: nil)], nil, PCAffine(m: [s, 0, 0, s, 10, 10]), [10, 10, 20, 20])
            let t = PSDText.textLayer(fromTySh: data, dpi: 72)
            #expect(t?.text == "M", "\(size)")
            // And it writes back.
            if let t { #expect(PSDText.textLayer(fromTySh: build(t), dpi: 72)?.text == "M") }
        }
    }

    /// Photoshop draws nothing when the engine text is blank, whatever the descriptor says.
    @Test func blankEngineTextIsBlank() {
        let data = tysh("", [Run(len: 0, size: 24, leading: nil)], nil, .translate(10, 40), [10, 10, 20, 20])
        #expect(PSDText.engineTextIsBlank(data))
        #expect(!PSDText.engineTextIsBlank(tysh("M", [Run(len: 1, size: 24, leading: nil)], nil, .identity, [0, 0, 0, 0])))
        #expect(!PSDText.engineTextIsBlank(bytes("not a TySh")))
    }
}

// MARK: - text_corpus.rs

@Suite struct CreatedTextLayerTests {
    /// A text layer created in PhotoCraft (no PSD data) writes an editable type layer and reads
    /// back with the same model.
    @Test func createdTextLayerRoundTripsThroughTySh() throws {
        let dpi: Float = 144
        let a = charStyle(family: "Inter", size: 10) { $0.color = .rgb(0.2, 0.4, 0.6) }
        var b = a
        b.fauxBold = true
        b.underline = true
        b.tracking = 50
        b.leadingPt = 14
        var t = TextLayer(text: "Größe\nzwei")
        t.runs = [TextRun(len: 3, style: a), TextRun(len: 9, style: b)]
        var p1 = ParagraphStyle(align: .center)
        p1.spaceAfterPt = 3
        t.paragraphs = [ParagraphRun(len: 7, style: p1), ParagraphRun(len: 5, style: ParagraphStyle(align: .justifyAll))]
        t.shape = .box(.init(x: 0, y: 0, width: 100, height: 60))
        t.transform = .translate(8, 6)
        t.syncSummary()
        let bt = try #require(PSDText.textLayer(fromTySh: PSDText.setTextIndex(build(t, dpi), 0)!, dpi: dpi))
        func strip(_ v: [TextRun]) -> [TextRun] {
            v.map { r in
                var r = r
                r.style.postscriptName = nil
                r.style.color.c = (r.style.color.c * 1000).rounded(.toNearestOrAwayFromZero) / 1000
                return r
            }
        }
        #expect(bt.text == t.text)
        #expect(strip(bt.charRuns()) == strip(t.charRuns()))
        #expect(bt.paragraphRuns() == t.paragraphRuns())
        #expect(bt.shape == t.shape)
        #expect(bt.transform == t.transform)
    }
}
