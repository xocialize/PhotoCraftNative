// Port of photocraft-cli (apps/photocraft-cli/src/lib.rs: USAGE, the subcommand table with strict flag parsing, `run_os`, `convert`, `info`, `run`, `batch` with `parse_actions` / `load_actions`, `droplet`, `commands`, `mcp`, `serve`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// `pccli` is the whole program as a function, so it is tested in-process as well as through the
// binary. Exit codes: 0 ok, 1 failure, 2 usage. pccli adds `control` (the stdio `serve` under the
// first port's name), `coverage` (command coverage against photocraft's catalogue) and
// `mcp --per-command-tools`.

import Foundation
import MCP
import PCDocument
import PCEngine
import PCPlatform

public enum CLI {
    public static let version = "0.1.0"

    public static let usage = """
        pccli: headless PhotoCraft (native port of photocraft-cli)

        USAGE:
          pccli convert <in> <out> [--format <ext>] [--quality <1-100>] [--in-place] [--tiff-layers] [--tga-bits <24|32>]
              Convert between formats (.psd, .psb, .pcraft, .ora, .tif, .png, .jpg, .webp, .exr, …).
              An <out> that is the <in> file is refused, as the result would replace the original;
              --in-place allows it.
              TIFF output is flat unless --tiff-layers keeps the layers (Photoshop layer data).
              --quality sets the JPEG or WebP quality; a WebP written with a quality is lossy, without one lossless.
              --tga-bits sets a TGA's bits per pixel: 32 writes the alpha channel (or else the transparency) as
              its alpha, 24 none. Without it: 32 with an alpha channel or transparency, else 24.
          pccli info <file> [--compact]
              Print the document as JSON (size, mode, depth, layer tree).
          pccli run (<file> | --new <json>) --cmd <id> [--params <json>] [--cmd …] [--out <file>] [--format <ext>] [--quality <1-100>] [--tiff-layers] [--tga-bits <24|32>]
              Open a file, run engine commands in order, save the result. Each --params
              applies to the preceding --cmd. Prints each command's JSON result.
          pccli batch --actions <actions.json> [--action <name>] --in <dir> --out <dir> [--format <ext>] [--quality <1-100>] [--in-place] [--tiff-layers] [--tga-bits <24|32>]
              Apply an action list to every image in a directory. Steps are [id, params] pairs,
              {"command": id, "params": {…}} objects or bare ids, as a recorded action or droplet stores them
              (a list, or wrapped in {"actions": …}, {"steps": …} or a droplet). An Actions set (the Actions
              panel's actions.json, {"actions": [{"name", "steps"}…]}) plays the action --action names (needed
              when the set holds more than one) with the whole set loaded, so its steps can play other actions
              of the set. An --out folder that is the --in folder is refused, as the results would replace
              the originals; --in-place allows it.
          pccli droplet <file.pcdroplet> <file-or-dir>… [--out <dir>]
              Run a droplet (File › Automate › Create Droplet) on images and folders.
          pccli commands [--json] [--filter <text>]
              List the engine command registry.
          pccli mcp [--bridge <127.0.0.1:port>] [--control-token <64-hex> | --control-token-file <path>]
              [--automation-read-root <dir>] [--automation-write-root <dir>] [--per-command-tools]
              Run the MCP server on stdio (headless engine, or bridge to a running `photocraft --control <port>`
              or `pccli serve --port <port>`). --per-command-tools also lists every command as its own tool.
          pccli serve [--port <port>] [--control-token <64-hex> | --control-token-file <path>]
              [--automation-read-root <dir>] [--automation-write-root <dir>]
              Keep one headless session open and answer JSON lines ({"id","method","params"}) on stdio,
              or on 127.0.0.1:<port>. Methods: engine.execute, jobs.list/cancel, engine.commands,
              doc.open/new/place/save/exportLayers/exportDataSets/importDataSets/inspect/render/select/close, session.list, batch, methods
              (docs/control-protocol.md#headless-server). `pccli control` is the same server.
          pccli coverage [--json|--markdown]
              Command coverage against photocraft's catalogue, per module.

          pccli <subcommand> --help (or -h) prints this text. A flag the subcommand doesn't take is
          an error.

        """

