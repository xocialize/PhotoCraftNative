// TySh/EngineData/Txt2 ⇄ TextLayer.
// Port of the PSD tests of photocraft-text (crates/text/src/tests.rs, vertical_tests.rs,
// font_names_tests.rs; the layout/render assertions belong to the CoreText engine and are left
// out), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCPSD
import Testing
@testable import PCIOText

@Suite struct PSDTextTests {
    /// The tab stays a tab in the document: PSD type round-trips it unchanged.
    @Test func psdRoundTripsTabs() {
        for shape in [TextShape.point, .box(.init(x: 0, y: 0, width: 300, height: 100))] {
            var t = point("Name\tValue\n\tIndented", 20)
            t.shape = shape
            #expect(load(build(t))?.text == t.text, "\(shape)")
        }
    }

    @Test func postscriptNames() {
        var g = guessFromPostscript("MyriadPro-BoldIt")
        #expect((g.family, g.weight, g.italic) == ("Myriad Pro", 700, true))
        g = guessFromPostscript("TimesNewRomanPSMT")
        #expect((g.family, g.weight, g.italic) == ("Times New Roman", 400, false))
        g = guessFromPostscript("Arial-BoldMT")
        #expect((g.family, g.weight) == ("Arial", 700))
        g = guessFromPostscript("JetBrainsMono-Regular")
        #expect(g.family == "Jet Brains Mono")
    }

    /// Optical (and "0") kerning only lives in `Txt2`: import applies it when the layer's
    /// `TextIndex` object still holds the same text.
    @Test func txt2CarriesOpticalKerning() throws {
        let t = styled("AVA", CharStyle())
        let tysh = withTextIndex(build(t), 0)
        var back = try #require(load(tysh))
        #expect(back.charRuns().allSatisfy { $0.style.kerning == .metrics })
        // "AVA\r": two optical characters, then manual ("0") for the last and the break.
        let txt2 = try #require(PSDText.parseTxt2(txt2WithModes("AVA", [(2, 2), (2, 0)])))
        PSDText.applyTxt2(&back, tysh: tysh, txt2: txt2)
        #expect(back.charRuns().map { [$0.len: $0.style.kerning] } == [[2: .optical], [1: .off]])
        // Stale Txt2 (other text), another index or garbage: nothing changes, nothing traps.
        for (data, index) in [(txt2WithModes("AVX", [(4, 2)]), Int32(0)), (txt2WithModes("AVA", [(4, 2)]), 3), (bytes("<< /1 [ (x"), 0), ([], 0)] {
            let tysh = withTextIndex(build(t), index)
            var l = try #require(load(tysh))
            if let txt2 = PSDText.parseTxt2(data) { PSDText.applyTxt2(&l, tysh: tysh, txt2: txt2) }
            #expect(l.charRuns().allSatisfy { $0.style.kerning == .metrics }, "case \(index)")
        }
        // Run lengths longer than the text, zero lengths and odd modes are tolerated.
        let odd = try #require(PSDText.parseTxt2(txt2WithModes("AVA", [(0, 2), (100, 2), (5, 9)])))
        var l = try #require(load(tysh))
        PSDText.applyTxt2(&l, tysh: tysh, txt2: odd)
        #expect(l.charRuns().allSatisfy { $0.style.kerning == .optical })
    }

