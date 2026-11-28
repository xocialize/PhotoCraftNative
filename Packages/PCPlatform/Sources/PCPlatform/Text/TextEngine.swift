// Shaping, paragraph layout, rasterisation and glyph outlines on CoreText.
// Replaces photocraft-text (crates/text/src/{layout,render,raster,glyphs,cjk,optical}.rs: parley +
// HarfRust shaping, its own line breaking and Photoshop leading rules, exact-area glyph rasteriser)
// with CoreText (CTTypesetter shaping and line breaking, CTLine justification, CTLineDraw into
// CGContext bitmaps of any depth, CTFontCreatePathForGlyph). Port of its API shape (`TextLayout`,
// `LineInfo`, `PlacedGlyph`, `ClusterInfo`, `rasterize`, `outlines`, hit testing and carets), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.
//
// Layout follows photocraft's (= Photoshop's) rules rather than CoreText's frame setter: point text's
// first baseline sits at the text-space origin; each line advances by the largest leading on it
// (explicit leading, else auto-leading × size); box text's first baseline is the first line's ascent
// below the box top; space before/after separate paragraphs; first-line, start and end indents;
// alignment per paragraph including the four justify modes. Text space is pixels, y down.
//
// Vertical type (photocraft layout.rs) is laid out in *line space* and turned 90° clockwise into
// text space: a line becomes a column running down, and columns advance right to left by their
// leading. CJK characters stay upright, centred on the column (CoreText's vertical forms give
// their `vert` alternates, vertical advances and `VORG` origins); other text runs rotated 90°
// clockwise, centred on the column. Point text's first column is centred on x = 0 and starts at
// y = 0; box text's columns run down the box height from its top, the first column's right edge on
// the box's right edge, and a column past the left edge is dropped with everything after it.
//
// The input is PCDocument's `TextLayer` (photocraft `doc::TextLayer`) and the document resolution,
// as photocraft-text's `TextEngine::layout(layer, dpi)`. Character runs carry fully resolved
// attributes (text style sheets are applied when runs are edited), so `TextStyles` is not consulted
// at render time.

import CoreGraphics
import CoreText
import Foundation
import PCDocument
import PCFoundation

/// A text layer prepared for layout (internal intermediate): its normalised character and
/// paragraph runs (`charRuns()` / `paragraphRuns()`) and the pixels-per-point scale.
struct TextBlock: Sendable {
    let layer: TextLayer
    let dpi: Double
    let text: String
    let runs: [TextRun]
    let paragraphs: [ParagraphRun]
    let box: CGRect?

    init(_ layer: TextLayer, dpi: Double) {
        self.layer = layer
        self.dpi = dpi
        text = layer.text
        runs = layer.charRuns()
        paragraphs = layer.paragraphRuns()
        // A box with non-finite fields (hostile input) lays out as if they were 0.
        func finite(_ v: Float) -> Double { v.isFinite ? Double(v) : 0 }
        // Area type wraps in its path's bounding box and type on a path lays out as point text: the
        // path itself is kept in the model but not followed here yet.
        if let b = layer.shape.layoutBox { box = CGRect(x: finite(b.x), y: finite(b.y), width: finite(b.width), height: finite(b.height)) } else { box = nil }
    }

    var orientation: TextOrientation { layer.orientation }
    var antialias: AntiAlias { layer.antialias }
    var transform: CGAffineTransform { layer.transform.cgAffineTransform }
    /// Pixels per point.
    var scale: Double { dpi > 0 ? dpi / 72 : 1 }

    /// The character style at UTF-8 offset `i` (the last run's past the end).
    func style(at i: Int) -> CharStyle {
        var acc = 0
        for r in runs { acc += r.len; if i < acc { return r.style } }
        return runs.last?.style ?? CharStyle()
    }

    func paragraphStyle(at i: Int) -> ParagraphStyle {
        var acc = 0
        for p in paragraphs { acc += p.len; if i < acc { return p.style } }
        return paragraphs.last?.style ?? ParagraphStyle()
    }
}

/// How a placed glyph's outline is oriented in text space (photocraft `GlyphOrient`).
public enum GlyphOrientation: Sendable, Equatable {
    /// Horizontal type: origin on the baseline, outline upright.
    case horizontal
    /// Vertical type, upright (CJK): the origin is the glyph's horizontal origin — the left end of
    /// its advance, on its baseline — placed so the glyph is centred on the column.
    case upright
    /// Vertical type, turned 90° clockwise about its origin (Latin): the baseline runs down the
    /// column and the ascent points right.
    case rotated
}

/// One positioned glyph (photocraft `PlacedGlyph`).
public struct PlacedGlyph: Sendable, Equatable {
    public var glyph: CGGlyph
    public var fontPostScriptName: String
    public var fontSize: CGFloat
    /// Origin in text space (y down): on the baseline in horizontal type; see `orientation` for
    /// vertical type. Baseline shift is included.
    public var position: CGPoint
    /// Advance along the line (down the column in vertical type).
    public var advance: CGFloat
    /// Source UTF-8 offset of the glyph's character.
    public var sourceIndex: Int
    public var orientation: GlyphOrientation = .horizontal
}

/// One laid-out line (photocraft `LineInfo`).
///
/// Horizontal type: `x` is where the line starts and `baseline` its y, in text space. Vertical
/// type, where a line is a column: `x` is the column's centre line and `baseline` the y the column
/// starts at, in text space; `width` runs down the column and `ascent`/`descent` are the column's
/// half widths (half its largest em). In photocraft's line space (`TextLayout.toLine`) a column's
/// baseline is −`x` and it spans `baseline`…`baseline + width` along.
public struct LineInfo: Sendable, Equatable {
    /// Source UTF-8 range.
    public var range: Range<Int>
    /// Line origin x and baseline y (text space; vertical type: see above).
    public var x: CGFloat
    public var baseline: CGFloat
    /// Extent along the line without the whitespace at its end (photocraft `x1 − x0`).
    public var width: CGFloat
    public var ascent: CGFloat
    public var descent: CGFloat
    /// Baseline-to-baseline distance used to reach this line.
    public var leading: CGFloat
    /// Advance of the whitespace hanging after `width` at the line's end: photocraft (parley
    /// `advance − trailing_whitespace`) keeps it outside the line's extent, and so do alignment and
    /// justification; `width + trailingWhitespace` is the full advance carets can reach.
    public var trailingWhitespace: CGFloat = 0
}

