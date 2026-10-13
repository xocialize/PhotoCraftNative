// ps-oracle — Adobe Photoshop as the acceptance oracle for PCPSD/PCIO output. See README.md.

import Foundation
import PCPSD
import PSOracleKit

let usage = """
ps-oracle — drive Adobe Photoshop as the PSD/PSB acceptance oracle (one Photoshop user at a time).

  ps-oracle info <file.psd|psb>                  Photoshop's reading: mode, depth, size, profile, layer tree (JSON)
  ps-oracle composite <file> <out.tif> [--alpha <alpha.tif>]
                                                 flatten a duplicate, save the composite at the document's
                                                 mode and depth (Duotone/Multichannel: Photoshop Raw)
  ps-oracle accept <dir> [--json <out.json>]     info on every PSD/PSB: opened / failed with Photoshop's error
  ps-oracle sweep <dir|file>... [--out <dir>] [--skip <dirname,...>] [--exclude <substring,...>] [--no-layers] [--name <run>] [--resume] [--fuzz]
                                                 acceptance sweep: open, tree vs PCPSD, composite vs PCPSD
                                                 merged image, every pixel layer vs PCPSD
  ps-oracle compare <file> <composite.tif>       PCPSD merged image vs a composite (no Photoshop)
  ps-oracle corpus build [--out <dir>] [--only <name,...>] [--list]
                                                 have Photoshop author the oracle corpus + composites + manifest
  ps-oracle corpus read [<dir>] [--json <out>]   PCPSD over the corpus: parse, rewrite, typed blocks, merged vs composite
  ps-oracle bisect <file> [--out <dir>]          why Photoshop rejects a file: each top-level layer node alone, no layers,
                                                 each global block / resource dropped — which variants open
  ps-oracle try-variants <variant>...            open variants in order, stop at the first that opens (one strike)
  ps-oracle lut-probe <lut> [--save-psd p] [--save-tif p]
                                                 one document: a Color Lookup loading <lut> by file name; read back (saves only if asked)
  ps-oracle eval <script.jsx> [args...]         run a script (lib.jsx prepended, ARGS.argv) under the lock — debugging
  ps-oracle structure <file>...                  how the file is laid out (no Photoshop)
  ps-oracle measure m1|m2|m3 [--out <dir>] [--only ids] [--probe]
                                                 measurement batches M1/M2/M3 (Photoshop as a function oracle; --probe: M2's one-document B/C check only)
  ps-oracle blend-table                          measure the blend modes Photoshop allows per mode/depth (new documents only)
  ps-oracle prescreen <dir|file>... [--skip-swept <report.json>]
                                                 offline: quarantine files of a known Photoshop crash/modal/refusal class (no Photoshop)
  ps-oracle explain <sweep.json> <dir>          offline: the proven refusal causes for each refused file of a sweep
  ps-oracle quarantine [<file> --reason <text>]  list, or add to, the files never opened again (crashed/hung Photoshop)
  ps-oracle ping | cleanup                       is Photoshop answering / close the documents ps-oracle owns

Any command that opens files refuses quarantined ones (files that crashed or hung Photoshop) unless
given --allow-quarantined "<hypothesis>". Every run first checks that Photoshop is running, answers,
and has no documents open; ps-oracle never launches Photoshop.

Environment: PS_ORACLE_SCRATCH (allowed data root; default: PhotoCraftNative's fixtures root,
PHOTOCRAFT_FIXTURES or ../PhotoCraftNative-Fixtures), PS_ORACLE_TIMEOUT (seconds per Photoshop call,
default 180), PS_ORACLE_LOCK (lock file), PS_ORACLE_VERBOSE.
"""

func log(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func emit(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
}

func jsonText(_ obj: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
    return String(decoding: d, as: UTF8.self)
}

func encoded<T: Encodable>(_ v: T) throws -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    return try e.encode(v)
}

/// The package directory (the second allowed root).
let toolDirectory: URL = {
    if let p = ProcessInfo.processInfo.environment["PS_ORACLE_TOOL_DIR"] { return URL(fileURLWithPath: p) }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}()

