// Port of photocraft-engine (crates/engine/src/automate_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// File › Automate › Contact Sheet II and Create Droplet, File › Scripts › Statistics, Browse and
// Script Events Manager.
//
// "Scripts" are PhotoCraft action scripts: JSON (`[[id, params], …]`, `{"steps": …}` or a
// droplet) or a plain-text list with one `command.id {json params}` per line (`#` comments).
// Droplets are JSON files (`.pcdroplet`) holding an action plus batch options; `photocraft-cli
// droplet <file> <inputs…>` runs one, and on Unix a `.command` shim makes it double-clickable /
// drop-target-able from the shell.
//
// Script events (Start Application, New / Open / Save / Close Document, Print, Export) are bound
// in the preferences (`scriptEvents`) and fired by `fireEvent`: the engine fires New and Close
// itself (an `after` dispatch hook); Print and Export are fired by the commands that print and
// export, and the app shell fires Start, Open (`documentOpened`) and Save (`documentSaved`).

import Foundation
import PCDocument
import PCFoundation
import PCPlatform

public enum AutomateCommands: CommandModule {
    public static let name = "automate_cmds"
    static let m = name

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    // MARK: Session state

    /// The script-event bookkeeping of photocraft's `FileMenuState` (not saved, not history).
    struct EventState: Sendable {
        /// Results of the most recent script events (for inspection), newest last, capped at 32.
        var log: [JSONValue] = []
        /// Set while event scripts run, so their commands don't fire events recursively.
        var firing = false
    }

    enum EventStateKey: StateKey { static let defaultValue = EventState() }

    /// Results of the most recent script events, newest last (photocraft `FileMenuState::event_log`).
    public static func eventLog(_ s: Session) -> [JSONValue] { s.state[EventStateKey.self].log }

    // MARK: Scripts

