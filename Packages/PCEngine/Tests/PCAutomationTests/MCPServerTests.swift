// Port of photocraft-automation's MCP tests (crates/automation/src/server.rs and server/transport.rs `mod tests`, tests/mcp.rs, tests/mcp_wire.rs, tests/agent_tasks.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Skipped: `strict_schema_inlines_refs…` (the native tool schemas are written strict, there is no
// schemars output to rewrite; `toolSchemasPassStrictValidators` checks the result),
// `a_panicking_command_does_not_wedge_the_session` (no unwinding in Swift),
// and `ui_set_description_names_every_accepted_field` (reads the egui shell's source).
// agent_tasks.rs's scripted runs are in AgentTasksTests.

import Darwin
import Foundation
import MCP
@testable import PCAutomation
import PCDocument
import PCEngine
import PCFormat
import PCFoundation
import PCPlatform
import Synchronization
import Testing

/// An MCP client connected to `mcp` in memory (rmcp's duplex in photocraft's tests).
func connect(_ mcp: PhotocraftMCP) async throws -> (Client, Server) {
    let server = await mcp.makeServer()
    let (ct, st) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: st)
    let client = Client(name: "pccli-tests", version: "1.0")
    _ = try await client.connect(transport: ct)
    return (client, server)
}

func disconnect(_ c: Client, _ s: Server) async {
    await c.disconnect()
    await s.stop()
}

typealias ToolReply = (content: [Tool.Content], isError: Bool?)

func call(_ c: Client, _ name: String, _ args: JSONValue = .object([:])) async throws -> ToolReply {
    try await c.callTool(name: name, arguments: MCPBridge.value(args).objectValue)
}

func text(_ r: ToolReply) -> String {
    r.content.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } }.joined(separator: "\n")
}

func jsonOf(_ r: ToolReply, sourceLocation: SourceLocation = #_sourceLocation) throws -> JSONValue {
    #expect(r.isError != true, "tool error: \(text(r))", sourceLocation: sourceLocation)
    return try JSONValue.parse(text(r))
}

func image(_ r: ToolReply) -> (data: String, mime: String)? {
    for c in r.content { if case .image(let d, let m, _, _) = c { return (d, m) } }
    return nil
}

func allTools(_ c: Client) async throws -> [Tool] {
    var all: [Tool] = []
    var cursor: String?
    repeat {
        let (tools, next) = try await c.listTools(cursor: cursor)
        all += tools
        cursor = next
    } while cursor != nil
    return all
}

func headlessIn(_ root: URL) throws -> PhotocraftMCP {
    PhotocraftMCP.headless(workspace: try AuthorizedWorkspace(readRoot: root.path, writeRoot: root.path))
}

/// photocraft's `fake_app`: a control server answering the methods the bridge forwards, writing a
/// stale reply line before each real one (to check id matching).
func fakeApp(screenshot: Data? = nil) throws -> (FakeServer, Seen) {
    let seen = Seen()
    let server = try FakeServer(maxConnections: 1) { conn, reader, _ in
        var authenticated = false
        while let line = FakeServer.readLine(reader), let req = try? JSONValue.parse(line) {
            let id = req["id"] ?? .null, method = req["method"]?.stringValue ?? ""
            let reply: JSONValue
            switch method {
            case "auth" where req["params"]?["token"]?.stringValue == controlToken:
                authenticated = true
                reply = ["id": id, "ok": true, "result": ["authenticated": true]]
            case _ where !authenticated: reply = ["id": id, "ok": false, "error": "authentication required"]
            case "ui.inspect": reply = ["id": id, "ok": true, "result": ["tool": "brush", "panels": ["layers"]]]
            case "engine.execute":
                reply = ["id": id, "ok": true, "result": ["ran": req["params"]?["command"] ?? .null, "params": req["params"]?["params"] ?? .null,
                                                         "wait": req["params"]?["wait"] ?? .null]]
            case "app.save": reply = ["id": id, "ok": true, "result": ["saved": req["params"] ?? .null]]
            case "engine.commands": reply = ["id": id, "ok": true, "result": [["id": "file.new", "label": "New…", "enabled": true]]]
            case "ui.pointer": reply = ["id": id, "ok": true, "result": req["params"] ?? .null]
            case "ui.screenshot":
                var bytes = screenshot
                if bytes == nil {
                    var s = Surface(format: .rgba8)
                    s.fill(PixelRect(x: 0, y: 0, width: 40, height: 20), with: [0.04, 0.04, 0.04, 0.04])
                    bytes = try? ImageCodecs.encode(s, rect: PixelRect(x: 0, y: 0, width: 40, height: 20), as: .png)
                }
                reply = ["id": id, "ok": true, "result": ["mimeType": "image/png", "base64": .string(bytes?.base64EncodedString() ?? "")]]
            default: reply = ["id": id, "ok": false, "error": .string("unknown tool `\(method)`")]
            }
            _ = FakeServer.write(conn, ["id": 999_999, "ok": true, "result": .null])
            _ = FakeServer.write(conn, reply)
            seen.add(req)
        }
    }
    return (server, seen)
}

func bridgeMCP(_ server: FakeServer, token: String = controlToken) throws -> PhotocraftMCP { try PhotocraftMCP.bridge(server.address, token: token) }

@Suite struct MCPServerTests {
    // MARK: server.rs

    @Test func mcpTextChecksTheEncodedToolEnvelope() {
        // JSON escaping in the outer text-content envelope also consumes the budget.
        let result = PhotocraftMCP.okJSON(.string(String(repeating: "\n", count: Budgets.maxResponseBytes / 3)))
        #expect(result.isError == true)
        #expect(PhotocraftMCP.encodedSize(result) < Budgets.maxResponseBytes)
        let error = PhotocraftMCP.fail(String(repeating: "x", count: Budgets.maxResponseBytes))
        #expect(error.isError == true)
        #expect(PhotocraftMCP.encodedSize(error) < Budgets.maxResponseBytes)
    }

    @Test func bridgeScreenshotDecodeLimitsApplyEvenWithoutDownscaling() throws {
        var s = Surface(format: .rgba8)
        s.fill(PixelRect(x: 0, y: 0, width: 8193, height: 1), with: [0, 0, 0, 0])
        let png = try ImageCodecs.encode(s, rect: PixelRect(x: 0, y: 0, width: 8193, height: 1), as: .png)
        #expect(throws: EngineError.self) { try FlatFiles.downscalePNG(Data("not a png".utf8), maxSide: 32) }
        #expect(throws: EngineError.self) { try FlatFiles.downscalePNG(png, maxSide: 0) }
        #expect(throws: EngineError.self) { try FlatFiles.downscalePNG(png, maxSide: 1024) }
    }

    @Test func mcpReportsInvalidFilterParametersWithoutChangingHistory() async throws {
        let mcp = PhotocraftMCP.headless()
        _ = try await mcp.callTool("command_run", ["id": "file.new", "params": ["width": 8, "height": 8]])
        let inspect = { try JSONValue.parse(text((await mcp.callTool("doc_inspect", [:])).asReply)) }
        let before = try await inspect()
        for (params, key) in [(["radius": "big"], "radius"), (["radus": 3], "radus"), (["radius": 5000], "radius"), (["radius": -4], "radius")] as [(JSONValue, String)] {
            for wait in [true, false] {
                let r = try await mcp.callTool("command_run", ["id": "filter.blur.gaussianBlur", "params": MCPBridge.value(params), "wait": .bool(wait)])
                #expect(r.isError == true)
                let e = text(r.asReply)
                #expect(e.contains("filter.blur.gaussianBlur") && e.contains(key), "\(e)")
                #expect(try await inspect() == before)
            }
        }
    }

    /// #504: the batch budget charges escaped sizes, so a batch it stops keeps its step results.
    @Test func mcpCommandBatchStoppedByTheBudgetKeepsItsStepResults() async throws {
        let mcp = PhotocraftMCP.headless()
        var steps = Array(repeating: ["id": "command.list"] as JSONValue, count: ControlSecurity.maxBatchSteps - 1)
        steps.append(["id": "file.new", "params": ["width": 8, "height": 8]])
        let result = try await mcp.callTool("command_batch", ["steps": MCPBridge.value(.array(steps)), "stop_on_error": false])
        #expect(result.isError != true, "\(text(result.asReply).prefix(200))")
        let reply = try JSONValue.parse(text(result.asReply))
        let results = reply["results"]?.arrayValue ?? []
        #expect(results.last?["error"]?.stringValue?.contains("batch response budget exceeded") == true)
        #expect(reply["completed"]?.intValue == results.count - 1)
        #expect(reply["failed"] == 1)
        guard case .headless(let host) = mcp.backend else { return }
        #expect(try await host.withHeadless { $0.session.documents.count } == 0, "the step after the budget ran out did not run")
    }

