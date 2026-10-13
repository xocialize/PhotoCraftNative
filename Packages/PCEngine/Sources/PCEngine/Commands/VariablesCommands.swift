// Port of photocraft-engine (crates/engine/src/variables_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Image › Variables and Data Sets, and the File menu's data-set import — Photoshop's data-driven
// graphics. Define variables that bind a layer's visibility, text or pixels to named data slots,
// then apply a data set (a row of values) to render a variation. Pixel Replacement imports the
// replacement file through PCIO (flat or layered: its composite is placed) and scales it with
// PCAlgo; Data Sets as Files exports each variation through PCIO in any format.

import Foundation
import PCDocument
import PCAlgo
import PCFoundation
import PCPlatform

public enum VariablesCommands: CommandModule {
    public static let name = "variables_cmds"
    static let m = name

    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document" : nil }

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    // MARK: Parse helpers

    static func parseKind(_ v: JSONValue) -> VarKind? {
        switch v["type"]?.stringValue {
        case "visibility"?: return .visibility
        case "textReplacement"?, "text"?: return .textReplacement
        case "pixelReplacement"?, "pixel"?:
            let method: PixelMethod = switch v["method"]?.stringValue {
            case "fill"?: .fill
            case "asIs"?: .asIs
            case "conform"?: .conform
            default: .fit
            }
            let align = v["align"]?.stringValue.flatMap { PixelAlign(rawValue: $0) } ?? .center
            return .pixelReplacement(method: method, align: align, clip: v["clip"]?.boolValue ?? false)
        default:
            return nil
        }
    }

    static func kindJSON(_ k: VarKind) -> [String: JSONValue] {
        switch k {
        case .visibility: ["type": "visibility"]
        case .textReplacement: ["type": "textReplacement"]
        case .pixelReplacement(let method, let align, let clip):
            ["type": "pixelReplacement", "method": .string(method.rawValue), "align": .string(align.rawValue), "clip": .bool(clip)]
        }
    }

    static func valueJSON(_ v: VariableValue) -> [String: JSONValue] {
        switch v {
        case .visibility(let b): ["kind": "visibility", "value": .bool(b)]
        case .text(let t): ["kind": "text", "value": .string(t)]
        case .pixels(let p): ["kind": "pixels", "value": .string(p)]
        }
    }

    static func parseValue(_ v: JSONValue) -> VariableValue? {
        guard v["variable"]?.stringValue != nil else { return nil }
        switch v["kind"]?.stringValue {
        case "visibility"?: return v["value"]?.boolValue.map { .visibility($0) }
        case "text"?: return v["value"]?.stringValue.map { .text($0) }
        case "pixels"?: return v["value"]?.stringValue.map { .pixels($0) }
        default: return nil
        }
    }

    /// Mutates the document's variables without a history step (config, not a canvas edit).
    static func setVars(_ s: Session, _ f: (inout Variables) -> Void) throws {
        let rev = try s.updateActive { st -> UInt64 in
            f(&st.doc.variables)
            st.revision += 1
            st.lastDamage = .empty
            st.lastTransaction = nil
            return st.revision
        }
        if let id = s.active?.id { s.emit(.documentChanged(id, revision: rev, damage: .empty)) }
    }

    // MARK: Commands

    static func define(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.variables.define"
        guard let defsIn = p["defs"]?.arrayValue else { throw bad(cmd, "need `defs`") }
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        var defs: [VariableDef] = []
        for d in defsIn {
            guard let name = d["name"]?.stringValue else { throw bad(cmd, "a def needs `name`") }
            guard let raw = d["layer"]?.uint64Value else { throw bad(cmd, "a def needs `layer`") }
            let layer = LayerId(raw)
            if doc.layer(layer) == nil { throw EngineError.noLayer(layer) }
            guard let kind = parseKind(d) else { throw bad(cmd, "a def needs a valid `type`") }
            if defs.contains(where: { $0.name == name }) { throw bad(cmd, "duplicate variable `\(name)`") }
            defs.append(VariableDef(name: name, layer: layer, kind: kind))
        }
        try setVars(s) { $0.defs = defs }
        return try list(s)
    }

