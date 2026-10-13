// Named type styles (Photoshop's Character Styles and Paragraph Styles panels).
// Port of photocraft-doc (crates/doc/src/text_styles.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.
//
// A document owns a list of character styles (partial character attributes) and paragraph styles
// (partial paragraph and character attributes). "None" (no character style) and "Basic Paragraph"
// (the default paragraph style, which can be redefined but not deleted) are implicit.
//
// Text keeps fully resolved attributes in its runs (so layout never needs the style list). A run
// references its styles through `CharStyle.styleSheet` (character style id) and the paragraph's
// `ParagraphStyle.styleSheet` (paragraph style id, nil = Basic Paragraph). The attributes a run
// would have from its styles alone are `defaults ← Basic Paragraph ← paragraph style ← character
// style`; whatever differs from that is a local override, shown as "+" after the style name.
//
// Attribute sets are JSON objects keyed by the coding keys of `CharStyle` / `ParagraphStyle`
// (`size_pt`, `font_family`, `align`, …, the same names photocraft's serde uses), so a set can
// name any subset of the fields and new fields need no extra code.

/// A partial attribute set: coding key → JSON value.
public typealias StyleAttrs = [String: JSONValue]

/// The key that holds a run's style reference; never part of an attribute set.
let styleRefKey = "style_sheet"

/// Name of the implicit default paragraph style.
public let basicParagraphName = "Basic Paragraph"
/// Name of the implicit "no character style" entry.
public let noCharacterStyleName = "None"

/// Style structs whose attributes can be addressed as JSON attribute sets.
public protocol TextStyleAttributes: Codable {
    init()
}

extension CharStyle: TextStyleAttributes {}
extension ParagraphStyle: TextStyleAttributes {}

/// A named character style.
public struct CharacterStyleDef: Hashable, Sendable, Codable {
    /// Stable id (≥ 1), referenced by `CharStyle.styleSheet`.
    public var id: UInt32 = 0
    public var name: String = ""
    /// Character attributes this style sets (others come from the paragraph style).
    public var attrs: StyleAttrs = [:]

    public init(id: UInt32 = 0, name: String = "", attrs: StyleAttrs = [:]) { self.id = id; self.name = name; self.attrs = attrs }

    enum CodingKeys: String, CodingKey { case id, name, attrs }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(.id, or: 0)
        name = try c.decode(.name, or: "")
        attrs = try c.decode(.attrs, or: [:])
    }
}

/// A named paragraph style (or Basic Paragraph).
public struct ParagraphStyleDef: Hashable, Sendable, Codable {
    /// Stable id (≥ 1; Basic Paragraph is 0), referenced by `ParagraphStyle.styleSheet`.
    public var id: UInt32 = 0
    public var name: String = ""
    /// Paragraph attributes this style sets.
    public var paraAttrs: StyleAttrs = [:]
    /// Character attributes this style sets (the basis of every run in its paragraphs).
    public var charAttrs: StyleAttrs = [:]

    public init(id: UInt32 = 0, name: String = "", paraAttrs: StyleAttrs = [:], charAttrs: StyleAttrs = [:]) {
        self.id = id; self.name = name; self.paraAttrs = paraAttrs; self.charAttrs = charAttrs
    }

    enum CodingKeys: String, CodingKey { case id, name, paraAttrs = "para_attrs", charAttrs = "char_attrs" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(.id, or: 0)
        name = try c.decode(.name, or: "")
        paraAttrs = try c.decode(.paraAttrs, or: [:])
        charAttrs = try c.decode(.charAttrs, or: [:])
    }
}

/// Serializes a style to its JSON object (without the style reference).
func styleObject<T: Encodable>(_ s: T) -> StyleAttrs {
    guard var m = (try? JSONValue(encoding: s))?.objectValue else { return [:] }
    m[styleRefKey] = nil
    return m
}