/// One character cluster (photocraft `ClusterInfo`), in line space: `x` is where it starts along
/// the line (text-space x in horizontal type, y down the column in vertical type) and `width` its
/// advance along the line.
public struct ClusterInfo: Sendable, Equatable {
    public var range: Range<Int>
    public var x: CGFloat
    public var width: CGFloat
    public var line: Int
    public var rtl: Bool
}

/// A laid-out text block (photocraft `TextLayout`). Immutable; holds the CoreText lines for drawing.
public final class TextLayout: @unchecked Sendable {
    let block: TextBlock
    /// The laid-out layer and the resolution it was laid out at.
    public var layer: TextLayer { block.layer }
    public var dpi: Double { block.dpi }
    public let lines: [LineInfo]
    public let glyphs: [PlacedGlyph]
    public let clusters: [ClusterInfo]
    /// CoreText lines with, per line, the attributed-string UTF-16 index → source UTF-8 offset map.
    let ctLines: [CTLine]
    let utf16ToSource: [[Int]]
    let utf16Starts: [Int]
    let extras: [[Decoration]]
    /// Vertical type: every glyph as drawn (CoreText draws lines horizontally, so columns are
    /// drawn glyph by glyph).
    let vglyphs: [VGlyph]

    struct Decoration { var rect: CGRect; var color: PCColor }

    /// A vertical-type glyph: its font, colour and stroke from the run, its text-space origin and
    /// orientation, and its ink rectangle in text space.
    struct VGlyph {
        var font: CTFont
        var glyph: CGGlyph
        var position: CGPoint
        var orientation: GlyphOrientation
        var fill: CGColor
        /// Stroke width in px (faux bold / Strong anti-aliasing), 0 for none.
        var stroke: CGFloat
        var ink: CGRect
    }

    init(block: TextBlock, lines: [LineInfo], glyphs: [PlacedGlyph], clusters: [ClusterInfo], ctLines: [CTLine], utf16ToSource: [[Int]], utf16Starts: [Int], extras: [[Decoration]],
         vglyphs: [VGlyph] = []) {
        self.block = block; self.lines = lines; self.glyphs = glyphs; self.clusters = clusters
        self.ctLines = ctLines; self.utf16ToSource = utf16ToSource; self.utf16Starts = utf16Starts; self.extras = extras; self.vglyphs = vglyphs
    }

    /// Vertical type: line space is turned 90° clockwise into text space.
    public var isVertical: Bool { block.orientation == .vertical }

    /// Line space → text space (photocraft `to_text`): the identity for horizontal type; for
    /// vertical type the line direction points down and the next line is to the left.
    public func toText(_ p: CGPoint) -> CGPoint { isVertical ? CGPoint(x: -p.y, y: p.x) : p }

    /// Text space → line space (photocraft `to_line`).
    public func toLine(_ p: CGPoint) -> CGPoint { isVertical ? CGPoint(x: p.y, y: -p.x) : p }

    /// Line `i` in line space: where it starts along the line, its baseline across it, ascent and
    /// descent.
    func lineSpace(_ i: Int) -> (x: CGFloat, baseline: CGFloat, ascent: CGFloat, descent: CGFloat) {
        let l = lines[i]
        return isVertical ? (l.baseline, -l.x, l.ascent, l.descent) : (l.x, l.baseline, l.ascent, l.descent)
    }

    /// Union of line boxes (ascent to descent, origin to width) in text space; columns in vertical
    /// type.
    public var lineBounds: CGRect? {
        guard !lines.isEmpty else { return nil }
        return lines.map { l in
            isVertical ? CGRect(x: l.x - l.descent, y: l.baseline, width: l.ascent + l.descent, height: l.width)
                : CGRect(x: l.x, y: l.baseline - l.ascent, width: l.width, height: l.ascent + l.descent)
        }.reduce(CGRect.null) { $0.union($1) }
    }

    /// Ink bounds in text space (glyph path bounds, faux bold included).
    public var bounds: CGRect? {
        var r = CGRect.null
        if isVertical {
            for g in vglyphs where !g.ink.isNull && !g.ink.isEmpty { r = r.union(g.ink) }
        } else {
            for (i, l) in ctLines.enumerated() {
                let b = CTLineGetBoundsWithOptions(l, .useGlyphPathBounds)
                if b.isNull || b.isEmpty { continue }
                let li = lines[i]
                r = r.union(CGRect(x: li.x + b.minX, y: li.baseline - b.maxY, width: b.width, height: b.height))
            }
        }
        for e in extras.flatMap({ $0 }) { r = r.union(e.rect) }
        return r.isNull ? nil : r
    }

    /// The source UTF-8 offset nearest to a text-space point (photocraft `hit_test`): the line
    /// nearest across (inside its ascent…descent is distance 0), then the nearest caret along it.
    public func hitTest(_ p: CGPoint) -> Int {
        guard !lines.isEmpty else { return 0 }
        let q = toLine(p)
        func distance(_ i: Int) -> CGFloat {
            let s = lineSpace(i)
            if q.y < s.baseline - s.ascent { return s.baseline - s.ascent - q.y }
            if q.y > s.baseline + s.descent { return q.y - s.baseline - s.descent }
            return 0
        }
        let li = lines.indices.min { distance($0) < distance($1) }!
        let idx = CTLineGetStringIndexForPosition(ctLines[li], CGPoint(x: q.x - lineSpace(li).x, y: 0))
        return source(line: li, utf16: idx)
    }

