// Port of photocraft-doc's module tests (crates/doc/src/{adjust,advanced,analysis,blend_if,comps,
// mode,pattern,slices,text,text_styles,variables,vector,video}.rs), MIT OR Apache-2.0, © ArtCraft
// Team and the PhotoCraft contributors.

import Foundation
import PCFoundation
import Testing
@testable import PCDocument

@Suite struct BlendRangePhotoshopRampTests {
    @Test func splitPointRampsOverHiMinusLoPlusOneLevels() {
        let r = BlendRange(black: SIMD2(50, 150), white: SIMD2(255, 255))
        #expect(r.weight(49) == 0)
        #expect(abs(r.weight(50) - 1.0 / 101.0) < 1e-6)
        #expect(abs(r.weight(100) - 51.0 / 101.0) < 1e-6)
        #expect(r.weight(150) == 1)
        let unsplit = BlendRange(black: SIMD2(80, 80), white: SIMD2(200, 200))
        #expect(unsplit.weight(79) == 0 && unsplit.weight(80) == 1 && unsplit.weight(200) == 1 && unsplit.weight(201) == 0)
        #expect(BlendRange.gray8(r: 255, g: 0, b: 0) == 77)   // round(76.5)
    }
}

@Suite struct AdjustTests {
    @Test func hueRangeWeights() {
        let reds = HueRange.neutral(0)
        #expect(reds.weight(0) == 1)
        #expect(reds.weight(350) == 1)
        #expect(abs(reds.weight(30) - 0.5) < 1e-5)
        #expect(abs(reds.weight(330) - 0.5) < 1e-5)
        #expect(reds.weight(60) == 0)
        #expect(reds.weight(180) == 0)
        let blues = HueRange.neutral(4)
        #expect(blues.weight(240) == 1)
        #expect(blues.weight(120) == 0)
        // Degenerate bounds never divide by zero.
        var odd = HueRange.neutral(0)
        odd.bounds = SIMD4(10, 10, 10, 10)
        #expect(odd.weight(10).isFinite && odd.weight(200).isFinite)
        var nan = HueRange.neutral(0)
        nan.bounds = SIMD4(repeating: .nan)
        #expect(nan.weight(10).isFinite)
    }

    @Test func canonicalBounds() {
        #expect(HueRange.canonicalBounds(SIMD4(315, 345, 15, 45)) == SIMD4(-45, -15, 15, 45))
        #expect(HueRange.canonicalBounds(SIMD4(-45, -15, 15, 45)) == SIMD4(-45, -15, 15, 45))
        #expect(HueRange.canonicalBounds(SIMD4(195, 225, 255, 285)) == SIMD4(195, 225, 255, 285))
        #expect(HueRange.canonicalBounds(SIMD4(.nan, 0, 0, 0)) == SIMD4(-45, -15, 15, 45))
    }

