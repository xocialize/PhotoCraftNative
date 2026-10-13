// Port of photocraft-cli's tests (apps/photocraft-cli/src/lib.rs `mod tests`, apps/photocraft-cli/tests/cli.rs), run in process through `CLI.run`, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Skipped: cli.rs `mcp_stdio_handshake_and_tool_call` (spawns the binary; `serveIO` covers the
// wire). Every other test of lib.rs and cli.rs runs in process.

import Foundation
@testable import PCAutomation
import PCDocument
import PCEngine
import PCFormat
import PCFoundation
import PCPlatform
import Testing

/// Runs the CLI in process: (exit code, stdout, stderr).
func invoke(_ args: [String]) async -> (Int32, String, String) {
    let c = Capture()
    let code = await CLI.run(args, io: c.io)
    return (code, c.stdout, c.stderr)
}

/// An RGBA PNG whose pixels vary (photocraft's `write_png`).
func writeNoisePNG(_ url: URL, _ w: Int, _ h: Int, seed: UInt8) throws {
    var floats = [Float](repeating: 0, count: w * h * 4)
    for i in floats.indices { floats[i] = Float(UInt8(truncatingIfNeeded: i) &* seed &+ seed) / 255 }
    try ImageCodecs.encode(RasterBuffer(width: w, height: h, format: .rgba8, floats: floats), as: .png).write(to: url)
}

@Suite struct CLIPortTests {
    // MARK: lib.rs

    @Test func missingTypefaceIsReportedByRunInfoAndConvert() async throws {
        let family = "DefinitelyMissingPhotoCraftTypeface1251"
        let dir = try tempDir("font-warnings")
        defer { try? FileManager.default.removeItem(at: dir) }
        let native = dir.appendingPathComponent("missing.pcraft").path, png = dir.appendingPathComponent("missing.png").path
        let params = (["x": 6, "y": 38, "text": "Missing font warning", "font": .string(family), "size": 20] as JSONValue).serialized()
        var (code, stdout, stderr) = await invoke(["run", "--new", #"{"width":256,"height":96,"background":"white"}"#, "--cmd", "type.create", "--params", params,
                                                   "--cmd", "type.resolveMissingFonts", "--out", native])
        #expect(code == 0, "\(stderr)")
        #expect(stderr.components(separatedBy: family).count - 1 == 1, "multi-command runs should not repeat the same missing font warning: \(stderr)")
        let rows = try stdout.split(separator: "\n").map { try JSONValue.parse(String($0)) }
        #expect(rows.count == 2, "\(stdout)")
        #expect(rows.first?["warnings"]?.arrayValue?.contains { $0.stringValue?.contains(family) == true } == true)
        #expect(rows.last?["warnings"] == nil, "only newly detected missing fonts are reported")

        (code, stdout, stderr) = await invoke(["info", native, "--compact"])
        #expect(code == 0, "\(stderr)")
        #expect(try JSONValue.parse(stdout)["warnings"]?.arrayValue?.contains { $0.stringValue?.contains(family) == true } == true, "\(stdout)")
        #expect(stderr.isEmpty, "info puts warnings in JSON, not stderr")

        (code, _, stderr) = await invoke(["convert", native, png])
        #expect(code == 0, "\(stderr)")
        #expect(stderr.contains("warning: font '\(family)'"), "\(stderr)")
        #expect(FileManager.default.fileExists(atPath: png))

        // Even with no commands, run --out checks the opened document before export.
        (code, stdout, stderr) = await invoke(["run", native, "--out", png])
        #expect(code == 0, "\(stderr)")
        #expect(stdout.isEmpty)
        #expect(stderr.components(separatedBy: family).count - 1 == 1, "\(stderr)")
    }

