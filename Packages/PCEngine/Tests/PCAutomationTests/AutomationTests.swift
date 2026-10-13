// Port of photocraft-cli's and photocraft-automation's tests (apps/photocraft-cli/src/lib.rs tests, crates/automation/src/rpc.rs tests, crates/automation/tests/mcp.rs, mcp_wire.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import MCP
import PCAutomation
import PCDocument
import PCEngine
import PCFoundation
import PCPlatform
import Synchronization
import Testing

/// Captures CLI output.
final class Capture: Sendable {
    let out = Mutex("")
    let err = Mutex("")
    var io: CLI.IO { CLI.IO(out: { s in self.out.withLock { $0 += s } }, err: { s in self.err.withLock { $0 += s } }) }
    var stdout: String { out.withLock { $0 } }
    var stderr: String { err.withLock { $0 } }
}

func tempDir(_ name: String) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("pccli-tests-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Copies a PSD a test wrote into the Photoshop oracle agent's folder: `PCIO_EXPORT_DIR`, as for
/// PCIO's tests, when set and not `none`. Unset, nothing is dropped (never into the fixtures folder
/// by default).
func dropForOracle(_ file: URL, as name: String) {
    guard let p = ProcessInfo.processInfo.environment["PCIO_EXPORT_DIR"], !p.isEmpty, p != "none" else { return }
    let dest = URL(fileURLWithPath: p).appendingPathComponent("pcengine-\(name)")
    try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: dest)
    try? FileManager.default.copyItem(at: file, to: dest)
}

/// A generated 8-bit RGB PNG: a red left half and a blue right half.
func writeTestPNG(_ url: URL, width: Int = 32, height: Int = 16) throws {
    var s = Surface(format: .rgba8)
    s.fill(PixelRect(x: 0, y: 0, width: width / 2, height: height), with: [1, 0, 0, 1])
    s.fill(PixelRect(x: width / 2, y: 0, width: width - width / 2, height: height), with: [0, 0, 1, 1])
    let data = try ImageCodecs.encode(s, rect: PixelRect(x: 0, y: 0, width: width, height: height), as: .png)
    try data.write(to: url)
}

@Suite struct CLITests {
    @Test func runInvertsAGeneratedPNGEndToEnd() async throws {
        let dir = try tempDir("run")
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.png"), output = dir.appendingPathComponent("out.png")
        try writeTestPNG(input)
        let c = Capture()
        let code = await CLI.run(["run", input.path, "--cmd", "layer.new.layer", "--params", #"{"name":"Ink"}"#,
                                  "--cmd", "layer.delete", "--cmd", "image.adjustments.invert", "--out", output.path], io: c.io)
        #expect(code == 0, "\(c.stderr)")
        let lines = c.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        let first = try JSONValue.parse(lines[0])
        #expect(first["command"] == "layer.new.layer")
        #expect(first["result"]?["layer"]?.uint64Value != nil)
        // The output is the input inverted: cyan left, yellow right.
        let img = try ImageCodecs.decode(Data(contentsOf: output))
        #expect(img.size == PixelSize(width: 32, height: 16))
        let left = img.surface.rgba(x: 2, y: 2), right = img.surface.rgba(x: 30, y: 2)
        #expect(abs(left.x - 0) < 0.01 && abs(left.y - 1) < 0.01 && abs(left.z - 1) < 0.01)
        #expect(abs(right.x - 1) < 0.01 && abs(right.y - 1) < 0.01 && abs(right.z - 0) < 0.01)
    }

    @Test func runWithNewDocumentAndBadFlags() async throws {
        let dir = try tempDir("new")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("blank.png")
        let c = Capture()
        #expect(await CLI.run(["run", "--new", #"{"width":8,"height":6,"background":"black"}"#, "--out", out.path], io: c.io) == 0)
        let img = try ImageCodecs.decode(Data(contentsOf: out))
        #expect(img.size == PixelSize(width: 8, height: 6))
        #expect(img.surface.rgba(x: 1, y: 1).x < 0.01)
        let c2 = Capture()
        #expect(await CLI.run(["run", "--new", "{}", "--fromat", "png"], io: c2.io) == 2)
        #expect(c2.stderr.contains("unknown flag --fromat"))
        let c3 = Capture()
        #expect(await CLI.run(["run", "--new", #"{"width":4,"height":4}"#, "--cmd", "nope.nope"], io: c3.io) == 1)
        #expect(c3.stderr.contains("unknown command `nope.nope`"))
    }