    static func dataSets(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.variables.dataSets"
        guard let rows = p["dataSets"]?.arrayValue else { throw bad(cmd, "need `dataSets`") }
        var sets: [DataSet] = []
        for r in rows {
            guard let name = r["name"]?.stringValue else { throw bad(cmd, "a data set needs `name`") }
            var values: [DataValue] = []
            for v in r["values"]?.arrayValue ?? [] {
                guard let variable = v["variable"]?.stringValue else { throw bad(cmd, "a value needs `variable`") }
                guard let value = parseValue(v) else { throw bad(cmd, "a value needs `kind` and `value`") }
                values.append(DataValue(variable: variable, value: value))
            }
            sets.append(DataSet(name: name, values: values))
        }
        let append = p["append"]?.boolValue ?? false
        try setVars(s) { v in
            if append { v.dataSets.append(contentsOf: sets) } else { v.dataSets = sets }
        }
        return try list(s)
    }

    /// Whether applying `set` needs a Pixel Replacement (an image file decoded and placed).
    static func replacesPixels(_ vars: Variables, _ set: DataSet) -> Bool {
        set.values.contains { dv in
            guard let def = vars.def(dv.variable), case .pixelReplacement = def.kind, case .pixels = dv.value else { return false }
            return true
        }
    }

    /// Applies one data set's values to the document (visibility, text). A history step.
    static func applyToDoc(_ doc: inout Document, _ vars: Variables, _ set: DataSet, images: [String: (Surface, PixelSize)] = [:]) throws {
        for dv in set.values {
            guard let def = vars.def(dv.variable) else { continue }
            switch (def.kind, dv.value) {
            case (.visibility, .visibility(let show)):
                doc.updateLayer(def.layer) { $0.visible = show }
            case (.textReplacement, .text(let text)):
                let (dpi, fmt) = (Double(doc.resolutionDpi), doc.pixelFormat)
                doc.updateLayer(def.layer) { l in
                    l.withText { t in
                        // As in Photoshop, the new text takes the style of the first character it
                        // replaces (and its paragraph's settings): clearing the runs fell back to
                        // the summary style and lost weight, italic, tracking, caps… (#2742).
                        let style = t.charRuns().first?.style ?? CharStyle()
                        let para = t.paragraphRuns().first?.style ?? ParagraphStyle()
                        t.text = text
                        t.runs = [TextRun(len: text.utf8.count, style: style)]
                        t.paragraphs = [ParagraphRun(len: text.utf8.count, style: para)]
                        t.syncSummary()
                        // The compositor draws a type layer from its cache: re-render it (#990).
                        // The PSD `TySh` data no longer describes the text; PSD export rebuilds it.
                        TextEngine.renderLayer(&t, dpi: dpi, format: fmt)
                        t.psdRaw = nil
                    }
                }
            case (.pixelReplacement(let method, let align, let clip), .pixels(let path)):
                guard let (img, size) = images[path] else { throw EngineError.other("read `\(path)`: the replacement image was not loaded") }
                replacePixels(&doc, def.layer, img, size, method, align, clip)
            default:
                continue // value type doesn't match the variable kind: skip
            }
        }
    }

    /// The replacement images of a data set's Pixel Replacement values: each file imported through
    /// PCIO (flat or layered) and flattened in the document's pixel format (photocraft
    /// `file_cmds::import` + `flattened`).
    static func replacementImages(_ s: Session, _ vars: Variables, _ set: DataSet, format: PixelFormat) throws -> [String: (Surface, PixelSize)] {
        var out: [String: (Surface, PixelSize)] = [:]
        for dv in set.values {
            guard let def = vars.def(dv.variable), case .pixelReplacement = def.kind, case .pixels(let path) = dv.value, out[path] == nil else { continue }
            let data: Data
            do { data = try s.services.fileSystem.read(path) } catch { throw EngineError.other("read `\(path)`: \(EngineError.wrap(error))") }
            let src = try FileCommands.import(s, path, [UInt8](data))
            out[path] = (try FileCommands.flattened(s, src, format), src.size)
        }
        return out
    }

