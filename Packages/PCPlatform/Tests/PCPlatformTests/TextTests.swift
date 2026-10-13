// Ports the intent of photocraft-text's tests (crates/text/src/tests.rs, vertical_tests.rs,
// font_names_tests.rs) onto the CoreText engine. MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. Fonts: Inter → Helvetica Neue; the CJK font → Hiragino Sans. Not ported
// from vertical_tests.rs: the punctuation squeeze (`squeeze_punctuation` is not ported) and the
// TySh round trip (PCPSD's).

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import Synchronization
import Testing
@testable import PCPlatform

/// A PCDocument text layer with one run.
private func layer(_ text: String, _ style: CharStyle, paragraph: ParagraphStyle = ParagraphStyle()) -> TextLayer {
    var l = TextLayer(text: text, fontFamily: style.fontFamily, sizePt: style.sizePt, color: style.color)
    l.runs = [TextRun(len: text.utf8.count, style: style)]
    l.paragraphs = [ParagraphRun(len: text.utf8.count, style: paragraph)]
    return l
}

private func point(_ text: String, _ size: Float, family: String = "Helvetica Neue") -> TextLayer {
    TextLayer(text: text, fontFamily: family, sizePt: size)
}

private func styled(_ text: String, _ f: (inout CharStyle) -> Void) -> TextLayer {
    var s = CharStyle(fontFamily: "Helvetica Neue", sizePt: 40)
    f(&s)
    return layer(text, s)
}

private func width(_ l: TextLayout) -> CGFloat { l.lines.map(\.width).max() ?? 0 }

private func coverageSum(_ r: RenderedText) -> Double {
    guard !r.rect.isEmpty else { return 0 }
    return r.surface.readRegion(r.rect).reduce(0) { $0 + Double($1) }
}

@Suite("Text (CoreText replaces photocraft-text)")
struct TextTests {
    @Test func fontsEnumerateAndPostScriptNamesResolve() {
        let fams = FontCatalog.families()
        measure("CoreText lists \(fams.count) font families")
        #expect(fams.contains("Helvetica Neue") && fams.count > 50)
        #expect(FontCatalog.faces(family: "Helvetica Neue").contains { $0.weight >= 700 })
        // photocraft font_names_tests: PostScript-name guessing.
        #expect(FontCatalog.guess(postScriptName: "TimesNewRomanPS-BoldItalicMT") == ("Times New Roman", 700, true))
        #expect(FontCatalog.guess(postScriptName: "ArialMT") == ("Arial", 400, false))
        #expect(FontCatalog.guess(postScriptName: "MyriadPro-Semibold") == ("Myriad Pro", 600, false))
        #expect(FontCatalog.guess(postScriptName: "HelveticaNeue-LightItalic").weight == 300)
        let exact = FontCatalog.resolve(postScriptName: "Helvetica-Bold")
        #expect(exact.exact && exact.face.family == "Helvetica" && exact.face.weight >= 700)
        let guessed = FontCatalog.resolve(postScriptName: "NoSuchFamilyPS-BoldMT")
        #expect(!guessed.exact && guessed.guessedFamily == "No Such Family" && guessed.face.weight >= 600, "falls back to the default family at the guessed weight")
        let face = FontCatalog.resolveFace(styled("x") { $0.postscriptName = "Menlo-Regular" }.runs[0].style)
        #expect(face.postScriptName == "Menlo-Regular" && face.isMonospace)
    }

    @Test func metricsAreStableAndScaleWithDPI() {
        let a = TextEngine.layout(point("Hello world", 24))
        let b = TextEngine.layout(point("Hello world", 24), dpi: 144)
        #expect(abs(width(b) / width(a) - 2) < 0.02, "\(width(a)) \(width(b))")
        #expect(width(TextEngine.layout(point("Hello world", 24))) == width(a), "deterministic")
        #expect(a.lines.count == 1 && a.lines[0].baseline == 0, "point text's first baseline is the origin")
    }

    @Test func autoAndExplicitLeading() {
        let auto = TextEngine.layout(point("one\ntwo\nthree", 20))
        #expect(auto.lines.count == 3)
        #expect(abs(auto.lines[1].baseline - auto.lines[0].baseline - 24) < 0.01, "auto leading 1.2 × 20 pt")
        let fixed = TextEngine.layout(styled("one\ntwo") { $0.sizePt = 20; $0.leadingPt = 33 })
        #expect(abs(fixed.lines[1].baseline - fixed.lines[0].baseline - 33) < 0.01)
        var p = ParagraphStyle(); p.spaceBeforePt = 10; p.spaceAfterPt = 5
        let spaced = TextEngine.layout(layer("a\nb", CharStyle(fontFamily: "Helvetica Neue", sizePt: 20), paragraph: p))
        #expect(abs(spaced.lines[1].baseline - spaced.lines[0].baseline - (24 + 15)) < 0.01, "space after + before")
    }

