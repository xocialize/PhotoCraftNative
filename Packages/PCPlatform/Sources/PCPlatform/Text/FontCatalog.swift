// Fonts: enumeration, PostScript-name ⇄ family/style matching (what PSD text needs), variable-font
// axes, in-memory font registration, and the CTFont a character style resolves to.
// Replaces photocraft-text's font database (crates/text/src/fonts.rs: bundled + scanned system fonts
// through fontique/skrifa, `resolve_postscript`, `guess_from_postscript`) with CoreText's font
// manager. Port of its API shape, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreText
import Foundation
import PCDocument
import Synchronization

/// One installed (or registered) face (photocraft `FaceInfo`).
public struct FontFace: Sendable, Hashable {
    public var postScriptName: String
    public var family: String
    public var style: String
    public var displayName: String
    /// CSS weight 100–900 (from the OS/2 table when present).
    public var weight: Int
    public var italic: Bool
    public var isMonospace: Bool
    public var isVariable: Bool
}

/// A variable-font axis.
public struct VariationAxis: Sendable, Equatable {
    public var tag: String
    public var name: String
    public var minimum: Double
    public var defaultValue: Double
    public var maximum: Double
}

/// How a PSD's PostScript name resolved (photocraft `ResolvedFont`).
public struct ResolvedFont: Sendable, Equatable {
    public var face: FontFace
    /// The exact face named by the PostScript name is available.
    public var exact: Bool
    /// The family/weight/italic photocraft's guess derived from the name.
    public var guessedFamily: String
    public var guessedWeight: Int
    public var guessedItalic: Bool
}

public enum FontCatalog {
    /// Used when a style names no family or one that is not installed (photocraft uses its bundled
    /// Inter; macOS always has Helvetica Neue).
    public static let defaultFamily = "Helvetica Neue"

    /// An immutable CTFontDescriptor (CoreText descriptors are immutable and thread-safe).
    final class Descriptor: @unchecked Sendable {
        let d: CTFontDescriptor
        init(_ d: CTFontDescriptor) { self.d = d }
    }

    /// A CTFont shared between threads (CoreText fonts are immutable and thread-safe).
    final class SharedFont: @unchecked Sendable {
        let font: CTFont
        init(_ font: CTFont) { self.font = font }
    }

    private static let registered = Mutex<[String: Descriptor]>([:])

    // MARK: Caches

    /// What the installed fonts resolve to. CoreText answers family and face queries through the
    /// font registry daemon over XPC — measured 36 µs a `resolveFace` (Release), asked for every
    /// character, with concurrent callers queueing at the daemon — so everything derived from it is
    /// kept here: faces per family, faces and descriptors per PostScript name, the face per
    /// character style, CTFonts per instance, OpenType features and vertical alternates per face.
    /// A lookup holds the mutex only to read the table; a miss is computed under `registryLock`, so
    /// the registry sees one query at a time and concurrent readers of warm entries never wait on
    /// it. Registering fonts here, or the system's registered fonts changing, clears everything.
    struct Caches {
        var generation = 0
        var families: [Bool: [String]] = [:]
        var faces: [String: [FontFace]] = [:]
        var faceByName: [String: FontFace?] = [:]
        var resolved: [StyleKey: FontFace] = [:]
        var descriptors: [String: Descriptor] = [:]
        var fonts: [FontKey: SharedFont] = [:]
        var features: [String: Set<String>] = [:]
        var verticalAlternates: [String: Bool] = [:]
    }

    /// The fields of a character style that pick its face.
    struct StyleKey: Hashable, Sendable {
        var postscriptName: String?
        var family: String
        var style: String
        var weight: UInt16
        var italic: Bool
    }

    /// One CTFont instance: face, size, font matrix and variation coordinates.
    struct FontKey: Hashable, Sendable {
        var postScriptName: String
        var size: CGFloat
        var matrix: [CGFloat]
        var variations: [PCDocument.FontVariation]
    }

    private static let caches = Mutex(Caches())
    /// Serialises cache misses: the queries that reach the font registry (recursive, since a miss
    /// for a style resolves its family's faces).
    private static let registryLock = NSRecursiveLock()