    @Test func commandsListsTheRegistry() async throws {
        let c = Capture()
        #expect(await CLI.run(["commands", "--json", "--filter", "gaussian"], io: c.io) == 0)
        let rows = try #require(try JSONValue.parse(c.stdout).arrayValue)
        #expect(rows.contains { $0["id"] == "filter.blur.gaussianBlur" })
        #expect(rows.allSatisfy { $0["needsDocument"] != nil && $0["disabledReason"] != nil })
        let c2 = Capture()
        #expect(await CLI.run(["commands"], io: c2.io) == 0)
        #expect(c2.stdout.split(separator: "\n").count == CommandRegistry.standard().count)
    }

    @Test func infoAndConvert() async throws {
        let dir = try tempDir("info")
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.png")
        try writeTestPNG(input)
        let c = Capture()
        #expect(await CLI.run(["info", input.path, "--compact"], io: c.io) == 0)
        let info = try JSONValue.parse(c.stdout)
        #expect(info["width"]?.intValue == 32)
        #expect(info["layers"]?.arrayValue?.count == 1)
        let tif = dir.appendingPathComponent("out.tif")
        #expect(await CLI.run(["convert", input.path, tif.path], io: Capture().io) == 0)
        #expect(try ImageCodecs.decode(Data(contentsOf: tif)).size == PixelSize(width: 32, height: 16))
    }

    @Test func psdRunConvertAndInfo() async throws {
        let dir = try tempDir("psd")
        defer { try? FileManager.default.removeItem(at: dir) }
        let psd = dir.appendingPathComponent("made.psd"), png = dir.appendingPathComponent("made.png"), out = dir.appendingPathComponent("edited.psd")
        // pccli writes a layered PSD…
        let c = Capture()
        #expect(await CLI.run(["run", "--new", #"{"width":40,"height":30,"background":"white"}"#, "--cmd", "layer.new.layer", "--params", #"{"name":"Ink"}"#,
                               "--cmd", "paint.stroke", "--params", ##"{"points":[[5,5],[35,25]],"size":5,"color":"#ff0000"}"##,
                               "--cmd", "layer.setProps", "--params", #"{"blend":"multiply","opacity":0.8}"#, "--out", psd.path], io: c.io) == 0, "\(c.stderr)")
        // …reads it back with its layers…
        let i = Capture()
        #expect(await CLI.run(["info", psd.path, "--compact"], io: i.io) == 0, "\(i.stderr)")
        let info = try JSONValue.parse(i.stdout)
        #expect(info["layers"]?.arrayValue?.count == 2)
        #expect(info["layers"]?.arrayValue?.contains { $0["name"] == "Ink" && $0["blend"] == "Multiply" } == true, "\(info)")
        // …converts it to a flat image…
        #expect(await CLI.run(["convert", psd.path, png.path], io: Capture().io) == 0)
        let img = try ImageCodecs.decode(Data(contentsOf: png))
        #expect(img.size == PixelSize(width: 40, height: 30))
        #expect(img.surface.rgba(x: 20, y: 15).y < 0.3, "the stroke is in the merged image")
        // …and edits it, PSD to PSD.
        #expect(await CLI.run(["run", psd.path, "--cmd", "image.adjustments.invert", "--out", out.path], io: Capture().io) == 0)
        let i2 = Capture()
        #expect(await CLI.run(["info", out.path, "--compact"], io: i2.io) == 0)
        #expect(try JSONValue.parse(i2.stdout)["layers"]?.arrayValue?.count == 2)
        for (f, n) in [(psd, "cli-made.psd"), (out, "cli-edited.psd")] { dropForOracle(f, as: n) }
    }

    @Test func coverageReport() async throws {
        let c = Capture()
        #expect(await CLI.run(["coverage", "--json"], io: c.io) == 0)
        let r = try JSONValue.parse(c.stdout)
        #expect(r["total"]?.intValue == PhotocraftCatalog.commands.count)
        #expect(r["missing"]?.intValue == 0)
    }
}