    @Test func boxTextWrapsInsideItsWidthAndAligns() {
        let text = "The quick brown fox jumps over the lazy dog again and again"
        for align in [TextAlign.left, .center, .right, .justifyLeft] {
            var p = ParagraphStyle(); p.align = align; p.startIndentPt = 4; p.endIndentPt = 6
            let box = CGRect(x: 10, y: 20, width: 160, height: 400)
            var t = layer(text, CharStyle(fontFamily: "Helvetica Neue", sizePt: 18), paragraph: p)
            t.shape = .box(.init(x: 10, y: 20, width: 160, height: 400))
            let l = TextEngine.layout(t)
            #expect(l.lines.count > 2, "\(align)")
            for line in l.lines {
                #expect(line.x >= box.minX + 4 - 0.5 && line.x + line.width <= box.maxX - 6 + 0.5, "\(align) line \(line.x) \(line.width)")
            }
            #expect(l.lines[0].baseline > box.minY && l.lines[0].baseline < box.minY + 20, "first baseline one ascent below the top")
            if align == .center {
                let mid = l.lines[0].x + l.lines[0].width / 2
                #expect(abs(mid - (box.minX + 4 + (box.width - 10) / 2)) < 0.5)
            }
            if align == .justifyLeft {
                #expect(abs(l.lines[0].width - (box.width - 10)) < 0.5, "justified lines fill the measure")
                #expect(l.lines.last!.width < box.width - 10, "the last line is not justified")
            }
        }
        // Point text alignment around the anchor.
        let lc = TextEngine.layout(layer("centred", CharStyle(fontFamily: "Helvetica Neue", sizePt: 20), paragraph: ParagraphStyle(align: .center)))
        #expect(abs(lc.lines[0].x + lc.lines[0].width / 2) < 0.01)
        let lr = TextEngine.layout(layer("right", CharStyle(fontFamily: "Helvetica Neue", sizePt: 20), paragraph: ParagraphStyle(align: .right)))
        #expect(abs(lr.lines[0].x + lr.lines[0].width) < 0.01)
    }

    @Test func trackingKerningCapsAndFeatures() {
        let base = width(TextEngine.layout(styled("Tracking") { _ in }))
        let tracked = width(TextEngine.layout(styled("Tracking") { $0.tracking = 200 }))
        #expect(tracked > base + 40 * 0.2 * 6, "tracking 200/1000 em widens every gap")
        let av = width(TextEngine.layout(styled("AV") { _ in }))
        let avOff = width(TextEngine.layout(styled("AV") { $0.kerning = .off }))
        measure("Helvetica Neue 40 px 'AV': metrics kerning \(av) px, kerning off \(avOff) px")
        #expect(avOff >= av)
        let manual = width(TextEngine.layout(styled("AV") { $0.kern = -100 }))
        #expect(abs(manual - (avOff - 4)) < 0.01, "manual kern −100/1000 em replaces the pair's metrics kerning: \(manual) vs \(avOff) − 4")
        let caps = width(TextEngine.layout(styled("caps") { $0.caps = .allCaps }))
        let small = width(TextEngine.layout(styled("caps") { $0.caps = .smallCaps }))
        let lower = width(TextEngine.layout(styled("caps") { _ in }))
        measure("'caps' widths: normal \(lower), small caps \(small), all caps \(caps)")
        #expect(caps > small && abs(small / caps - 0.7) < 0.03, "synthesised small caps are capitals at 70 % (photocraft)")
        let scaled = width(TextEngine.layout(styled("Wide") { $0.horizontalScale = 1.5 }))
        #expect(abs(scaled / width(TextEngine.layout(styled("Wide") { _ in })) - 1.5) < 0.05)
    }

    @Test func rasterCoverageScalesAndDepthsAgree() throws {
        let t = point("Coverage", 30)
        let c8 = TextEngine.rasterizeCoverage(t, sample: .u8), c16 = TextEngine.rasterizeCoverage(t, sample: .u16), c32 = TextEngine.rasterizeCoverage(t, sample: .f32)
        #expect(c8.rect == c16.rect && c16.rect == c32.rect && !c8.rect.isEmpty)
        let a = c8.surface.readRegion(c8.rect), b = c32.surface.readRegion(c32.rect), m = c16.surface.readRegion(c16.rect)
        let d8 = zip(a, b).map { abs($0 - $1) }.max()!, d16 = zip(m, b).map { abs($0 - $1) }.max()!
        measure("text coverage u8 vs f32 max \(d8 * 255)/255, u16 vs f32 max \(d16 * 65535)/65535")
        #expect(d8 <= 1.0 / 255 + 1e-6 && d16 <= 2.0 / 65535)
        let double = TextEngine.rasterizeCoverage(t, dpi: 144, sample: .f32)
        let ratio = coverageSum(double) / coverageSum(c32)
        measure("ink at 144 dpi / 72 dpi = \(ratio) (area ∝ scale² = 4)")
        #expect(abs(ratio - 4) < 0.2)
        // No anti-aliasing: hard edges.
        var hard = t; hard.antialias = .none
        let h = TextEngine.rasterizeCoverage(hard, sample: .f32)
        #expect(h.surface.readRegion(h.rect).allSatisfy { $0 == 0 || $0 == 1 })
        for aa in [AntiAlias.sharp, .crisp, .strong, .smooth] {
            var x = t; x.antialias = aa
            measure("anti-alias \(aa): ink \(coverageSum(TextEngine.rasterizeCoverage(x)))")
        }
        var strong = t; strong.antialias = .strong
        #expect(coverageSum(TextEngine.rasterizeCoverage(strong)) > coverageSum(c32))
    }