    /// The caret at source UTF-8 offset `offset` in line space (photocraft `caret`): its position
    /// along the line and the line's top and bottom across it — text space for horizontal type;
    /// `caretSegment` gives text space for both.
    public func caret(_ offset: Int) -> (x: CGFloat, top: CGFloat, bottom: CGFloat) {
        guard !lines.isEmpty else { return (0, 0, 0) }
        let li = lines.lastIndex { $0.range.lowerBound <= offset } ?? 0
        let map = utf16ToSource[li]
        let u = (map.firstIndex { $0 >= offset } ?? map.count) + utf16Starts[li]
        let x = CTLineGetOffsetForStringIndex(ctLines[li], u, nil)
        let s = lineSpace(li)
        return (s.x + x, s.baseline - s.ascent, s.baseline + s.descent)
    }

    /// The caret at `offset` as a text-space segment from the line's top to its bottom (photocraft
    /// `caret_segment`): vertical in horizontal type, across the column in vertical type.
    public func caretSegment(_ offset: Int) -> (CGPoint, CGPoint) {
        let c = caret(offset)
        return (toText(CGPoint(x: c.x, y: c.top)), toText(CGPoint(x: c.x, y: c.bottom)))
    }

    func source(line: Int, utf16 idx: Int) -> Int {
        let map = utf16ToSource[line], k = idx - utf16Starts[line]
        if k < 0 { return lines[line].range.lowerBound }
        if k >= map.count { return lines[line].range.upperBound }
        return map[k]
    }
}

/// The result of rasterising a block (photocraft `Rendered`).
public struct RenderedText: Sendable {
    public var layout: TextLayout
    /// Document-space pixel rectangle drawn.
    public var rect: PixelRect
    public var surface: Surface
}

public enum TextEngine {
    // MARK: Attributed strings

    /// One paragraph built for CoreText, with its UTF-16 → source map.
    struct Para {
        var string: NSAttributedString
        var map: [Int]          // per UTF-16 unit, the source UTF-8 offset
        var sourceRange: Range<Int>
        var style: ParagraphStyle
        /// What CoreText does not draw: strikethrough, and in vertical type underline too.
        var decorations: [Decorated]
    }

    struct Decorated {
        var range: NSRange
        var style: CharStyle
        var font: CTFont
        var underline: Bool
    }

    /// How a character is set in vertical type (photocraft `VClass`, a simplification of Unicode's
    /// `Vertical_Orientation`, UAX #50).
    enum VerticalClass: Equatable {
        /// Rotated 90° clockwise (Latin, digits, most symbols).
        case rotate
        /// Upright (ideographs, kana, Hangul, full-width forms, CJK punctuation such as 、。), with
        /// its vertical alternate when the font has one.
        case upright
        /// Upright through its vertical alternate (brackets, the long-vowel mark, dashes); rotated
        /// when the font has none.
        case alternateOrRotate
    }

    /// The vertical-type class of a scalar (photocraft `vertical_class`).
    static func verticalClass(_ u: UInt32) -> VerticalClass {
        switch u {
        case 0x2014...0x2016, 0x2025, 0x2026, 0x2329, 0x232A, 0x3008...0x3011, 0x3014...0x301F, 0x3030, 0x30A0, 0x30FC, 0xFE59...0xFE5E,
             0xFF08, 0xFF09, 0xFF0D, 0xFF1A...0xFF1E, 0xFF3B, 0xFF3D, 0xFF3F, 0xFF5B...0xFF60, 0xFFE3:
            return .alternateOrRotate
        case 0xFF61...0xFFDC:
            // Half-width katakana and Hangul rotate like other half-width text.
            return .rotate
        case 0xA7, 0xA9, 0xAE, 0xB1, 0xBC...0xBE, 0xD7, 0xF7, 0x2E80...0x2EFF, 0xFE10...0xFE1F, 0xFE30...0xFE4F, 0x1F000...0x1FAFF:
            return .upright
        default:
            return isCJK(u) ? .upright : .rotate
        }
    }

    /// A character that needs a CJK font (photocraft `cjk::classify` is `Some`): Hangul, kana,
    /// Bopomofo, Han, CJK punctuation and full-width forms.
    static func isCJK(_ u: UInt32) -> Bool {
        switch u {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF, 0xFFA0...0xFFDC,
             0x3040...0x30FF, 0x31F0...0x31FF, 0xFF65...0xFF9F, 0x1B000...0x1B16F,
             0x3100...0x312F, 0x31A0...0x31BF,
             0x2E80...0x2FDF, 0x3000...0x303F, 0x3190...0x319F, 0x31C0...0x31EF, 0x3200...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF64, 0xFFE0...0xFFEF, 0x20000...0x3FFFF:
            return true
        default:
            return false
        }
    }

    /// Splits text into paragraphs at \r\n, \r and \n (photocraft `split_paragraphs`): ranges exclude
    /// the break.
    static func paragraphs(_ text: String) -> [Range<Int>] {
        let b = Array(text.utf8)
        var out: [Range<Int>] = [], start = 0, i = 0
        while i < b.count {
            if b[i] == 10 || b[i] == 13 {
                out.append(start..<i)
                if b[i] == 13, i + 1 < b.count, b[i + 1] == 10 { i += 1 }
                start = i + 1
            }
            i += 1
        }
        out.append(start..<b.count)
        return out
    }