    @Test func convertReadsAndWritesOpenRaster() async throws {
        let dir = try tempDir("ora")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (native, ora, png) = (dir.appendingPathComponent("layers.pcraft").path, dir.appendingPathComponent("layers.ora").path, dir.appendingPathComponent("back.png").path)
        var (code, stdout, stderr) = await invoke(["run", "--new", #"{"width":16,"height":12}"#, "--cmd", "layer.new.layer", "--out", native])
        #expect(code == 0, "\(stderr)")
        (code, _, stderr) = await invoke(["convert", native, ora])
        #expect(code == 0, "\(stderr)")
        (code, stdout, stderr) = await invoke(["info", ora, "--compact"])
        #expect(code == 0, "\(stderr)")
        #expect(try JSONValue.parse(stdout)["layers"]?.arrayValue?.count == 2, "\(stdout)")
        (code, _, stderr) = await invoke(["convert", ora, png])
        #expect(code == 0, "\(stderr)")
        #expect(CLI.isInput(ora))
    }

    @Test func noTypeLayersDoNotProduceMissingFontWarnings() async throws {
        let dir = try tempDir("no-font-warning")
        defer { try? FileManager.default.removeItem(at: dir) }
        let native = dir.appendingPathComponent("blank.pcraft").path, png = dir.appendingPathComponent("blank.png").path
        let (code, _, stderr) = await invoke(["run", "--new", #"{"width":16,"height":16}"#, "--out", native])
        #expect(code == 0, "\(stderr)")
        #expect(!stderr.contains("font '"), "\(stderr)")
        let (code2, stdout, stderr2) = await invoke(["info", native, "--compact"])
        #expect(code2 == 0, "\(stderr2)")
        #expect(try JSONValue.parse(stdout)["warnings"]?.arrayValue?.allSatisfy { $0.stringValue?.contains("font '") != true } == true)
        let (code3, _, stderr3) = await invoke(["convert", native, png])
        #expect(code3 == 0 && !stderr3.contains("font '"), "\(stderr3)")
    }

    /// A batched action that plays another action of its set finds it in every file's session; a
    /// failure inside the called action fails the file, and a self-call stops instead of looping.
    @Test func batchPlaysAnActionThatCallsAnotherActionOfItsSet() async throws {
        let dir = try tempDir("action-set")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = { (name: String) in dir.appendingPathComponent(name).path }
        try FileManager.default.createDirectory(atPath: path("in"), withIntermediateDirectories: true)
        for name in ["a", "b"] {
            let (code, _, stderr) = await invoke(["run", "--new", #"{"width":8,"height":6}"#, "--out", path("in/\(name).png")])
            #expect(code == 0, "\(stderr)")
        }
        let set: JSONValue = ["version": 1, "actions": [
            ["name": "Outer", "steps": [["actions.play", ["action": "Rotate"]]]],
            ["name": "Rotate", "steps": [["image.imageRotation.90cw", .object([:])]]],
            ["name": "Calls bad", "steps": [["actions.play", ["action": "Bad"]]]],
            ["name": "Bad", "steps": [["layer.delete", ["layer": 999_999]]]],
            ["name": "Loop", "steps": [["actions.play", ["action": "Loop"]]]],
        ]]
        try Data(set.serialized().utf8).write(to: URL(fileURLWithPath: path("actions.json")))
        let batch = { (action: String) in await invoke(["batch", "--actions", path("actions.json"), "--action", action, "--in", path("in"), "--out", path(action)]) }
        let (code, stdout, stderr) = await batch("Outer")
        #expect(code == 0, "\(stdout)\(stderr)")
        for name in ["a", "b"] {
            let (c, info, e) = await invoke(["info", path("Outer/\(name).png"), "--compact"])
            #expect(c == 0, "\(e)")
            let v = try JSONValue.parse(info)
            #expect(v["width"] == 6 && v["height"] == 8, "rotated by the called action")
        }
        for action in ["Calls bad", "Loop"] {
            let (c, out, err) = await batch(action)
            #expect(c != 0, "\(out)")
            #expect(err.components(separatedBy: "FAIL").count - 1 == 2, "\(err)")
            #expect(!FileManager.default.fileExists(atPath: path("\(action)/a.png")), "a file whose called action failed is not saved")
        }
    }

    // MARK: tests/cli.rs

    @Test func usageAndUnknownCommand() async {
        let (code, _, err) = await invoke([])
        #expect(code == 2 && err.contains("USAGE"))
        #expect(await invoke(["frobnicate"]).0 == 2)
        let (c2, out, _) = await invoke(["--help"])
        #expect(c2 == 0 && out.contains("convert"))
        let (c3, version, _) = await invoke(["--version"])
        #expect(c3 == 0 && version.hasPrefix("pccli "))
    }

    /// #423: `<subcommand> --help` and `-h` print usage at once, whatever else is on the line.
    @Test func everySubcommandAnswersHelp() async {
        for sub in ["convert", "info", "run", "batch", "droplet", "commands", "mcp", "serve", "control", "coverage"] {
            for help in ["--help", "-h"] {
                let (code, out, err) = await invoke([sub, help, "--out", "x.png"])
                #expect(code == 0, "\(sub) \(help): \(err)")
                #expect(out.contains("USAGE") && out.contains("pccli batch"), "\(sub) \(help)")
            }
        }
    }

    /// #423: a flag the subcommand doesn't take is a usage error naming it, before any work.
    @Test func unknownFlagsAreUsageErrors() async throws {
        let d = try tempDir("flags")
        defer { try? FileManager.default.removeItem(at: d) }
        let input = d.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try writeNoisePNG(input.appendingPathComponent("a.png"), 8, 4, seed: 3)
        let actions = d.appendingPathComponent("actions.json").path
        try Data(#"[{"command":"image.adjustments.invert"}]"#.utf8).write(to: URL(fileURLWithPath: actions))
        let outDir = d.appendingPathComponent("out").path
        func fails(_ args: [String], _ flag: String) async {
            let (code, _, err) = await invoke(args)
            #expect(code == 2, "\(err)")
            #expect(err.contains("unknown flag \(flag)"), "\(err)")
        }
        for typo in [["--fromat", "jpg"], ["--fromat=jpg"]] {
            await fails(["batch", "--actions", actions, "--in", input.path, "--out", outDir] + typo, "--fromat")
            #expect(!FileManager.default.fileExists(atPath: outDir), "nothing written")
        }
        let x = d.appendingPathComponent("x.png").path
        await fails(["run", input.appendingPathComponent("a.png").path, "--cmd", "image.adjustments.invert", "--param", "{}", "--out", x], "--param")
        #expect(!FileManager.default.fileExists(atPath: x))
        // A flag one subcommand takes is still unknown to another; a bare flag takes no value.
        await fails(["info", "--json", input.appendingPathComponent("a.png").path], "--json")
        let (code, _, err) = await invoke(["commands", "--json=yes"])
        #expect(code == 2 && err.contains("--json takes no value"))
        // Every flag still works in both forms.
        let (c1, out1, _) = await invoke(["commands", "--json", "--filter=gaussian"])
        #expect(c1 == 0 && out1.contains("filter.blur.gaussianBlur"))
        let (c2, _, e2) = await invoke(["batch", "--actions", actions, "--in=\(input.path)", "--out", outDir, "--format=jpg", "--quality", "80"])
        #expect(c2 == 0, "\(e2)")
        #expect(FileManager.default.fileExists(atPath: outDir + "/a.jpg"))
        let (c3, out3, _) = await invoke(["info", input.appendingPathComponent("a.png").path, "--compact"])
        #expect(c3 == 0 && !out3.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n"), "compact JSON is one line")
    }

    @Test func convertPngPcraftPngIsLossless() async throws {
        let d = try tempDir("convert")
        defer { try? FileManager.default.removeItem(at: d) }
        let (a, b, c) = (d.appendingPathComponent("a.png"), d.appendingPathComponent("b.pcraft"), d.appendingPathComponent("c.png"))
        try writeNoisePNG(a, 37, 23, seed: 7)
        var (code, _, err) = await invoke(["convert", a.path, b.path])
        #expect(code == 0, "\(err)")
        #expect(PcraftFormat.isPcraft([UInt8](try Data(contentsOf: b))))
        (code, _, err) = await invoke(["convert", b.path, c.path])
        #expect(code == 0, "\(err)")
        let (x, y) = (try ImageCodecs.decode(Data(contentsOf: a)), try ImageCodecs.decode(Data(contentsOf: c)))
        #expect(x.size == y.size)
        let r = PixelRect(x: 0, y: 0, width: x.size.width, height: x.size.height)
        let q = { (v: [Float]) in v.map { UInt8(($0 * 255).rounded()) } }
        #expect(q(x.surface.readRegion(r)) == q(y.surface.readRegion(r)))
        // Format override and lossy warning path.
        let bin = d.appendingPathComponent("out.bin")
        (code, _, err) = await invoke(["convert", a.path, bin.path, "--format", "jpg", "--quality", "60"])
        #expect(code == 0, "\(err)")
        #expect(try Data(contentsOf: bin).prefix(3) == Data([0xFF, 0xD8, 0xFF]))
    }

    @Test func convertErrors() async throws {
        let d = try tempDir("converr")
        defer { try? FileManager.default.removeItem(at: d) }
        #expect(await invoke(["convert", "/missing/in.png", d.appendingPathComponent("x.png").path]).0 == 1)
        #expect(await invoke(["convert", "only-one"]).0 == 1)
    }

    @Test func infoPrintsLayerTreeJSON() async throws {
        let d = try tempDir("info")
        defer { try? FileManager.default.removeItem(at: d) }
        let a = d.appendingPathComponent("a.png").path
        try writeNoisePNG(URL(fileURLWithPath: a), 10, 6, seed: 3)
        let (code, out, _) = await invoke(["info", a])
        #expect(code == 0)
        let v = try JSONValue.parse(out)
        #expect(v["width"] == 10 && v["height"] == 6)
        // An RGBA PNG opens as a normal "Layer 0", not the locked Background (as in Photoshop).
        #expect(v["layers"]?[0]?["name"] == "Layer 0")
        #expect(v["history"] == nil)
        let (_, compact, _) = await invoke(["info", a, "--compact"])
        #expect(compact.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").count == 1)
    }

    @Test func runCommandsAndSave() async throws {
        let d = try tempDir("run")
        defer { try? FileManager.default.removeItem(at: d) }
        let outPc = d.appendingPathComponent("r.pcraft").path
        let (code, out, err) = await invoke(["run", "--new", #"{"width":40,"height":30,"name":"Run"}"#, "--cmd", "layer.new.layer", "--params", #"{"name":"Ink"}"#,
                                             "--cmd", "paint.stroke", "--params", ##"{"points":[[2,2,1],[30,20,1]],"size":5,"color":"#00ff00"}"##,
                                             "--cmd", "document.inspect", "--out", outPc])
        #expect(code == 0, "\(err)")
        let lines = try out.split(separator: "\n").map { try JSONValue.parse(String($0)) }
        #expect(lines.count == 3)
        #expect(lines.last?["command"] == "document.inspect")
        #expect(lines.last?["result"]?["name"] == "Run")
        let (c2, info, e2) = await invoke(["info", outPc])
        #expect(c2 == 0, "\(e2)")
        let v = try JSONValue.parse(info)
        // Saving a native document gives the reopened bundle its output filename.
        #expect(v["name"] == "r.pcraft")
        #expect((v["layers"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue } == ["Ink", "Background"])
        // Continue from the saved file and export PNG.
        let png = d.appendingPathComponent("r.png")
        let (c3, _, e3) = await invoke(["run", outPc, "--cmd", "layer.new.layer", "--out", png.path])
        #expect(c3 == 0, "\(e3)")
        #expect(try ImageCodecs.decode(Data(contentsOf: png)).size == PixelSize(width: 40, height: 30))
    }

    @Test func runStopsAfterFailedActionWithoutExporting() async throws {
        let d = try tempDir("run-failed-action")
        defer { try? FileManager.default.removeItem(at: d) }
        let out = d.appendingPathComponent("result.png").path
        let (code, stdout, error) = await invoke([
            "run", "--new", #"{"width":8,"height":8}"#, "--cmd", "layer.new.layer", "--cmd", "actions.record", "--params", #"{"name":"Delete"}"#,
            "--cmd", "layer.delete", "--cmd", "actions.stop",
            // The recorded deletion succeeded with two layers; replay cannot delete the last one.
            "--cmd", "actions.play", "--params", #"{"action":"Delete"}"#, "--cmd", "document.inspect", "--out", out,
        ])
        #expect(code == 1, "stdout: \(stdout)\nstderr: \(error)")
        #expect(error.contains("actions.play") && error.contains("Delete") && error.contains("step 1"), "\(error)")
        let rows = try stdout.split(separator: "\n").map { try JSONValue.parse(String($0)) }
        #expect(rows.allSatisfy { $0["command"] != "document.inspect" }, "later commands must not run")
        #expect(!FileManager.default.fileExists(atPath: out), "a failed action must not export a partial result")
    }

    @Test func runContinuesAfterSuccessfulActionAndExports() async throws {
        let d = try tempDir("run-successful-action")
        defer { try? FileManager.default.removeItem(at: d) }
        let out = d.appendingPathComponent("result.png").path
        let (code, stdout, stderr) = await invoke([
            "run", "--new", #"{"width":8,"height":8}"#, "--cmd", "actions.record", "--params", #"{"name":"Add"}"#, "--cmd", "layer.new.layer",
            "--cmd", "actions.stop", "--cmd", "actions.play", "--params", #"{"action":"Add"}"#, "--cmd", "document.inspect", "--out", out,
        ])
        #expect(code == 0, "\(stderr)")
        let rows = try stdout.split(separator: "\n").map { try JSONValue.parse(String($0)) }
        let playback = try #require(rows.first { $0["command"] == "actions.play" })
        #expect(playback["result"]?["ran"] == 1)
        #expect(playback["result"]?["failed"] == nil)
        #expect(rows.contains { $0["command"] == "document.inspect" })
        #expect(FileManager.default.fileExists(atPath: out))
    }

    @Test func runErrors() async {
        let (c1, _, e1) = await invoke(["run", "--new", "{}", "--cmd", "no.such"])
        #expect(c1 == 1 && e1.contains("unknown command"))
        #expect(await invoke(["run", "--new", "{}", "--params", "{}"]).0 == 1)
        #expect(await invoke(["run", "--new", "{", "--cmd", "x"]).0 == 1)
        // Params must be a JSON object, for `--new` and for each `--params`.
        let (c2, _, e2) = await invoke(["run", "--new", "[3]", "--cmd", "layer.new.layer"])
        #expect(c2 == 1 && e2.contains("--new") && e2.contains("must be a JSON object"), "\(e2)")
        let (c3, _, e3) = await invoke(["run", "--new", "{}", "--cmd", "layer.new.layer", "--params", "\"x\""])
        #expect(c3 == 1 && e3.contains("layer.new.layer") && e3.contains("must be a JSON object"), "\(e3)")
    }

    @Test func runRejectsInvalidFilterParametersWithoutExporting() async throws {
        let d = try tempDir("invalid-filter-params")
        defer { try? FileManager.default.removeItem(at: d) }
        let out = d.appendingPathComponent("result.png").path
        for (params, key) in [(#"{"radius":"big"}"#, "radius"), (#"{"radus":3}"#, "radus"), (#"{"radius":5000}"#, "radius"), (#"{"radius":-4}"#, "radius")] {
            let (code, _, error) = await invoke(["run", "--new", #"{"width":8,"height":8}"#, "--cmd", "filter.blur.gaussianBlur", "--params", params, "--out", out])
            #expect(code == 1)
            #expect(error.contains("filter.blur.gaussianBlur") && error.contains(key), "\(error)")
            #expect(!FileManager.default.fileExists(atPath: out))
        }
    }

    @Test func batchAppliesActionsToDirectory() async throws {
        let d = try tempDir("batch")
        defer { try? FileManager.default.removeItem(at: d) }
        let inp = d.appendingPathComponent("in").path, outp = d.appendingPathComponent("out").path
        try FileManager.default.createDirectory(atPath: inp, withIntermediateDirectories: true)
        try writeNoisePNG(URL(fileURLWithPath: inp + "/one.png"), 12, 8, seed: 1)
        try writeNoisePNG(URL(fileURLWithPath: inp + "/two.png"), 9, 9, seed: 2)
        try Data("ignored".utf8).write(to: URL(fileURLWithPath: inp + "/notes.txt"))
        let actions = d.appendingPathComponent("actions.json")
        try Data((JSONValue.array([["command": "layer.new.layer", "params": ["name": "Batch"]]])).serialized().utf8).write(to: actions)
        let (code, out, err) = await invoke(["batch", "--actions", actions.path, "--in", inp, "--out", outp, "--format", "pcraft"])
        #expect(code == 0 && out.contains("2 succeeded, 0 failed"), "\(out)\(err)")
        for n in ["one", "two"] {
            let (c, info, e) = await invoke(["info", outp + "/\(n).pcraft"])
            #expect(c == 0, "\(e)")
            #expect(try JSONValue.parse(info)["layers"]?[0]?["name"] == "Batch", "\(n)")
        }
        // A failing action reports and exits 1.
        try Data(#"{"actions":[{"id":"no.such.command"}]}"#.utf8).write(to: actions)
        let (c2, _, e2) = await invoke(["batch", "--actions", actions.path, "--in", inp, "--out", outp])
        #expect(c2 == 1 && e2.contains("FAIL"))
    }

    @Test func batchSkipsRecordedViewAndSaveSteps() async throws {
        let d = try tempDir("batch-shell-steps")
        defer { try? FileManager.default.removeItem(at: d) }
        let input = d.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let source = input.appendingPathComponent("a.png")
        try writeNoisePNG(source, 12, 8, seed: 3)
        let original = try Data(contentsOf: source)
        let recordedSave = d.appendingPathComponent("recorded-save.psd").path
        var cases: [(String, JSONValue)] = [("zoom-in", "view.zoomIn"), ("zoom-out", "view.zoomOut"), ("fit", "view.fitOnScreen"), ("actual-pixels", "view.actualPixels")]
            .map { ($0.0, [[.string($0.1), .object([:])], ["image.imageRotation.90cw", .object([:])]]) }
        cases.append(("save", [["file.save", .object([:])], ["image.imageRotation.90cw", .object([:])]]))
        cases.append(("save-as", [["file.saveAs", ["path": .string(recordedSave)]], ["image.imageRotation.90cw", .object([:])]]))
        for (name, actions) in cases {
            let file = d.appendingPathComponent("\(name).json")
            try Data(actions.serialized().utf8).write(to: file)
            let (code, out, err) = await invoke(["batch", "--actions", file.path, "--in", input.path, "--out", d.appendingPathComponent(name).path])
            #expect(code == 0 && out.contains("1 succeeded, 0 failed"), "\(name): \(out)\n\(err)")
            let (_, info, _) = await invoke(["info", d.appendingPathComponent(name).appendingPathComponent("a.png").path])
            let v = try JSONValue.parse(info)
            #expect(v["width"] == 8 && v["height"] == 12, "\(name)")
            #expect(try Data(contentsOf: source) == original, "\(name) changed its input")
            #expect(!FileManager.default.fileExists(atPath: recordedSave), "\(name) wrote the recorded Save As path")
        }
    }

    @Test func parseActionsFormats() throws {
        let a = try CLI.parseActions(#"[{"command":"a","params":{"x":1}},{"id":"b"}]"#)
        #expect(a.map(\.0) == ["a", "b"] && a.map(\.1) == [["x": 1], .object([:])])
        #expect(try CLI.parseActions(#"{"actions":[{"command":"c"}]}"#).count == 1)
        #expect(throws: (any Error).self) { try CLI.parseActions(#"[{"params":{}}]"#) }
        #expect(throws: (any Error).self) { try CLI.parseActions("7") }
        // #489: the step shapes a recorded action and a droplet store, bare or wrapped.
        for text in [#"[["a",{"x":1}],["b"]]"#, #"[["a",{"x":1}],"b"]"#, #"{"steps":[["a",{"x":1}],["b",{}]]}"#,
                     #"{"photocraftDroplet":1,"action":{"steps":[["a",{"x":1}],{"command":"b"}]}}"#, #"{"actions":[["a",{"x":1}],["b",{}]]}"#] {
            let got = try CLI.parseActions(text)
            #expect(got.map(\.0) == ["a", "b"] && got.map(\.1) == [["x": 1], .object([:])], "\(text)")
        }
        for text in ["[42]", "[[]]", "[[7,{}]]", #"{"name":"x"}"#] {
            #expect(throws: (any Error).self, "\(text)") { try CLI.parseActions(text) }
        }
    }

    func batchWith(_ d: URL, _ input: URL, _ name: String, _ actions: String, _ extra: [String] = []) async throws -> (Int32, String, String) {
        let file = d.appendingPathComponent("\(name).json")
        try Data(actions.utf8).write(to: file)
        return await invoke(["batch", "--actions", file.path, "--in", input.path, "--out", d.appendingPathComponent(name).path] + extra)
    }

    /// #489: `batch --actions` takes `[id, params]` steps and a droplet's steps, with the same
    /// results as the object form; a malformed step fails before anything is written.
    @Test func batchAcceptsRecordedActionSteps() async throws {
        let d = try tempDir("batch-steps")
        defer { try? FileManager.default.removeItem(at: d) }
        let input = d.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try writeNoisePNG(input.appendingPathComponent("a.png"), 8, 4, seed: 3)
        try writeNoisePNG(input.appendingPathComponent("b.png"), 6, 5, seed: 9)
        for (name, actions) in [("objects", #"[{"command":"image.adjustments.invert"}]"#), ("pairs", #"[["image.adjustments.invert",{}]]"#),
                                ("ids", #"["image.adjustments.invert"]"#), ("droplet", #"{"photocraftDroplet":1,"action":{"steps":[["image.adjustments.invert",{}]]}}"#)] {
            let (code, out, err) = try await batchWith(d, input, name, actions)
            #expect(code == 0 && out.contains("2 succeeded, 0 failed"), "\(name): \(err)")
            for f in ["a.png", "b.png"] {
                #expect(try Data(contentsOf: d.appendingPathComponent(name).appendingPathComponent(f)) == Data(contentsOf: d.appendingPathComponent("objects").appendingPathComponent(f)),
                        "\(name)/\(f)")
            }
        }
        #expect(try await batchWith(d, input, "bad", "[42]").0 == 1)
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("bad").path), "nothing written")
    }

    /// #490: a leading dot on `--format` doesn't double the dot in output names.
    @Test func batchFormatWithLeadingDot() async throws {
        let d = try tempDir("batch-dot")
        defer { try? FileManager.default.removeItem(at: d) }
        let input = d.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try writeNoisePNG(input.appendingPathComponent("a.png"), 8, 4, seed: 3)
        try writeNoisePNG(input.appendingPathComponent("b.png"), 6, 5, seed: 9)
        for (name, format) in [("dot", ".jpg"), ("plain", "jpg")] {
            let (code, _, err) = try await batchWith(d, input, name, #"[{"command":"image.adjustments.invert"}]"#, ["--format", format])
            #expect(code == 0, "\(format): \(err)")
            #expect(contents(d.appendingPathComponent(name)) == ["a.jpg", "b.jpg"], "\(format)")
            #expect(ImageFormat.detect(try Data(contentsOf: d.appendingPathComponent(name).appendingPathComponent("a.jpg"))) == .jpeg)
        }
    }

    /// #491: `--quality` outside 1-100 is an error for every subcommand, and nothing is written.
    @Test func qualityOutside1To100IsRefused() async throws {
        let d = try tempDir("quality")
        defer { try? FileManager.default.removeItem(at: d) }
        let input = d.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let a = input.appendingPathComponent("a.png").path
        try writeNoisePNG(URL(fileURLWithPath: a), 8, 4, seed: 3)
        for q in ["0", "101", "255", "256", "1000", "-1", "abc", "50.5", ""] {
            let out = d.appendingPathComponent("q.jpg").path
            for args in [["convert", a, out, "--quality", q], ["run", a, "--cmd", "image.adjustments.invert", "--out", out, "--quality", q]] {
                let (code, _, err) = await invoke(args)
                #expect(code == 1, "--quality \(q)")
                #expect(err.contains("bad --quality `\(q)`: expected a whole number from 1 to 100"), "--quality \(q): \(err)")
                #expect(!FileManager.default.fileExists(atPath: out), "--quality \(q) wrote a file")
            }
            #expect(try await batchWith(d, input, "qb", #"[{"command":"image.adjustments.invert"}]"#, ["--format", "jpg", "--quality", q]).0 == 1)
            #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("qb").path), "batch --quality \(q) wrote a folder")
        }
        // The documented range still encodes, lower quality making a smaller file.
        var sizes: [Int] = []
        for q in ["1", "50", "100"] {
            let out = d.appendingPathComponent("q\(q).jpg").path
            #expect(await invoke(["convert", a, out, "--quality", q]).0 == 0)
            sizes.append(try Data(contentsOf: URL(fileURLWithPath: out)).count)
        }
        #expect(sizes[0] <= sizes[1] && sizes[1] <= sizes[2], "\(sizes)")
    }

    /// `--tga-bits` picks a TGA's bits per pixel (byte 16 of its header); anything but 24 or 32
    /// is refused and nothing is written.
    @Test func tgaBitsChooseTheTargaDepth() async throws {
        let d = try tempDir("tga-bits-cli")
        defer { try? FileManager.default.removeItem(at: d) }
        let a = d.appendingPathComponent("a.png").path
        try writeNoisePNG(URL(fileURLWithPath: a), 8, 4, seed: 3)
        for (bits, want) in [(nil, 32), ("24", 24), ("32", 32)] as [(String?, UInt8)] {
            let out = d.appendingPathComponent("a.tga").path
            let (code, _, err) = await invoke(["convert", a, out] + (bits.map { ["--tga-bits", $0] } ?? []))
            #expect(code == 0, "\(err)")
            let bytes = try Data(contentsOf: URL(fileURLWithPath: out))
            #expect(bytes.count > 16 && bytes[16] == want, "--tga-bits \(String(describing: bits))")
        }
        for bad in ["16", "0", "abc", ""] {
            let out = d.appendingPathComponent("bad.tga").path
            let (code, _, err) = await invoke(["convert", a, out, "--tga-bits", bad])
            #expect(code == 1 && err.contains("bad --tga-bits `\(bad)`: expected 24 or 32"), "--tga-bits \(bad): \(err)")
            #expect(!FileManager.default.fileExists(atPath: out))
        }
    }

    /// #492: an `--out` folder that is the `--in` folder, however it is spelt, is refused before
    /// anything is written, unless `--in-place` asks for it.
    @Test func batchRefusesToWriteOverItsInputs() async throws {
        let d = try tempDir("batch-in-place")
        defer { try? FileManager.default.removeItem(at: d) }
        let input = d.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try writeNoisePNG(input.appendingPathComponent("a.png"), 8, 4, seed: 3)
        var tif = Surface(format: .rgba8)
        tif.fill(PixelRect(x: 0, y: 0, width: 8, height: 4), with: [0.35, 0.35, 0.35, 1])
        try ImageCodecs.encode(tif, rect: PixelRect(x: 0, y: 0, width: 8, height: 4), as: .tiff).write(to: input.appendingPathComponent("a.tif"))
        let actions = d.appendingPathComponent("actions.json").path
        try Data(#"[{"command":"image.adjustments.invert"}]"#.utf8).write(to: URL(fileURLWithPath: actions))
        let snapshot = { try contents(input).map { ($0, try Data(contentsOf: input.appendingPathComponent($0))) } }
        let before = try snapshot()
        try FileManager.default.createSymbolicLink(at: d.appendingPathComponent("link"), withDestinationURL: input)
        for out in [input.path, input.path + "/", input.path + "/.", d.appendingPathComponent("link").path] {
            for extra in [[], ["--format", "tif"]] {
                let (code, _, err) = await invoke(["batch", "--actions", actions, "--in", input.path, "--out", out] + extra)
                #expect(code == 1, "--out \(out) \(extra): \(err)")
                #expect(err.contains("is the --in folder") && err.contains("--in-place"), "\(err)")
                #expect(try snapshot().map(\.1) == before.map(\.1), "--out \(out) changed the originals")
            }
        }
        // A separate folder runs as before, leaving the originals alone.
        let (c1, out1, _) = await invoke(["batch", "--actions", actions, "--in", input.path, "--out", d.appendingPathComponent("out").path])
        #expect(c1 == 0 && out1.contains("2 succeeded, 0 failed"), "\(out1)")
        #expect(try snapshot().map(\.1) == before.map(\.1))
        // `--in-place` opts in: each result replaces its original.
        let (c2, _, e2) = await invoke(["batch", "--actions", actions, "--in", input.path, "--out", input.path, "--in-place"])
        #expect(c2 == 0, "\(e2)")
        let after = try snapshot()
        #expect(after.count == 2 && zip(after, before).allSatisfy { $0.0 == $1.0 && $0.1 != $1.1 }, "both inputs replaced")
    }

    @Test func commandsListing() async throws {
        let (code, out, _) = await invoke(["commands"])
        #expect(code == 0 && out.contains("file.new"))
        let (_, json, _) = await invoke(["commands", "--json", "--filter", "layer.new"])
        let rows = try JSONValue.parse(json).arrayValue ?? []
        #expect(rows.allSatisfy { ($0["id"]?.stringValue ?? "").contains("layer.new") || ($0["label"]?.stringValue ?? "").lowercased().contains("layer.new") })
    }

    /// `--format` mapping two inputs to one name fails the second instead of overwriting the first.
    @Test func batchFailsInputsThatShareAnOutputName() async throws {
        let d = try tempDir("batch-collide")
        defer { try? FileManager.default.removeItem(at: d) }
        let input = d.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try writeNoisePNG(input.appendingPathComponent("a.png"), 8, 4, seed: 3)
        var s = Surface(format: .rgba8)
        s.fill(PixelRect(x: 0, y: 0, width: 8, height: 4), with: [0.35, 0.35, 0.35, 1])
        for (name, format) in [("a.bmp", ImageFormat.bmp), ("A.tif", .tiff)] {
            try ImageCodecs.encode(s, rect: PixelRect(x: 0, y: 0, width: 8, height: 4), as: format).write(to: input.appendingPathComponent(name))
        }
        let actions = d.appendingPathComponent("actions.json").path
        try Data(#"[{"command":"image.adjustments.invert"}]"#.utf8).write(to: URL(fileURLWithPath: actions))
        let (code, out, err) = await invoke(["batch", "--actions", actions, "--in", input.path, "--out", d.appendingPathComponent("out").path, "--format", "png"])
        #expect(code != 0, "a lost result must fail the run\n\(out)\n\(err)")
        #expect(out.contains("1 succeeded, 2 failed"), "\(out)")
        #expect(err.components(separatedBy: "not written").count - 1 == 2, "\(err)")
        #expect(contents(d.appendingPathComponent("out")).count == 1)
        // Keeping each file's format, every input gets its own output.
        let (c2, out2, _) = await invoke(["batch", "--actions", actions, "--in", input.path, "--out", d.appendingPathComponent("same").path])
        #expect(c2 == 0 && out2.contains("3 succeeded, 0 failed"), "\(out2)")
    }

    @Test func dropletRunsAnActionOnFiles() async throws {
        let d = try tempDir("droplet")
        defer { try? FileManager.default.removeItem(at: d) }
        try writeNoisePNG(d.appendingPathComponent("a.png"), 8, 4, seed: 3)
        try writeNoisePNG(d.appendingPathComponent("b.png"), 6, 2, seed: 5)
        let droplet = d.appendingPathComponent("rot.pcdroplet")
        let spec: JSONValue = ["photocraftDroplet": 1, "name": "rot", "action": ["steps": [["image.imageRotation.90cw", .object([:])]]], "options": ["format": "png"]]
        try Data(spec.serialized().utf8).write(to: droplet)
        let outDir = d.appendingPathComponent("out")
        let (code, out, err) = await invoke(["droplet", droplet.path, d.appendingPathComponent("a.png").path, d.appendingPathComponent("b.png").path, "--out", outDir.path])
        #expect(code == 0, "\(err)")
        #expect(out.split(separator: "\n").filter { $0.hasPrefix("ok") }.count == 2, "\(out)")
        #expect(try ImageCodecs.decode(Data(contentsOf: outDir.appendingPathComponent("a.png"))).size == PixelSize(width: 4, height: 8))
        let (c2, _, _) = await invoke(["droplet", d.appendingPathComponent("a.png").path, d.appendingPathComponent("b.png").path])
        #expect(c2 != 0, "not a droplet")
    }

    @Test func tiffOutputIsFlatUnlessTiffLayersIsGiven() async throws {
        let d = try tempDir("tiff-layers")
        defer { try? FileManager.default.removeItem(at: d) }
        func layerCount(_ path: String) async throws -> Int? {
            let (code, info, err) = await invoke(["info", path])
            #expect(code == 0, "\(err)")
            return try JSONValue.parse(info)["layers"]?.arrayValue?.count
        }
        for (name, flag, layers) in [("flat.tif", nil, 1), ("layered.tif", "--tiff-layers", 2)] as [(String, String?, Int)] {
            let out = d.appendingPathComponent(name).path
            let args = ["run", "--new", #"{"width":16,"height":16}"#, "--cmd", "layer.new.layer", "--params", #"{"name":"Ink"}"#] + (flag.map { [$0] } ?? []) + ["--out", out]
            let (code, _, err) = await invoke(args)
            #expect(code == 0, "\(err)")
            #expect(try await layerCount(out) == layers, "\(name)")
        }
        // convert honours the same flag.
        let src = d.appendingPathComponent("layered.tif").path
        let flat = d.appendingPathComponent("converted.tif").path
        #expect(await invoke(["convert", src, flat]).0 == 0)
        #expect(try await layerCount(flat) == 1)
        let kept = d.appendingPathComponent("kept.tif").path
        #expect(await invoke(["convert", src, kept, "--tiff-layers"]).0 == 0)
        #expect(try await layerCount(kept) == 2)
    }

    /// Issue #1108: a non-UTF-8 argument is a usage error naming the argument, never a trap.
    @Test func aNonUnicodeArgumentIsAUsageErrorNotATrap() async {
        for args in [[Array("info".utf8), [0x63, 0x61, 0x66, 0xE9] + Array(".png".utf8)],
                     [Array("convert".utf8), [0x63, 0x61, 0x66, 0xE9] + Array(".png".utf8), Array("out.png".utf8)]] {
            let c = Capture()
            let code = await CLI.run(raw: args, io: c.io)
            #expect(code == 2, "\(c.stderr)")
            #expect(c.stderr.contains("argument 2 is not valid Unicode") && c.stderr.contains("caf\u{FFFD}.png"), "\(c.stderr)")
        }
    }
}