    @Test func stylesChangePixels() {
        let regular = coverageSum(TextEngine.rasterizeCoverage(styled("Style") { _ in }))
        let bold = coverageSum(TextEngine.rasterizeCoverage(styled("Style") { $0.weight = 700 }))
        let faux = coverageSum(TextEngine.rasterizeCoverage(styled("Style") { $0.fauxBold = true }))
        let fauxBig = coverageSum(TextEngine.rasterizeCoverage(styled("Style") { $0.fauxBold = true; $0.sizePt = 80 }))
        let regBig = coverageSum(TextEngine.rasterizeCoverage(styled("Style") { $0.sizePt = 80 }))
        measure("ink: regular \(regular), bold \(bold), faux bold \(faux); faux bold gain at 40 px \(faux / regular), at 80 px \(fauxBig / regBig)")
        #expect(bold > regular * 1.1 && faux > regular * 1.05)
        #expect(abs(faux / regular - fauxBig / regBig) < 0.05, "faux bold scales with the glyphs (photocraft)")
        let italic = TextEngine.rasterizeCoverage(styled("I") { $0.fauxItalic = true })
        let upright = TextEngine.rasterizeCoverage(styled("I") { _ in })
        #expect(italic.rect.width > upright.rect.width, "12° skew widens the ink")
        let under = coverageSum(TextEngine.rasterizeCoverage(styled("Style") { $0.underline = true }))
        let strike = coverageSum(TextEngine.rasterizeCoverage(styled("Style") { $0.strikethrough = true }))
        #expect(under > regular && strike > regular)
        let up = TextEngine.layout(styled("x") { $0.baselineShiftPt = 10 }).bounds!, flat = TextEngine.layout(styled("x") { _ in }).bounds!
        #expect(abs((flat.minY - up.minY) - 10) < 0.5, "baseline shift raises the ink by 10 px")
    }