    /// Replaces a pixel layer's content with an image, scaled (`method`, bicubic) and aligned in
    /// the layer's content bounds (else the canvas); `clip` keeps it inside them (photocraft
    /// `replace_pixels`).
    static func replacePixels(_ doc: inout Document, _ layer: LayerId, _ img: Surface, _ size: PixelSize, _ method: PixelMethod, _ align: PixelAlign, _ clip: Bool) {
        let content = doc.layer(layer)?.surface?.contentBounds ?? .empty
        let target = content.isEmpty ? doc.bounds : content
        if target.isEmpty { return }
        let (iw, ih) = (Double(max(size.width, 1)), Double(max(size.height, 1)))
        let (tw, th) = (Double(target.width), Double(target.height))
        let (sx, sy): (Double, Double)
        switch method {
        case .fit: let k = min(tw / iw, th / ih); (sx, sy) = (k, k)
        case .fill: let k = max(tw / iw, th / ih); (sx, sy) = (k, k)
        case .conform: (sx, sy) = (tw / iw, th / ih)
        case .asIs: (sx, sy) = (1, 1)
        }
        let scaled = abs(sx - 1) > 1e-9 || abs(sy - 1) > 1e-9 ? Resample.resizeSurface(img, sx: sx, sy: sy, filter: .bicubic) : img
        let (sw, sh) = (iw * sx, ih * sy)
        let fx: Double = switch align {
        case .topLeft, .centerLeft, .bottomLeft: 0
        case .topRight, .centerRight, .bottomRight: 1
        default: 0.5
        }
        let fy: Double = switch align {
        case .topLeft, .topCenter, .topRight: 0
        case .bottomLeft, .bottomCenter, .bottomRight: 1
        default: 0.5
        }
        let dx = Int32(clamping: Int64((Double(target.x0) + (tw - sw) * fx).rounded()))
        let dy = Int32(clamping: Int64((Double(target.y0) + (th - sh) * fy).rounded()))
        var placed = scaled.shifted(dx: dx, dy: dy)
        if clip { placed = Resample.cropSurface(placed, keep: target) }
        doc.updateLayer(layer) { l in
            if case .raster = l.content { l.content = .raster(placed) }
        }
    }

    static func applyDataSet(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let (set, idx) = try resolveSet(s, p, "image.applyDataSet")
        guard let vars = s.active?.doc.variables else { throw EngineError.noDocument }
        // Pixel Replacement reads image files, so an untrusted session's gate judges each path.
        if let auth = s.authorize {
            for dv in set.values {
                if case .pixels(let path) = dv.value {
                    do { try auth("image.applyDataSet", ["path": .string(path)]) } catch { throw EngineError.wrap(error) }
                }
            }
        }
        let images = try replacementImages(s, vars, set, format: s.active?.doc.pixelFormat ?? .rgba8)
        try s.edit("Apply Data Set \"\(set.name)\"") { doc, _ in try applyToDoc(&doc, vars, set, images: images) }
        try setVars(s) { $0.active = idx }
        return ["applied": .string(set.name), "index": .int(idx)]
    }

    /// File › Export › Data Sets as Files: apply each data set in turn and export the flattened
    /// document (photocraft `export_as_files`). `{dir, format?("png"), dataSets?[names]}` →
    /// `{files:[…],count}`. The folder appears only once the batch has been planned, so a batch
    /// rejected for colliding names leaves nothing behind.
    static func exportAsFiles(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let dir = p["dir"]?.stringValue else { throw bad("file.export.dataSetsAsFiles", "need `dir`") }
        var madeDir = false
        let names = try exportDataSets(s, p) { name, bytes in
            if !madeDir {
                do { try s.services.fileSystem.createDirectory(dir) } catch { throw EngineError.other("mkdir `\(dir)`: \(EngineError.wrap(error))") }
                madeDir = true
            }
            try FileCommands.writeFile(s, "\(dir)/\(name)", bytes)
        }
        let files = names.map { JSONValue.string("\(dir)/\($0)") }
        return ["files": .array(files), "count": .int(files.count)]
    }