    /// CoreText attributes of a character style. `verticalForms` sets an upright vertical-type
    /// character (CoreText's `vert` alternates, vertical advances and origins); vertical type places
    /// baseline shift itself, so it passes `baselineShift: false`. Manual kerning is set per pair by
    /// `paragraph`.
    static func attributes(_ s: CharStyle, font: CTFont, scale: Double, antialias: AntiAlias, verticalForms: Bool = false, baselineShift: Bool = true,
                           direction: TextDirection = .auto) -> [NSAttributedString.Key: Any] {
        let px = Double(s.sizePt) * scale
        var a: [NSAttributedString.Key: Any] = [:]
        a[NSAttributedString.Key(kCTFontAttributeName as String)] = font
        let rgb = s.color.rgb
        let cg = CGColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: CGFloat(s.color.alpha))
        a[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = cg
        // Tracking spaces every glyph and keeps pair kerning; kCTKern = 0 turns automatic kerning off.
        if s.tracking != 0 { a[NSAttributedString.Key(kCTTrackingAttributeName as String)] = Double(s.tracking) / 1000 * px }
        if s.kerning == .off { a[NSAttributedString.Key(kCTKernAttributeName as String)] = 0.0 }
        var feats: [[String: Any]] = []
        func ot(_ tag: String, _ v: Int) { feats.append([kCTFontOpenTypeFeatureTag as String: tag, kCTFontOpenTypeFeatureValue as String: v]) }
        if s.kerning == .off { ot("kern", 0) }
        if !s.ligatures { ot("liga", 0); ot("clig", 0) }
        if s.discretionaryLigatures { ot("dlig", 1) }
        if s.caps == .smallCaps, FontCatalog.hasFeature(font, "smcp") { ot("smcp", 1) }
        for f in s.features { ot(f.tag, Int(f.value)) }
        if !feats.isEmpty {
            let d = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(font), [kCTFontFeatureSettingsAttribute: feats] as CFDictionary)
            var m = CTFontGetMatrix(font)
            a[NSAttributedString.Key(kCTFontAttributeName as String)] = CTFontCreateWithFontDescriptor(d, CTFontGetSize(font), &m)
        }
        var stroke = 0.0
        if s.fauxBold { stroke -= 2 * 1.8 }           // photocraft FAUX_BOLD_RADIUS 0.018 em each side
        if antialias == .strong { stroke -= 1.0 }     // Photoshop's "Strong": a slightly heavier edge
        if stroke != 0 {
            a[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = stroke
            a[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = cg
        }
        if s.underline { a[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue }
        if baselineShift, s.baselineShiftPt != 0 { a[NSAttributedString.Key(kCTBaselineOffsetAttributeName as String)] = Double(s.baselineShiftPt) * scale }
        if direction != .auto {
            // The paragraph's base direction for bidi (photocraft `TextDirection`).
            var dir: CTWritingDirection = direction == .rtl ? .rightToLeft : .leftToRight
            let ps = withUnsafeMutablePointer(to: &dir) { p in
                var setting = CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size, value: p)
                return CTParagraphStyleCreate(&setting, 1)
            }
            a[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = ps
        }
        if verticalForms { a[NSAttributedString.Key(kCTVerticalFormsAttributeName as String)] = true }
        if let l = s.language { a[NSAttributedString.Key(kCTLanguageAttributeName as String)] = l }
        return a
    }

    /// Builds the attributed string of one paragraph: runs split at style boundaries; all-caps
    /// uppercased and missing small caps synthesised at 70 % (photocraft
    /// `SYNTHETIC_SMALL_CAPS_SCALE`); in vertical type, upright characters set in vertical forms;
    /// manual kerning set on its pairs.
    static func paragraph(_ block: TextBlock, _ range: Range<Int>) -> Para {
        let bytes = Array(block.text.utf8)
        let m = NSMutableAttributedString()
        var map: [Int] = []
        var decorations: [Decorated] = []
        let scale = block.scale
        let vertical = block.orientation == .vertical
        let direction = block.paragraphStyle(at: range.lowerBound).direction
        // Per scalar: its range in `m`, its manual kern (1/1000 em) and its size in px.
        var pieces: [(range: NSRange, kern: Float, px: Double)] = []
        // Attributes are built once per style, size and orientation.
        struct Key: Hashable { var style: CharStyle; var size: CGFloat; var upright: Bool }
        var memo: [Key: (font: CTFont, attributes: [NSAttributedString.Key: Any])] = [:]
        // The font of the current run (looked up again only where the style changes).
        var current: (style: CharStyle, font: CTFont)?
        // Text is appended a run of equal attributes at a time: every NSAttributedString made with
        // attributes uniques its dictionary under one process-wide lock (measured: per-character
        // appends kept parallel layouts at one thread's throughput).
        var run = "", runKey: Key?
        func flush() {
            guard let k = runKey, !run.isEmpty, let e = memo[k] else { return }
            m.append(NSAttributedString(string: run, attributes: e.attributes))
            run = ""
        }
        var length = 0
        var i = range.lowerBound
        while i < range.upperBound {
            // One scalar at a time keeps every style and kerning boundary exact.
            var len = 1
            let b0 = bytes[i]
            if b0 >= 0xF0 { len = 4 } else if b0 >= 0xE0 { len = 3 } else if b0 >= 0xC0 { len = 2 }
            len = min(len, range.upperBound - i)
            let s = block.style(at: i)
            var str = String(decoding: bytes[i..<(i + len)], as: UTF8.self)
            let nominal = CGFloat(Double(s.sizePt) * scale)
            var size = nominal
            let baseFont: CTFont
            if let c = current, c.style == s { baseFont = c.font } else {
                baseFont = FontCatalog.ctFont(for: s, sizePx: size)
                current = (s, baseFont)
            }
            if s.caps == .allCaps { str = str.uppercased() }
            if s.caps == .smallCaps, !FontCatalog.hasFeature(baseFont, "smcp"), str != str.uppercased() {
                str = str.uppercased(); size *= 0.7
            }
            let font = size == nominal ? baseFont : FontCatalog.ctFont(for: s, sizePx: size)
            var upright = false
            if vertical, let u = str.unicodeScalars.first?.value {
                switch verticalClass(u) {
                case .upright: upright = true
                case .alternateOrRotate: upright = FontCatalog.hasVerticalAlternate(font, str)
                case .rotate: upright = false
                }
            }
            let key = Key(style: s, size: size, upright: upright)
            if memo[key] == nil {
                memo[key] = (font, attributes(s, font: font, scale: scale, antialias: block.antialias, verticalForms: upright, baselineShift: !vertical, direction: direction))
            }
            if key != runKey { flush(); runKey = key }
            run += str
            let added = str.utf16.count
            map += [Int](repeating: i, count: added)
            let r = NSRange(location: length, length: added)
            length += added
            if s.strikethrough { decorations.append(Decorated(range: r, style: s, font: font, underline: false)) }
            if vertical && s.underline { decorations.append(Decorated(range: r, style: s, font: font, underline: true)) }
            pieces.append((r, s.kern, Double(size)))
            i += len
        }
        flush()
        // Manual kerning (after the character) replaces the pair's metrics kerning, as in Photoshop
        // and photocraft (whose `feature_list` turns `kern` off for a manually kerned character).
        // CoreText adds kCTKern to the font's pair kerning, so the pair's own is measured and taken
        // off. A manual value on the paragraph's last character moves nothing (photocraft).
        let kernKey = NSAttributedString.Key(kCTKernAttributeName as String)
        for k in pieces.indices.dropLast() where pieces[k].kern != 0 && pieces[k].kern.isFinite {
            let manual = Double(pieces[k].kern) / 1000 * pieces[k].px
            var v = manual - pairKerning(m, pieces[k].range, pieces[k + 1].range)
            // kCTKern = 0 means "no kerning", not "nothing added".
            if abs(v) < 1e-6 { v = 1e-6 }
            m.addAttribute(kernKey, value: v, range: pieces[k].range)
        }
        return Para(string: m, map: map, sourceRange: range, style: block.paragraphStyle(at: range.lowerBound), decorations: decorations)
    }

    /// The kerning (px) CoreText adds between the characters at `a` and the following `b` in `m`
    /// when the first carries a manual kern: where the second's glyphs start with a negligible
    /// kCTKern on the first, less where they start with kerning off (kCTKern = 0). Glyph positions,
    /// not `CTLineGetOffsetForStringIndex`: the caret offset between a kerned pair carries only
    /// half the pair's kerning (measured: −0.92 of −1.84 px for Helvetica Neue 40 px "AV").
    static func pairKerning(_ m: NSAttributedString, _ a: NSRange, _ b: NSRange) -> Double {
        let probe = 1e-3
        let key = NSAttributedString.Key(kCTKernAttributeName as String)
        let pair = NSMutableAttributedString(attributedString: m.attributedSubstring(from: NSRange(location: a.location, length: b.location + b.length - a.location)))
        let first = NSRange(location: 0, length: a.length)
        func secondStart() -> Double {
            let line = CTLineCreateWithAttributedString(pair)
            var x = Double.infinity
            for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
                let n = CTRunGetGlyphCount(run)
                guard n > 0 else { continue }
                var p = [CGPoint](repeating: .zero, count: n), idx = [CFIndex](repeating: 0, count: n)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &p)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &idx)
                // Vertical-forms runs keep their pen in −y (see `layout`).
                let vertical = (CTRunGetAttributes(run) as NSDictionary)[kCTVerticalFormsAttributeName as String] as? Bool ?? false
                var vt = [CGSize](repeating: .zero, count: vertical ? n : 0)
                if vertical, let f = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] {
                    var gs = [CGGlyph](repeating: 0, count: n)
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &gs)
                    CTFontGetVerticalTranslationsForGlyphs(f as! CTFont, gs, &vt, n)
                }
                for g in 0..<n where idx[g] >= a.length { x = min(x, Double(vertical ? vt[g].height - p[g].y : p[g].x)) }
            }
            return x.isFinite ? x : 0
        }
        pair.addAttribute(key, value: probe, range: first)
        let kerned = secondStart() - probe
        pair.addAttribute(key, value: 0.0, range: first)
        return kerned - secondStart()
    }

    // MARK: Layout

    /// Lays out a text layer at `dpi` (photocraft `TextEngine::layout`; text space is pixels before
    /// `layer.transform`).
    public static func layout(_ layer: TextLayer, dpi: Double = 72) -> TextLayout {
        layout(TextBlock(layer, dpi: dpi))
    }

    static func layout(_ block: TextBlock) -> TextLayout {
        let scale = block.scale
        let vertical = block.orientation == .vertical
        var lines: [LineInfo] = [], ctLines: [CTLine] = [], maps: [[Int]] = [], starts: [Int] = []
        var glyphs: [PlacedGlyph] = [], clusters: [ClusterInfo] = [], extras: [[TextLayout.Decoration]] = [], vglyphs: [TextLayout.VGlyph] = []
        let box = block.box
        // The box along the lines: its width, or its height for vertical type (columns).
        let lineStart = box.map { vertical ? $0.minY : $0.minX } ?? 0
        let lineEnd = box.map { vertical ? $0.maxY : $0.maxX } ?? 0
        let lineLength = box.map { vertical ? $0.height : $0.width }
        // Line space: the baseline across the lines (a column's centre line is at x = −baseline).
        var baseline: CGFloat = 0
        var firstLine = true
        paragraphLoop: for (pi, pr) in paragraphs(block.text).enumerated() {
            let para = paragraph(block, pr)
            let ps = para.style
            let start = CGFloat(Double(ps.startIndentPt) * scale), end = CGFloat(Double(ps.endIndentPt) * scale)
            let first = CGFloat(Double(ps.firstLineIndentPt) * scale)
            if pi > 0 { baseline += CGFloat(Double(ps.spaceBeforePt) * scale) }
            // An empty paragraph still takes a line at its style's size.
            let str: NSAttributedString = para.string.length > 0 ? para.string : {
                let s = block.style(at: pr.lowerBound)
                return NSAttributedString(string: " ", attributes: attributes(s, font: FontCatalog.ctFont(for: s, sizePx: CGFloat(Double(s.sizePt) * scale)), scale: scale,
                                                                          antialias: block.antialias))
            }()
            let ts = CTTypesetterCreateWithAttributedString(str)
            let n = str.length
            var pos = 0
            var lineInPara = 0
            repeat {
                let indent = start + (lineInPara == 0 ? first : 0)
                let avail: CGFloat = lineLength.map { max($0 - indent - end, 1) } ?? 1e7
                var count = CTTypesetterSuggestLineBreak(ts, pos, Double(avail))
                if count <= 0 { count = max(n - pos, 1) }
                var line = CTTypesetterCreateLine(ts, CFRange(location: pos, length: count))
                var ascent: CGFloat = 0, descent: CGFloat = 0, lead: CGFloat = 0
                var width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &lead))
                // Trailing whitespace hangs outside the line's extent (photocraft: parley's advance
                // less its trailing whitespace).
                let trailing = CGFloat(CTLineGetTrailingWhitespaceWidth(line))
                width -= trailing
                let isLast = pos + count >= n
                // Justification.
                if box != nil {
                    let justify = [TextAlign.justifyLeft, .justifyCenter, .justifyRight].contains(ps.align) && !isLast || ps.align == .justifyAll
                    if justify, let j = CTLineCreateJustifiedLine(line, 1.0, Double(avail)) {
                        line = j; width = avail
                    }
                }
                // The line's leading: the largest of its characters' (Photoshop).
                let srcRange = (para.map.isEmpty ? pr : (para.map[pos]..<(pos + count < para.map.count ? para.map[pos + count] : pr.upperBound)))
                var leading: CGFloat = 0
                var i = srcRange.lowerBound
                repeat {
                    let s = block.style(at: i)
                    leading = max(leading, CGFloat(Double(s.leadingPt ?? ps.autoLeading * s.sizePt) * scale))
                    i += 1
                } while i < srcRange.upperBound
                if vertical {
                    // A column's half width: half the largest em on it (photocraft).
                    var half: CGFloat = 0
                    for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] where CTRunGetGlyphCount(run) > 0 {
                        let f = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
                        half = max(half, CTFontGetSize(f) / 2)
                    }
                    ascent = half > 0 ? half : CGFloat(Double(block.style(at: pr.lowerBound).sizePt) * scale) / 2
                    descent = ascent
                }
                if firstLine {
                    // Box text: the first baseline one ascent below the top; the first column's
                    // right edge on the box's right edge.
                    baseline = box.map { vertical ? -$0.maxX + ascent : $0.minY + ascent } ?? 0
                } else {
                    baseline += leading
                }
                // A column past the box's left edge is dropped, with everything after it.
                if vertical, let b = box, baseline + descent > -b.minX + 0.5 { break paragraphLoop }
                firstLine = false
                // Alignment along the line.
                let x: CGFloat
                let align: TextAlign = {
                    switch ps.align {
                    case .justifyLeft: return .left
                    case .justifyCenter: return .center
                    case .justifyRight: return .right
                    case .justifyAll: return .left
                    default: return ps.align
                    }
                }()
                if box != nil {
                    switch align {
                    case .center: x = lineStart + indent + (avail - width) / 2
                    case .right: x = lineEnd - end - width
                    default: x = lineStart + indent
                    }
                } else {
                    switch align {
                    case .center: x = indent - width / 2
                    case .right: x = -end - width
                    default: x = indent
                    }
                }
                let li = lines.count
                lines.append(vertical
                    ? LineInfo(range: srcRange, x: -baseline, baseline: x, width: width, ascent: ascent, descent: descent, leading: leading, trailingWhitespace: trailing)
                    : LineInfo(range: srcRange, x: x, baseline: baseline, width: width, ascent: ascent, descent: descent, leading: leading, trailingWhitespace: trailing))
                ctLines.append(line)
                maps.append(Array(para.map[min(pos, para.map.count)..<min(pos + count, para.map.count)]))
                starts.append(pos)
                // Glyphs and clusters.
                for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
                    let gc = CTRunGetGlyphCount(run)
                    guard gc > 0 else { continue }
                    var gs = [CGGlyph](repeating: 0, count: gc), ps2 = [CGPoint](repeating: .zero, count: gc)
                    var adv = [CGSize](repeating: .zero, count: gc), idx = [CFIndex](repeating: 0, count: gc)
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &gs)
                    CTRunGetPositions(run, CFRange(location: 0, length: 0), &ps2)
                    CTRunGetAdvances(run, CFRange(location: 0, length: 0), &adv)
                    CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &idx)
                    let attrs = CTRunGetAttributes(run) as NSDictionary
                    let font = attrs[kCTFontAttributeName as String] as! CTFont
                    let psName = CTFontCopyPostScriptName(font) as String
                    let rtl = CTRunGetStatus(run).contains(.rightToLeft)
                    // Vertical type: CoreText positions a vertical-forms run's glyphs from their
                    // vertical origins (x = −advance / 2 centres them, y = −VORG − pen); other runs
                    // are rotated and centred on the column by half their ascent − descent.
                    let upright = vertical && ((attrs[kCTVerticalFormsAttributeName as String] as? Bool) ?? false)
                    var vt = [CGSize](repeating: .zero, count: upright ? gc : 0)
                    if upright { CTFontGetVerticalTranslationsForGlyphs(font, gs, &vt, gc) }
                    var inks = [CGRect](repeating: .zero, count: vertical ? gc : 0)
                    if vertical { CTFontGetBoundingRectsForGlyphs(font, .horizontal, gs, &inks, gc) }
                    let fill = attrs[kCTForegroundColorAttributeName as String].map { $0 as! CGColor } ?? CGColor(gray: 0, alpha: 1)
                    let strokePercent = (attrs[kCTStrokeWidthAttributeName as String] as? NSNumber)?.doubleValue ?? 0
                    let stroke = strokePercent < 0 ? CGFloat(-strokePercent) / 100 * CTFontGetSize(font) : 0
                    let centring = (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2
                    for g in 0..<gc {
                        let k = idx[g] - 0
                        let src = k < para.map.count ? para.map[k] : pr.upperBound
                        let along = upright ? vt[g].height - ps2[g].y : ps2[g].x
                        var origin = CGPoint(x: x + ps2[g].x, y: baseline - ps2[g].y)
                        var orientation = GlyphOrientation.horizontal
                        if vertical {
                            // Baseline shift moves a vertical glyph right (photocraft).
                            let shift = CGFloat(Double(block.style(at: src).baselineShiftPt) * scale)
                            let centre = -baseline
                            if upright {
                                origin = CGPoint(x: centre + ps2[g].x + shift, y: x - ps2[g].y)
                                orientation = .upright
                            } else {
                                origin = CGPoint(x: centre - centring + ps2[g].y + shift, y: x + ps2[g].x)
                                orientation = .rotated
                            }
                            let r = inks[g]
                            var ink = CGRect.null
                            if !r.isNull, !r.isEmpty {
                                ink = upright ? CGRect(x: origin.x + r.minX, y: origin.y - r.maxY, width: r.width, height: r.height)
                                    : CGRect(x: origin.x + r.minY, y: origin.y + r.minX, width: r.height, height: r.width)
                                ink = ink.insetBy(dx: -stroke / 2, dy: -stroke / 2)
                            }
                            vglyphs.append(.init(font: font, glyph: gs[g], position: origin, orientation: orientation, fill: fill, stroke: stroke, ink: ink))
                        }
                        glyphs.append(PlacedGlyph(glyph: gs[g], fontPostScriptName: psName, fontSize: CTFontGetSize(font), position: origin, advance: adv[g].width,
                                                  sourceIndex: src, orientation: orientation))
                        let next = k + 1 < para.map.count ? para.map[k + 1] : pr.upperBound
                        clusters.append(ClusterInfo(range: src..<max(next, src + 1), x: x + along, width: adv[g].width, line: li, rtl: rtl))
                    }
                }
                // Strikethrough bars (CoreText draws underline but not strikethrough); in vertical
                // type the underline is right of the column and the strikethrough on its centre line.
                var deco: [TextLayout.Decoration] = []
                for d in para.decorations where d.range.location < pos + count && d.range.location + d.range.length > pos {
                    let a = CTLineGetOffsetForStringIndex(line, max(d.range.location, pos), nil)
                    let b = CTLineGetOffsetForStringIndex(line, min(d.range.location + d.range.length, pos + count), nil)
                    let th = max(CTFontGetUnderlineThickness(d.font), 1)
                    if vertical {
                        let x0 = d.underline ? -baseline + ascent : -baseline - th / 2
                        deco.append(.init(rect: CGRect(x: x0, y: x + min(a, b), width: th, height: abs(b - a)), color: d.style.color))
                    } else {
                        let y = baseline - CTFontGetXHeight(d.font) / 2
                        deco.append(.init(rect: CGRect(x: x + min(a, b), y: y - th / 2, width: abs(b - a), height: th), color: d.style.color))
                    }
                }
                extras.append(deco)
                pos += count
                lineInPara += 1
            } while pos < n
            if !firstLine { baseline += CGFloat(Double(ps.spaceAfterPt) * scale) }
        }
        return TextLayout(block: block, lines: lines, glyphs: glyphs, clusters: clusters, ctLines: ctLines, utf16ToSource: maps, utf16Starts: starts, extras: extras,
                          vglyphs: vglyphs)
    }

    // MARK: Rasterisation

    /// Draws the layout into `ctx`, whose CTM maps text space (y down) to the bitmap.
    static func draw(_ layout: TextLayout, in ctx: CGContext, coverageOnly: Bool) {
        let aa = layout.block.antialias
        ctx.setShouldAntialias(aa != .none)
        ctx.setShouldSmoothFonts(false)
        let subpixel = aa == .smooth || aa == .crisp || aa == .strong
        ctx.setAllowsFontSubpixelPositioning(subpixel)
        ctx.setShouldSubpixelPositionFonts(subpixel)
        ctx.setShouldSubpixelQuantizeFonts(!subpixel)
        if layout.isVertical {
            // Columns glyph by glyph: upright at their origin, or turned 90° clockwise about it.
            ctx.textMatrix = .identity
            for g in layout.vglyphs {
                ctx.saveGState()
                ctx.translateBy(x: g.position.x, y: g.position.y)
                if g.orientation == .rotated { ctx.rotate(by: .pi / 2) }
                ctx.scaleBy(x: 1, y: -1)
                let color = coverageOnly ? CGColor(gray: 1, alpha: 1) : g.fill
                ctx.setFillColor(color)
                if g.stroke > 0 {
                    ctx.setTextDrawingMode(.fillStroke)
                    ctx.setStrokeColor(color)
                    ctx.setLineWidth(g.stroke)
                } else {
                    ctx.setTextDrawingMode(.fill)
                }
                var glyph = g.glyph, at = CGPoint.zero
                CTFontDrawGlyphs(g.font, &glyph, &at, 1, ctx)
                ctx.restoreGState()
            }
        }
        for (i, line) in layout.ctLines.enumerated() {
            if !layout.isVertical {
                let l = layout.lines[i]
                ctx.saveGState()
                ctx.translateBy(x: l.x, y: l.baseline)
                ctx.scaleBy(x: 1, y: -1)
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
            for d in layout.extras[i] {
                if coverageOnly { ctx.setFillColor(gray: 1, alpha: 1) } else {
                    let rgb = d.color.rgb
                    ctx.setFillColor(CGColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: CGFloat(d.color.alpha)))
                }
                ctx.fill(d.rect)
            }
        }
    }

    /// The document-space pixel rectangle the block's ink covers (2 px padding).
    public static func inkRect(_ layout: TextLayout) -> PixelRect {
        guard let b = layout.bounds else { return .empty }
        let d = b.applying(layout.block.transform).insetBy(dx: -2, dy: -2)
        guard d.minX.isFinite, d.minY.isFinite, d.maxX.isFinite, d.maxY.isFinite else { return .empty }
        // Ink beyond ±2³⁰ px (hostile box positions) is clamped there: off any canvas, never a trap.
        func px(_ v: CGFloat) -> Int32 { Int32(min(max(v, -1_073_741_824), 1_073_741_824)) }
        return PixelRect(x0: px(floor(d.minX)), y0: px(floor(d.minY)), x1: px(ceil(d.maxX)), y1: px(ceil(d.maxY)))
    }

    /// A bitmap context over `rect` in document space with text space mapped through the block
    /// transform.
    static func context(rect: PixelRect, transform: CGAffineTransform, sample: SampleType, gray: Bool) -> CGContext? {
        let w = max(rect.width, 1), h = max(rect.height, 1)
        let space = gray ? CGColorSpace(name: CGColorSpace.linearGray)! : CGColorSpace(name: CGColorSpace.sRGB)!
        var info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        if sample == .u16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        if sample == .f32 { info |= CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: sample.bits, bytesPerRow: w * (gray ? 1 : 4) * sample.bytes,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -CGFloat(rect.x0), y: -CGFloat(rect.y0))
        ctx.concatenate(transform)
        return ctx
    }

    /// Anti-aliased coverage (0…1) of the layer in document space at `sample` depth: a grayscale
    /// surface (photocraft's coverage raster; colours ignored).
    public static func rasterizeCoverage(_ layer: TextLayer, dpi: Double = 72, sample: SampleType = .f32) -> RenderedText {
        // Coverage ignores colour: lay the layer out with every run opaque white.
        var white = layer
        white.color = .white
        for i in white.runs.indices { white.runs[i].style.color = .white }
        let block = TextBlock(layer, dpi: dpi)
        let layout = self.layout(TextBlock(white, dpi: dpi))
        let rect = inkRect(layout)
        var s = Surface(format: PixelFormat(mode: .grayscale, sample: sample, alpha: false))
        guard !rect.isEmpty, let ctx = context(rect: rect, transform: block.transform, sample: sample, gray: true) else {
            return RenderedText(layout: self.layout(block), rect: .empty, surface: s)
        }
        draw(layout, in: ctx, coverageOnly: true)
        if let img = ctx.makeImage(), let r = try? SurfaceBridge.raster(from: img) { s.writeInterleaved(rect, r.bytes) }
        return RenderedText(layout: layout, rect: rect, surface: s)
    }

    /// The layer rendered in colour (straight alpha) into a surface of `format` (photocraft
    /// `TextEngine::render`): each run in its own colour, converted to the document model.
    /// `layer.warp` is not applied (see PORT-NOTES).
    public static func rasterize(_ layer: TextLayer, dpi: Double = 72, format: PixelFormat) -> RenderedText {
        let block = TextBlock(layer, dpi: dpi)
        let layout = self.layout(block)
        let rect = inkRect(layout)
        var s = Surface(format: format)
        let sample: SampleType = format.sample
        guard !rect.isEmpty, let ctx = context(rect: rect, transform: block.transform, sample: sample, gray: false) else {
            return RenderedText(layout: layout, rect: .empty, surface: s)
        }
        draw(layout, in: ctx, coverageOnly: false)
        guard let img = ctx.makeImage(), let rgba = try? SurfaceBridge.raster(from: img) else { return RenderedText(layout: layout, rect: rect, surface: s) }
        if format.mode.isRGBLike && format.alpha {
            s.writeInterleaved(rect, rgba.converted(to: sample).bytes)
        } else {
            let f = rgba.floats()
            var out = [Float](repeating: 0, count: rect.area * format.channels)
            for i in 0..<rect.area {
                let a = f[i * 4 + 3]
                guard a > 0 else { continue }
                let c = PCColor(mode: .rgb, c: SIMD4(f[i * 4], f[i * 4 + 1], f[i * 4 + 2], 0), alpha: a).converted(to: format.mode)
                for k in 0..<format.mode.colorChannels { out[i * format.channels + k] = c.c[k] }
                if format.alpha { out[i * format.channels + format.channels - 1] = a }
            }
            s.writeRegion(rect, out)
        }
        return RenderedText(layout: layout, rect: rect, surface: s)
    }

    // MARK: Outlines

    /// Re-renders `layer.cache` from its model (photocraft `TextEngine::render_layer`); returns the
    /// document-space rectangle drawn.
    @discardableResult
    public static func renderLayer(_ layer: inout TextLayer, dpi: Double = 72, format: PixelFormat) -> PixelRect {
        let r = rasterize(layer, dpi: dpi, format: format)
        layer.cache = r.surface
        return r.rect
    }

    /// Glyph outlines in document space as a PCDocument path (photocraft `render::outlines`;
    /// Type ▸ Create Work Path / Convert to Shape).
    public static func outlines(_ layer: TextLayer, dpi: Double = 72) -> VectorPath {
        let block = TextBlock(layer, dpi: dpi)
        let layout = self.layout(block)
        let path = CGMutablePath()
        for (i, line) in layout.ctLines.enumerated() where !layout.isVertical {
            let l = layout.lines[i]
            let lineT = CGAffineTransform(translationX: l.x, y: l.baseline)
            for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
                let n = CTRunGetGlyphCount(run)
                guard n > 0 else { continue }
                var gs = [CGGlyph](repeating: 0, count: n), ps = [CGPoint](repeating: .zero, count: n)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &gs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &ps)
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let font = attrs[kCTFontAttributeName as String] as! CTFont
                for g in 0..<n {
                    // Glyph space (y up) → line space (y down) → text → document. The run positions
                    // already carry the baseline shift.
                    let t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: ps[g].x, ty: -ps[g].y)
                        .concatenating(lineT).concatenating(block.transform)
                    if let gp = CTFontCreatePathForGlyph(font, gs[g], nil) { path.addPath(gp, transform: t) }
                }
            }
        }
        // Vertical type: each glyph upright at its origin, or turned 90° clockwise about it.
        for g in layout.vglyphs {
            let (o, r) = (g.position, g.orientation == .rotated)
            let t = (r ? CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: o.x, ty: o.y) : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: o.x, ty: o.y))
                .concatenating(block.transform)
            if let gp = CTFontCreatePathForGlyph(g.font, g.glyph, nil) { path.addPath(gp, transform: t) }
        }
        for e in layout.extras.flatMap({ $0 }) { path.addRect(e.rect, transform: block.transform) }
        return VectorPath(cgPath: path)
    }
}
