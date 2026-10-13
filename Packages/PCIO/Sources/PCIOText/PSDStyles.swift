// Named character and paragraph styles in the PSD text engine data.
// Port of photocraft-text (crates/text/src/psd_styles.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.
//
// Every type layer's `EngineData` carries the document's style sheets in its `ResourceDict` (and
// `DocumentResources`): `StyleSheetSet` (character style sheets: `Name`, `StyleSheetData`) and
// `ParagraphSheetSet` (`Name`, `DefaultStyleSheet`, `Properties`), with `TheNormalStyleSheet` /
// `TheNormalParagraphSheet` naming the defaults. Runs refer to a sheet from their `StyleSheet` /
// `ParagraphSheet` dictionaries.
//
// How Photoshop links a run to a named sheet isn't in Adobe's published PSD spec. We read both a
// `Parent` index and a `Name` on the run's sheet, and write `Parent` (plus the run's fully
// resolved attributes, so the text looks the same whatever a reader makes of the reference).
// Named sheets are written with fully resolved attributes too. Unverified against Photoshop.

import Foundation
import PCDocument
import PCPSD

/// photocraft `photocraft_text::psd_styles`.
public enum PSDStyles {
    /// A named character sheet: its index in `StyleSheetSet`, name and resolved style.
    public struct CharSheet: Equatable, Sendable {
        public var index: Int
        public var name: String
        public var style: CharStyle
        public init(index: Int, name: String, style: CharStyle) {
            self.index = index
            self.name = name
            self.style = style
        }
    }

    /// A named paragraph sheet: its index in `ParagraphSheetSet`, name, paragraph style, and the
    /// character style of its `DefaultStyleSheet` when that isn't the normal sheet.
    public struct ParaSheet: Equatable, Sendable {
        public var index: Int
        public var name: String
        public var style: ParagraphStyle
        public var charStyle: CharStyle?
        public init(index: Int, name: String, style: ParagraphStyle, charStyle: CharStyle?) {
            self.index = index
            self.name = name
            self.style = style
            self.charStyle = charStyle
        }
    }

    /// Style sheets read from one type layer (photocraft `PsdStyleSheets`).
    public struct StyleSheets: Equatable, Sendable {
        /// The default ("Normal") character sheet, resolved.
        public var normalChar = CharStyle()
        public var normalPara = ParagraphStyle()
        /// Named character sheets other than the normal one.
        public var charSheets: [CharSheet] = []
        /// Named paragraph sheets other than the normal one.
        public var paraSheets: [ParaSheet] = []
        /// Per `StyleRun` entry: the character sheet index it refers to, if any.
        public var runChar: [Int?] = []
        /// Per `StyleRun` entry: its length in UTF-8 bytes of the layer text (entries don't map
        /// one to one to model runs: kerning moves pair data between characters).
        public var runCharLens: [Int] = []
        /// Per `ParagraphRun` entry: the paragraph sheet index it refers to, if any.
        public var runPara: [Int?] = []
        public init() {}
    }

    static func kOf(_ dpi: Float) -> Float { 72 / (dpi > 0 ? dpi : 72) }

    static func names(_ set: PSDEngineData?) -> [String] {
        set?.arr?.map { $0.get("Name")?.str ?? "" } ?? []
    }

    /// Index a run's sheet dictionary refers to (`Parent` index, else `Name`), skipping `normal`.
    static func reference(_ sheet: PSDEngineData?, _ setNames: [String], _ normal: Int) -> Int? {
        guard let s = sheet else { return nil }
        let i: Int
        if let p = s.get("Parent")?.i64 {
            i = usizeIndex(p)
        } else {
            guard let n = s.get("Name")?.str, let pos = setNames.firstIndex(where: { same($0, n) }) else { return nil }
            i = pos
        }
        return i != normal && i < setNames.count ? i : nil
    }

    /// Adds to `sheet[key]` (a dictionary) every entry of `resolved` it lacks; existing entries win.
    static func fillMissing(_ sheet: inout PSDEngineData, _ key: String, _ resolved: PSDEngineData) {
        guard case let .dict(all) = resolved else { return }
        if sheet.get(key) == nil { sheet.put(key, .emptyDict) }
        guard case var .dict(have)? = sheet.get(key) else { return }
        for entry in all where !have.contains(where: { same($0.key, entry.key) }) {
            have.append(entry)
        }
        sheet.put(key, .dict(have))
    }