    /// #503: the MCP server applies finished jobs before every tool call too.
    @Test func mcpToolsSeeAFinishedBackgroundJob() async throws {
        let mcp = PhotocraftMCP.headless()
        guard case .headless(let host) = mcp.backend else { return }
        _ = try await host.withHeadless { h in
            try h.commandRun("file.new", ["width": 64, "height": 48])
            try h.commandRun("filter.noise.addNoise", ["amount": 50])
            return try h.commandStart("filter.blur.gaussianBlur", ["radius": 4], wait: false)
        }
        let start = Date()
        while true {
            let inspected = try JSONValue.parse(text(try await mcp.callTool("doc_inspect", [:]).asReply))
            if inspected["history"]?.arrayValue?.last == "Gaussian Blur" { break }
            #expect(Date().timeIntervalSince(start) < 60, "doc_inspect never saw the finished job")
            if Date().timeIntervalSince(start) >= 60 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: server/transport.rs

    @Test func boundedLineAcceptsExactLimitAndFinalLine() throws {
        let input = LineReader(data: Data("1234\nlast!".utf8))
        #expect(try input.readMCPLine(maximum: 5) == "1234")
        #expect(try input.readMCPLine(maximum: 5) == "last!")
        #expect(try input.readMCPLine(maximum: 5) == nil)
        #expect(throws: EngineError.self) { try LineReader(data: Data("longer".utf8)).readMCPLine(maximum: 5) }
    }

    @Test func oversizedValidToolCallNeverReachesDispatch() async throws {
        let initialize: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                     "params": ["protocolVersion": "2025-06-18", "capabilities": .object([:]), "clientInfo": ["name": "admission-test", "version": "1"]]]
        var input = Data((initialize.serialized() + "\n" + #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n").utf8)
        let call = Data((["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "doc_new", "arguments": ["width": 8, "height": 8]]] as JSONValue).serialized().utf8)
        #expect(call.count < ControlSecurity.maxRequestBytes)
        input.append(call)
        // The valid JSON prefix spans several reads; only its whitespace suffix crosses the limit.
        input.append(Data(repeating: 0x20, count: ControlSecurity.maxRequestBytes - call.count))
        input.append(0x0A)
        let mcp = PhotocraftMCP.headless()
        do {
            try await mcp.serveIO(reader: LineReader(data: input, chunk: 8192)) { _ in }
            Issue.record("oversized MCP input should end the session with an error")
        } catch {
            #expect("\(error)".contains("request exceeds 1048576 bytes"), "\(error)")
        }
        guard case .headless(let host) = mcp.backend else { return }
        #expect(try await host.withHeadless { $0.session.documents.count } == 0, "the oversized tool call must not run")
    }

    // MARK: tests/mcp_wire.rs

    @Test func malformedLineRecoversAndModernListsAreComplete() async throws {
        let meta: JSONValue = ["io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientInfo": ["name": "test", "version": "1"],
                               "io.modelcontextprotocol/clientCapabilities": .object([:])]
        var lines = [
            (["jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": ["protocolVersion": "2025-06-18", "capabilities": .object([:]), "clientInfo": ["name": "test", "version": "1"]]] as JSONValue).serialized(),
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, "BROKEN",
        ]
        for (id, method, extra) in [(2, "tools/list", JSONValue.object([:])), (3, "resources/list", .object([:])), (4, "resources/read", ["uri": "photocraft://document"])] {
            lines.append((["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": extra.setting("_meta", meta)] as JSONValue).serialized())
        }
        let out = Mutex(Data())
        try await PhotocraftMCP.headless().serveIO(reader: LineReader(data: Data((lines.joined(separator: "\n") + "\n").utf8))) { d in
            out.withLock { $0.append(d) }
        }
        let replies = try String(decoding: out.withLock { $0 }, as: UTF8.self).split(separator: "\n").map { try JSONValue.parse(String($0)) }
        let error = try #require(replies.first { $0["error"]?["code"] == -32700 })
        #expect(error["id"] == .null)
        for id in [2, 3, 4] {
            let reply = try #require(replies.first { $0["id"] == .int(id) }, "no reply \(id)")
            #expect(reply["result"]?["resultType"] == "complete", "\(reply)")
            #expect(reply["result"]?["ttlMs"]?.doubleValue != nil)
            #expect(reply["result"]?["cacheScope"] == "private")
        }
    }

    /// Render Video over the line transport: progress notifications for a progress token (none
    /// without one), a collision that keeps the earlier file, a refused escape, and a cancel
    /// mid-render that answers pings meanwhile and removes only its own frames.
    @Test func videoExportProgressPingCancelAndScopedCleanup() async throws {
        let root = try tempDir("conventions-video")
        defer { try? FileManager.default.removeItem(at: root) }
        let mcp = PhotocraftMCP.headless(workspace: try AuthorizedWorkspace(writeRoot: root.path))
        let input = Pipe()
        let (replies, sink) = AsyncStream<JSONValue>.makeStream()
        let pending = Mutex(Data())
        let server = Task {
            try await mcp.serveIO(reader: LineReader(fd: input.fileHandleForReading.fileDescriptor)) { d in
                pending.withLock { buf in
                    buf.append(d)
                    while let nl = buf.firstIndex(of: 0x0A) {
                        let line = buf[buf.startIndex..<nl]
                        buf.removeSubrange(buf.startIndex...nl)
                        if let v = try? JSONValue.parse(Data(line)) { sink.yield(v) }
                    }
                }
            }
        }
        var it = replies.makeAsyncIterator()
        func send(_ v: JSONValue) { input.fileHandleForWriting.write(Data((v.serialized() + "\n").utf8)) }
        func next() async throws -> JSONValue { try #require(await it.next(), "the server stopped answering") }
        func call(_ id: Int, _ name: String, _ args: JSONValue) -> JSONValue {
            ["jsonrpc": "2.0", "id": .int(id), "method": "tools/call", "params": ["name": .string(name), "arguments": args]]
        }
        func render(_ id: Int, _ dir: String, _ format: String, _ token: JSONValue?) -> JSONValue {
            var v = call(id, "command_run", ["id": "file.export.renderVideo", "params": ["dir": .string(dir), "format": .string(format)]])
            if let token { v = v.setting("params", (v["params"] ?? .null).setting("_meta", ["progressToken": token])) }
            return v
        }
        func entries(_ dir: String) -> Int { (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path).count) ?? -1 }

        send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": ["protocolVersion": "2025-06-18", "capabilities": .object([:]), "clientInfo": ["name": "test", "version": "1"]]])
        _ = try await next()
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        send(call(2, "doc_new", ["width": 64, "height": 48, "name": "clip"]))
        #expect(try await next()["result"]?["isError"] == false)
        send(call(3, "command_run", ["id": "timeline.create", "params": ["duration": 6, "fps": 6]]))
        #expect(try await next()["result"]?["isError"] == false)
        for (id, dir, format, token) in [(4, "complete", "png", JSONValue.string("frames")), (5, "quiet", "png", nil), (6, "gif", "gif", .int(77))] as [(Int, String, String, JSONValue?)] {
            send(render(id, dir, format, token))
            var progress: [Double] = []
            while true {
                let reply = try await next()
                if reply["id"] == .int(id) {
                    #expect(reply["result"]?["isError"] == false, "\(reply)")
                    break
                }
                #expect(token != nil, "no token: \(reply)")
                #expect(reply["params"]?["progressToken"] == token)
                #expect(reply["params"]?["total"]?.doubleValue == 6)
                progress.append(reply["params"]?["progress"]?.doubleValue ?? -1)
            }
            if token != nil {
                #expect(progress.first == 0 && progress.last == 6, "\(progress)")
                #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 < $1 }, "\(progress)")
            }
        }
        #expect(entries("complete") == 6)
        #expect((try? ImageCodecs.decode(Data(contentsOf: root.appendingPathComponent("gif/clip.gif")))) != nil)
        // A collision must preserve the earlier file and remove only frames from this failed run.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("collision"), withIntermediateDirectories: false)
        try Data("earlier export".utf8).write(to: root.appendingPathComponent("collision/clip_0001.png"))
        send(render(7, "collision", "png", nil))
        #expect(try await next()["result"]?["isError"] == true)
        #expect(entries("collision") == 1)
        #expect(try Data(contentsOf: root.appendingPathComponent("collision/clip_0001.png")) == Data("earlier export".utf8))
        send(render(8, "../outside", "png", nil))
        #expect(try await next()["result"]?["isError"] == true)
        send(call(9, "doc_new", ["width": 1600, "height": 1200, "name": "clip"]))
        #expect(try await next()["result"]?["isError"] == false)
        send(call(10, "command_run", ["id": "timeline.create", "params": ["duration": 100, "fps": 30]]))
        #expect(try await next()["result"]?["isError"] == false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cancel"), withIntermediateDirectories: false)
        try Data("unrelated".utf8).write(to: root.appendingPathComponent("cancel/clip_9999.png"))
        send(render(11, "cancel", "png", .int(11)))
        var pinged = false
        while true {
            let note = try await next()
            #expect(note["id"] == nil || note["id"] == .null, "export finished early: \(note)")
            if note["id"] == .int(11) { break }
            if !pinged {
                send(["jsonrpc": "2.0", "id": 12, "method": "ping"])
                while true {
                    let reply = try await next()
                    #expect(reply["id"] != .int(11))
                    if reply["id"] == .int(12) { break }
                }
                pinged = true
            }
            if (note["params"]?["progress"]?.doubleValue ?? 0) >= 1 { break }
        }
        #expect(entries("cancel") > 1)
        send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 11]])
        // Inspect waits for the same session, so cleanup must have finished before its reply.
        send(call(13, "doc_inspect", .object([:])))
        while true {
            let reply = try await next()
            #expect(reply["id"] != .int(11), "cancelled requests have no response: \(reply)")
            if reply["id"] == .int(13) {
                #expect(reply["result"]?["isError"] == false)
                break
            }
        }
        #expect(entries("cancel") == 1)
        #expect(try Data(contentsOf: root.appendingPathComponent("cancel/clip_9999.png")) == Data("unrelated".utf8))
        try input.fileHandleForWriting.close()
        try await server.value
    }

    // MARK: tests/mcp.rs

    @Test func listsExpectedTools() async throws {
        let (c, s) = try await connect(.headless())
        let tools = try await allTools(c)
        let names = Set(tools.map(\.name))
        for n in ["session_list", "doc_open", "doc_new", "doc_place", "doc_export_layers", "doc_export_data_sets", "doc_import_data_sets", "doc_save", "doc_export",
                  "doc_inspect", "doc_render_preview", "doc_select", "doc_close", "command_list", "command_run", "command_batch", "ui_inspect", "ui_screenshot",
                  "ui_pointer", "ui_menu_invoke", "ui_set", "control_call"] {
            #expect(names.contains(n), "missing tool \(n)")
        }
        for t in tools {
            #expect(t.name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }, "tool name `\(t.name)`")
            #expect(t.description?.isEmpty == false)
        }
        let server = PhotocraftMCP.serverName
        #expect(server == "photocraft")
        #expect(PhotocraftMCP.instructions.contains("command_list"))
        await disconnect(c, s)
    }

    @Test func headlessEditRenderSaveRoundtrip() async throws {
        let dir = try tempDir("mcp-edit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (c, s) = try await connect(try headlessIn(dir))
        #expect(try await call(c, "doc_new", ["width": 64, "height": 48, "background": "white", "name": "Agent"]).isError != true)
        #expect(try await call(c, "command_run", ["id": "layer.new.layer", "params": ["name": "Ink"]]).isError != true)
        let stroke = try await call(c, "command_run", ["id": "paint.stroke", "params": ["points": [[5, 5, 1.0], [50, 40, 1.0]], "size": 6, "color": "#ff0000"]])
        #expect(stroke.isError != true, "\(text(stroke))")
        let doc = try jsonOf(try await call(c, "doc_inspect"))
        #expect(doc["width"] == 64)
        #expect((doc["layers"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue } == ["Ink", "Background"])
        let preview = try #require(image(try await call(c, "doc_render_preview", ["max_side": 32])))
        #expect(preview.mime == "image/png")
        #expect(try decodePNG(preview.data).size == PixelSize(width: 32, height: 24))
        // The native format and flat exports.
        let native = try await call(c, "doc_save", ["path": "agent.pcraft"])
        #expect(native.isError != true, "\(text(native))")
        #expect(try jsonOf(native)["path"] == "agent.pcraft")
        #expect(try jsonOf(try await call(c, "doc_export", ["path": "agent.png"]))["path"] == "agent.png")
        _ = try jsonOf(try await call(c, "doc_export", ["path": "agent.jpg", "quality": 70]))
        _ = try ImageCodecs.decode(Data(contentsOf: dir.appendingPathComponent("agent.png")))
        #expect(try Data(contentsOf: dir.appendingPathComponent("agent.jpg")).count > 100)
        // Re-open the native file: identical layer tree.
        let o = try jsonOf(try await call(c, "doc_open", ["path": "agent.pcraft"]))
        #expect(o["index"] == 1)
        #expect(try jsonOf(try await call(c, "doc_inspect", ["index": 1]))["layers"]?.arrayValue?.count == 2)
        #expect(try jsonOf(try await call(c, "session_list"))["documents"]?.arrayValue?.count == 2)
        _ = try jsonOf(try await call(c, "doc_close", ["index": 1]))
        _ = try jsonOf(try await call(c, "doc_select", ["index": 0]))
        await disconnect(c, s)
    }

    @Test func commandListFilters() async throws {
        let (c, s) = try await connect(.headless())
        let all = try jsonOf(try await call(c, "command_list")).arrayValue ?? []
        #expect(all.count > 20)
        let blur = try jsonOf(try await call(c, "command_list", ["filter": "blur"])).arrayValue ?? []
        #expect(!blur.isEmpty && blur.count < all.count)
        #expect(blur.allSatisfy { $0["params"]?.stringValue != nil })
        let enabled = try jsonOf(try await call(c, "command_list", ["enabled_only": true])).arrayValue ?? []
        #expect(enabled.contains { $0["id"] == "file.new" })
        #expect(!enabled.contains { $0["id"] == "layer.new.layer" }, "needs a document")
        // The full list says why a document command is off with no document open (#3664).
        let layer = try #require(all.first { $0["id"] == "layer.new.layer" })
        #expect(layer["enabled"] == false && layer["needsDocument"] == true, "\(layer)")
        #expect(layer["disabledReason"]?.stringValue?.hasPrefix("no document") == true, "\(layer)")
        let new = try #require(all.first { $0["id"] == "file.new" })
        #expect(new["needsDocument"] == false && new["disabledReason"] == .null, "\(new)")
        await disconnect(c, s)
    }

    /// Constructs strict tool-schema validators reject: `$ref` / `$defs`, or a boolean schema.
    static func strictSchemaProblems(_ path: String, _ schema: JSONValue, _ out: inout [String]) {
        guard case .object(let m) = schema else {
            if case .bool = schema { out.append("\(path): boolean schema \(schema.serialized())") }
            return
        }
        for key in ["$ref", "$defs", "definitions"] where m[key] != nil { out.append("\(path): \(key)") }
        for (k, v) in m["properties"]?.objectValue ?? [:] { strictSchemaProblems("\(path).properties.\(k)", v, &out) }
        for key in ["items", "not"] { if let v = m[key] { strictSchemaProblems("\(path).\(key)", v, &out) } }
        for key in ["anyOf", "oneOf", "allOf", "prefixItems"] {
            for (i, v) in (m[key]?.arrayValue ?? []).enumerated() { strictSchemaProblems("\(path).\(key)[\(i)]", v, &out) }
        }
        if let v = m["additionalProperties"], case .object = v { strictSchemaProblems("\(path).additionalProperties", v, &out) }
    }

    @Test func toolSchemasPassStrictValidators() async throws {
        let (c, s) = try await connect(.headless())
        let tools = try await allTools(c)
        var problems: [String] = []
        for t in tools { Self.strictSchemaProblems(t.name, MCPBridge.json(t.inputSchema), &problems) }
        #expect(problems.isEmpty, "\(problems)")
        let schema = { (name: String) in MCPBridge.json(tools.first { $0.name == name }?.inputSchema ?? .null) }
        let event = schema("ui_pointer")["properties"]?["events"]?["items"]
        #expect(event?["type"] == "object")
        for k in ["kind", "x", "y", "pressure"] { #expect(event?["properties"]?[k]?.objectValue != nil, "ui_pointer event field \(k)") }
        let step = schema("command_batch")["properties"]?["steps"]?["items"]
        #expect(step?["properties"]?["id"]?["description"]?.stringValue?.contains("layer.new.layer") == true)
        await disconnect(c, s)
    }

    @Test func commandIDsInToolSchemasExist() async throws {
        // Agents copy these examples verbatim (#378).
        let ids = Set(CommandRegistry.standard().specs.map(\.id))
        func examples(_ v: JSONValue, _ out: inout [String]) {
            switch v {
            case .object(let m):
                if let d = m["properties"]?["id"]?["description"]?.stringValue {
                    out += d.split(separator: "`", omittingEmptySubsequences: false).enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
                }
                for x in m.values { examples(x, &out) }
            case .array(let a): for x in a { examples(x, &out) }
            default: break
            }
        }
        for name in ["command_run", "command_batch"] {
            var found: [String] = []
            examples(MCPBridge.json(MCPTools.byName[name]?.inputSchema ?? .null), &found)
            #expect(!found.isEmpty, "\(name): no example ids")
            for id in found { #expect(ids.contains(id), "\(name): `\(id)` is not a registered command") }
        }
    }

    @Test func errorsAreToolErrorsNotCrashes() async throws {
        let (c, s) = try await connect(.headless())
        let r = try await call(c, "command_run", ["id": "no.such.command"])
        #expect(r.isError == true && text(r).contains("unknown command"))
        #expect(try await call(c, "doc_inspect", ["index": 0]).isError == true)
        #expect(try await call(c, "doc_open", ["path": "/definitely/missing.png"]).isError == true)
        let ui = try await call(c, "ui_inspect")
        #expect(ui.isError == true && text(ui).contains("bridge"))
        #expect(try await call(c, "doc_export").isError == true)
        // Server still alive.
        _ = try jsonOf(try await call(c, "session_list"))
        await disconnect(c, s)
    }

    @Test func previewBudgetFailurePreservesTheMCPSession() async throws {
        let (c, s) = try await connect(.headless())
        _ = try jsonOf(try await call(c, "doc_new", ["width": 2049, "height": 1]))
        for side in [0, 2049] {
            let reply = try await call(c, "doc_render_preview", ["max_side": .int(side)])
            #expect(reply.isError == true && text(reply).contains("preview side exceeds"))
        }
        #expect(image(try await call(c, "doc_render_preview", ["max_side": 32])) != nil)
        #expect(try jsonOf(try await call(c, "doc_inspect"))["width"] == 2049)
        await disconnect(c, s)
    }

    @Test func bridgeDocSaveRejectsHeadlessOnlyOptionsInsteadOfSavingWithDefaults() async throws {
        let mcp = try PhotocraftMCP.bridge("127.0.0.1:1", token: String(repeating: "a", count: 64))
        for params in [["path": "out.jpg", "quality": 50], ["path": "out.png", "format": "png"], ["path": "out.tif", "tiffLayers": true],
                       ["path": "out.pcraft", "index": 0]] as [JSONValue] {
            let r = try await mcp.callTool("doc_save", MCPBridge.value(params).objectValue)
            #expect(r.isError == true, "\(params)")
            #expect(text(r.asReply).contains("headless"), "\(params): \(text(r.asReply))")
        }
    }

    /// #946: a bridged `doc_save` without `path` reaches the app's `app.save`.
    @Test func bridgeDocSaveWithoutPathForwardsAppSaveForWriteBack() async throws {
        let (app, _) = try fakeApp()
        defer { app.stop() }
        let mcp = try bridgeMCP(app)
        #expect(try jsonOf(try await mcp.callTool("doc_save", [:]).asReply) == ["saved": .object([:])], "no `path` is sent, not even null")
        #expect(try jsonOf(try await mcp.callTool("doc_save", ["path": "out.psd"]).asReply) == ["saved": ["path": "out.psd"]])
    }

    @Test func bridgeDocSaveForwardsTargaBits() async throws {
        let (app, _) = try fakeApp()
        defer { app.stop() }
        let mcp = try bridgeMCP(app)
        #expect(try jsonOf(try await mcp.callTool("doc_save", ["path": "out.tga", "tgaBits": 24]).asReply) == ["saved": ["path": "out.tga", "tgaBits": 24]])
        let r = try await mcp.callTool("doc_save", ["path": "out.tga", "tgaBits": 16])
        #expect(r.isError == true && text(r.asReply).contains("24 or 32"), "\(text(r.asReply))")
    }

    /// Headless `doc_save`/`doc_export` write the TGA bits asked for (byte 16 of the header);
    /// unset, a document with an alpha channel is written as 32-bit.
    @Test func headlessDocSaveWritesTargaBits() async throws {
        let dir = try tempDir("tga-bits")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (c, s) = try await connect(try headlessIn(dir))
        _ = try jsonOf(try await call(c, "doc_new", ["width": 16, "height": 8, "background": "white"]))
        for id in ["select.all", "select.saveSelection"] {
            let r = try await call(c, "command_run", ["id": .string(id), "params": .object([:])])
            #expect(r.isError != true, "\(text(r))")
        }
        for (tool, params, bpp) in [("doc_export", ["path": "auto.tga"] as JSONValue, 32), ("doc_export", ["path": "flat.tga", "tgaBits": 24], 24),
                                    ("doc_save", ["path": "alpha.tga", "tgaBits": 32], 32)] {
            let r = try await call(c, tool, params)
            #expect(r.isError != true, "\(params): \(text(r))")
            let bytes = try Data(contentsOf: dir.appendingPathComponent(params["path"]?.stringValue ?? ""))
            #expect(bytes.count > 16 && Int(bytes[16]) == bpp, "\(params)")
        }
        let bad = try await call(c, "doc_export", ["path": "bad.tga", "tgaBits": 8])
        #expect(bad.isError == true)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("bad.tga").path))
        await disconnect(c, s)
    }

    @Test func openPNGAndInspect() async throws {
        let dir = try tempDir("mcp-open")
        defer { try? FileManager.default.removeItem(at: dir) }
        var surface = Surface(format: .rgba8)
        surface.fill(PixelRect(x: 0, y: 0, width: 8, height: 4), with: [200.0 / 255, 200.0 / 255, 200.0 / 255, 1])
        try ImageCodecs.encode(surface, rect: PixelRect(x: 0, y: 0, width: 8, height: 4), as: .png).write(to: dir.appendingPathComponent("in.png"))
        let (c, s) = try await connect(try headlessIn(dir))
        let o = try jsonOf(try await call(c, "doc_open", ["path": "in.png"]))
        #expect(o["width"] == 8 && o["height"] == 4)
        let px = try jsonOf(try await call(c, "command_run", ["id": "document.pixel", "params": ["x": 1, "y": 1]]))
        #expect(px.serialized().contains("0.78"), "\(px.serialized())")
        await disconnect(c, s)
    }

    /// A save without `path` writes back only to a layered file in its own format (#416).
    @Test func saveWithoutPathNeverFlattensOverTheOpenedFile() async throws {
        let dir = try tempDir("save-in-place")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTestPNG(dir.appendingPathComponent("seed.png"))
        let png = try Data(contentsOf: dir.appendingPathComponent("seed.png"))
        var s0 = Surface(format: .rgba8)
        s0.fill(PixelRect(x: 0, y: 0, width: 16, height: 8), with: [0.3, 0.5, 0.7, 1])
        try ImageCodecs.encode(s0, rect: PixelRect(x: 0, y: 0, width: 16, height: 8), as: .jpeg).write(to: dir.appendingPathComponent("seed.jpg"))
        let jpg = try Data(contentsOf: dir.appendingPathComponent("seed.jpg"))
        let (c, s) = try await connect(try headlessIn(dir))
        let refused = { (r: ToolReply) in r.isError == true && text(r).contains("pass `path`") }
        _ = try jsonOf(try await call(c, "doc_open", ["path": "seed.png"]))
        _ = try jsonOf(try await call(c, "command_run", ["id": "layer.newAdjustmentLayer.curves", "params": ["points": [[0, 0], [128, 170], [255, 255]]]]))
        #expect(refused(try await call(c, "doc_save")))
        #expect(try Data(contentsOf: dir.appendingPathComponent("seed.png")) == png)
        _ = try jsonOf(try await call(c, "doc_open", ["path": "seed.jpg"]))
        #expect(refused(try await call(c, "doc_save")))
        #expect(try Data(contentsOf: dir.appendingPathComponent("seed.jpg")) == jpg)
        // An explicit path, even the opened file's own, still writes and reports what was lost.
        let r = try jsonOf(try await call(c, "doc_save", ["path": "seed.jpg"]))
        #expect(r["warnings"]?.serialized().contains("lossy") == true, "\(r.serialized())")

        // A layered file saves in place in its own format, but not converted over itself.
        _ = try jsonOf(try await call(c, "doc_select", ["index": 0]))
        _ = try jsonOf(try await call(c, "doc_save", ["path": "layered.psd"]))
        _ = try jsonOf(try await call(c, "doc_open", ["path": "layered.psd"]))
        let psd = try Data(contentsOf: dir.appendingPathComponent("layered.psd"))
        let converted = try await call(c, "doc_save", ["format": "png"])
        #expect(refused(converted), "\(text(converted))")
        #expect(try Data(contentsOf: dir.appendingPathComponent("layered.psd")) == psd)
        #expect(try jsonOf(try await call(c, "doc_save"))["path"] == "layered.psd")
        #expect(try Data(contentsOf: dir.appendingPathComponent("layered.psd")).prefix(4) == Data("8BPS".utf8))

        // Once saved as .pcraft, a flat-born document saves in place there.
        _ = try jsonOf(try await call(c, "doc_select", ["index": 0]))
        _ = try jsonOf(try await call(c, "doc_save", ["path": "work.pcraft"]))
        #expect(try jsonOf(try await call(c, "doc_save"))["path"] == "work.pcraft")
        #expect(try Data(contentsOf: dir.appendingPathComponent("seed.png")) == png)

        // A template opens untitled, without its path.
        try psd.write(to: dir.appendingPathComponent("card.psdt"))
        #expect(try jsonOf(try await call(c, "doc_open", ["path": "card.psdt"]))["name"] == "Untitled-1")
        let template = try await call(c, "doc_save")
        #expect(refused(template), "\(text(template))")
        #expect(try Data(contentsOf: dir.appendingPathComponent("card.psdt")) == psd)
        await disconnect(c, s)
    }

    @Test func affinityPreviewWarnsAndRequiresANewSavePath() async throws {
        let dir = try tempDir("affinity-preview")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTestPNG(dir.appendingPathComponent("preview.png"), width: 16, height: 8)
        let png = [UInt8](try Data(contentsOf: dir.appendingPathComponent("preview.png")))
        // Synthetic v12 envelope; the native document graph is intentionally absent.
        var bytes = [UInt8](repeating: 0, count: 72)
        func le16(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func le64(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        bytes.replaceSubrange(0..<4, with: [0x00, 0xff, 0x4b, 0x41])
        bytes.replaceSubrange(4..<6, with: le16(12))
        bytes.replaceSubrange(8..<12, with: Array("nsrP".utf8))
        bytes.replaceSubrange(12..<16, with: Array("#Inf".utf8))
        bytes.replaceSubrange(24..<32, with: le64(72))
        bytes.replaceSubrange(64..<68, with: Array("Prot".utf8))
        bytes += [0xff, 0xff, 0xff, 0xff] + Array("Thmb".utf8)
        bytes += le32(1) + le32(UInt32(png.count) + 13) + le32(29) + le32(0) + le32(UInt32(png.count))
        bytes.append(1)
        bytes += png
        try Data(bytes).write(to: dir.appendingPathComponent("source.af"))
        // A renamed layered extension must not bypass source protection.
        try Data(bytes).write(to: dir.appendingPathComponent("renamed.psd"))
        let (c, s) = try await connect(try headlessIn(dir))
        for name in ["source.af", "renamed.psd"] {
            let opened = try jsonOf(try await call(c, "doc_open", ["path": .string(name)]))
            #expect(opened["warnings"]?.serialized().contains("only its embedded 16×8 PNG preview") == true, "\(opened.serialized())")
            #expect(opened["width"] == 16)
            let refused = try await call(c, "doc_save")
            #expect(refused.isError == true && text(refused).contains("pass `path`"), "\(text(refused))")
            let native = try await call(c, "doc_save", ["path": "source.af"])
            #expect(native.isError == true && text(native).contains("Affinity export"), "\(text(native))")
            #expect(try [UInt8](Data(contentsOf: dir.appendingPathComponent(name))) == bytes)
        }
        _ = try jsonOf(try await call(c, "doc_save", ["path": "copy.pcraft"]))
        #expect(try jsonOf(try await call(c, "doc_save"))["path"] == "copy.pcraft")
        #expect(try [UInt8](Data(contentsOf: dir.appendingPathComponent("source.af"))) == bytes)
        await disconnect(c, s)
    }

    @Test func filesystemPolicyRejectsAbsoluteAndEscapingPathsBeforeEffects() async throws {
        let base = try tempDir("filesystem-policy")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("workspace"), outside = base.appendingPathComponent("outside")
        for d in [root, outside] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try writeTestPNG(root.appendingPathComponent("inside.png"), width: 4, height: 3)
        let (c, s) = try await connect(try headlessIn(root))
        #expect(try await call(c, "doc_open", ["path": "inside.png"]).isError != true)
        // An absolute path beneath the root is the same file (#2176).
        let inside = try await call(c, "doc_open", ["path": .string(root.appendingPathComponent("inside.png").path)])
        #expect(inside.isError != true, "\(text(inside))")
        let absolute = outside.appendingPathComponent("absolute.png")
        let response = try await call(c, "doc_save", ["path": .string(absolute.path)])
        #expect(response.isError == true && text(response).contains("automation path rejected"), "\(text(response))")
        #expect(!FileManager.default.fileExists(atPath: absolute.path))
        for path in ["../outside/traversal.png", "..\\outside\\mixed.png", "C:/outside/prefix.png", ""] {
            #expect(try await call(c, "doc_save", ["path": .string(path)]).isError == true, "\(path)")
        }
        #expect(contents(outside).isEmpty)
        let ambient = try await call(c, "command_run", ["id": "layer.smartObjects.exportContents", "params": ["path": "outside.bin"]])
        #expect(ambient.isError == true && text(ambient).contains("ambient filesystem paths"), "\(text(ambient))")
        await disconnect(c, s)
    }

    /// #2810: a file from the read root places as a Smart Object layer; `file.placeEmbedded`
    /// itself stays refused, so `doc_place` is the only way in and the root is still the scope.
    @Test func docPlaceIsCapabilityScoped() async throws {
        let base = try tempDir("mcp-place")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("workspace"), outside = base.appendingPathComponent("outside")
        for d in [root, outside] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try writeTestPNG(root.appendingPathComponent("inside.png"), width: 8, height: 6)
        try writeTestPNG(outside.appendingPathComponent("outside.png"), width: 8, height: 6)
        let (c, s) = try await connect(try headlessIn(root))
        _ = try jsonOf(try await call(c, "doc_new", ["width": 40, "height": 30]))
        let placed = try await call(c, "doc_place", ["path": "inside.png", "center": [10, 10]])
        #expect(placed.isError != true, "\(text(placed))")
        #expect(try jsonOf(try await call(c, "doc_inspect"))["layers"]?.arrayValue?.count == 2, "the placed layer is in the document")
        // An absolute path beneath the root is the same file (#2176), so it places too; outside
        // it, nothing.
        let inside = try await call(c, "doc_place", ["path": .string(root.appendingPathComponent("inside.png").path)])
        #expect(inside.isError != true, "\(text(inside))")
        let count = try jsonOf(try await call(c, "doc_inspect"))["layers"]?.arrayValue?.count
        #expect(count == 3, "the absolute path beneath the root places as well")
        let refused = try await call(c, "doc_place", ["path": .string(outside.appendingPathComponent("outside.png").path)])
        #expect(refused.isError == true && text(refused).contains("must be inside the automation root"), "\(text(refused))")
        #expect(try jsonOf(try await call(c, "doc_inspect"))["layers"]?.arrayValue?.count == count, "nothing outside the root was placed")
        // The ambient command keeps its refusal: the capability-scoped method is the only way in.
        let ambient = try await call(c, "command_run", ["id": "file.placeEmbedded", "params": ["path": "inside.png"]])
        #expect(ambient.isError == true && text(ambient).contains("ambient filesystem paths"), "\(text(ambient))")
        await disconnect(c, s)
    }

    /// #3216: the export half of #2810. The write root scopes both exports, the read root the
    /// CSV, and the three ambient commands keep their refusal.
    @Test func docExportsAndDataSetImportAreCapabilityScoped() async throws {
        let base = try tempDir("mcp-export")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let (c, s) = try await connect(try headlessIn(root))
        func entries(_ dir: String) -> Int { (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path).count) ?? -1 }
        _ = try jsonOf(try await call(c, "doc_new", ["width": 10, "height": 6, "background": "white", "name": "card"]))
        let layer = try jsonOf(try await call(c, "doc_inspect"))["layers"]?[0]?["id"] ?? .null
        _ = try jsonOf(try await call(c, "command_run", ["id": "image.variables.define", "params": ["defs": [["name": "show", "layer": layer, "type": "visibility"]]]]))
        _ = try jsonOf(try await call(c, "command_run", ["id": "image.variables.dataSets", "params": ["dataSets": [
            ["name": "one", "values": [["variable": "show", "kind": "visibility", "value": true]]],
            ["name": "two", "values": [["variable": "show", "kind": "visibility", "value": false]]],
        ]]]))

        let layers = try await call(c, "doc_export_layers", ["dir": "layers", "prefix": "card"])
        #expect(layers.isError != true, "\(text(layers))")
        #expect(try jsonOf(layers)["count"] == 1, "\(text(layers))")
        #expect(entries("layers") == 1)
        let sets = try await call(c, "doc_export_data_sets", ["dir": "sets", "format": "png"])
        #expect(sets.isError != true, "\(text(sets))")
        if sets.isError != true { #expect(try jsonOf(sets)["count"] == 2, "\(text(sets))") }
        #expect(entries("sets") == 2)
        // A colliding template is refused before any file of the batch is written.
        let clash = try await call(c, "doc_export_data_sets", ["dir": "clash", "naming": "{document}"])
        #expect(clash.isError == true, "\(text(clash))")
        #expect(entries("clash") == 0)
        // A CSV from the read root.
        try Data("Data Set,show\none,true\n".utf8).write(to: root.appendingPathComponent("sets.csv"))
        let imported = try await call(c, "doc_import_data_sets", ["path": "sets.csv"])
        #expect(imported.isError != true, "\(text(imported))")
        #expect(try jsonOf(imported)["imported"] == 1, "\(text(imported))")

        // Outside the roots nothing happens at all.
        let escaped = try await call(c, "doc_export_layers", ["dir": .string(base.appendingPathComponent("escaped").path)])
        #expect(escaped.isError == true, "\(text(escaped))")
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("escaped").path))
        try Data("Data Set,show\none,true\n".utf8).write(to: base.appendingPathComponent("outside.csv"))
        #expect(try await call(c, "doc_import_data_sets", ["path": .string(base.appendingPathComponent("outside.csv").path)]).isError == true)
        for command in ["file.export.layersToFiles", "file.export.dataSetsAsFiles", "file.import.variableDataSets"] {
            let refused = try await call(c, "command_run", ["id": .string(command), "params": .object([:])])
            #expect(refused.isError == true && text(refused).contains("ambient filesystem paths"), "\(command): \(text(refused))")
        }
        await disconnect(c, s)
    }

    @Test func smartObjectCommandsRefuseRealLinkedFilesWithoutChangingTheSession() async throws {
        let dir = try tempDir("linked-smart-object")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeTestPNG(dir.appendingPathComponent("external.png"), width: 16, height: 8)
        let original = try Data(contentsOf: dir.appendingPathComponent("external.png"))
        let session = Session()
        try session.execute("file.new", ["width": 16, "height": 8, "background": "white"])
        let layer = try session.execute("layer.smartObjects.convertToSmartObject")["layer"] ?? .null
        var doc = try #require(session.active?.doc)
        guard case .smart(var smart) = doc.layers[0].content else { Issue.record("not a smart object"); return }
        smart.source = .linked(path: dir.appendingPathComponent("external.png").path)
        doc.layers[0].content = .smart(smart)
        try Data(try PcraftFormat.save(doc)).write(to: dir.appendingPathComponent("parent.pcraft"))
        let (c, s) = try await connect(try headlessIn(dir))
        _ = try jsonOf(try await call(c, "doc_open", ["path": "parent.pcraft"]))
        let before = try jsonOf(try await call(c, "doc_inspect"))
        for id in ["layer.smartObjects.editContents", "layer.smartObjects.convertToLayers"] {
            let response = try await call(c, "command_run", ["id": .string(id), "params": ["layer": layer]])
            #expect(response.isError == true && text(response).contains("ambient filesystem paths"), "\(id): \(text(response))")
            #expect(try jsonOf(try await call(c, "doc_inspect")) == before)
            #expect(try jsonOf(try await call(c, "session_list"))["documents"]?.arrayValue?.count == 1)
        }
        #expect(try Data(contentsOf: dir.appendingPathComponent("external.png")) == original)
        await disconnect(c, s)
    }

    @Test func embeddedSmartObjectsCanBeEditedSavedAndUnpackedWithoutFileAuthority() async throws {
        let (c, s) = try await connect(.headless())
        func run(_ id: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
            try jsonOf(try await call(c, "command_run", ["id": .string(id), "params": params]))
        }
        _ = try jsonOf(try await call(c, "doc_new", ["width": 16, "height": 12, "background": "white"]))
        _ = try await run("layer.smartObjects.convertToSmartObject")
        let outer = try await run("layer.smartObjects.convertToSmartObject")["layer"] ?? .null
        // An explicit target works even with a regular pixel layer selected.
        _ = try await run("layer.new.layer", ["name": "Other layer"])
        #expect(try await run("layer.smartObjects.editContents", ["layer": outer])["document"] == 1)
        #expect(try await run("layer.smartObjects.editContents")["document"] == 2)
        _ = try await run("layer.setProps", ["name": "Edited photo", "opacity": 0.5])
        #expect(try await run("layer.smartObjects.saveContents")["updated"] == true)
        _ = try jsonOf(try await call(c, "doc_close"))
        _ = try await run("layer.smartObjects.saveContents")
        _ = try jsonOf(try await call(c, "doc_close"))
        #expect(try jsonOf(try await call(c, "session_list"))["documents"]?.arrayValue?.count == 1)
        // Reopening the saved nested source proves both in-memory parent updates survived closing.
        _ = try await run("layer.smartObjects.editContents", ["layer": outer])
        _ = try await run("layer.smartObjects.editContents")
        let doc = try jsonOf(try await call(c, "doc_inspect"))
        #expect(doc["layers"]?[0]?["name"] == "Edited photo")
        #expect(doc["layers"]?[0]?["opacity"] == 0.5)
        _ = try jsonOf(try await call(c, "doc_close"))
        _ = try jsonOf(try await call(c, "doc_close"))
        let unpacked = try await run("layer.smartObjects.convertToLayers", ["layer": outer])["layer"] ?? .null
        _ = try await run("layer.smartObjects.convertToLayers", ["layer": unpacked])
        let flat = try jsonOf(try await call(c, "doc_inspect"))
        #expect((flat["layers"]?.arrayValue ?? []).allSatisfy { $0["kind"] == "Pixel" }, "\(flat.serialized())")
        await disconnect(c, s)
    }

    // MARK: Bridge mode against a fake control server

    @Test func bridgeForwardsToControlProtocol() async throws {
        let (app, _) = try fakeApp()
        defer { app.stop() }
        let mcp = try bridgeMCP(app)
        #expect(try jsonOf(try await mcp.callTool("ui_inspect", [:]).asReply)["tool"] == "brush")
        #expect(try jsonOf(try await mcp.callTool("command_run", ["id": "layer.new.layer", "params": ["name": "X"]]).asReply)["ran"] == "layer.new.layer")
        let inspected = try jsonOf(try await mcp.callTool("doc_inspect", ["index": 1]).asReply)
        #expect(inspected["ran"] == "document.inspect")
        #expect(inspected["params"] == ["document": 1])
        #expect(try jsonOf(try await mcp.callTool("command_list", [:]).asReply)[0]?["id"] == "file.new")
        let shot = try #require(image(try await mcp.callTool("ui_screenshot", ["max_side": 20]).asReply))
        #expect(try decodePNG(shot.data).size == PixelSize(width: 20, height: 10))
        let e = try await mcp.callTool("control_call", ["method": "bogus.method"])
        #expect(e.isError == true && text(e.asReply).contains("unknown tool"))
        #expect(try await mcp.callTool("doc_select", ["index": 0]).isError == true)
    }

    @Test func bridgePreviewsDownscaleBeforeEnforcingThePNGBudget() async throws {
        let (width, height) = (1400, 1000)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        var state: UInt32 = 0x6D2B_79F5
        for i in pixels.indices {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            pixels[i] = Float(state & 0xFF) / 255
        }
        let raster = RasterBuffer(width: width, height: height, format: .rgba8, floats: pixels)
        let source = try ImageCodecs.encode(raster, as: .png)
        #expect(source.count > Budgets.maxPNGBytes, "fixture must exceed the PNG budget")
        let (app, _) = try fakeApp(screenshot: source)
        defer { app.stop() }
        let mcp = try bridgeMCP(app)
        for tool in ["ui_screenshot", "doc_render_preview"] {
            let reply = try await mcp.callTool(tool, ["max_side": 32])
            #expect(reply.isError != true, "\(tool): \(text(reply.asReply))")
            let png = try #require(image(reply.asReply))
            #expect((Data(base64Encoded: png.data)?.count ?? .max) <= Budgets.maxPNGBytes)
            #expect(try decodePNG(png.data).size == PixelSize(width: 32, height: 22), "\(tool)")
        }
        let full = try await mcp.callTool("ui_screenshot", [:])
        #expect(full.isError == true && text(full.asReply).contains("automation PNG exceeds"), "\(text(full.asReply))")
    }

    @Test func bridgePreviewsRejectDocumentIndices() async throws {
        let (app, seen) = try fakeApp()
        defer { app.stop() }
        let mcp = try bridgeMCP(app)
        for tool in ["ui_screenshot", "doc_render_preview"] {
            var message: String?
            do {
                let r = try await mcp.callTool(tool, ["index": 0, "max_side": 20])
                if r.isError == true { message = text(r.asReply) }
            } catch {
                message = "\(error)"
            }
            #expect(message?.contains("index") == true, "\(tool): \(String(describing: message))")
            let reply = try await mcp.callTool(tool, ["max_side": 20])
            let png = try #require(image(reply.asReply))
            #expect(try decodePNG(png.data).size == PixelSize(width: 20, height: 10))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(seen.all.filter { $0["method"] == "ui.screenshot" }.count == 2, "rejected indices must not reach the app")
        let schema = MCPBridge.json(MCPTools.byName["ui_screenshot"]?.inputSchema ?? .null)
        #expect(schema["properties"]?["index"] == nil)
        #expect(schema["properties"]?["max_side"] != nil)
        #expect(schema["additionalProperties"] == false)
    }

    @Test func headlessPreviewsPreserveDocumentIndices() async throws {
        let (c, s) = try await connect(.headless())
        _ = try jsonOf(try await call(c, "doc_new", ["width": 12, "height": 6, "background": "white"]))
        _ = try jsonOf(try await call(c, "doc_new", ["width": 6, "height": 12, "background": "black"]))
        for (args, size, value) in [(["index": 0, "max_side": 6] as JSONValue, PixelSize(width: 6, height: 3), Float(1)), (["max_side": 6], PixelSize(width: 3, height: 6), 0)] {
            let reply = try await call(c, "doc_render_preview", args)
            let png = try #require(image(reply), "\(text(reply))")
            let img = try decodePNG(png.data)
            #expect(img.size == size)
            let p = img.surface.rgba(x: 1, y: 1)
            #expect(abs(p.x - value) < 0.01 && abs(p.w - 1) < 0.01)
        }
        #expect(try jsonOf(try await call(c, "session_list"))["active"] == 1)
        #expect(MCPBridge.json(MCPTools.byName["doc_render_preview"]?.inputSchema ?? .null)["properties"]?["index"] != nil)
        await disconnect(c, s)
    }

    @Test func bridgeRejectsNonLoopback() throws {
        #expect(throws: EngineError.self) { try PhotocraftMCP.bridge("10.0.0.5:7878", token: controlToken) }
        _ = try PhotocraftMCP.bridge("127.0.0.1:7878", token: controlToken)
        _ = try PhotocraftMCP.bridge("localhost:1", token: controlToken)
        #expect(throws: EngineError.self) { try PhotocraftMCP.bridge("localhost:1", token: "short") }
    }

    @Test func bridgeRejectsWrongTokenBeforeControlMethods() async throws {
        let (app, _) = try fakeApp()
        defer { app.stop() }
        let r = try await bridgeMCP(app, token: String(repeating: "a", count: 64)).callTool("ui_inspect", [:])
        #expect(r.isError == true && text(r.asReply).contains("authentication required"), "\(text(r.asReply))")
    }

    @Test func bridgeReportsUnreachableApp() async throws {
        let r = try await PhotocraftMCP.bridge("127.0.0.1:1", token: controlToken).callTool("ui_inspect", [:])
        #expect(r.isError == true && text(r.asReply).contains("--control"), "\(text(r.asReply))")
    }

    @Test func commandBatchDescriptionExposesNonAtomicSemantics() async throws {
        let (c, s) = try await connect(.headless())
        let description = try #require(try await allTools(c).first { $0.name == "command_batch" }?.description)
        for contract in ["in order", "Not an atomic transaction", "first error", "stop_on_error is false", "no rollback"] {
            #expect(description.contains(contract), "command_batch description omits `\(contract)`")
        }
        await disconnect(c, s)
    }

    @Test func commandBatchRunsStepsInOrder() async throws {
        let (c, s) = try await connect(.headless())
        _ = try jsonOf(try await call(c, "doc_new", ["width": 32, "height": 32]))
        let r = try jsonOf(try await call(c, "command_batch", ["steps": [
            ["id": "layer.new.layer", "params": ["name": "One"]], ["id": "layer.new.layer", "params": ["name": "Two"]], ["id": "no.such.command"],
            ["id": "layer.new.layer", "params": ["name": "Three"]],
        ]]))
        #expect(r["completed"] == 2 && r["failed"] == 1)
        let doc = try jsonOf(try await call(c, "doc_inspect")).serialized()
        #expect(doc.contains("\"Two\"") && !doc.contains("\"Three\""))
        await disconnect(c, s)
    }

    @Test func commandBatchStepWithoutWaitingStartsABackgroundJob() async throws {
        let (c, s) = try await connect(.headless())
        _ = try jsonOf(try await call(c, "doc_new", ["width": 600, "height": 400]))
        let r = try jsonOf(try await call(c, "command_batch", ["steps": [
            ["id": "layer.new.layer"], ["id": "edit.fill", "params": ["color": "#808080"]],
            ["id": "filter.blur.gaussianBlur", "params": ["radius": 40], "wait": false],
        ]]))
        #expect(r["completed"] == 3, "\(r.serialized())")
        let started = r["results"]?[2]?["result"]
        #expect(started?["pending"] == true)
        let job = try #require(started?["job"])
        let start = Date()
        while Date().timeIntervalSince(start) < 60 {
            let l = try jsonOf(try await call(c, "jobs_list"))
            let state = l["jobs"]?.arrayValue?.first { $0["id"] == job }?["state"]
            #expect(state != nil, "job not listed: \(l.serialized())")
            if state == "done" || state == nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        // Without `wait` a step still returns the command's own result.
        let again = try jsonOf(try await call(c, "command_batch", ["steps": [["id": "filter.blur.gaussianBlur", "params": ["radius": 2]]]]))
        #expect(again["results"]?[0]?["result"]?["filter"]?.objectValue != nil, "\(again.serialized())")
        await disconnect(c, s)
    }

    @Test func bridgeCommandBatchForwardsEachStepsWait() async throws {
        let (app, _) = try fakeApp()
        defer { app.stop() }
        let r = try jsonOf(try await bridgeMCP(app).callTool("command_batch", ["steps": [["id": "filter.blur.gaussianBlur", "wait": false], ["id": "layer.new.layer"]]]).asReply)
        #expect(r["completed"] == 2, "\(r.serialized())")
        #expect(r["results"]?[0]?["result"]?["wait"] == false)
        #expect(r["results"]?[1]?["result"]?["wait"] == true)
    }

    /// #514: `ui_pointer` forwards `button` and rejects arguments it doesn't forward.
    @Test func bridgeUIPointerForwardsTheButtonAndRejectsUnknownArguments() async throws {
        let (app, _) = try fakeApp()
        defer { app.stop() }
        let mcp = try bridgeMCP(app)
        let events: JSONValue = [["kind": "down", "x": 5, "y": 6], ["kind": "up", "x": 5, "y": 6]]
        let sent = try jsonOf(try await mcp.callTool("ui_pointer", MCPBridge.value(["events": events, "button": "right", "modifiers": ["command": true]]).objectValue).asReply)
        #expect(sent == ["events": events, "button": "right", "modifiers": ["command": true]])
        #expect(try jsonOf(try await mcp.callTool("ui_pointer", MCPBridge.value(["events": events]).objectValue).asReply) == ["events": events],
                "unset fields are not sent")
        for bad in [["events": events, "buton": "right"], ["events": events, "space": true]] as [JSONValue] {
            await #expect(throws: MCPError.self, "\(bad.serialized()) accepted") { try await mcp.callTool("ui_pointer", MCPBridge.value(bad).objectValue) }
        }
        let schema = MCPBridge.json(MCPTools.byName["ui_pointer"]?.inputSchema ?? .null)
        #expect(schema["additionalProperties"] == false)
        #expect(schema["properties"]?["button"] != nil)
    }

    /// #368: agents can open the clipboard as a document of its own.
    @Test func newFromClipboardOpensTheCopyAsADocument() async throws {
        let (c, s) = try await connect(.headless())
        _ = try jsonOf(try await call(c, "doc_new", ["width": 40, "height": 30]))
        let r = try jsonOf(try await call(c, "command_batch", ["steps": [
            ["id": "select.rect", "params": ["x": 5, "y": 5, "width": 12, "height": 7]], ["id": "edit.copy"], ["id": "file.newFromClipboard"],
        ]]))
        #expect(r["completed"] == 3, "\(r.serialized())")
        let doc = try jsonOf(try await call(c, "doc_inspect"))
        #expect(doc["width"] == 12 && doc["height"] == 7)
        #expect(try jsonOf(try await call(c, "session_list"))["documents"]?.arrayValue?.count == 2)
        await disconnect(c, s)
    }

    @Test func commandBatchRejectsTooManySteps() async throws {
        let steps = JSONValue.array(Array(repeating: ["id": "command.list"], count: ControlSecurity.maxBatchSteps + 1))
        let r = try await PhotocraftMCP.headless().callTool("command_batch", ["steps": MCPBridge.value(steps)])
        #expect(r.isError == true && text(r.asReply).contains("maximum is 256"))
    }

    @Test func conventionToolsHaveTitlesHintsAndStrictSchemas() async throws {
        let (c, s) = try await connect(.headless())
        let tools = try await allTools(c)
        #expect(tools.contains { $0.name == "render_preview" })
        #expect(tools.contains { $0.name == "doc_render_preview" })
        for tool in tools {
            #expect(tool.title?.isEmpty == false, "\(tool.name)")
            let a = tool.annotations
            #expect(a.readOnlyHint != nil && a.destructiveHint != nil && a.idempotentHint != nil && a.openWorldHint != nil, "\(tool.name)")
            #expect(MCPBridge.json(tool.inputSchema)["additionalProperties"] == false, "\(tool.name)")
        }
        await disconnect(c, s)
    }

    @Test func conventionUnknownArgumentsNameTheKeyWithoutSideEffects() async throws {
        let (c, s) = try await connect(.headless())
        for (name, args) in [("doc_new", ["widht": 8] as JSONValue), ("session_list", ["surprise": true]), ("command_run", ["id": "file.new", "surprise": true]),
                             ("command_batch", ["steps": [["id": "file.new", "surprise": true]]])] {
            let key = name == "doc_new" ? "widht" : "surprise"
            do {
                _ = try await call(c, name, args)
                Issue.record("unknown key must fail before execution: \(name)")
            } catch {
                #expect("\(error)".contains("-32602") && "\(error)".contains(key), "\(error)")
            }
        }
        #expect(try jsonOf(try await call(c, "session_list"))["documents"] == [])
        await disconnect(c, s)
    }

    @Test func conventionResourcesAreLiveJSON() async throws {
        let (c, s) = try await connect(.headless())
        let (resources, _) = try await c.listResources()
        for uri in ["photocraft://document", "photocraft://commands"] { #expect(resources.contains { $0.uri == uri }) }
        func read(_ uri: String) async throws -> JSONValue { try JSONValue.parse(try await c.readResource(uri: uri).first?.text ?? "") }
        #expect(try await read("photocraft://document")["document"] == .null)
        _ = try jsonOf(try await call(c, "doc_new", ["width": 8, "height": 6]))
        #expect(try await read("photocraft://document")["width"] == 8)
        // Edit › Purge › All's `enabled` can flip with process-wide caches other tests fill.
        func stable(_ v: JSONValue) -> JSONValue {
            .array((v.arrayValue ?? []).map { $0["id"] == "edit.purge.all" ? $0.removing("enabled") : $0 })
        }
        let commands = stable(try await read("photocraft://commands"))
        #expect((commands.arrayValue?.count ?? 0) > 100)
        #expect(commands == stable(try jsonOf(try await call(c, "command_list"))))
        await #expect(throws: (any Error).self) { try await c.readResource(uri: "photocraft://missing") }
        #expect(image(try await call(c, "render_preview", ["max_side": 4])) != nil)
        await disconnect(c, s)
    }

    // MARK: tests/agent_tasks.rs

    @Test func agentRecordsAndReplaysAnAction() async throws {
        let dir = try tempDir("agent-actions")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (c, s) = try await connect(try headlessIn(dir))
        func run(_ id: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
            try jsonOf(try await call(c, "command_run", ["id": .string(id), "params": params]))
        }
        let ids = Set((try jsonOf(try await call(c, "command_list", ["filter": "actions."])).arrayValue ?? []).compactMap { $0["id"]?.stringValue })
        for id in ["actions.list", "actions.get", "actions.record", "actions.stop", "actions.play", "actions.delete"] { #expect(ids.contains(id), "\(id)") }
        _ = try await run("file.new", ["width": 32, "height": 32, "background": "white"])
        _ = try await run("actions.record", ["name": "Red"])
        _ = try await run("layer.new.layer")
        _ = try await run("select.rect", ["x": 0, "y": 0, "width": 8, "height": 8])
        _ = try await run("edit.fill", ["color": "#ff0000"])
        #expect(try await run("actions.stop")["steps"] == 3)
        let got = try await run("actions.get", ["action": "Red"])
        #expect(got["steps"]?[0]?[0] == "layer.new.layer" && got["steps"]?[1]?[0] == "select.rect" && got["steps"]?[2]?[0] == "edit.fill")
        _ = try await run("file.new", ["width": 32, "height": 32, "background": "white"])
        let played = try await run("actions.play", ["action": "Red"])
        #expect(played["ran"] == 3 && played["failed"] == nil, "\(played.serialized())")
        let px = (try await run("document.pixel", ["x": 2, "y": 2])).arrayValue?.compactMap(\.doubleValue) ?? []
        #expect(px.count == 4 && abs(px[0] - 1) < 1e-4 && abs(px[1]) < 1e-4 && abs(px[2]) < 1e-4 && abs(px[3] - 1) < 1e-4, "\(px)")
        await disconnect(c, s)
    }

    @Test func agentPlayRefusesARecordedFileOpen() async throws {
        let dir = try tempDir("agent-actions-auth")
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = EngineHost(filesystem: .workspace(try AuthorizedWorkspace(readRoot: dir.path, writeRoot: dir.path)))
        try await host.withHeadless { h in
            h.session.state[ActionsCommands.ActionStateKey.self].list.append(
                ActionsCommands.Action("Open", [CommandInvocation("file.open", ["path": "/etc/passwd"]), CommandInvocation("layer.new.layer")]))
        }
        let (c, s) = try await connect(await PhotocraftMCP.headless(host: host, perCommandTools: false))
        let played = try jsonOf(try await call(c, "command_run", ["id": "actions.play", "params": ["action": "Open"]]))
        #expect(played["ran"] == 0 && played["failed"]?["step"] == 0 && played["failed"]?["id"] == "file.open", "\(played.serialized())")
        #expect(played["failed"]?["error"]?.stringValue?.contains("disabled") == true, "\(played.serialized())")
        #expect(try jsonOf(try await call(c, "session_list"))["documents"] == [])
        await disconnect(c, s)
    }
}

extension CallTool.Result {
    /// The client-side shape of a tool reply.
    var asReply: ToolReply { (content, isError) }
}