/// `base` with `attrs` applied. Fails if an attribute is unknown or has the wrong type.
public func applyAttrs<T: Codable>(_ base: T, _ attrs: StyleAttrs) throws(DocumentError) -> T {
    if attrs.isEmpty { return base }
    guard case .object(var m)? = try? JSONValue(encoding: base) else { throw DocumentError("style is not an object") }
    for (k, x) in attrs where k != styleRefKey {
        // A nil optional is written as null, so every field is present in `m`.
        guard m.keys.contains(k) else { throw DocumentError("unknown style attribute \"\(k)\"") }
        m[k] = x
    }
    do {
        return try JSONValue.object(m).decode(as: T.self)
    } catch {
        throw DocumentError("\(error)")
    }
}

/// Attributes of `style` that differ from `base` (the style reference is ignored).
public func diffAttrs<T: Encodable>(_ style: T, _ base: T) -> StyleAttrs {
    let (a, b) = (styleObject(style), styleObject(base))
    return a.filter { k, v in b[k] != v }
}

/// Every attribute of a character style (a full set, for "redefine from text").
public func charAttrs(_ s: CharStyle) -> StyleAttrs { styleObject(s) }

/// Every attribute of a paragraph style.
public func paraAttrs(_ s: ParagraphStyle) -> StyleAttrs { styleObject(s) }

/// Checks that `attrs` only names fields of `T` with values of the right type.
public func validateAttrs<T: TextStyleAttributes>(_ attrs: StyleAttrs, for type: T.Type) throws(DocumentError) {
    _ = try applyAttrs(T(), attrs)
}

/// The document's named type styles. Every JSON key is optional.
public struct TextStyles: Hashable, Sendable, Codable {
    /// Character styles in panel order ("None" is implicit and first).
    public var character: [CharacterStyleDef] = []
    /// Paragraph styles in panel order (Basic Paragraph is `basic`, listed first).
    public var paragraph: [ParagraphStyleDef] = []
    /// Basic Paragraph (id 0). Empty attribute sets = the defaults.
    public var basic = ParagraphStyleDef(id: 0, name: basicParagraphName)
    /// Style sheets of the PSD text engine this document was read from (`ResourceDict`
    /// `StyleSheetSet` / `ParagraphSheetSet`), kept so unmapped data survives a round trip.
    public var psdRaw: JSONValue?

    public init() {}

    enum CodingKeys: String, CodingKey { case character, paragraph, basic, psdRaw = "psd_raw" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        character = try c.decode(.character, or: [])
        paragraph = try c.decode(.paragraph, or: [])
        basic = try c.decode(.basic, or: ParagraphStyleDef(id: 0, name: basicParagraphName))
        psdRaw = try c.decodeIfPresent(JSONValue.self, forKey: .psdRaw)
    }

    public var isEmpty: Bool {
        character.isEmpty && paragraph.isEmpty && basic.charAttrs.isEmpty && basic.paraAttrs.isEmpty
    }

    public func charStyle(_ id: UInt32) -> CharacterStyleDef? { character.first { $0.id == id } }

    /// Paragraph style by id (0 = Basic Paragraph).
    public func paraStyle(_ id: UInt32) -> ParagraphStyleDef? { id == 0 ? basic : paragraph.first { $0.id == id } }

    /// Read/write access to a character style by id (setting nil is ignored; use `character` to
    /// remove styles).
    public subscript(charStyle id: UInt32) -> CharacterStyleDef? {
        get { charStyle(id) }
        set {
            guard let newValue, let i = character.firstIndex(where: { $0.id == id }) else { return }
            character[i] = newValue
        }
    }

    /// Read/write access to a paragraph style by id (0 = Basic Paragraph; setting nil is ignored).
    public subscript(paraStyle id: UInt32) -> ParagraphStyleDef? {
        get { paraStyle(id) }
        set {
            guard let newValue else { return }
            if id == 0 { basic = newValue; return }
            if let i = paragraph.firstIndex(where: { $0.id == id }) { paragraph[i] = newValue }
        }
    }

