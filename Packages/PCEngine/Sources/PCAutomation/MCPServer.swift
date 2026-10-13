// Port of photocraft-automation (crates/automation/src/server.rs `PhotocraftMcp`, server/conventions.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The MCP server (official Swift SDK) over either backend: a headless session (`EngineHost`) or a
// running control server reached through `BridgeClient`. Tool names use snake_case. Every tool
// has a title, the four behaviour hints and a strict input schema (no `$ref`, no boolean schemas,
// `additionalProperties: false`); an argument a tool doesn't take is an invalid-params error
// naming it, before anything runs. Results are bounded as encoded JSON, including the content
// envelope. Two live resources mirror `doc_inspect` and `command_list`.
//
// pccli extension: with `perCommandTools`, every available command is also its own tool
// (`cmd_layer_new_layer`) whose input schema is the command's params schema (headless only).

import Dispatch
import Foundation
import MCP
import PCDocument
import PCEngine
import Synchronization

/// The headless session behind the MCP server, on its own serial executor: commands run there one
/// at a time, and a command that waits for a job blocks that queue, never the concurrency pool.
public actor EngineHost {
    private let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    let headless: Headless

    public init(filesystem: Headless.Filesystem) {
        queue = DispatchSerialQueue(label: "pccli.engine")
        headless = Headless(filesystem: filesystem)
    }

    /// Runs `body` on the session after applying finished background jobs (photocraft
    /// `headless_op`).
    public func withHeadless<T: Sendable>(_ body: @Sendable (Headless) throws -> T) throws -> T {
        headless.syncJobs()
        return try body(headless)
    }

    public func handle(_ method: String, _ params: JSONValue) throws -> JSONValue { try headless.handle(method, params) }
    public func run(_ id: String, _ params: JSONValue, wait: Bool) throws -> JSONValue {
        headless.syncJobs()
        return try headless.commandStart(id, params, wait: wait)
    }
    public func list(filter: String?, enabledOnly: Bool) -> JSONValue { headless.commandList(filter: filter, enabledOnly: enabledOnly) }
    public func batch(_ p: JSONValue) throws -> JSONValue { try headless.batch(p) }
    public func png(_ index: Int?, maxSide: Int) throws -> Data { try headless.renderPNG(index, maxSide: maxSide) }
    public func availableCommands() -> [(id: String, label: String, params: String, schema: JSONValue, journal: Bool)] {
        headless.session.registry.specs.filter(\.isAvailable).map { ($0.id, $0.label, $0.params, $0.schema, $0.journal) }
    }
}

/// The MCP server's tools, resources and dispatch (photocraft `PhotocraftMcp`).
public final class PhotocraftMCP: Sendable {
    /// Where tools are executed.
    public enum Backend: Sendable {
        /// In-process engine session.
        case headless(EngineHost)
        /// A running control server reached over the control protocol.
        case bridge(BridgeClient)
    }

    public let backend: Backend
    /// pccli's per-command tools (headless only) and the command each one runs.
    let commandTools: [Tool]
    let commandIDs: [String: String]

    public init(backend: Backend, commandTools commands: [(id: String, label: String, params: String, schema: JSONValue, journal: Bool)] = []) {
        self.backend = backend
        commandTools = MCPBridge.commandTools(commands)
        commandIDs = Dictionary(commands.map { (MCPBridge.commandToolName($0.id), $0.id) }, uniquingKeysWith: { a, _ in a })
    }

    /// A headless server with no filesystem authority.
    public static func headless() -> PhotocraftMCP { PhotocraftMCP(backend: .headless(EngineHost(filesystem: .denied))) }

    /// A headless server confined to `workspace`.
    public static func headless(workspace: AuthorizedWorkspace) -> PhotocraftMCP {
        PhotocraftMCP(backend: .headless(EngineHost(filesystem: .workspace(workspace))))
    }

    /// A bridge to the control server at `addr` (loopback only).
    public static func bridge(_ addr: String, token: String) throws -> PhotocraftMCP {
        PhotocraftMCP(backend: .bridge(try BridgeClient(addr, token: token)))
    }