    /// Where output goes (stdout/stderr, or a test's buffers).
    public struct IO: Sendable {
        public var out: @Sendable (String) -> Void
        public var err: @Sendable (String) -> Void
        public init(out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void) { self.out = out; self.err = err }
        public static let standard = IO(out: { FileHandle.standardOutput.write(Data($0.utf8)) }, err: { FileHandle.standardError.write(Data($0.utf8)) })
    }

    struct Args {
        var positional: [String] = []
        var flags: [(String, String?)] = []
        func get(_ k: String) -> String? { flags.last { $0.0 == k }?.1 ?? nil }
        func has(_ k: String) -> Bool { flags.contains { $0.0 == k } }
    }

    /// A subcommand: the flags it reads (taking a value, or given bare). A flag outside these is a
    /// usage error, so a typo such as `--fromat` can't be silently ignored (#423).
    struct Subcommand {
        var name: String
        var values: Set<String>
        var bare: Set<String>
    }

    static let serverFlags: Set<String> = ["--port", "--control-token", "--control-token-file", "--automation-read-root", "--automation-write-root"]

    static let subcommands: [Subcommand] = [
        Subcommand(name: "convert", values: ["--format", "--quality", "--tga-bits"], bare: ["--in-place", "--tiff-layers"]),
        Subcommand(name: "info", values: [], bare: ["--compact"]),
        Subcommand(name: "run", values: ["--new", "--cmd", "--params", "--out", "--format", "--quality", "--tga-bits"], bare: ["--tiff-layers"]),
        Subcommand(name: "batch", values: ["--actions", "--action", "--in", "--out", "--format", "--quality", "--tga-bits"], bare: ["--in-place", "--tiff-layers"]),
        Subcommand(name: "droplet", values: ["--out"], bare: []),
        Subcommand(name: "commands", values: ["--filter"], bare: ["--json"]),
        Subcommand(name: "mcp", values: ["--bridge", "--control-token", "--control-token-file", "--automation-read-root", "--automation-write-root"],
                   bare: ["--per-command-tools"]),
        Subcommand(name: "serve", values: serverFlags, bare: []),
        Subcommand(name: "control", values: serverFlags, bare: []),
        Subcommand(name: "coverage", values: [], bare: ["--json", "--markdown"]),
    ]

    /// The subcommand's arguments, or nil when they ask for help (`--help` or `-h`).
    static func parse(_ sub: Subcommand, _ args: [String]) throws(EngineError) -> Args? {
        var a = Args()
        var i = 0
        while i < args.count {
            let s = args[i]
            if s == "--help" || s == "-h" { return nil }
            if s.hasPrefix("--"), let eq = s.firstIndex(of: "=") {
                let k = String(s[..<eq]), v = String(s[s.index(after: eq)...])
                if sub.bare.contains(k) { throw .other("\(k) takes no value") }
                guard sub.values.contains(k) else { throw .other("unknown flag \(k) for \(sub.name)") }
                a.flags.append((k, v))
            } else if sub.values.contains(s) {
                guard i + 1 < args.count else { throw .other("\(s) needs a value") }
                a.flags.append((s, args[i + 1]))
                i += 1
            } else if sub.bare.contains(s) {
                a.flags.append((s, nil))
            } else if s.hasPrefix("--") {
                throw .other("unknown flag \(s) for \(sub.name)")
            } else {
                a.positional.append(s)
            }
            i += 1
        }
        return a
    }

    /// `run` on raw process arguments (photocraft `run_os`): an argument that is not valid
    /// UTF-8 is a usage error naming its position and a lossy rendering (exit 2), never a trap.
    public static func run(raw: [[UInt8]], io: IO = .standard) async -> Int32 {
        var strings: [String] = []
        for (i, bytes) in raw.enumerated() {
            guard let s = String(validating: bytes, as: UTF8.self) else {
                io.err("error: argument \(i + 1) is not valid Unicode: `\(String(decoding: bytes, as: UTF8.self))`\n\n\(usage)\n")
                return 2
            }
            strings.append(s)
        }
        return await run(strings, io: io)
    }