    /// The bodies of `file.export.dataSetsAsFiles`, streamed to `write` as a single-component
    /// filename plus its bytes: one flattened file per data set (photocraft
    /// `export_data_sets_with`). The whole batch is planned first, so colliding names are
    /// rejected before any file is written. Returns the filenames written, in order.
    public static func exportDataSets(_ s: Session, _ p: JSONValue, _ write: (String, [UInt8]) throws -> Void) throws -> [String] {
        let cmd = "file.export.dataSetsAsFiles"
        let format = p["format"]?.stringValue ?? "png"
        guard let st = s.active else { throw EngineError.noDocument }
        let original = st.doc
        let vars = original.variables
        let wanted: [String]? = p["dataSets"]?.arrayValue.map { $0.compactMap(\.stringValue) }
        let sets = vars.dataSets.filter { d in wanted.map { $0.contains(d.name) } ?? true }
        if sets.isEmpty { throw bad(cmd, "no data sets to export") }
        // Filename template: `{name}` (sanitised data-set name), `{index}` (1-based). Default `{name}`.
        let template = p["naming"]?.stringValue ?? "{name}"
        let docStem = original.name.lastIndex(of: ".").map { String(original.name[..<$0]) } ?? original.name
        // Plan the whole batch before writing: sanitised names or a constant template may collide.
        var claimed: [String: String] = [:]
        var names: [String] = []
        for (n, set) in sets.enumerated() {
            let safe = String(String.UnicodeScalarView(set.name.unicodeScalars.map { u in
                u.properties.isAlphabetic || u.properties.numericType != nil || u == "-" || u == "_" ? u : "_"
            }))
            let stem = template.replacingOccurrences(of: "{name}", with: safe)
                .replacingOccurrences(of: "{index}", with: String(format: "%03d", n + 1))
                .replacingOccurrences(of: "{document}", with: docStem)
            let name = "\(stem).\(format)"
            if let first = claimed.updateValue(set.name, forKey: name.lowercased()) {
                throw bad(cmd, "data sets `\(first)` and `\(set.name)` resolve to the same output `\(name)`; include {index} in `naming` to use distinct filenames")
            }
            names.append(name)
        }
        var written: [String] = []
        for (set, name) in zip(sets, names) {
            var doc = original
            let images = try replacementImages(s, vars, set, format: doc.pixelFormat)
            try applyToDoc(&doc, vars, set, images: images)
            let bytes: [UInt8]
            do { bytes = try EngineIO.export(doc, as: format, services: s.services).bytes } catch {
                throw EngineError.other("export `\(set.name)`: \(EngineError.wrap(error))")
            }
            try write(name, bytes)
            written.append(name)
        }
        return written
    }