    /// A headless server over `host`, with every available command as its own tool when asked.
    public static func headless(host: EngineHost, perCommandTools: Bool) async -> PhotocraftMCP {
        PhotocraftMCP(backend: .headless(host), commandTools: perCommandTools ? await host.availableCommands() : [])
    }

    public static let serverName = "photocraft"
    public static let instructions =
        "PhotoCraft image editor. Start with doc_new/doc_open, discover ids and parameter docs with command_list, edit with command_run or command_batch (one history step per command). Inspect with doc_inspect and render_preview; doc_save writes native .pcraft or exports by extension. File paths are relative to the read/write roots granted at launch. ui_inspect/ui_screenshot and other ui_* tools require bridge mode. Read photocraft://document and photocraft://commands for live JSON state."
    static let documentURI = "photocraft://document"
    static let commandsURI = "photocraft://commands"

    /// Every tool: the router's, then the per-command ones.
    public var tools: [Tool] { MCPTools.all + commandTools }

    // MARK: Result envelopes (photocraft `ok_json`, `fail`, `png_result`)

    static func encodedSize(_ r: CallTool.Result) -> Int {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(r).count) ?? Int.max
    }

    static func bounded(_ r: CallTool.Result) -> CallTool.Result {
        if encodedSize(r) > Budgets.maxResponseBytes - 1 {
            return fail("response encoding failed: response exceeds \(Budgets.maxResponseBytes - 1) bytes; operation may have completed")
        }
        return r
    }

    /// A JSON value as text content, within the reply ceiling.
    public static func okJSON(_ v: JSONValue) -> CallTool.Result {
        let data: Data
        do { data = try Budgets.jsonBytes(v) } catch { return fail("\(EngineError.wrap(error)); operation may have completed") }
        return bounded(CallTool.Result(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)], isError: false))
    }

    /// A tool error (the result itself bounded).
    public static func fail(_ message: String) -> CallTool.Result {
        let r = CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
        if encodedSize(r) > Budgets.maxResponseBytes - 1 {
            return CallTool.Result(content: [.text(text: "response budget exceeded; operation may have completed", annotations: nil, _meta: nil)], isError: true)
        }
        return r
    }

    static func fail(_ error: any Error) -> CallTool.Result { fail(EngineError.wrap(error).description) }

    static func pngResult(_ png: Data, note: String) -> CallTool.Result {
        do { try Budgets.checkPNG(png.count) } catch { return fail(error) }
        return bounded(CallTool.Result(content: [.image(data: png.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil),
                                                 .text(text: note, annotations: nil, _meta: nil)], isError: false))
    }

    static func toResult(_ r: Result<JSONValue, EngineError>) -> CallTool.Result {
        switch r {
        case .success(let v): okJSON(v)
        case .failure(let e): fail(e.description)
        }
    }

    static func bridgeOnly(_ name: String) -> CallTool.Result {
        fail("`\(name)` drives the live GUI and needs bridge mode: start the app with `photocraft --control <port> --control-token-file <path>`, then run `pccli mcp --bridge 127.0.0.1:<port> --control-token-file <path>`")
    }

    static func headlessOnly(_ name: String) -> CallTool.Result {
        fail("`\(name)` is only available in headless mode (in the GUI use the window/tab UI or control_call)")
    }

    static func noBackend() -> CallTool.Result { fail("internal error: no headless session or app bridge") }

    // MARK: Backends

    /// Runs `body` on the headless session; nil in bridge mode.
    func headlessOp<T: Sendable>(_ body: @escaping @Sendable (Headless) throws -> T) async -> Result<T, EngineError>? {
        guard case .headless(let host) = backend else { return nil }
        do { return .success(try await host.withHeadless(body)) } catch { return .failure(EngineError.wrap(error)) }
    }

    var bridgeClient: BridgeClient? { if case .bridge(let b) = backend { b } else { nil } }

    static func bridged(_ body: () async throws -> JSONValue) async -> CallTool.Result {
        do { return okJSON(try await body()) } catch { return fail(error) }
    }

    func runCommand(_ id: String, _ params: JSONValue, wait: Bool) async -> CallTool.Result {
        if let r = await headlessOp({ try $0.commandStart(id, params, wait: wait) }) { return Self.toResult(r) }
        guard let b = bridgeClient else { return Self.noBackend() }
        return await Self.bridged { try await b.call("engine.execute", ["command": .string(id), "params": params, "wait": .bool(wait)]) }
    }

    /// `jobs.list` / `jobs.cancel` in either backend; `read` picks the bridge's retry rule.
    func jobsCall(_ method: String, _ params: JSONValue, read: Bool) async -> CallTool.Result {
        if let r = await headlessOp({ try $0.commandStart(method, params, wait: true) }) { return Self.toResult(r) }
        guard let b = bridgeClient else { return Self.noBackend() }
        return await Self.bridged { read ? try await b.callRead(method, params) : try await b.call(method, params) }
    }

    func screenshot(_ b: BridgeClient, maxSide: Int?) async -> CallTool.Result {
        if let m = maxSide, m > Budgets.maxPreviewSide { return Self.fail("automation preview side exceeds \(Budgets.maxPreviewSide) pixels") }
        let response: JSONValue
        do { response = try await b.callRead("ui.screenshot", .object([:])) } catch { return Self.fail(error) }
        guard let encoded = response["base64"]?.stringValue else { return Self.fail("app screenshot response did not contain PNG data") }
        guard var bytes = Data(base64Encoded: encoded) else { return Self.fail("app screenshot data: invalid base64") }
        do {
            if let small = try FlatFiles.downscalePNG(bytes, maxSide: maxSide ?? 0) { bytes = small }
            try Budgets.checkPNG(bytes.count)
        } catch {
            return Self.fail(error)
        }
        return Self.pngResult(bytes, note: "screenshot of the live app window")
    }

    // MARK: Render Video progress

    /// Render Video on the headless session, with MCP progress notifications (`token`, at most
    /// every 100 ms and for the last frame, always increasing) and cancellation: a cancelled
    /// request stops the render at the next frame, which removes the frames it wrote (photocraft
    /// `render_video_progress`).
    func renderVideoProgress(_ params: JSONValue, token: ProgressToken?, server: Server) async -> CallTool.Result {
        let (frames, sink) = AsyncStream<(Int, Int)>.makeStream()
        let stop = StopFlag()
        let notifier = Task {
            var last: Int?
            var sentAt: ContinuousClock.Instant?
            for await (done, total) in frames {
                guard let token else { continue }
                let due = done == total || sentAt.map { $0.duration(to: .now) >= .milliseconds(100) } ?? true
                guard due, last.map({ done > $0 }) ?? true, !stop.isSet else { continue }
                last = done
                sentAt = .now
                try? await server.notify(ProgressNotification.message(.init(progressToken: token, progress: Double(done), total: Double(total))))
            }
        }
        let result = await withTaskCancellationHandler {
            await headlessOp { h in
                try h.renderVideo(params) { done, total in
                    sink.yield((done, total))
                    return !stop.isSet
                }
            }
        } onCancel: {
            stop.set()
        }
        sink.finish()
        await notifier.value
        guard let result else { return Self.noBackend() }
        return Self.toResult(result)
    }

    // MARK: Tool calls

    /// Answers one tool call. Arguments a tool doesn't take, or of the wrong type, are an
    /// invalid-params error (nothing runs); everything else is a tool result, never a trap.
    public func callTool(_ name: String, _ arguments: [String: Value]?) async throws -> CallTool.Result {
        let args = MCPBridge.json(arguments)
        if let tool = MCPTools.byName[name] {
            try MCPTools.validate(name, args, schema: MCPBridge.json(tool.inputSchema))
        }
        return await dispatch(name, args)
    }

    func dispatch(_ name: String, _ a: JSONValue) async -> CallTool.Result {
        let index = a["index"]?.uint64Value.map { Int(clamping: $0) }
        func opts(_ pairs: [(String, String)]) -> [String: JSONValue] {
            var o: [String: JSONValue] = [:]
            for (from, to) in pairs { if let v = a[from], v != .null { o[to] = v } }
            return o
        }
        switch name {
        case "session_list":
            if let r = await headlessOp({ $0.sessionList() }) { return Self.toResult(r) }
            guard let b = bridgeClient else { return Self.noBackend() }
            return await Self.bridged { try await b.callRead("ui.inspect", .object([:])) }
        case "doc_open":
            let path = a["path"]?.stringValue ?? ""
            if let r = await headlessOp({ try $0.open(path) }) { return Self.toResult(r) }
            guard let b = bridgeClient else { return Self.noBackend() }
            return await Self.bridged { try await b.call("app.open", ["path": .string(path)]) }
        case "doc_place":
            let path = a["path"]?.stringValue ?? ""
            let o = opts([("scale", "scale"), ("fit", "fit"), ("center", "center")])
            if let r = await headlessOp({ try $0.place(index: index, path: path, params: .object(o)) }) { return Self.toResult(r) }
            // Bridge mode runs the app on this machine, which reads the path itself like any command.
            return await runCommand("file.placeEmbedded", .object(o.merging(["path": .string(path)]) { _, n in n }), wait: true)
        case "doc_export_layers":
            let dir = a["dir"]?.stringValue ?? ""
            let o = opts([("format", "format"), ("prefix", "prefix"), ("visible_only", "visibleOnly"), ("quality", "quality")])
            if let r = await headlessOp({ try $0.exportLayers(index: index, dir: dir, params: .object(o)) }) { return Self.toResult(r) }
            return await runCommand("file.export.layersToFiles", .object(o.merging(["dir": .string(dir)]) { _, n in n }), wait: true)
        case "doc_export_data_sets":
            let dir = a["dir"]?.stringValue ?? ""
            let o = opts([("format", "format"), ("data_sets", "dataSets"), ("naming", "naming")])
            if let r = await headlessOp({ try $0.exportDataSets(index: index, dir: dir, params: .object(o)) }) { return Self.toResult(r) }
            return await runCommand("file.export.dataSetsAsFiles", .object(o.merging(["dir": .string(dir)]) { _, n in n }), wait: true)
        case "doc_import_data_sets":
            let path = a["path"]?.stringValue ?? ""
            let o = opts([("delimiter", "delimiter")])
            if let r = await headlessOp({ try $0.importDataSets(index: index, path: path, params: .object(o)) }) { return Self.toResult(r) }
            return await runCommand("file.import.variableDataSets", .object(o.merging(["path": .string(path)]) { _, n in n }), wait: true)
        case "doc_new":
            let p = opts(["width", "height", "mode", "depth", "background", "name"].map { ($0, $0) })
            return await runCommand("file.new", .object(p), wait: true)
        case "doc_save":
            return await save(a, index: index)
        case "doc_export":
            if a["path"] == nil || a["path"] == .null { return Self.fail("doc_export needs `path`") }
            return await save(a, index: index)
        case "doc_inspect":
            if let r = await headlessOp({ h -> JSONValue in
                if index == nil && h.session.activeIndex == nil { return ["document": .null, "session": h.sessionList()] }
                return try h.inspect(index)
            }) { return Self.toResult(r) }
            guard let b = bridgeClient else { return Self.noBackend() }
            let params: JSONValue = index.map { ["document": .int($0)] } ?? .object([:])
            return await Self.bridged { try await b.callRead("engine.execute", ["command": "document.inspect", "params": params]) }
        case "doc_render_preview", "render_preview":
            let maxSide = a["max_side"]?.uint64Value.map { Int(clamping: $0) } ?? 1024
            if let r = await headlessOp({ try $0.renderPNG(index, maxSide: maxSide) }) {
                switch r {
                case .success(let png): return Self.pngResult(png, note: "flattened preview (max side \(maxSide))")
                case .failure(let e): return Self.fail(e.description)
                }
            }
            guard let b = bridgeClient else { return Self.noBackend() }
            if index != nil { return Self.fail("`index` is only supported in headless mode; bridge previews capture the app window") }
            return await screenshot(b, maxSide: maxSide)
        case "doc_select":
            guard let r = await headlessOp({ try $0.select(index ?? -1) }) else { return Self.headlessOnly("doc_select") }
            return Self.toResult(r)
        case "doc_close":
            guard let r = await headlessOp({ try $0.close(index) }) else { return Self.headlessOnly("doc_close") }
            return Self.toResult(r)
        case "command_list":
            let all: Result<JSONValue, EngineError>
            if let r = await headlessOp({ $0.commandList() }) {
                all = r
            } else if let b = bridgeClient {
                do { all = .success(try await b.callRead("engine.commands", .object([:]))) } catch { all = .failure(EngineError.wrap(error)) }
            } else {
                return Self.noBackend()
            }
            guard case .success(let list) = all else {
                if case .failure(let e) = all { return Self.fail(e.description) }
                return Self.noBackend()
            }
            let needle = a["filter"]?.stringValue?.lowercased()
            let enabledOnly = a["enabled_only"]?.boolValue ?? false
            let items = (list.arrayValue ?? list["commands"]?.arrayValue ?? []).filter { c in
                let hay = "\(c["id"]?.stringValue ?? "") \(c["label"]?.stringValue ?? "")".lowercased()
                return (needle.map { hay.contains($0) } ?? true) && (!enabledOnly || (c["enabled"]?.boolValue ?? true))
            }
            return Self.okJSON(.array(items))
        case "command_run":
            let params = a["params"].flatMap { $0 == .null ? nil : $0 } ?? .object([:])
            return await runCommand(a["id"]?.stringValue ?? "", params, wait: a["wait"]?.boolValue ?? true)
        case "jobs_list":
            return await jobsCall("jobs.list", .object([:]), read: true)
        case "jobs_cancel":
            let p: JSONValue = a["job"].flatMap { $0 == .null ? nil : $0 }.map { ["job": $0] } ?? .object([:])
            return await jobsCall("jobs.cancel", p, read: false)
        case "command_batch":
            return await batch(a)
        case "ui_inspect":
            guard let b = bridgeClient else { return Self.bridgeOnly(name) }
            return await Self.bridged { try await b.callRead("ui.inspect", .object([:])) }
        case "ui_screenshot":
            guard let b = bridgeClient else { return Self.bridgeOnly(name) }
            return await screenshot(b, maxSide: a["max_side"]?.uint64Value.map { Int(clamping: $0) })
        case "ui_pointer":
            guard let b = bridgeClient else { return Self.bridgeOnly(name) }
            var p: [String: JSONValue] = ["events": a["events"] ?? .array([])]
            if let m = a["modifiers"], m != .null { p["modifiers"] = m }
            if let button = a["button"], button != .null { p["button"] = button }
            return await Self.bridged { try await b.call("ui.pointer", .object(p)) }
        case "ui_menu_invoke":
            guard let b = bridgeClient else { return Self.bridgeOnly(name) }
            return await Self.bridged { try await b.call("ui.menu.invoke", ["id": a["id"] ?? .null]) }
        case "ui_set":
            guard let b = bridgeClient else { return Self.bridgeOnly(name) }
            return await Self.bridged { try await b.call("ui.set", a["fields"] ?? .null) }
        case "control_call":
            guard let b = bridgeClient else { return Self.bridgeOnly(name) }
            let method = a["method"]?.stringValue ?? ""
            let params = a["params"].flatMap { $0 == .null ? nil : $0 } ?? .object([:])
            return await Self.bridged { try await b.call(method, params) }
        default:
            if let id = commandIDs[name] {
                if let r = await headlessOp({ try $0.commandStart(id, a, wait: true) }) { return Self.toResult(r) }
                return await runCommand(id, a, wait: true)
            }
            return Self.fail("unknown tool `\(name)`")
        }
    }

    func save(_ a: JSONValue, index: Int?) async -> CallTool.Result {
        var tgaBits: Int?
        if let v = a["tgaBits"], v != .null, let b = v.uint64Value {
            guard b == 24 || b == 32 else { return Self.fail("`tgaBits` must be 24 or 32, got \(b)") }
            tgaBits = Int(b)
        }
        let path = a["path"]?.stringValue, format = a["format"]?.stringValue
        let quality = a["quality"]?.uint64Value.map { Int(clamping: $0) }
        let tiffLayers = a["tiffLayers"]?.boolValue ?? false
        if let b = bridgeClient {
            // The app's `app.save` takes only a path and the Targa bits: saying so beats saving
            // with defaults while the caller believes their options were applied.
            let unsupported = [format != nil ? "format" : nil, quality != nil ? "quality" : nil, tiffLayers ? "tiffLayers" : nil,
                               index != nil ? "index" : nil].compactMap { $0 }
            if !unsupported.isEmpty {
                return Self.fail("bridge mode saves with the app's current settings; `\(unsupported.joined(separator: "`, `"))` need headless mode")
            }
            var p: [String: JSONValue] = [:]
            if let path { p["path"] = .string(path) }
            if let tgaBits { p["tgaBits"] = .int(tgaBits) }
            return await Self.bridged { try await b.call("app.save", .object(p)) }
        }
        let opts = FlatFiles.ExportOptions(quality: quality.map { min(max($0, 1), 100) }, tiffLayers: tiffLayers, tgaBits: tgaBits)
        guard let r = await headlessOp({ try $0.save(index: index, path: path, format: format, options: opts) }) else { return Self.noBackend() }
        return Self.toResult(r)
    }

    func batch(_ a: JSONValue) async -> CallTool.Result {
        let given = a["steps"]?.arrayValue ?? []
        if given.count > ControlSecurity.maxBatchSteps {
            return Self.fail("batch contains \(given.count) steps; maximum is \(ControlSecurity.maxBatchSteps)")
        }
        let stop = a["stop_on_error"]?.boolValue ?? true
        let steps: [JSONValue] = given.map { s in
            ["command": s["id"] ?? .null, "params": s["params"].flatMap { $0 == .null ? nil : $0 } ?? .object([:]), "wait": .bool(s["wait"]?.boolValue ?? true)]
        }
        // The reply travels as escaped JSON text, so steps are charged their escaped size.
        let args: JSONValue = ["steps": .array(steps), "stopOnError": .bool(stop)]
        if let r = await headlessOp({ try $0.batch(args, budget: .escapedBudget()) }) { return Self.toResult(r) }
        guard let b = bridgeClient else { return Self.noBackend() }
        var results: [JSONValue] = []
        var failed = 0
        var budget = Budgets.BatchReplyBudget.escapedBudget()
        for s in steps {
            let item: JSONValue
            var wasError = false
            do { item = ["ok": true, "result": try await b.call("engine.execute", s)] } catch {
                item = ["ok": false, "error": .string(EngineError.wrap(error).description)]
                wasError = true
            }
            do { try budget.charge(item) } catch {
                failed += 1
                results.append(["ok": false, "error": .string("batch response budget exceeded; current step may have completed: \(EngineError.wrap(error))")])
                break
            }
            results.append(item)
            if wasError {
                failed += 1
                if stop { break }
            }
        }
        return Self.okJSON(["completed": .int(results.count - failed), "failed": .int(failed), "results": .array(results)])
    }

    // MARK: Resources

    public var resources: [Resource] {
        [
            Resource(name: "document", uri: Self.documentURI, title: "Active document", description: "Live doc_inspect state, or an empty session.",
                     mimeType: "application/json"),
            Resource(name: "commands", uri: Self.commandsURI, title: "Command catalog", description: "Live command_list including enabled state.",
                     mimeType: "application/json"),
        ]
    }

    /// The live JSON of a resource; an unknown one is "resource not found" (-32002).
    public func readResource(_ uri: String) async throws -> ReadResource.Result {
        let result: CallTool.Result
        switch uri {
        case Self.documentURI: result = await dispatch("doc_inspect", .object([:]))
        case Self.commandsURI: result = await dispatch("command_list", .object([:]))
        default: throw MCPError.serverError(code: -32002, message: "unknown resource `\(uri)`")
        }
        let text = result.content.compactMap { c -> String? in if case .text(let t, _, _) = c { t } else { nil } }.joined(separator: "\n")
        if result.isError == true { throw MCPError.internalError(text) }
        return ReadResource.Result(contents: [.text(text, uri: uri, mimeType: "application/json")])
    }

    // MARK: Server

    /// An MCP server over this backend, ready to `start(transport:)`.
    public func makeServer() async -> Server {
        let server = Server(name: Self.serverName, version: CLI.version, title: "PhotoCraft (native)", instructions: Self.instructions,
                            capabilities: .init(resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false)))
        let tools = self.tools
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: tools) }
        await server.withMethodHandler(CallTool.self) { [self, weak server] params in
            // Headless Render Video reports progress and stops when the client cancels.
            let args = MCPBridge.json(params.arguments)
            if params.name == "command_run", case .headless = self.backend, let server, args["id"] == "file.export.renderVideo" {
                if let tool = MCPTools.byName[params.name] { try MCPTools.validate(params.name, args, schema: MCPBridge.json(tool.inputSchema)) }
                let r = await self.renderVideoProgress(args["params"] ?? .object([:]), token: params._meta?.progressToken, server: server)
                // A cancelled request gets no response (the SDK drops it on CancellationError).
                if Task.isCancelled { throw CancellationError() }
                return r
            }
            return try await self.callTool(params.name, params.arguments)
        }
        await server.withMethodHandler(ListResources.self) { [self] _ in ListResources.Result(resources: self.resources) }
        await server.withMethodHandler(ReadResource.self) { [self] params in try await self.readResource(params.uri) }
        return server
    }
}