    /// Reads the style sheets of a `TySh` block. nil when it has no engine data.
    public static func readStyleSheets(_ tysh: [UInt8], dpi: Float) -> StyleSheets? {
        guard let t = PSDText.parseTySh(tysh), let e = PSDText.engineData(t.text) else { return nil }
        let k = kOf(dpi)
        guard let res = e.get("ResourceDict") ?? e.get("DocumentResources") else { return nil }
        let fonts = names(res.get("FontSet"))
        let sset = res.get("StyleSheetSet")?.arr ?? []
        let pset = res.get("ParagraphSheetSet")?.arr ?? []
        let normalC = usizeIndex(res.get("TheNormalStyleSheet")?.i64 ?? 0)
        let normalP = usizeIndex(res.get("TheNormalParagraphSheet")?.i64 ?? 0)
        let empty = E.emptyDict
        let baseData = sset[safe: normalC]?.get("StyleSheetData")
        let baseProps = pset[safe: normalP]?.get("Properties")
        var out = StyleSheets()
        out.normalChar = PSDText.charStyle(nil, baseData ?? empty, fonts, k)
        out.normalPara = PSDText.paraStyle(nil, baseProps ?? empty, k)
        for (i, s) in sset.enumerated() where i != normalC {
            let name = s.get("Name")?.str ?? ""
            let data = s.get("StyleSheetData") ?? empty
            out.charSheets.append(CharSheet(index: i, name: name, style: PSDText.charStyle(baseData, data, fonts, k)))
        }
        for (i, s) in pset.enumerated() where i != normalP {
            let name = s.get("Name")?.str ?? ""
            let props = s.get("Properties") ?? empty
            var dss = s.get("DefaultStyleSheet")?.i64.map(usizeIndex)
            if dss == normalC { dss = nil }
            let cs = dss.flatMap { sset[safe: $0] }.map { PSDText.charStyle(baseData, $0.get("StyleSheetData") ?? empty, fonts, k) }
            out.paraSheets.append(ParaSheet(index: i, name: name, style: PSDText.paraStyle(baseProps, props, k), charStyle: cs))
        }
        let snames = names(res.get("StyleSheetSet"))
        let pnames = names(res.get("ParagraphSheetSet"))
        if let a = e.at("EngineDict", "StyleRun", "RunArray")?.arr {
            out.runChar = a.map { reference($0.get("StyleSheet"), snames, normalC) }
            let edText = e.at("EngineDict", "Editor", "Text")?.str ?? ""
            out.runCharLens = PSDText.utf16ToByteLengths(edText, arrF(e.at("EngineDict", "StyleRun", "RunLengthArray")))
        }
        if let a = e.at("EngineDict", "ParagraphRun", "RunArray")?.arr {
            out.runPara = a.map { reference($0.get("ParagraphSheet"), pnames, normalP) }
        }
        return out
    }

    /// Whether a `TySh` block carries named sheets beyond the normal ones.
    public static func hasNamedSheets(_ tysh: [UInt8]) -> Bool {
        guard let e = PSDText.parseTySh(tysh).flatMap({ PSDText.engineData($0.text) }), let res = e.get("ResourceDict") else { return false }
        func n(_ k: String) -> Int { res.get(k)?.arr?.count ?? 0 }
        return n("StyleSheetSet") > 1 || n("ParagraphSheetSet") > 1
    }

