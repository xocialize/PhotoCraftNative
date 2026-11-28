// Typed style model for type (text) layers: character runs, paragraph runs, point/box shape and
// warp. Pure data; layout and rendering live in the text engine.
// Port of photocraft-doc (crates/doc/src/text.rs, and `TextLayer` from lib.rs), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.
//
// Units follow Photoshop's Character/Paragraph panels: sizes, leading, indents and spacing are in
// points (converted to pixels with the document resolution: `px = pt * dpi / 72`), tracking is in
// 1/1000 em, and box bounds are in text-space pixels (before the layer transform).
//
// Runs cover the text by UTF-8 byte length, in order. A run list whose lengths don't add up to
// `text.utf8.count` is normalised by `TextLayer.charRuns` (the last run is stretched or truncated),
// so edits never produce unstyled text.

import PCFoundation

/// Kerning mode (Photoshop: Metrics, Optical, 0).
public enum Kerning: String, CaseIterable, Hashable, Sendable, Codable {
    /// Font kerning (`kern` feature).
    case metrics = "Metrics"
    /// Photoshop's optical kerning: pair spacing computed from the glyph outlines.
    case optical = "Optical"
    /// No automatic kerning (Photoshop's "0" / manual kerning).
    case off = "Off"
}

public enum Caps: String, CaseIterable, Hashable, Sendable, Codable {
    case normal = "Normal"
    case smallCaps = "SmallCaps"
    case allCaps = "AllCaps"
}

/// An OpenType feature setting, e.g. `{ tag: "ss01", value: 1 }`.
public struct FontFeature: Hashable, Sendable, Codable {
    public var tag: String
    public var value: UInt16
    public init(tag: String, value: UInt16) { self.tag = tag; self.value = value }
}

/// A variable-font axis setting, e.g. `{ axis: "wght", value: 650 }`.
public struct FontVariation: Hashable, Sendable, Codable {
    public var axis: String
    public var value: Float
    public init(axis: String, value: Float) { self.axis = axis; self.value = value }
}

/// Character style (Photoshop's Character panel). Every JSON key is optional; nil optionals are
/// written as `null` (except `style_sheet`, omitted when nil) so attribute sets can clear them.
public struct CharStyle: Hashable, Sendable, Codable {
    /// Family name ("Inter"). Empty = the default family.
    public var fontFamily: String = ""
    /// Face style name as shown in the UI ("Bold Italic"); informational, `weight`/`italic` rule.
    public var fontStyle: String = ""
    /// PostScript name from a PSD (`ArialMT`), used to find the exact face when present.
    public var postscriptName: String?
    /// CSS-style weight, 100–900.
    public var weight: UInt16 = 400
    public var italic = false
    public var sizePt: Float = 12
    public var color: PCColor = .black
    /// Letter spacing in 1/1000 em.
    public var tracking: Float = 0
    /// Baseline-to-baseline distance in points; nil = auto (paragraph `autoLeading` × size).
    public var leadingPt: Float?
    /// Positive raises the text.
    public var baselineShiftPt: Float = 0
    public var horizontalScale: Float = 1
    public var verticalScale: Float = 1
    public var underline = false
    public var strikethrough = false
    public var fauxBold = false
    public var fauxItalic = false
    /// Automatic (pair) kerning mode.
    public var kerning: Kerning = .metrics
    /// Manual kerning in 1/1000 em between this character and the next one (Photoshop stores it
    /// per character run as `Kerning`). Added to the automatic kerning of the pair.
    public var kern: Float = 0
    public var caps: Caps = .normal
    /// Standard ligatures (`liga`/`clig`).
    public var ligatures = true
    /// Discretionary ligatures (`dlig`).
    public var discretionaryLigatures = false
    /// Extra OpenType features (`ss01`, `onum`, `tnum`, …).
    public var features: [FontFeature] = []
    /// Variable-font axis values.
    public var variations: [FontVariation] = []
    /// BCP-47 language tag (affects shaping and line breaking).
    public var language: String?
    /// Applied character style (id in `TextStyles`); nil = "None". Attributes above stay fully
    /// resolved; differences from the style are local overrides.
    public var styleSheet: UInt32?

    public init() {}

    public init(fontFamily: String = "", sizePt: Float = 12, color: PCColor = .black) {
        self.fontFamily = fontFamily; self.sizePt = sizePt; self.color = color
    }