    /// Runs the CLI; returns the exit code (0 ok, 1 failure, 2 usage).
    public static func run(_ args: [String], io: IO = .standard) async -> Int32 {
        guard let cmd = args.first else { io.err(usage); return 2 }
        switch cmd {
        case "-h", "--help", "help": io.out(usage); return 0
        case "--version", "version": io.out("pccli \(version) (PhotoCraft native port of photocraft-cli)\n"); return 0
        default: break
        }
        guard let sub = subcommands.first(where: { $0.name == cmd }) else { io.err("error: unknown command `\(cmd)`\n\n\(usage)\n"); return 2 }
        let parsed: Args
        do {
            // `<subcommand> --help`: usage, without reading inputs or starting a server.
            guard let p = try parse(sub, Array(args.dropFirst())) else { io.out(usage); return 0 }
            parsed = p
        } catch {
            io.err("error: \(error)\n\n\(usage)\n")
            return 2
        }
        do {
            switch cmd {
            case "convert": try convert(parsed, io)
            case "info": try info(parsed, io)
            case "run": try runCommands(parsed, io)
            case "batch": try batch(parsed, io)
            case "droplet": try droplet(parsed, io)
            case "commands": try commands(parsed, io)
            case "mcp": try await mcp(parsed)
            case "serve", "control": try serve(parsed, io)
            case "coverage": coverage(parsed, io)
            default: break
            }
            return 0
        } catch {
            io.err("error: \(EngineError.wrap(error))\n")
            return 1
        }
    }

    static func exportOptions(_ a: Args) throws -> FlatFiles.ExportOptions {
        // TIFF output is flat unless asked: scripted conversions keep predictable sizes.
        var o = FlatFiles.ExportOptions(tiffLayers: a.has("--tiff-layers"))
        if let q = a.get("--quality") {
            guard let n = UInt8(q), (1...100).contains(n) else { throw AutomationError.other("bad --quality `\(q)`: expected a whole number from 1 to 100") }
            o.quality = Int(n)
        }
        if let b = a.get("--tga-bits") {
            guard let n = UInt64(b), n == 24 || n == 32 else { throw AutomationError.other("bad --tga-bits `\(b)`: expected 24 or 32") }
            o.tgaBits = Int(n)
        }
        return o
    }

    static func warnAll(_ io: IO, _ warnings: [String]) {
        for w in warnings { io.err("warning: \(w)\n") }
    }

    static func automationWorkspace(_ a: Args) throws -> AuthorizedWorkspace {
        try AuthorizedWorkspace(readRoot: a.get("--automation-read-root"), writeRoot: a.get("--automation-write-root"))
    }

    static func printJSON(_ io: IO, _ v: JSONValue, compact: Bool) { io.out(v.serialized(pretty: !compact) + "\n") }

    static func strings(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap(\.stringValue) }

    static func convert(_ a: Args, _ io: IO) throws {
        guard a.positional.count == 2 else { throw AutomationError.other("convert needs <in> <out>") }
        // An output that is the input file itself, however it is spelt (relative, with `./`,
        // through a hard or symbolic link), would replace the original, and a lossy re-encode
        // can't be undone: refused before anything is read unless `--in-place` asks for it, as
        // `batch` refuses an `--out` that is its `--in` folder (photocraft #7437).
        if !a.has("--in-place") && sameFile(a.positional[0], a.positional[1]) {
            throw AutomationError.other(
                "\(a.positional[1]) is the input file, so the result would replace the original: choose another output, or pass --in-place to overwrite it")
        }
        let opts = try exportOptions(a)
        let o = try FlatFiles.open(path: a.positional[0])
        warnAll(io, o.warnings)
        warnAll(io, FlatFiles.missingFontWarnings(o.document))
        warnAll(io, try FlatFiles.save(o.document, path: a.positional[1], format: a.get("--format"), options: opts))
    }