@Suite struct ControlChannelTests {
    @Test func jsonLinesSession() throws {
        let dir = try tempDir("control")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTestPNG(dir.appendingPathComponent("in.png"))
        let h = Headless(filesystem: .workspace(try AuthorizedWorkspace(readRoot: dir.path, writeRoot: dir.path)))
        let replies = ControlServer.respondAll(h, """
            {"id":1,"method":"doc.open","params":{"path":"in.png"}}
            {"id":2,"method":"batch","params":{"steps":[{"command":"image.adjustments.invert"},{"command":"layer.new.layer","params":{"name":"A"}}]}}
            {"id":3,"method":"doc.save","params":{"path":"out.png"}}
            {"id":4,"method":"doc.inspect"}
            {"id":5,"method":"methods"}
            {"id":6,"method":"nope"}
            not json
            {"id":7,"method":"engine.execute","params":{"command":"file.open","params":{"path":"/etc/passwd"}}}
            {"id":8,"method":"doc.open","params":{"path":"../escape.png"}}
            {"id":9,"method":"doc.render","params":{"maxSide":8}}
            """)
        #expect(replies.count == 10)
        #expect(replies[0]["ok"] == true)
        #expect(replies[0]["result"]?["width"]?.intValue == 32)
        #expect(replies[1]["result"]?["completed"]?.intValue == 2)
        #expect(replies[2]["ok"] == true, "\(replies[2])")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("out.png").path))
        #expect(replies[3]["result"]?["layers"]?.arrayValue?.count == 2)
        #expect(replies[4]["result"]?.arrayValue?.count == Headless.methods.count)
        #expect(replies[5]["ok"] == false)
        #expect(replies[6]["id"] == .null && replies[6]["ok"] == false)
        #expect(replies[7]["error"]?.stringValue?.contains("ambient filesystem paths") == true)
        #expect(replies[8]["error"]?.stringValue?.contains("parent traversal") == true)
        #expect(replies[9]["result"]?["mime"] == "image/png")
    }

    @Test func untrustedSessionsFailClosedWithoutRoots() throws {
        let h = Headless(filesystem: .denied)
        let r = ControlServer.respondAll(h, #"{"id":1,"method":"doc.open","params":{"path":"x.png"}}"#)
        #expect(r[0]["error"]?.stringValue?.contains("read authority is absent") == true)
    }

    @Test func batchStepLimit() throws {
        let h = Headless(filesystem: .denied)
        let steps = JSONValue.array((0...Headless.maxBatchSteps).map { _ in ["command": "session.inspect"] })
        #expect(throws: EngineError.self) { try h.batch(["steps": steps]) }
    }
}

@Suite struct MCPTests {
    @Test func toolsListAndCommandRunOverInMemoryTransport() async throws {
        let host = EngineHost(filesystem: .denied)
        let server = await MCPBridge.makeServer(host)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "pccli-tests", version: "1.0")
        _ = try await client.connect(transport: clientTransport)
        let (tools, _) = try await client.listTools()
        let names = Set(tools.map(\.name))
        for n in ["session_list", "doc_new", "doc_open", "doc_save", "doc_inspect", "doc_render_preview", "command_list", "command_run", "command_batch",
                  "jobs_list", "jobs_cancel"] {
            #expect(names.contains(n), "missing tool \(n)")
        }
        let run = try await client.callTool(name: "command_run", arguments: ["id": "file.new", "params": ["width": 16, "height": 16]])
        #expect(run.isError != true)
        let layer = try await client.callTool(name: "command_run", arguments: ["id": "layer.new.layer"])
        guard case .text(let text, _, _)? = layer.content.first else { Issue.record("no text content"); return }
        #expect(try JSONValue.parse(text)["layer"]?.uint64Value != nil)
        let preview = try await client.callTool(name: "doc_render_preview", arguments: ["max_side": 8])
        guard case .image(_, let mime, _, _)? = preview.content.first else { Issue.record("no image content"); return }
        #expect(mime == "image/png")
        let bad = try await client.callTool(name: "command_run", arguments: ["id": "file.open", "params": ["path": "/etc/passwd"]])
        #expect(bad.isError == true)
        await client.disconnect()
        await server.stop()
    }

    @Test func perCommandToolsExposeTheRegistry() async throws {
        let host = EngineHost(filesystem: .denied)
        let server = await MCPBridge.makeServer(host, perCommandTools: true)
        let (ct, st) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: st)
        let client = Client(name: "pccli-tests", version: "1.0")
        _ = try await client.connect(transport: ct)
        var all: [Tool] = []
        var cursor: String?
        repeat {
            let (tools, next) = try await client.listTools(cursor: cursor)
            all += tools
            cursor = next
        } while cursor != nil
        let available = CommandRegistry.standard().specs.filter(\.isAvailable).count
        #expect(all.filter { $0.name.hasPrefix("cmd_") }.count == available)
        let t = try #require(all.first { $0.name == "cmd_layer_new_layer" })
        #expect(t.description?.contains("layer.new.layer") == true)
        let r = try await client.callTool(name: "cmd_file_new", arguments: ["width": 8, "height": 8])
        #expect(r.isError != true)
        await client.disconnect()
        await server.stop()
    }
}