    enum CodingKeys: String, CodingKey {
        case fontFamily = "font_family", fontStyle = "font_style", postscriptName = "postscript_name", weight, italic
        case sizePt = "size_pt", color, tracking, leadingPt = "leading_pt", baselineShiftPt = "baseline_shift_pt"
        case horizontalScale = "horizontal_scale", verticalScale = "vertical_scale", underline, strikethrough
        case fauxBold = "faux_bold", fauxItalic = "faux_italic", kerning, kern, caps, ligatures
        case discretionaryLigatures = "discretionary_ligatures", features, variations, language, styleSheet = "style_sheet"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CharStyle()
        fontFamily = try c.decode(.fontFamily, or: d.fontFamily)
        fontStyle = try c.decode(.fontStyle, or: d.fontStyle)
        postscriptName = try c.decodeIfPresent(String.self, forKey: .postscriptName)
        weight = try c.decode(.weight, or: d.weight)
        italic = try c.decode(.italic, or: d.italic)
        sizePt = try c.decode(.sizePt, or: d.sizePt)
        color = try c.decode(.color, or: d.color)
        tracking = try c.decode(.tracking, or: d.tracking)
        leadingPt = try c.decodeIfPresent(Float.self, forKey: .leadingPt)
        baselineShiftPt = try c.decode(.baselineShiftPt, or: d.baselineShiftPt)
        horizontalScale = try c.decode(.horizontalScale, or: d.horizontalScale)
        verticalScale = try c.decode(.verticalScale, or: d.verticalScale)
        underline = try c.decode(.underline, or: d.underline)
        strikethrough = try c.decode(.strikethrough, or: d.strikethrough)
        fauxBold = try c.decode(.fauxBold, or: d.fauxBold)
        fauxItalic = try c.decode(.fauxItalic, or: d.fauxItalic)
        kerning = try c.decode(.kerning, or: d.kerning)
        kern = try c.decode(.kern, or: d.kern)
        caps = try c.decode(.caps, or: d.caps)
        ligatures = try c.decode(.ligatures, or: d.ligatures)
        discretionaryLigatures = try c.decode(.discretionaryLigatures, or: d.discretionaryLigatures)
        features = try c.decode(.features, or: d.features)
        variations = try c.decode(.variations, or: d.variations)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        styleSheet = try c.decodeIfPresent(UInt32.self, forKey: .styleSheet)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fontFamily, forKey: .fontFamily)
        try c.encode(fontStyle, forKey: .fontStyle)
        try c.encode(postscriptName, forKey: .postscriptName)
        try c.encode(weight, forKey: .weight)
        try c.encode(italic, forKey: .italic)
        try c.encode(sizePt, forKey: .sizePt)
        try c.encode(color, forKey: .color)
        try c.encode(tracking, forKey: .tracking)
        try c.encode(leadingPt, forKey: .leadingPt)
        try c.encode(baselineShiftPt, forKey: .baselineShiftPt)
        try c.encode(horizontalScale, forKey: .horizontalScale)
        try c.encode(verticalScale, forKey: .verticalScale)
        try c.encode(underline, forKey: .underline)
        try c.encode(strikethrough, forKey: .strikethrough)
        try c.encode(fauxBold, forKey: .fauxBold)
        try c.encode(fauxItalic, forKey: .fauxItalic)
        try c.encode(kerning, forKey: .kerning)
        try c.encode(kern, forKey: .kern)
        try c.encode(caps, forKey: .caps)
        try c.encode(ligatures, forKey: .ligatures)
        try c.encode(discretionaryLigatures, forKey: .discretionaryLigatures)
        try c.encode(features, forKey: .features)
        try c.encode(variations, forKey: .variations)
        try c.encode(language, forKey: .language)
        try c.encodeIfPresent(styleSheet, forKey: .styleSheet)
    }
}

/// A character style applied to `len` UTF-8 bytes.
public struct TextRun: Hashable, Sendable, Codable {
    public var len: Int
    public var style: CharStyle
    public init(len: Int, style: CharStyle) { self.len = len; self.style = style }

    enum CodingKeys: String, CodingKey { case len, style }

    /// `len` saturates at `Int.max` (photocraft's `usize` runs reach `u64::MAX`).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        len = try c.decodeRunLength(.len)
        style = try c.decode(CharStyle.self, forKey: .style)
    }
}