    /// Clears the caches when the system's registered fonts change (fonts installed or removed
    /// while the process runs).
    final class FontsChangedObserver: @unchecked Sendable {
        let token: any NSObjectProtocol
        init() {
            token = NotificationCenter.default.addObserver(forName: Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String),
                                                           object: nil, queue: nil) { _ in FontCatalog.invalidateCaches() }
        }
    }

    private static let observer = FontsChangedObserver()

    /// Drops every cached face, descriptor and font (done automatically when fonts are registered
    /// here or the system's set changes).
    public static func invalidateCaches() {
        caches.withLock { c in
            let g = c.generation &+ 1
            c = Caches()
            c.generation = g
        }
    }

    /// The cached value for `key` in `table`, or `make()`'s, stored unless the caches were cleared
    /// meanwhile. Tables are bounded: one that reaches `limit` entries starts again.
    static func cached<K: Hashable & Sendable, V: Sendable>(_ table: WritableKeyPath<Caches, [K: V]>, _ key: K, limit: Int = 4096, _ make: () -> V) -> V {
        _ = observer
        if let hit = caches.withLock({ $0[keyPath: table][key] }) { return hit }
        registryLock.lock()
        defer { registryLock.unlock() }
        // Another thread may have filled it while this one waited.
        let (hit, generation) = caches.withLock { ($0[keyPath: table][key], $0.generation) }
        if let hit { return hit }
        let value = make()
        caches.withLock { c in
            guard c.generation == generation else { return }
            if c[keyPath: table].count >= limit { c[keyPath: table].removeAll() }
            c[keyPath: table][key] = value
        }
        return value
    }

    /// Every installed family (photocraft `FontDb::families`).
    public static func families() -> [String] {
        cached(\.families, true) {
            let fam = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
            let reg = registered.withLock { $0.values.compactMap { CTFontDescriptorCopyAttribute($0.d, kCTFontFamilyNameAttribute) as? String } }
            return Array(Set(fam + reg)).filter { !$0.hasPrefix(".") }.sorted()
        }
    }

    /// The faces of a family (photocraft `FontDb::faces`).
    public static func faces(family: String) -> [FontFace] {
        cached(\.faces, family) { uncachedFaces(family: family) }
    }

    static func uncachedFaces(family: String) -> [FontFace] {
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        var out = ((CTFontDescriptorCreateMatchingFontDescriptors(desc, Set([kCTFontFamilyNameAttribute as String]) as CFSet) as? [CTFontDescriptor]) ?? []).map { face(of: $0) }
        let descs = registered.withLock { Array($0.values) }
        out += descs.map { face(of: $0.d) }.filter { $0.family == family }
        var seen = Set<String>()
        return out.filter { seen.insert($0.postScriptName).inserted }.sorted { ($0.weight, $0.italic ? 1 : 0) < ($1.weight, $1.italic ? 1 : 0) }
    }

    static func face(of d: CTFontDescriptor) -> FontFace {
        let font = CTFontCreateWithFontDescriptor(d, 12, nil)
        return face(of: font)
    }

    static func face(of font: CTFont) -> FontFace {
        let ps = CTFontCopyPostScriptName(font) as String
        let fam = CTFontCopyFamilyName(font) as String
        let style = (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? ""
        let display = CTFontCopyFullName(font) as String
        let traits = CTFontGetSymbolicTraits(font)
        let axes = (CTFontCopyVariationAxes(font) as? [[String: Any]]) ?? []
        return FontFace(postScriptName: ps, family: fam, style: style, displayName: display, weight: cssWeight(font),
                        italic: traits.contains(.traitItalic), isMonospace: traits.contains(.traitMonoSpace), isVariable: !axes.isEmpty)
    }

    /// CSS weight: OS/2 `usWeightClass`, else the CoreText weight trait mapped onto 100–900.
    static func cssWeight(_ font: CTFont) -> Int {
        if let os2 = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?, os2.count >= 6 {
            let w = Int(os2[4]) << 8 | Int(os2[5])
            if (1...1000).contains(w) { return w }
        }
        let traits = CTFontCopyTraits(font) as? [String: Any]
        let t = (traits?[kCTFontWeightTrait as String] as? Double) ?? 0
        let table: [(Double, Int)] = [(-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500), (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 900)]
        return table.min { abs($0.0 - t) < abs($1.0 - t) }!.1
    }

    /// The face with exactly this PostScript name, if installed or registered.
    public static func face(postScriptName ps: String) -> FontFace? {
        cached(\.faceByName, ps) {
            if let d = registered.withLock({ $0[ps] }) { return face(of: d.d) }
            let f = CTFontCreateWithName(ps as CFString, 12, nil)
            return (CTFontCopyPostScriptName(f) as String) == ps ? face(of: f) : nil
        }
    }

    /// The closest face of `family` to `weight`/`italic` (photocraft's family matching).
    public static func match(family: String, weight: Int = 400, italic: Bool = false) -> FontFace? {
        let fs = faces(family: family)
        guard !fs.isEmpty else { return nil }
        return fs.min { a, b in
            let ka = (a.italic == italic ? 0 : 1000) + abs(a.weight - weight), kb = (b.italic == italic ? 0 : 1000) + abs(b.weight - weight)
            return ka < kb
        }
    }

    /// A family's face by its style name ("Bold Italic"; photocraft `named_face`).
    public static func named(family: String, style: String) -> FontFace? {
        faces(family: family).first { $0.style.caseInsensitiveCompare(style) == .orderedSame }
    }

    /// Resolves a PSD PostScript name (photocraft `resolve_postscript`): the exact face, else the
    /// best face of the family guessed from the name, else the default family.
    public static func resolve(postScriptName ps: String) -> ResolvedFont {
        let g = guess(postScriptName: ps)
        if let f = face(postScriptName: ps) {
            return ResolvedFont(face: f, exact: true, guessedFamily: g.family, guessedWeight: g.weight, guessedItalic: g.italic)
        }
        let f = match(family: g.family, weight: g.weight, italic: g.italic)
            ?? match(family: defaultFamily, weight: g.weight, italic: g.italic)!
        return ResolvedFont(face: f, exact: false, guessedFamily: g.family, guessedWeight: g.weight, guessedItalic: g.italic)
    }

    /// Family, weight and italic guessed from a PostScript name (port of photocraft
    /// `guess_from_postscript`): "TimesNewRomanPS-BoldItalicMT" → ("Times New Roman", 700, true).
    public static func guess(postScriptName ps: String) -> (family: String, weight: Int, italic: Bool) {
        let parts = ps.split(separator: "-", maxSplits: 1).map(String.init)
        let famPart = parts.first ?? ps, style = parts.count > 1 ? parts[1] : ""
        var fam = famPart
        for suffix in ["MT", "PS", "Std", "Pro"] where fam.hasSuffix(suffix) { fam.removeLast(suffix.count) }
        for suffix in ["MT", "PS", "Std", "Pro"] where fam.hasSuffix(suffix) { fam.removeLast(suffix.count) }
        let tail = famPart.hasSuffix("Pro") ? " Pro" : (famPart.hasSuffix("Std") ? " Std" : "")
        var family = ""
        let chars = Array(fam)
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase, chars[i - 1].isLowercase || (i + 1 < chars.count && chars[i + 1].isLowercase && chars[i - 1].isUppercase) {
                family.append(" ")
            }
            family.append(c)
        }
        family += tail
        let s = style.lowercased()
        let weight: Int
        if s.contains("thin") || s.contains("hairline") { weight = 100 }
        else if s.contains("extralight") || s.contains("ultralight") { weight = 200 }
        else if s.contains("light") { weight = 300 }
        else if s.contains("medium") { weight = 500 }
        else if s.contains("semibold") || s.contains("demibold") || s.contains("demi") { weight = 600 }
        else if s.contains("extrabold") || s.contains("ultrabold") || s.contains("heavy") { weight = 800 }
        else if s.contains("black") { weight = 900 }
        else if s.contains("bold") { weight = 700 }
        else { weight = 400 }
        let italic = s.contains("italic") || s.contains("oblique") || s.hasSuffix("it")
        return (family, weight, italic)
    }

    /// A font's variation axes (photocraft's variable-font support).
    public static func variationAxes(postScriptName ps: String) -> [VariationAxis] {
        let font = ctFont(postScriptName: ps, size: 12)
        let axes = (CTFontCopyVariationAxes(font) as? [[String: Any]]) ?? []
        return axes.map { a in
            let id = (a[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value ?? 0
            return VariationAxis(tag: fourCC(id), name: a[kCTFontVariationAxisNameKey as String] as? String ?? "",
                                 minimum: a[kCTFontVariationAxisMinimumValueKey as String] as? Double ?? 0,
                                 defaultValue: a[kCTFontVariationAxisDefaultValueKey as String] as? Double ?? 0,
                                 maximum: a[kCTFontVariationAxisMaximumValueKey as String] as? Double ?? 0)
        }
    }

    static func fourCC(_ v: UInt32) -> String {
        String(decoding: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)], as: UTF8.self)
    }

    static func tagValue(_ s: String) -> UInt32 {
        Array(s.utf8.prefix(4)).reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Registers font data for this process (TrueType, OpenType, collections; photocraft
    /// `register_font_data`). Returns the PostScript names added.
    @discardableResult
    public static func register(fontData: Data) -> [String] {
        guard let ds = CTFontManagerCreateFontDescriptorsFromData(fontData as CFData) as? [CTFontDescriptor] else { return [] }
        let boxed = ds.map { (CTFontCopyPostScriptName(CTFontCreateWithFontDescriptor($0, 12, nil)) as String, Descriptor($0)) }
        registered.withLock { reg in for (ps, d) in boxed { reg[ps] = d } }
        invalidateCaches()
        return boxed.map(\.0)
    }

    /// The CTFont for a PostScript name (registered faces first), from its cached descriptor.
    static func ctFont(postScriptName ps: String, size: CGFloat, matrix: CGAffineTransform? = nil) -> CTFont {
        var m = matrix ?? .identity
        let d = cached(\.descriptors, ps) {
            registered.withLock { $0[ps] } ?? Descriptor(CTFontCopyFontDescriptor(CTFontCreateWithName(ps as CFString, 12, nil)))
        }
        return CTFontCreateWithFontDescriptor(d.d, size, &m)
    }

    /// The face a document character style resolves to: its PostScript name when installed, else
    /// the face photocraft's guess of that name picks, else the family's named style, else the
    /// family at the style's weight/italic, else the default family. Cached per style.
    public static func resolveFace(_ s: CharStyle) -> FontFace {
        cached(\.resolved, StyleKey(postscriptName: s.postscriptName, family: s.fontFamily, style: s.fontStyle, weight: s.weight, italic: s.italic)) {
            if let ps = s.postscriptName, let f = face(postScriptName: ps) { return f }
            if let ps = s.postscriptName { return resolve(postScriptName: ps).face }
            let fam = s.fontFamily.isEmpty ? defaultFamily : s.fontFamily
            if !s.fontStyle.isEmpty, let f = named(family: fam, style: s.fontStyle) { return f }
            return match(family: fam, weight: Int(s.weight), italic: s.italic) ?? match(family: defaultFamily, weight: Int(s.weight), italic: s.italic)!
        }
    }

    /// The CTFont for a style at `sizePx`, with variation axes, faux italic (12° skew, photocraft
    /// `FAUX_ITALIC_DEG`; also used when italic is asked of a face that has none) and
    /// horizontal/vertical scale in the font matrix. Cached per instance.
    public static func ctFont(for s: CharStyle, sizePx: CGFloat) -> CTFont {
        let face = resolveFace(s)
        var matrix = CGAffineTransform(scaleX: CGFloat(s.horizontalScale), y: CGFloat(s.verticalScale))
        if s.fauxItalic || (s.italic && !face.italic) {
            matrix = matrix.concatenating(CGAffineTransform(a: 1, b: 0, c: tan(12 * .pi / 180), d: 1, tx: 0, ty: 0))
        }
        let key = FontKey(postScriptName: face.postScriptName, size: sizePx, matrix: [matrix.a, matrix.b, matrix.c, matrix.d], variations: s.variations)
        return cached(\.fonts, key, limit: 1024) {
            var font = ctFont(postScriptName: face.postScriptName, size: sizePx, matrix: matrix)
            if !s.variations.isEmpty {
                var vars: [NSNumber: NSNumber] = [:]
                for v in s.variations { vars[NSNumber(value: tagValue(v.axis))] = NSNumber(value: v.value) }
                let d = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(font), [kCTFontVariationAttribute: vars] as CFDictionary)
                font = CTFontCreateWithFontDescriptor(d, sizePx, &matrix)
            }
            return SharedFont(font)
        }.font
    }

    /// Whether the face has an OpenType feature (e.g. `smcp`); cached per face.
    static func hasFeature(_ font: CTFont, _ tag: String) -> Bool {
        cached(\.features, CTFontCopyPostScriptName(font) as String) {
            guard let feats = CTFontCopyFeatures(font) as? [[String: Any]] else { return [] }
            // CoreText lists AAT features; OpenType tags appear as kCTFontOpenTypeFeatureTag entries.
            var tags = Set<String>()
            for f in feats {
                if let t = f[kCTFontOpenTypeFeatureTag as String] as? String { tags.insert(t) }
                for sel in (f[kCTFontFeatureTypeSelectorsKey as String] as? [[String: Any]]) ?? [] {
                    if let t = sel[kCTFontOpenTypeFeatureTag as String] as? String { tags.insert(t) }
                }
            }
            return tags
        }.contains(tag)
    }

    /// Whether vertical forms give `character` its own glyph in `font` or the fallback font CoreText
    /// picks for it (photocraft's `vert` alternate test for brackets, dashes and the long-vowel
    /// mark); cached per face and character.
    static func hasVerticalAlternate(_ font: CTFont, _ character: String) -> Bool {
        cached(\.verticalAlternates, (CTFontCopyPostScriptName(font) as String) + "\u{0}" + character) {
            func glyph(_ vertical: Bool) -> (String, CGGlyph)? {
                var a: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
                if vertical { a[NSAttributedString.Key(kCTVerticalFormsAttributeName as String)] = true }
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: character, attributes: a))
                guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first, CTRunGetGlyphCount(run) > 0 else { return nil }
                var g: CGGlyph = 0
                CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &g)
                let f = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
                return (CTFontCopyPostScriptName(f) as String, g)
            }
            guard let h = glyph(false), let v = glyph(true) else { return false }
            return h.0 == v.0 && h.1 != v.1
        }
    }
}