    @Test func oldFilesGetNeutralNewFields() throws {
        let a = try decodeJSON(Adjustment.self, #"{"HueSaturation":{"hue":1.0,"saturation":2.0,"lightness":3.0,"colorize":false}}"#)
        guard case .hueSaturation(let hs) = a else { Issue.record("not hue/sat"); return }
        #expect(hs.ranges == HueRange.defaults)
        let c = try decodeJSON(Adjustment.self, #"{"Curves":{"master":[],"per_channel":[[],[],[]]}}"#)
        guard case .curves(let cv) = c else { Issue.record("not curves"); return }
        #expect(cv.space == .rgb && !cv.pencil)
        let g = try decodeJSON(Adjustment.self, #"{"GradientMap":{"stops":[],"reverse":true}}"#)
        guard case .gradientMap(let gm) = g else { Issue.record("not gradient map"); return }
        #expect(!gm.dither)
    }

    @Test func lut3DLengthRejectsTinyAndOverflowingSizes() {
        #expect(lut3DLength(0) == nil)
        #expect(lut3DLength(1) == nil)
        #expect(lut3DLength(2) == 24)
        #expect(lut3DLength(33) == 33 * 33 * 33 * 3)
        #expect(lut3DLength(1 << 22) == nil, "(2²²)³ overflows a 64-bit length")
        #expect(lut3DLength(.max) == nil)
    }

    @Test func curveMapsAndIdentity() {
        #expect(isIdentityCurve([CurvePoint(input: 0, output: 0), CurvePoint(input: 1, output: 1)]))
        #expect(isIdentityCurve([]))
        #expect(!isIdentityCurve([CurvePoint(input: 0, output: 0.1), CurvePoint(input: 1, output: 1)]))
        let m = curveMap([0.5, .nan, 2])
        #expect(m.count == curveMapLength)
        #expect(m[0].output == 0.5 && m[1].output == 0.5 && m[2].output == 1 && m[255].output == 1)
        #expect(m[255].input == 1)
        let outs = curveMapOutputs([CurvePoint(input: 1, output: 0), CurvePoint(input: 0, output: 1)])
        #expect(outs.count == 256 && outs[0] == 1 && outs[255] == 0 && abs(outs[128] - (1 - 128 / 255.0)) < 1e-6)
        #expect(curveMapOutputs([])[200] == 200 / 255.0)
    }

    @Test func adjustmentsRoundTripInSerdeShape() throws {
        let all: [Adjustment] = [
            .brightnessContrast(.init(brightness: 10, contrast: -5, legacy: true)), .identityLevels(), .identityCurves(),
            .exposure(.init(exposure: 1, offset: 0.1, gamma: 0.9)), .vibrance(.init(vibrance: 20, saturation: 5)),
            .defaultHueSaturation(), .colorBalance(.init(shadows: SIMD3(1, 2, 3))), .blackWhite(.init(weights: [40, 60, 40, 60, 20, 80], tint: SIMD3(1, 0.5, 0))),
            .photoFilter(.init(color: SIMD3(1, 0.5, 0), density: 0.25)), .channelMixer(.init(matrix: [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0)])),
            .colorLookup(.init(name: "lut", lut: [0, 0, 0], size: 2)), .invert, .posterize(levels: 4), .threshold(level: 0.5),
            .gradientMap(.init(stops: [GradientMapStop(0, SIMD3(0, 0, 0)), GradientMapStop(1, SIMD3(1, 1, 1))])),
            .selectiveColor(.init()), .unsupported(psdKey: "mixr", raw: [1, 2, 3]),
        ]
        for a in all { #expect(try roundTrip(a) == a, "\(a.label)") }
        #expect(try encodeJSON(Adjustment.invert) == #""Invert""#)
        #expect(try encodeJSON(Adjustment.posterize(levels: 4)) == #"{"Posterize":{"levels":4}}"#)
        #expect(try jsonValue(Adjustment.identityLevels())["Levels"]?["per_channel"]?.arrayValue?.count == 3)
        #expect(try jsonValue(Adjustment.unsupported(psdKey: "k", raw: [7]))["Unsupported"]?["psd_key"] == "k")
        #expect(throws: (any Error).self) { try decodeJSON(Adjustment.self, #"{"Levels":{"master":{"in_black":0,"in_white":1,"gamma":1,"out_black":0,"out_white":1},"per_channel":[]}}"#) }
    }
}

@Suite struct AdvancedTests {
    @Test func defaultsMatchPhotoshop() {
        let a = AdvancedBlending()
        #expect(a.knockout == .none)
        #expect(!a.blendInterior)
        #expect(a.blendClipped)
        #expect(a.transparencyShapes)
        #expect(!a.layerMaskHidesEffects)
        #expect(!a.vectorMaskHidesEffects)
        #expect(a.isDefault)
        var b = a
        b.blendClipped = false
        #expect(!b.isDefault)
    }

    @Test func knockoutPsdValuesAndNames() {
        for k in [Knockout.none, .shallow, .deep] {
            #expect(Knockout(psdValue: k.psdValue) == k)
            #expect(Knockout(name: k.name) == k)
        }
        #expect(Knockout(psdValue: 7) == .deep)
        #expect(Knockout(name: "DEEP") == .deep)
        #expect(Knockout(name: "medium") == nil)
    }

    @Test func partialJsonKeepsPhotoshopDefaults() throws {
        let a = try decodeJSON(AdvancedBlending.self, #"{"knockout":"deep"}"#)
        #expect(a == AdvancedBlending(knockout: .deep))
        let b = try decodeJSON(AdvancedBlending.self, "{}")
        #expect(b.isDefault)
        let json = try encodeJSON(AdvancedBlending(layerMaskHidesEffects: true))
        #expect(json.contains(#""layerMaskHidesEffects":true"#), "\(json)")
    }
}

@Suite struct AnalysisTests {
    @Test func scaleFactorAndText() {
        let s = MeasurementScale(pixelLength: 100, logicalLength: 2.5, units: "cm")
        #expect(abs(s.factor - 0.025) < 1e-12)
        #expect(s.describe == "100 pixels = 2.5000 cm")
        #expect(MeasurementScale().isDefault)
        #expect(MeasurementScale().describe == "1 pixels = 1.0000 pixels")
        #expect(MeasurementScale(pixelLength: 0).factor == 1)
        #expect(MeasurementScale(pixelLength: 2.5).describe.hasPrefix("2.5 pixels"))
    }

    @Test func serdeDefaultsFillMissingFields() throws {
        let m = try decodeJSON(MeasurementSettings.self, "{}")
        #expect(m.isEmpty)
        let n = try decodeJSON(Note.self, #"{"text":"hi"}"#)
        #expect(n.text == "hi")
        #expect(n.color == PCColor.rgb(1, 1, 0.51))
        let g = CountGroup(points: [SIMD2(1, 2), SIMD2(3, 4)])
        let m2 = MeasurementSettings(countGroups: [g, g])
        #expect(m2.countTotal == 4)
        #expect(try roundTrip(m2) == m2)
        #expect(try jsonValue(m2)["count_groups"]?[0]?["marker_size"] == 1)
    }

    @Test func rustFloatFormatting() {
        #expect(rustFloatString(2.5) == "2.5")
        #expect(rustFloatString(1e20) == "100000000000000000000")
        #expect(rustFloatString(1.5e-7) == "0.00000015")
        #expect(rustFloatString(-3.25) == "-3.25")
    }
}

@Suite struct BlendIfTests {
    @Test func fullRangeShowsEverything() {
        let r = BlendRange.full
        #expect(r.isFull)
        for v: Float in [0, 0.5, 127, 254.9, 255] { #expect(r.weight(v) == 1) }
    }

    @Test func unsplitPointsAreHardThresholds() {
        let r = BlendRange(black: SIMD2(50, 50), white: SIMD2(200, 200))
        #expect(r.weight(49) == 0)
        #expect(r.weight(49.9) == 0)
        #expect(r.weight(50) == 1)
        #expect(r.weight(200) == 1)
        #expect(r.weight(200.1) == 0)
        #expect(!r.isFull)
    }

    @Test func splitPointsRampLinearly() {
        let r = BlendRange(black: SIMD2(0, 100), white: SIMD2(155, 255))
        // A split black point fades from its low half to its high half over hi − lo + 1 levels —
        // Photoshop's measured ramp, (v − lo + 1) / (hi − lo + 1); photocraft's (v − lo) / (hi − lo)
        // gave 0 at 0 and 0.5 at 50. The white point mirrors it.
        #expect(abs(r.weight(0) - 1 / 101) < 1e-6)
        #expect(abs(r.weight(50) - 51 / 101) < 1e-6)
        #expect(r.weight(100) == 1)
        #expect(r.weight(155) == 1)
        #expect(abs(r.weight(205) - 51 / 101) < 1e-6)
        #expect(abs(r.weight(255) - 1 / 101) < 1e-6)
        #expect(!r.isFull)
    }

    @Test func bytesRoundTripInPsdOrder() {
        let r = BlendRange(black: SIMD2(10, 20), white: SIMD2(230, 240))
        #expect(r.bytes == [10, 20, 230, 240])
        #expect(BlendRange(bytes: r.bytes) == r)
    }

    @Test func setTrimsTrailingFullEntries() throws {
        var b = BlendIf()
        #expect(b.isDefault)
        let r = BlendRange(black: SIMD2(30, 30), white: SIMD2(255, 255))
        b.set(2, BlendRangePair(.full, r))
        #expect(b.ranges.count == 3)
        #expect(b.get(2) == BlendRangePair(.full, r))
        #expect(b.get(7) == .full)
        #expect(!b.isDefault)
        #expect(try encodeJSON(b) == #"{"ranges":[[{"black":[0,0],"white":[255,255]},{"black":[0,0],"white":[255,255]}],[{"black":[0,0],"white":[255,255]},{"black":[0,0],"white":[255,255]}],[{"black":[0,0],"white":[255,255]},{"black":[30,30],"white":[255,255]}]]}"#)
        #expect(try roundTrip(b) == b)
        b.set(2, .full)
        #expect(b == BlendIf())
    }
}

@Suite struct CompsTests {
    func doc() -> Document {
        var d = Document.withBackground(name: "t", size: PixelSize(width: 64, height: 64), mode: .rgb, depth: .u8, fill: .white)
        var l = Layer.raster("A", format: .rgba8)
        l.withRaster { $0.fill(PixelRect(x0: 10, y0: 12, x1: 20, y1: 22), with: [1, 0, 0, 1]) }
        d.layers.append(l)
        return d
    }

    @Test func captureRecordsEveryLayer() {
        let s = doc().captureCompStates()
        #expect(s.count == 2)
        #expect(s[1].position == SIMD2(10, 12))
        #expect(s[1].visible == true)
        #expect(s[1].appearance != nil)
    }

    @Test func capturedInfoBits() {
        var c = LayerComp(id: 1, name: "c", applyVisibility: false, applyPosition: false, applyAppearance: false)
        c.capturedInfo = 5
        #expect(c.applyVisibility && !c.applyPosition && c.applyAppearance)
        #expect(c.capturedInfo == 5)
    }

    @Test func missingLayersAndIds() {
        var d = doc()
        let states = d.captureCompStates()
        d.layerComps.append(LayerComp(id: d.nextCompId(), name: "c", states: states))
        #expect(d.layerComps[0].id == 1)
        #expect(d.nextCompId() == 2)
        let gone = d.layers[1].id
        d.layers.removeLast()
        #expect(d.layerComps[0].missingLayers(in: d) == [gone])
    }

    @Test func artboardsListedAndFound() throws {
        var d = doc()
        let child = Layer.raster("in", format: .rgba8)
        let cid = child.id
        var g = Layer.group("Artboard 1", [child])
        g.artboard = Artboard(rect: PixelRect(x0: 0, y0: 0, x1: 32, y1: 32))
        let gid = g.id
        d.layers.append(g)
        #expect(d.hasArtboards)
        #expect(d.artboards.count == 1)
        #expect(d.artboard(of: cid) == gid)
        #expect(try #require(d.layer(gid)).compPosition == SIMD2(0, 0))
        #expect(ArtboardBackground.black.rgba == SIMD4(0, 0, 0, 1))
        #expect(ArtboardBackground.transparent.rgba == nil)
    }

    @Test func artboardsSerializeLikePhotocraft() throws {
        let a = Artboard(rect: PixelRect(x0: 1, y0: 2, x1: 3, y1: 4), background: .custom(.rgb(1, 0, 0)))
        #expect(try roundTrip(a) == a)
        #expect(try encodeJSON(ArtboardBackground.white) == #""white""#)
        let b = try decodeJSON(Artboard.self, #"{"rect":{"x0":0,"y0":0,"x1":8,"y1":8},"background":"black"}"#)
        #expect(b.background == .black && b.preset.isEmpty)
    }
}

@Suite struct ModeTests {
    @Test func colorTableNearest() {
        let t = ColorTable(colors: [SIMD3(0, 0, 0), SIMD3(255, 255, 255), SIMD3(255, 0, 0)])
        #expect(t.nearest(SIMD3(0.9, 0.1, 0.1)) == 2)
        #expect(t.nearest(SIMD3(0.6, 0.6, 0.6)) == 1)
        #expect(t.rgb(2) == SIMD3(1, 0, 0))
        #expect(t.rgb(9) == .zero)
    }

    @Test func duotoneRenderBlackInkIsGray() {
        let d = Duotone(inks: [DuotoneInk(name: "Black", color: .zero)])
        for g: Float in [0, 0.25, 1] {
            let c = d.render(g)
            #expect(abs(c.x - g) < 1e-6 && c.x == c.z)
        }
        let d2 = Duotone(inks: [DuotoneInk(name: "Black", color: .zero), DuotoneInk(name: "Orange", color: SIMD3(1, 0.5, 0))])
        let c = d2.render(0.5)
        #expect(c.x > c.z, "\(c)")
        guard case .gradientMap(let gm) = d2.displayAdjustment else { Issue.record("not a gradient map"); return }
        #expect(gm.stops.count == 33)
    }

    @Test func stackModeIdsRoundTrip() throws {
        for m in StackMode.all {
            #expect(StackMode(id: m.id) == m)
            #expect(try roundTrip(m) == m)
        }
        #expect(try encodeJSON(StackMode.standardDeviation) == #""StandardDeviation""#)
    }
}

@Suite struct PatternTests {
    @Test func idsAreDeterministicAndLookupFallsBackToNames() {
        var s = Surface(format: .rgba8)
        s.fill(PixelRect(x0: 0, y0: 0, x1: 4, y1: 4), with: [1, 0, 0, 1])
        let a = Pattern(name: "$$$/Patterns/Defaults/Water=Water", surface: s, width: 4, height: 4)
        let b = Pattern(name: "$$$/Patterns/Defaults/Water=Water", surface: s, width: 4, height: 4)
        #expect(a.id == b.id)
        #expect(a.id.count == 36)
        #expect(Pattern(name: "Other", surface: s, width: 4, height: 4).id != a.id)
        #expect(a.displayName == "Water")
        let list = [a]
        #expect(Pattern.find(list, id: a.id, name: "") != nil)
        #expect(Pattern.find(list, id: "nope", name: "water") != nil)
        #expect(Pattern.find(list, id: "nope", name: "") == nil)
    }

    /// The same content gets photocraft's id (FNV-1a over name, size, f32 sample bits and the Rust
    /// `Debug` form of the format, cross-checked with an independent implementation).
    @Test func idsMatchPhotocraft() {
        var s = Surface(format: .rgba8)
        s.fill(PixelRect(x0: 0, y0: 0, x1: 4, y1: 4), with: [1, 0, 0, 1])
        #expect(Pattern(name: "$$$/Patterns/Defaults/Water=Water", surface: s, width: 4, height: 4).id == "d408e621-446d-9d54-ac0c-0f9295698959")
        #expect(Pattern(name: "Other", surface: s, width: 4, height: 4).id == "d582f349-166c-9415-4afd-4cc9f5252ab0")
        #expect(rustDebugString(.rgba8) == "PixelFormat { mode: Rgb, sample: U8, alpha: true }")
    }

    @Test func displayNamesAndLimits() {
        #expect(Pattern.displayName("Plain\0\0") == "Plain")
        #expect(Pattern.displayName("$$$/NoEquals") == "$$$/NoEquals")
        let p = Pattern(id: "x", name: "n", width: 1 << 14, height: 1 << 14, surface: Surface(format: .rgba8))
        #expect(!p.isPaintable && !p.isEmpty)
        #expect(Pattern(id: "e", name: "e", width: 0, height: 5, surface: Surface(format: .rgba8)).isEmpty)
    }
}

@Suite struct SlicesTests {
    func area(_ rs: [PixelRect]) -> Int { rs.reduce(0) { $0 + $1.area } }

    @Test func autoSlicesTileTheRestOfTheCanvas() {
        let canvas = PixelRect(x0: 0, y0: 0, x1: 100, y1: 80)
        let user = [PixelRect(x0: 20, y0: 10, x1: 60, y1: 30)]
        let auto = autoSlices(canvas: canvas, taken: user)
        #expect(area(auto) + area(user) == 100 * 80)
        for (i, a) in auto.enumerated() {
            #expect(a.intersect(user[0]).isEmpty)
            for b in auto[(i + 1)...] { #expect(a.intersect(b).isEmpty, "\(a) overlaps \(b)") }
        }
        // Above band, left, right, below band.
        #expect(auto.count == 4)
        #expect(auto[0] == PixelRect(x0: 0, y0: 0, x1: 100, y1: 10))
        #expect(autoSlices(canvas: canvas, taken: []) == [canvas])
    }

    @Test func resolveNumbersTopToBottom() throws {
        var d = Document(name: "site.psd", size: PixelSize(width: 100, height: 80), mode: .rgb, depth: .u8)
        #expect(d.resolvedSlices().count == 1)
        #expect(d.resolvedSlices()[0].name == "site")
        d.slices.list.append(Slice(id: 1, rect: PixelRect(x0: 20, y0: 10, x1: 60, y1: 30)))
        let r = d.resolvedSlices()
        #expect(r.count == 5)
        #expect(r[0].name == "site_01")
        let user = try #require(r.first { $0.id == 1 })
        #expect(user.number == 3, "after the top band and the left cell")
        #expect(user.origin == .user)
        d.slices.list[0].name = "logo"
        #expect(d.resolvedSlices().contains { $0.name == "logo" })
        d.name = "my site (v2).png"
        #expect(d.sliceBaseName == "my_site__v2_")
    }

    @Test func exhaustedSliceIdSurvivesSerialization() throws {
        let slices = Slices(list: [Slice(id: .max)])
        let loaded = try roundTrip(slices)
        #expect(loaded.nextId == nil)
        #expect(try jsonValue(Slice(id: 3))["cellTextIsHtml"] == false)
        #expect(try decodeJSON(Slice.self, #"{"id":4,"kind":"noImage","layer":12}"#).layer == LayerId(12))
    }
}

@Suite struct TextTests {
    func run(_ len: Int, _ size: Float) -> TextRun {
        var s = CharStyle()
        s.sizePt = size
        return TextRun(len: len, style: s)
    }

    @Test func runsAreNormalizedToTheText() {
        let base = TextLayer(text: "héllo", sizePt: 9)
        // No runs: one run from the summary fields.
        var r = base.charRuns()
        #expect(r.count == 1)
        #expect(r[0].len == 6 && r[0].style.sizePt == 9)
        // Too short: last run stretched. Split inside 'é' snaps to the char boundary.
        var t = base
        t.runs = [run(2, 10), run(1, 20)]
        r = t.charRuns()
        #expect(r.map(\.len) == [3, 3])
        // Too long: truncated; empty runs dropped.
        t.runs = [run(0, 1), run(100, 10), run(5, 20)]
        r = t.charRuns()
        #expect(r.count == 1)
        #expect(r[0].len == 6 && r[0].style.sizePt == 10)
        // Empty text keeps the first run's style.
        t.text = ""
        t.runs = [run(0, 33)]
        #expect(t.charRuns()[0].style.sizePt == 33)
        #expect(t.paragraphRuns().count == 1)
    }

    @Test func trailingBreakKeepsTheFinalEmptyParagraphRun() {
        var t = TextLayer(text: "ab\r\n")
        t.paragraphs = [ParagraphRun(len: 4, style: ParagraphStyle()), ParagraphRun(len: 1, style: ParagraphStyle(align: .right))]
        let p = t.paragraphRuns()
        #expect(p.map(\.len) == [4, 0])
        #expect(p[1].style.align == .right)
    }

    @Test func summaryFollowsFirstRun() {
        var t = TextLayer(text: "ab")
        var s = CharStyle()
        s.fontFamily = "X"
        s.sizePt = 7
        t.runs = [TextRun(len: 2, style: s)]
        t.syncSummary()
        #expect(t.fontFamily == "X" && t.sizePt == 7)
    }

    @Test func stylesSerialize() throws {
        var s = CharStyle()
        s.features = [FontFeature(tag: "ss01", value: 1)]
        #expect(try roundTrip(s) == s)
        // Missing keys take defaults.
        let p = try decodeJSON(ParagraphStyle.self, #"{"align":"Center"}"#)
        #expect(p.align == .center && p.autoLeading == 1.2)
        // Optionals are written as null (attribute sets can clear them); the style ref is omitted.
        let v = try jsonValue(CharStyle())
        #expect(v["postscript_name"] == .null)
        #expect(v["style_sheet"] == nil)
        #expect(try roundTrip(TextShape.box(.init(x: 1, y: 2, width: 3, height: 4))) == .box(.init(x: 1, y: 2, width: 3, height: 4)))
        #expect(try encodeJSON(TextShape.point) == #""Point""#)
    }

    /// photocraft's later type on a path and area type (after this port's base) decode and are
    /// written back unchanged; a path without `end` stays without it (photocraft
    /// `path_end_is_backward_compatible`).
    @Test func pathAndAreaShapesSurviveARoundTrip() throws {
        let onPath = try decodeJSON(TextShape.self, #"{"Path":{"path":{"closed":false,"knots":[],"op":"Combine"},"start":2.0,"flip":false}}"#)
        guard case .path(let p) = onPath else { Issue.record("not a path shape"); return }
        #expect(p.start == 2 && p.end == nil && !p.flip)
        let v = try jsonValue(onPath)
        #expect(v["Path"]?["end"] == nil)
        #expect(try roundTrip(onPath) == onPath)
        #expect(onPath.layoutBox == nil)
        let bounded = TextShape.path(.init(path: Subpath(), start: 80, end: 120, flip: true))
        #expect(try roundTrip(bounded) == bounded)

        let area = TextShape.area(.init(path: VectorPath([.polygon([(10, 20), (110, 20), (110, 70), (10, 70)])])))
        #expect(try roundTrip(area) == area)
        #expect(area.layoutBox == .init(x: 10, y: 20, width: 100, height: 50))
        #expect(try jsonValue(area)["Area"]?["path"] != nil)
    }
}

@Suite struct TextStylesTests {
    func styles() -> TextStyles {
        var s = TextStyles()
        s.character.append(CharacterStyleDef(id: 1, name: "Big", attrs: ["size_pt": 40.0, "underline": true]))
        s.paragraph.append(ParagraphStyleDef(id: 1, name: "Head", paraAttrs: ["align": "Center"], charAttrs: ["size_pt": 20.0, "weight": 700]))
        return s
    }

    @Test func resolutionLayersStyles() {
        let s = styles()
        let none = s.resolveChar(para: nil, chr: nil, defaultFamily: "Inter")
        #expect(none.fontFamily == "Inter" && none.sizePt == 12 && none.styleSheet == nil)
        let head = s.resolveChar(para: 1, chr: nil, defaultFamily: "Inter")
        #expect(head.sizePt == 20 && head.weight == 700)
        let big = s.resolveChar(para: 1, chr: 1, defaultFamily: "Inter")
        #expect(big.sizePt == 40 && big.weight == 700 && big.underline && big.styleSheet == 1)
        // Missing ids fall back.
        #expect(s.resolveChar(para: 9, chr: 9, defaultFamily: "Inter").styleSheet == nil)
        let p = s.resolvePara(1)
        #expect(p.align == .center && p.styleSheet == 1)
        #expect(s.resolvePara(nil).align == .left)
    }

    @Test func overridesSurviveRestyling() {
        let old = styles()
        var run = old.resolveChar(para: nil, chr: 1, defaultFamily: "Inter")
        #expect(old.charOverrides(run, para: nil, defaultFamily: "Inter").isEmpty)
        run.italic = true
        let ov = old.charOverrides(run, para: nil, defaultFamily: "Inter")
        #expect(ov == ["italic": true])
        // Redefine "Big" to 50 pt: the run follows and keeps its italic override.
        var new = old
        new[charStyle: 1]?.attrs["size_pt"] = 50.0
        var r = new.restyleChar(old: old, run: run, oldPara: nil, newPara: nil, newChr: 1, family: "Inter")
        #expect(r.sizePt == 50 && r.italic && r.underline)
        // Clearing the character style keeps overrides on the paragraph basis.
        r = new.restyleChar(old: old, run: run, oldPara: nil, newPara: nil, newChr: nil, family: "Inter")
        #expect(r.sizePt == 12 && r.italic && !r.underline && r.styleSheet == nil)
    }

    @Test func attrsValidateAndDiff() throws {
        try validateAttrs(["size_pt": 3.0], for: CharStyle.self)
        #expect(throws: DocumentError.self) { try validateAttrs(["size_pt": "big"], for: CharStyle.self) }
        #expect(throws: DocumentError.self) { try validateAttrs(["nope": 1], for: CharStyle.self) }
        var a = CharStyle()
        a.sizePt = 30
        a.styleSheet = 3
        #expect(diffAttrs(a, CharStyle()) == ["size_pt": 30.0])
        #expect(charAttrs(a)["style_sheet"] == nil)
        // An override that clears an optional is kept as null.
        var named = CharStyle()
        named.postscriptName = "ArialMT"
        #expect(diffAttrs(CharStyle(), named) == ["postscript_name": nil])
        #expect(try applyAttrs(named, ["postscript_name": nil]).postscriptName == nil)
    }

    @Test func namesAndIds() throws {
        let s = styles()
        #expect(s.uniqueName(paragraph: false, base: "Character Style") == "Character Style 1")
        #expect(s.nextCharId == 2 && s.nextParaId == 2)
        #expect(s.paraStyle(0)?.name == basicParagraphName)
        #expect(try roundTrip(s) == s)
        let empty = try decodeJSON(TextStyles.self, "{}")
        #expect(empty.basic.name == basicParagraphName)
    }

    @Test func exhaustedStyleIdsSurviveSerialization() throws {
        var s = TextStyles()
        s.character.append(CharacterStyleDef(id: .max))
        s.paragraph.append(ParagraphStyleDef(id: .max))
        let loaded = try roundTrip(s)
        #expect(loaded.nextCharId == nil)
        #expect(loaded.nextParaId == nil)
    }
}

@Suite struct VariablesTests {
    @Test func roundTripsThroughJson() throws {
        let v = Variables(
            defs: [
                VariableDef(name: "show", layer: LayerId(1), kind: .visibility),
                VariableDef(name: "title", layer: LayerId(2), kind: .textReplacement),
                VariableDef(name: "photo", layer: LayerId(3), kind: .pixelReplacement(method: .fill, align: .topLeft, clip: true)),
            ],
            dataSets: [DataSet(name: "row1", values: [
                DataValue(variable: "show", value: .visibility(false)),
                DataValue(variable: "title", value: .text("Hello")),
                DataValue(variable: "photo", value: .pixels("/tmp/a.png")),
            ])],
            active: 0)
        #expect(try roundTrip(v) == v)
        // serde's shapes: internally tagged kinds, flattened adjacently tagged values.
        let j = try jsonValue(v)
        #expect(j["defs"]?[2]?["kind"] == ["type": "pixelReplacement", "method": "fill", "align": "topLeft", "clip": true])
        #expect(j["data_sets"]?[0]?["values"]?[1] == ["variable": "title", "kind": "text", "value": "Hello"])
        let pr = try decodeJSON(VarKind.self, #"{"type":"pixelReplacement"}"#)
        #expect(pr == .pixelReplacement(method: .fit, align: .center, clip: false))
    }

    @Test func lookups() {
        let v = Variables(defs: [VariableDef(name: "t", layer: LayerId(9), kind: .textReplacement)],
                          dataSets: [DataSet(name: "s", values: [DataValue(variable: "t", value: .text("x"))])])
        #expect(v.def("t")?.layer == LayerId(9))
        #expect(v.dataSetIndex("s") == 0)
        #expect(v.dataSet("s")?.get("t") == .text("x"))
        #expect(v.def("missing") == nil)
    }
}

@Suite struct VectorTests {
    @Test func segmentsOpenAndClosed() {
        let s = Subpath.polygon([(0, 0), (10, 0), (10, 10)])
        #expect(s.segments.count == 3)
        let o = Subpath.polyline([(0, 0), (10, 0), (10, 10)])
        #expect(o.segments.count == 2)
        #expect(o.segments[1][3] == PCPoint(10, 10))
        #expect(!s.cgPath.isEmpty)
    }

    @Test func firstOpIsCombineAndBounds() {
        let p = VectorPath([Subpath.polygon([(1, 2), (5, 2), (5, 9)]).withOp(.intersect)])
        #expect(p.effectiveOp(0) == .combine)
        #expect(p.controlBounds == SIMD4(1, 2, 5, 9))
        let t = p.transform(.translate(1, 1))
        #expect(t.controlBounds == SIMD4(2, 3, 6, 10))
        #expect(VectorPath().controlBounds == nil)
    }

    @Test func componentsFollowJoins() {
        let sq = Subpath.polygon([(0, 0), (1, 0), (1, 1)])
        let p = VectorPath([sq, sq.withOp(.join), sq.withOp(.subtract), sq.withOp(.join), sq.withOp(.join), sq])
        #expect(p.components == [0..<2, 2..<5, 5..<6])
    }

    @Test func serdeRoundTrip() throws {
        let p = VectorPath([Subpath.polygon([(0, 0), (3, 4)]).withOp(.exclude)])
        let s = ShapeStroke(dashes: [2, 1])
        let live = LiveShape.rect(rect: .zero, radii: SIMD4(repeating: 1))
        #expect(try roundTrip(p) == p)
        #expect(try roundTrip(s) == s)
        #expect(try roundTrip(live) == live)
        #expect(try jsonValue(live) == ["kind": "rect", "rect": [0, 0, 0, 0], "radii": [1, 1, 1, 1]])
        #expect(try jsonValue(LiveShape.polygon(rect: .zero, sides: 5, starRatio: 0.5))["star_ratio"] == 0.5)
        let v = try decodeJSON(VectorPath.self, #"{"subpaths":[{"closed":true,"knots":[]}]}"#)
        #expect(v.subpaths[0].op == .combine)
        let k = try decodeJSON(Knot.self, #"{"anchor":{"x":1,"y":2},"in_ctrl":{"x":1,"y":2},"out_ctrl":{"x":3,"y":4}}"#)
        #expect(k.outCtrl == PCPoint(3, 4) && !k.smooth)
    }

    @Test func strokeValidation() {
        #expect(throws: Never.self) { try ShapeStroke().validate() }
        #expect(throws: DocumentError.self) { try ShapeStroke(width: .nan).validate() }
        #expect(throws: DocumentError.self) { try ShapeStroke(miterLimit: 0.5).validate() }
        #expect(throws: DocumentError.self) { try ShapeStroke(dashes: [0, 0]).validate() }
        #expect(throws: DocumentError.self) { try ShapeStroke(dashes: Array(repeating: 1, count: 33)).validate() }
    }
}

@Suite struct VideoTests {
    @Test func newAndClamp() {
        let t0 = Timeline(duration: 0, fps: 0)
        #expect(t0.duration == 1)
        #expect(t0.fps == 30)
        var t = Timeline(duration: 24, fps: 24)
        t.current = 100
        t.workEnd = 999
        t.clamp()
        #expect(t.current == 23)
        #expect(t.workEnd == 24)
        #expect(abs(t.time - 23.0 / 24.0) < 1e-6)
    }

    /// Stepping never traps or leaves the timeline, whatever was stored.
    @Test func stepSaturatesAtBothEnds() {
        var t = Timeline(duration: 3, fps: 24)
        t.step(-1)
        #expect(t.current == 0)
        t.step(1)
        t.step(.max)
        #expect(t.current == 2)
        t.step(.min)
        #expect(t.current == 0)
        for duration in [0, Int.max] {
            var t = Timeline(fps: .infinity, duration: duration, current: .max, workStart: 0, workEnd: 0)
            t.step(1)
            #expect(t.current == max(duration - 1, 0))
            t.clamp()
            #expect(t.fps == 30)
            #expect(t.current < t.duration)
        }
    }

    @Test func roundTrips() throws {
        let t = Timeline(duration: 48, fps: 25)
        #expect(try roundTrip(t) == t)
        #expect(try decodeJSON(Timeline.self, #"{"fps":24,"duration":10,"current":2,"work_end":10}"#).workStart == 0)
        #expect(try roundTrip(VideoSource.file(path: "/a.mov")) == .file(path: "/a.mov"))
        #expect(try encodeJSON(VideoSource.blank) == #""Blank""#)
    }

    @Test func videoDataComparesByShape() {
        var a = VideoData(frames: [Surface(format: .rgba8)], fps: 24)
        var b = a
        b.frames[0].setPixel(x: 0, y: 0, [1, 1, 1, 1])
        #expect(a == b)
        a.originalFrames = a.frames
        #expect(a != b)
    }
}

/// Brightness/Contrast's Photoshop 27 modes (additive; legacy / modern serialise as before).
@Suite struct BrightnessContrastModeTests {
    typealias BC = Adjustment.BrightnessContrast

    @Test func legacyFlagMapsToTheMode() {
        #expect(BC(brightness: 10, contrast: 5, legacy: true).mode == .legacy)
        #expect(BC(brightness: 10, contrast: 5, legacy: false).mode == .modern)
        var b = BC(contrast: 35, mode: .light)
        #expect(!b.legacy)
        b.legacy = false
        #expect(b.mode == .light, "clearing legacy keeps Light")
        b.legacy = true
        #expect(b.mode == .legacy)
        b.legacy = false
        #expect(b.mode == .modern)
    }

    @Test func jsonIsUnchangedForLegacyAndModernAndCarriesLight() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let modern = String(decoding: try enc.encode(BC(brightness: 10, contrast: -5, legacy: false)), as: UTF8.self)
        #expect(modern == #"{"brightness":10,"contrast":-5,"legacy":false}"#)
        let light = BC(brightness: 0, contrast: 35, mode: .light, exposure: 0.5, whites: 10, blacks: -5, highlights: 20, shadows: -15)
        let back = try JSONDecoder().decode(BC.self, from: try enc.encode(light))
        #expect(back == light)
        let old = try JSONDecoder().decode(BC.self, from: Data(#"{"brightness":3,"contrast":4,"legacy":true}"#.utf8))
        #expect(old == BC(brightness: 3, contrast: 4, legacy: true))
    }

    /// Photoshop 27 clamps Light's controls silently (M3 `lightModeDescriptor`).
    @Test func lightControlsClampToPhotoshopRanges() throws {
        var b = BC(contrast: 150, mode: .light, exposure: 9, whites: -130, blacks: 120, highlights: 101, shadows: -500)
        #expect(b.contrast == 100 && b.exposure == 5 && b.whites == -100 && b.blacks == 100 && b.highlights == 100 && b.shadows == -100)
        b.exposure = -7.5
        b.contrast = -140
        #expect(b.exposure == -5 && b.contrast == -100)
        b.exposure = 1.25
        #expect(b.exposure == 1.25, "in-range values are kept exactly")
        // Modern and legacy contrast keep their values (their ranges are the renderer's business).
        var m = BC(brightness: 10, contrast: -80, legacy: false)
        #expect(m.contrast == -80)
        m.mode = .light
        #expect(m.contrast == -80)
        m.contrast = -120
        #expect(m.contrast == -100)
        let decoded = try JSONDecoder().decode(BC.self, from: Data(#"{"brightness":0,"contrast":0,"legacy":false,"mode":"light","exposure":12}"#.utf8))
        #expect(decoded.exposure == 5)
    }
}