    /// A fresh character style id, or nil when the stored ids exhaust the UInt32 id space.
    public var nextCharId: UInt32? {
        let m = character.map(\.id).max() ?? 0
        return m == .max ? nil : m + 1
    }

    /// A fresh paragraph style id, or nil when the stored ids exhaust the UInt32 id space.
    public var nextParaId: UInt32? {
        let m = paragraph.map(\.id).max() ?? 0
        return m == .max ? nil : m + 1
    }

    /// "Character Style N" / "Paragraph Style N" with the first unused N.
    public func uniqueName(paragraph isParagraph: Bool, base: String) -> String {
        func taken(_ n: String) -> Bool {
            isParagraph ? (n == basicParagraphName || paragraph.contains { $0.name == n })
                : (n == noCharacterStyleName || character.contains { $0.name == n })
        }
        var i = 1
        while taken("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    /// Paragraph attributes from Basic Paragraph and `para` (a missing id falls back to Basic
    /// Paragraph). The result references `para`.
    public func resolvePara(_ para: UInt32?) -> ParagraphStyle {
        var s = (try? applyAttrs(ParagraphStyle(), basic.paraAttrs)) ?? ParagraphStyle()
        if let id = para, let def = paraStyle(id) { s = (try? applyAttrs(s, def.paraAttrs)) ?? s }
        s.styleSheet = para.flatMap { $0 != 0 && paraStyle($0) != nil ? $0 : nil }
        return s
    }

    /// Character attributes a run gets from its styles alone: defaults (with `defaultFamily` for an
    /// unset family) ← Basic Paragraph ← paragraph style ← character style. The result references
    /// `chr`.
    public func resolveChar(para: UInt32?, chr: UInt32?, defaultFamily: String) -> CharStyle {
        var base = CharStyle()
        base.fontFamily = defaultFamily
        var s = (try? applyAttrs(base, basic.charAttrs)) ?? base
        if let id = para, let def = paraStyle(id), def.id != 0 { s = (try? applyAttrs(s, def.charAttrs)) ?? s }
        let chr = chr.flatMap { charStyle($0) != nil ? $0 : nil }
        if let id = chr, let def = charStyle(id) { s = (try? applyAttrs(s, def.attrs)) ?? s }
        s.styleSheet = chr
        return s
    }

    /// The local overrides of a run (attributes that differ from its styles).
    public func charOverrides(_ run: CharStyle, para: UInt32?, defaultFamily: String) -> StyleAttrs {
        diffAttrs(run, resolveChar(para: para, chr: run.styleSheet, defaultFamily: defaultFamily))
    }

    /// The local overrides of a paragraph.
    public func paraOverrides(_ p: ParagraphStyle) -> StyleAttrs { diffAttrs(p, resolvePara(p.styleSheet)) }

    /// Re-resolves a run against (possibly changed) styles, keeping its overrides: `old` gives the
    /// styles as they were when the overrides were made.
    public func restyleChar(old: TextStyles, run: CharStyle, oldPara: UInt32?, newPara: UInt32?, newChr: UInt32?, family: String) -> CharStyle {
        let overrides = old.charOverrides(run, para: oldPara, defaultFamily: family)
        let base = resolveChar(para: newPara, chr: newChr, defaultFamily: family)
        return (try? applyAttrs(base, overrides)) ?? base
    }

    /// Re-resolves a paragraph against (possibly changed) styles, keeping its overrides.
    public func restylePara(old: TextStyles, _ p: ParagraphStyle, newPara: UInt32?) -> ParagraphStyle {
        let overrides = old.paraOverrides(p)
        let base = resolvePara(newPara)
        var s = (try? applyAttrs(base, overrides)) ?? base
        s.styleSheet = newPara.flatMap { $0 != 0 && paraStyle($0) != nil ? $0 : nil }
        return s
    }
}