extension KeyedDecodingContainer {
    /// A run length: an `Int`, or a `UInt64` beyond `Int.max` saturated to `Int.max` (photocraft
    /// writes run lengths as `usize`).
    func decodeRunLength(_ key: Key) throws -> Int {
        if let v = try? decode(Int.self, forKey: key) { return v }
        return Int(clamping: try decode(UInt64.self, forKey: key))
    }
}

public enum TextAlign: String, CaseIterable, Hashable, Sendable, Codable {
    case left = "Left"
    case center = "Center"
    case right = "Right"
    /// Justified, last line left.
    case justifyLeft = "JustifyLeft"
    /// Justified, last line centered.
    case justifyCenter = "JustifyCenter"
    /// Justified, last line right.
    case justifyRight = "JustifyRight"
    /// Justified including the last line.
    case justifyAll = "JustifyAll"

    public var isJustified: Bool {
        switch self {
        case .justifyLeft, .justifyCenter, .justifyRight, .justifyAll: true
        default: false
        }
    }
}

public enum TextDirection: String, CaseIterable, Hashable, Sendable, Codable {
    /// From the first strong character (Unicode bidi rules).
    case auto = "Auto"
    case ltr = "Ltr"
    case rtl = "Rtl"
}

/// Paragraph style (Photoshop's Paragraph panel). Every JSON key is optional.
public struct ParagraphStyle: Hashable, Sendable, Codable {
    public var align: TextAlign = .left
    public var firstLineIndentPt: Float = 0
    public var startIndentPt: Float = 0
    public var endIndentPt: Float = 0
    public var spaceBeforePt: Float = 0
    public var spaceAfterPt: Float = 0
    /// Auto leading as a multiple of the font size (Photoshop default 1.2).
    public var autoLeading: Float = 1.2
    public var direction: TextDirection = .auto
    public var hyphenate = false
    /// Applied paragraph style (id in `TextStyles`); nil = Basic Paragraph.
    public var styleSheet: UInt32?

    public init() {}

    public init(align: TextAlign) { self.align = align }

    enum CodingKeys: String, CodingKey {
        case align, firstLineIndentPt = "first_line_indent_pt", startIndentPt = "start_indent_pt", endIndentPt = "end_indent_pt"
        case spaceBeforePt = "space_before_pt", spaceAfterPt = "space_after_pt", autoLeading = "auto_leading", direction, hyphenate
        case styleSheet = "style_sheet"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ParagraphStyle()
        align = try c.decode(.align, or: d.align)
        firstLineIndentPt = try c.decode(.firstLineIndentPt, or: d.firstLineIndentPt)
        startIndentPt = try c.decode(.startIndentPt, or: d.startIndentPt)
        endIndentPt = try c.decode(.endIndentPt, or: d.endIndentPt)
        spaceBeforePt = try c.decode(.spaceBeforePt, or: d.spaceBeforePt)
        spaceAfterPt = try c.decode(.spaceAfterPt, or: d.spaceAfterPt)
        autoLeading = try c.decode(.autoLeading, or: d.autoLeading)
        direction = try c.decode(.direction, or: d.direction)
        hyphenate = try c.decode(.hyphenate, or: d.hyphenate)
        styleSheet = try c.decodeIfPresent(UInt32.self, forKey: .styleSheet)
    }
}

/// A paragraph style applied to `len` UTF-8 bytes (whole paragraphs, including the break).
public struct ParagraphRun: Hashable, Sendable, Codable {
    public var len: Int
    public var style: ParagraphStyle
    public init(len: Int, style: ParagraphStyle) { self.len = len; self.style = style }

    enum CodingKeys: String, CodingKey { case len, style }

    /// `len` saturates at `Int.max`, as `TextRun`'s.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        len = try c.decodeRunLength(.len)
        style = try c.decode(ParagraphStyle.self, forKey: .style)
    }
}

/// Point text grows from its anchor (text-space origin = first baseline at the anchor); paragraph
/// (box) text wraps inside a rectangle. JSON: `"Point"` / `{"Box":{"x":…,"y":…,"width":…,"height":…}}`.
///
/// `path` and `area` are photocraft's later type on a path and area type (after this port's base,
/// photocraft #4365, #4377, #11629). They are decoded and written back unchanged so a photocraft
/// document opens and survives a save; the text engine does not follow the path yet: path text is
/// laid out as point text and area text in the path's bounding box (`layoutBox`).
public enum TextShape: Hashable, Sendable, Codable {
    case point
    /// Text-space pixels, before the layer transform.
    case box(TextBox)
    /// Type on a path. JSON: `{"Path":{"path":…,"start":…,"end":…?,"flip":…}}`.
    case path(OnPath)
    /// Area type: paragraph text inside the closed subpaths of `path`. JSON: `{"Area":{"path":…}}`.
    case area(Area)

