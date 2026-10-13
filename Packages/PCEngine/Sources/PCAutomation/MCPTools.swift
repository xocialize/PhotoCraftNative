// Port of photocraft-automation (crates/automation/src/server.rs: the `#[tool]` set and its parameter structs, `strict_schema`; server/conventions.rs `annotated` and the argument checks), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The tool list with photocraft's names, descriptions and parameter docs. Schemas are written in
// the strict subset (what photocraft's `strict_schema` reduces schemars output to: no `$ref` or
// `$defs`, no boolean schemas), and every tool is annotated as conventions.rs does it: a title
// from the name, read-only / destructive / idempotent / open-world hints, and
// `additionalProperties: false`. `validate` is serde's `deny_unknown_fields` plus the field types.

import Foundation
import MCP
import PCDocument
import PCEngine

enum MCPTools {
    // MARK: Schema pieces

    static func prop(_ type: JSONValue, _ description: String? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["type": type]
        if let description { o["description"] = .string(description) }
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    /// An optional field (`Option<T>` with `#[serde(default)]`): its type or null.
    static func opt(_ type: String, _ description: String? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
        prop(.array([.string(type), "null"]), description, extra: extra)
    }

    static let u32: [String: JSONValue] = ["minimum": 0, "maximum": .number(Double(UInt32.max))]
    static let u8: [String: JSONValue] = ["minimum": 0, "maximum": 255]
    static let uint: [String: JSONValue] = ["minimum": 0]

    static let indexDoc = "Document index from `session_list` (default: the active document)."
    static let readPathDoc = "Path beneath the configured automation read root: relative (forward slashes) or absolute."
    static let index = opt("integer", indexDoc, extra: uint)

    static func object(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
        var o: [String: JSONValue] = ["type": "object", "properties": .object(props), "additionalProperties": false]
        if !required.isEmpty { o["required"] = .strings(required) }
        return .object(o)
    }

    /// `RunParams` (a `command_run` call, a `command_batch` step).
    static let runParams = object([
        "id": prop("string", "Command id, e.g. `layer.new.layer`, `filter.blur.gaussianBlur`."),
        "params": ["description": "Command parameters as a JSON object (see the `params` doc in `command_list`)."],
        "wait": opt("boolean", "Wait for a long command (filters, Content-Aware Fill, Photomerge, …) to finish (default true). With false it runs as a background job and the result is `{\"job\": id}`: poll it with `jobs_list`, stop it with `jobs_cancel`."),
    ], required: ["id"])

    static let saveParams = object([
        "path": opt("string", "Target beneath the configured automation write root: relative (forward slashes) or absolute. The extension selects the format. Omit to write back to the document's own file, which works only for a PSD, PSB or .pcraft file kept in its own format; any other save needs `path`, so a flattened or converted copy never replaces the opened file."),
        "format": opt("string", "Format override as an extension (pcraft, psd, png, jpg, tif, webp, exr, …)."),
        "quality": opt("integer", "JPEG or WebP quality 1..100. A WebP saved with a quality is lossy; without one it is lossless.", extra: u8),
        "tiffLayers": prop("boolean", "TIFF: keep the layers (Photoshop layer data). Off by default: a flat TIFF.", extra: ["default": false]),
        "tgaBits": opt("integer", "TGA: 24 or 32 bits per pixel. 32 writes the alpha channel (or else the transparency) as the alpha, 24 none. Unset: 32 with an alpha channel or transparency, else 24.", extra: u8),
        "index": opt("integer", nil, extra: uint),
    ])

    static let previewParams = object([
        "index": opt("integer", "Headless mode only: document index (default: the active document). Bridge previews capture the app window and reject `index`.", extra: uint),
        "max_side": opt("integer", "Longest side of a headless preview (default 1024, maximum 2048). Zero requests full size within that ceiling. Bridge mode returns the window screenshot.", extra: u32),
    ])

    static let pointerEvent = object([
        "kind": opt("string", "`down`, `move` (default) or `up`.", extra: ["enum": ["down", "move", "up", .null]]),
        "x": prop("number", "Document x in pixels."),
        "y": prop("number", "Document y in pixels."),
        "pressure": opt("number", "Pen pressure 0..1 (default 1)."),
        "tiltX": opt("number", "A simulated pen's tilt, as a stylus reports it."),
        "tiltY": opt("number"),
        "rotation": opt("number", "A simulated pen's barrel rotation."),
    ], required: ["x", "y"])

    static let uiSetFieldsDoc = "Fields for the control method `ui.set`: tool, panels, dock, dockTabs, dockWidth, colorPanel ({background: bool} picks which swatch the Color panel edits), maskTarget, vectorMaskTarget, selectionMode, zoom, center, rotation (view angle in degrees), fit, theme (pro, proMedium, studio, studioLight, classic, solarizedDark, adwaita, adwaitaDark, breezeLight, breezeDark), brushSection, brushTab, brushesView, brushPicker ([x, y] opens the Brush Preset picker there, null closes it), brushPickerName, brushPickerStroke, brushPickerTip (the picker card's parts, at least one on), brushPickerScale (the picker footer's card-scale slider, 0.15 to 2, 1 the standard), brushSize, gradientBlendMode (a blend mode name, for the Gradient tool), gradientClassic (bool), eyedropperSampleSize (\"point\" or 1, 3, 5, 11, 31, 51, 101), eyedropperSample (current, currentAndBelow, all, allNoAdjustments, currentAndBelowNoAdjustments), eyedropperRing (bool), cropOverlay (thirds, grid, diagonal, triangle, goldenRatio, goldenSpiral), cropOverlayShow (auto, always, never), cropOverlayOrientation (0..3), cropShield (an object patching show_cropped_area, enabled, color (\"matchCanvas\" or \"custom\"), custom_color ([r, g, b]), opacity (0..100), auto_adjust, classic_mode and auto_center_preview), shapeStroke (an object patching width, align, cap, join, miterLimit, dashes, dashOffset and opacity; null disables the stroke). Shape stroke fields use `shape.edit` names and units; colour comes from `tools.setColors`. camTransformOnDrop (bool, the Content-Aware Move tool's Transform On Drop). Other fields are an error."

    // MARK: Tools

    /// (name, description, input schema) in photocraft's router order.
    static let definitions: [(String, String, JSONValue)] = [
        ("session_list", "List open documents (index, name, size, dirty) and the active index.", object([:])),
        ("doc_open", "Open an image or document file and make it active. Returns index, size and import warnings.",
         object(["path": prop("string", readPathDoc)], required: ["path"])),
        ("doc_place", "Place a file into the document as a Smart Object layer (Place Embedded), reading `path` beneath the read root. `scale` (percent), `fit` and `center` are the command's own.",
         object([
             "path": prop("string", readPathDoc), "index": index,
             "scale": opt("number", "Scale as a percentage; defaults to fitting a file larger than the canvas."),
             "fit": opt("boolean", "Place at a centred size instead of a scaled one."),
             "center": prop(.array(["array", "null"]), "Centre of the placed layer, in document pixels.",
                            extra: ["items": ["type": "number"], "minItems": 2, "maxItems": 2]),
         ], required: ["path"])),
        ("doc_export_layers", "Export each exported layer of the document as its own file beneath the write root (the capability-scoped Layers to Files). A file that already exists is an error, not an overwrite.",
         object([
             "dir": prop("string", "Directory beneath the configured automation write root: relative (forward slashes) or absolute."), "index": index,
             "format": opt("string", "Export format (default png)."), "prefix": opt("string", "Filename prefix (default: the document name)."),
             "visible_only": opt("boolean", "Export only the layers that are visible (default true)."),
             "quality": opt("number", "Encoder quality, 0..12, for the formats that take one."),
         ], required: ["dir"])),
        ("doc_export_data_sets", "Export every data set of the document as its own flattened file beneath the write root (the capability-scoped Export Data Sets). The batch is planned first, so colliding filenames are refused before any file is written.",
         object([
             "dir": prop("string", "Directory beneath the configured automation write root: relative (forward slashes) or absolute."), "index": index,
             "format": opt("string", "Export format (default png)."),
             "data_sets": prop(.array(["array", "null"]), "Only these data sets, by name; default every one of them.", extra: ["items": ["type": "string"]]),
             "naming": opt("string", "Filename template with `{name}`, `{index}` and `{document}` (default `{name}`)."),
         ], required: ["dir"])),
        ("doc_import_data_sets", "Import a data set CSV from the read root into the document (the capability-scoped Import Variable Data Sets).",
         object(["path": prop("string", readPathDoc), "index": index, "delimiter": opt("string", "Field delimiter (default `,`).")], required: ["path"])),
        ("doc_new", "Create a new document (defaults: 1920x1080 RGB 8-bit white).",
         object([
             "width": opt("integer", nil, extra: u32), "height": opt("integer", nil, extra: u32), "mode": opt("string", "rgb | gray | cmyk | lab"),
             "depth": opt("integer", "8 | 16 | 32", extra: u32), "background": opt("string", "white | black | transparent | #rrggbb"), "name": opt("string"),
         ])),
        ("doc_save", "Save the document. `.pcraft` is the lossless native format (incremental); other extensions (psd, png, jpg, tif, webp, exr, …) export. Without `path` only a PSD, PSB or .pcraft document is written back to its own file. Returns warnings about anything the format cannot hold.",
         saveParams),
        ("doc_export", "Export the document to another format (same as doc_save with an explicit path/format).", saveParams),
        ("doc_inspect", "Document state as JSON: layer tree (top to bottom), history, selection, active layer.", object(["index": index])),
        ("doc_render_preview", "Render the flattened document and return it as a PNG image (bridge mode: window screenshot).", previewParams),
        ("render_preview", "Render a bounded flattened PNG preview (bridge mode: app window screenshot).", previewParams),
        ("doc_select", "Make the document at `index` active.", object(["index": prop("integer", nil, extra: uint)], required: ["index"])),
        ("doc_close", "Close a document (default: the active one) without saving.", object(["index": index])),
        ("command_list", "List engine commands: id, label, menu path, shortcut, parameter doc, enabled now. `disabledReason` says why a command is off (null when enabled); `needsDocument` is true when it is off because no document is open: create or open one first (doc_new, doc_open).",
         object([
             "filter": opt("string", "Only commands whose id or label contains this text (case-insensitive)."),
             "enabled_only": opt("boolean", "Only commands that can run right now."),
         ])),
        ("command_run", "Run an engine command by id with JSON params (see command_list). Returns the command's JSON result. Long commands (filters, Content-Aware Fill/Scale, Photomerge, brush import) wait to finish unless `wait` is false: then they run as a background job and the result is {job: id} (see jobs_list, jobs_cancel).",
         runParams),
        ("jobs_list", "List background jobs: running ones with progress (0-1), message and elapsed time, then the last few that ended (state done|failed|cancelled with their result or error). Finished jobs are applied first.",
         object([:])),
        ("jobs_cancel", "Cancel a background job by id (or every running job when `job` is omitted). The document is left unchanged.",
         object(["job": opt("integer", "The job id from `command_run` / `jobs_list` (omit to cancel every running job).", extra: uint)])),
        ("command_batch", "Run several engine commands in one call, in order (fewer round trips). Returns {completed, failed, results:[{ok, result|error}]}; stops at the first error unless stop_on_error is false. Not an atomic transaction: earlier successful steps stay applied (no rollback).",
         object([
             "steps": prop("array", "Commands to run in order: `[{\"id\": \"layer.new.layer\", \"params\": {\"name\": \"Ink\"}}, …]`. A step with `\"wait\": false` starts a long command as a background job (its result is `{\"job\": id}`, as in `command_run`); later steps that edit the same document fail until the job ends.",
                           extra: ["items": runParams]),
             "stop_on_error": opt("boolean", "Stop at the first failing step (default true)."),
         ], required: ["steps"])),
        ("ui_inspect", "Bridge mode: full UI state of the live app (tool, panels, views, dialogs, windows). For the menu tree, call `control_call` with method `ui.menu.list`.",
         object([:])),
        ("ui_screenshot", "Bridge mode: screenshot of the live app window as PNG.",
         object(["max_side": opt("integer", "Downscale the window screenshot to this longest side (maximum 2048). Omit or pass zero to keep the original size.", extra: u32)])),
        ("ui_pointer", "Bridge mode: send pointer events (document coordinates) to the active tool; with a Color Picker open they sample the image into it instead.",
         object([
             "events": prop("array", "Events in document coordinates: `[{\"kind\":\"down|move|up\",\"x\":..,\"y\":..,\"pressure\":..}]`.", extra: ["items": pointerEvent]),
             "modifiers": ["description": "Modifier keys, e.g. `{\"shift\":true}` (also `alt`, `command`, `ctrl`, `space`)."],
             "button": opt("string", "Mouse button: `left` (default), or `right` / `secondary`: with the Move tool or `{\"command\":true}` it opens the canvas layer menu, with a painting tool the Brush Preset picker."),
         ], required: ["events"])),
        ("ui_menu_invoke", "Bridge mode: activate a menu item by id.", object(["id": prop("string", "Menu item / command id.")], required: ["id"])),
        ("ui_set", "Bridge mode: change UI state (tool, panels, dock, zoom, center, fit, theme, brush settings; see `fields`). Unknown fields are an error.",
         object(["fields": ["description": .string(uiSetFieldsDoc)]], required: ["fields"])),
        ("control_call", "Bridge mode: call any control-protocol method (docs/control-protocol.md) with raw params.",
         object(["method": prop("string", "Any control-protocol method, e.g. `ui.dialog.open`."), "params": ["description": "Raw params (default {})."]], required: ["method"])),
    ]

    static let readOnly: Set<String> = ["command_list", "doc_inspect", "session_list", "render_preview", "doc_render_preview", "ui_inspect", "ui_screenshot"]
    static let additive: Set<String> = ["doc_new", "doc_open", "doc_place"]

    /// conventions.rs `annotated`: a title from the name and the four hints.
    static func annotated(_ name: String, _ description: String, _ schema: JSONValue) -> Tool {
        let words = name.replacingOccurrences(of: "_", with: " ")
        let title = words.prefix(1).uppercased() + words.dropFirst()
        let read = readOnly.contains(name)
        return Tool(name: name, title: title, description: description, inputSchema: MCPBridge.value(schema),
                    annotations: .init(title: title, readOnlyHint: read, destructiveHint: !read && !additive.contains(name), idempotentHint: read, openWorldHint: false))
    }

    static let all: [Tool] = definitions.map { annotated($0.0, $0.1, $0.2) }
    static let byName: [String: Tool] = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

    // MARK: Argument checks

    /// Refuses arguments a tool doesn't take (conventions.rs: "unknown argument `k` for tool")
    /// and arguments of the wrong shape (serde's errors), before anything runs.
    static func validate(_ tool: String, _ args: JSONValue, schema: JSONValue) throws {
        let props = schema["properties"]?.objectValue ?? [:]
        for key in (args.objectValue ?? [:]).keys.sorted() where props[key] == nil {
            throw MCPError.invalidParams("unknown argument `\(key)` for \(tool)")
        }
        if let problem = check(args, schema, path: nil) { throw MCPError.invalidParams(problem) }
    }

    /// The first way `v` doesn't fit `schema`, or nil.
    static func check(_ v: JSONValue, _ schema: JSONValue, path: String?) -> String? {
        let at = path.map { " for `\($0)`" } ?? ""
        var types: [String] = []
        if let t = schema["type"]?.stringValue { types = [t] }
        if let ts = schema["type"]?.arrayValue { types = ts.compactMap(\.stringValue) }
        if !types.isEmpty && !types.contains(where: { matches(v, $0, schema) }) {
            return "invalid type\(at): \(kind(v)), expected \(types.filter { $0 != "null" }.joined(separator: " or "))"
        }
        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(v) {
            return "unknown variant \(v.serialized())\(at), expected one of \(allowed.filter { $0 != .null }.map { $0.serialized() }.joined(separator: ", "))"
        }
        switch v {
        case .object(let o):
            let props = schema["properties"]?.objectValue ?? [:]
            if schema["additionalProperties"] == .bool(false) {
                for key in o.keys.sorted() where props[key] == nil {
                    return "unknown field `\(key)`, expected one of \(props.keys.sorted().map { "`\($0)`" }.joined(separator: ", "))"
                }
            }
            for req in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where o[req] == nil {
                return "missing field `\(req)`"
            }
            for (key, value) in o.sorted(by: { $0.key < $1.key }) {
                if let s = props[key], let p = check(value, s, path: path.map { "\($0).\(key)" } ?? key) { return p }
            }
        case .array(let a):
            if let n = schema["minItems"]?.intValue, a.count < n { return "invalid length \(a.count)\(at), expected \(n) items" }
            if let n = schema["maxItems"]?.intValue, a.count > n { return "invalid length \(a.count)\(at), expected \(n) items" }
            if let items = schema["items"] {
                for (i, x) in a.enumerated() {
                    if let p = check(x, items, path: "\(path ?? "")[\(i)]") { return p }
                }
            }
        default: break
        }
        return nil
    }

    static func matches(_ v: JSONValue, _ type: String, _ schema: JSONValue) -> Bool {
        switch (type, v) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object): return true
        case ("number", .number(let n)): return n.isFinite
        case ("integer", .number(let n)):
            guard n.isFinite, n == n.rounded() else { return false }
            if let lo = schema["minimum"]?.doubleValue, n < lo { return false }
            if let hi = schema["maximum"]?.doubleValue, n > hi { return false }
            return true
        default: return false
        }
    }

    static func kind(_ v: JSONValue) -> String {
        switch v {
        case .null: "null"
        case .bool(let b): "boolean `\(b)`"
        case .number(let n): n == n.rounded() && abs(n) < 9e15 ? "integer `\(Int(n))`" : "floating point `\(n)`"
        case .string(let s): "string \(JSONValue.string(s).serialized())"
        case .array: "sequence"
        case .object: "map"
        }
    }
}
