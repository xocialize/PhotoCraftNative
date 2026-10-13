// Port of photocraft-affinity (crates/affinity/src/text.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// Artistic and frame text: the story's characters with their font, size, colour, tracking and
// leading, the paragraph alignment and the first baseline. Layout (line breaks in frames, kerning,
// OpenType features) is left to the importing application.

extension Affinity {
    enum TextReader {
        /// Characters read per text node (stories are split into blocks; this caps hostile ones).
        static let maxChars = 1 << 20
        static let objectReplacement: Unicode.Scalar = "\u{FFFC}"

        static func read(_ r: Reader, _ id: ObjID, _ world: Affine) -> Text? {
            let s = r.s
            guard let story = s.obj(id, "StSt"), let frame = s.obj(id, "TxtH") else { return nil }
            let artistic = s.isClass(frame, "ArFr")
            guard let bounds = s.floats(frame, "FrmB", count: 4).map(Affinity.rect) else { return nil }
            var runs: [TextRun] = []
            var align: Text.Align?
            var total = 0
            var placeholders = false
            for block in s.objs(story, "Blok") {
                guard let glyphs = s.obj(block, "Glyp") else { return nil }
                var chars: [Unicode.Scalar]
                if let t = s.str(glyphs, "Utf8") {
                    chars = Array(t.unicodeScalars)
                } else {
                    // Inline objects (page numbers, anchors) each take one index before the segment text.
                    chars = []
                    for seg in s.objs(glyphs, "Mixd") {
                        let inline = s.objs(seg, "Glys").count
                        chars.append(contentsOf: repeatElement(objectReplacement, count: inline))
                        placeholders = placeholders || inline > 0
                        chars.append(contentsOf: (s.str(seg, "Utf8") ?? "").unicodeScalars)
                    }
                }
                total += chars.count
                if total > maxChars {
                    r.warn("text longer than a million characters (truncated)")
                    break
                }
                var start = 0
                let attributeRuns = s.obj(block, "GAtt").map { s.objs($0, "Runs") } ?? []
                for run in attributeRuns {
                    guard let index = s.int(run, "Indx"), let i = Int(exactly: index), i >= 0 else { return nil }
                    let end = min(i, chars.count)
                    if end <= start { continue }
                    var view = String.UnicodeScalarView()
                    view.append(contentsOf: chars[start..<end].lazy.filter { $0 != "\0" && $0 != objectReplacement })
                    let text = String(view)
                    start = end
                    guard let attrs = s.obj(run, "Item") else { continue }
                    if !text.isEmpty { runs.append(runAttributes(r, attrs, text, world)) }
                }
                if align == nil,
                   let p = s.obj(block, "PAtt"), let first = s.objs(p, "Runs").first, let item = s.obj(first, "Item") {
                    align = paragraphAlign(r, item)
                }
            }
            if placeholders { r.warn("text fields such as page numbers (left out of the text)") }
            let alignment = align ?? .left
            let firstBaseline = bounds.y0 + (s.f64(frame, "ArtV") ?? 0)
            let anchorX: Double
            switch alignment {
            case .center: anchorX = (bounds.x0 + bounds.x1) / 2
            case .right: anchorX = bounds.x1
            default: anchorX = bounds.x0
            }
            if !artistic {
                var columns = s.objs(frame, "ColW").count > 1
                if case .array(let a)? = s.field(frame, "ColW"), a.count > 1 { columns = true }
                if columns { r.warn("text frames with several columns (imported as one column)") }
                if s.classTag(id) == "TxtC" { r.warn("text frames with a curved outline (imported as rectangular frames)") }
            }
            return Text(runs: runs, align: alignment, anchor: Point(x: anchorX, y: firstBaseline), frame: artistic ? nil : bounds, transform: world)
        }

        static func slot<T>(_ v: Value?, _ i: Int, _ f: (Value) -> T?) -> T? {
            guard case .array(let a)? = v, a.indices.contains(i) else { return nil }
            return f(a[i])
        }

        static func float(_ v: Value) -> Double? {
            if case .float(let f) = v, f.isFinite { return f }
            return nil
        }

        static func int(_ v: Value) -> Int64? {
            switch v {
            case .int(let i): i
            case .uint(let u): Int64(exactly: u)
            default: nil
            }
        }

        static func runAttributes(_ r: Reader, _ attrs: ObjID, _ text: String, _ world: Affine) -> TextRun {
            let s = r.s
            let doubles = s.field(attrs, "Doub")
            let ints = s.field(attrs, "Ints")
            let size = slot(doubles, 0, float).flatMap { $0 > 0 && $0 < 1e6 ? $0 : nil } ?? 12 * r.dpi / 72
            let tracking = slot(doubles, 4, float) ?? 0
            let leading = slot(ints, 4, int) == 1 ? slot(doubles, 13, float).flatMap { $0 > 0 ? $0 : nil } : nil
            var objects: [ObjID?] = []
            if case .array(let a)? = s.field(attrs, "Objs") {
                objects = a.map { if case .obj(let o) = $0 { o } else { nil } }
            }
            let fill = objects.first.flatMap { $0 }.flatMap { PaintReader.descriptor(r, $0, world) } ?? .none
            if let pen = objects.dropFirst().first.flatMap({ $0 }), let p = PaintReader.descriptor(r, pen, world), p != .none {
                r.warn("outlined (stroked) text")
            }
            if let h = slot(doubles, 10, float), abs(h - 1) > 1e-3 {
                r.warn("horizontally scaled text")
            }
            let font = s.obj(attrs, "DFnt")
            func get(_ tag: Tag) -> String { font.flatMap { s.str($0, tag) } ?? "" }
            return TextRun(
                text: text,
                postscript: get("Post"),
                family: get("Famy"),
                weight: font.flatMap { s.int($0, "Wegt") } ?? 400,
                italic: font.flatMap { s.bool($0, "Ital") } ?? false,
                size: size,
                tracking: tracking,
                leading: leading,
                fill: fill
            )
        }

        static func paragraphAlign(_ r: Reader, _ p: ObjID) -> Text.Align {
            switch slot(r.s.field(p, "Ints"), 0, int) {
            case 1?: return .center
            case 2?: return .right
            case 3?: return .justify
            case 0?, nil: return .left
            default:
                r.warn("an unknown paragraph alignment (imported as left)")
                return .left
            }
        }
    }
}