    /// Rewrites the style sheets of a `TySh` block from the document's styles and the layer's run
    /// references. The normal sheets are kept; other sheets are replaced by `styles`.
    public static func writeStyleSheets(_ tysh: [UInt8], _ layer: TextLayer, _ styles: TextStyles, dpi: Float) -> [UInt8]? {
        guard var t = PSDText.parseTySh(tysh), var e = PSDText.engineData(t.text) else { return nil }
        let k = kOf(dpi)
        for key in ["ResourceDict", "DocumentResources"] {
            guard var rd = e.get(key) else { continue }
            var fonts = names(rd.get("FontSet"))
            let normalC = usizeIndex(rd.get("TheNormalStyleSheet")?.i64 ?? 0)
            let normalP = usizeIndex(rd.get("TheNormalParagraphSheet")?.i64 ?? 0)
            let keepC = rd.get("StyleSheetSet")?.arr.flatMap { $0[safe: normalC] ?? $0.first }
            let keepP = rd.get("ParagraphSheetSet")?.arr.flatMap { $0[safe: normalP] ?? $0.first }
            func fontIndex(_ s: CharStyle) -> Int {
                let ps = PSDText.postscriptFor(s)
                if let i = fonts.firstIndex(where: { same($0, ps) }) { return i }
                fonts.append(ps)
                return fonts.count - 1
            }
            var sset: [E] = keepC.map { [$0] } ?? []
            for d in styles.character {
                let st = styles.resolveChar(para: nil, chr: d.id, defaultFamily: defaultFamily)
                let fi = fontIndex(st)
                sset.append(.d([("Name", .string(d.name)), ("Parent", .int(0)), ("StyleSheetData", PSDText.styleSheetData(st, fi, k))]))
            }
            var pset: [E] = keepP.map { [$0] } ?? []
            for d in styles.paragraph {
                let p = styles.resolvePara(d.id)
                pset.append(.d([
                    ("Name", .string(d.name)),
                    ("DefaultStyleSheet", .int(0)),
                    ("Parent", .int(0)),
                    ("Properties", PSDText.paragraphProperties(p, k)),
                ]))
            }
            rd.put("StyleSheetSet", .array(sset))
            rd.put("ParagraphSheetSet", .array(pset))
            rd.put("TheNormalStyleSheet", .int(0))
            rd.put("TheNormalParagraphSheet", .int(0))
            rd.put("FontSet", .array(fonts.map(PSDText.fontEntry)))
            e.put(key, rd)
        }
        let charFonts = (e.at("ResourceDict", "FontSet") ?? e.at("DocumentResources", "FontSet")).map { names($0) } ?? []
        func charIx(_ id: UInt32?) -> Int64? {
            id.flatMap { id in styles.character.firstIndex { $0.id == id } }.map { Int64($0) + 1 }
        }
        func paraIx(_ id: UInt32?) -> Int64? {
            id.flatMap { id in styles.paragraph.firstIndex { $0.id == id } }.map { Int64($0) + 1 }
        }
        let runs = layer.charRuns()
        // Each entry lies inside one model run: find it by the entry's start offset.
        let edText = e.at("EngineDict", "Editor", "Text")?.str ?? ""
        let entryLens = PSDText.utf16ToByteLengths(edText, arrF(e.at("EngineDict", "StyleRun", "RunLengthArray")))
        func runAt(_ off: Int) -> TextRun? {
            var end = 0
            for r in runs {
                end = satAdd(end, r.len)
                if off < end { return r }
            }
            return runs.last
        }
        e.update("EngineDict") { dict in
            dict.update("StyleRun") { sr in
                sr.update("RunArray") { arr in
                    guard case var .array(a) = arr else { return }
                    var off = 0
                    for i in a.indices {
                        let start = off
                        off = satAdd(off, entryLens[safe: i] ?? 0)
                        a[i].update("StyleSheet") { sheet in
                            sheet.removeAll("Parent")
                            sheet.removeAll("Name")
                            let run = runAt(start)
                            if let ix = charIx(run?.style.styleSheet) { sheet.put("Parent", .int(ix)) }
                            // The run's reference may be dropped or renumbered: write what it
                            // inherited too, so it keeps its look whatever sheet it now points
                            // to (#3795).
                            if let run {
                                let ps = PSDText.postscriptFor(run.style)
                                let fi = charFonts.firstIndex { same($0, ps) } ?? 0
                                fillMissing(&sheet, "StyleSheetData", PSDText.styleSheetData(run.style, fi, k))
                            }
                        }
                    }
                    arr = .array(a)
                }
            }
        }
        let paras = layer.paragraphRuns()
        e.update("EngineDict") { dict in
            dict.update("ParagraphRun") { pr in
                pr.update("RunArray") { arr in
                    guard case var .array(a) = arr else { return }
                    for i in a.indices {
                        a[i].update("ParagraphSheet") { sheet in
                            sheet.removeAll("Parent")
                            sheet.removeAll("Name")
                            if let ix = paraIx(paras[safe: i]?.style.styleSheet) { sheet.put("Parent", .int(ix)) }
                            if let p = paras[safe: i] {
                                fillMissing(&sheet, "Properties", PSDText.paragraphProperties(p.style, k))
                            }
                        }
                    }
                    arr = .array(a)
                }
            }
        }
        guard let i = t.text.items.firstIndex(where: { $0.key.is("EngineData") }) else { return nil }
        t.text.items[i].value = .rawData(Data(PSDText.engineDataBytes(e)))
        return PSDText.writeTySh(t)
    }
}