    /// photocraft `TextShape::Path`: `start` is the arc-length offset (px) of the text origin along
    /// the path, `end` the unwrapped end offset (absent = unbounded), `flip` the other side.
    public struct OnPath: Hashable, Sendable, Codable {
        public var path: Subpath
        public var start: Float
        public var end: Float?
        public var flip: Bool
        public init(path: Subpath, start: Float = 0, end: Float? = nil, flip: Bool = false) {
            self.path = path; self.start = start; self.end = end; self.flip = flip
        }
    }

    /// photocraft `TextShape::Area`.
    public struct Area: Hashable, Sendable, Codable {
        public var path: VectorPath
        public init(path: VectorPath) { self.path = path }
    }

    /// The rectangle paragraph layout wraps in: the box itself, the bounding box of an area's
    /// anchors (finite ones only), or nil for point and path text.
    public var layoutBox: TextBox? {
        switch self {
        case .point, .path: return nil
        case .box(let b): return b
        case .area(let a):
            var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
            for sp in a.path.subpaths {
                for k in sp.knots where k.anchor.x.isFinite && k.anchor.y.isFinite {
                    x0 = min(x0, k.anchor.x); y0 = min(y0, k.anchor.y)
                    x1 = max(x1, k.anchor.x); y1 = max(y1, k.anchor.y)
                }
            }
            guard x0 <= x1, y0 <= y1 else { return TextBox(x: 0, y: 0, width: 0, height: 0) }
            return TextBox(x: Float(x0), y: Float(y0), width: Float(x1 - x0), height: Float(y1 - y0))
        }
    }

    /// Whether the text wraps in a region (box or area) instead of growing from an anchor.
    public var isParagraph: Bool { layoutBox != nil }

    public struct TextBox: Hashable, Sendable, Codable {
        public var x: Float, y: Float, width: Float, height: Float
        public init(x: Float, y: Float, width: Float, height: Float) { self.x = x; self.y = y; self.width = width; self.height = height }
    }

    public init(from decoder: any Decoder) throws {
        let v = try TaggedVariant(from: decoder)
        switch v.tag {
        case "Point": self = .point
        case "Box": self = .box(try v.payload())
        case "Path": self = .path(try v.payload())
        case "Area": self = .area(try v.payload())
        default: throw v.unknown()
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .point: try Tagged.unit("Point", to: encoder)
        case .box(let b): try Tagged.variant("Box", b, to: encoder)
        case .path(let p): try Tagged.variant("Path", p, to: encoder)
        case .area(let a): try Tagged.variant("Area", a, to: encoder)
        }
    }
}

/// Horizontal or vertical type (photocraft `text::Orientation`).
public enum TextOrientation: String, CaseIterable, Hashable, Sendable, Codable {
    case horizontal = "Horizontal"
    /// Vertical type (tategaki): columns top to bottom, advancing right to left.
    case vertical = "Vertical"
}

public enum AntiAlias: String, CaseIterable, Hashable, Sendable, Codable {
    case none = "None"
    case sharp = "Sharp"
    case crisp = "Crisp"
    case strong = "Strong"
    case smooth = "Smooth"
    /// Photoshop's "Windows" (platform grayscale) anti-aliasing; rendered like `sharp`.
    case windows = "Windows"
    /// Photoshop's "Windows LCD" (platform subpixel) anti-aliasing; rendered like `sharp` (we never
    /// produce colour-fringed subpixel text in document pixels).
    case windowsLcd = "WindowsLcd"
}

/// Warp Text settings (Photoshop `warp` descriptor), applied to the glyph outlines by the text
/// engine and round-tripped through PSD.
public struct TextWarp: Hashable, Sendable, Codable {
    /// `warpNone`, `warpArc`, `warpFlag`, …
    public var style: String = ""
    /// Bend in percent (-100...100).
    public var value: Float = 0
    public var horizontalDistortion: Float = 0
    public var verticalDistortion: Float = 0
    /// Horizontal (true) or vertical warp axis.
    public var horizontal = false

    public init(style: String = "", value: Float = 0, horizontalDistortion: Float = 0, verticalDistortion: Float = 0, horizontal: Bool = false) {
        self.style = style; self.value = value; self.horizontalDistortion = horizontalDistortion
        self.verticalDistortion = verticalDistortion; self.horizontal = horizontal
    }

