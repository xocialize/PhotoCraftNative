// Port of photocraft-engine (crates/engine/src/type_extra_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Type menu: anti-aliasing, orientation, point ⇄ paragraph conversion, Create Work Path,
// Convert to Shape, Rasterize, Warp Text, the OpenType toggles, Paste Lorem Ipsum, Update All
// Text Layers, missing-font replacement and the default type styles.
//
// Everything edits PCDocument's `TextLayer` model and re-renders through `TypeCommands.refresh`.
// Deviations from photocraft, all from PCPlatform's text engine: Warp Text is stored on the layer
// (`TextLayer.warp`, round-tripped by PSD) but PCPlatform does not render it yet, so pixels and
// outlines stay unwarped; glyph outlines come from `TextEngine.outlines` and their path operations
// are assigned by contour nesting (outer combine, counters subtract) instead of per-glyph winding.

import CoreGraphics
import Foundation
import PCDocument
import PCFoundation
import PCPlatform

enum TypeExtraCommands: CommandModule {
    static let name = "type_extra_cmds"
    static let m = name
    typealias T = TypeCommands

    /// Photoshop's Paste Lorem Ipsum filler.
    static let loremIpsum = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."

    /// Warp styles in Photoshop's menu order: (PSD `warpStyle` value, short id used by commands)
    /// (photocraft-text `warp::STYLES`).
    static let warpStyles: [(String, String)] = [
        ("warpArc", "arc"), ("warpArcLower", "arcLower"), ("warpArcUpper", "arcUpper"), ("warpArch", "arch"), ("warpBulge", "bulge"),
        ("warpShellLower", "shellLower"), ("warpShellUpper", "shellUpper"), ("warpFlag", "flag"), ("warpWave", "wave"), ("warpFish", "fish"),
        ("warpRise", "rise"), ("warpFisheye", "fisheye"), ("warpInflate", "inflate"), ("warpSqueeze", "squeeze"), ("warpTwist", "twist"),
    ]

    /// PSD style name (`warpArc`) for a short id (`arc`, case-insensitive) or a PSD name.
    static func psdStyle(_ id: String) -> String? {
        let l = id.lowercased()
        if l == "none" || l == "warpnone" { return "warpNone" }
        return warpStyles.first { $0.0.lowercased() == l || $0.1.lowercased() == l }?.0
    }

    // MARK: Predicates

    static func activeText(_ s: Session) -> Result<TextLayer, EngineError> {
        guard let d = s.active else { return .failure(.other("no document open")) }
        if let id = d.activeLayer, let t = T.textOf(d.doc, id) { return .success(t) }
        return .failure(.other("the active layer is not a type layer"))
    }

    static func why(_ r: Result<TextLayer, EngineError>) -> String? {
        if case .failure(let e) = r { return e.description }
        return nil
    }

    static let hasText: CommandEnabled = { s, _ in why(activeText(s)) }

    static let hasPointText: CommandEnabled = { s, _ in
        switch activeText(s) {
        case .failure(let e): return e.description
        case .success(let t): if case .box = t.shape { return "the type layer is already paragraph text" }; return nil
        }
    }

    static let hasBoxText: CommandEnabled = { s, _ in
        switch activeText(s) {
        case .failure(let e): return e.description
        case .success(let t): if case .point = t.shape { return "the type layer is already point text" }; return nil
        }
    }