    /// Resolves a data set from `{name}` or `{index}`.
    static func resolveSet(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> (DataSet, Int) {
        guard let vars = s.active?.doc.variables else { throw EngineError.noDocument }
        if let name = p["name"]?.stringValue {
            guard let i = vars.dataSetIndex(name) else { throw bad(cmd, "no data set `\(name)`") }
            return (vars.dataSets[i], i)
        } else if let raw = p["index"]?.uint64Value {
            guard let i = Int(exactly: raw), i < vars.dataSets.count else { throw bad(cmd, "no data set at index \(raw)") }
            return (vars.dataSets[i], i)
        }
        throw bad(cmd, "need `name` or `index`")
    }

    /// Imports data sets from a CSV: the header row holds variable names, each later row is a
    /// data set. A value is a boolean for a Visibility variable, a path for a Pixel Replacement
    /// variable, else text. The first column may be a data-set name (header empty or `DataSet`).
    static func importDataSets(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let path = p["path"]?.stringValue else { throw bad("file.import.variableDataSets", "need `path`") }
        let data: Data
        do { data = try s.services.fileSystem.read(path) } catch {
            throw EngineError.other("read `\(path)`: \(EngineError.wrap(error).description)")
        }
        guard let text = String(data: data, encoding: .utf8) else { throw EngineError.other("read `\(path)`: stream did not contain valid UTF-8") }
        return try importDataSetsText(s, text, p)
    }

    /// The body of `file.import.variableDataSets` over CSV text already read: automation reads
    /// the file beneath its read root and hands the text over (#3216).
    static func importDataSetsText(_ s: Session, _ text: String, _ p: JSONValue) throws -> JSONValue {
        let delim = p["delimiter"]?.stringValue?.utf8.first.map { Unicode.Scalar($0) } ?? ","
        guard let vars = s.active?.doc.variables else { throw EngineError.noDocument }
        var records = csvRecords(text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }[...]
        let header = records.popFirst().map { splitCSV($0, delim) } ?? []
        if header.isEmpty { throw bad("file.import.variableDataSets", "empty CSV") }
        let named = header[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || header[0].lowercased() == "dataset"
        var sets: [DataSet] = []
        for (row, record) in records.enumerated() {
            let cells = splitCSV(record, delim)
            let name = named ? (cells.first.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "Data Set \(row + 1)") : "Data Set \(row + 1)"
            var values: [DataValue] = []
            for (ci, variable) in header.enumerated().dropFirst(named ? 1 : 0) {
                guard ci < cells.count, let def = vars.def(variable) else { continue }
                let cell = cells[ci]
                let value: VariableValue = switch def.kind {
                case .visibility: .visibility(["true", "1", "yes", "visible", "on"].contains(cell.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()))
                case .pixelReplacement: .pixels(cell)
                case .textReplacement: .text(cell)
                }
                values.append(DataValue(variable: variable, value: value))
            }
            sets.append(DataSet(name: name, values: values))
        }
        let n = sets.count
        try setVars(s) { $0.dataSets = sets }
        return ["imported": .int(n)]
    }

    /// Splits logical CSV records without changing line endings inside quoted fields.
    static func csvRecords(_ text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        var out: [String] = []
        var start = 0
        var quoted = false
        func string(_ r: Range<Int>) -> String {
            var v = String.UnicodeScalarView()
            v.append(contentsOf: scalars[r])
            return String(v)
        }
        for (i, c) in scalars.enumerated() {
            if c == "\"" {
                // An escaped quote pair toggles twice, leaving the surrounding state intact.
                quoted.toggle()
            } else if c == "\n" && !quoted {
                let end = i > start && scalars[i - 1] == "\r" ? i - 1 : i
                out.append(string(start..<end))
                start = i + 1
                quoted = false
            }
        }
        if start < scalars.count { out.append(string(start..<scalars.count)) }
        return out
    }

    /// Minimal CSV field splitter with double-quote support.
    static func splitCSV(_ line: String, _ delim: Unicode.Scalar) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        var inQuotes = false
        let s = Array(line.unicodeScalars)
        var i = 0
        while i < s.count {
            let c = s[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < s.count && s[i + 1] == "\"" {
                        cur.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    cur.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delim {
                out.append(String(cur))
                cur = String.UnicodeScalarView()
            } else {
                cur.append(c)
            }
            i += 1
        }
        out.append(String(cur))
        return out
    }

    /// `a` with `b`'s fields added.
    static func merged(_ a: [String: JSONValue], _ b: [String: JSONValue]) -> JSONValue {
        var o = a
        for (k, v) in b { o[k] = v }
        return .object(o)
    }

    static func list(_ s: Session) throws -> JSONValue {
        guard let v = s.active?.doc.variables else { throw EngineError.noDocument }
        return [
            "defs": .array(v.defs.map { d in merged(["name": .string(d.name), "layer": .id(d.layer)], kindJSON(d.kind)) }),
            "dataSets": .array(v.dataSets.map { ds in
                ["name": .string(ds.name), "values": .array(ds.values.map { dv in merged(["variable": .string(dv.variable)], valueJSON(dv.value)) })]
            }),
            "active": v.active.map { .int($0) } ?? .null,
        ]
    }

    // MARK: Registration

    public static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("image.variables.define", "Define…", menu: ["Image", "Variables"],
                        params: #"{defs:[{name, layer:id, type:visibility|textReplacement|pixelReplacement, method?:fit|fill|asIs|conform, align?, clip?}]} → {defs,dataSets,active}"#,
                        module: m, enabled: hasDoc, run: define),
            CommandSpec("image.variables.dataSets", "Data Sets…", menu: ["Image", "Variables"],
                        params: #"{dataSets:[{name, values:[{variable, kind:visibility|text|pixels, value}]}], append?} → {defs,dataSets,active}"#,
                        module: m, enabled: hasDoc, run: dataSets),
            CommandSpec("image.applyDataSet", "Apply Data Set…", menu: ["Image"],
                        params: #"{name|index} → {applied, index}: sets layer visibility/text/pixels from the data set (one history step)"#,
                        module: m, enabled: hasDoc, run: applyDataSet),
            CommandSpec("file.import.variableDataSets", "Variable Data Sets…", menu: ["File", "Import"],
                        params: #"{path, delimiter?} → {imported}: CSV header = variable names, each row a data set (first column may be the data-set name)"#,
                        module: m, enabled: hasDoc, run: importDataSets),
            CommandSpec("file.export.dataSetsAsFiles", "Data Sets as Files…", menu: ["File", "Export"],
                        params: #"{dir, format?:png, dataSets?[names], naming?:"{name}|{index}|{document}"} → {files,count}: apply each data set and export the flattened document; colliding filenames are rejected before writing (include {index} to disambiguate)"#,
                        module: m, enabled: hasDoc, run: exportAsFiles),
            CommandSpec("variables.list", "List Variables", params: "{} → {defs,dataSets,active}", module: m, journal: false, enabled: hasDoc) { s, _ in
                try list(s)
            },
        ])
    }
}

/// photocraft-engine's public `import_data_sets_text`: `file.import.variableDataSets` over CSV text
/// a host already read (automation reads it beneath its workspace root).
public enum VariableDataSets {
    public static func importText(_ s: Session, _ text: String, _ p: JSONValue) throws -> JSONValue {
        try VariablesCommands.importDataSetsText(s, text, p)
    }
}