/// Conversions between the engine's JSON and MCP values, and the first port's entry points.
public enum MCPBridge {
    public static func value(_ j: JSONValue) -> Value {
        switch j {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n):
            if n == n.rounded(), abs(n) < 9e15 { return .int(Int(n)) }
            return .double(n)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(value))
        case .object(let o): return .object(o.mapValues(value))
        }
    }

    public static func json(_ v: Value) -> JSONValue {
        switch v {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string(let s): return .string(s)
        case .data(_, let d): return .string(d.base64EncodedString())
        case .array(let a): return .array(a.map(json))
        case .object(let o): return .object(o.mapValues(json))
        }
    }

    public static func json(_ args: [String: Value]?) -> JSONValue { .object((args ?? [:]).mapValues(json)) }

    /// The tool name of a command (`layer.new.layer` → `cmd_layer_new_layer`).
    public static func commandToolName(_ id: String) -> String { "cmd_" + id.replacingOccurrences(of: ".", with: "_") }

    /// pccli's per-command tools: the command's params schema, open to extra keys.
    public static func commandTools(_ cmds: [(id: String, label: String, params: String, schema: JSONValue, journal: Bool)]) -> [Tool] {
        cmds.map { c in
            var s = c.schema.objectValue ?? ["type": "object"]
            s["additionalProperties"] = true
            return Tool(name: commandToolName(c.id), title: c.label, description: "\(c.label) (`\(c.id)`). Params: \(c.params)", inputSchema: value(.object(s)),
                        annotations: .init(title: c.label, readOnlyHint: !c.journal, destructiveHint: c.journal, idempotentHint: !c.journal, openWorldHint: false))
        }
    }

    /// photocraft's tool set (router tools, annotated).
    public static var baseTools: [Tool] { MCPTools.all }

    /// An MCP server over `host`, ready to `start(transport:)`.
    public static func makeServer(_ host: EngineHost, perCommandTools: Bool = false) async -> Server {
        await PhotocraftMCP.headless(host: host, perCommandTools: perCommandTools).makeServer()
    }
}

/// A flag the render's frame callback reads from the engine's queue while the request's task sets
/// it on cancellation.
final class StopFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    var isSet: Bool { flag.load(ordering: .acquiring) }
    func set() { flag.store(true, ordering: .releasing) }
}