    static let anyText: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.walk().contains { T.isText($0.layer) } ? nil : "the document has no type layers"
    }

    static let hasDefaults: CommandEnabled = { s, p in
        if let why = T.hasFormatTarget(s, p) { return why }
        return s.state[T.DefaultsKey.self] == nil ? "no default type styles have been saved" : nil
    }

    // MARK: Helpers

    /// Edits a type layer as one history step and re-renders it.
    static func withText<R>(_ s: Session, _ p: JSONValue, _ label: String, _ f: (inout TextLayer, Document) throws -> R) throws -> R {
        let id = try s.layerParam(p)
        return try s.edit(label) { doc, _ in
            let snapshot = doc
            let out: R? = try doc.updateLayer(id) { l -> R in
                let autoNamed = T.isAutoNamed(l)
                guard T.isText(l) else { throw T.notTypeLayer(id, l.content) }
                var name: String?
                let r: R? = try l.withText { t -> R in
                    let r = try f(&t, snapshot)
                    T.refresh(snapshot, &t)
                    if autoNamed { name = T.layerName(t.text) }
                    return r
                }
                guard let r else { throw T.notTypeLayer(id, l.content) }
                if let name { l.name = name }
                return r
            }
            guard let out else { throw EngineError.noLayer(id) }
            return out
        }
    }

    static func layout(_ doc: Document, _ t: TextLayer) -> T.Layout { T.Layout(t, dpi: Double(doc.resolutionDpi)) }

    /// `m ∘ translate(tx, ty)`.
    static func thenTranslate(_ m: PCAffine, _ tx: Double, _ ty: Double) -> PCAffine {
        PCAffine(a: m.a, b: m.b, c: m.c, d: m.d, e: m.a * tx + m.c * ty + m.e, f: m.b * tx + m.d * ty + m.f)
    }

    static func firstAlign(_ t: TextLayer) -> TextAlign { t.paragraphRuns().first?.style.align ?? .left }

    // MARK: Anti-aliasing / orientation

    static func aaName(_ a: AntiAlias) -> String {
        switch a {
        case .none: "none"
        case .sharp: "sharp"
        case .crisp: "crisp"
        case .strong: "strong"
        case .smooth: "smooth"
        case .windows: "windows"
        case .windowsLcd: "windowsLcd"
        }
    }

    static func setAA(_ s: Session, _ p: JSONValue, _ aa: AntiAlias) throws -> JSONValue {
        try T.withTextTargets(s, p, "Anti-Alias") { t, _ in t.antialias = aa }
        return ["antialias": .string(aaName(aa))]
    }

    static func setOrientation(_ s: Session, _ p: JSONValue, _ o: TextOrientation) throws -> JSONValue {
        try T.withTextTargets(s, p, "Change Text Orientation") { t, _ in t.orientation = o }
        return ["orientation": .string(o == .vertical ? "vertical" : "horizontal")]
    }

    // MARK: Point ⇄ paragraph

    static func toParagraph(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let r = try withText(s, p, "Convert to Paragraph Text") { t, doc -> [Double] in
            let l = layout(doc, t)
            let dpi = Double(doc.resolutionDpi)
            let sizePx = Double(t.charRuns().map(\.style.sizePt).reduce(t.sizePt, max)) * dpi / 72
            let ps = t.paragraphRuns().first?.style ?? ParagraphStyle()
            let indents = Double(max(ps.startIndentPt + ps.endIndentPt, 0)) * dpi / 72
            if l.vertical {
                // Line space: u along the columns, v across them.
                let b = l.lineBounds() ?? [0, -sizePx / 2, sizePx, sizePx / 2]
                let (u0, v0, u1, v1) = (b[0], b[1], b[2], b[3])
                let height = max(u1 - u0, 1) + indents + max(sizePx * 0.5, 4)
                let width = max(v1 - v0, 1) + sizePx * 0.5
                let y: Double
                switch ps.align {
                case .center, .justifyCenter: y = -height / 2
                case .right, .justifyRight: y = -height
                default: y = 0
                }
                // The box's right edge is the first column's right edge, so the columns stay put.
                let x = -v0 - width
                t.shape = .box(.init(x: 0, y: 0, width: Float(width), height: Float(height)))
                t.transform = thenTranslate(t.transform, x, y)
                return [x, y, width, height]
            }
            let b = l.bounds() ?? [0, -Double(t.sizePt), Double(t.sizePt), 0]
            let (x0, y0, x1, y1) = (b[0], b[1], b[2], b[3])
            // A little slack so no line re-wraps; the box keeps the text where it was.
            let width = max(x1 - x0, 1) + indents + max(sizePx * 0.5, 4)
            let height = max(y1 - y0, 1) + sizePx * 0.5
            let x: Double
            switch ps.align {
            case .center, .justifyCenter: x = -width / 2
            case .right, .justifyRight: x = -width
            default: x = 0
            }
            var probe = t
            probe.shape = .box(.init(x: Float(x), y: Float(y0), width: Float(width), height: Float(height)))
            // Box text puts the first baseline at the box top plus the ascender height: measure it
            // and shift the box so that baseline stays at the point-text anchor (y = 0).
            let b0 = layout(doc, probe).lines.first?.baseline ?? 0
            let y = y0 - b0
            t.shape = .box(.init(x: 0, y: 0, width: Float(width), height: Float(height)))
            t.transform = thenTranslate(t.transform, x, y)
            return [x, y, width, height]
        }
        return ["box": .doubles(r)]
    }

    static func toPoint(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let r = try withText(s, p, "Convert to Point Text") { t, doc -> Int in
            guard case .box(let bx) = t.shape else { throw EngineError.other("already point text") }
            let l = layout(doc, t)
            // Vertical type: columns run along the box height.
            let (x, width) = l.vertical ? (Double(bx.y), Double(bx.height)) : (Double(bx.x), Double(bx.width))
            let baseline = l.lines.first?.baseline ?? 0
            // Photoshop inserts a hard return at every soft line break.
            var breaks: [Int] = []
            if l.lines.count > 1 {
                for i in 1..<l.lines.count where l.lines[i - 1].paragraph == l.lines[i].paragraph { breaks.append(l.lines[i].range.lowerBound) }
            }
            breaks = Array(Set(breaks)).sorted()
            for at in breaks.reversed() { T.replaceText(&t, at, at, "\n") }
            let ax: Double
            switch firstAlign(t) {
            case .center, .justifyCenter: ax = x + width / 2
            case .right, .justifyRight: ax = x + width
            default: ax = x
            }
            t.shape = .point
            // `baseline` is in line space (it already includes the box edge).
            let (tx, ty) = l.toText(ax, baseline)
            t.transform = thenTranslate(t.transform, tx, ty)
            return breaks.count
        }
        return ["inserted": .int(r)]
    }

    // MARK: Outlines → paths

    /// The type layer's glyph outlines as a document-space path. Outer contours combine and
    /// counters (the hole in "o") subtract, ordered by nesting depth, which reproduces the nonzero
    /// fill under Photoshop's per-subpath path operations.
    static func textPath(_ doc: Document, _ t: TextLayer) -> VectorPath {
        let contours = T.fonts { TextEngine.outlines(t, dpi: Double(doc.resolutionDpi)) }.subpaths.filter { $0.knots.count >= 2 }
        let paths = contours.map { VectorPath([Subpath(closed: true, knots: $0.knots)]).cgPath }
        let boxes = paths.map(\.boundingBoxOfPath)
        var depth = [Int](repeating: 0, count: contours.count)
        for i in contours.indices {
            guard let k = contours[i].knots.first else { continue }
            let pt = CGPoint(x: k.anchor.x, y: k.anchor.y)
            for j in contours.indices where j != i && boxes[j].contains(boxes[i]) && paths[j].contains(pt, using: .winding) {
                depth[i] += 1
            }
        }
        let order = contours.indices.sorted { (depth[$0], $0) < (depth[$1], $1) }
        return VectorPath(order.map { i in
            Subpath(closed: true, knots: contours[i].knots, op: depth[i] % 2 == 0 ? .combine : .subtract)
        })
    }

    static func createWorkPath(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        guard let d = s.active else { throw EngineError.noDocument }
        guard let t = T.textOf(d.doc, id) else { throw EngineError.other("not a type layer") }
        let path = textPath(d.doc, t)
        let n = path.subpaths.count
        try s.edit("Create Work Path") { doc, _ in doc.workPath = path }
        return ["subpaths": .int(n)]
    }

    static func convertToShape(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        let n = try s.edit("Convert to Shape") { doc, _ -> Int in
            let snapshot = doc
            let out: Int? = try doc.updateLayer(id) { l -> Int in
                guard case .text(let t) = l.content else { throw EngineError.other("not a type layer") }
                let color = t.charRuns().first?.style.color ?? t.color
                var sh = ShapeLayer(path: textPath(snapshot, t), fill: .solid(color))
                VectorRasterizer.renderCache(&sh, format: snapshot.pixelFormat, clip: snapshot.bounds)
                let n = sh.path.subpaths.count
                l.content = .shape(sh)
                l.psdBlocks.removeAll { $0.key == PSDKey("TySh") }
                return n
            }
            guard let out else { throw EngineError.noLayer(id) }
            return out
        }
        return ["layer": .id(id), "subpaths": .int(n)]
    }

    // MARK: Warp

    static func warpText(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "type.warpText"
        let style = p["style"]?.stringValue ?? "arc"
        guard let psd = psdStyle(style) else { throw EngineError.bad(cmd, "unknown warp style \"\(style)\"") }
        func f(_ k: String, _ d: Double) -> Float { Float(min(max(p[k]?.doubleValue ?? d, -100), 100)) }
        let warp: TextWarp? = psd == "warpNone" ? nil : TextWarp(
            style: psd, value: f("bend", 50), horizontalDistortion: f("horizontalDistortion", 0),
            verticalDistortion: f("verticalDistortion", 0), horizontal: p["orientation"]?.stringValue != "vertical")
        let out: JSONValue = ["warp": warp.map { .encoded($0) } ?? .null]
        try T.withTextTargets(s, p, "Warp Text") { t, _ in t.warp = warp }
        return out
    }

    // MARK: OpenType toggles

    /// Is the OpenType toggle `tag` on for a character style? (`liga`/`dlig` have dedicated fields.)
    static func featureOn(_ st: CharStyle, _ tag: String) -> Bool {
        switch tag {
        case "liga": st.ligatures
        case "dlig": st.discretionaryLigatures
        default: st.features.contains { $0.tag == tag && $0.value > 0 }
        }
    }

    static func setFeature(_ st: inout CharStyle, _ tag: String, _ on: Bool) {
        switch tag {
        case "liga": st.ligatures = on
        case "dlig": st.discretionaryLigatures = on
        default:
            st.features.removeAll { $0.tag == tag }
            if on { st.features.append(FontFeature(tag: tag, value: 1)) }
        }
    }

    static func toggleOpenType(_ s: Session, _ p: JSONValue, _ tag: String) throws -> JSONValue {
        let ids = try T.formatTargets(s, p)
        guard let st = s.active else { throw EngineError.noDocument }
        let representative = st.activeLayer.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        let cur = representative.flatMap { T.textOf(st.doc, $0) }.flatMap { $0.charRuns().first }.map { featureOn($0.style, tag) } ?? false
        let on = p["on"]?.boolValue ?? !cur
        try T.withTextTargets(s, p, "Change OpenType Feature") { t, r in
            T.styleRange(&t, min(r.0, r.1), max(r.0, r.1)) { setFeature(&$0, tag, on) }
        }
        return ["feature": .string(tag), "on": .bool(on)]
    }

    // MARK: Lorem ipsum / update / fonts / defaults

    static func pasteLorem(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        if why(activeText(s)) == nil && p["new"]?.boolValue != true {
            let caret = try withText(s, p, "Paste Lorem Ipsum") { t, _ -> Int in
                let at = T.index(p["at"]).map { T.byteAt(t.text, $0) } ?? t.text.utf8.count
                T.replaceText(&t, at, at, loremIpsum)
                return T.charAt(t.text, at + loremIpsum.utf8.count)
            }
            return ["caret": .int(caret)]
        }
        // No type layer active: a paragraph text box over most of the canvas.
        guard let d = s.active else { throw EngineError.noDocument }
        let (w, h) = (Double(d.doc.size.width), Double(d.doc.size.height))
        let size = p["size"]?.doubleValue ?? min(max(h / 20 * 72 / Double(d.doc.resolutionDpi), 6), 72)
        let r = try s.execute("type.create", ["box": .doubles([w * 0.1, h * 0.1, w * 0.8, h * 0.8]), "text": .string(loremIpsum), "size": .number(size)])
        return ["layer": r["layer"] ?? .null]
    }

    static func updateAll(_ s: Session) throws -> JSONValue {
        let n = try s.edit("Update All Text Layers") { doc, _ -> Int in
            let snapshot = doc
            var n = 0
            for id in T.textLayerIds(snapshot) where T.withText(&doc, id, { T.refresh(snapshot, &$0) }) != nil { n += 1 }
            return n
        }
        return ["updated": .int(n)]
    }

    /// Replace missing families per `map` (missing → installed; unmapped ones → the default family).
    static func replaceFonts(_ s: Session, _ map: [String: JSONValue], all: Bool) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let missing = T.missingFonts(d.doc)
        func pick(_ f: String) -> String? {
            guard missing.contains(f) else { return nil }
            return map[f]?.stringValue ?? (all ? T.defaultFamily : nil)
        }
        let ids = T.textLayerIds(d.doc)
        if missing.isEmpty { return ["missing": [], "replaced": 0] }
        let n = try s.edit("Replace Missing Fonts") { doc, _ -> Int in
            let snapshot = doc
            var n = 0
            for id in ids {
                T.withText(&doc, id) { t in
                    var changed = false
                    var at = 0
                    for r in t.charRuns() {
                        if let to = pick(r.style.fontFamily) {
                            T.styleRange(&t, at, at + r.len) { st in
                                st.fontFamily = to
                                st.postscriptName = nil
                            }
                            changed = true
                        }
                        at += r.len
                    }
                    if changed {
                        T.refresh(snapshot, &t)
                        n += 1
                    }
                }
            }
            return n
        }
        return ["missing": .strings(missing), "replaced": .int(n)]
    }

    static func resolveMissing(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        if let m = p["map"]?.objectValue { return try replaceFonts(s, m, all: false) }
        guard let d = s.active else { throw EngineError.noDocument }
        return ["missing": .strings(T.missingFonts(d.doc))]
    }

    static func saveDefaults(_ s: Session) throws -> JSONValue {
        let t = try activeText(s).get()
        let c = t.charRuns().first?.style ?? CharStyle()
        let pp = t.paragraphRuns().first?.style ?? ParagraphStyle()
        s.state[T.DefaultsKey.self] = T.Defaults(char: c, para: pp)
        return ["font": .string(c.fontFamily), "size": .float(c.sizePt)]
    }

    static func loadDefaults(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.state[T.DefaultsKey.self] else { throw EngineError.other("no default type styles have been saved") }
        try T.withTextTargets(s, p, "Load Default Type Styles") { t, _ in
            let n = t.text.utf8.count
            T.styleRange(&t, 0, n) { $0 = d.char }
            T.styleParagraphs(&t, 0, n) { $0 = d.para }
        }
        return ["font": .string(d.char.fontFamily), "size": .float(d.char.sizePt)]
    }

    // MARK: Registry

    static func register(into r: inout CommandRegistry) {
        let lp = ##"{"layer":id?}"##
        let fp = ##"{"layer":id? or "layers":[id,…]? (default selected Type layers)}"##
        let ot = ##"{"layer":id? or "layers":[id,…]? (default selected Type layers),"on":bool? (default: toggle representative),"range":[startChar,endChar]? (single layer; default all)}"##
        let aa: [(String, String, AntiAlias)] = [("none", "None", .none), ("sharp", "Sharp", .sharp), ("crisp", "Crisp", .crisp), ("strong", "Strong", .strong),
                                                  ("smooth", "Smooth", .smooth), ("windowsLcd", "Windows LCD", .windowsLcd), ("windows", "Windows", .windows)]
        for (id, label, mode) in aa {
            r.add(CommandSpec("type.antiAlias.\(id)", label, menu: ["Type", "Anti-Alias"], params: fp, module: m, enabled: T.hasFormatTarget) { s, p in
                try setAA(s, p, mode)
            })
        }
        r.add(CommandSpec("type.orientation.horizontal", "Horizontal", menu: ["Type", "Orientation"], params: fp, module: m, enabled: T.hasFormatTarget) { s, p in
            try setOrientation(s, p, .horizontal)
        })
        r.add(CommandSpec("type.orientation.vertical", "Vertical", menu: ["Type", "Orientation"], params: fp, module: m, enabled: T.hasFormatTarget) { s, p in
            try setOrientation(s, p, .vertical)
        })
        let features: [(String, String, String)] = [
            ("standardLigatures", "Standard Ligatures", "liga"), ("contextualAlternates", "Contextual Alternates", "calt"),
            ("discretionaryLigatures", "Discretionary Ligatures", "dlig"), ("swash", "Swash", "swsh"), ("oldstyle", "Oldstyle", "onum"),
            ("stylisticAlternates", "Stylistic Alternates", "salt"), ("titlingAlternates", "Titling Alternates", "titl"), ("ornaments", "Ornaments", "ornm"),
            ("ordinals", "Ordinals", "ordn"), ("fractions", "Fractions", "frac"),
        ]
        for (id, label, tag) in features {
            r.add(CommandSpec("type.openType.\(id)", label, menu: ["Type", "OpenType"], params: ot, module: m, enabled: T.hasFormatTarget) { s, p in
                try toggleOpenType(s, p, tag)
            })
        }
        r.add(CommandSpec("type.createWorkPath", "Create Work Path", menu: ["Type"], params: lp, module: m, enabled: hasText) { s, p in try createWorkPath(s, p) })
        r.add(CommandSpec("type.convertToShape", "Convert to Shape", menu: ["Type"], params: lp, module: m, enabled: hasText) { s, p in try convertToShape(s, p) })
        r.add(CommandSpec("type.rasterizeTypeLayer", "Rasterize Type Layer", menu: ["Type"], params: lp, module: m, enabled: hasText) { s, p in
            try s.execute("type.rasterize", p)
        })
        r.add(CommandSpec("type.convertToParagraphText", "Convert to Paragraph Text", menu: ["Type"], params: lp, module: m, enabled: hasPointText) { s, p in
            try toParagraph(s, p)
        })
        r.add(CommandSpec("type.convertToPointText", "Convert to Point Text", menu: ["Type"], params: lp, module: m, enabled: hasBoxText) { s, p in
            try toPoint(s, p)
        })
        r.add(CommandSpec("type.warpText", "Warp Text…", menu: ["Type"],
                          params: ##"{"layer":id? or "layers":[id,…]? (default selected Type layers),"style":"none|arc|arcLower|arcUpper|arch|bulge|shellLower|shellUpper|flag|wave|fish|rise|fisheye|inflate|squeeze|twist"="arc","orientation":"horizontal|vertical"="horizontal","bend":-100..100=50,"horizontalDistortion":-100..100=0,"verticalDistortion":-100..100=0}"##,
                          module: m, enabled: T.hasFormatTarget) { s, p in try warpText(s, p) })
        r.add(CommandSpec("type.updateAllTextLayers", "Update All Text Layers", menu: ["Type"], params: "{}", module: m, enabled: anyText) { s, _ in try updateAll(s) })
        r.add(CommandSpec("type.replaceAllMissingFonts", "Replace All Missing Fonts", menu: ["Type"], params: "{} (with the default family)", module: m,
                          enabled: anyText) { s, _ in try replaceFonts(s, [:], all: true) })
        r.add(CommandSpec("type.resolveMissingFonts", "Resolve Missing Fonts…", menu: ["Type"],
                          params: ##"{"map":{"Missing Family":"Installed Family"}?} (no map: list the missing families)"##, module: m, enabled: anyText) { s, p in
            try resolveMissing(s, p)
        })
        r.add(CommandSpec("type.pasteLoremIpsum", "Paste Lorem Ipsum", menu: ["Type"],
                          params: ##"{"layer":id?,"at":char? (default end),"new":bool=false (new paragraph text layer)}"##, module: m, enabled: T.hasDoc) { s, p in
            try pasteLorem(s, p)
        })
        r.add(CommandSpec("type.saveDefaultTypeStyles", "Save Default Type Styles", menu: ["Type"],
                          params: "{} (from the active type layer; new type layers start from them)", module: m, enabled: hasText) { s, _ in try saveDefaults(s) })
        r.add(CommandSpec("type.loadDefaultTypeStyles", "Load Default Type Styles", menu: ["Type"], params: fp, module: m, enabled: hasDefaults) { s, p in
            try loadDefaults(s, p)
        })
    }
}