    static func info(_ a: Args, _ io: IO) throws {
        guard a.positional.count == 1 else { throw AutomationError.other("info needs <file>") }
        let h = Headless.trustedLocal()
        let opened = try h.open(a.positional[0])
        var doc = try h.inspect(nil).members
        var warnings = strings(opened["warnings"])
        if let st = h.session.active {
            for w in FlatFiles.missingFontWarnings(st.doc) where !warnings.contains(w) { warnings.append(w) }
        }
        doc["warnings"] = .strings(warnings)
        doc["file"] = .string(a.positional[0])
        // Drop per-session noise.
        for k in ["history", "canUndo", "canRedo", "revision"] { doc[k] = nil }
        printJSON(io, .object(doc), compact: a.has("--compact"))
    }

    /// `(id, params)` pairs from repeated `--cmd` / `--params` flags.
    static func commandList(_ a: Args) throws -> [(String, JSONValue)] {
        var cmds: [(String, JSONValue)] = []
        for (k, v) in a.flags {
            switch k {
            case "--cmd": cmds.append((v ?? "", .object([:])))
            case "--params":
                guard !cmds.isEmpty else { throw AutomationError.other("--params must follow a --cmd") }
                do { cmds[cmds.count - 1].1 = try JSONValue.parse(v ?? "") } catch {
                    throw AutomationError.other("bad --params JSON for `\(cmds[cmds.count - 1].0)`: \(error)")
                }
            default: break
            }
        }
        return cmds
    }

    static func runCommands(_ a: Args, _ io: IO) throws {
        let opts = try exportOptions(a)
        let h = Headless.trustedLocal()
        // Each missing-font warning is printed once, wherever it is first detected.
        var reported = Set<String>()
        switch (a.positional.count, a.get("--new")) {
        case (1, nil):
            let o = try h.open(a.positional[0])
            let ws = strings(o["warnings"])
            warnAll(io, ws)
            reported.formUnion(ws)
        case (0, let new?):
            let p: JSONValue
            do { p = try JSONValue.parse(new) } catch { throw AutomationError.other("bad --new JSON: \(error)") }
            do { try h.commandRun("file.new", p) } catch { throw AutomationError.other("--new: \(EngineError.wrap(error))") }
        default:
            throw AutomationError.other("run needs exactly one of <file> or --new <json>")
        }
        let cmds = try commandList(a)
        if cmds.isEmpty && a.get("--out") == nil { throw AutomationError.other("run needs at least one --cmd (or --out)") }
        func newFontWarnings() -> [String] {
            (h.session.active.map { FlatFiles.missingFontWarnings($0.doc) } ?? []).filter { reported.insert($0).inserted }
        }
        for (id, params) in cmds {
            let r: JSONValue
            do { r = try h.commandRun(id, params) } catch { throw AutomationError.other("`\(id)`: \(EngineError.wrap(error))") }
            if let e = ActionsCommands.nestedFailure(id, r) { throw AutomationError.other("`\(id)`: \(e)") }
            let fresh = newFontWarnings()
            warnAll(io, fresh)
            var row: JSONValue = ["command": .string(id), "result": r]
            if !fresh.isEmpty { row = row.setting("warnings", .strings(fresh)) }
            printJSON(io, row, compact: true)
        }
        // A `run` with only `--out` still reports missing fonts before exporting.
        warnAll(io, newFontWarnings())
        if let out = a.get("--out") {
            let r = try h.save(index: nil, path: out, format: a.get("--format"), options: opts)
            // The save repeats the document's missing-font warnings; each was already reported.
            warnAll(io, strings(r["warnings"]).filter { !reported.contains($0) })
        }
    }

    // MARK: Batch

    /// Engine commands to run in order: `(id, params)`.
    public typealias Steps = [(String, JSONValue)]