    /// #3617: Photoshop keeps Stylistic Sets, Contextual Alternates, Swash and the other OpenType
    /// settings besides (discretionary) ligatures only in `Txt2`. Import reads them.
    @Test func txt2CarriesOpenTypeFeatures() throws {
        func feats(_ l: TextLayer) -> [[String]] { l.charRuns().map { $0.style.features.map { "\($0.tag)=\($0.value)" } } }
        let text = "Il->36"
        let plain = styled(text, charStyle(family: "Inter"))
        let tysh = withTextIndex(build(plain), 0)
        let styles = [(2, "/11 1 /18 true /19 false /20 true /25 true /85 2"), (5, "/11 1 /20 false /23 true /85 1")]
        let txt2 = try #require(PSDText.parseTxt2(txt2WithStyles(text, styles)))
        var back = try #require(load(tysh))
        #expect(feats(back) == [[]], "EngineData alone doesn't have them")
        PSDText.applyTxt2(&back, tysh: tysh, txt2: txt2)
        #expect(feats(back) == [["calt=1", "swsh=1", "ss02=1"], ["calt=0", "frac=1", "ss01=1"]])
        #expect(back.charRuns().map(\.len) == [2, 4])
        // A feature the style already sets (from EngineData, read first) keeps its value; masks
        // and flags of the wrong type, masks beyond the 20 sets and unknown keys change nothing.
        var t = try #require(load(tysh))
        var s = CharStyle()
        s.features = [FontFeature(tag: "ss01", value: 0)]
        t.runs = [TextRun(len: text.utf8.count, style: s)]
        let odd = [(1, "/85 1"), (1, "/85 (x) /20 (x) /25 (true)"), (1, "/85 -1"), (4, "/85 99999999999 /999 true")]
        PSDText.applyTxt2(&t, tysh: tysh, txt2: try #require(PSDText.parseTxt2(txt2WithStyles(text, odd))))
        #expect(feats(t) == [["ss01=0"]])
    }

    /// A `Txt2` written by `buildTxt2` (what PSD export writes for the type layers) restores every
    /// auto-kern mode on import (#1348).
    @Test func buildTxt2RoundTripsKerningModes() throws {
        func style(_ kerning: Kerning, _ kern: Float) -> CharStyle { charStyle { $0.kerning = kerning; $0.kern = kern } }
        let t = runsOf("AVAT", [(2, style(.optical, 0)), (1, style(.metrics, 0)), (1, style(.off, 0))])
        let tysh = withTextIndex(build(t), 0)
        var back = try #require(load(tysh))
        #expect(back.charRuns().allSatisfy { $0.style.kerning != .optical }, "EngineData alone can't say Optical")
        let txt2 = try #require(PSDText.parseTxt2(PSDText.buildTxt2([(0, t)], previous: nil)))
        PSDText.applyTxt2(&back, tysh: tysh, txt2: txt2)
        #expect(back.charRuns().map { [$0.len: $0.style.kerning] } == [[2: .optical], [1: .metrics], [1: .off]])
        // A manual kern (a nonzero pair value) is the manual mode, as in the EngineData pair fields.
        let manual = runsOf("AB", [(1, style(.metrics, 50)), (1, style(.metrics, 0))])
        let mtysh = withTextIndex(build(manual), 0)
        var mback = try #require(load(mtysh))
        PSDText.applyTxt2(&mback, tysh: mtysh, txt2: try #require(PSDText.parseTxt2(PSDText.buildTxt2([(0, manual)], previous: nil))))
        #expect(mback.charRuns().map { [$0.len: $0.style.kerning] } == [[1: .off], [1: .metrics]])
    }

    /// #3514: the document `Txt2` is only needed for a non-Metrics (`Optical`) auto-kern mode.
    @Test func needsTxt2OnlyForOptical() {
        func style(_ k: Kerning) -> CharStyle { charStyle { $0.kerning = k } }
        typealias Objects = [(index: Int32, layer: TextLayer)]
        let metrics: Objects = [(0, runsOf("AV", [(2, style(.metrics))]))]
        let off: Objects = [(0, runsOf("AV", [(2, style(.off))]))]
        let optical: Objects = [(0, runsOf("AV", [(1, style(.optical)), (1, CharStyle())]))]
        #expect(!PSDText.needsTxt2(metrics))
        #expect(!PSDText.needsTxt2(off), "Off lives in EngineData, not Txt2")
        #expect(PSDText.needsTxt2(optical))
        #expect(!PSDText.needsTxt2([]))
    }

    /// A kept `Txt2` object — same text — keeps everything the file held beyond the regenerated
    /// keys (pen positions under `/21 /1`); a changed text drops those extras with the stale runs.
    /// The block's own extras always survive.
    @Test func txt2KeepsAKeptObjectsExtrasAndDropsThemWithItsText() throws {
        func style(_ k: Kerning) -> CharStyle { charStyle { $0.kerning = k } }
        let obj = E.d([
            ("0", .d([("0", .string("AB\r")), ("6", .d([("0", .array([]))])), ("keep", .int(7))])),
            ("21", .d([("1", .array([.real(1.5), .real(2.5)]))])),
        ])
        let prev = PSDText.engineDataBareBytes([
            E.Entry("98", .d([("0", .int(14))])), E.Entry("0", .emptyDict), E.Entry("1", .d([("1", .array([obj]))])), E.Entry("extra", .int(3)),
        ])
        // Same text: the extras survive, the style runs are ours.
        let t = runsOf("AB", [(1, style(.optical)), (1, style(.metrics))])
        var out = try #require(PSDText.parseTxt2(PSDText.buildTxt2([(0, t)], previous: prev)))
        #expect(out.get("extra")?.i64 == 3, "block extras survive")
        var object = try #require(out.at("1", "1")?.arr?.first)
        #expect(object.at("21", "1")?.arr?.count == 2, "pen positions survive an unchanged text")
        #expect(object.at("0", "keep")?.i64 == 7, "model extras survive")
        #expect(object.at("0", "6", "0")?.arr?.count == 2, "the style runs are regenerated")
        // Changed text: the extras go stale with the old runs and are dropped.
        let x = runsOf("XY", [(1, style(.optical)), (1, style(.metrics))])
        out = try #require(PSDText.parseTxt2(PSDText.buildTxt2([(0, x)], previous: prev)))
        #expect(out.get("extra")?.i64 == 3, "block extras survive a text change too")
        object = try #require(out.at("1", "1")?.arr?.first)
        #expect(object.get("21") == nil, "pen positions of another text are dropped")
        #expect(object.at("0", "keep") == nil, "model extras of another text are dropped")
    }

    /// #2374: an unedited save hands Photoshop back its own `Txt2`, byte for byte.
    @Test func unchangedTxt2IsWrittenBackByteForByte() throws {
        var prev = photoshopTxt2([(2, 1), (2, 1)])
        let tysh = withTextIndex(build(styled("AVA", CharStyle())), 0)
        var t = try #require(load(tysh))
        PSDText.applyTxt2(&t, tysh: tysh, txt2: try #require(PSDText.parseTxt2(prev)))
        #expect(t.charRuns().allSatisfy { $0.style.kerning == .metrics })
        #expect(PSDText.buildTxt2([(0, t)], previous: prev) == prev)
        // An optical run reads back and writes back the same way.
        prev = photoshopTxt2([(1, 2), (3, 1)])
        PSDText.applyTxt2(&t, tysh: tysh, txt2: try #require(PSDText.parseTxt2(prev)))
        #expect(t.charRuns().first?.style.kerning == .optical)
        #expect(PSDText.buildTxt2([(0, t)], previous: prev) == prev)
    }

    /// Photoshop leaves `/11` out of a style whose auto-kern mode is Metrics (its default): an
    /// unedited save keeps it out (photocraft added `/11 1` and rewrote the block, #2374), and an
    /// edit adds it only where the mode is no longer Metrics.
    @Test func missingAutoKernModeIsMetrics() throws {
        let prev = txt2WithStyles("AVA", [(4, "/1 12.0")])
        let tysh = withTextIndex(build(styled("AVA", CharStyle())), 0)
        var t = try #require(load(tysh))
        PSDText.applyTxt2(&t, tysh: tysh, txt2: try #require(PSDText.parseTxt2(prev)))
        #expect(PSDText.buildTxt2([(0, t)], previous: prev) == prev)
        let edited = runsOf("AVA", [(1, charStyle { $0.kerning = .optical }), (2, CharStyle())])
        let out = try #require(PSDText.parseTxt2(PSDText.buildTxt2([(0, edited)], previous: prev)))
        let runs = try #require(out.at("1", "1")?.arr?.first?.at("0", "6", "0")?.arr)
        #expect(runs.map { $0.get("1")?.i64 } == [1, 3])
        #expect(runs.map { $0.at("0", "0", "6", "11")?.i64 } == [2, nil], "Metrics stays implicit")
        #expect(runs.allSatisfy { $0.at("0", "0", "6", "1")?.f64 == 12 }, "the file's style keys survive")
    }

    /// An edited auto-kern mode changes only `/11` (splitting the run it falls inside); the file's
    /// style keys, the other `/1` keys and the objects no layer names all survive.
    @Test func editedTxt2KeepsTheFilesStylesAndObjects() throws {
        let prev = photoshopTxt2([(4, 1)])
        func style(_ k: Kerning) -> CharStyle { charStyle { $0.kerning = k } }
        let t = runsOf("AVA", [(1, style(.optical)), (2, style(.metrics))])
        let out = try #require(PSDText.parseTxt2(PSDText.buildTxt2([(0, t)], previous: prev)))
        let before = try #require(PSDText.parseTxt2(prev))
        for key in [["0"], ["1", "0"], ["1", "2"], ["3"]] {
            #expect(path(out, key) == path(before, key), "/\(key.joined(separator: " /")) survives")
        }
        let objects = try #require(out.at("1", "1")?.arr)
        #expect(objects.count == 2, "the object no layer names is kept")
        #expect(objects[safe: 1] == before.at("1", "1")?.arr?[safe: 1])
        let object = objects[0]
        #expect(object.at("0", "7", "0")?.i64 == 1, "model extras survive")
        #expect(object.at("21", "1") != nil, "pen positions survive an unchanged text")
        let runs = try #require(object.at("0", "6", "0")?.arr)
        #expect(runs.map { [$0.get("1")?.i64 ?? -1, $0.at("0", "0", "6", "11")?.i64 ?? -1] } == [[1, 2], [3, 1]], "the run is split where the mode changes")
        for r in runs {
            #expect(r.at("0", "0", "6", "1")?.f64 == 12, "the font size survives")
            #expect(r.at("0", "0", "6", "2")?.f64 == 14.5, "the leading survives")
        }
        // And it reads back with the edited modes.
        let tysh = withTextIndex(build(t), 0)
        var back = try #require(load(tysh))
        PSDText.applyTxt2(&back, tysh: tysh, txt2: out)
        #expect(back.charRuns().map { [$0.len: $0.style.kerning] } == [[1: .optical], [2: .metrics]])
    }

    func path(_ v: E, _ keys: [String]) -> E? {
        var x: E? = v
        for k in keys { x = x?.get(k) }
        return x
    }

    /// The file's style runs are only reused when they cover the text: runs of another length (or
    /// hostile lengths) fall back to generated runs, without trapping.
    @Test func txt2RunsThatDontCoverTheTextAreRegenerated() throws {
        let t = runsOf("AVA", [(3, CharStyle())])
        let all: [[(Int, Int64)]] = [[(3, 1)], [(9, 1)], [(Int(Int64.max), 1), (2, 1)], []]
        for modes in all {
            let prev = photoshopTxt2(modes)
            let out = try #require(PSDText.parseTxt2(PSDText.buildTxt2([(0, t)], previous: prev)))
            let runs = try #require(out.at("1", "1")?.arr?.first?.at("0", "6", "0")?.arr)
            #expect(runs.compactMap { $0.get("1")?.i64 }.reduce(0, +) == 4, "\(modes)")
            #expect(out.at("1", "2") != nil)
        }
    }

    /// A file-controlled `TextIndex` must not size the save.
    @Test func hostileTextIndexIsIgnoredNotSized() throws {
        let t = runsOf("AB", [(2, CharStyle())])
        let tysh = build(t)
        #expect(PSDText.textIndex(try #require(PSDText.setTextIndex(tysh, 0))) == 0)
        #expect(PSDText.textIndex(try #require(PSDText.setTextIndex(tysh, PSDText.maxTextIndex))) == PSDText.maxTextIndex)
        for hostile in [PSDText.maxTextIndex + 1, Int32.max] {
            #expect(PSDText.textIndex(try #require(PSDText.setTextIndex(tysh, hostile))) == nil, "\(hostile)")
            let out = try #require(PSDText.parseTxt2(PSDText.buildTxt2([(hostile, t)], previous: nil)))
            #expect(out.at("1", "1")?.arr?.isEmpty == true, "\(hostile)")
        }
        // The bound is real but generous: the last honoured number lands at its slot.
        let out = try #require(PSDText.parseTxt2(PSDText.buildTxt2([(PSDText.maxTextIndex, t)], previous: nil)))
        #expect(out.at("1", "1")?.arr?.count == Int(PSDText.maxTextIndex) + 1)
    }

    /// Photopea needs an enabled fill, not just FillColor, to paint text after an edit.
    @Test func psdTextFillIsEnabledInRunsAndNewDefaultStyles() throws {
        var t = point("AB", 100)
        t.runs = [
            TextRun(len: 1, style: charStyle { $0.color = .rgb(0.2, 0.4, 0.6) }),
            TextRun(len: 1, style: charStyle(size: 100) { $0.fauxBold = true }),
        ]
        for shape in [TextShape.point, .box(.init(x: 0, y: 0, width: 300, height: 200))] {
            t.shape = shape
            let tysh = try #require(PSDText.parseTySh(build(t)))
            let data = try #require(PSDText.engineData(tysh.text))
            let runs = try #require(data.at("EngineDict", "StyleRun", "RunArray")?.arr)
            #expect(runs.count == 2)
            for run in runs { #expect(run.at("StyleSheet", "StyleSheetData", "FillFlag")?.flag == true) }
            for key in ["ResourceDict", "DocumentResources"] {
                #expect(data.at(key, "StyleSheetSet")?.arr?.first?.at("StyleSheetData", "FillFlag")?.flag == true)
            }
            let back = try #require(load(PSDText.writeTySh(tysh)))
            #expect(back.text == t.text)
            #expect(back.runs.count == t.runs.count)
            for (actual, expected) in zip(back.runs, t.runs) {
                #expect(actual.style.color == expected.style.color)
                #expect(actual.style.sizePt == expected.style.sizePt)
                #expect(actual.style.fauxBold == expected.style.fauxBold)
            }
        }
    }

    @Test func psdTextFillIsEnabledAfterEditingALegacyExport() throws {
        // A legacy PhotoCraft export has a normal style and character runs without FillFlag.
        var t = point("Before", 40)
        var legacy = try #require(PSDText.parseTySh(build(t)))
        func removeFillFlags(_ v: inout E) {
            switch v {
            case var .dict(items):
                items.removeAll { $0.key == "FillFlag" }
                for i in items.indices { removeFillFlags(&items[i].value) }
                v = .dict(items)
            case var .array(items):
                for i in items.indices { removeFillFlags(&items[i]) }
                v = .array(items)
            default: break
            }
        }
        var data = try #require(PSDText.engineData(legacy.text))
        removeFillFlags(&data)
        legacy.text.set("EngineData", .rawData(Data(PSDText.engineDataBytes(data))))
        t.psdRaw = PSDText.writeTySh(legacy)
        t.text = "After"
        let tysh = try #require(PSDText.parseTySh(build(t)))
        let runs = try #require(PSDText.engineData(tysh.text)?.at("EngineDict", "StyleRun", "RunArray")?.arr)
        #expect(!runs.isEmpty)
        for run in runs { #expect(run.at("StyleSheet", "StyleSheetData", "FillFlag")?.flag == true) }
    }

    /// EngineData pair fields: manual kerning and "no automatic kerning" round-trip exactly, in
    /// Photoshop's form (see `pairRuns`).
    @Test func psdRoundTripsManualKerning() throws {
        let cases: [[(Int, Kerning, Float)]] = [
            [(1, .off, 100), (1, .off, -50), (2, .metrics, 0)],
            [(1, .metrics, 0), (1, .off, 0), (2, .metrics, 0)],
            [(4, .off, 0)],
            [(2, .metrics, 0), (1, .off, 25), (1, .metrics, 0)],
            [(3, .metrics, 0), (1, .off, 300)],
        ]
        func per(_ t: TextLayer) -> [String] {
            t.charRuns().flatMap { r in Array(repeating: "\(r.style.kerning)/\(r.style.kern)", count: r.len) }
        }
        for runs in cases {
            let t = runsOf("AVAT", runs.map { len, kerning, kern in (len, charStyle { $0.kerning = kerning; $0.kern = kern }) })
            let back = try #require(load(build(t)))
            var want = t.charRuns().flatMap { r in Array(repeating: (r.style.kerning, r.style.kern), count: r.len) }
            // The last character's mode has no EngineData slot (it reads back as Metrics unless it
            // has a manual kern).
            if let last = want.last, last.1 == 0 { want[want.count - 1].0 = .metrics }
            #expect(per(back) == want.map { "\($0.0)/\($0.1)" }, "\(runs)")
        }
    }

    @Test func psdRoundTripsAntialiasOpenTypeAndWarp() throws {
        var style = charStyle(family: "Inter", size: 20)
        style.features = [FontFeature(tag: "swsh", value: 1), FontFeature(tag: "frac", value: 1)]
        style.discretionaryLigatures = true
        for aa in [AntiAlias.windows, .windowsLcd, .crisp, .none] {
            var t = styled("1/2 Swash", style)
            t.antialias = aa
            t.warp = TextWarp(style: "warpFlag", value: -35, horizontalDistortion: 10, verticalDistortion: 0, horizontal: false)
            let back = try #require(load(build(t)))
            #expect(back.antialias == aa)
            #expect(back.warp == t.warp)
            let st = back.charRuns()[0].style
            #expect(st.discretionaryLigatures)
            #expect(st.features.map(\.tag).sorted() == ["frac", "swsh"])
        }
    }

    /// #1469: some older PSD writers combine a zero PointBase with an enormous local ink origin.
    /// Fold the descriptor origin into the imported transform and preserve it on a TySh round trip.
    @Test func legacyTyShPointOriginImportsAndRoundTripsOnCanvas() throws {
        let source = styled("Name", charStyle(family: "Inter", size: 120))
        var tysh = try #require(PSDText.parseTySh(build(source)))
        tysh.transform = PCAffine(m: [4.1667, 0, 0, 4.1667, -32375, -32887.5])
        let ink: [Double] = [8050, 8160, 8220, 8300]
        func rect(_ cls: String) -> PSDDescriptor.Value {
            .descriptor(PSDDescriptor(classID: PSDDescriptor.ID(cls))
                .with("Left", .unitFloat(unit: "#Pnt", value: ink[0]))
                .with("Top ", .unitFloat(unit: "#Pnt", value: ink[1]))
                .with("Rght", .unitFloat(unit: "#Pnt", value: ink[2]))
                .with("Btom", .unitFloat(unit: "#Pnt", value: ink[3])))
        }
        tysh.text.items.removeAll { $0.key.is("bounds") || $0.key.is("boundingBox") }
        tysh.text.items.append(.init("bounds", rect("bounds")))
        tysh.text.items.append(.init("boundingBox", rect("boundingBox")))
        let data = PSDText.writeTySh(tysh)
        let imported = try #require(load(data))
        let expected = [4.1667, 0, 0, 4.1667, 1166.935, 1112.772]
        for (got, want) in zip(imported.transform.m, expected) { #expect(abs(got - want) < 0.001, "\(imported.transform)") }
        let inkF = SIMD4<Float>(Float(ink[0]), Float(ink[1]), Float(ink[2]), Float(ink[3]))
        let roundTrip = try #require(load(build(imported, ink: inkF)))
        for (got, want) in zip(roundTrip.transform.m, expected) { #expect(abs(got - want) < 0.001, "\(roundTrip.transform)") }
    }

    /// Regression: a PSD whose text engine data has no `EngineDict` (or isn't a dictionary)
    /// trapped when the layer was written back.
    @Test func engineDataTemplateWithoutEngineDict() throws {
        let t = styled("Hi", CharStyle())
        let noEngineDict = try PSDEngineData.parse(Data(bytes("<< /ResourceDict << >> >>")))
        for template in [noEngineDict, .dict([]), .int(3)] {
            let e = PSDText.buildEngineData(t, template: template, dpi: 72)
            #expect(e.at("EngineDict", "Editor", "Text") == .string("Hi\r"))
        }
    }

    /// #1317: point text whose anchor Photoshop keeps only in its `Txt2` frame is placed at that
    /// anchor. A rewritten `TySh` (bounds near the origin) is left alone.
    @Test func txt2FramePlacesPointTextAtItsAnchor() throws {
        var t = point("2", 100)
        t.transform = .translate(-1000, -2000)
        // Photoshop's text space: anchor at (1100, 2050), ink above its baseline.
        let tysh = withTextIndex(build(t, ink: SIMD4(1100, 1980, 1160, 2050)), 0)
        let txt2 = try #require(PSDText.parseTxt2(txt2WithFrame("2", (1000, 2100), [1, 0, 0, 1, 100, -50])))
        var l = try #require(load(tysh))
        PSDText.applyTxt2Frame(&l, tysh: tysh, txt2: txt2)
        let o = l.transform.apply(PCPoint(0, 0))
        #expect(abs(o.x - 100) < 1e-3 && abs(o.y - 50) < 1e-3, "anchor at \(o)")
        // Already folded in (bounds near the origin): unchanged; another text: unchanged.
        let folded = withTextIndex(build(t, ink: SIMD4(0, -70, 60, 0)), 0)
        var f = try #require(load(folded))
        let before = f.transform
        PSDText.applyTxt2Frame(&f, tysh: folded, txt2: txt2)
        #expect(f.transform == before)
        let other = try #require(PSDText.parseTxt2(txt2WithFrame("3", (1000, 2100), [1, 0, 0, 1, 100, -50])))
        var g = try #require(load(tysh))
        let gBefore = g.transform
        PSDText.applyTxt2Frame(&g, tysh: tysh, txt2: other)
        #expect(g.transform == gBefore)
    }

    /// `tysh` with its text-space `bounds` set to `r` (Photoshop's, where it drew the text).
    func withBounds(_ tysh: [UInt8], _ r: [Double]) -> [UInt8] {
        var t = PSDText.parseTySh(tysh)!
        var d = PSDDescriptor()
        for (k, v) in zip(["Left", "Top ", "Rght", "Btom"], r) { d.items.append(.init(PSDDescriptor.ID(k), .double(v))) }
        t.text.items.removeAll { $0.key.is("bounds") }
        t.text.items.append(.init("bounds", .descriptor(d)))
        return PSDText.writeTySh(t)
    }

    /// #1317: a text box whose `BoxBounds` are in its `Txt2` frame's space is moved by the
    /// frame's matrix onto the `bounds` Photoshop drew it at.
    @Test func txt2FrameMovesBoxTextOntoItsBounds() throws {
        var t = styled("Casemiro 45", charStyle(size: 25))
        t.shape = .box(.init(x: 500, y: 600, width: 300, height: 90))
        t.transform = .translate(-700, -300)
        let built = withTextIndex(build(t), 0)
        let tysh = withBounds(built, [960, 300, 1260, 390])
        let txt2 = try #require(PSDText.parseTxt2(txt2WithFrame("Casemiro 45", nil, [1, 0, 0, 1, 460, -300])))
        var l = try #require(load(tysh))
        guard case let .box(b) = l.shape else { Issue.record("not a box"); return }
        PSDText.applyTxt2Frame(&l, tysh: tysh, txt2: txt2)
        let o = l.transform.apply(PCPoint(Double(b.x), Double(b.y)))
        #expect(abs(o.x - 260) < 1e-3 && abs(o.y) < 1e-3, "box top left at \(o)")
        // PhotoCraft's own `TySh` (bounds = the box, frame already folded in): unchanged.
        var own = try #require(load(built))
        let before = own.transform
        PSDText.applyTxt2Frame(&own, tysh: built, txt2: txt2)
        #expect(own.transform == before)
    }

    @Test func translateTyShMovesOnlyTheTranslation() throws {
        var t = point("Hello!", 26)
        t.transform = PCAffine(m: [1.5, 0, 0, 1.5, 80, 340])
        let tysh = build(t, ink: SIMD4(0, -20, 300, 4))
        let moved = try #require(PSDText.translateTySh(tysh, dx: -8, dy: -279))
        let back = try #require(PSDText.parseTySh(moved))
        #expect(back.transform.m == [1.5, 0, 0, 1.5, 72, 61])
        // Everything but the 16 translation bytes is unchanged.
        #expect(moved.count == tysh.count)
        #expect(moved[..<34] == tysh[..<34] && moved[50...] == tysh[50...])
        #expect(PSDText.parseTySh(tysh)?.bounds == back.bounds, "bounds are in text space")
        #expect(PSDText.translateTySh(Array(tysh[..<40]), dx: 1, dy: 1) == nil, "a truncated block is refused")
    }

    /// The four values after the `TySh` warp descriptor are big-endian f32, as Photoshop writes
    /// them: zeros for unwarped type, the text-space bounds for warped type.
    @Test func tyShTrailingBoundsAreF32() throws {
        func tail(_ b: [UInt8]) -> SIMD4<Float> {
            var v = SIMD4<Float>.zero
            let t = Array(b.suffix(16))
            for i in 0 ..< 4 { v[i] = Float(bitPattern: t[i * 4 ..< i * 4 + 4].reduce(0) { $0 << 8 | UInt32($1) }) }
            return v
        }
        let ink = SIMD4<Float>(0, -34.316406, 288.90625, 15.058594)
        #expect(tail(build(point("Type", 20), ink: ink)) == .zero)
        var warped = point("Type", 20)
        warped.warp = TextWarp(style: "warpArc", value: 50, horizontalDistortion: 0, verticalDistortion: 0, horizontal: true)
        let b = build(warped, ink: ink)
        #expect(tail(b) == ink)
        let parsed = try #require(PSDText.parseTySh(b))
        #expect(parsed.bounds == ink)
        #expect(PSDText.writeTySh(parsed) == b)
    }

    /// EngineData's `AntiAlias` numbers as Photoshop writes them: 0 None, 1 Crisp, 2 Strong,
    /// 3 Smooth, 4 Sharp. Read back from EngineData alone (no `AntA`), every mode survives.
    @Test func engineDataAntialiasNumbersMatchPhotoshop() throws {
        let cases: [(AntiAlias, Double)] = [(.none, 0), (.crisp, 1), (.strong, 2), (.smooth, 3), (.sharp, 4)]
        for (mode, n) in cases {
            var t = point("Type", 20)
            t.antialias = mode
            var tysh = try #require(PSDText.parseTySh(build(t)))
            #expect(PSDText.engineData(tysh.text)?.at("EngineDict", "AntiAlias")?.f64 == n, "\(mode)")
            tysh.text.items.removeAll { $0.key.is("AntA") }
            #expect(load(PSDText.writeTySh(tysh))?.antialias == mode, "\(n)")
        }
    }

    /// Vertical type: the descriptor's `Ornt` and EngineData's writing direction round-trip.
    @Test func psdTyShRoundTripsOrientationAndWritingDirection() throws {
        func vertical(_ text: String) -> TextLayer {
            var t = styled(text, charStyle(family: "Inter", size: 20))
            t.orientation = .vertical
            return t
        }
        for o in [TextOrientation.vertical, .horizontal] {
            var t = vertical("縦書きAB")
            t.orientation = o
            let b = build(t)
            #expect(load(b)?.orientation == o)
            let ed = try #require(PSDText.parseTySh(b).flatMap { PSDText.engineData($0.text) })
            #expect(ed.at("EngineDict", "Rendered", "Shapes", "WritingDirection")?.f64 == (o == .vertical ? 2 : 0))
        }
        // A file without `Ornt` but with a vertical writing direction imports as vertical.
        var parsed = try #require(PSDText.parseTySh(build(vertical("ab"))))
        parsed.text.items.removeAll { $0.key.is("Ornt") }
        #expect(load(PSDText.writeTySh(parsed))?.orientation == .vertical)
    }

    /// The PostScript name a run names survives a PSD round trip (font_names_tests).
    @Test func postscriptNameSurvivesARoundTrip() throws {
        var t = TextLayer(text: "Hamburgefonstiv")
        t.runs = [TextRun(len: 14, style: charStyle(family: "Numeric Test", size: 32) { $0.fontStyle = "30"; $0.postscriptName = "UnrelatedPS30" })]
        #expect(try #require(load(build(t))).charRuns()[0].style.postscriptName == "UnrelatedPS30")
    }

    /// Malformed blocks never trap.
    @Test func malformedInputNeverTraps() {
        let good = build(point("Hello", 12))
        for cut in stride(from: 0, to: good.count, by: 7) {
            let b = Array(good[..<cut])
            _ = PSDText.textLayer(fromTySh: b, dpi: 72)
            _ = PSDText.textIndex(b)
            _ = PSDText.setTextIndex(b, 1)
            _ = PSDText.translateTySh(b, dx: 1, dy: 1)
            _ = PSDText.engineTextIsBlank(b)
            _ = PSDStyles.readStyleSheets(b, dpi: 72)
        }
        #expect(PSDText.textLayer(fromTySh: [], dpi: 72) == nil)
        #expect(PSDText.parseTxt2(bytes("<< /1 [ (x")) == nil)
    }
}