    enum CodingKeys: String, CodingKey {
        case style, value, horizontalDistortion = "horizontal_distortion", verticalDistortion = "vertical_distortion", horizontal
    }
}

// MARK: - Text layers

/// A type layer: its text, styled runs, shape and the rendered cache.
public struct TextLayer: Equatable, Sendable {
    public var text: String = ""
    public var fontFamily: String = ""
    public var sizePt: Float = 12
    public var color: PCColor = .black
    public var transform: PCAffine = .identity
    /// Rasterized appearance (from PSD or the text engine).
    public var cache: Surface?
    /// Data of the PSD `TySh` block. On export it replaces the `TySh` entry in `Layer.psdBlocks`
    /// (the text engine updates this field when it edits text).
    public var psdRaw: [UInt8]?
    /// Character style runs. Empty = one run built from `fontFamily`, `sizePt` and `color`, which
    /// otherwise mirror the first run (summary for simple UIs).
    public var runs: [TextRun] = []
    /// Paragraph style runs. Empty = default paragraph style.
    public var paragraphs: [ParagraphRun] = []
    /// Point or paragraph (box) text.
    public var shape: TextShape = .point
    public var orientation: TextOrientation = .horizontal
    public var antialias: AntiAlias = .smooth
    /// Warp Text settings (applied to the glyph outlines when rendering).
    public var warp: TextWarp?

    public init(text: String = "", fontFamily: String = "", sizePt: Float = 12, color: PCColor = .black) {
        self.text = text; self.fontFamily = fontFamily; self.sizePt = sizePt; self.color = color
    }

    /// Character runs covering exactly `text.utf8.count` bytes, each on a character boundary.
    public func charRuns() -> [TextRun] {
        var base = CharStyle()
        base.fontFamily = fontFamily
        base.sizePt = sizePt
        base.color = color
        return normalizeRuns(text, runs.map { ($0.len, $0.style) }, base).map { TextRun(len: $0.0, style: $0.1) }
    }

    /// Paragraph runs covering exactly `text.utf8.count` bytes, with an optional zero-length final
    /// run for an empty paragraph after a trailing line break.
    public func paragraphRuns() -> [ParagraphRun] {
        var out = normalizeRuns(text, paragraphs.map { ($0.len, $0.style) }, ParagraphStyle())
        // The final empty paragraph owns the synthetic terminal paragraph marker in PSD text. Its
        // formatting has no source bytes; do not lose that last run when normalizing.
        // Bytes, not Characters: "\r\n" is one Character in Swift.
        let endsWithBreak = text.utf8.last == 0x0D || text.utf8.last == 0x0A
        if endsWithBreak, let last = paragraphs.last, last.len <= 1 {
            var total = 0
            var overflow = false
            for r in paragraphs.dropLast() {
                let (s, o) = total.addingReportingOverflow(r.len)
                if o || r.len < 0 { overflow = true; break }
                total = s
            }
            if !overflow && total == text.utf8.count { out.append((0, last.style)) }
        }
        return out.map { ParagraphRun(len: $0.0, style: $0.1) }
    }

    /// Copies the first run's family, size and colour into the summary fields.
    public mutating func syncSummary() {
        if let r = runs.first {
            fontFamily = r.style.fontFamily
            sizePt = r.style.sizePt
            color = r.style.color
        }
    }
}

/// Stretches/truncates `(len, style)` runs to cover `text` exactly, snapping to character
/// boundaries and dropping empty runs (keeps one run for empty text).
func normalizeRuns<S>(_ text: String, _ runs: [(Int, S)], _ base: S) -> [(Int, S)] {
    let bytes = Array(text.utf8)
    let total = bytes.count
    if total == 0 { return [(0, runs.first?.1 ?? base)] }
    func isBoundary(_ i: Int) -> Bool { i >= total || (bytes[i] & 0xC0) != 0x80 }
    var out: [(Int, S)] = []
    var at = 0
    for (len, style) in runs {
        if at >= total { break }
        var end = len <= 0 ? at : (len > total - at ? total : at + len)
        while !isBoundary(end) { end += 1 }
        if end > at {
            out.append((end - at, style))
            at = end
        }
    }
    if at < total {
        if out.isEmpty { out.append((total, base)) } else { out[out.count - 1].0 += total - at }
    }
    if out.isEmpty { out.append((0, base)) }
    return out
}