    /// Parses an actions file: the steps of a recorded action or a droplet (`[id, params]` pairs,
    /// `{"command": id, "params": {…}}` objects or bare ids; `"id"` is accepted for `"command"`),
    /// as a list or wrapped in `{"actions": […]}`, `{"steps": […]}` or a droplet (#489).
    public static func parseActions(_ text: String) throws -> Steps {
        let v: JSONValue
        do { v = try JSONValue.parse(text) } catch { throw AutomationError.other("actions JSON: \(error)") }
        return try stepsOf(v)
    }

    static func stepsOf(_ v: JSONValue) throws -> Steps {
        try parseAction(v["actions"] ?? v, "batch --actions")
    }

    /// photocraft-engine `automate_cmds::parse_action`: `[step…]`, `{"steps"|"action": …}` (a
    /// recorded action) or a droplet.
    static func parseAction(_ v: JSONValue, _ cmd: String) throws -> Steps {
        let steps: JSONValue
        switch v {
        case .array: steps = v
        case .object(let o):
            guard let s = o["steps"] ?? o["action"].map({ $0["steps"] ?? $0 }) else { throw EngineError.bad(cmd, "an action object needs \"steps\"") }
            steps = s
        default: throw EngineError.bad(cmd, "an action must be an array of steps or an object")
        }
        guard let arr = steps.arrayValue else { throw EngineError.bad(cmd, "steps must be an array") }
        return try arr.map { st in
            switch st {
            case .array(let a) where !a.isEmpty:
                guard let id = a[0].stringValue else { throw EngineError.bad(cmd, "step id must be a string") }
                return (id, a.count > 1 ? a[1] : .object([:]))
            case .object(let o):
                guard let id = (o["command"] ?? o["id"])?.stringValue else { throw EngineError.bad(cmd, #"step needs "command""#) }
                return (id, o["params"] ?? .object([:]))
            case .string(let id): return (id, .object([:]))
            default: throw EngineError.bad(cmd, #"each step is [id, params], {"command", "params"} or an id"#)
            }
        }
    }

    /// The steps `batch` plays on each file, and the actions they can call. An Actions set
    /// (`{"actions": [{"name", "steps"}…]}`, or the bare list) plays the action `name` picks
    /// (optional when the set holds one) with the whole set loaded, as Photoshop's Batch does;
    /// anything else is one action's steps (#2786).
    public static func loadActions(_ text: String, name: String?) throws -> (Steps, [ActionsCommands.Action]) {
        let v: JSONValue
        do { v = try JSONValue.parse(text) } catch { throw AutomationError.other("actions JSON: \(error)") }
        let list = v["actions"] ?? v
        let isSet = list.arrayValue.map { !$0.isEmpty && $0.allSatisfy { $0["name"]?.stringValue != nil } } ?? false
        if !isSet {
            if name != nil {
                throw AutomationError.other(#"--action picks an action from an Actions set ({"actions": [{"name", "steps"}…]}), but this file holds one action's steps"#)
            }
            return (try stepsOf(v), [])
        }
        let set: [ActionsCommands.Action]
        do { set = try list.decode(as: [ActionsCommands.Action].self) } catch { throw AutomationError.other("Actions set: \(error)") }
        let names = set.map { "`\($0.name)`" }.joined(separator: ", ")
        let action: ActionsCommands.Action
        if let n = name {
            guard let found = set.first(where: { $0.name == n }) else { throw AutomationError.other("no action named `\(n)` in the set (it holds \(names))") }
            action = found
        } else if set.count == 1 {
            action = set[0]
        } else {
            throw AutomationError.other("the Actions set holds \(set.count) actions: pick one with --action <name> (\(names))")
        }
        return ([("actions.play", ["action": .string(action.name)])], set)
    }

    /// Whether `a` and `b` name the same existing folder, however they are spelt.
    /// Whether two paths name the same existing file (same device and inode, symbolic links followed).
    static func sameFile(_ a: String, _ b: String) -> Bool {
        var x = stat(), y = stat()
        guard stat(a, &x) == 0, stat(b, &y) == 0 else { return false }
        return x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }

    static func sameDir(_ a: String, _ b: String) -> Bool {
        guard let x = realpath(a, nil), let y = realpath(b, nil) else { return false }
        defer { free(x); free(y) }
        return strcmp(x, y) == 0
    }

    static func isInput(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              let ext = FlatFiles.extensionOf(path: path) else { return false }
        if ["pcraft", "psd", "psb", "pdn", "ora", "af", "afdesign", "afphoto", "afpub"].contains(ext) { return true }
        return ImageFormat.from(extension: ext).map { $0.caps.read } ?? false
    }

    static func batch(_ a: Args, _ io: IO) throws {
        guard let actionsPath = a.get("--actions") else { throw AutomationError.other("batch needs --actions <file>") }
        guard let inDir = a.get("--in") else { throw AutomationError.other("batch needs --in <dir>") }
        guard let outDir = a.get("--out") else { throw AutomationError.other("batch needs --out <dir>") }
        let text: String
        do { text = try String(contentsOfFile: actionsPath, encoding: .utf8) } catch {
            throw AutomationError.other("\(actionsPath): \(ControlSecurity.ioMessage(error))")
        }
        let (actions, set) = try loadActions(text, name: a.get("--action"))
        let opts = try exportOptions(a)
        // Results are saved as `<out>/<stem>.<ext>`, so an `--out` that is the `--in` folder
        // would replace the originals (#492).
        if !a.has("--in-place") && sameDir(inDir, outDir) {
            throw AutomationError.other(
                "--out \(outDir) is the --in folder, so the results would replace the originals: choose another --out folder, or pass --in-place to overwrite them")
        }
        do { try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true) } catch {
            throw AutomationError.other(ControlSecurity.ioMessage(error))
        }
        let entries: [String]
        do { entries = try FileManager.default.contentsOfDirectory(atPath: inDir) } catch {
            throw AutomationError.other("\(inDir): \(ControlSecurity.ioMessage(error))")
        }
        let inputs = entries.map { (inDir as NSString).appendingPathComponent($0) }.filter(isInput).sorted()
        var ok = 0, failed = 0
        var written = FlatFiles.OutputClaims()
        // `--format .jpg` names outputs `<stem>.jpg`, as `--format jpg` does (#490).
        let format = a.get("--format").map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
        for input in inputs {
            let ext = format ?? ((input as NSString).pathExtension.isEmpty ? "png" : (input as NSString).pathExtension)
            let stem = ((input as NSString).lastPathComponent as NSString).deletingPathExtension
            let target = (outDir as NSString).appendingPathComponent("\(stem).\(ext)")
            do {
                try written.check(target)
                let h = Headless.trustedLocal()
                // Steps that play another action find it in the set; the session's playback stack
                // stops an action that calls itself.
                h.session.state[ActionsCommands.ActionStateKey.self].list = set
                try h.open(input)
                for (id, p) in actions {
                    if ActionsCommands.shellViewCommand(id) || ActionsCommands.shellSaveCommand(id) { continue }
                    let r: JSONValue
                    do { r = try h.commandRun(id, p) } catch { throw AutomationError.other("`\(id)`: \(EngineError.wrap(error))") }
                    // A failed step inside a called action makes this file an error, not a result.
                    if let e = ActionsCommands.nestedFailure(id, r) { throw AutomationError.other("`\(id)`: \(e)") }
                }
                let r = try h.save(index: nil, path: target, format: ext, options: opts)
                ok += 1
                written.record(target, input: input)
                io.out("ok    \(input) -> \(target)\n")
                warnAll(io, strings(r["warnings"]))
            } catch {
                failed += 1
                io.err("FAIL  \(input): \(EngineError.wrap(error))\n")
            }
        }
        io.out("\(ok) succeeded, \(failed) failed\n")
        if failed > 0 { throw AutomationError.other("\(failed) file(s) failed") }
    }

    static func droplet(_ a: Args, _ io: IO) throws {
        guard let file = a.positional.first else { throw AutomationError.other("droplet needs <file.pcdroplet> and inputs") }
        let inputs = Array(a.positional.dropFirst())
        if inputs.isEmpty { throw AutomationError.other("droplet needs at least one input file or folder") }
        var p: JSONValue = ["droplet": .string(file), "input": .strings(inputs)]
        if let o = a.get("--out") { p = p.setting("output", .string(o)) }
        let s = Session()
        let r = try s.execute("file.automate.runDroplet", p)
        for f in strings(r["files"]) { io.out("ok    \(f)\n") }
        let errors = r["errors"]?.arrayValue ?? []
        for e in errors { io.err("FAIL  \(e["file"]?.stringValue ?? ""): \(e["error"]?.stringValue ?? "")\n") }
        if !errors.isEmpty { throw AutomationError.other("\(errors.count) file(s) failed") }
    }

    static func commands(_ a: Args, _ io: IO) throws {
        let h = Headless()
        let list = h.commandList(filter: a.get("--filter"))
        if a.has("--json") { printJSON(io, list, compact: false); return }
        let pad = { (s: String, n: Int) in s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
        for c in list.arrayValue ?? [] {
            let menu = strings(c["menu"]).joined(separator: " > ")
            let unavailable = c["available"]?.boolValue == false ? "  [unavailable]" : ""
            io.out(pad(c["id"]?.stringValue ?? "", 44) + " " + pad(c["label"]?.stringValue ?? "", 32) + " " + menu + unavailable + "\n")
        }
    }

    static func serve(_ a: Args, _ io: IO) throws {
        let h = Headless.withWorkspace(try automationWorkspace(a))
        guard let port = a.get("--port") else {
            try ControlServer.serve(h)
            return
        }
        guard let n = UInt16(port) else { throw AutomationError.other("bad --port `\(port)`") }
        let (supplied, tokenFile) = ControlSecurity.tokenInputs(supplied: a.get("--control-token"), tokenFile: a.get("--control-token-file"))
        let token = try ControlSecurity.serverToken(supplied: supplied, tokenFile: tokenFile)
        if let tokenFile {
            io.err("pccli control token file: \(tokenFile)\n")
        } else if supplied == nil {
            io.err("pccli control token: \(token)\n")
        }
        try ControlServer.serveTCP("127.0.0.1:\(n)", SharedHeadless(h), token: token) { local in io.err("pccli serving on \(local)\n") }
    }

    static func mcp(_ a: Args) async throws {
        let server: PhotocraftMCP
        if let addr = a.get("--bridge") {
            let (supplied, tokenFile) = ControlSecurity.tokenInputs(supplied: a.get("--control-token"), tokenFile: a.get("--control-token-file"))
            let token = try ControlSecurity.clientToken(supplied: supplied, tokenFile: tokenFile)
            server = try PhotocraftMCP.bridge(addr, token: token)
        } else {
            let host = EngineHost(filesystem: .workspace(try automationWorkspace(a)))
            server = await PhotocraftMCP.headless(host: host, perCommandTools: a.has("--per-command-tools"))
        }
        try await server.serveStdio()
    }

    static func coverage(_ a: Args, _ io: IO) {
        let report = CoverageReport(registry: .standard())
        if a.has("--json") { printJSON(io, report.json, compact: false); return }
        if a.has("--markdown") { io.out(report.markdown); return }
        io.out("photocraft commands: \(report.total)  implemented: \(report.implemented)  stubbed: \(report.stubbed)  not registered: \(report.missing)\n")
        io.out("new ids (not in photocraft): \(report.extra.joined(separator: ", "))\n")
        for r in report.rows {
            io.out("\(r.module.padding(toLength: 28, withPad: " ", startingAt: 0)) \(r.implemented)/\(r.total)" + (r.stubbed > 0 ? "  (\(r.stubbed) unavailable)" : "") + "\n")
        }
    }
}