    @Test func multicolorRunsAndModes() {
        let red = CharStyle(fontFamily: "Helvetica Neue", sizePt: 40, color: .rgb(1, 0, 0))
        var blue = red; blue.color = .rgb(0, 0, 1)
        var block = TextLayer(text: "RRBB")
        block.runs = [TextRun(len: 2, style: red), TextRun(len: 2, style: blue)]
        let r = TextEngine.rasterize(block, format: .rgba8)
        let px = r.surface.readRegion(r.rect)
        var reds = 0, blues = 0
        for i in 0..<r.rect.area where px[i * 4 + 3] > 0.9 {
            let x = i % r.rect.width
            if px[i * 4] > 0.9 && px[i * 4 + 2] < 0.1 { reds += 1; #expect(x < r.rect.width / 2 + 2) }
            if px[i * 4 + 2] > 0.9 && px[i * 4] < 0.1 { blues += 1; #expect(x > r.rect.width / 2 - 2) }
        }
        #expect(reds > 50 && blues > 50)
        let cmyk = TextEngine.rasterize(block, format: .cmyka8)
        #expect(cmyk.surface.format == .cmyka8 && cmyk.rect == r.rect)
        // photocraft `render_layer`: the cache is refreshed from the model.
        let drawn = TextEngine.renderLayer(&block, format: .rgba8)
        #expect(drawn == r.rect && block.cache == r.surface)
    }

    @Test func hitTestCaretAndEmptyLines() {
        let l = TextEngine.layout(point("abc def", 30))
        var last: CGFloat = -1
        for i in 0...7 {
            let c = l.caret(i)
            #expect(c.x >= last, "carets advance")
            last = c.x
            #expect(l.hitTest(CGPoint(x: c.x + 0.5, y: -8)) == i, "hit test at caret \(i)")
        }
        let empty = TextEngine.layout(point("", 20))
        #expect(empty.lines.count == 1 && TextEngine.rasterizeCoverage(point("", 20)).rect.isEmpty)
        let gaps = TextEngine.layout(point("a\n\nb", 20))
        #expect(gaps.lines.count == 3 && gaps.lines[2].range == 3..<4)
        // UTF-8 offsets survive multi-byte characters.
        let u = TextEngine.layout(point("é→x", 20))
        #expect(u.lines[0].range == 0..<6 && u.clusters.map(\.range.lowerBound) == [0, 2, 5])
    }

    @Test func variableFontAxes() throws {
        let axes = FontCatalog.variationAxes(postScriptName: "Skia-Regular")
        measure("Skia variation axes: \(axes.map { "\($0.tag) \($0.minimum)…\($0.maximum)" })")
        let wght = try #require(axes.first { $0.tag == "wght" })
        let thin = coverageSum(TextEngine.rasterizeCoverage(styled("Axes") { $0.postscriptName = "Skia-Regular"; $0.variations = [FontVariation(axis: "wght", value: Float(wght.minimum))] }))
        let heavy = coverageSum(TextEngine.rasterizeCoverage(styled("Axes") { $0.postscriptName = "Skia-Regular"; $0.variations = [FontVariation(axis: "wght", value: Float(wght.maximum))] }))
        measure("Skia wght \(wght.minimum) ink \(thin) vs wght \(wght.maximum) ink \(heavy)")
        #expect(heavy > thin * 1.3)
    }

    @Test func outlinesMatchTheRaster() {
        for t in [point("Outline", 40), styled("Ital") { $0.fauxItalic = true }, styled("Shift") { $0.baselineShiftPt = 8 }] {
            let path = TextEngine.outlines(t)
            let r = TextEngine.rasterizeCoverage(t)
            let cov = VectorRasterizer.fillCoverage(path, rect: r.rect)
            let ras = r.surface.readRegion(r.rect)
            let inter = zip(cov, ras).map { min($0, $1) }.reduce(0, +), uni = zip(cov, ras).map { max($0, $1) }.reduce(0, +)
            measure("glyph outlines (PCDocument VectorPath) vs CTLineDraw coverage IoU \(inter / uni) for '\(t.text)'")
            #expect(inter / uni > 0.93)
        }
    }

    @Test func verticalTextStacksColumnsRightToLeft() {
        var v = point("縦書き\n二列", 30, family: "Hiragino Sans")
        v.orientation = .vertical
        let l = TextEngine.layout(v)
        #expect(l.lines.count == 2 && l.lines[1].x < l.lines[0].x, "the second column is left of the first")
        let r = TextEngine.rasterizeCoverage(v)
        measure("vertical text ink rect \(r.rect)")
        #expect(r.rect.height > r.rect.width, "columns are tall")
        #expect(coverageSum(r) > 100)
    }

    @Test func registeredFontDataResolves() throws {
        let url = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Courier New.ttf")
        guard let data = try? Data(contentsOf: url) else { return }
        let names = FontCatalog.register(fontData: data)
        #expect(names.contains("CourierNewPSMT"))
        #expect(FontCatalog.face(postScriptName: "CourierNewPSMT")?.isMonospace == true)
    }

    // MARK: PCEngine change requests

    /// Request 1: `FontCatalog` answers from caches (faces per family, descriptors per PostScript
    /// name, the face per style, CTFonts per instance) and serves concurrent readers: layouts on
    /// many threads at once, from cold caches, equal the single-threaded ones.
    @Test(.timeLimit(.minutes(2))) func fontCatalogCachesAndServesConcurrentReaders() {
        let clock = ContinuousClock()
        let style = CharStyle(fontFamily: "Times New Roman", sizePt: 24)
        FontCatalog.invalidateCaches()
        let cold = clock.measure { _ = FontCatalog.resolveFace(style) }
        let n = 5000
        let warm = clock.measure { for _ in 0..<n { _ = FontCatalog.resolveFace(style) } } / n
        let uncached = clock.measure { for _ in 0..<50 { _ = FontCatalog.uncachedFaces(family: "Times New Roman") } } / 50
        // Timings are reported, not asserted (parallel suites and CoreText's own caches move them);
        // the Release before/after numbers are in PORT-NOTES §11.
        measure("FontCatalog.resolveFace (Debug): first call \(cold), cached \(warm) per call; one family's faces from the registry \(uncached)")
        #expect(FontCatalog.resolveFace(style).family == "Times New Roman")
        #expect(FontCatalog.ctFont(for: style, sizePx: 24) === FontCatalog.ctFont(for: style, sizePx: 24), "one CTFont per instance")
        #expect(FontCatalog.faces(family: "Times New Roman") == FontCatalog.uncachedFaces(family: "Times New Roman"))
        #expect(FontCatalog.face(postScriptName: "NoSuchFont-Regular") == nil && FontCatalog.face(postScriptName: "NoSuchFont-Regular") == nil, "misses are cached too")

        let families = ["Helvetica Neue", "Times New Roman", "Menlo", "Avenir Next", "Hiragino Sans", "Georgia", "Courier New", "Futura"]
        @Sendable func job(_ i: Int) -> TextLayer {
            var t = layer("The quick brown fox — 縦書き \(i % 7) jumps over the lazy dog", CharStyle(fontFamily: families[i % families.count], sizePt: 18 + Float(i % 3) * 6))
            t.shape = .box(.init(x: 0, y: 0, width: 220, height: 800))
            if i % 4 == 3 { t.orientation = .vertical }
            return t
        }
        let jobs = 24
        let reference = (0..<jobs).map { TextEngine.layout(job($0)).glyphs }
        FontCatalog.invalidateCaches()
        let threads = 16, rounds = 3
        let results = Mutex<[Int: [PlacedGlyph]]>([:])
        let mismatches = Mutex(0)
        let wall = clock.measure {
            DispatchQueue.concurrentPerform(iterations: threads) { t in
                for r in 0..<rounds {
                    for j in stride(from: (t + r) % jobs, to: jobs, by: threads) {
                        let g = TextEngine.layout(job(j)).glyphs
                        if g != reference[j] { mismatches.withLock { $0 += 1 } }
                        results.withLock { $0[j] = g }
                    }
                }
            }
        }
        measure("\(threads) threads laying out \(jobs) mixed layers × \(rounds) from cold font caches (Debug): \(wall)")
        #expect(mismatches.withLock { $0 } == 0, "concurrent layouts equal the single-threaded ones")
        #expect(results.withLock { $0.count } == jobs)
    }

    /// Request 2: a manual kern replaces the pair's metrics kerning (Photoshop; photocraft layout.rs
    /// `feature_list`: "Optical and manual kerning replace the font's kerning table"), and moves
    /// everything after it by kern × size (photocraft `manual_kerning_moves_the_next_glyph`).
    @Test func manualKerningReplacesThePairsMetricsKerning() {
        func runs(_ text: String, _ styles: [(Int, CharStyle)]) -> TextLayer {
            var t = TextLayer(text: text, fontFamily: "Helvetica Neue", sizePt: styles[0].1.sizePt)
            t.runs = styles.map { TextRun(len: $0.0, style: $0.1) }
            return t
        }
        let s = CharStyle(fontFamily: "Helvetica Neue", sizePt: 100)
        func kerned(_ k: Float, _ mode: Kerning = .metrics) -> CharStyle { var c = s; c.kern = k; c.kerning = mode; return c }
        func x(_ l: TextLayout, _ i: Int) -> CGFloat { l.glyphs[i].position.x }
        let plain = TextEngine.layout(runs("HOH", [(3, s)]))
        let k = TextEngine.layout(runs("HOH", [(1, kerned(100)), (2, s)]))
        #expect(x(k, 0) == x(plain, 0))
        // 100/1000 em at 100 px = 10 px, for the next glyph and everything after it.
        #expect(abs(x(k, 1) - x(plain, 1) - 10) < 1e-3 && abs(x(k, 2) - x(plain, 2) - 10) < 1e-3)
        #expect(abs(width(k) - width(plain) - 10) < 1e-3)
        #expect(abs(x(TextEngine.layout(runs("HOH", [(1, kerned(-50)), (2, s)])), 1) - x(plain, 1) + 5) < 1e-3, "negative kerning tightens")
        #expect(abs(width(TextEngine.layout(runs("HOH", [(2, s), (1, kerned(500))]))) - width(plain)) < 1e-3, "the last character's kern moves nothing")
        // The pair's metrics kerning is replaced, not added to: "AV" kerns by itself.
        let metric = x(TextEngine.layout(runs("AV", [(2, s)])), 1)
        let off = x(TextEngine.layout(runs("AV", [(2, kerned(0, .off))])), 1)
        let manual = x(TextEngine.layout(runs("AV", [(1, kerned(-50)), (1, s)])), 1)
        measure("Helvetica Neue 100 px 'AV': V at \(metric) (metrics), \(off) (off), \(manual) (manual −50: off − 5)")
        #expect(off - metric > 1, "Helvetica Neue kerns AV")
        #expect(abs(manual - (off - 5)) < 1e-3, "manual −50/1000 em from the unkerned pair")
        #expect(abs(x(TextEngine.layout(runs("AV", [(1, kerned(-50, .off)), (1, s)])), 1) - (off - 5)) < 1e-3, "Off with a manual kern: the manual value")
        #expect(abs(x(TextEngine.layout(runs("AV", [(1, kerned(-50, .optical)), (1, s)])), 1) - (off - 5)) < 1e-3)
        // The pair before the kerned character keeps its own kerning.
        let vav = TextEngine.layout(runs("VAV", [(3, s)])), vak = TextEngine.layout(runs("VAV", [(1, s), (1, kerned(100)), (1, s)]))
        #expect(abs(x(vak, 1) - x(vav, 1)) < 1e-3, "V·A stays metrics-kerned")
        #expect(abs(x(vak, 2) - x(vak, 1) - (off + 10)) < 1e-3, "A·V: the unkerned advance + 10 px")
        // Centred point text stays centred around the anchor with kerning.
        var centred = runs("HOH", [(1, kerned(300)), (2, s)])
        centred.paragraphs = [ParagraphRun(len: 3, style: ParagraphStyle(align: .center))]
        let c = TextEngine.layout(centred)
        #expect(abs(c.lines[0].x + c.lines[0].width / 2) < 0.5)
    }

    /// Request 4, checked against photocraft: its line extent is parley's advance less the trailing
    /// whitespace (layout.rs `adv = m.advance - m.trailing_whitespace`, `x1 = x0 + adv + …`; tests.rs
    /// "a trailing tab is whitespace outside the line's extent"), so `width` keeps trailing spaces
    /// out — alignment and justification ignore them — and `trailingWhitespace` gives their advance.
    @Test func trailingWhitespaceHangsOutsideTheLineExtent() {
        let style = CharStyle(fontFamily: "Helvetica Neue", sizePt: 30)
        let bare = TextEngine.layout(layer("abc", style)), spaced = TextEngine.layout(layer("abc   ", style))
        let space = TextEngine.layout(layer("a b", style)).lines[0].width - TextEngine.layout(layer("ab", style)).lines[0].width
        #expect(abs(spaced.lines[0].width - bare.lines[0].width) < 1e-3)
        #expect(abs(spaced.lines[0].trailingWhitespace - 3 * space) < 0.01 && bare.lines[0].trailingWhitespace == 0, "\(spaced.lines[0].trailingWhitespace) vs 3 × \(space)")
        // Carets still reach the end of the spaces.
        let l = spaced.lines[0]
        #expect(abs(spaced.caret(6).x - (l.x + l.width + l.trailingWhitespace)) < 0.01)
        #expect(spaced.hitTest(CGPoint(x: l.x + l.width + l.trailingWhitespace + 5, y: -5)) == 6)
        // Right-aligned point text: the ink ends at the anchor, the spaces hang past it.
        let right = TextEngine.layout(layer("abc   ", style, paragraph: ParagraphStyle(align: .right)))
        #expect(abs(right.lines[0].x + right.lines[0].width) < 1e-3)
        // A wrapped box line's space hangs past the right edge.
        let boxWidth = Float(bare.lines[0].width + 10)
        var box = layer("abc def", style, paragraph: ParagraphStyle(align: .right))
        box.shape = .box(.init(x: 0, y: 0, width: boxWidth, height: 200))
        let b = TextEngine.layout(box)
        #expect(b.lines.count == 2 && abs(b.lines[0].x + b.lines[0].width - CGFloat(boxWidth)) < 0.01 && b.lines[0].trailingWhitespace > 0)
    }

    // MARK: Vertical type (photocraft vertical_tests.rs; PCEngine request 3)

    private func vertical(_ text: String, _ family: String = "Helvetica Neue", _ size: Float = 20) -> TextLayer {
        var t = TextLayer(text: text, fontFamily: family, sizePt: size)
        t.orientation = .vertical
        return t
    }

    @Test func verticalClassesFollowUnicodeVerticalOrientation() {
        for c in ["縦", "か", "カ", "한", "、", "。", "Ａ", "１"] { #expect(TextEngine.verticalClass(c.unicodeScalars.first!.value) == .upright, "\(c)") }
        for c in ["ー", "「", "」", "（", "）", "〜", "…", "—"] { #expect(TextEngine.verticalClass(c.unicodeScalars.first!.value) == .alternateOrRotate, "\(c)") }
        for c in ["A", "z", "1", " ", "-", "ｶ", "é"] { #expect(TextEngine.verticalClass(c.unicodeScalars.first!.value) == .rotate, "\(c)") }
    }

    @Test func verticalLatinIsRotatedAndRunsDownColumnsRightToLeft() {
        let l = TextEngine.layout(vertical("abc\nde"))
        #expect(l.isVertical && l.lines.count == 2)
        #expect(l.glyphs.allSatisfy { $0.orientation == .rotated })
        let (a, b, c, d) = (l.glyphs[0].position, l.glyphs[1].position, l.glyphs[2].position, l.glyphs[3].position)
        // Down the first column, on one vertical baseline.
        #expect(a.y < b.y && b.y < c.y && a.x == b.x && b.x == c.x, "\(a) \(b) \(c)")
        // The second column is to the left by the leading and starts at the top again.
        #expect(abs(a.x - d.x - 24) < 1e-3 && abs(d.y - a.y) < 1e-3, "\(a) \(d)")
        // Rotated text is centred on the column through the anchor (x = 0): its baseline sits left.
        #expect(a.x < 0 && a.x > -10, "\(a)")
        // The column: centre line x, half widths of half an em, running down from y = 0.
        #expect(l.lines[0].x == 0 && l.lines[1].x == -24 && l.lines[0].ascent == 10 && l.lines[0].descent == 10 && l.lines[0].baseline == 0)
        let one = TextEngine.layout(vertical("abcdef")).lineBounds!
        #expect(one.height > 2 * one.width && abs(one.minX + 10) < 1e-3 && abs(one.maxX - 10) < 1e-3 && abs(one.minY) < 1e-3, "\(one)")
        // Clusters are in line space: along the column.
        #expect(l.clusters.map(\.line) == [0, 0, 0, 1, 1] && l.clusters[0].x == 0 && abs(l.clusters[1].x - l.clusters[0].width) < 1e-3)
        #expect(abs(l.clusters[1].x - b.y) < 1e-3, "a rotated glyph's origin is its cluster's start")
    }

    @Test func verticalRotatedInkIsTheHorizontalWordTurned() {
        var h = TextLayer(text: "Vertical", fontFamily: "Helvetica Neue", sizePt: 30)
        h.transform = PCAffine(a: 1, b: 0, c: 0, d: 1, e: 100, f: 50)
        var v = h
        v.orientation = .vertical
        let hr = TextEngine.rasterize(h, format: .rgba8).rect, vr = TextEngine.rasterize(v, format: .rgba8).rect
        measure("'Vertical' 30 px ink: horizontal \(hr), vertical \(vr)")
        #expect(hr.width > hr.height && vr.height > 2 * vr.width, "\(vr)")
        #expect(abs(vr.height - hr.width) <= 3, "same ink length: \(vr) \(hr)")
        // It runs down from the anchor (2 px ink padding), centred on x = 100.
        #expect(vr.y0 >= 47 && vr.x0 < 100 && vr.x1 > 100, "\(vr)")
    }

    @Test func verticalCaretAndHitTestFollowColumns() {
        let l = TextEngine.layout(vertical("abc\ndef"))
        // Above the first column's top → offset 0; below it → the end of the first line.
        #expect(l.hitTest(CGPoint(x: 0, y: -5)) == 0)
        #expect(l.hitTest(CGPoint(x: 0, y: 1000)) == 3)
        // Left of the anchor is the second column.
        #expect(l.hitTest(CGPoint(x: -24, y: -5)) == 4)
        // Down the column: each caret's position hits back to itself.
        for i in 0...3 {
            let (p, q) = l.caretSegment(i)
            #expect(l.hitTest(CGPoint(x: (p.x + q.x) / 2, y: p.y + 0.3)) == i, "caret \(i) at \(p)")
        }
        // The caret is a horizontal segment across the column, lower for later offsets.
        let (p0, p1) = l.caretSegment(1)
        #expect(abs(p0.y - p1.y) < 1e-4 && p0.x > p1.x && abs(p0.x - p1.x - 20) < 1e-3, "\(p0) \(p1)")
        #expect(l.caretSegment(2).0.y > p0.y)
        // `caret` is line space: along the column, across it.
        #expect(abs(l.caret(1).x - p0.y) < 1e-4 && l.caret(1).top == -10 && l.caret(5).top == 14)
        // Round trip through line space.
        #expect(l.toText(l.toLine(CGPoint(x: -7, y: 33))) == CGPoint(x: -7, y: 33))
        #expect(l.toLine(CGPoint(x: -7, y: 33)) == CGPoint(x: 33, y: 7))
    }

    @Test func verticalBoxTextWrapsColumnsWithinTheBoxHeight() {
        var t = vertical("ab cd ef gh ij kl mn op")
        t.shape = .box(.init(x: 10, y: 20, width: 200, height: 60))
        let l = TextEngine.layout(t)
        #expect(l.lines.count >= 3, "\(l.lines.count)")
        let b = l.lineBounds!
        // Columns start at the box's right edge and wrap within its height, from its top.
        #expect(abs(b.maxX - 210) < 1e-3 && b.minX >= 10 - 1e-3 && b.minY >= 20 - 1e-3 && b.maxY <= 80 + 1e-3, "\(b)")
        #expect(abs(l.lines[0].baseline - 20) < 1e-3)
        for g in l.glyphs { #expect(g.position.y >= 20 - 1e-3 && g.position.y <= 80 + 1e-3, "\(g)") }
        // A narrow box drops the columns that don't fit (like overflowing lines).
        var narrow = t
        narrow.shape = .box(.init(x: 0, y: 0, width: 30, height: 60))
        #expect(TextEngine.layout(narrow).lines.count == 1)
        // Alignment runs along the column: centred and bottom-aligned columns in the box height.
        for (align, edge) in [(TextAlign.center, CGFloat(50)), (.right, 80)] {
            var a = vertical("ab")
            a.shape = .box(.init(x: 10, y: 20, width: 200, height: 60))
            a.paragraphs = [ParagraphRun(len: 2, style: ParagraphStyle(align: align))]
            let line = TextEngine.layout(a).lines[0]
            #expect(abs((align == .center ? line.baseline + line.width / 2 : line.baseline + line.width) - edge) < 1e-3, "\(align): \(line)")
        }
    }

    @Test func horizontalLayoutIsUnchangedByTheVerticalPath() {
        let l = TextEngine.layout(point("abc", 20))
        #expect(!l.isVertical && l.glyphs.allSatisfy { $0.orientation == .horizontal })
        #expect(l.toText(CGPoint(x: 3, y: 4)) == CGPoint(x: 3, y: 4))
        let (p, q) = l.caretSegment(1)
        #expect(p.x == q.x && p.y == l.lines[0].baseline - l.lines[0].ascent && q.y == l.lines[0].baseline + l.lines[0].descent)
    }

    @Test func verticalCJKIsUprightCentredWithVerticalAlternates() {
        let text = "縦書き、テスト。ーA"
        let l = TextEngine.layout(vertical(text, "Hiragino Sans", 40))
        var flat = vertical(text, "Hiragino Sans", 40)
        flat.orientation = .horizontal
        let h = TextEngine.layout(flat)
        let g = l.glyphs
        #expect(g.count == text.count && g.allSatisfy { $0.glyph != 0 })
        // Ideographs and kana: upright, centred on the column (full-width advance 40 px).
        for (i, gl) in g.prefix(8).enumerated() {
            #expect(gl.orientation == .upright, "glyph \(i)")
            #expect(abs(gl.position.x + 20) < 4, "glyph \(i) at \(gl.position)")
        }
        // Positions go down the column; the first glyph's baseline is inside its em cell (its VORG).
        #expect(zip(g, g.dropFirst()).allSatisfy { $1.position.y > $0.position.y })
        #expect(g[0].position.y > 20 && g[0].position.y < 40, "\(g[0])")
        // 、 and 。 use their vertical alternates.
        for i in [3, 7] { #expect(g[i].glyph != h.glyphs[i].glyph, "char \(i) should use its vertical alternate") }
        // ー: upright through its alternate when the font has one, else rotated.
        #expect(g[8].glyph != h.glyphs[8].glyph ? g[8].orientation == .upright : g[8].orientation == .rotated)
        // Latin inside vertical CJK runs rotated.
        #expect(g[9].orientation == .rotated)
        // Rendered: the column is tall and narrow, centred on the anchor and running down from it.
        var r = vertical("縦書きテスト", "Hiragino Sans", 40)
        r.transform = PCAffine(a: 1, b: 0, c: 0, d: 1, e: 900, f: 30)
        let rect = TextEngine.rasterizeCoverage(r).rect
        measure("'縦書きテスト' Hiragino Sans 40 px vertical at (900, 30): ink \(rect)")
        #expect(rect.height > 4 * rect.width, "\(rect)")
        #expect(rect.x0 > 870 && rect.x1 < 930 && rect.y0 >= 28 && rect.y1 < 30 + 6 * 40 + 4, "\(rect)")
        // Outlines follow the drawn glyphs.
        let path = TextEngine.outlines(r)
        let cov = TextEngine.rasterizeCoverage(r)
        let o = VectorRasterizer.fillCoverage(path, rect: cov.rect), ras = cov.surface.readRegion(cov.rect)
        let iou = zip(o, ras).map { min($0, $1) }.reduce(0, +) / zip(o, ras).map { max($0, $1) }.reduce(0, +)
        measure("vertical glyph outlines vs drawn coverage IoU \(iou)")
        #expect(iou > 0.93)
    }

    @Test func verticalManualKerningRunsAlongTheColumn() {
        func kerned(_ t: TextLayer, _ kern: Float) -> TextLayer {
            var k = t
            let first = t.text.unicodeScalars.first.map { String($0).utf8.count } ?? 0
            var s = t.runs.first?.style ?? CharStyle(fontFamily: t.fontFamily, sizePt: t.sizePt)
            let rest = s
            s.kerning = .off; s.kern = kern
            k.runs = [TextRun(len: first, style: s), TextRun(len: t.text.utf8.count - first, style: rest)]
            return k
        }
        // Rotated Latin: 100/1000 em at 40 px = 4 px further down for the second glyph on.
        let t = vertical("HOH", "Helvetica Neue", 40)
        let plain = TextEngine.layout(t), k = TextEngine.layout(kerned(t, 100))
        #expect(k.glyphs[0].position == plain.glyphs[0].position)
        for i in 1..<3 {
            #expect(abs(k.glyphs[i].position.y - plain.glyphs[i].position.y - 4) < 1e-3, "\(i)")
            #expect(abs(k.glyphs[i].position.x - plain.glyphs[i].position.x) < 1e-3, "stays on the column")
        }
        #expect(abs(k.lineBounds!.maxY - plain.lineBounds!.maxY - 4) < 1e-3, "the column grows by the kern")
        // Upright CJK moves up by 10 px.
        let c = vertical("東京、「都」", "Hiragino Sans", 40)
        let cp = TextEngine.layout(c), ck = TextEngine.layout(kerned(c, -250))
        #expect(abs(ck.glyphs[1].position.y - cp.glyphs[1].position.y + 10) < 1e-3, "\(ck.glyphs[1].position) vs \(cp.glyphs[1].position)")
    }

    @Test func verticalDecorationsAndFauxBoldDraw() {
        let base = vertical("縦書きAb", "Hiragino Sans", 30)
        func ink(_ f: (inout CharStyle) -> Void) -> (Double, RenderedText) {
            var t = base
            var s = CharStyle(fontFamily: "Hiragino Sans", sizePt: 30)
            f(&s)
            t.runs = [TextRun(len: t.text.utf8.count, style: s)]
            let r = TextEngine.rasterizeCoverage(t)
            return (coverageSum(r), r)
        }
        let (plain, pr) = ink { _ in }
        let (under, ur) = ink { $0.underline = true }
        let (strike, _) = ink { $0.strikethrough = true }
        let (bold, _) = ink { $0.fauxBold = true }
        measure("vertical ink: plain \(plain), underline \(under), strikethrough \(strike), faux bold \(bold)")
        #expect(under > plain && strike > plain && bold > plain * 1.05)
        // The underline is right of the column.
        #expect(ur.rect.x1 > pr.rect.x1)
    }

    @Test func hostileVerticalInputDoesNotTrap() {
        for text in ["", "\n\n", "\u{200F}א\u{0301}", "「」ー。、\r\n\u{FFFF}", "a\u{0000}b"] {
            for shape in [TextShape.point, .box(.init(x: 0, y: 0, width: 0, height: 0)), .box(.init(x: .nan, y: 1e30, width: -5, height: 1))] {
                var t = vertical(text, "Helvetica Neue", 12)
                t.shape = shape
                let r = TextEngine.rasterize(t, format: .rgba8)
                _ = (r.layout.bounds, r.layout.lineBounds, r.layout.hitTest(CGPoint(x: 1, y: 2)), r.layout.caretSegment(1), TextEngine.outlines(t))
            }
        }
    }
}
