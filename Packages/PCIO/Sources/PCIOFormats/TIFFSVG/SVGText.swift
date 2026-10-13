// SVG text as outlines for the import, natively with CoreText: photocraft-io (crates/io/src/svg.rs)
// takes usvg's `Text::flattened()` (text shaped and turned into paths with the system fonts);
// here `<text>`/`<tspan>` runs are shaped with CoreText and their glyph outlines become one path
// per run. Supported: `x`/`y`/`dx`/`dy` (lists, per character), `text-anchor`, `font-family`
// (lists, generic families), `font-size`, `font-weight`, `font-style`, `letter-spacing`,
// `word-spacing`, `xml:space`. `textPath` and vertical writing are rasterised instead.
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreGraphics
import CoreText
import Foundation

extension SVGImport {
    /// One run of text with one style: its outline in user space and the style to paint it with.
    struct TextRun {
        var path: CGMutablePath
        var style: [String: String]
    }

    /// usvg's defaults.
    static let defaultFontSize = 12.0
    static let defaultFontFamily = "Times New Roman"

    /// A font size in user units from a computed style.
    static func fontSize(_ style: [String: String], parent: Double = defaultFontSize, viewport: CGSize = .zero) -> Double {
        guard let s = style["font-size"]?.trimmingCharacters(in: .whitespaces).lowercased() else { return parent }
        let named: [String: Double] = ["xx-small": 9, "x-small": 10, "small": 13, "medium": 16, "large": 18, "x-large": 24, "xx-large": 32]
        if let v = named[s] { return v }
        if s == "larger" { return parent * 1.2 }
        if s == "smaller" { return parent / 1.2 }
        let v = length(s, percentBase: parent, fontSize: parent) ?? parent
        return v.isFinite && v >= 0 ? v : parent
    }

