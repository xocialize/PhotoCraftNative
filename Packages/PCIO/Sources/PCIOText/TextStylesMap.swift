// Character and paragraph styles ⇄ the PSD text engine's style sheets (see `PSDStyles`). Import
// merges the named sheets of every type layer into the document's `TextStyles` by name and sets
// the runs' style references; export rewrites each type layer's sheets from the document's
// styles. Files without named styles are left as they are (byte-exact).
// Port of photocraft-io (crates/io/src/text_styles_map.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.

import PCDocument

/// photocraft `photocraft_io::text_styles_map`.
public enum TextStylesMap {
    /// Builds `doc.textStyles` from the type layers' engine data and links the runs (photocraft
    /// `import`). Returns warnings.
    public static func importStyles(_ doc: inout Document) -> [String] {
        var warnings: [String] = []
        let dpi = doc.resolutionDpi
        var styles = doc.textStyles
        doc.textStyles = TextStyles()
        // Names compare by bytes, as photocraft's `HashMap<String, u32>` does.
        var charIds = Dictionary(styles.character.map { (Array($0.name.utf8), $0.id) }, uniquingKeysWith: { _, last in last })
        var paraIds = Dictionary(styles.paragraph.map { (Array($0.name.utf8), $0.id) }, uniquingKeysWith: { _, last in last })
        // Depth-first, bottom to top, parents before children: photocraft's `walk` order.
        doc.forEachLayerMut { layer in
            layer.withText { t in
                guard let raw = t.psdRaw, PSDStyles.hasNamedSheets(raw), let sh = PSDStyles.readStyleSheets(raw, dpi: dpi) else { return }
                var cmap: [Int: UInt32] = [:]
                for cs in sh.charSheets {
                    let key = Array(cs.name.utf8)
                    let id: UInt32
                    if let existing = charIds[key] {
                        id = existing
                    } else {
                        guard let fresh = styles.nextCharId else {
                            warnings.append("character style \(debugQuoted(cs.name)) was not imported: style id space exhausted")
                            continue
                        }
                        var attrs = diffAttrs(cs.style, sh.normalChar)
                        attrs["postscript_name"] = nil
                        styles.character.append(CharacterStyleDef(id: fresh, name: cs.name, attrs: attrs))
                        charIds[key] = fresh
                        id = fresh
                    }
                    cmap[cs.index] = id
                }
                var pmap: [Int: UInt32] = [:]
                for ps in sh.paraSheets {
                    let key = Array(ps.name.utf8)
                    let id: UInt32
                    if let existing = paraIds[key] {
                        id = existing
                    } else {
                        guard let fresh = styles.nextParaId else {
                            warnings.append("paragraph style \(debugQuoted(ps.name)) was not imported: style id space exhausted")
                            continue
                        }
                        var charAttrs = ps.charStyle.map { diffAttrs($0, sh.normalChar) } ?? [:]
                        charAttrs["postscript_name"] = nil
                        styles.paragraph.append(ParagraphStyleDef(id: fresh, name: ps.name, paraAttrs: diffAttrs(ps.style, sh.normalPara), charAttrs: charAttrs))
                        paraIds[key] = fresh
                        id = fresh
                    }
                    pmap[ps.index] = id
                }
                link(&t, sh.runChar, sh.runCharLens, cmap, sh.runPara, pmap)
            }
        }
        doc.textStyles = styles
        return warnings
    }

    static func link(_ t: inout TextLayer, _ runChar: [Int?], _ runCharLens: [Int], _ cmap: [Int: UInt32], _ runPara: [Int?], _ pmap: [Int: UInt32]) {
        if runCharLens.count == runChar.count && !runChar.isEmpty {
            // Each model run takes the sheet of the `StyleRun` entry its first character is in.
            var off = 0
            var i = 0
            var end = runCharLens.first ?? 0
            for r in t.runs.indices {
                while off >= end && i + 1 < runCharLens.count {
                    i += 1
                    end = satAdd(end, runCharLens[safe: i] ?? 0)
                }
                t.runs[r].style.styleSheet = (runChar[safe: i] ?? nil).flatMap { cmap[$0] }
                off = satAdd(off, max(0, t.runs[r].len))
            }
        } else if t.runs.count == runChar.count {
            for (r, ix) in zip(t.runs.indices, runChar) {
                t.runs[r].style.styleSheet = ix.flatMap { cmap[$0] }
            }
        }
        if t.paragraphs.count == runPara.count {
            for (r, ix) in zip(t.paragraphs.indices, runPara) {
                t.paragraphs[r].style.styleSheet = ix.flatMap { pmap[$0] }
            }
        }
    }

    /// The `TySh` data to write for a type layer, with its style sheets regenerated from
    /// `styles`; nil when neither the document nor the data has named styles (write as is).
    public static func exportTySh(_ data: [UInt8], _ layer: TextLayer, _ styles: TextStyles, dpi: Float) -> [UInt8]? {
        let named = !styles.character.isEmpty || !styles.paragraph.isEmpty
        if !named && !PSDStyles.hasNamedSheets(data) { return nil }
        return PSDStyles.writeStyleSheets(data, layer, styles, dpi: dpi)
    }

    /// Rust's `{:?}` of a string: quoted, with `\\`, `\"`, `\n`, `\r`, `\t`, `\0` and other control
    /// characters escaped.
    static func debugQuoted(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\0": out += "\\0"
            default:
                if c.properties.generalCategory == .control {
                    out += "\\u{" + String(c.value, radix: 16) + "}"
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        return out + "\""
    }
}