    /// Parses an action script: JSON (array of steps, `{"steps"|"action": …}`, a droplet) or one
    /// `command.id {json}` per line (photocraft `parse_script`).
    public static func parseScript(_ text: String) throws -> [CommandInvocation] {
        let cmd = "file.scripts.browse"
        var u = Substring(text)
        while u.hasPrefix("\u{feff}") { u = u.dropFirst() }
        let t = u.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("[") || t.hasPrefix("{") {
            let v: JSONValue
            do { v = try JSONValue.parse(t) } catch { throw bad(cmd, "script JSON: \(error)") }
            return try parseAction(v, cmd)
        }
        var out: [CommandInvocation] = []
        for (n, raw) in t.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            let id: String, rest: String
            if let ws = line.firstIndex(where: \.isWhitespace) {
                id = String(line[..<ws])
                rest = line[line.index(after: ws)...].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                (id, rest) = (line, "")
            }
            var params: JSONValue = .object([:])
            if !rest.isEmpty {
                do { params = try JSONValue.parse(rest) } catch { throw bad(cmd, "line \(n + 1): \(error)") }
            }
            out.append(CommandInvocation(id, params))
        }
        return out
    }

    /// The steps of a JSON action: an array of steps (`[id, params]`, `{"command", "params"}` or a
    /// bare id), `{"steps"|"action": …}` (a recorded action) or a droplet. `cmd` names the caller
    /// in errors (photocraft `parse_action`).
    public static func parseAction(_ v: JSONValue, _ cmd: String) throws -> [CommandInvocation] {
        let steps: JSONValue
        switch v {
        case .array: steps = v
        case .object(let o):
            if let st = o["steps"] {
                steps = st
            } else if let a = o["action"] {
                steps = a["steps"] ?? a
            } else {
                throw bad(cmd, #"an action object needs "steps""#)
            }
        default: throw bad(cmd, "an action must be an array of steps or an object")
        }
        return try parseSteps(steps, cmd)
    }

    static func parseSteps(_ v: JSONValue, _ cmd: String) throws -> [CommandInvocation] {
        guard let arr = v.arrayValue else { throw bad(cmd, "steps must be an array") }
        return try arr.map { st in
            switch st {
            case .array(let a) where !a.isEmpty:
                guard let id = a[0].stringValue else { throw bad(cmd, "step id must be a string") }
                return CommandInvocation(id, a.count > 1 ? a[1] : .object([:]))
            case .object(let o):
                guard let id = (o["command"] ?? o["id"])?.stringValue else { throw bad(cmd, #"step needs "command""#) }
                return CommandInvocation(id, o["params"] ?? .object([:]))
            case .string(let id):
                return CommandInvocation(id, .object([:]))
            default:
                throw bad(cmd, #"each step is [id, params], {"command", "params"} or an id"#)
            }
        }
    }

    static func checkKnown(_ s: Session, _ steps: [CommandInvocation], _ cmd: String) throws {
        if let st = steps.first(where: { s.registry.spec($0.id) == nil }) { throw bad(cmd, "unknown command `\(st.id)` in the script") }
    }

    static func runSteps(_ s: Session, _ steps: [CommandInvocation]) -> [JSONValue] {
        var results: [JSONValue] = []
        for st in steps {
            do {
                let r = try s.execute(st.id, st.params)
                // A called action reports a failed step inside a success; it stops the script too.
                if let error = ActionsCommands.nestedFailure(st.id, r) {
                    results.append(["command": .string(st.id), "result": r, "error": .string(error)])
                    break
                }
                results.append(["command": .string(st.id), "result": r])
            } catch {
                results.append(["command": .string(st.id), "error": .string(EngineError.wrap(error).description)])
                break
            }
        }
        return results
    }

    /// File › Scripts › Browse…: runs a script file on the session.
    static func browse(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.scripts.browse"
        let steps: [CommandInvocation]
        if let path = p["path"]?.stringValue {
            steps = try parseScript(String(decoding: try FileCommands.readFile(s, path), as: UTF8.self))
        } else if let text = p["script"]?.stringValue {
            steps = try parseScript(text)
        } else if let v = p["steps"] {
            steps = try parseSteps(v, cmd)
        } else {
            throw bad(cmd, #"give "path" (a script file), "script" (its text) or "steps""#)
        }
        try checkKnown(s, steps, cmd)
        let results = runSteps(s, steps)
        let ok = results.allSatisfy { $0["error"] == nil }
        return ["steps": .int(steps.count), "ok": .bool(ok), "results": .array(results)]
    }

    // MARK: Script Events Manager

    /// Events a script can be bound to (Photoshop's Script Events Manager list).
    public static let events: [(id: String, label: String)] = [
        ("startApplication", "Start Application"), ("newDocument", "New Document"), ("openDocument", "Open Document"),
        ("saveDocument", "Save Document"), ("closeDocument", "Close Document"), ("print", "Print Document"), ("export", "Export Document"),
        ("everything", "Everything"),
    ]

    /// One event → script binding.
    public struct ScriptBinding: Hashable, Sendable, Codable {
        public var event = ""
        /// A script file (see `parseScript`).
        public var script: String?
        /// Or inline steps (an action).
        public var steps: JSONValue?
        /// Display name (the action's name).
        public var name = ""

        public init(event: String, script: String?, steps: JSONValue?, name: String) {
            self.event = event
            self.script = script
            self.steps = steps
            self.name = name
        }

        enum CodingKeys: String, CodingKey { case event, script, steps, name }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            event = try c.decodeIfPresent(String.self, forKey: .event) ?? ""
            script = try c.decodeIfPresent(String.self, forKey: .script)
            steps = try c.decodeIfPresent(JSONValue.self, forKey: .steps).flatMap { $0 == .null ? nil : $0 }
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(event, forKey: .event)
            try c.encode(script.map(JSONValue.string) ?? .null, forKey: .script)
            try c.encode(steps ?? .null, forKey: .steps)
            try c.encode(name, forKey: .name)
        }
    }

    /// Preferences › Script Events Manager.
    public struct ScriptEvents: Hashable, Sendable, Codable {
        /// "Enable Events to Run Scripts/Actions".
        public var enabled = false
        public var bindings: [ScriptBinding] = []

        public init(enabled: Bool = false, bindings: [ScriptBinding] = []) { self.enabled = enabled; self.bindings = bindings }

        enum CodingKeys: String, CodingKey { case enabled, bindings }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            bindings = try c.decodeIfPresent([ScriptBinding].self, forKey: .bindings) ?? []
        }
    }

    /// The preference key the bindings persist under (photocraft `Preferences::script_events`).
    static let prefsKey = "scriptEvents"

    /// The session's script events (photocraft `prefs().script_events`).
    public static func scriptEvents(_ s: Session) -> ScriptEvents {
        (try? s.preferences[prefsKey]?.decode(as: ScriptEvents.self)) ?? ScriptEvents()
    }

    /// Stores the script events in the preferences (persisted with them) and marks them dirty.
    static func storeScriptEvents(_ s: Session, _ ev: ScriptEvents) {
        s.preferences = Preferences(values: s.preferences.values.setting(prefsKey, .encoded(ev)))
        s.emit(.preferencesChanged)
    }

    static func scriptEventsManager(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.scripts.scriptEventsManager"
        let current = scriptEvents(s)
        var ev = current
        if let b = p["enabled"]?.boolValue { ev.enabled = b }
        if p["removeAll"]?.boolValue == true { ev.bindings.removeAll() }
        if let i = Params.int(p, "remove"), i >= 0 {
            if i >= ev.bindings.count { throw bad(cmd, "no binding \(i)") }
            ev.bindings.remove(at: i)
        }
        // The dialog's flat form: "event" + "script" at the top level means add.
        var flat: JSONValue?
        if let e = p["event"]?.stringValue, let script = p["script"]?.stringValue, !script.isEmpty {
            flat = ["event": .string(e), "script": .string(script), "name": p["name"] ?? .null]
        }
        if let a = p["add"] ?? flat {
            guard let event = a["event"]?.stringValue else { throw bad(cmd, #"add needs "event""#) }
            if !events.contains(where: { $0.id == event }) {
                throw bad(cmd, "unknown event `\(event)` (\(events.map(\.id).joined(separator: "|")))")
            }
            let script = a["script"]?.stringValue
            let steps = a["steps"]
            if script == nil && steps == nil { throw bad(cmd, #"add needs "script" (a file) or "steps" (an action)"#) }
            if let st = steps { try checkKnown(s, try parseSteps(st, cmd), cmd) }
            let name = a["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? script.map(FileCommands.fileName) ?? "Action"
            ev.bindings.append(ScriptBinding(event: event, script: script, steps: steps, name: name))
            if a["enable"]?.boolValue ?? true { ev.enabled = true }
        }
        if ev != current { storeScriptEvents(s, ev) }
        let list: [JSONValue] = events.map { ["id": .string($0.id), "label": .string($0.label)] }
        return ["enabled": .bool(ev.enabled), "bindings": .encoded(ev.bindings), "events": .array(list)]
    }

    /// Runs the scripts bound to `event` (when Script Events are enabled). Returns how many ran
    /// (photocraft `fire_event`). Print and export commands call it with `"print"` / `"export"`.
    @discardableResult
    public static func fireEvent(_ s: Session, _ event: String) -> Int {
        if s.state[EventStateKey.self].firing { return 0 }
        let ev = scriptEvents(s)
        if !ev.enabled { return 0 }
        let jobs = ev.bindings.filter { $0.event == event || $0.event == "everything" }
        if jobs.isEmpty { return 0 }
        s.state[EventStateKey.self].firing = true
        for b in jobs {
            let entry: JSONValue
            do {
                let steps: [CommandInvocation]
                if let st = b.steps {
                    steps = try parseSteps(st, "scriptEvent")
                } else if let path = b.script {
                    steps = try parseScript(String(decoding: try FileCommands.readFile(s, path), as: UTF8.self))
                } else {
                    steps = []
                }
                entry = ["event": .string(event), "binding": .string(b.name), "results": .array(runSteps(s, steps))]
            } catch {
                entry = ["event": .string(event), "binding": .string(b.name), "error": .string(EngineError.wrap(error).description)]
            }
            s.state[EventStateKey.self].log.append(entry)
        }
        let n = s.state[EventStateKey.self].log.count
        if n > 32 { s.state[EventStateKey.self].log.removeFirst(n - 32) }
        s.state[EventStateKey.self].firing = false
        return jobs.count
    }

    /// After every successful command: fires the engine-side script events (photocraft
    /// `after_command`; its slice refresh is SliceCommands' own hook).
    static func afterCommand(_ s: Session, _ id: String) {
        switch id {
        case "file.new": fireEvent(s, "newDocument")
        case "file.close", "file.closeAll", "file.closeOthers": fireEvent(s, "closeDocument")
        default: break
        }
    }

    /// App shell hook: a document was opened.
    public static func documentOpened(_ s: Session) { fireEvent(s, "openDocument") }

    /// After the shell saved document `index`: Save Document scripts (photocraft
    /// `document_saved`; its File › Generate › Image Assets half belongs to WebCommands).
    @discardableResult
    public static func documentSaved(_ s: Session, _ index: Int) -> JSONValue? {
        fireEvent(s, "saveDocument")
        return WebCommands.onSaved(s, index)
    }

    // MARK: Create Droplet

    static func createDroplet(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.automate.createDroplet"
        guard let given = p["path"]?.stringValue, !given.isEmpty else { throw bad(cmd, #"missing "path" (where to save the droplet)"#) }
        guard let stepsValue = p["steps"] ?? p["action"] else { throw bad(cmd, #"missing "steps" (the action to run)"#) }
        var steps = try parseSteps(stepsValue, cmd)
        // The droplet's output folder replaces recorded saves, and view steps don't apply, as in batch.
        steps.removeAll { ActionsCommands.shellSaveCommand($0.id) || ActionsCommands.shellViewCommand($0.id) }
        try checkKnown(s, steps, cmd)
        // Play Action steps need their actions when the droplet runs on its own (#2794). Not under
        // `actions`: the CLI reads that key as an action set.
        let called = ActionsCommands.calledActions(ActionsCommands.state(s).list, &steps)
        let path = given.hasSuffix(".pcdroplet") || given.hasSuffix(".json") ? given : "\(given).pcdroplet"
        let name = p["name"]?.stringValue ?? FileCommands.stem(path)
        let stepsJSON: [JSONValue] = steps.map { [.string($0.id), $0.params] }
        var options: [String: JSONValue] = [:]
        for k in ["output", "format", "quality", "suffix", "overrideOpen"] { if let v = p[k] { options[k] = v } }
        var droplet: JSONValue = [
            "photocraftDroplet": 1, "name": .string(name), "action": ["name": .string(name), "steps": .array(stepsJSON)], "options": .object(options),
        ]
        if !called.isEmpty { droplet = droplet.setting("calledActions", .encoded(called)) }
        try FileCommands.writeFile(s, path, Array(droplet.serialized(pretty: true).utf8))
        let shim = p["shim"]?.boolValue ?? true // every platform PCEngine runs on is Unix
        let shimPath = shim ? try writeShim(s, path) : nil
        return ["path": .string(path), "shim": shimPath.map(JSONValue.string) ?? .null, "steps": .int(steps.count)]
    }

    /// The absolute, symlink-free form of `path` (Rust `std::fs::canonicalize`), nil when it
    /// can't be resolved.
    static func canonicalPath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// A tiny shell script next to the droplet: drop files on it (or pass them) to run the droplet.
    static func writeShim(_ s: Session, _ droplet: String) throws -> String {
        let local = s.services.fileSystem is LocalFileSystem
        let abs = (local ? canonicalPath(droplet) : nil) ?? droplet
        var base = Substring(abs)
        while base.hasSuffix(".pcdroplet") { base = base.dropLast(".pcdroplet".count) }
        while base.hasSuffix(".json") { base = base.dropLast(".json".count) }
        let shim = "\(base).command"
        // Single quotes keep shell expansions inert; embedded quotes end the quoted segment, emit
        // a literal quote, then resume it.
        let quoted = "'\(abs.replacingOccurrences(of: "'", with: "'\\''"))'"
        let body = "#!/bin/sh\n# PhotoCraft droplet: runs the action on the files given (or dropped).\nexec \"${PHOTOCRAFT_CLI:-photocraft-cli}\" droplet \(quoted) \"$@\"\n"
        try FileCommands.writeFile(s, shim, Array(body.utf8))
        if local { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim) }
        return shim
    }

    /// Runs a droplet file on inputs (files and/or folders).
    static func runDroplet(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.automate.runDroplet"
        guard let path = (p["droplet"] ?? p["path"])?.stringValue else { throw bad(cmd, #"missing "droplet""#) }
        let v: JSONValue
        do { v = try JSONValue.parse(Data(try FileCommands.readFile(s, path))) } catch let e as EngineError { throw e } catch {
            throw bad(cmd, "\(path): \(error)")
        }
        if v["photocraftDroplet"] == nil { throw bad(cmd, "\(path) is not a PhotoCraft droplet") }
        guard let steps = v["action"]?["steps"] else { throw bad(cmd, "droplet has no action") }
        let opts = v["options"] ?? .object([:])
        let raw: [String]
        switch p["input"] ?? p["files"] {
        case .array(let a)?: raw = a.compactMap(\.stringValue)
        case .string(let one)?: raw = [one]
        default: throw bad(cmd, #"missing "input" (files or folders)"#)
        }
        var inputs: [String] = []
        for i in raw {
            if s.services.fileSystem.isDirectory(i) { inputs += try FileCommands.listImages(s, i) } else { inputs.append(i) }
        }
        guard let first = inputs.first else { throw bad(cmd, "no input images") }
        let output = (p["output"] ?? opts["output"])?.stringValue
            ?? FileCommands.join((first as NSString).deletingLastPathComponent, "droplet-output")
        var bp: JSONValue = ["steps": steps, "input": .strings(inputs), "output": .string(output), "format": opts["format"] ?? "same"]
        if let q = opts["quality"] { bp = bp.setting("quality", q) }
        if let called = v["calledActions"] { bp = bp.setting("calledActions", called) }
        let r = try s.execute("file.automate.batch", bp)
        return ["droplet": .string(path), "output": .string(output), "files": r["files"] ?? .null, "errors": r["errors"] ?? .null]
    }

    // MARK: Statistics

    static func statistics(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.scripts.statistics"
        let mode = (p["mode"] ?? p["stackMode"])?.stringValue ?? "median"
        guard let sm = StackMode.all.first(where: { $0.id.caseInsensitiveCompare(mode) == .orderedSame }) else {
            throw bad(cmd, "unknown stack mode `\(mode)`")
        }
        guard let input = p["input"] ?? p["paths"] else { throw bad(cmd, #"missing "input" (files or a folder)"#) }
        let align = p["align"]?.boolValue ?? false
        let r = try s.execute("file.scripts.loadFilesIntoStack", ["paths": input, "createSmartObject": .bool(!align)])
        let n = r["layers"]?.uint64Value ?? 0
        if align && n > 1 {
            try s.execute("select.allLayers")
            try s.execute("edit.autoAlignLayers", ["projection": "auto"])
            let name = s.active?.doc.name ?? ""
            try s.edit("Convert to Smart Object") { doc, active in
                let layers = doc.layers
                let smart = try FileCommands.layersToSmart(s, doc, name, layers)
                active = smart.id
                doc.layers = [smart]
            }
            try? s.updateActive { st in st.selectedLayerIds = st.activeLayer.map { [$0] } ?? [] }
        }
        guard let id = s.active?.doc.layers.first?.id else { throw EngineError.noDocument }
        try s.selectLayer(id)
        try s.execute("layer.smartObjects.stackMode.\(sm.id)", ["layer": .id(id)])
        return ["document": s.activeIndex.map { .int($0) } ?? .null, "layer": .id(id), "images": .int(n), "mode": .string(sm.id)]
    }

    // MARK: Contact Sheet II

    static func unitsPx(_ v: Double, _ unit: String, _ res: Double) -> Double {
        switch unit {
        case "cm": v * res / 2.54
        case "mm": v * res / 25.4
        case "px", "pixels": v
        default: v * res
        }
    }

    static func contactSheet(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.automate.contactSheetII"
        let files: [String]
        switch p["input"] ?? p["files"] {
        case .array(let a)?: files = a.compactMap(\.stringValue)
        case .string(let dir)?: files = try FileCommands.listImages(s, dir)
        default: throw bad(cmd, #"missing "input" (a folder or an array of files)"#)
        }
        if files.isEmpty { throw bad(cmd, "no images to place") }
        func f(_ k: String, _ d: Double) -> Double { p[k]?.doubleValue.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? d }
        func side(_ v: Double) -> Int { Int(min(max(v.rounded(), 16), 30_000)) }
        let unit = p["units"]?.stringValue ?? "inches"
        let res = min(max(f("resolution", 300), 1), 10_000)
        let pw = side(unitsPx(f("width", 8), unit, res))
        let ph = side(unitsPx(f("height", 10), unit, res))
        let cols = Int(min(max(f("columns", 5).rounded(), 1), 100))
        let rows = Int(min(max(f("rows", 6).rounded(), 1), 100))
        let auto = p["autoSpacing"]?.boolValue ?? true
        let gap = max(Double(min(pw, ph)) * 0.014, 2)
        let hs = auto ? gap : (p["horizontal"]?.doubleValue.map { unitsPx($0, unit, res) } ?? gap)
        let vs = auto ? gap : (p["vertical"]?.doubleValue.map { unitsPx($0, unit, res) } ?? gap)
        let across = p["placeAcrossFirst"]?.boolValue ?? true
        let rotate = p["rotateForBestFit"]?.boolValue ?? false
        let caption = p["caption"]?.boolValue ?? true
        let font = p["font"]?.stringValue ?? FontCatalog.defaultFamily
        let fontPt = f("fontSize", 12)
        let flatten = p["flatten"]?.boolValue ?? false
        let mode = p["mode"]?.stringValue ?? "rgb"
        let depth = Params.int(p, "depth") ?? 8
        let captionPx = caption ? fontPt * res / 72 * 1.5 : 0
        let cellW = max((Double(pw) - Double(cols + 1) * hs) / Double(cols), 1)
        let cellH = max((Double(ph) - Double(rows + 1) * vs) / Double(rows), 1)
        let boxH = max(cellH - captionPx, 1)
        let perPage = cols * rows
        var docs: [Int] = []
        var placed = 0
        var errors: [JSONValue] = []
        for (page, start) in stride(from: 0, to: files.count, by: perPage).enumerated() {
            let chunk = files[start ..< min(start + perPage, files.count)]
            let name = files.count > perPage ? String(format: "ContactSheet-%03d", page + 1) : "ContactSheet-001"
            try s.execute("file.new", ["width": .int(pw), "height": .int(ph), "mode": .string(mode), "depth": .int(depth), "background": "white",
                                       "name": .string(name)])
            guard let idx = s.activeIndex else { throw EngineError.noDocument }
            try s.updateActive { $0.doc.resolutionDpi = Float(res) }
            guard let fmt = s.active?.doc.pixelFormat else { throw EngineError.noDocument }
            for (k, path) in chunk.enumerated() {
                let (c, r) = across ? (k % cols, k / cols) : (k / rows, k % rows)
                let x0 = hs + Double(c) * (cellW + hs)
                let y0 = vs + Double(r) * (cellH + vs)
                let surf: Surface
                do {
                    surf = try thumbnail(s, path, fmt, x0: x0, y0: y0, cellW: cellW, boxH: boxH, rotate: rotate)
                } catch {
                    errors.append(["file": .string(path), "error": .string(EngineError.wrap(error).description)])
                    continue
                }
                let label = FileCommands.stem(path)
                try s.edit("Contact Sheet") { doc, active in
                    let l = Layer(name: label, content: .raster(surf))
                    active = l.id
                    doc.layers.append(l)
                }
                placed += 1
                if caption {
                    let baseline = y0 + boxH + captionPx * 0.72
                    try s.execute("type.create", ["x": .number(x0 + cellW / 2), "y": .number(baseline), "text": .string(label), "font": .string(font),
                                                  "size": .number(fontPt), "align": "center", "color": [0.0, 0.0, 0.0], "name": .string(label)])
                }
            }
            if flatten { try s.execute("layer.flattenImage") }
            docs.append(idx)
        }
        return ["documents": .array(docs.map { .int($0) }), "pages": .int(docs.count), "images": .int(placed), "errors": .array(errors),
                "width": .int(pw), "height": .int(ph)]
    }

    /// One contact-sheet cell: the file opened in a scratch session, turned when that fits better,
    /// resized to fit the cell and placed centred in it, as a surface in the sheet's format.
    static func thumbnail(_ s: Session, _ path: String, _ fmt: PixelFormat, x0: Double, y0: Double, cellW: Double, boxH: Double,
                          rotate: Bool) throws -> Surface {
        let bytes = try FileCommands.readFile(s, path)
        let src = try FileCommands.import(s, FileCommands.fileName(path), bytes)
        let t = FileCommands.scratchSession(s)
        t.addDocument(src)
        func size() -> (Double, Double) { t.active.map { (Double($0.doc.size.width), Double($0.doc.size.height)) } ?? (1, 1) }
        func fit(_ w: Double, _ h: Double) -> Double { min(cellW / w, boxH / h) }
        var (w, h) = size()
        if rotate && fit(h, w) > fit(w, h) * 1.001 { try t.execute("image.imageRotation.90cw") }
        (w, h) = size()
        let k = fit(w, h)
        let (tw, th) = (max((w * k).rounded(), 1), max((h * k).rounded(), 1))
        try t.execute("image.imageSize", ["width": .number(tw), "height": .number(th), "resample": "bicubic"])
        guard let d = t.active?.doc else { throw EngineError.noDocument }
        let buf = try s.services.renderer.render(d, region: d.bounds)
        let ox = FileCommands.clampI32(x0 + (cellW - tw) / 2), oy = FileCommands.clampI32(y0 + (boxH - th) / 2)
        let rect = PixelRect(x0: ox, y0: oy, x1: ox &+ Int32(d.size.width), y1: oy &+ Int32(d.size.height))
        var surf = Surface(format: fmt)
        if buf.px.count == rect.width * rect.height { surf.writeRegion(rect, PixelCodec.fromRGBA(fmt, rgba: buf.px)) }
        return surf
    }

    // MARK: Registration

    public static func register(into r: inout CommandRegistry) {
        r.hooks.after.append { s, id, _ in afterCommand(s, id) }
        let native = FileCommands.native
        r.add([
            CommandSpec("file.automate.contactSheetII", "Contact Sheet II…", menu: ["File", "Automate"],
                        params: #"{"input":folder|[paths],"units":"inches|cm|mm|pixels"="inches","width":8,"height":10,"resolution":ppi=300,"mode":"rgb|gray|cmyk|lab"="rgb","depth":8|16=8,"columns":5,"rows":6,"placeAcrossFirst":bool=true,"autoSpacing":bool=true,"horizontal":units?,"vertical":units?,"rotateForBestFit":bool=false,"caption":bool=true (file name as caption),"font":family?,"fontSize":pt=12,"flatten":bool=false} → {documents, pages, images}"#,
                        module: m, enabled: native, run: contactSheet),
            CommandSpec("file.automate.createDroplet", "Create Droplet…", menu: ["File", "Automate"],
                        params: #"{"path":str (.pcdroplet),"steps":[[id,params]…] (the action),"name":str?,"output":folder?,"format":"same|png|jpg|…"?,"quality":0..12?,"shim":bool=true on Unix (writes <name>.command calling `photocraft-cli droplet`)} → {path, shim} (the actions its Play Action steps call are saved in the droplet)"#,
                        module: m, enabled: native, run: createDroplet),
            CommandSpec("file.automate.runDroplet", "Run Droplet",
                        params: #"{"droplet":path,"input":[files or folders],"output":folder? (default: droplet's, else <input folder>/droplet-output)} → {files, errors} (an input whose output name was already written in the run goes to errors)"#,
                        module: m, enabled: native, run: runDroplet),
            CommandSpec("file.scripts.statistics", "Statistics…", menu: ["File", "Scripts"],
                        params: #"{"mode":"mean|median|maximum|minimum|range|summation|variance|standardDeviation|skewness|kurtosis|entropy"="median","input":folder|[paths],"align":bool=false (Auto-Align first)} → new document with one stack-mode smart object"#,
                        module: m, enabled: native, run: statistics),
            CommandSpec("file.scripts.browse", "Browse…", menu: ["File", "Scripts"],
                        params: #"{"path":script file | "script":text | "steps":[[id,params]…]} (JSON action, or one `command.id {json}` per line) → {steps, ok, results}"#,
                        module: m, run: browse),
            CommandSpec("file.scripts.scriptEventsManager", "Script Events Manager…", menu: ["File", "Scripts"],
                        params: #"{"enabled":bool?,"add":{"event":"startApplication|newDocument|openDocument|saveDocument|closeDocument|print|export|everything","script":path?|"steps":[…]?,"name":str?}?,"remove":index?,"removeAll":bool?} → {enabled, bindings, events}"#,
                        module: m, run: scriptEventsManager),
        ])
    }
}
