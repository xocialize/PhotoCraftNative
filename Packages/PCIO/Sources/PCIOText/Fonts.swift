// The two pieces of photocraft's font database that PSD type mapping needs: the default family
// and the PostScript-name heuristic.
// Port of photocraft-text (crates/text/src/fonts.rs: `DEFAULT_FAMILY`, `ResolvedFont`,
// `guess_from_postscript`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Font lookup itself (the database, system fonts) belongs to the CoreText layer (PCPlatform).

/// Family used when a style names no family or an unknown one.
let defaultFamily = "Inter"

/// Result of a PostScript-name lookup.
struct ResolvedFont: Equatable {
    var family: String
    var weight: UInt16
    var italic: Bool
    /// True when the exact face was found; false for a heuristic family guess.
    var exact: Bool
}

/// Heuristic PostScript-name split: `MyriadPro-BoldIt` → ("Myriad Pro", 700, italic).
func guessFromPostscript(_ ps: String) -> ResolvedFont {
    let scalars = Array(ps.unicodeScalars)
    let dash = scalars.firstIndex(of: "-")
    let fam0 = dash.map { String(String.UnicodeScalarView(scalars[..<$0])) } ?? ps
    let style = dash.map { String(String.UnicodeScalarView(scalars[($0 + 1)...])) } ?? ""
    var fam = fam0
    for suffix in ["MT", "PS", "Std", "Pro"] {
        // `trim_end_matches`: every repetition of the suffix.
        while endsWith(fam, suffix) {
            fam = String(decoding: Array(fam.utf8).dropLast(suffix.utf8.count), as: UTF8.self)
        }
    }
    let pro = fam0
    let suffix = endsWith(pro, "Pro") ? " Pro" : endsWith(pro, "Std") ? " Std" : ""
    // Split camel case: "TimesNewRoman" → "Times New Roman".
    var family = String.UnicodeScalarView()
    let chars = Array(fam.unicodeScalars)
    for (i, c) in chars.enumerated() {
        if i > 0, c.properties.isUppercase,
           chars[i - 1].properties.isLowercase || (i + 1 < chars.count && chars[i + 1].properties.isLowercase) && chars[i - 1].properties.isUppercase {
            family.append(" ")
        }
        family.append(c)
    }
    family.append(contentsOf: suffix.unicodeScalars)
    let s = style.lowercased()
    let has = { (n: String) in containsBytes(s, n) }
    let weight: UInt16 =
        if has("thin") || has("hairline") { 100 }
        else if has("extralight") || has("ultralight") { 200 }
        else if has("light") { 300 }
        else if has("medium") { 500 }
        else if has("semibold") || has("demibold") || has("demi") { 600 }
        else if has("extrabold") || has("ultrabold") || has("heavy") { 800 }
        else if has("black") { 900 }
        else if has("bold") { 700 }
        else { 400 }
    let italic = has("italic") || endsWith(s, "it") || has("oblique")
    return ResolvedFont(family: trimmedWhitespace(String(family)), weight: weight, italic: italic, exact: false)
}