    /// The CoreText font for a computed style (first installed family of the list).
    static func font(_ style: [String: String], size: Double) -> CTFont {
        let families = (style["font-family"] ?? defaultFontFamily).split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        let generic: [String: String] = ["serif": "Times New Roman", "sans-serif": "Helvetica", "monospace": "Courier",
                                         "cursive": "Apple Chancery", "fantasy": "Papyrus", "system-ui": "Helvetica"]
        let weightValue = style["font-weight"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? "normal"
        let weight: Double = ["normal": 400, "bold": 700, "bolder": 700, "lighter": 300][weightValue] ?? Double(weightValue) ?? 400
        let italic = ["italic", "oblique"].contains(style["font-style"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? "")
        // CoreText weights: -1...1 (0 regular, 0.4 bold).
        let ctWeight = weight <= 400 ? (weight - 400) / 300 * 0.6 : (weight - 400) / 500 * 0.62
        for name in families + [defaultFontFamily] where !name.isEmpty {
            let family = generic[name.lowercased()] ?? name
            var traits: [CFString: Any] = [kCTFontWeightTrait: ctWeight]
            if italic { traits[kCTFontSymbolicTrait] = CTFontSymbolicTraits.traitItalic.rawValue }
            let attrs: [CFString: Any] = [kCTFontFamilyNameAttribute: family, kCTFontTraitsAttribute: traits]
            let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
            if let match = CTFontDescriptorCreateMatchingFontDescriptor(desc, Set([kCTFontFamilyNameAttribute as String]) as CFSet) {
                return CTFontCreateWithFontDescriptor(match, size, nil)
            }
        }
        return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    /// The characters of a text element with their positioning attributes and styles.
    private struct TextChar {
        var ch: Character
        var style: Int
        var x: Double?
        var y: Double?
        var dx = 0.0
        var dy = 0.0
    }

    /// Lays a `<text>` element out as outline runs in its user space. `style` is the text
    /// element's computed style.
    static func textRuns(_ text: Node, style: [String: String], viewport: CGSize) -> [TextRun] {
        var styles: [[String: String]] = []
        var chars: [TextChar] = []
        let preserve = style["xml:space"] == "preserve"
        // Collect characters depth first, each element's x/y/dx/dy lists applying to its own
        // characters from its first one on.
        func collect(_ n: Node, _ st: [String: String]) {
            let first = chars.count
            for c in n.children {
                if c.isText {
                    var s = c.text
                    if !preserve {
                        s = s.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\t", with: " ")
                    } else {
                        s = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
                    }
                    let idx = styles.count
                    styles.append(st)
                    for ch in s { chars.append(TextChar(ch: ch, style: idx)) }
                } else if c.name == "tspan" || c.name == "a" {
                    collect(c, computedStyle(st, c))
                }
            }
            let fs = fontSize(st, viewport: viewport)
            func list(_ k: String, _ base: Double) -> [Double] {
                (n.attrs[k] ?? "").split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { length(String($0), percentBase: base, fontSize: fs) }
            }
            let xs = list("x", viewport.width), ys = list("y", viewport.height), dxs = list("dx", viewport.width), dys = list("dy", viewport.height)
            var i = first, k = 0
            while i < chars.count, k < max(xs.count, ys.count, dxs.count, dys.count) {
                if k < xs.count, chars[i].x == nil { chars[i].x = xs[k] }
                if k < ys.count, chars[i].y == nil { chars[i].y = ys[k] }
                if k < dxs.count { chars[i].dx += dxs[k] }
                if k < dys.count { chars[i].dy += dys[k] }
                i += 1
                k += 1
            }
        }
        collect(text, style)
        // Collapse white space (xml:space default): no leading/trailing spaces, no runs of them.
        if !preserve {
            var out: [TextChar] = []
            for c in chars {
                if c.ch == " ", out.last?.ch == " " || out.isEmpty {
                    // Keep positioning carried by a dropped space on the next character.
                    continue
                }
                out.append(c)
            }
            while out.last?.ch == " " { out.removeLast() }
            chars = out
        }
        guard !chars.isEmpty else { return [] }
        if chars[0].x == nil { chars[0].x = 0 }
        if chars[0].y == nil { chars[0].y = 0 }

        // Segments: maximal sequences of one style without new positioning after their start.
        struct Segment { var start: Int; var end: Int }
        var segments: [Segment] = []
        for i in chars.indices {
            let c = chars[i]
            let breaks = i == 0 || c.x != nil || c.y != nil || c.dx != 0 || c.dy != 0 || c.style != chars[i - 1].style
            if breaks { segments.append(Segment(start: i, end: i + 1)) } else { segments[segments.count - 1].end = i + 1 }
        }
        // Chunks (for text-anchor): a new chunk at every absolute position.
        var runs: [TextRun] = []
        var pen = CGPoint.zero
        var chunk: [(run: Int, path: CGMutablePath, advance: Double)] = []
        var chunkStart = 0.0
        func finishChunk() {
            guard let firstRun = chunk.first else { return }
            let total = pen.x - chunkStart
            let anchor = styles[chars[segments[firstRun.run].start].style]["text-anchor"]?.trimmingCharacters(in: .whitespaces) ?? "start"
            let shift = anchor == "middle" ? -total / 2 : anchor == "end" ? -total : 0
            for c in chunk {
                let st = styles[chars[segments[c.run].start].style]
                if shift != 0 {
                    let moved = CGMutablePath()
                    moved.addPath(c.path, transform: CGAffineTransform(translationX: shift, y: 0))
                    runs.append(TextRun(path: moved, style: st))
                } else {
                    runs.append(TextRun(path: c.path, style: st))
                }
            }
            chunk = []
        }
        for (si, seg) in segments.enumerated() {
            let c0 = chars[seg.start]
            if c0.x != nil || c0.y != nil {
                finishChunk()
                pen = CGPoint(x: c0.x ?? pen.x, y: c0.y ?? pen.y)
                chunkStart = pen.x
            }
            pen.x += c0.dx
            pen.y += c0.dy
            let st = styles[c0.style]
            let size = fontSize(st, viewport: viewport)
            let string = String(chars[seg.start ..< seg.end].map(\.ch))
            let path = CGMutablePath()
            if size > 0 {
                let f = font(st, size: size)
                var attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): f]
                if let ls = st["letter-spacing"].flatMap({ length($0, percentBase: size, fontSize: size) }), ls != 0 {
                    attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = ls
                }
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
                var ws = 0.0
                if let w = st["word-spacing"].flatMap({ length($0, percentBase: size, fontSize: size) }) { ws = w }
                let runsCT = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
                for run in runsCT {
                    let n = CTRunGetGlyphCount(run)
                    guard n > 0 else { continue }
                    let runAttrs = CTRunGetAttributes(run) as NSDictionary
                    var runFont = f
                    if let v = runAttrs[kCTFontAttributeName as String], CFGetTypeID(v as CFTypeRef) == CTFontGetTypeID() {
                        runFont = unsafeDowncast(v as AnyObject, to: CTFont.self)
                    }
                    var glyphs = [CGGlyph](repeating: 0, count: n)
                    var positions = [CGPoint](repeating: .zero, count: n)
                    var indices = [CFIndex](repeating: 0, count: n)
                    CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
                    CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
                    CTRunGetStringIndices(run, CFRange(location: 0, length: n), &indices)
                    let units = Array(string.utf16)
                    for k in 0 ..< n {
                        // Word spacing: every space before this glyph adds `ws`.
                        var extra = 0.0
                        if ws != 0 {
                            let upto = min(max(0, indices[k]), units.count)
                            extra = Double(units[..<upto].filter { $0 == 0x20 }.count) * ws
                        }
                        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: pen.x + positions[k].x + extra, ty: pen.y)
                        if let g = CTFontCreatePathForGlyph(runFont, glyphs[k], &t) { path.addPath(g) }
                    }
                }
                pen.x += CTLineGetTypographicBounds(line, nil, nil, nil)
                if ws != 0 { pen.x += Double(string.filter { $0 == " " }.count) * ws }
            }
            chunk.append((si, path, 0))
        }
        finishChunk()
        // Merge consecutive runs of the same style into one outline.
        var merged: [TextRun] = []
        for r in runs {
            if let last = merged.last, last.style == r.style {
                last.path.addPath(r.path)
            } else {
                merged.append(r)
            }
        }
        return merged.filter { !$0.path.isEmpty }
    }

    /// The text content of an element (for layer names).
    static func textContent(_ n: Node) -> String {
        var out = ""
        for c in n.children {
            if c.isText { out += c.text } else if c.name == "tspan" || c.name == "a" { out += textContent(c) }
        }
        return out
    }
}