let config = OracleConfig(toolDirectory: toolDirectory)

struct Options {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var switches: Set<String> = []

    init(_ args: ArraySlice<String>, valued: Set<String>) {
        var it = args.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                let k = String(a.dropFirst(2))
                if valued.contains(k), let v = it.next() { flags[k] = v } else { switches.insert(k) }
            } else {
                positional.append(a)
            }
        }
    }
}

/// A Photoshop session (lock + preflight). `--allow-quarantined "<hypothesis>"` lets this run open
/// quarantined files, logging the hypothesis.
func session(preflight: Bool = true) throws -> Photoshop {
    let ps = try Photoshop(config: config, log: log, preflight: preflight)
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--allow-quarantined"), i + 1 < args.count { ps.quarantineOverride = args[i + 1] }
    return ps
}

func runCommand(_ argv: [String]) throws -> Int32 {
    guard argv.count >= 2 else { emit(usage); return 2 }
    let cmd = argv[1]
    let rest = argv.dropFirst(2)
    switch cmd {
    case "info":
        let o = Options(rest, valued: [])
        guard let file = o.positional.first else { throw OracleError.usage("ps-oracle info <file>") }
        let ps = try session()
        try ps.admit(URL(fileURLWithPath: file))
        let r = try ps.run("info", ["path": try config.checked(file)])
        emit(jsonText(r))
        return (r["ok"] as? Bool ?? false) ? 0 : 1

    case "composite":
        let o = Options(rest, valued: ["alpha"])
        guard o.positional.count == 2 else { throw OracleError.usage("ps-oracle composite <file> <out.tif> [--alpha <alpha.tif>]") }
        var args: [String: Any] = ["path": try config.checked(o.positional[0]), "out": try config.checked(o.positional[1])]
        if let a = o.flags["alpha"] { args["alphaOut"] = try config.checked(a) }
        let ps = try session()
        try ps.admit(URL(fileURLWithPath: o.positional[0]))
        let r = try ps.run("composite", args)
        emit(jsonText(r))
        return (r["ok"] as? Bool ?? false) ? 0 : 1

    case "accept":
        let o = Options(rest, valued: ["json"])
        guard let dir = o.positional.first else { throw OracleError.usage("ps-oracle accept <dir>") }
        let files = Sweep.files(in: URL(fileURLWithPath: dir))
        let ps = try session()
        var results: [[String: Any]] = []
        var opened = 0
        for url in files {
            var r: [String: Any]
            do {
                try ps.admit(url)
                r = try ps.run("info", ["path": try config.checked(url.path)])
            } catch let e as OracleError {
                switch e {
                case let .crashed(why): ps.quarantine(url, reason: "crashed Photoshop on open: \(why)")
                case let .modal(why): ps.quarantine(url, reason: "raised a modal dialog on open: \(why)")
                case .timedOut: ps.quarantine(url, reason: "timed out on open (modal dialog?)")
                default: break
                }
                if e.isFatal { throw e }
                r = ["ok": false, "opened": false, "error": "\(e)"]
            }
            let ok = r["opened"] as? Bool ?? false
            if ok { opened += 1 }
            let err = (r["error"] as? String)?.replacingOccurrences(of: "\n", with: " ") ?? ""
            emit("\(ok ? "opened" : "FAILED")\t\(url.lastPathComponent)\t\(ok ? "\(r["mode"] ?? "?") \(r["bits"] ?? "?")-bit, \((r["layers"] as? [Any])?.count ?? 0) layer records" : err)")
            results.append(["file": url.path, "opened": ok, "error": r["error"] ?? NSNull(), "mode": r["mode"] ?? NSNull(), "bits": r["bits"] ?? NSNull(),
                            "layerRecords": (r["layers"] as? [Any])?.count ?? 0])
        }
        emit("accept: \(opened)/\(files.count) opened")
        if let j = o.flags["json"] { try Data(jsonText(["opened": opened, "total": files.count, "files": results]).utf8).write(to: URL(fileURLWithPath: try config.checked(j))) }
        return opened == files.count ? 0 : 1

    case "sweep":
        let o = Options(rest, valued: ["out", "skip", "name", "exclude"])
        guard !o.positional.isEmpty else { throw OracleError.usage("ps-oracle sweep <dir|file>...") }
        let skip = Set((o.flags["skip"] ?? "").split(separator: ",").map(String.init))
        var exclude = (o.flags["exclude"] ?? "").split(separator: ",").map(String.init)
        // PCPSD's randomised structural fixtures are not export-quality documents: only with --fuzz.
        if !o.switches.contains("fuzz") { exclude.append("testgen") }
        var files: [URL] = []
        for p in o.positional {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { files += Sweep.files(in: URL(fileURLWithPath: p), skip: skip) } else { files.append(URL(fileURLWithPath: p)) }
        }
        let name = o.flags["name"] ?? "sweep"
        let out = URL(fileURLWithPath: o.flags["out"] ?? config.scratch.appendingPathComponent("ps-oracle/\(name)").path)
        _ = try config.checked(out.path)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let excluded = files.filter { u in exclude.contains { u.lastPathComponent.contains($0) } }
        files.removeAll { u in exclude.contains { u.lastPathComponent.contains($0) } }
        if !excluded.isEmpty { log("excluded \(excluded.count) files matching \(exclude)") }
        let reportURL = out.appendingPathComponent("\(name).json")
        var rows: [SweepRow] = []
        if o.switches.contains("resume"), let d = try? Data(contentsOf: reportURL) {
            rows = (try? JSONDecoder().decode([SweepRow].self, from: d)) ?? []
            let done = Set(rows.map(\.file))
            files.removeAll { done.contains($0.lastPathComponent) }
            log("resuming: \(rows.count) files already in \(reportURL.lastPathComponent), \(files.count) to go")
        }
        let ps = try session()
        for (i, url) in files.enumerated() {
            let row: SweepRow
            do { row = try Sweep.run(url, ps: ps, outDir: out, layerExports: !o.switches.contains("no-layers"), log: log) } catch let stop as SweepStop {
                rows.append(stop.row)
                try encoded(rows).write(to: reportURL)
                try Data(Sweep.markdownTable(rows).utf8).write(to: out.appendingPathComponent("\(name).md"))
                log("STOPPED at [\(i + 1)/\(files.count)] \(stop.row.file): \(stop.error)")
                log("the row is recorded; after checking Photoshop, continue with --resume (add --exclude <name> to quarantine this file)")
                return 3
            }
            rows.append(row)
            let comp = row.composite.map { "composite \(fmtD($0.max8))/\(fmtD($0.mean8))" } ?? (row.compositeError ?? "")
            log("[\(i + 1)/\(files.count)] \(row.file): \(row.opened ? "opened" : "FAILED \(row.photoshopError ?? "")") tree=\(row.treeMatch.map { $0 ? "match" : "\(row.mismatches.count) mismatches" } ?? "-") \(comp) layers=\(row.layersWorst.map(fmtD) ?? "-") (\(fmtD(row.seconds))s)")
            try encoded(rows).write(to: reportURL)
        }
        try Data(Sweep.markdownTable(rows).utf8).write(to: out.appendingPathComponent("\(name).md"))
        let opened = rows.filter(\.opened).count
        emit("sweep: \(opened)/\(rows.count) opened in Photoshop; tree match \(rows.filter { $0.treeMatch == true }.count)/\(rows.count); report \(out.appendingPathComponent("\(name).md").path)")
        return 0

    case "compare":
        let o = Options(rest, valued: [])
        guard o.positional.count == 2 else { throw OracleError.usage("ps-oracle compare <file> <composite.tif>") }
        let f = try PSDFile(contentsOf: URL(fileURLWithPath: o.positional[0]))
        let ref = try ReferenceImageReader.read(contentsOf: URL(fileURLWithPath: o.positional[1]))
        emit(try PixelCompare.merged(f, against: ref).summary)
        return 0

    case "corpus":
        guard let sub = rest.first else { throw OracleError.usage("ps-oracle corpus build|read") }
        let o = Options(rest.dropFirst(), valued: ["out", "only", "json"])
        switch sub {
        case "build":
            let out = URL(fileURLWithPath: o.flags["out"] ?? config.scratch.appendingPathComponent("ps-corpus").path)
            let ps = try session()
            try CorpusBuilder.build(ps: ps, out: out, only: o.flags["only"].map { Set($0.split(separator: ",").map(String.init)) },
                                    listOnly: o.switches.contains("list"), log: log, emit: emit)
            return 0
        case "read":
            let dir = URL(fileURLWithPath: o.positional.first ?? config.scratch.appendingPathComponent("ps-corpus").path)
            let report = try CorpusReader.read(dir, log: log)
            let json = o.flags["json"] ?? dir.appendingPathComponent("pcpsd-read.json").path
            try encoded(report).write(to: URL(fileURLWithPath: try config.checked(json)))
            try Data(CorpusReader.markdown(report).utf8).write(to: URL(fileURLWithPath: try config.checked(json.replacingOccurrences(of: ".json", with: ".md"))))
            emit(CorpusReader.summary(report))
            return 0
        default:
            throw OracleError.usage("ps-oracle corpus build|read")
        }

    case "bisect":
        let o = Options(rest, valued: ["out"])
        guard let file = o.positional.first else { throw OracleError.usage("ps-oracle bisect <file> [--out <dir>]") }
        let src = URL(fileURLWithPath: try config.checked(file))
        let out = URL(fileURLWithPath: try config.checked(o.flags["out"] ?? config.scratch.appendingPathComponent("ps-oracle/bisect/\(src.deletingPathExtension().lastPathComponent)").path))
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let variants = try Bisect.variants(of: src, into: out)
        let ps = try session()
        func opens(_ u: URL) throws -> (Bool, String) {
            do {
                try ps.admit(u)
                let r = try ps.run("info", ["path": try config.checked(u.path)])
                return (r["opened"] as? Bool ?? false, (r["error"] as? String ?? "").replacingOccurrences(of: "\n", with: " "))
            } catch let e as OracleError {
                switch e {
                case let .crashed(why): ps.quarantine(u, reason: "crashed Photoshop on open: \(why)")
                case let .modal(why): ps.quarantine(u, reason: "raised a modal dialog on open: \(why)")
                case .timedOut: ps.quarantine(u, reason: "timed out on open (modal dialog?)")
                default: break
                }
                if e.isFatal { throw e }
                return (false, "\(e)")
            }
        }
        let (orig, origErr) = try opens(src)
        emit("original: \(orig ? "opens" : "REJECTED — \(origErr)")")
        for v in variants {
            let (ok, err) = try opens(v.url)
            emit("\(ok ? "opens   " : "rejected")  \(v.name)  \(v.description)\(ok ? "" : "  — \(err)")")
        }
        return 0

    case "try-variants":
        // Opens variants of one refused file in the order given (lowest risk first) and stops at
        // the first that opens; any crash, timeout or modal stops everything (one strike).
        let o = Options(rest, valued: [])
        guard !o.positional.isEmpty else { throw OracleError.usage("ps-oracle try-variants <variant>...") }
        let ps = try session()
        for p in o.positional {
            let u = URL(fileURLWithPath: try config.checked(p))
            do {
                try ps.admit(u)
                let r = try ps.run("info", ["path": try config.checked(u.path)])
                let ok = r["opened"] as? Bool ?? false
                emit("\(ok ? "OPENS   " : "refused ")  \(u.lastPathComponent)\(ok ? "" : "  — " + ((r["error"] as? String) ?? "").replacingOccurrences(of: "\n", with: " "))")
                if ok { return 0 }
            } catch let e as OracleError {
                switch e {
                case let .crashed(why): ps.quarantine(u, reason: "crashed Photoshop on open: \(why)")
                case let .modal(why): ps.quarantine(u, reason: "raised a modal dialog on open: \(why)")
                case .timedOut: ps.quarantine(u, reason: "timed out on open (modal dialog?)")
                default: break
                }
                emit("FAILED    \(u.lastPathComponent)  — \(e)")
                if e.isFatal { return 3 }
            }
        }
        emit("none opened")
        return 0

    case "lut-probe":
        // One new document with a Color Lookup loading a 3DLUT file by name and format; reads the
        // layer back (key names; raw data as byte counts) and saves nothing.
        let o = Options(rest, valued: ["save-psd", "save-tif"])
        guard let lut = o.positional.first else { throw OracleError.usage("ps-oracle lut-probe <lut file inside the data root> [--save-psd p] [--save-tif p]") }
        var args: [String: Any] = ["lut": try config.checked(lut)]
        for (flag, key) in [("save-psd", "psd"), ("save-tif", "tif")] {
            if let p = o.flags[flag] {
                let u = URL(fileURLWithPath: try config.checked(p))
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                args[key] = u.path
            }
        }
        let ps = try session()
        emit(jsonText(try ps.run("lut-probe", args)))
        return 0

    case "eval":
        let o = Options(rest, valued: [])
        guard let file = o.positional.first else { throw OracleError.usage("ps-oracle eval <script.jsx>") }
        let ps = try session()
        emit(try ps.runFile(URL(fileURLWithPath: try config.checked(file)), ["argv": Array(o.positional.dropFirst())]))
        return 0

    case "structure":
        let o = Options(rest, valued: [])
        for p in o.positional {
            emit("== \(p)")
            emit(Structure.outline(try PSDFile(contentsOf: URL(fileURLWithPath: p))))
        }
        return 0

    case "ping":
        let ps = try session(preflight: false)
        emit(jsonText(try ps.ping()))
        return 0

    case "cleanup":
        let ps = try session(preflight: false)
        emit(jsonText(try ps.cleanup()))
        return 0

    case "measure":
        // Measurement batches: Photoshop as a function oracle (creates documents, or opens the
        // plain PNG inputs this tool writes; never a PSD).
        let o = Options(rest, valued: ["out", "only"])
        let batch = o.positional.first ?? ""
        guard ["m1", "m2", "m3"].contains(batch) else { throw OracleError.usage("ps-oracle measure m1|m2|m3 [--out <dir>] [--only id,...] [--probe]") }
        let out = URL(fileURLWithPath: o.flags["out"] ?? config.scratch.appendingPathComponent("ps-measure/\(batch.uppercased())").path)
        let only = o.flags["only"].map { Set($0.split(separator: ",").map(String.init)) }
        let ps = try session()
        if batch == "m2" { return try MeasureM2.run(ps: ps, out: out, only: only, probeOnly: o.switches.contains("probe"), log: log) }
        if batch == "m3" { return try MeasureM3.run(ps: ps, out: out, only: only, log: log) }
        return try MeasureM1.run(ps: ps, out: out, only: only, log: log)

    case "blend-table":
        // Measures which blend modes Photoshop allows per colour mode and depth (new documents
        // only; no file is opened) and saves it for the pre-screen.
        let ps = try session()
        let r = try ps.run("blendprobe", [:], timeout: 300)
        guard r["ok"] as? Bool == true else { emit(jsonText(r)); return 1 }
        let url = BlendTable.defaultURL(config.scratch)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        emit(BlendTable(json: r).markdown)
        emit("saved \(url.path)")
        return 0

    case "prescreen":
        // Offline (no Photoshop): every PSD/PSB under the paths against the known crash classes;
        // failures are quarantined and never opened.
        let o = Options(rest, valued: ["skip-swept"])
        guard !o.positional.isEmpty else { throw OracleError.usage("ps-oracle prescreen <dir|file>... [--skip-swept <report.json>]") }
        var files: [URL] = []
        for p in o.positional {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { files += Sweep.files(in: URL(fileURLWithPath: p)) } else { files.append(URL(fileURLWithPath: p)) }
        }
        if let r = o.flags["skip-swept"], let d = try? Data(contentsOf: URL(fileURLWithPath: r)), let rows = try? JSONDecoder().decode([SweepRow].self, from: d) {
            let done = Set(rows.map(\.file))
            files.removeAll { done.contains($0.lastPathComponent) }
        }
        var q = Quarantine(scratch: config.scratch)
        let table = BlendTable.load(config.scratch)
        if table == nil { log("no measured blend-mode table yet (ps-oracle blend-table): only the EngineData screen runs") }
        var caught = 0, already = 0, typeFiles = 0, unparsable = 0
        for u in files {
            guard let f = try? PSDFile(contentsOf: u) else { unparsable += 1; continue }
            if f.layers.contains(where: { $0.typeTool != nil }) { typeFiles += 1 }
            guard let why = CrashSignatures.match(f) ?? TypeSizeScreen.violation(f) ?? LinterScreen.violation(f) ?? table?.violation(f) else { continue }
            caught += 1
            if q.entry(for: u) != nil { already += 1 } else if !o.switches.contains("dry-run") { try q.add(u, reason: why) }
            emit("CAUGHT\t\(u.lastPathComponent)\t\(why)")
        }
        emit("prescreen: \(files.count) files, \(typeFiles) with type layers, \(caught) caught (\(already) already quarantined), \(unparsable) PCPSD cannot parse")
        return 0

    case "explain":
        // Offline: the proven refusal causes for every file a sweep report lists as refused.
        let o = Options(rest, valued: [])
        guard o.positional.count == 2 else { throw OracleError.usage("ps-oracle explain <sweep.json> <dir>") }
        let rows = try JSONDecoder().decode([SweepRow].self, from: Data(contentsOf: URL(fileURLWithPath: o.positional[0])))
        let table = BlendTable.load(config.scratch)
        var explained = 0, unexplained: [String] = []
        for r in rows where !r.opened && !(r.photoshopError ?? "").contains("is quarantined") && !(r.photoshopError ?? "").contains("quit while running") {
            guard let f = try? PSDFile(contentsOf: URL(fileURLWithPath: o.positional[1]).appendingPathComponent(r.file)) else { continue }
            let why = KnownCauses.explain(f, blendTable: table)
            let txt2 = (r.photoshopError ?? "").hasPrefix("General Photoshop error") && f.globalBlocks.contains { $0.key == "Txt2" }
            let all = why + (txt2 && why.isEmpty ? ["Txt2 written by PCIO (General Photoshop error; files open without it)"] : [])
            if all.isEmpty { unexplained.append(r.file) } else { explained += 1 }
            emit("\(all.isEmpty ? "UNEXPLAINED" : "explained")\t\(r.file)\t\(all.joined(separator: " | "))")
        }
        emit("explain: \(explained) refusals explained, \(unexplained.count) unexplained")
        return 0

    case "quarantine":
        let q = Quarantine(scratch: config.scratch)
        let o = Options(rest, valued: ["reason"])
        if let f = o.positional.first {
            var q2 = q
            try q2.add(URL(fileURLWithPath: f), reason: o.flags["reason"] ?? "added by hand")
            emit("quarantined \(URL(fileURLWithPath: f).lastPathComponent)")
        } else {
            for e in q.entries { emit("\(e.name)\t\(e.reason)\t\(e.date)") }
            emit("\(q.entries.count) quarantined (\(q.url.path))")
        }
        return 0

    case "-h", "--help", "help":
        emit(usage)
        return 0

    default:
        emit(usage)
        return 2
    }
}

func fmtD(_ v: Double) -> String { v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(format: "%.3f", v) }

/// The arguments without `--allow-quarantined <hypothesis>` (read by `session()`).
let commandArguments: [String] = {
    var a = CommandLine.arguments
    if let i = a.firstIndex(of: "--allow-quarantined") { a.removeSubrange(i ..< min(a.count, i + 2)) }
    return a
}()

do {
    exit(try runCommand(commandArguments))
} catch {
    log("ps-oracle: \(error)")
    exit(1)
}
